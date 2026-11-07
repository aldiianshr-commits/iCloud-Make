import Foundation
import Photos
import Contacts
import EventKit
import SwiftData

enum ConflictPolicy: String, CaseIterable, Identifiable {
    case skipDuplicates, keepBoth
    var id: String { rawValue }
    var title: String { self == .skipDuplicates ? L("Skip items that already exist") : L("Keep both copies") }
}

struct RestoreReport: Equatable {
    var restored = 0
    var skippedDuplicates = 0
    var failed: [String] = []
    var locations: Set<String> = []
}

/// Restores backed-up items: photos/videos into the Photos library, contacts/calendar/reminders
/// into their system databases, files into "On My iPhone ▸ iCloud IPA ▸ Restored".
/// Every download is integrity-checked (MD5 for Google Drive, size for TeraBox) and decrypted if needed.
@MainActor
final class RestoreEngine: ObservableObject {
    let store: DataStore
    let accounts: AccountManager
    @Published private(set) var isRunning = false
    @Published private(set) var processed = 0
    @Published private(set) var total = 0
    @Published private(set) var current = ""

    init(store: DataStore, accounts: AccountManager) {
        self.store = store
        self.accounts = accounts
    }

    func restore(_ entries: [BackupEntry], policy: ConflictPolicy) async -> RestoreReport {
        isRunning = true
        processed = 0
        total = entries.count
        defer { isRunning = false; current = "" }
        var report = RestoreReport()
        for entry in entries {
            if Task.isCancelled { break }
            current = entry.name
            do {
                let provider = try accounts.provider(for: entry.accountID)
                let remote = RemoteItem(id: entry.remoteID, name: entry.name + (entry.encrypted ? "." + FileEncryptor.encryptedExtension : ""),
                                        isFolder: false, size: 0, path: entry.remoteID.hasPrefix("/") ? entry.remoteID : nil, md5: nil)
                // Fetch real metadata so size/MD5 verification uses the server's values.
                let meta = (try? await provider.item(id: entry.remoteID)) ?? remote
                if let expected = entry.md5, provider.kind == .googleDrive, let server = meta.md5, server.lowercased() != expected.lowercased() {
                    throw AppError.integrityCheckFailed(L("cloud copy differs from the backed-up file"))
                }
                let staging = AppPaths.ensure(AppPaths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true))
                defer { try? FileManager.default.removeItem(at: staging) }
                var named = meta
                named.name = entry.name + (entry.encrypted ? "." + FileEncryptor.encryptedExtension : "")
                let file = try await TransferManager.download(named, provider: provider, to: staging, progress: nil)
                let outcome = try await apply(file, entry: entry, policy: policy)
                switch outcome {
                case .restored(let location): report.restored += 1; report.locations.insert(location)
                case .duplicate: report.skippedDuplicates += 1
                }
            } catch {
                report.failed.append("\(entry.name): \(error.localizedDescription)")
            }
            processed += 1
        }
        store.logActivity(.restore, LF("Restored %d items", report.restored),
                          detail: LF("%d duplicates skipped, %d failed", report.skippedDuplicates, report.failed.count),
                          success: report.failed.isEmpty)
        return report
    }

    enum Outcome { case restored(String), duplicate }

    private func apply(_ file: URL, entry: BackupEntry, policy: ConflictPolicy) async throws -> Outcome {
        switch entry.category {
        case .photos, .videos: return try await restoreMedia(file, entry: entry, policy: policy)
        case .contacts: return try await restoreContacts(file, policy: policy)
        case .calendar:
            guard entry.name.hasSuffix(".json") else { return try restoreFile(file, entry: entry, policy: policy) }
            return try await restoreCalendar(file, policy: policy)
        case .reminders:
            guard entry.name.hasSuffix(".json") else { return try restoreFile(file, entry: entry, policy: policy) }
            return try await restoreReminders(file, policy: policy)
        case .documents, .audio, .files, .appData:
            return try restoreFile(file, entry: entry, policy: policy)
        }
    }

    // MARK: Photos

    private func restoreMedia(_ file: URL, entry: BackupEntry, policy: ConflictPolicy) async throws -> Outcome {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw AppError.permissionDenied(L("Photos")) }
        if policy == .skipDuplicates, PHAsset.fetchAssets(withLocalIdentifiers: [entry.sourceID], options: nil).count > 0 {
            return .duplicate
        }
        let type: PHAssetResourceType = entry.category == .videos ? .video : .photo
        let originalName = entry.name.split(separator: "_", maxSplits: 1).last.map(String.init) ?? entry.name
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let opts = PHAssetResourceCreationOptions()
            opts.originalFilename = originalName
            opts.shouldMoveFile = false
            req.addResource(with: type, fileURL: file, options: opts)
            if let d = entry.creationDate { req.creationDate = d }
        }
        return .restored(L("Photos library"))
    }

    // MARK: Contacts

    static func contactKey(_ c: CNContact) -> String {
        let name = [c.givenName, c.familyName, c.organizationName].joined(separator: " ").lowercased().trimmingCharacters(in: .whitespaces)
        let phones = c.phoneNumbers.map { $0.value.stringValue.filter(\.isNumber) }.sorted().joined(separator: ",")
        let emails = c.emailAddresses.map { ($0.value as String).lowercased() }.sorted().joined(separator: ",")
        return "\(name)|\(phones)|\(emails)"
    }

    private func restoreContacts(_ file: URL, policy: ConflictPolicy) async throws -> Outcome {
        let store = CNContactStore()
        guard try await store.requestAccess(for: .contacts) else { throw AppError.permissionDenied(L("Contacts")) }
        let incoming = try CNContactVCardSerialization.contacts(with: Data(contentsOf: file))
        var existingKeys = Set<String>()
        if policy == .skipDuplicates {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
            try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in existingKeys.insert(Self.contactKey(c)) }
        }
        let save = CNSaveRequest()
        var added = 0
        for c in incoming where policy == .keepBoth || !existingKeys.contains(Self.contactKey(c)) {
            guard let m = c.mutableCopy() as? CNMutableContact else { continue }
            save.add(m, toContainerWithIdentifier: nil)
            added += 1
        }
        guard added > 0 else { return .duplicate }
        try store.execute(save)
        return .restored(L("Contacts"))
    }

    // MARK: Calendar / Reminders

    static func eventKey(title: String, start: Date) -> String { "\(title.lowercased())|\(Int(start.timeIntervalSince1970))" }

    private func restoreCalendar(_ file: URL, policy: ConflictPolicy) async throws -> Outcome {
        let ek = EKEventStore()
        guard try await ek.requestFullAccessToEvents() else { throw AppError.permissionDenied(L("Calendar")) }
        let events = try BackupSnapshot.decoder.decode([CalendarEventDTO].self, from: Data(contentsOf: file))
        guard let start = events.map(\.start).min(), let end = events.map(\.end).max() else { return .duplicate }
        var existing = Set<String>()
        if policy == .skipDuplicates {
            var cursor = start
            while cursor < end {
                let next = min(end.addingTimeInterval(1), Calendar.current.date(byAdding: .year, value: 1, to: cursor)!)
                for e in ek.events(matching: ek.predicateForEvents(withStart: cursor, end: next, calendars: nil)) {
                    existing.insert(Self.eventKey(title: e.title ?? "", start: e.startDate))
                }
                cursor = next
            }
        }
        let calendars = ek.calendars(for: .event).filter(\.allowsContentModifications)
        guard let fallback = ek.defaultCalendarForNewEvents ?? calendars.first else { throw AppError.unsupported(L("No writable calendar")) }
        var added = 0
        for dto in events where policy == .keepBoth || !existing.contains(Self.eventKey(title: dto.title, start: dto.start)) {
            let e = EKEvent(eventStore: ek)
            e.title = dto.title
            e.startDate = dto.start
            e.endDate = dto.end
            e.isAllDay = dto.allDay
            e.location = dto.location
            e.notes = dto.notes
            e.url = dto.url.flatMap(URL.init(string:))
            if let tz = dto.timeZone { e.timeZone = TimeZone(identifier: tz) }
            e.calendar = calendars.first { $0.title == dto.calendarTitle } ?? fallback
            try ek.save(e, span: .thisEvent, commit: false)
            added += 1
        }
        try ek.commit()
        return added > 0 ? .restored(L("Calendar")) : .duplicate
    }

    private func restoreReminders(_ file: URL, policy: ConflictPolicy) async throws -> Outcome {
        let ek = EKEventStore()
        guard try await ek.requestFullAccessToReminders() else { throw AppError.permissionDenied(L("Reminders")) }
        let items = try BackupSnapshot.decoder.decode([ReminderDTO].self, from: Data(contentsOf: file))
        var existing = Set<String>()
        if policy == .skipDuplicates {
            let current: [EKReminder] = await withCheckedContinuation { cont in
                ek.fetchReminders(matching: ek.predicateForReminders(in: nil)) { cont.resume(returning: $0 ?? []) }
            }
            existing = Set(current.map { "\(($0.title ?? "").lowercased())|\($0.calendar?.title ?? "")" })
        }
        let lists = ek.calendars(for: .reminder).filter(\.allowsContentModifications)
        guard let fallback = ek.defaultCalendarForNewReminders() ?? lists.first else { throw AppError.unsupported(L("No writable reminders list")) }
        var added = 0
        for dto in items where policy == .keepBoth || !existing.contains("\(dto.title.lowercased())|\(dto.listTitle)") {
            let r = EKReminder(eventStore: ek)
            r.title = dto.title
            r.notes = dto.notes
            r.priority = dto.priority
            r.isCompleted = dto.completed
            if let d = dto.dueDate { r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d) }
            r.calendar = lists.first { $0.title == dto.listTitle } ?? fallback
            try ek.save(r, commit: false)
            added += 1
        }
        try ek.commit()
        return added > 0 ? .restored(L("Reminders")) : .duplicate
    }

    // MARK: Files

    private func restoreFile(_ file: URL, entry: BackupEntry, policy: ConflictPolicy) throws -> Outcome {
        var dir = AppPaths.restored.appendingPathComponent(entry.category.groupFolderName, isDirectory: true)
        // Recreate the original folder structure for picked-folder items ("<folderUUID>/<relative path>").
        if [.documents, .audio, .files].contains(entry.category) {
            let rel = entry.sourceID.split(separator: "/").dropFirst().dropLast().map(String.init)
            for c in rel { dir.appendPathComponent(AppPaths.sanitize(c), isDirectory: true) }
        }
        AppPaths.ensure(dir)
        let target = dir.appendingPathComponent(entry.name)
        if FileManager.default.fileExists(atPath: target.path) {
            if policy == .skipDuplicates, (try? FileHasher.sha256Hex(of: target)) == (try? FileHasher.sha256Hex(of: file)) {
                return .duplicate
            }
        }
        let out = AppPaths.uniqueURL(in: dir, name: entry.name)
        try FileManager.default.copyItem(at: file, to: out)
        return .restored(L("Files ▸ On My iPhone ▸ iCloud IPA ▸ Restored"))
    }

    /// Checks for conflicts before restoring (used by the preview screen).
    func conflicts(in entries: [BackupEntry]) -> [BackupEntry] {
        entries.filter { e in
            switch e.category {
            case .photos, .videos: return PHAsset.fetchAssets(withLocalIdentifiers: [e.sourceID], options: nil).count > 0
            case .documents, .audio, .files, .appData:
                return FileManager.default.fileExists(atPath: AppPaths.restored.appendingPathComponent(e.category.groupFolderName).appendingPathComponent(e.name).path)
            default: return false
            }
        }
    }
}
