import Foundation
import SwiftData

// MARK: - Enums stored as raw strings

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case googleDrive, teraBox
    var id: String { rawValue }
    var title: String { self == .googleDrive ? "Google Drive" : "TeraBox" }
    var symbol: String { self == .googleDrive ? "externaldrive.fill.badge.icloud" : "cloud.fill" }
}

enum AccountRole: String, Codable, CaseIterable, Identifiable {
    case primary, backup, normal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .primary: return L("Primary")
        case .backup: return L("Backup (fallback)")
        case .normal: return L("Normal")
        }
    }
}

enum ConnectionStatus: String, Codable {
    case connected, expired, error, experimental
    var title: String {
        switch self {
        case .connected: return L("Connected")
        case .expired: return L("Sign-in expired")
        case .error: return L("Error")
        case .experimental: return L("Connected (experimental)")
        }
    }
}

enum TransferKind: String, Codable { case upload, download, copy, move }
enum TransferStatus: String, Codable { case queued, running, paused, completed, failed, cancelled
    var isFinished: Bool { self == .completed || self == .failed || self == .cancelled }
}

enum BackupCategory: String, Codable, CaseIterable, Identifiable {
    case photos, videos, contacts, calendar, reminders, documents, audio, files, appData
    var id: String { rawValue }
    var title: String {
        switch self {
        case .photos: return L("Photos")
        case .videos: return L("Videos")
        case .contacts: return L("Contacts")
        case .calendar: return L("Calendar")
        case .reminders: return L("Reminders")
        case .documents: return L("Documents")
        case .audio: return L("Audio")
        case .files: return L("Files")
        case .appData: return L("iCloud IPA app data")
        }
    }
    var symbol: String {
        switch self {
        case .photos: return "photo.on.rectangle"
        case .videos: return "video"
        case .contacts: return "person.crop.circle"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .documents: return "doc.on.doc"
        case .audio: return "waveform"
        case .files: return "folder"
        case .appData: return "gearshape.2"
        }
    }
    /// Short explanation of what iOS actually allows for this category.
    var scopeNote: String {
        switch self {
        case .photos: return L("Original photo files from your Photos library (including iCloud Photos originals when downloadable).")
        case .videos: return L("Original video files from your Photos library.")
        case .contacts: return L("All contacts as a vCard file.")
        case .calendar: return L("Events from your calendars (past 2 years to next 2 years) as JSON + .ics.")
        case .reminders: return L("All reminders as JSON + .ics.")
        case .documents: return L("Documents inside folders you pick in the Files app.")
        case .audio: return L("Audio files inside folders you pick. Apple Music library songs cannot be exported by apps.")
        case .files: return L("All other files inside folders you pick in the Files app.")
        case .appData: return L("This app's own database and settings. Other apps' private data is not accessible on iOS.")
        }
    }
    var groupFolderName: String {
        switch self {
        case .photos: return "Photos"
        case .videos: return "Videos"
        case .contacts: return "Contacts"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .documents: return "Documents"
        case .audio: return "Audio"
        case .files: return "Files"
        case .appData: return "AppData"
        }
    }
}

enum BackupRunStatus: String, Codable { case running, completed, completedWithErrors, failed, cancelled }
enum BackupKind: String, Codable { case full, incremental }
enum BackupTrigger: String, Codable { case manual, scheduled }

enum ActivityKind: String, Codable { case upload, download, delete, rename, move, copy, backup, restore, account, sync, security, error }

// MARK: - Models

@Model
final class CloudAccount {
    @Attribute(.unique) var id: UUID
    var providerRaw: String
    var displayName: String
    var email: String
    var avatarURL: String?
    var roleRaw: String
    var isActive: Bool
    var statusRaw: String
    var lastError: String?
    var quotaTotal: Int64?
    var quotaUsed: Int64?
    var quotaTrash: Int64?
    var quotaUpdatedAt: Date?
    var lastSync: Date?
    var lastActivity: Date?
    var createdAt: Date
    var sortOrder: Int
    /// Provider-specific stable user id (Google permissionId / TeraBox uk) used to prevent duplicates.
    var externalUserID: String?

    init(id: UUID = UUID(), provider: ProviderKind, displayName: String, email: String, externalUserID: String?) {
        self.id = id
        self.providerRaw = provider.rawValue
        self.displayName = displayName
        self.email = email
        self.externalUserID = externalUserID
        self.roleRaw = AccountRole.normal.rawValue
        self.isActive = false
        self.statusRaw = ConnectionStatus.connected.rawValue
        self.createdAt = Date()
        self.sortOrder = 0
    }

