import Foundation
import Security
@testable import iCloudIPA

/// In-memory CloudProvider used to exercise engines end-to-end without network access.
/// It behaves like Google Drive (ids, MD5 checksums, trash) so the verification paths run for real.
final class MockProvider: CloudProvider {
    let kind: ProviderKind
    let accountID: UUID
    var capabilities: ProviderCapabilities = [.serverSideCopy, .trash, .checksums, .search]
    var maxConcurrentTransfers: Int { 2 }
    var rootFolder: RemoteFolder { RemoteFolder(id: "root", name: "Root", path: "/") }

    struct Node { var item: RemoteItem; var data: Data? }
    private(set) var nodes: [String: Node] = [:]
    var corruptUploads = false
    var failNextUploads = 0
    private(set) var uploadCalls = 0
    private let lock = NSLock()

    init(accountID: UUID, kind: ProviderKind = .googleDrive) {
        self.accountID = accountID
        self.kind = kind
    }

    private func put(_ item: RemoteItem, data: Data?) {
        lock.lock(); nodes[item.id] = Node(item: item, data: data); lock.unlock()
    }

    func accountInfo() async throws -> ProviderAccountInfo { ProviderAccountInfo(displayName: "Mock", email: "mock@example.com", userID: accountID.uuidString) }
    func quota() async throws -> StorageQuota {
        StorageQuota(total: 10 * 1024 * 1024 * 1024, used: nodes.values.reduce(0) { $0 + $1.item.size }, trash: 0)
    }

    func list(folder: RemoteFolder) async throws -> [RemoteItem] {
        lock.lock(); defer { lock.unlock() }
        return nodes.values.map(\.item).filter { $0.parentID == folder.id && !$0.trashed }.sorted { $0.name < $1.name }
    }

    func item(id: String) async throws -> RemoteItem {
        guard let n = nodes[id] else { throw AppError.notFound(id) }
        return n.item
    }

    func search(_ query: String) async throws -> [RemoteItem] {
        nodes.values.map(\.item).filter { $0.name.localizedCaseInsensitiveContains(query) && !$0.trashed }
    }

    func createFolder(name: String, in parent: RemoteFolder) async throws -> RemoteItem {
        let item = RemoteItem(id: UUID().uuidString, name: name, isFolder: true, size: 0, parentID: parent.id, path: nil,
                              mimeType: GoogleDriveProvider.folderMime, modifiedAt: Date(), createdAt: Date())
        put(item, data: nil)
        return item
    }

    func rename(_ item: RemoteItem, to newName: String) async throws -> RemoteItem {
        guard var n = nodes[item.id] else { throw AppError.notFound(item.id) }
        n.item.name = newName
        put(n.item, data: n.data)
        return n.item
    }

    func move(_ item: RemoteItem, to parent: RemoteFolder) async throws -> RemoteItem {
        guard var n = nodes[item.id] else { throw AppError.notFound(item.id) }
        n.item.parentID = parent.id
        put(n.item, data: n.data)
        return n.item
    }

    func copy(_ item: RemoteItem, to parent: RemoteFolder) async throws -> RemoteItem {
        guard let n = nodes[item.id] else { throw AppError.notFound(item.id) }
        var c = n.item
        c.id = UUID().uuidString
        c.parentID = parent.id
        put(c, data: n.data)
        return c
    }

    func delete(_ item: RemoteItem, permanently: Bool) async throws {
        lock.lock(); defer { lock.unlock() }
        if permanently { nodes[item.id] = nil } else { nodes[item.id]?.item.trashed = true }
    }

    func upload(file: URL, name: String, to parent: RemoteFolder, record: TransferHandle?, progress: ProgressHandler?) async throws -> RemoteItem {
        uploadCalls += 1
        if failNextUploads > 0 { failNextUploads -= 1; throw AppError.network("simulated outage") }
        var data = try Data(contentsOf: file)
        let md5 = FileHasher.md5Hex(of: data)
        if corruptUploads { data.append(0x00) }
        let item = RemoteItem(id: UUID().uuidString, name: name, isFolder: false, size: Int64(data.count), parentID: parent.id, path: nil,
                              mimeType: MIME.type(forFilename: name), md5: corruptUploads ? FileHasher.md5Hex(of: data) : md5,
                              modifiedAt: Date(), createdAt: Date())
        put(item, data: data)
        progress?(item.size, item.size)
        return item
    }

    func download(_ item: RemoteItem, to destination: URL, progress: ProgressHandler?) async throws {
        guard let d = nodes[item.id]?.data else { throw AppError.notFound(item.id) }
        try? FileManager.default.removeItem(at: destination)
        try d.write(to: destination)
    }

    func trashed() async throws -> [RemoteItem] { nodes.values.map(\.item).filter(\.trashed) }
    func restoreFromTrash(_ item: RemoteItem) async throws { nodes[item.id]?.item.trashed = false }
    func emptyTrash() async throws { nodes = nodes.filter { !$0.value.item.trashed } }
    func revisions(of item: RemoteItem) async throws -> [RemoteRevision] { [] }
    func downloadRevision(_ revision: RemoteRevision, of item: RemoteItem, to destination: URL) async throws { throw AppError.unsupported("mock") }
    func listAll(progress: ((Int) -> Void)?) async throws -> [RemoteItem] { nodes.values.map(\.item).filter { !$0.trashed } }
    func signOut() async {}

    func data(for id: String) -> Data? { nodes[id]?.data }
}

enum TestSupport {
    /// The iOS simulator keychain needs a signed test host; skip keychain-dependent tests otherwise.
    static var keychainAvailable: Bool {
        let k = KeychainStore(service: "icloudipa.tests.probe")
        do { try k.set(Data([1]), for: "probe"); k.remove("probe"); return true } catch { return false }
    }

    static func tempFile(_ bytes: Data, name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    static func randomData(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
