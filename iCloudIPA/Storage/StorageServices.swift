import Foundation
import SwiftData
import ZIPFoundation

// MARK: - Index

/// Builds the local metadata index (file/folder structure) for each account. Google Drive uses the
/// Changes API after the first full scan; TeraBox is rescanned.
@MainActor
final class StorageIndexer: ObservableObject {
    let store: DataStore
    let accounts: AccountManager
    @Published private(set) var indexing: Set<UUID> = []
    @Published private(set) var counts: [UUID: Int] = [:]
    @Published var lastError: String?

    init(store: DataStore, accounts: AccountManager) {
        self.store = store
        self.accounts = accounts
    }

    private func tokenKey(_ id: UUID) -> String { "index.changeToken.\(id.uuidString)" }

    func index(_ account: CloudAccount, full: Bool = false) async {
        let id = account.id
        guard !indexing.contains(id) else { return }
        indexing.insert(id)
        defer { indexing.remove(id) }
        do {
            let provider = try accounts.provider(for: id)
            if let drive = provider as? GoogleDriveProvider, !full, let token = UserDefaults.standard.string(forKey: tokenKey(id)) {
                let delta = try await drive.changes(since: token)
                store.upsertIndex(account: id, items: delta.changed)
                for r in delta.removed { store.removeFromIndex(account: id, remoteID: r) }
                UserDefaults.standard.set(delta.next, forKey: tokenKey(id))
            } else {
                let startToken = try? await (provider as? GoogleDriveProvider)?.startPageToken()
                let items = try await provider.listAll { [weak self] n in Task { @MainActor in self?.counts[id] = n } }
                store.clearIndex(account: id)
                store.upsertIndex(account: id, items: items)
                if let startToken { UserDefaults.standard.set(startToken, forKey: tokenKey(id)) }
            }
            account.lastSync = Date()
            store.save()
            store.logActivity(.sync, LF("Index updated (%@)", account.provider.title), detail: account.email, account: id)
        } catch {
            lastError = error.localizedDescription
            store.logActivity(.sync, L("Index update failed"), detail: error.localizedDescription, account: id, success: false)
        }
    }

    func indexAll(full: Bool = false) async {
        for a in accounts.accounts { await index(a, full: full) }
    }

    func reset(_ account: CloudAccount) {
        UserDefaults.standard.removeObject(forKey: tokenKey(account.id))
        store.clearIndex(account: account.id)
    }
}

// MARK: - Analyzer

struct DuplicateGroup: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let size: Int64
    let files: [RemoteItemRef]
    var reclaimable: Int64 { size * Int64(max(0, files.count - 1)) }
}

struct RemoteItemRef: Hashable, Identifiable {
    var id: String { "\(accountID.uuidString)|\(item.id)" }
    let accountID: UUID
    let item: RemoteItem
}

struct CategoryUsage: Identifiable, Hashable {
    var id: FileCategory { category }
    let category: FileCategory
    let bytes: Int64
    let count: Int
}

/// Pure analysis over the index (unit-tested).
enum StorageAnalyzer {
    /// Duplicates are files with identical content: same MD5 (when the provider supplies one)
    /// and same size; files without a checksum are grouped by name+size as "likely duplicates".
    static func duplicates(_ records: [RemoteItemRef], minSize: Int64 = 1) -> [DuplicateGroup] {
        var groups: [String: [RemoteItemRef]] = [:]
        for r in records where !r.item.isFolder && r.item.size >= minSize {
            let key: String
            if let md5 = r.item.md5, md5.count == 32 { key = "md5:\(md5.lowercased()):\(r.item.size)" }
            else { key = "name:\(r.item.name.lowercased()):\(r.item.size)" }
            groups[key, default: []].append(r)
        }
        return groups.filter { $0.value.count > 1 }
            .map { DuplicateGroup(key: $0.key, size: $0.value[0].item.size, files: $0.value.sorted { ($0.item.modifiedAt ?? .distantPast) < ($1.item.modifiedAt ?? .distantPast) }) }
            .sorted { $0.reclaimable > $1.reclaimable }
    }

    static func largest(_ records: [RemoteItemRef], limit: Int = 100, minSize: Int64 = 50 * 1024 * 1024) -> [RemoteItemRef] {
        Array(records.filter { !$0.item.isFolder && $0.item.size >= minSize }.sorted { $0.item.size > $1.item.size }.prefix(limit))
    }

