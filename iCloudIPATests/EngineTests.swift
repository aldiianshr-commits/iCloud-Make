import XCTest
import SwiftData
import ZIPFoundation
@testable import iCloudIPA

private func item(_ id: String, fp: String) -> BackupSourceItem {
    BackupSourceItem(category: .files, sourceID: id, name: id, fingerprint: fp, size: 1, creationDate: nil, subfolder: []) {
        URL(fileURLWithPath: "/dev/null")
    }
}

final class BackupPlanningTests: XCTestCase {
    let account = UUID()

    func testIncrementalSkipsUnchangedAndDetectsChangesAndDeletions() {
        let existing: [String: EntryState] = [
            "a": EntryState(fingerprint: "1", accountID: account, deleted: false),
            "b": EntryState(fingerprint: "1", accountID: account, deleted: false),
            "gone": EntryState(fingerprint: "1", accountID: account, deleted: false),
            "alreadyGone": EntryState(fingerprint: "1", accountID: account, deleted: true),
        ]
        let plan = BackupEngine.plan(items: [item("a", fp: "1"), item("b", fp: "2"), item("new", fp: "1")],
                                     existing: existing, kind: .incremental, accountID: account)
        XCTAssertEqual(plan.skipped, 1)
        XCTAssertEqual(plan.toUpload.map(\.sourceID), ["b", "new"])
        XCTAssertEqual(plan.deletedSourceIDs, ["gone"])
    }

    func testFullBackupUploadsEverything() {
        let existing = ["a": EntryState(fingerprint: "1", accountID: account, deleted: false)]
        let plan = BackupEngine.plan(items: [item("a", fp: "1")], existing: existing, kind: .full, accountID: account)
        XCTAssertEqual(plan.toUpload.count, 1)
        XCTAssertEqual(plan.skipped, 0)
    }

    func testChangingDestinationAccountReuploads() {
        let existing = ["a": EntryState(fingerprint: "1", accountID: UUID(), deleted: false)]
        let plan = BackupEngine.plan(items: [item("a", fp: "1")], existing: existing, kind: .incremental, accountID: account)
        XCTAssertEqual(plan.toUpload.count, 1)
    }

    func testSnapshotNames() {
        let d = Date(timeIntervalSince1970: 0)
        let name = BackupEngine.snapshotName("contacts.vcf", date: d)
        XCTAssertTrue(name.hasPrefix("contacts_19"))
        XCTAssertTrue(name.hasSuffix(".vcf"))
    }

    func testScheduleDueDates() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Makassar")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 15))!
        XCTAssertNil(BackupScheduler.nextDueDate(last: nil, schedule: .off, hour: 2, now: now, calendar: cal))
        XCTAssertEqual(BackupScheduler.nextDueDate(last: nil, schedule: .daily, hour: 2, now: now, calendar: cal), now, "never backed up → due now")
        let last = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 1))!
        let next = BackupScheduler.nextDueDate(last: last, schedule: .daily, hour: 2, now: now, calendar: cal)!
        XCTAssertEqual(cal.component(.day, from: next), 8)
        XCTAssertEqual(cal.component(.hour, from: next), 2)
        XCTAssertFalse(BackupScheduler.isOverdue(last: last, schedule: .daily, hour: 2, now: now))
        let old = cal.date(byAdding: .day, value: -9, to: now)!
        XCTAssertTrue(BackupScheduler.isOverdue(last: old, schedule: .weekly, hour: 2, now: now))
    }
}

final class ICSWriterTests: XCTestCase {
    func testEventsAreEscapedAndFolded() {
        let e = CalendarEventDTO(identifier: "E1", title: "Meet; team, now", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600),
                                 allDay: false, location: nil, notes: String(repeating: "long note ", count: 20), url: nil, calendarTitle: "Work", timeZone: nil, recurrence: nil)
        let ics = ICSWriter.events([e], stamp: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(ics.hasPrefix("BEGIN:VCALENDAR\r\n"))
        XCTAssertTrue(ics.contains("SUMMARY:Meet\\; team\\, now"))
        XCTAssertTrue(ics.contains("DTSTART:19700101T000000Z"))
        XCTAssertTrue(ics.contains("\r\n "), "long DESCRIPTION is folded")
        for line in ics.components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.utf8.count, 76) }
        XCTAssertTrue(ics.hasSuffix("END:VCALENDAR\r\n"))
    }

    func testTodos() {
        let r = ReminderDTO(identifier: "R1", title: "Buy milk", notes: nil, completed: true, completionDate: Date(timeIntervalSince1970: 0),
                            dueDate: nil, priority: 1, listTitle: "Home")
        let ics = ICSWriter.todos([r])
        XCTAssertTrue(ics.contains("BEGIN:VTODO"))
        XCTAssertTrue(ics.contains("STATUS:COMPLETED"))
        XCTAssertTrue(ics.contains("PRIORITY:1"))
    }
}

