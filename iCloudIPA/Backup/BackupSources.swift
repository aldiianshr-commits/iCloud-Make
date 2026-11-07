import Foundation
import Photos
import Contacts
import EventKit
import UIKit
import SwiftData

/// One item a backup source can export.
struct BackupSourceItem {
    let category: BackupCategory
    /// Stable identity of the item on this device (asset id, relative path, …).
    let sourceID: String
    /// File name used in the cloud.
    let name: String
    /// Changes whenever the content changes; drives incremental backup.
    let fingerprint: String
    let size: Int64?
    let creationDate: Date?
    /// Folder path below the category folder.
    let subfolder: [String]
    /// Writes the item to a local file (in staging) and returns it.
    let export: () async throws -> URL
    /// Snapshot items (contacts, calendar…) get a dated file name per version.
    var isSnapshot: Bool = false
}

protocol BackupSource {
    var category: BackupCategory { get }
    func requestAccess() async throws
    func enumerate() async throws -> [BackupSourceItem]
}

// MARK: - Photos & Videos

struct PhotoLibrarySource: BackupSource {
    let category: BackupCategory   // .photos or .videos

    func requestAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw AppError.permissionDenied(L("Photos")) }
    }

    static func monthFolder(_ date: Date?) -> [String] {
        guard let date else { return ["Unknown date"] }
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        return [String(c.year ?? 0), String(format: "%02d", c.month ?? 0)]
    }

    static func stamp(_ date: Date?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date ?? Date(timeIntervalSince1970: 0))
    }

    func enumerate() async throws -> [BackupSourceItem] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        opts.includeHiddenAssets = false
        let mediaType: PHAssetMediaType = category == .videos ? .video : .image
        let assets = PHAsset.fetchAssets(with: mediaType, options: opts)
        var out: [BackupSourceItem] = []
        out.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let primaryTypes: [PHAssetResourceType] = mediaType == .video ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto]
            guard let res = resources.first(where: { primaryTypes.contains($0.type) }) ?? resources.first else { return }
            let original = res.originalFilename.isEmpty ? (mediaType == .video ? "video.mov" : "photo.jpg") : res.originalFilename
            let name = "\(Self.stamp(asset.creationDate))_\(original)"
            let modified = asset.modificationDate?.timeIntervalSince1970 ?? 0
            let size = (res.value(forKey: "fileSize") as? CLong).map { Int64($0) }
            let localID = asset.localIdentifier
            out.append(BackupSourceItem(category: category, sourceID: localID, name: name,
                                        fingerprint: "\(Int(modified))|\(original)", size: size, creationDate: asset.creationDate,
                                        subfolder: Self.monthFolder(asset.creationDate)) {
                try await Self.export(resource: res, name: name)
            })
        }
        return out
    }

    static func export(resource: PHAssetResource, name: String) async throws -> URL {
        let url = AppPaths.tempFile(UUID().uuidString + "-" + AppPaths.sanitize(name))
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true // download iCloud Photos originals when needed
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        return url
    }
}

// MARK: - Contacts

struct ContactsSource: BackupSource {
    let category: BackupCategory = .contacts

    func requestAccess() async throws {
        let ok = try await CNContactStore().requestAccess(for: .contacts)
        guard ok else { throw AppError.permissionDenied(L("Contacts")) }
    }

    func enumerate() async throws -> [BackupSourceItem] {
        let data = try Self.exportVCard()
        let hash = FileHasher.sha256Hex(of: data)
        let url = AppPaths.tempFile("contacts-\(UUID().uuidString).vcf")
        try data.write(to: url)
        return [BackupSourceItem(category: .contacts, sourceID: "contacts.vcf", name: "contacts.vcf", fingerprint: hash,
                                 size: Int64(data.count), creationDate: Date(), subfolder: [], export: { url }, isSnapshot: true)]
    }

