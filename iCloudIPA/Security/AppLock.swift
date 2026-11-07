import Foundation
import LocalAuthentication
import SwiftUI

protocol DeviceAuthenticator {
    /// Biometry type the device offers (Face ID / Touch ID / none).
    var biometryName: String { get }
    var canAuthenticate: Bool { get }
    func authenticate(reason: String) async -> Result<Void, AppError>
}

/// Face ID / Touch ID with automatic fallback to the device passcode
/// (`.deviceOwnerAuthentication` policy).
struct LocalDeviceAuthenticator: DeviceAuthenticator {
    var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return L("Passcode")
        }
    }

    var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(reason: String) async -> Result<Void, AppError> {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = L("Use Passcode")
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            return .failure(.permissionDenied(err?.localizedDescription ?? L("No passcode is set on this device")))
        }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .success(()) : .failure(.permissionDenied(L("Authentication failed")))
        } catch let e as LAError where e.code == .userCancel || e.code == .appCancel || e.code == .systemCancel {
            return .failure(.cancelled)
        } catch {
            return .failure(.permissionDenied(error.localizedDescription))
        }
    }
}

/// App-level lock state machine. Locks on launch and after the app has been in the background
/// longer than the grace period.
@MainActor
final class AppLockManager: ObservableObject {
    @Published private(set) var isLocked: Bool
    @Published var lastError: String?
    /// Remote folder keys unlocked during this foreground session.
    @Published private(set) var unlockedFolders: Set<String> = []

    let authenticator: DeviceAuthenticator
    private let settings: AppSettings
    private var backgroundedAt: Date?

    init(settings: AppSettings, authenticator: DeviceAuthenticator = LocalDeviceAuthenticator()) {
        self.settings = settings
        self.authenticator = authenticator
        self.isLocked = settings.appLockEnabled && !AppConfig.isScreenshotMode
    }

    func didEnterBackground(now: Date = Date()) {
        backgroundedAt = now
        unlockedFolders.removeAll()
    }

    func willEnterForeground(now: Date = Date()) {
        guard settings.appLockEnabled else { isLocked = false; return }
        if let t = backgroundedAt, now.timeIntervalSince(t) >= TimeInterval(settings.lockGraceSeconds) {
            isLocked = true
        }
        backgroundedAt = nil
    }

    func unlock() async {
        guard isLocked else { return }
        switch await authenticator.authenticate(reason: L("Unlock iCloud IPA")) {
        case .success:
            isLocked = false
            lastError = nil
        case .failure(let e):
            if e != .cancelled { lastError = e.localizedDescription }
        }
    }

    /// Enabling the lock requires a successful authentication first so users can't lock themselves out.
    func setLockEnabled(_ enabled: Bool) async -> Bool {
        if enabled {
            guard authenticator.canAuthenticate else {
                lastError = L("Set a device passcode to use App Lock.")
                return false
            }
            switch await authenticator.authenticate(reason: L("Enable App Lock")) {
            case .success: settings.appLockEnabled = true; return true
            case .failure(let e): lastError = e.localizedDescription; return false
            }
        } else {
            settings.appLockEnabled = false
            isLocked = false
            return true
        }
    }

    func isFolderUnlocked(_ key: String) -> Bool { unlockedFolders.contains(key) }

    func unlockFolder(_ key: String, name: String) async -> Bool {
        if unlockedFolders.contains(key) { return true }
        switch await authenticator.authenticate(reason: LF("Open protected folder “%@”", name)) {
        case .success:
            unlockedFolders.insert(key)
            return true
        case .failure(let e):
            if e != .cancelled { lastError = e.localizedDescription }
            return false
        }
    }
}