final class StorageAnalyzerTests: XCTestCase {
    let a = UUID(), b = UUID()

    func ref(_ acc: UUID, _ name: String, size: Int64, md5: String?) -> RemoteItemRef {
        RemoteItemRef(accountID: acc, item: RemoteItem(id: UUID().uuidString, name: name, isFolder: false, size: size, md5: md5))
    }

    func testDuplicatesAcrossAccounts() {
        let md5 = String(repeating: "a", count: 32)
        let refs = [ref(a, "x.jpg", size: 100, md5: md5), ref(b, "copy.jpg", size: 100, md5: md5), ref(a, "y.jpg", size: 100, md5: String(repeating: "b", count: 32)),
                    ref(a, "n.bin", size: 5, md5: nil), ref(b, "N.bin", size: 5, md5: nil)]
        let groups = StorageAnalyzer.duplicates(refs)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].reclaimable, 100)
        XCTAssertTrue(groups.contains { $0.key.hasPrefix("name:") })
    }

    func testLargestAndCategories() {
        let refs = [ref(a, "big.mov", size: 200 * 1024 * 1024, md5: nil), ref(a, "small.txt", size: 10, md5: nil), ref(a, "mid.pdf", size: 60 * 1024 * 1024, md5: nil)]
        XCTAssertEqual(StorageAnalyzer.largest(refs).map(\.item.name), ["big.mov", "mid.pdf"])
        let usage = StorageAnalyzer.byCategory(refs)
        XCTAssertEqual(usage.first?.category, .video)
        let s = StorageAnalyzer.suggestions(duplicates: [], large: StorageAnalyzer.largest(refs), trashBytes: 5, accounts: [("full", 0.95), ("empty", 0.1)])
        XCTAssertEqual(Set(s.map(\.kind)), [.largeFiles, .trash, .rebalance])
    }

    func testSyncNeedsCopy() {
        let src = RemoteItem(id: "1", name: "a", isFolder: false, size: 10, md5: String(repeating: "c", count: 32))
        XCTAssertTrue(SyncEngine.needsCopy(source: src, target: nil))
        XCTAssertFalse(SyncEngine.needsCopy(source: src, target: src))
        var other = src
        other.md5 = String(repeating: "d", count: 32)
        XCTAssertTrue(SyncEngine.needsCopy(source: src, target: other))
        var noHash = src
        noHash.md5 = nil
        XCTAssertFalse(SyncEngine.needsCopy(source: noHash, target: src), "falls back to size")
    }

    func testAutomaticAccountRanking() async {
        await MainActor.run {
            let primaryFull = CloudAccount(provider: .googleDrive, displayName: "P", email: "p", externalUserID: "1")
            primaryFull.role = .primary
            primaryFull.quotaTotal = 100; primaryFull.quotaUsed = 99
            let backup = CloudAccount(provider: .teraBox, displayName: "B", email: "b", externalUserID: "2")
            backup.role = .backup
            backup.quotaTotal = 1000; backup.quotaUsed = 0
            let normal = CloudAccount(provider: .googleDrive, displayName: "N", email: "n", externalUserID: "3")
            normal.quotaTotal = 10_000; normal.quotaUsed = 0
            let ranked = AccountManager.rankForUpload([normal, backup, primaryFull])
            XCTAssertEqual(ranked.map(\.displayName), ["P", "B", "N"])
        }
    }
}

