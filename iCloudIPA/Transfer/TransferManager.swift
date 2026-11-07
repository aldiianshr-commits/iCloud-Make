import Foundation
import SwiftData
import UIKit

/// Counting semaphore for limiting parallel transfers.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ permits: Int) { self.permits = permits }

    func wait() async {
        if permits > 0 { permits -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty { permits += 1 } else { waiters.removeFirst().resume() }
    }

    func setPermits(_ n: Int, inUse: Int) {
        permits = max(0, n - inUse)
    }
}

struct LiveProgress: Equatable {
    var completed: Int64
    var total: Int64
    var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
}

/// Upload/download queue with persistence, parallelism limits, retry, pause/resume,
/// optional client-side encryption and post-transfer integrity verification.
@MainActor
final class TransferManager: ObservableObject {
    let store: DataStore
    let accounts: AccountManager
    let settings: AppSettings
    @Published private(set) var live: [UUID: LiveProgress] = [:]
    @Published private(set) var activeCount = 0

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var semaphores: [UUID: AsyncSemaphore] = [:]
    private var globalSemaphore: AsyncSemaphore
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static var outbox: URL { AppPaths.ensure(AppPaths.applicationSupport.appendingPathComponent("Outbox", isDirectory: true)) }

    init(store: DataStore, accounts: AccountManager, settings: AppSettings) {
        self.store = store
        self.accounts = accounts
        self.settings = settings
        self.globalSemaphore = AsyncSemaphore(max(1, settings.maxParallelTransfers))
    }

    // MARK: Startup recovery

    /// Records left "running" by a crash or termination are re-queued; queued ones restart.
    func recoverAfterLaunch() {
        let all = (try? store.context.fetch(FetchDescriptor<TransferRecord>())) ?? []
        for r in all where r.status == .running { r.status = .queued }
        store.save()
        for r in all where r.status == .queued { schedule(r) }
    }

    // MARK: Queries

    func records(limit: Int = 200) -> [TransferRecord] {
        var d = FetchDescriptor<TransferRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.fetchLimit = limit
        return (try? store.context.fetch(d)) ?? []
    }

    func record(_ id: UUID) -> TransferRecord? {
        var d = FetchDescriptorFactory.transfer(id)
        d.fetchLimit = 1
        return try? store.context.fetch(d).first
    }

    // MARK: Enqueue