    static func byCategory(_ records: [RemoteItemRef]) -> [CategoryUsage] {
        var bytes: [FileCategory: Int64] = [:]
        var count: [FileCategory: Int] = [:]
        for r in records where !r.item.isFolder {
            let c = r.item.category
            bytes[c, default: 0] += r.item.size
            count[c, default: 0] += 1
        }
        return bytes.map { CategoryUsage(category: $0.key, bytes: $0.value, count: count[$0.key] ?? 0) }.sorted { $0.bytes > $1.bytes }
    }

    static func recent(_ records: [RemoteItemRef], limit: Int = 50) -> [RemoteItemRef] {
        Array(records.filter { !$0.item.isFolder }.sorted { ($0.item.createdAt ?? $0.item.modifiedAt ?? .distantPast) > ($1.item.createdAt ?? $1.item.modifiedAt ?? .distantPast) }.prefix(limit))
    }

    struct Suggestion: Identifiable, Hashable {
        enum Kind: Hashable { case duplicates, largeFiles, trash, rebalance }
        var id: String { "\(kind)" }
        let kind: Kind
        let bytes: Int64
        let detail: String
    }

    /// Storage optimisation suggestions based on real index data and quotas.
    static func suggestions(duplicates: [DuplicateGroup], large: [RemoteItemRef], trashBytes: Int64, accounts: [(name: String, fraction: Double)]) -> [Suggestion] {
        var out: [Suggestion] = []
        let dup = duplicates.reduce(0) { $0 + $1.reclaimable }
        if dup > 0 { out.append(Suggestion(kind: .duplicates, bytes: dup, detail: LF("%d groups of duplicate files", duplicates.count))) }
        let big = large.reduce(0) { $0 + $1.item.size }
        if big > 0 { out.append(Suggestion(kind: .largeFiles, bytes: big, detail: LF("%d files larger than 50 MB", large.count))) }
        if trashBytes > 0 { out.append(Suggestion(kind: .trash, bytes: trashBytes, detail: L("Files in trash still count against your quota"))) }
        if let full = accounts.first(where: { $0.fraction > 0.9 }), accounts.contains(where: { $0.fraction < 0.5 }) {
            out.append(Suggestion(kind: .rebalance, bytes: 0, detail: LF("%@ is over 90%% full — move files to an emptier account", full.name)))
        }
        return out
    }
}

// MARK: - ZIP

/// Create and extract ZIP archives (ZIPFoundation, MIT). RAR is not supported: there is no
/// RAR extractor with a license compatible with App Store distribution.
enum ZipService {
    static func zip(_ items: [URL], into archive: URL) throws {
        try? FileManager.default.removeItem(at: archive)
        let a: Archive
        do { a = try Archive(url: archive, accessMode: .create) } catch { throw AppError.io(error.localizedDescription) }
        for item in items {
            let base = item.deletingLastPathComponent()
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
            if isDir.boolValue {
                let en = FileManager.default.enumerator(at: item, includingPropertiesForKeys: [.isDirectoryKey])
                try a.addEntry(with: item.lastPathComponent + "/", relativeTo: base)
                while let u = en?.nextObject() as? URL {
                    let rel = String(u.path.dropFirst(base.path.count + 1))
                    try a.addEntry(with: rel, relativeTo: base, compressionMethod: .deflate)
                }
            } else {
                try a.addEntry(with: item.lastPathComponent, relativeTo: base, compressionMethod: .deflate)
            }
        }
    }

    /// Extracts into `directory`, rejecting entries that would escape it ("zip slip").
    static func unzip(_ archive: URL, to directory: URL) throws -> [URL] {
        let a: Archive
        do { a = try Archive(url: archive, accessMode: .read) } catch { throw AppError.unsupported(L("Not a valid ZIP archive")) }
        AppPaths.ensure(directory)
        var out: [URL] = []
        let root = directory.standardizedFileURL.path
        for entry in a {
            let dest = directory.appendingPathComponent(entry.path).standardizedFileURL
            guard dest.path.hasPrefix(root + "/") || dest.path == root else { throw AppError.io("unsafe path in archive: \(entry.path)") }
            if entry.type == .directory {
                AppPaths.ensure(dest)
                continue
            }
            AppPaths.ensure(dest.deletingLastPathComponent())
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            _ = try a.extract(entry, to: dest)
            out.append(dest)
        }
        return out
    }