final class ZipServiceTests: XCTestCase {
    func testZipAndUnzipRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: folder.appendingPathComponent("1.txt"))
        try Data("two".utf8).write(to: folder.appendingPathComponent("Sub/2.txt"))
        let archive = root.appendingPathComponent("out.zip")
        try ZipService.zip([folder], into: archive)
        let out = root.appendingPathComponent("extracted")
        let files = try ZipService.unzip(archive, to: out)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Docs/Sub/2.txt")), "two")
    }

    func testZipSlipIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("evil.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let payload = Data("x".utf8)
        try archive.addEntry(with: "../../evil.txt", type: .file, uncompressedSize: Int64(payload.count), provider: { pos, size in
            payload.subdata(in: Int(pos)..<Int(pos) + size)
        })
        XCTAssertThrowsError(try ZipService.unzip(archiveURL, to: root.appendingPathComponent("out")))
    }

    func testInvalidArchive() throws {
        let url = try TestSupport.tempFile(Data("not a zip".utf8), name: "bad.zip")
        XCTAssertThrowsError(try ZipService.unzip(url, to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
}

/// End-to-end flows over SwiftData (in memory) + MockProvider: account management, transfer queue,
/// integrity checks, cross-account copy, backup and restore catalogue.
@MainActor
final class IntegrationTests: XCTestCase {
    var env: AppEnvironment!
    var accountA: CloudAccount!
    var accountB: CloudAccount!
    var providerA: MockProvider!
    var providerB: MockProvider!

    override func setUp() async throws {
        env = AppEnvironment(inMemory: true, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        accountA = CloudAccount(provider: .googleDrive, displayName: "A", email: "a@example.com", externalUserID: "a")
        accountB = CloudAccount(provider: .googleDrive, displayName: "B", email: "b@example.com", externalUserID: "b")
        accountA.role = .primary
        accountA.isActive = true
        for acc in [accountA!, accountB!] { env.store.context.insert(acc) }
        env.store.save()
        providerA = MockProvider(accountID: accountA.id)
        providerB = MockProvider(accountID: accountB.id)
        env.accounts.register(providerA)
        env.accounts.register(providerB)
        await env.accounts.refreshAll()
    }

    func testRefreshStoresQuotaAndStatus() {
        XCTAssertEqual(accountA.status, .connected)
        XCTAssertEqual(accountA.quotaTotal, 10 * 1024 * 1024 * 1024)
        XCTAssertNotNil(accountA.quotaUpdatedAt)
    }

    func testUploadVerifiesChecksumAndDetectsCorruption() async throws {
        let file = try TestSupport.tempFile(TestSupport.randomData(100_000), name: "photo.jpg")
        let ok = try await TransferManager.upload(localFile: file, name: "photo.jpg", provider: providerA, folder: providerA.rootFolder, encrypt: false, handle: nil, progress: nil)
        XCTAssertTrue(ok.verified)
        XCTAssertEqual(providerA.data(for: ok.item.id), try Data(contentsOf: file))

        providerA.corruptUploads = true
        do {
            _ = try await TransferManager.upload(localFile: file, name: "bad.jpg", provider: providerA, folder: providerA.rootFolder, encrypt: false, handle: nil, progress: nil)
            XCTFail("corrupted upload must fail verification")
        } catch let e as AppError {
            if case .integrityCheckFailed = e {} else { XCTFail("unexpected \(e)") }
        }
    }

    func testEncryptedUploadDownloadRoundTrip() async throws {
        try XCTSkipUnless(TestSupport.keychainAvailable, "Keychain not available for this test host")
        let original = TestSupport.randomData(3 * 1024 * 1024 + 7)
        let file = try TestSupport.tempFile(original, name: "secret.pdf")
        let up = try await TransferManager.upload(localFile: file, name: "secret.pdf", provider: providerA, folder: providerA.rootFolder, encrypt: true, handle: nil, progress: nil)
        XCTAssertEqual(up.item.name, "secret.pdf.icipaenc")
        XCTAssertNotEqual(providerA.data(for: up.item.id), original, "cloud never sees plaintext")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = try await TransferManager.download(up.item, provider: providerA, to: dir, progress: nil)
        XCTAssertEqual(local.lastPathComponent, "secret.pdf")
        XCTAssertEqual(try Data(contentsOf: local), original)
    }

    func testQueueUploadRetriesTransientFailuresAndIndexes() async throws {
        providerA.failNextUploads = 0
        let file = try TestSupport.tempFile(Data("hello".utf8), name: "hello.txt")
        let record = try env.transfers.enqueueUpload(file: file, account: accountA.id, folder: providerA.rootFolder, encrypt: false)
        try await waitUntil { record.status.isFinished }
        XCTAssertEqual(record.status, .completed)
        XCTAssertTrue(record.verified)
        XCTAssertNotNil(env.store.indexRecord(account: accountA.id, remoteID: record.remoteID ?? ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.localPath ?? "/nonexistent"), "staged copy cleaned up")
    }

    func testFailedTransferCanBeRetried() async throws {
        let file = try TestSupport.tempFile(Data("x".utf8), name: "x.txt")
        let hello = try await providerA.createFolder(name: "Target", in: providerA.rootFolder)
        providerA.corruptUploads = true
        let record = try env.transfers.enqueueUpload(file: file, account: accountA.id, folder: RemoteFolder(item: hello), encrypt: false)
        try await waitUntil { record.status.isFinished }
        XCTAssertEqual(record.status, .failed)
        XCTAssertNotNil(record.errorMessage)
        providerA.corruptUploads = false
        env.transfers.resume(record)
        try await waitUntil { record.status == .completed }
    }

    func testCrossAccountCopyAndMove() async throws {
        let folder = try await providerA.createFolder(name: "Album", in: providerA.rootFolder)
        let f = try TestSupport.tempFile(Data("pic".utf8), name: "p.jpg")
        let uploaded = try await providerA.upload(file: f, name: "p.jpg", to: RemoteFolder(item: folder), record: nil, progress: nil)
        let copied = try await TransferManager.crossAccountCopy(folder, from: providerA, to: providerB, folder: providerB.rootFolder, progress: nil)
        XCTAssertTrue(copied.isFolder)
        let inB = try await providerB.list(folder: RemoteFolder(item: copied))
        XCTAssertEqual(inB.map(\.name), ["p.jpg"])
        XCTAssertEqual(providerB.data(for: inB[0].id), providerA.data(for: uploaded.id))

        let record = env.transfers.enqueueTransfer(uploaded, from: accountA.id, to: accountB.id, folder: providerB.rootFolder, move: true)
        try await waitUntil { record.status.isFinished }
        XCTAssertEqual(record.status, .completed)
        let trashedInA = try await providerA.trashed()
        XCTAssertTrue(trashedInA.contains { $0.id == uploaded.id }, "move = copy + trash at source")
    }

    func testAutomaticAccountSelectionByFreeSpace() throws {
        accountA.quotaTotal = 1000
        accountA.quotaUsed = 999
        let chosen = try env.accounts.pickAccount(forBytes: 10)
        XCTAssertEqual(chosen.id, accountB.id, "primary is full → next account")
        accountB.quotaTotal = 1000
        accountB.quotaUsed = 1000
        XCTAssertThrowsError(try env.accounts.pickAccount(forBytes: 10))
    }

    func testAppDataBackupIsIncrementalAndManifestImports() async throws {
        env.settings.backupCategories = [.appData]
        env.settings.backupAccountID = accountA.id
        let first = await env.backup.run(kind: .incremental, trigger: .manual)
        XCTAssertEqual(first?.status, .completed, first?.message ?? "")
        XCTAssertEqual(first?.itemsUploaded, 1)
        XCTAssertEqual(first?.verifiedCount, 1)
        XCTAssertNotNil(first?.manifestRemoteID)

        let entries = env.backup.entries(category: .appData)
        XCTAssertEqual(entries.count, 1)

        // Nothing changed except timestamps → skipped.
        let second = await env.backup.run(kind: .incremental, trigger: .manual)
        XCTAssertEqual(second?.itemsSkipped, 1, second?.message ?? "")

        // Simulate a new device: wipe local catalogue and import it from the cloud manifest.
        for e in env.backup.entries() { env.store.context.delete(e) }
        env.store.save()
        let imported = try await env.backup.importLatestManifest(accountID: accountA.id)
        XCTAssertGreaterThanOrEqual(imported, 1)
        XCTAssertEqual(env.backup.entries(category: .appData).first?.remoteID, entries.first?.remoteID)

        let report = try await env.backup.verify(accountID: accountA.id)
        XCTAssertEqual(report.missing, [])
        XCTAssertEqual(report.mismatched, [])
    }

    func testRestoreFileWithIntegrityCheck() async throws {
        env.settings.backupCategories = [.appData]
        env.settings.backupAccountID = accountA.id
        _ = await env.backup.run(kind: .incremental, trigger: .manual)
        let entries = env.backup.entries(category: .appData)
        let report = await env.restore.restore(entries, policy: .keepBoth)
        XCTAssertEqual(report.restored, 1, report.failed.joined())
        let again = await env.restore.restore(entries, policy: .skipDuplicates)
        XCTAssertEqual(again.skippedDuplicates, 1)
    }

    func testRemovingAccountPurgesLocalData() async throws {
        env.store.upsertIndex(account: accountB.id, items: [RemoteItem(id: "z", name: "z", isFolder: false, size: 1)])
        env.store.setProtected(true, account: accountB.id, remoteID: "folder", name: "Private")
        await env.accounts.remove(accountB)
        XCTAssertNil(env.store.account(accountB.id))
        XCTAssertTrue(env.store.indexRecords(account: accountB.id).isEmpty)
        XCTAssertFalse(env.store.isProtected(account: accountB.id, remoteID: "folder"))
    }

    func testIndexerAndAnalyzer() async throws {
        let f = try TestSupport.tempFile(Data("same".utf8), name: "a.txt")
        _ = try await providerA.upload(file: f, name: "a.txt", to: providerA.rootFolder, record: nil, progress: nil)
        _ = try await providerB.upload(file: f, name: "b.txt", to: providerB.rootFolder, record: nil, progress: nil)
        await env.indexer.indexAll(full: true)
        let refs = env.store.indexRecords().map { RemoteItemRef(accountID: $0.accountID, item: $0.asRemoteItem) }
        XCTAssertEqual(StorageAnalyzer.duplicates(refs).count, 1)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
