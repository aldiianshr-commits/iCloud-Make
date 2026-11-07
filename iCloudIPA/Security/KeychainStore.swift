import Foundation
import Security

/// Minimal Keychain wrapper (generic passwords). All OAuth tokens and web sessions are stored here,
/// never in UserDefaults or the database.
struct KeychainStore {
    let service: String

    init(service: String = "\(AppConfig.bundleID).secure") {
        self.service = service
    }

    enum Accessibility {
        /// Readable by background tasks after first unlock; never leaves this device.
        case afterFirstUnlockThisDevice
        case whenUnlockedThisDevice

        var value: CFString {
            switch self {
            case .afterFirstUnlockThisDevice: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case .whenUnlockedThisDevice: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
        }
    }

    func set(_ data: Data, for key: String, accessibility: Accessibility = .afterFirstUnlockThisDevice) throws {
        var query = baseQuery(key)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: accessibility.value]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(update) { $1 }
            let add = SecItemAdd(query as CFDictionary, nil)
            guard add == errSecSuccess else { throw AppError.crypto("Keychain add failed (\(add))") }
        } else if status != errSecSuccess {
            throw AppError.crypto("Keychain update failed (\(status))")
        }
    }

    func data(for key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    func remove(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    func setCodable<T: Encodable>(_ value: T, for key: String) throws {
        try set(try JSONEncoder().encode(value), for: key)
    }

    func codable<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        guard let d = data(for: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    // MARK: Well-known keys
    static func credentialKey(_ account: UUID) -> String { "credential.\(account.uuidString)" }
    static let masterKey = "encryption.masterKey.v1"
}
