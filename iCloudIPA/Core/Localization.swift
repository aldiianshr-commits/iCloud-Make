import Foundation
import SwiftUI

/// In-app language selection (Bahasa Indonesia / English), independent of the system language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", indonesian = "id"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L("System")
        case .english: return "English"
        case .indonesian: return "Bahasa Indonesia"
        }
    }

    /// Resolved language code actually used for lookups.
    var resolvedCode: String {
        switch self {
        case .english: return "en"
        case .indonesian: return "id"
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("id") || preferred.hasPrefix("in") ? "id" : "en"
        }
    }
}

final class Localizer {
    static let shared = Localizer()
    static let defaultsKey = "settings.language"

    private var bundle: Bundle = .main
    private(set) var code: String = "en"

    init() { reload() }

    func reload() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? AppLanguage.system.rawValue
        let lang = AppLanguage(rawValue: raw) ?? .system
        code = lang.resolvedCode
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) {
            bundle = b
        } else {
            bundle = .main
        }
    }

    func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    var locale: Locale { Locale(identifier: code) }
}

/// Localized string lookup. English source strings are used as keys.
@inline(__always)
func L(_ key: String) -> String { Localizer.shared.string(key) }

/// Localized format string.
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localizer.shared.string(key), locale: Localizer.shared.locale, arguments: args)
}
