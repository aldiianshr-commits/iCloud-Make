import Foundation
import SwiftData
import UIKit

struct EntryState: Equatable {
    let fingerprint: String
    let accountID: UUID
    let deleted: Bool
}

struct BackupPlan {
    var toUpload: [BackupSourceItem] = []
    var skipped = 0
    /// Items backed up earlier that no longer exist on the device.
    var deletedSourceIDs: [String] = []
}

struct BackupManifest: Codable {
    struct Item: Codable {
        let category: String; let sourceID: String; let name: String; let remoteID: String
        let size: Int64; let md5: String?; let fingerprint: String; let encrypted: Bool; let backedUpAt: Date; let deletedAt: Date?
    }
    var runID: UUID
    var device: String
    var createdAt: Date
    var kind: String
    var categories: [String]
    var accountID: UUID
    var items: [Item]
}

/// Runs full / incremental backups of the categories iOS lets an app read, uploads them to a
/// cloud account (auto-selected by free space unless the user picked one), verifies uploads and
/// records history. See `BackupCategory.scopeNote` for exactly what each category covers.
@MainActor
final class BackupEngine: ObservableObject {
    struct Progress: Equatable {
        var category: BackupCategory?
        var itemName = ""
        var processed = 0
        var total = 0
        var bytes: Int64 = 0
        var phase = ""
        var fraction: Double { total > 0 ? Double(processed) / Double(total) : 0 }
    }

    let store: DataStore
    let accounts: AccountManager
    let settings: AppSettings
    @Published private(set) var isRunning = false
    @Published private(set) var progress = Progress()
    @Published var lastMessage: String?
    private var runTask: Task<BackupRun?, Never>?
    /// Device folder name inside "iCloud IPA Backup".
    var deviceFolderName: String { AppPaths.sanitize(UIDevice.current.name) }

    init(store: DataStore, accounts: AccountManager, settings: AppSettings) {
        self.store = store
        self.accounts = accounts
        self.settings = settings
    }

    // MARK: Planning (pure, unit-tested)

    static func plan(items: [BackupSourceItem], existing: [String: EntryState], kind: BackupKind, accountID: UUID) -> BackupPlan {
        var plan = BackupPlan()
        let present = Set(items.map(\.sourceID))
        for item in items {
            if kind == .incremental, let e = existing[item.sourceID], !e.deleted, e.fingerprint == item.fingerprint, e.accountID == accountID {
                plan.skipped += 1
            } else {
                plan.toUpload.append(item)
            }
        }
        plan.deletedSourceIDs = existing.filter { !$0.value.deleted && !present.contains($0.key) }.map(\.key).sorted()
        return plan
    }

    // MARK: Sources

    func folderSources() -> [(id: UUID, name: String, bookmark: Data)] {
        let rows = (try? store.context.fetch(FetchDescriptor<BackupFolderSource>(sortBy: [SortDescriptor(\.addedAt)]))) ?? []
        return rows.map { ($0.id, $0.name, $0.bookmark) }
    }

    func source(for category: BackupCategory) -> BackupSource {
        switch category {
        case .photos, .videos: return PhotoLibrarySource(category: category)
        case .contacts: return ContactsSource()
        case .calendar: return CalendarSource()
        case .reminders: return RemindersSource()
        case .documents, .audio, .files: return FolderSource(category: category, folders: folderSources())
        case .appData: return AppDataSource { [weak self] in try await self?.appDataSnapshot() ?? Data() }
        }
    }

    func appDataSnapshot() throws -> Data {
        let accs = store.accounts().map { AppDataExport.Account(id: $0.id, provider: $0.providerRaw, displayName: $0.displayName, email: $0.email, role: $0.roleRaw) }
        let entries = ((try? store.context.fetch(FetchDescriptor<BackupEntry>())) ?? []).map {
            AppDataExport.Entry(key: $0.key, category: $0.categoryRaw, sourceID: $0.sourceID, name: $0.name, fingerprint: $0.fingerprint,
                                accountID: $0.accountID, remoteID: $0.remoteID, size: $0.size, md5: $0.md5, encrypted: $0.encrypted,
                                lastBackedUp: $0.lastBackedUp, deletedAt: $0.deletedAt)
        }.sorted { $0.key < $1.key }
        let settingsDict = settings.exportDictionary().mapValues { "\($0)" }
        let export = AppDataExport(exportedAt: Date(), appVersion: AppConfig.version, accounts: accs, entries: entries, settings: settingsDict)
        return try BackupSnapshot.encoder.encode(export)
    }

    func entries(category: BackupCategory? = nil) -> [BackupEntry] {
        let all = (try? store.context.fetch(FetchDescriptor<BackupEntry>(sortBy: [SortDescriptor(\.lastBackedUp, order: .reverse)]))) ?? []
        guard let category else { return all }
        return all.filter { $0.categoryRaw == category.rawValue }
    }

