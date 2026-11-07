import Foundation
import SwiftData

/// Owns the SwiftData container. SQLite (WAL) underneath keeps the store consistent if the
/// app is killed; every mutation path calls `save()` explicitly instead of relying on autosave.
@MainActor
final class DataStore {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(Schema_V1.models)
        if inMemory {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        }
        let dir = AppPaths.applicationSupport.appendingPathComponent("Database", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // iOS Data Protection: the store is encrypted at rest by the OS. "Until first unlock" keeps it
        // readable for background backups after the device has been unlocked once since boot.
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
        let url = dir.appendingPathComponent("iCloudIPA.store")
        var exclude = URLResourceValues()
        exclude.isExcludedFromBackup = false
        let config = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, configurations: config)
    }

    init(inMemory: Bool = false) {
        do {
            container = try Self.makeContainer(inMemory: inMemory)
        } catch {
            Log.app.error("Persistent store failed, falling back to in-memory: \(error.localizedDescription, privacy: .public)")
            container = try! Self.makeContainer(inMemory: true)
        }
        container.mainContext.autosaveEnabled = true
    }

    var databaseURL: URL? { container.configurations.first?.url }

    func save() {
        do { try context.save() } catch { Log.app.error("save failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Accounts

    func accounts() -> [CloudAccount] {
        (try? context.fetch(FetchDescriptor<CloudAccount>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]))) ?? []
    }

    func account(_ id: UUID?) -> CloudAccount? {
        guard let id else { return nil }
        var d = FetchDescriptor<CloudAccount>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    // MARK: Activity

    func logActivity(_ kind: ActivityKind, _ title: String, detail: String? = nil, account: UUID? = nil, success: Bool = true) {
        context.insert(ActivityItem(kind: kind, title: title, detail: detail, accountID: account, success: success))
        if let account, let acc = self.account(account) { acc.lastActivity = Date() }
        save()
        trimActivity()
    }

    private func trimActivity(keep: Int = 1000) {
        var d = FetchDescriptor<ActivityItem>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        d.fetchOffset = keep
        if let old = try? context.fetch(d), !old.isEmpty {
            old.forEach { context.delete($0) }
            save()
        }
    }

    func recentActivity(limit: Int = 20) -> [ActivityItem] {
        var d = FetchDescriptor<ActivityItem>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        d.fetchLimit = limit
        return (try? context.fetch(d)) ?? []
    }

    // MARK: Index

    func indexRecord(account: UUID, remoteID: String) -> RemoteFileRecord? {
        let key = "\(account.uuidString)|\(remoteID)"
        var d = FetchDescriptor<RemoteFileRecord>(predicate: #Predicate { $0.key == key })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func upsertIndex(account: UUID, items: [RemoteItem]) {
        for item in items {
            if let rec = indexRecord(account: account, remoteID: item.id) {
                rec.update(from: item)
            } else {
                context.insert(RemoteFileRecord(accountID: account, item: item))
            }
        }
        save()
    }

    func removeFromIndex(account: UUID, remoteID: String) {
        if let rec = indexRecord(account: account, remoteID: remoteID) {
            context.delete(rec)
            save()
        }
    }

    func indexRecords(account: UUID? = nil) -> [RemoteFileRecord] {
        let d: FetchDescriptor<RemoteFileRecord>
        if let account {
            d = FetchDescriptor(predicate: #Predicate { $0.accountID == account && $0.trashed == false })
        } else {
            d = FetchDescriptor(predicate: #Predicate { $0.trashed == false })
        }
        return (try? context.fetch(d)) ?? []
    }

    func clearIndex(account: UUID) {
        try? context.delete(model: RemoteFileRecord.self, where: #Predicate { $0.accountID == account })
        save()
    }

    // MARK: Protected folders

    func isProtected(account: UUID, remoteID: String) -> Bool {
        let key = "\(account.uuidString)|\(remoteID)"
        var d = FetchDescriptor<ProtectedFolder>(predicate: #Predicate { $0.key == key })
        d.fetchLimit = 1
        return ((try? context.fetchCount(d)) ?? 0) > 0
    }

    func setProtected(_ on: Bool, account: UUID, remoteID: String, name: String) {
        let key = "\(account.uuidString)|\(remoteID)"
        if on {
            if !isProtected(account: account, remoteID: remoteID) {
                context.insert(ProtectedFolder(accountID: account, remoteID: remoteID, name: name))
            }
        } else {
            try? context.delete(model: ProtectedFolder.self, where: #Predicate { $0.key == key })
        }
        save()
    }

    // MARK: Background jobs

    func jobRecord(_ identifier: String) -> BackgroundJobRecord {
        var d = FetchDescriptor<BackgroundJobRecord>(predicate: #Predicate { $0.identifier == identifier })
        d.fetchLimit = 1
        if let r = try? context.fetch(d).first { return r }
        let r = BackgroundJobRecord(identifier: identifier)
        context.insert(r)
        save()
        return r
    }

    // MARK: Account removal

    /// Deletes every local record that belongs to an account (index, transfers, protected folders, sync pairs).
    func purgeAccountData(_ id: UUID) {
        try? context.delete(model: RemoteFileRecord.self, where: #Predicate { $0.accountID == id })
        try? context.delete(model: ProtectedFolder.self, where: #Predicate { $0.accountID == id })
        try? context.delete(model: SyncPair.self, where: #Predicate { $0.sourceAccountID == id || $0.targetAccountID == id })
        let transfers = (try? context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate { $0.accountID == id }))) ?? []
        for t in transfers where !t.status.isFinished { t.status = .cancelled }
        save()
    }
}