    static func isSupportedArchive(_ name: String) -> Bool {
        ["zip", "ipa"].contains((name as NSString).pathExtension.lowercased())
    }
}

// MARK: - Sync between accounts

/// One-way mirror: copies files that are missing or changed (by size, and MD5 when both sides
/// report one) from the source folder into the target folder, recursively. Never deletes.
@MainActor
final class SyncEngine: ObservableObject {
    let store: DataStore
    let accounts: AccountManager
    @Published private(set) var running: Set<UUID> = []

    init(store: DataStore, accounts: AccountManager) {
        self.store = store
        self.accounts = accounts
    }

    struct Result: Equatable { var copied = 0; var unchanged = 0; var failed: [String] = [] }

    static func needsCopy(source: RemoteItem, target: RemoteItem?) -> Bool {
        guard let target else { return true }
        if let a = source.md5, let b = target.md5, a.count == 32, b.count == 32 { return a.lowercased() != b.lowercased() }
        return source.size != target.size
    }

    func pairs() -> [SyncPair] {
        (try? store.context.fetch(FetchDescriptor<SyncPair>())) ?? []
    }

    func run(_ pair: SyncPair) async -> Result {
        running.insert(pair.id)
        defer { running.remove(pair.id) }
        var result = Result()
        do {
            let src = try accounts.provider(for: pair.sourceAccountID)
            let dst = try accounts.provider(for: pair.targetAccountID)
            try await mirror(src: src, srcFolder: RemoteFolder(id: pair.sourceFolderID, name: pair.sourceFolderName, path: pair.sourceFolderID.hasPrefix("/") ? pair.sourceFolderID : nil),
                             dst: dst, dstFolder: RemoteFolder(id: pair.targetFolderID, name: pair.targetFolderName, path: pair.targetFolderID.hasPrefix("/") ? pair.targetFolderID : nil),
                             sameAccount: pair.sourceAccountID == pair.targetAccountID, result: &result)
        } catch {
            result.failed.append(error.localizedDescription)
        }
        pair.lastRun = Date()
        pair.lastResult = LF("%d copied, %d unchanged, %d failed", result.copied, result.unchanged, result.failed.count)
        store.save()
        store.logActivity(.sync, LF("Sync %@ → %@", pair.sourceFolderName, pair.targetFolderName), detail: pair.lastResult,
                          account: pair.targetAccountID, success: result.failed.isEmpty)
        return result
    }

    private func mirror(src: CloudProvider, srcFolder: RemoteFolder, dst: CloudProvider, dstFolder: RemoteFolder, sameAccount: Bool, result: inout Result) async throws {
        let sourceItems = try await src.list(folder: srcFolder)
        let targetItems = try await dst.list(folder: dstFolder)
        let byName = Dictionary(targetItems.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for item in sourceItems {
            try Task.checkCancellation()
            if item.isFolder {
                let sub: RemoteFolder
                if let existing = byName[item.name], existing.isFolder {
                    sub = RemoteFolder(id: existing.id, name: existing.name, path: existing.path)
                } else {
                    let made = try await dst.createFolder(name: item.name, in: dstFolder)
                    sub = RemoteFolder(id: made.id, name: made.name, path: made.path)
                }
                try await mirror(src: src, srcFolder: RemoteFolder(id: item.id, name: item.name, path: item.path), dst: dst, dstFolder: sub, sameAccount: sameAccount, result: &result)
                continue
            }
            let existing = byName[item.name]
            guard Self.needsCopy(source: item, target: existing) else { result.unchanged += 1; continue }
            do {
                if let existing { try await dst.delete(existing, permanently: false) }
                if sameAccount { _ = try await src.copy(item, to: dstFolder) }
                else { _ = try await TransferManager.crossAccountCopy(item, from: src, to: dst, folder: dstFolder, progress: nil) }
                result.copied += 1
            } catch {
                result.failed.append("\(item.name): \(error.localizedDescription)")
            }
        }
    }
}