    static func exportVCard() throws -> Data {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [CNContactVCardSerialization.descriptorForRequiredKeys()]
        var contacts: [CNContact] = []
        let req = CNContactFetchRequest(keysToFetch: keys)
        req.sortOrder = .userDefault
        try store.enumerateContacts(with: req) { c, _ in contacts.append(c) }
        return try CNContactVCardSerialization.data(with: contacts)
    }
}

// MARK: - Calendar & Reminders

struct CalendarEventDTO: Codable, Equatable {
    var identifier: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String?
    var notes: String?
    var url: String?
    var calendarTitle: String
    var timeZone: String?
    var recurrence: String?
}

struct ReminderDTO: Codable, Equatable {
    var identifier: String
    var title: String
    var notes: String?
    var completed: Bool
    var completionDate: Date?
    var dueDate: Date?
    var priority: Int
    var listTitle: String
}

struct CalendarSource: BackupSource {
    let category: BackupCategory = .calendar

    func requestAccess() async throws {
        let ok = try await EKEventStore().requestFullAccessToEvents()
        guard ok else { throw AppError.permissionDenied(L("Calendar")) }
    }

    func enumerate() async throws -> [BackupSourceItem] {
        let store = EKEventStore()
        let cal = Calendar.current
        var events: [EKEvent] = []
        // EventKit limits a predicate to 4 years; cover 2 years back and 2 forward in yearly windows.
        let now = Date()
        for offset in -2..<2 {
            let start = cal.date(byAdding: .year, value: offset, to: now)!
            let end = cal.date(byAdding: .year, value: offset + 1, to: now)!
            events += store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        }
        var seen = Set<String>()
        let dtos: [CalendarEventDTO] = events.compactMap { e in
            let key = "\(e.eventIdentifier ?? UUID().uuidString)|\(e.startDate.timeIntervalSince1970)"
            guard seen.insert(key).inserted else { return nil }
            return CalendarEventDTO(identifier: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "", start: e.startDate, end: e.endDate,
                                    allDay: e.isAllDay, location: e.location, notes: e.notes, url: e.url?.absoluteString,
                                    calendarTitle: e.calendar?.title ?? "", timeZone: e.timeZone?.identifier,
                                    recurrence: e.recurrenceRules?.first.map { "\($0.frequency.rawValue)/\($0.interval)" })
        }.sorted { $0.start < $1.start }
        return try BackupSnapshot.items(category: .calendar, baseName: "calendar", json: dtos, ics: ICSWriter.events(dtos))
    }
}

struct RemindersSource: BackupSource {
    let category: BackupCategory = .reminders

    func requestAccess() async throws {
        let ok = try await EKEventStore().requestFullAccessToReminders()
        guard ok else { throw AppError.permissionDenied(L("Reminders")) }
    }

    func enumerate() async throws -> [BackupSourceItem] {
        let store = EKEventStore()
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: store.predicateForReminders(in: nil)) { cont.resume(returning: $0 ?? []) }
        }
        let dtos = reminders.map { r in
            ReminderDTO(identifier: r.calendarItemIdentifier, title: r.title ?? "", notes: r.notes, completed: r.isCompleted,
                        completionDate: r.completionDate, dueDate: r.dueDateComponents?.date ?? r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                        priority: r.priority, listTitle: r.calendar?.title ?? "")
        }.sorted { $0.title < $1.title }
        return try BackupSnapshot.items(category: .reminders, baseName: "reminders", json: dtos, ics: ICSWriter.todos(dtos))
    }
}

enum BackupSnapshot {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// JSON (used for restore) + .ics (portable), sharing one fingerprint so they move together.
    static func items<T: Encodable>(category: BackupCategory, baseName: String, json: T, ics: String) throws -> [BackupSourceItem] {
        let data = try encoder.encode(json)
        let icsData = Data(ics.utf8)
        let hash = FileHasher.sha256Hex(of: data)
        let jsonURL = AppPaths.tempFile("\(baseName)-\(UUID().uuidString).json")
        let icsURL = AppPaths.tempFile("\(baseName)-\(UUID().uuidString).ics")
        try data.write(to: jsonURL)
        try icsData.write(to: icsURL)
        return [
            BackupSourceItem(category: category, sourceID: "\(baseName).json", name: "\(baseName).json", fingerprint: hash,
                             size: Int64(data.count), creationDate: Date(), subfolder: [], export: { jsonURL }, isSnapshot: true),
            BackupSourceItem(category: category, sourceID: "\(baseName).ics", name: "\(baseName).ics", fingerprint: hash,
                             size: Int64(icsData.count), creationDate: Date(), subfolder: [], export: { icsURL }, isSnapshot: true),
        ]
    }
}