    var provider: ProviderKind { ProviderKind(rawValue: providerRaw) ?? .googleDrive }
    var role: AccountRole {
        get { AccountRole(rawValue: roleRaw) ?? .normal }
        set { roleRaw = newValue.rawValue }
    }
    var status: ConnectionStatus {
        get { ConnectionStatus(rawValue: statusRaw) ?? .error }
        set { statusRaw = newValue.rawValue }
    }
    var quotaFree: Int64? {
        guard let t = quotaTotal, let u = quotaUsed else { return nil }
        return max(0, t - u)
    }
    var usageFraction: Double {
        guard let t = quotaTotal, t > 0, let u = quotaUsed else { return 0 }
        return min(1, Double(u) / Double(t))
    }
}

@Model
final class RemoteFileRecord {
    /// "\(accountID)|\(remoteID)"
    @Attribute(.unique) var key: String
    var accountID: UUID
    var remoteID: String
    var parentID: String?
    var name: String
    var path: String?
    var isFolder: Bool
    var size: Int64
    var mimeType: String?
    var md5: String?
    var modifiedAt: Date?
    var createdAt: Date?
    var categoryRaw: String
    var indexedAt: Date
    var trashed: Bool

    init(accountID: UUID, item: RemoteItem) {
        self.key = "\(accountID.uuidString)|\(item.id)"
        self.accountID = accountID
        self.remoteID = item.id
        self.parentID = item.parentID
        self.name = item.name
        self.path = item.path
        self.isFolder = item.isFolder
        self.size = item.size
        self.mimeType = item.mimeType
        self.md5 = item.md5
        self.modifiedAt = item.modifiedAt
        self.createdAt = item.createdAt
        self.categoryRaw = FileCategory.from(filename: item.name, mimeType: item.mimeType, isFolder: item.isFolder).rawValue
        self.indexedAt = Date()
        self.trashed = item.trashed
    }

    func update(from item: RemoteItem) {
        parentID = item.parentID
        name = item.name
        path = item.path
        isFolder = item.isFolder
        size = item.size
        mimeType = item.mimeType
        md5 = item.md5
        modifiedAt = item.modifiedAt
        createdAt = item.createdAt
        categoryRaw = FileCategory.from(filename: item.name, mimeType: item.mimeType, isFolder: item.isFolder).rawValue
        indexedAt = Date()
        trashed = item.trashed
    }

    var category: FileCategory { FileCategory(rawValue: categoryRaw) ?? .other }

    var asRemoteItem: RemoteItem {
        RemoteItem(id: remoteID, name: name, isFolder: isFolder, size: size, parentID: parentID, path: path,
                   mimeType: mimeType, md5: md5, modifiedAt: modifiedAt, createdAt: createdAt, trashed: trashed)
    }
}

@Model
final class TransferRecord {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var statusRaw: String
    var accountID: UUID
    var targetAccountID: UUID?
    var name: String
    var localPath: String?
    var remoteID: String?
    var remoteParentID: String?
    var totalBytes: Int64
    var transferredBytes: Int64
    var attempts: Int
    var errorMessage: String?
    var encrypted: Bool
    var verified: Bool
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    /// Google resumable session URL, persisted so an interrupted upload can resume.
    var resumeURL: String?

    init(kind: TransferKind, accountID: UUID, name: String, totalBytes: Int64) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.statusRaw = TransferStatus.queued.rawValue
        self.accountID = accountID
        self.name = name
        self.totalBytes = totalBytes
        self.transferredBytes = 0
        self.attempts = 0
        self.encrypted = false
        self.verified = false
        self.createdAt = Date()
    }

    var kind: TransferKind { TransferKind(rawValue: kindRaw) ?? .upload }
    var status: TransferStatus {
        get { TransferStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }
    var progress: Double { totalBytes > 0 ? min(1, Double(transferredBytes) / Double(totalBytes)) : (status == .completed ? 1 : 0) }
}

@Model
final class BackupRun {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var finishedAt: Date?
    var statusRaw: String
    var kindRaw: String
    var triggerRaw: String
    var accountID: UUID?
    var categoriesRaw: String
    var itemsTotal: Int
    var itemsUploaded: Int
    var itemsSkipped: Int
    var itemsFailed: Int
    var itemsDeletedDetected: Int
    var bytesUploaded: Int64
    var verifiedCount: Int
    var message: String?
    var manifestRemoteID: String?
    var remoteFolderID: String?

    init(kind: BackupKind, trigger: BackupTrigger, categories: [BackupCategory], accountID: UUID?) {
        self.id = UUID()
        self.startedAt = Date()
        self.statusRaw = BackupRunStatus.running.rawValue
        self.kindRaw = kind.rawValue
        self.triggerRaw = trigger.rawValue
        self.accountID = accountID
        self.categoriesRaw = categories.map(\.rawValue).joined(separator: ",")
        self.itemsTotal = 0
        self.itemsUploaded = 0
        self.itemsSkipped = 0
        self.itemsFailed = 0
        self.itemsDeletedDetected = 0
        self.bytesUploaded = 0
        self.verifiedCount = 0
    }

