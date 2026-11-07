import Foundation

/// Developer/build configuration. Values are injected at build time from `Config/*.xcconfig`
/// through Info.plist. This is deliberately separate from the user-facing `AppSettings`.
enum AppConfig {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.aldiianshr.icloudipa"

    static var googleClientID: String? {
        nonEmpty(Bundle.main.object(forInfoDictionaryKey: "ICIPAGoogleClientID") as? String)
    }

    /// Reversed client ID, used as the OAuth redirect URL scheme.
    static var googleRedirectScheme: String? {
        guard let s = nonEmpty(Bundle.main.object(forInfoDictionaryKey: "ICIPAGoogleRedirectScheme") as? String),
              s.hasPrefix("com.googleusercontent.apps.") else { return nil }
        return s
    }

    static var isGoogleConfigured: Bool { googleClientID != nil && googleRedirectScheme != nil }

    static var teraBoxHost: String {
        nonEmpty(Bundle.main.object(forInfoDictionaryKey: "ICIPATeraBoxHost") as? String) ?? "www.terabox.com"
    }

    static var buildFlavor: String {
        nonEmpty(Bundle.main.object(forInfoDictionaryKey: "ICIPABuildFlavor") as? String) ?? "Unknown"
    }

    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    static let backupProcessingTaskID = "com.aldiianshr.icloudipa.backup.processing"
    static let backupRefreshTaskID = "com.aldiianshr.icloudipa.backup.refresh"
    static let backgroundURLSessionID = "com.aldiianshr.icloudipa.transfer.background"

    /// Root folder created in every cloud account for backups.
    static let remoteBackupRoot = "iCloud IPA Backup"

    static var isScreenshotMode: Bool {
        UserDefaults.standard.bool(forKey: "ICIPAScreenshotMode")
    }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, !s.hasPrefix("$(") else { return nil }
        return s
    }
}
