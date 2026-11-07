import Foundation
import SwiftUI

enum BackupSchedule: String, CaseIterable, Identifiable {
    case off, daily, weekly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return L("Manual only")
        case .daily: return L("Daily")
        case .weekly: return L("Weekly")
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .off: return nil
        case .daily: return 24 * 3600
        case .weekly: return 7 * 24 * 3600
        }
    }
}

enum FileViewMode: String { case list, grid }

enum FileSortMode: String, CaseIterable, Identifiable {
    case name, date, size, type
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return L("Name")
        case .date: return L("Date")
        case .size: return L("Size")
        case .type: return L("Type")
        }
    }
}

enum DeletedItemPolicy: String, CaseIterable, Identifiable {
    case keep, markOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keep: return L("Keep cloud copy (recommended)")
        case .markOnly: return L("Keep copy and mark as deleted")
        }
    }
}

/// End-user preferences (stored in UserDefaults). Nothing secret lives here.
@MainActor
final class AppSettings: ObservableObject {
    private let d: UserDefaults

    @Published var language: AppLanguage { didSet { d.set(language.rawValue, forKey: Localizer.defaultsKey); Localizer.shared.reload() } }
    @Published var appLockEnabled: Bool { didSet { d.set(appLockEnabled, forKey: "settings.appLock") } }
    @Published var lockGraceSeconds: Int { didSet { d.set(lockGraceSeconds, forKey: "settings.lockGrace") } }
    @Published var encryptUploads: Bool { didSet { d.set(encryptUploads, forKey: "settings.encryptUploads") } }
    @Published var encryptBackups: Bool { didSet { d.set(encryptBackups, forKey: "settings.encryptBackups") } }
    @Published var backupCategories: Set<BackupCategory> { didSet { d.set(backupCategories.map(\.rawValue), forKey: "settings.backupCategories") } }
    @Published var backupSchedule: BackupSchedule { didSet { d.set(backupSchedule.rawValue, forKey: "settings.backupSchedule") } }
    @Published var backupHour: Int { didSet { d.set(backupHour, forKey: "settings.backupHour") } }
    @Published var backupWiFiOnly: Bool { didSet { d.set(backupWiFiOnly, forKey: "settings.backupWiFiOnly") } }
    @Published var backupRequiresCharging: Bool { didSet { d.set(backupRequiresCharging, forKey: "settings.backupCharging") } }
    /// nil = choose automatically by free space.
    @Published var backupAccountID: UUID? { didSet { d.set(backupAccountID?.uuidString, forKey: "settings.backupAccount") } }
    @Published var deletedItemPolicy: DeletedItemPolicy { didSet { d.set(deletedItemPolicy.rawValue, forKey: "settings.deletedPolicy") } }
    @Published var allowCellular: Bool { didSet { d.set(allowCellular, forKey: "settings.allowCellular") } }
    @Published var maxParallelTransfers: Int { didSet { d.set(maxParallelTransfers, forKey: "settings.parallel") } }
    @Published var fileViewMode: FileViewMode { didSet { d.set(fileViewMode.rawValue, forKey: "settings.viewMode") } }
    @Published var sortMode: FileSortMode { didSet { d.set(sortMode.rawValue, forKey: "settings.sortMode") } }
    @Published var sortAscending: Bool { didSet { d.set(sortAscending, forKey: "settings.sortAsc") } }
    @Published var showDeveloperInfo: Bool { didSet { d.set(showDeveloperInfo, forKey: "settings.devInfo") } }
    @Published var lastBackupAt: Date? { didSet { d.set(lastBackupAt, forKey: "settings.lastBackupAt") } }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        language = AppLanguage(rawValue: d.string(forKey: Localizer.defaultsKey) ?? "") ?? .system
        appLockEnabled = d.bool(forKey: "settings.appLock")
        lockGraceSeconds = d.object(forKey: "settings.lockGrace") as? Int ?? 60
        encryptUploads = d.bool(forKey: "settings.encryptUploads")
        encryptBackups = d.bool(forKey: "settings.encryptBackups")
        let cats = (d.stringArray(forKey: "settings.backupCategories") ?? [BackupCategory.photos, .videos, .contacts].map(\.rawValue))
        backupCategories = Set(cats.compactMap(BackupCategory.init(rawValue:)))
        backupSchedule = BackupSchedule(rawValue: d.string(forKey: "settings.backupSchedule") ?? "") ?? .off
        backupHour = d.object(forKey: "settings.backupHour") as? Int ?? 2
        backupWiFiOnly = d.object(forKey: "settings.backupWiFiOnly") as? Bool ?? true
        backupRequiresCharging = d.object(forKey: "settings.backupCharging") as? Bool ?? false
        backupAccountID = d.string(forKey: "settings.backupAccount").flatMap(UUID.init(uuidString:))
        deletedItemPolicy = DeletedItemPolicy(rawValue: d.string(forKey: "settings.deletedPolicy") ?? "") ?? .markOnly
        allowCellular = d.object(forKey: "settings.allowCellular") as? Bool ?? true
        maxParallelTransfers = d.object(forKey: "settings.parallel") as? Int ?? 3
        fileViewMode = FileViewMode(rawValue: d.string(forKey: "settings.viewMode") ?? "") ?? .list
        sortMode = FileSortMode(rawValue: d.string(forKey: "settings.sortMode") ?? "") ?? .name
        sortAscending = d.object(forKey: "settings.sortAsc") as? Bool ?? true
        showDeveloperInfo = d.bool(forKey: "settings.devInfo")
        lastBackupAt = d.object(forKey: "settings.lastBackupAt") as? Date
    }

    /// Snapshot of user settings for the app-data backup (no secrets).
    func exportDictionary() -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in d.dictionaryRepresentation() where k.hasPrefix("settings.") {
            if let date = v as? Date { out[k] = ISO8601DateFormatter().string(from: date) } else { out[k] = v }
        }
        return out
    }

    func importDictionary(_ dict: [String: Any]) {
        for (k, v) in dict where k.hasPrefix("settings.") && k != "settings.appLock" {
            if k == "settings.lastBackupAt", let s = v as? String { d.set(ISO8601DateFormatter().date(from: s), forKey: k) } else { d.set(v, forKey: k) }
        }
    }
}