// MARK: - Picked folders (Documents / Audio / Files)

struct FolderSource: BackupSource {
    let category: BackupCategory
    let folders: [(id: UUID, name: String, bookmark: Data)]

    func requestAccess() async throws {
        if folders.isEmpty { throw AppError.permissionDenied(L("Pick at least one folder in Backup ▸ Folders")) }
    }

    static func matches(_ category: BackupCategory, _ url: URL) -> Bool {
        let c = FileCategory.from(filename: url.lastPathComponent)
        switch category {
        case .documents: return [.pdf, .document, .spreadsheet, .presentation, .text, .code].contains(c)
        case .audio: return c == .audio
        case .files: return ![.pdf, .document, .spreadsheet, .presentation, .text, .code, .audio].contains(c)
        default: return false
        }
    }

    func enumerate() async throws -> [BackupSourceItem] {
        var out: [BackupSourceItem] = []
        for folder in folders {
            var stale = false
            guard let root = try? URL(resolvingBookmarkData: folder.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                Log.backup.error("bookmark for \(folder.name, privacy: .public) could not be resolved")
                continue
            }
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in en {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, Self.matches(category, url) else { continue }
                let rel = url.path.replacingOccurrences(of: root.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let dirs = (rel as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
                let mtime = Int(v.contentModificationDate?.timeIntervalSince1970 ?? 0)
                let size = Int64(v.fileSize ?? 0)
                let bookmark = folder.bookmark
                let name = url.lastPathComponent
                out.append(BackupSourceItem(category: category, sourceID: "\(folder.id.uuidString)/\(rel)", name: name,
                                            fingerprint: "\(size)|\(mtime)", size: size, creationDate: v.creationDate,
                                            subfolder: [folder.name] + dirs) {
                    try Self.copyOut(bookmark: bookmark, relativePath: rel, name: name)
                })
            }
        }
        return out
    }

    static func copyOut(bookmark: Data, relativePath: String, name: String) throws -> URL {
        var stale = false
        let root = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let src = root.appendingPathComponent(relativePath)
        let dst = AppPaths.tempFile(UUID().uuidString + "-" + AppPaths.sanitize(name))
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [.withoutChanges], error: &coordError) { readURL in
            do { try FileManager.default.copyItem(at: readURL, to: dst) } catch { copyError = error }
        }
        if let e = coordError ?? copyError { throw AppError.io(e.localizedDescription) }
        return dst
    }
}

// MARK: - App data

struct AppDataExport: Codable {
    struct Account: Codable { let id: UUID; let provider: String; let displayName: String; let email: String; let role: String }
    var exportedAt: Date
    var appVersion: String
    var accounts: [Account]
    var settings: [String: String]
}

struct AppDataSource: BackupSource {
    let category: BackupCategory = .appData
    let snapshot: () async throws -> Data

    func requestAccess() async throws {}

    func enumerate() async throws -> [BackupSourceItem] {
        let data = try await snapshot()
        // Fingerprint ignores the export timestamp so unchanged data is not re-uploaded.
        var stable = data
        if var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj["exportedAt"] = nil
            stable = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? data
        }
        let url = AppPaths.tempFile("appdata-\(UUID().uuidString).json")
        try data.write(to: url)
        return [BackupSourceItem(category: .appData, sourceID: "appdata.json", name: "appdata.json", fingerprint: FileHasher.sha256Hex(of: stable),
                                 size: Int64(data.count), creationDate: Date(), subfolder: [], export: { url }, isSnapshot: true)]
    }
}