    var status: BackupRunStatus {
        get { BackupRunStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }
    var kind: BackupKind { BackupKind(rawValue: kindRaw) ?? .incremental }
    var trigger: BackupTrigger { BackupTrigger(rawValue: triggerRaw) ?? .manual }
    var categories: [BackupCategory] { categoriesRaw.split(separator: ",").compactMap { BackupCategory(rawValue: String($0)) } }
}

/// One backed-up item; the basis of incremental backup and restore.
@Model
final class BackupEntry {
    /// "\(category)|\(sourceID)"
    @Attribute(.unique) var key: String
    var categoryRaw: String
    var sourceID: String
    var name: String
    var fingerprint: String
    var accountID: UUID
    var remoteID: String
    var remoteParentID: String?
    var size: Int64
    var md5: String?
    var encrypted: Bool
    var creationDate: Date?
    var lastBackedUp: Date
    var deletedAt: Date?
    var lastRunID: UUID?

    init(category: BackupCategory, sourceID: String, name: String, fingerprint: String, accountID: UUID, remoteID: String) {
        self.key = "\(category.rawValue)|\(sourceID)"
        self.categoryRaw = category.rawValue
        self.sourceID = sourceID
        self.name = name
        self.fingerprint = fingerprint
        self.accountID = accountID
        self.remoteID = remoteID
        self.size = 0
        self.encrypted = false
        self.lastBackedUp = Date()
    }

    var category: BackupCategory { BackupCategory(rawValue: categoryRaw) ?? .files }
}

@Model
final class ActivityItem {
    @Attribute(.unique) var id: UUID
    var date: Date
    var kindRaw: String
    var title: String
    var detail: String?
    var accountID: UUID?
    var success: Bool

    init(kind: ActivityKind, title: String, detail: String?, accountID: UUID?, success: Bool = true) {
        self.id = UUID()
        self.date = Date()
        self.kindRaw = kind.rawValue
        self.title = title
        self.detail = detail
        self.accountID = accountID
        self.success = success
    }

    var kind: ActivityKind { ActivityKind(rawValue: kindRaw) ?? .error }
}

/// Folders that require Face ID / passcode before opening.
@Model
final class ProtectedFolder {
    @Attribute(.unique) var key: String
    var accountID: UUID
    var remoteID: String
    var name: String
    var createdAt: Date

    init(accountID: UUID, remoteID: String, name: String) {
        self.key = "\(accountID.uuidString)|\(remoteID)"
        self.accountID = accountID
        self.remoteID = remoteID
        self.name = name
        self.createdAt = Date()
    }
}

/// One-way mirror between two cloud folders (possibly in different accounts).
@Model
final class SyncPair {
    @Attribute(.unique) var id: UUID
    var sourceAccountID: UUID
    var sourceFolderID: String
    var sourceFolderName: String
    var targetAccountID: UUID
    var targetFolderID: String
    var targetFolderName: String
    var enabled: Bool
    var lastRun: Date?
    var lastResult: String?

    init(source: (UUID, String, String), target: (UUID, String, String)) {
        self.id = UUID()
        self.sourceAccountID = source.0
        self.sourceFolderID = source.1
        self.sourceFolderName = source.2
        self.targetAccountID = target.0
        self.targetFolderID = target.1
        self.targetFolderName = target.2
        self.enabled = true
    }
}

/// Local folders (security-scoped bookmarks) the user picked for Documents/Audio/Files backup.
@Model
final class BackupFolderSource {
    @Attribute(.unique) var id: UUID
    var name: String
    var bookmark: Data
    var addedAt: Date

    init(name: String, bookmark: Data) {
        self.id = UUID()
        self.name = name
        self.bookmark = bookmark
        self.addedAt = Date()
    }
}

/// Persisted status of background work (BGTaskScheduler).
@Model
final class BackgroundJobRecord {
    @Attribute(.unique) var identifier: String
    var lastScheduledAt: Date?
    var earliestBeginDate: Date?
    var lastStartedAt: Date?
    var lastFinishedAt: Date?
    var lastResult: String?
    var lastExpired: Bool

    init(identifier: String) {
        self.identifier = identifier
        self.lastExpired = false
    }
}

enum Schema_V1 {
    static var models: [any PersistentModel.Type] {
        [CloudAccount.self, RemoteFileRecord.self, TransferRecord.self, BackupRun.self, BackupEntry.self,
         ActivityItem.self, ProtectedFolder.self, SyncPair.self, BackupFolderSource.self, BackgroundJobRecord.self]
    }
}
