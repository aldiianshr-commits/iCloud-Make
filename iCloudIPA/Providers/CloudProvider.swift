import Foundation
import SwiftData

/// A file or folder in a cloud account. `id` is the provider's stable identifier
/// (Google Drive file ID, or the absolute path for TeraBox).
struct RemoteItem: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var isFolder: Bool
    var size: Int64
    var parentID: String?
    var path: String?
    var mimeType: String?
    var md5: String?
    var modifiedAt: Date?
    var createdAt: Date?
    var trashed: Bool = false
    var thumbnailURL: URL?
    /// Provider specific numeric id (TeraBox fs_id).
    var numericID: Int64?

    var category: FileCategory { FileCategory.from(filename: name, mimeType: mimeType, isFolder: isFolder) }
}

/// Folder reference used for navigation and as an upload target.
struct RemoteFolder: Hashable, Codable, Identifiable {
    var id: String
    var name: String
    var path: String?
}

struct StorageQuota: Equatable, Codable {
    /// nil when the provider reports unlimited / unknown.
    var total: Int64?
    var used: Int64
    var trash: Int64?
    var free: Int64? { total.map { max(0, $0 - used) } }
}

struct ProviderAccountInfo: Equatable {
    var displayName: String
    var email: String
    var userID: String?
    var avatarURL: URL?
}

struct RemoteRevision: Identifiable, Hashable {
    var id: String
    var modifiedAt: Date?
    var size: Int64?
    var md5: String?
    var keepForever: Bool
}

struct ProviderCapabilities: OptionSet {
    let rawValue: Int
    static let resumableUpload = ProviderCapabilities(rawValue: 1 << 0)
    static let serverSideCopy = ProviderCapabilities(rawValue: 1 << 1)
    static let trash = ProviderCapabilities(rawValue: 1 << 2)
    static let revisions = ProviderCapabilities(rawValue: 1 << 3)
    static let checksums = ProviderCapabilities(rawValue: 1 << 4)
    static let search = ProviderCapabilities(rawValue: 1 << 5)
    static let changeFeed = ProviderCapabilities(rawValue: 1 << 6)
    static let backgroundTransfer = ProviderCapabilities(rawValue: 1 << 7)
}

typealias ProgressHandler = @Sendable (_ completed: Int64, _ total: Int64) -> Void

/// The adapter contract every storage provider implements. UI and engines only talk to this.
protocol CloudProvider: AnyObject {
    var kind: ProviderKind { get }
    var accountID: UUID { get }
    var capabilities: ProviderCapabilities { get }
    /// Max concurrent transfers this provider tolerates.
    var maxConcurrentTransfers: Int { get }
    var rootFolder: RemoteFolder { get }

    func accountInfo() async throws -> ProviderAccountInfo
    func quota() async throws -> StorageQuota
    func list(folder: RemoteFolder) async throws -> [RemoteItem]
    func item(id: String) async throws -> RemoteItem
    func search(_ query: String) async throws -> [RemoteItem]
    func createFolder(name: String, in parent: RemoteFolder) async throws -> RemoteItem
    func rename(_ item: RemoteItem, to newName: String) async throws -> RemoteItem
    func move(_ item: RemoteItem, to parent: RemoteFolder) async throws -> RemoteItem
    func copy(_ item: RemoteItem, to parent: RemoteFolder) async throws -> RemoteItem
    func delete(_ item: RemoteItem, permanently: Bool) async throws
    func upload(file: URL, name: String, to parent: RemoteFolder, record: TransferHandle?, progress: ProgressHandler?) async throws -> RemoteItem
    func download(_ item: RemoteItem, to destination: URL, progress: ProgressHandler?) async throws
    func trashed() async throws -> [RemoteItem]
    func restoreFromTrash(_ item: RemoteItem) async throws
    func emptyTrash() async throws
    func revisions(of item: RemoteItem) async throws -> [RemoteRevision]
    func downloadRevision(_ revision: RemoteRevision, of item: RemoteItem, to destination: URL) async throws
    /// Lists every file in the account (used by the storage index). Implementations page internally.
    func listAll(progress: ((Int) -> Void)?) async throws -> [RemoteItem]
    /// Revokes tokens / logs out the web session on the provider side where possible.
    func signOut() async
}

extension CloudProvider {
    /// Returns (creating as needed) the folder at `components` below the root.
    func ensureFolder(path components: [String]) async throws -> RemoteFolder {
        var current = rootFolder
        for name in components where !name.isEmpty {
            let children = try await list(folder: current)
            if let existing = children.first(where: { $0.isFolder && $0.name == name }) {
                current = RemoteFolder(id: existing.id, name: existing.name, path: existing.path)
            } else {
                let made = try await createFolder(name: name, in: current)
                current = RemoteFolder(id: made.id, name: made.name, path: made.path)
            }
        }
        return current
    }

    /// Recursively lists a folder tree (files and folders), depth-first.
    func listRecursive(folder: RemoteFolder, maxItems: Int = 100_000) async throws -> [RemoteItem] {
        var out: [RemoteItem] = []
        var stack = [folder]
        while let f = stack.popLast() {
            let children = try await list(folder: f)
            out.append(contentsOf: children)
            if out.count >= maxItems { break }
            for c in children where c.isFolder { stack.append(RemoteFolder(id: c.id, name: c.name, path: c.path)) }
        }
        return out
    }
}

/// Lets a provider persist resumable-upload state into the TransferRecord while it works.
@MainActor
final class TransferHandle {
    let recordID: UUID
    private let store: DataStore

    init(recordID: UUID, store: DataStore) {
        self.recordID = recordID
        self.store = store
    }

    private var record: TransferRecord? {
        var d = FetchDescriptorFactory.transfer(recordID)
        d.fetchLimit = 1
        return try? store.context.fetch(d).first
    }

    func currentResumeURL() -> String? { record?.resumeURL }

    func setResumeURL(_ url: String?) {
        record?.resumeURL = url
        store.save()
    }
}

enum FetchDescriptorFactory {
    static func transfer(_ id: UUID) -> FetchDescriptor<TransferRecord> {
        FetchDescriptor<TransferRecord>(predicate: #Predicate { $0.id == id })
    }
}