    func runs(limit: Int = 100) -> [BackupRun] {
        var d = FetchDescriptor<BackupRun>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        d.fetchLimit = limit
        return (try? store.context.fetch(d)) ?? []
    }

    // MARK: Run

    func start(kind: BackupKind, trigger: BackupTrigger, categories: Set<BackupCategory>? = nil) {
        guard !isRunning else { return }
        runTask = Task { await self.run(kind: kind, trigger: trigger, categories: categories) }
    }

    func cancel() { runTask?.cancel() }

    @discardableResult
    func run(kind: BackupKind, trigger: BackupTrigger, categories requested: Set<BackupCategory>? = nil) async -> BackupRun? {
        guard !isRunning else { return nil }
        let categories = BackupCategory.allCases.filter { (requested ?? settings.backupCategories).contains($0) }
        guard !categories.isEmpty else { lastMessage = L("Choose at least one category to back up."); return nil }
        isRunning = true
        progress = Progress(phase: L("Preparing…"))
        defer { isRunning = false; progress.phase = "" }

        let account: CloudAccount
        do {
            if accounts.accounts.contains(where: { $0.quotaUpdatedAt == nil }) { await accounts.refreshAll() }
            account = try accounts.pickAccount(forBytes: 0, preferred: settings.backupAccountID)
        } catch {
            lastMessage = error.localizedDescription
            store.logActivity(.backup, L("Backup could not start"), detail: error.localizedDescription, success: false)
            return nil
        }
        let run = BackupRun(kind: kind, trigger: trigger, categories: categories, accountID: account.id)
        store.context.insert(run)
        store.save()
        store.logActivity(.backup, LF("%@ backup started", kind == .full ? L("Full") : L("Incremental")), detail: account.email, account: account.id)

        var errors: [String] = []
        do {
            let provider = try accounts.provider(for: account.id)
            progress.phase = L("Preparing cloud folders…")
            let deviceRoot = try await provider.ensureFolder(path: [AppConfig.remoteBackupRoot, deviceFolderName])
            run.remoteFolderID = deviceRoot.id
            var folderCache: [String: RemoteFolder] = [:]

            for category in categories {
                try Task.checkCancellation()
                progress.category = category
                progress.phase = LF("Scanning %@…", category.title)
                let src = source(for: category)
                let items: [BackupSourceItem]
                do {
                    try await src.requestAccess()
                    items = try await src.enumerate()
                } catch {
                    errors.append("\(category.title): \(error.localizedDescription)")
                    continue
                }
                let existingEntries = entries(category: category)
                var existing: [String: EntryState] = [:]
                for e in existingEntries { existing[e.sourceID] = EntryState(fingerprint: e.fingerprint, accountID: e.accountID, deleted: e.deletedAt != nil) }
                let plan = Self.plan(items: items, existing: existing, kind: kind, accountID: account.id)

                // Deletion detection: never deletes cloud copies; marks them so restore can still offer them.
                for id in plan.deletedSourceIDs {
                    if let e = existingEntries.first(where: { $0.sourceID == id }) { e.deletedAt = Date() }
                }
                run.itemsDeletedDetected += plan.deletedSourceIDs.count
                run.itemsSkipped += plan.skipped
                run.itemsTotal += items.count
                progress.total += plan.toUpload.count
                store.save()

                for item in plan.toUpload {
                    try Task.checkCancellation()
                    progress.itemName = item.name
                    progress.phase = LF("Backing up %@", category.title)
                    do {
                        let path = [category.groupFolderName] + item.subfolder
                        let key = path.joined(separator: "/")
                        let folder: RemoteFolder
                        if let f = folderCache[key] { folder = f } else {
                            folder = try await ensure(path: path, under: deviceRoot, provider: provider, cache: &folderCache)
                        }
                        let local = try await item.export()
                        defer { try? FileManager.default.removeItem(at: local) }
                        let uploadName = item.isSnapshot ? Self.snapshotName(item.name, date: Date()) : item.name
                        let result = try await RetryPolicy(maxAttempts: 3).run {
                            try await TransferManager.upload(localFile: local, name: uploadName, provider: provider, folder: folder,
                                                             encrypt: self.settings.encryptBackups, handle: nil, progress: nil)
                        }
                        let previous = existingEntries.first { $0.sourceID == item.sourceID }
                        if kind == .full, let previous, previous.accountID == account.id, previous.remoteID != result.item.id, !item.isSnapshot {
                            // Full backup replaced this item: move the older copy to the provider's trash (recoverable).
                            try? await provider.delete(RemoteItem(id: previous.remoteID, name: previous.name, isFolder: false, size: previous.size,
                                                                  path: previous.remoteID.hasPrefix("/") ? previous.remoteID : nil), permanently: false)
                        }
                        upsertEntry(item: item, result: result, account: account.id, run: run, folderID: folder.id)
                        run.itemsUploaded += 1
                        run.bytesUploaded += result.item.size
                        if result.verified { run.verifiedCount += 1 }
                        progress.bytes += result.item.size
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch AppError.cancelled {
                        throw CancellationError()
                    } catch {
                        run.itemsFailed += 1
                        errors.append("\(item.name): \(error.localizedDescription)")
                        Log.backup.error("item failed \(item.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                    progress.processed += 1
                    if progress.processed % 10 == 0 { store.save() }
                }
                store.save()
            }

            progress.phase = L("Writing manifest…")
            run.manifestRemoteID = try? await uploadManifest(run: run, account: account.id, provider: provider, deviceRoot: deviceRoot, cache: &folderCache)
            run.status = errors.isEmpty ? .completed : (run.itemsUploaded + run.itemsSkipped > 0 ? .completedWithErrors : .failed)
        } catch is CancellationError {
            run.status = .cancelled
        } catch {
            run.status = .failed
            errors.append(error.localizedDescription)
        }
        run.finishedAt = Date()
        run.message = errors.isEmpty ? nil : errors.prefix(20).joined(separator: "\n")
        store.save()
        if run.status == .completed || run.status == .completedWithErrors { settings.lastBackupAt = Date() }
        let summary = LF("%d uploaded, %d unchanged, %d failed", run.itemsUploaded, run.itemsSkipped, run.itemsFailed)
        store.logActivity(.backup, LF("Backup %@", run.status.title), detail: summary, account: account.id, success: run.status == .completed)
        lastMessage = summary
        BackupScheduler.shared.scheduleNext(settings: settings)
        Task { await accounts.refresh(account) }
        return run
    }

    private func ensure(path: [String], under root: RemoteFolder, provider: CloudProvider, cache: inout [String: RemoteFolder]) async throws -> RemoteFolder {
        var current = root
        var key: [String] = []
        for component in path {
            key.append(component)
            let k = key.joined(separator: "/")
            if let f = cache[k] { current = f; continue }
            let children = try await provider.list(folder: current)
            if let existing = children.first(where: { $0.isFolder && $0.name == component }) {
                current = RemoteFolder(id: existing.id, name: existing.name, path: existing.path)
            } else {
                let made = try await provider.createFolder(name: component, in: current)
                current = RemoteFolder(id: made.id, name: made.name, path: made.path)
            }
            cache[k] = current
        }
        return current
    }

    static func snapshotName(_ name: String, date: Date) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return "\(base)_\(f.string(from: date))" + (ext.isEmpty ? "" : ".\(ext)")
    }

    private func upsertEntry(item: BackupSourceItem, result: TransferManager.UploadResult, account: UUID, run: BackupRun, folderID: String) {
        let key = "\(item.category.rawValue)|\(item.sourceID)"
        var d = FetchDescriptor<BackupEntry>(predicate: #Predicate { $0.key == key })
        d.fetchLimit = 1
        let entry: BackupEntry
        if let e = try? store.context.fetch(d).first { entry = e } else {
            entry = BackupEntry(category: item.category, sourceID: item.sourceID, name: item.name, fingerprint: item.fingerprint, accountID: account, remoteID: result.item.id)
            store.context.insert(entry)
        }
        entry.name = item.name
        entry.fingerprint = item.fingerprint
        entry.accountID = account
        entry.remoteID = result.item.id
        entry.remoteParentID = folderID
        entry.size = result.item.size
        entry.md5 = result.md5
        entry.encrypted = settings.encryptBackups
        entry.creationDate = item.creationDate
        entry.lastBackedUp = Date()
        entry.deletedAt = nil
        entry.lastRunID = run.id
    }

    private func uploadManifest(run: BackupRun, account: UUID, provider: CloudProvider, deviceRoot: RemoteFolder, cache: inout [String: RemoteFolder]) async throws -> String {
        let folder = try await ensure(path: ["Manifests"], under: deviceRoot, provider: provider, cache: &cache)
        let items = entries().filter { $0.accountID == account }.map {
            BackupManifest.Item(category: $0.categoryRaw, sourceID: $0.sourceID, name: $0.name, remoteID: $0.remoteID, size: $0.size,
                                md5: $0.md5, fingerprint: $0.fingerprint, encrypted: $0.encrypted, backedUpAt: $0.lastBackedUp, deletedAt: $0.deletedAt)
        }
        let manifest = BackupManifest(runID: run.id, device: deviceFolderName, createdAt: Date(), kind: run.kindRaw,
                                      categories: run.categories.map(\.rawValue), accountID: account, items: items)
        let url = AppPaths.tempFile("manifest-\(run.id.uuidString).json")
        try BackupSnapshot.encoder.encode(manifest).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await TransferManager.upload(localFile: url, name: Self.snapshotName("manifest.json", date: Date()), provider: provider,
                                                      folder: folder, encrypt: false, handle: nil, progress: nil)
        return result.item.id
    }

    // MARK: Verification

    struct VerificationReport: Equatable {
        var checked = 0
        var ok = 0
        var missing: [String] = []
        var mismatched: [String] = []
    }

    /// Re-lists the backup folder in the cloud and checks every recorded item still exists with the
    /// expected size (and MD5 where the provider reports one).
    func verify(accountID: UUID? = nil) async throws -> VerificationReport {
        let targets = Set(entries().map(\.accountID)).filter { accountID == nil || $0 == accountID }
        var report = VerificationReport()
        for acc in targets {
            let provider = try accounts.provider(for: acc)
            progress.phase = L("Verifying backup…")
            let root = try await provider.ensureFolder(path: [AppConfig.remoteBackupRoot, deviceFolderName])
            let remote = try await provider.listRecursive(folder: root)
            let byID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for e in entries().filter({ $0.accountID == acc }) {
                report.checked += 1
                guard let r = byID[e.remoteID] else { report.missing.append(e.name); continue }
                let sizeOK = e.size == 0 || r.size == e.size
                let md5OK = provider.kind != .googleDrive || e.md5 == nil || r.md5?.lowercased() == e.md5?.lowercased()
                if sizeOK && md5OK { report.ok += 1 } else { report.mismatched.append(e.name) }
            }
        }
        progress.phase = ""
        store.logActivity(.backup, L("Backup verified"), detail: LF("%d OK, %d missing, %d mismatched", report.ok, report.missing.count, report.mismatched.count),
                          success: report.missing.isEmpty && report.mismatched.isEmpty)
        return report
    }

    // MARK: Manifests (restore on a new device)

    /// Downloads the newest manifest from the account and recreates local entries so restore works
    /// after reinstalling or on another device.
    func importLatestManifest(accountID: UUID, deviceFolder: String? = nil) async throws -> Int {
        let provider = try accounts.provider(for: accountID)
        let root = try await provider.ensureFolder(path: [AppConfig.remoteBackupRoot])
        let devices = try await provider.list(folder: root).filter(\.isFolder)
        guard let device = devices.first(where: { $0.name == (deviceFolder ?? deviceFolderName) }) ?? devices.first else {
            throw AppError.notFound(L("backup folder"))
        }
        let manifests = try await provider.list(folder: RemoteFolder(id: device.id, name: device.name, path: device.path))
            .first(where: { $0.isFolder && $0.name == "Manifests" })
        guard let mf = manifests else { throw AppError.notFound(L("manifest")) }
        let files = try await provider.list(folder: RemoteFolder(id: mf.id, name: mf.name, path: mf.path))
            .filter { !$0.isFolder && $0.name.hasPrefix("manifest") }
            .sorted { $0.name > $1.name }
        guard let latest = files.first else { throw AppError.notFound(L("manifest")) }
        let local = try await TransferManager.download(latest, provider: provider, to: AppPaths.staging, progress: nil)
        defer { try? FileManager.default.removeItem(at: local) }
        let manifest = try BackupSnapshot.decoder.decode(BackupManifest.self, from: Data(contentsOf: local))
        var count = 0
        for i in manifest.items {
            guard let cat = BackupCategory(rawValue: i.category) else { continue }
            let key = "\(i.category)|\(i.sourceID)"
            var d = FetchDescriptor<BackupEntry>(predicate: #Predicate { $0.key == key })
            d.fetchLimit = 1
            let e = (try? store.context.fetch(d).first) ?? {
                let n = BackupEntry(category: cat, sourceID: i.sourceID, name: i.name, fingerprint: i.fingerprint, accountID: accountID, remoteID: i.remoteID)
                store.context.insert(n)
                return n
            }()
            e.remoteID = i.remoteID
            e.accountID = accountID
            e.size = i.size
            e.md5 = i.md5
            e.encrypted = i.encrypted
            e.lastBackedUp = i.backedUpAt
            e.deletedAt = i.deletedAt
            count += 1
        }
        store.save()
        store.logActivity(.restore, LF("Imported backup catalogue (%d items)", count), account: accountID)
        return count
    }
}

extension BackupRunStatus {
    var title: String {
        switch self {
        case .running: return L("running")
        case .completed: return L("completed")
        case .completedWithErrors: return L("completed with errors")
        case .failed: return L("failed")
        case .cancelled: return L("cancelled")
        }
    }
}