    @discardableResult
    func enqueueUpload(file: URL, name: String? = nil, account: UUID, folder: RemoteFolder, encrypt: Bool? = nil, deleteSourceAfter: Bool = false) throws -> TransferRecord {
        let displayName = name ?? file.lastPathComponent
        // Copy into the persistent outbox so the transfer survives relaunch.
        let staged = AppPaths.uniqueURL(in: Self.outbox, name: UUID().uuidString + "-" + AppPaths.sanitize(displayName))
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: file, to: staged)
        } catch {
            throw AppError.io(error.localizedDescription)
        }
        if deleteSourceAfter { try? FileManager.default.removeItem(at: file) }
        let r = TransferRecord(kind: .upload, accountID: account, name: displayName, totalBytes: AppPaths.fileSize(staged))
        r.localPath = staged.path
        r.remoteParentID = folder.id
        r.errorMessage = nil
        r.encrypted = encrypt ?? settings.encryptUploads
        // Folder path (TeraBox) is carried in remoteID until the upload completes.
        r.remoteID = folder.path
        store.context.insert(r)
        store.save()
        schedule(r)
        return r
    }

    @discardableResult
    func enqueueDownload(_ item: RemoteItem, account: UUID, to directory: URL = AppPaths.downloads) -> TransferRecord {
        let r = TransferRecord(kind: .download, accountID: account, name: item.name, totalBytes: item.size)
        r.remoteID = item.id
        r.remoteParentID = item.parentID
        r.localPath = directory.path
        store.context.insert(r)
        store.save()
        schedule(r, item: item)
        return r
    }

    /// Copies or moves an item between (or within) accounts. Same-account copies use the
    /// provider's server-side copy when available; cross-account goes through a temporary download.
    @discardableResult
    func enqueueTransfer(_ item: RemoteItem, from source: UUID, to target: UUID, folder: RemoteFolder, move: Bool) -> TransferRecord {
        let r = TransferRecord(kind: move ? .move : .copy, accountID: source, name: item.name, totalBytes: item.size)
        r.targetAccountID = target
        r.remoteID = item.id
        r.remoteParentID = folder.id
        r.localPath = folder.path
        store.context.insert(r)
        store.save()
        schedule(r, item: item)
        return r
    }

    // MARK: Control

    func pause(_ r: TransferRecord) {
        guard !r.status.isFinished else { return }
        tasks[r.id]?.cancel()
        tasks[r.id] = nil
        r.status = .paused
        store.save()
    }

    func resume(_ r: TransferRecord) {
        guard r.status == .paused || r.status == .failed else { return }
        r.status = .queued
        r.errorMessage = nil
        store.save()
        schedule(r)
    }

    func cancel(_ r: TransferRecord) {
        tasks[r.id]?.cancel()
        tasks[r.id] = nil
        r.status = .cancelled
        r.finishedAt = Date()
        cleanupStaged(r)
        store.save()
    }

    func clearFinished() {
        for r in records(limit: 5000) where r.status.isFinished { store.context.delete(r) }
        store.save()
    }

    private func cleanupStaged(_ r: TransferRecord) {
        if r.kind == .upload, let p = r.localPath, p.hasPrefix(Self.outbox.path) { try? FileManager.default.removeItem(atPath: p) }
    }

    // MARK: Scheduling

    private func semaphore(for account: UUID) -> AsyncSemaphore {
        if let s = semaphores[account] { return s }
        let limit = (try? accounts.provider(for: account).maxConcurrentTransfers) ?? 2
        let s = AsyncSemaphore(limit)
        semaphores[account] = s
        return s
    }

    private func schedule(_ r: TransferRecord, item: RemoteItem? = nil) {
        guard tasks[r.id] == nil else { return }
        let id = r.id
        let accountSem = semaphore(for: r.accountID)
        let global = globalSemaphore
        tasks[id] = Task { [weak self] in
            await global.wait()
            await accountSem.wait()
            defer { Task { await accountSem.signal(); await global.signal() } }
            guard let self, !Task.isCancelled else { return }
            await self.execute(id, item: item)
            self.tasks[id] = nil
        }
    }

    private func execute(_ id: UUID, item: RemoteItem?) async {
        guard let r = record(id), r.status == .queued else { return }
        r.status = .running
        r.startedAt = Date()
        r.attempts += 1
        store.save()
        beginBackgroundWork()
        activeCount += 1
        defer {
            activeCount -= 1
            live[id] = nil
            endBackgroundWorkIfIdle()
        }
        let progress: ProgressHandler = { [weak self] done, total in
            Task { @MainActor in self?.live[id] = LiveProgress(completed: done, total: total) }
        }
        do {
            switch r.kind {
            case .upload: try await performUpload(r, progress: progress)
            case .download: try await performDownload(r, item: item, progress: progress)
            case .copy, .move: try await performTransfer(r, item: item, progress: progress)
            }
            r.status = .completed
            r.transferredBytes = r.totalBytes
            r.finishedAt = Date()
            r.errorMessage = nil
            store.save()
        } catch {
            if let latest = record(id), latest.status == .paused || latest.status == .cancelled { return }
            let message = (error as? AppError)?.localizedDescription ?? error.localizedDescription
            if (error as? AppError) == .cancelled || Task.isCancelled {
                r.status = .paused
            } else {
                r.status = .failed
                r.errorMessage = message
                r.finishedAt = Date()
                store.logActivity(.error, LF("Transfer failed: %@", r.name), detail: message, account: r.accountID, success: false)
            }
            store.save()
        }
    }

    // MARK: Workers

    private func performUpload(_ r: TransferRecord, progress: @escaping ProgressHandler) async throws {
        guard let path = r.localPath, FileManager.default.fileExists(atPath: path) else {
            throw AppError.io(L("The staged file is missing; add it again."))
        }
        let provider = try accounts.provider(for: r.accountID)
        let folder = RemoteFolder(id: r.remoteParentID ?? provider.rootFolder.id, name: "", path: r.remoteID ?? r.remoteParentID)
        let result = try await Self.upload(localFile: URL(fileURLWithPath: path), name: r.name, provider: provider, folder: folder,
                                           encrypt: r.encrypted, handle: TransferHandle(recordID: r.id, store: store), progress: progress)
        r.remoteID = result.item.id
        r.verified = result.verified
        r.totalBytes = result.item.size
        store.upsertIndex(account: r.accountID, items: [result.item])
        cleanupStaged(r)
        store.logActivity(.upload, LF("Uploaded %@", r.name), detail: result.verified ? L("Verified") : nil, account: r.accountID)
    }

    struct UploadResult { let item: RemoteItem; let verified: Bool; let md5: String }

    /// Shared by the queue and the backup engine: optional encryption, upload, integrity verification.
    static func upload(localFile: URL, name: String, provider: CloudProvider, folder: RemoteFolder, encrypt: Bool,
                       handle: TransferHandle?, progress: ProgressHandler?) async throws -> UploadResult {
        var source = localFile
        var remoteName = name
        var tempEncrypted: URL?
        if encrypt {
            let enc = AppPaths.tempFile(UUID().uuidString + "." + FileEncryptor.encryptedExtension)
            try FileEncryptor.encrypt(file: localFile, to: enc, key: try KeyManager.shared.masterKey())
            source = enc
            remoteName = name + "." + FileEncryptor.encryptedExtension
            tempEncrypted = enc
        }
        defer { if let t = tempEncrypted { try? FileManager.default.removeItem(at: t) } }
        let localMD5 = try FileHasher.md5Hex(of: source)
        let localSize = AppPaths.fileSize(source)
        var item = try await provider.upload(file: source, name: remoteName, to: folder, record: handle, progress: progress)
        if provider.kind == .googleDrive && item.md5 == nil { item = try await provider.item(id: item.id) }
        // Verification: Drive returns the server-side MD5; TeraBox returns size (its md5 field is not a plain digest).
        var verified = false
        if provider.kind == .googleDrive {
            guard let remote = item.md5 else { throw AppError.integrityCheckFailed(L("server did not return a checksum")) }
            guard remote.lowercased() == localMD5 else {
                throw AppError.integrityCheckFailed(LF("checksum mismatch (local %@, cloud %@)", localMD5, remote))
            }
            verified = true
        } else {
            verified = item.size == localSize
        }
        return UploadResult(item: item, verified: verified, md5: localMD5)
    }

    private func performDownload(_ r: TransferRecord, item: RemoteItem?, progress: @escaping ProgressHandler) async throws {
        let provider = try accounts.provider(for: r.accountID)
        let remote: RemoteItem
        if let item { remote = item } else { remote = try await provider.item(id: r.remoteID ?? "") }
        let dir = URL(fileURLWithPath: r.localPath ?? AppPaths.downloads.path)
        AppPaths.ensure(dir)
        let final = try await Self.download(remote, provider: provider, to: dir, recordID: r.id, progress: progress)
        r.localPath = final.path
        r.verified = true
        store.logActivity(.download, LF("Downloaded %@", remote.name), account: r.accountID)
    }

    /// Files at or above this size are downloaded with the background URLSession (Google Drive).
    static let backgroundDownloadThreshold: Int64 = 20 * 1024 * 1024

    /// Downloads, verifies and (when needed) decrypts into `directory`; returns the final local URL.
    static func download(_ remote: RemoteItem, provider: CloudProvider, to directory: URL, recordID: UUID? = nil, progress: ProgressHandler?) async throws -> URL {
        let tmp: URL
        if let drive = provider as? GoogleDriveProvider, let recordID, remote.size >= backgroundDownloadThreshold,
           GoogleDriveProvider.exportFormat(for: remote.mimeType) == nil, !AppConfig.isRunningTests {
            let req = try await drive.mediaRequest(for: remote)
            tmp = try await BackgroundTransferService.shared.download(req, recordID: recordID, expectedSize: remote.size, progress: progress)
        } else {
            tmp = AppPaths.tempFile()
            try await provider.download(remote, to: tmp, progress: progress)
        }
        return try finalizeDownload(tmp, remote: remote, provider: provider, directory: directory)
    }

    /// Verifies checksum, decrypts iCloud IPA encrypted files and moves the result into place.
    static func finalizeDownload(_ tmp: URL, remote: RemoteItem, provider: CloudProvider, directory: URL) throws -> URL {
        defer { try? FileManager.default.removeItem(at: tmp) }
        if provider.kind == .googleDrive, let md5 = remote.md5, GoogleDriveProvider.exportFormat(for: remote.mimeType) == nil {
            let local = try FileHasher.md5Hex(of: tmp)
            guard local == md5.lowercased() else { throw AppError.integrityCheckFailed(LF("checksum mismatch (local %@, cloud %@)", local, md5)) }
        }
        var name = remote.name
        if let export = GoogleDriveProvider.exportFormat(for: remote.mimeType), (name as NSString).pathExtension.lowercased() != export.ext {
            name += "." + export.ext
        }
        if FileEncryptor.isEncrypted(tmp) {
            if name.hasSuffix("." + FileEncryptor.encryptedExtension) { name = String(name.dropLast(FileEncryptor.encryptedExtension.count + 1)) }
            let out = AppPaths.uniqueURL(in: directory, name: name)
            try FileEncryptor.decrypt(file: tmp, to: out, key: try KeyManager.shared.masterKey())
            return out
        }
        let out = AppPaths.uniqueURL(in: directory, name: name)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    private func performTransfer(_ r: TransferRecord, item: RemoteItem?, progress: @escaping ProgressHandler) async throws {
        guard let target = r.targetAccountID else { throw AppError.notFound(L("target account")) }
        let src = try accounts.provider(for: r.accountID)
        let dst = try accounts.provider(for: target)
        let source: RemoteItem
        if let item { source = item } else { source = try await src.item(id: r.remoteID ?? "") }
        let folder = RemoteFolder(id: r.remoteParentID ?? dst.rootFolder.id, name: "", path: r.localPath ?? r.remoteParentID)
        let isMove = r.kind == .move
        let result: RemoteItem
        if r.accountID == target {
            result = isMove ? try await src.move(source, to: folder) : try await src.copy(source, to: folder)
        } else {
            result = try await Self.crossAccountCopy(source, from: src, to: dst, folder: folder, progress: progress)
            if isMove { try await src.delete(source, permanently: false) }
        }
        store.upsertIndex(account: target, items: [result])
        if isMove { store.removeFromIndex(account: r.accountID, remoteID: source.id) }
        store.logActivity(isMove ? .move : .copy, LF(isMove ? "Moved %@" : "Copied %@", source.name), account: target)
    }

    /// Download → upload (with checksum verification on both legs). Folders are copied recursively.
    static func crossAccountCopy(_ item: RemoteItem, from src: CloudProvider, to dst: CloudProvider, folder: RemoteFolder, progress: ProgressHandler?) async throws -> RemoteItem {
        if item.isFolder {
            let made = try await dst.createFolder(name: item.name, in: folder)
            let target = RemoteFolder(id: made.id, name: made.name, path: made.path)
            for child in try await src.list(folder: RemoteFolder(id: item.id, name: item.name, path: item.path)) {
                _ = try await crossAccountCopy(child, from: src, to: dst, folder: target, progress: nil)
            }
            return made
        }
        let dir = AppPaths.ensure(AppPaths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true))
        defer { try? FileManager.default.removeItem(at: dir) }
        let tmp = dir.appendingPathComponent("payload")
        try await src.download(item, to: tmp) { done, total in progress?(done / 2, total) }
        if src.kind == .googleDrive, let md5 = item.md5, GoogleDriveProvider.exportFormat(for: item.mimeType) == nil {
            guard try FileHasher.md5Hex(of: tmp) == md5.lowercased() else { throw AppError.integrityCheckFailed(item.name) }
        }
        var name = item.name
        if let export = GoogleDriveProvider.exportFormat(for: item.mimeType) { name += "." + export.ext }
        let result = try await upload(localFile: tmp, name: name, provider: dst, folder: folder, encrypt: false, handle: nil) { done, total in
            progress?(total / 2 + done / 2, total)
        }
        return result.item
    }

    // MARK: Background execution

    private func beginBackgroundWork() {
        guard backgroundTask == .invalid, !AppConfig.isRunningTests else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "transfers") { [weak self] in
            Task { @MainActor in self?.endBackgroundWork() }
        }
    }

    private func endBackgroundWorkIfIdle() {
        if activeCount == 0 { endBackgroundWork() }
    }

    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
