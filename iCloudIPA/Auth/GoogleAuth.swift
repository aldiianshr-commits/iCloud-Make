import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

struct GoogleCredential: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var scope: String
}

/// OAuth 2.0 for installed apps (Authorization Code + PKCE), as documented at
/// https://developers.google.com/identity/protocols/oauth2/native-app — no client secret is embedded.
enum GoogleOAuth {
    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let revokeEndpoint = "https://oauth2.googleapis.com/revoke"
    static let scopes = ["openid", "email", "profile", "https://www.googleapis.com/auth/drive"]

    struct PKCE {
        let verifier: String
        let challenge: String

        init(verifier: String = PKCE.randomVerifier()) {
            self.verifier = verifier
            self.challenge = PKCE.challenge(for: verifier)
        }

        static func randomVerifier() -> String {
            var bytes = [UInt8](repeating: 0, count: 48)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return Data(bytes).base64URL
        }

        static func challenge(for verifier: String) -> String {
            Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        }
    }

    static func redirectURI(scheme: String) -> String { "\(scheme):/oauth2redirect" }

    static func authorizationURL(clientID: String, scheme: String, pkce: PKCE, state: String, loginHint: String? = nil) -> URL {
        var q: [String: String] = [
            "client_id": clientID,
            "redirect_uri": redirectURI(scheme: scheme),
            "response_type": "code",
            "scope": scopes.joined(separator: " "),
            "code_challenge": pkce.challenge,
            "code_challenge_method": "S256",
            "state": state,
            "prompt": "select_account consent",
            "include_granted_scopes": "true",
        ]
        if let loginHint { q["login_hint"] = loginHint }
        return HTTP.url(authEndpoint, q)
    }

    struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
        let scope: String?
        let error: String?
    }

    struct ErrorResponse: Decodable { let error: String; let error_description: String? }

    static func exchange(code: String, clientID: String, scheme: String, verifier: String) async throws -> GoogleCredential {
        var req = URLRequest(url: URL(string: tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = HTTP.formBody(["code": code, "client_id": clientID, "redirect_uri": redirectURI(scheme: scheme),
                                      "grant_type": "authorization_code", "code_verifier": verifier])
        let (data, resp) = try await HTTP.send(req)
        guard resp.statusCode == 200 else { throw mapTokenError(data, status: resp.statusCode) }
        let t = try HTTP.decode(TokenResponse.self, data)
        guard let refresh = t.refresh_token else { throw AppError.provider(code: 0, message: "Google did not return a refresh token") }
        return GoogleCredential(accessToken: t.access_token, refreshToken: refresh,
                                expiresAt: Date().addingTimeInterval(TimeInterval(t.expires_in)), scope: t.scope ?? "")
    }

    static func refresh(_ cred: GoogleCredential, clientID: String) async throws -> GoogleCredential {
        var req = URLRequest(url: URL(string: tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = HTTP.formBody(["client_id": clientID, "refresh_token": cred.refreshToken, "grant_type": "refresh_token"])
        let (data, resp) = try await HTTP.send(req)
        guard resp.statusCode == 200 else { throw mapTokenError(data, status: resp.statusCode) }
        let t = try HTTP.decode(TokenResponse.self, data)
        var out = cred
        out.accessToken = t.access_token
        out.expiresAt = Date().addingTimeInterval(TimeInterval(t.expires_in))
        if let r = t.refresh_token { out.refreshToken = r }
        if let s = t.scope { out.scope = s }
        return out
    }

    /// Revokes the refresh token at Google (also invalidates its access tokens).
    static func revoke(_ token: String) async {
        var req = URLRequest(url: HTTP.url(revokeEndpoint, ["token": token]))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        _ = try? await HTTP.send(req)
    }

    static func mapTokenError(_ data: Data, status: Int) -> AppError {
        if let e = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            if e.error == "invalid_grant" { return .sessionExpired }
            return .provider(code: status, message: "\(e.error): \(e.error_description ?? "")")
        }
        return .http(status: status, message: String(data: data, encoding: .utf8) ?? "")
    }

    static func parseCallback(_ url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        if let err = v("error") { throw err == "access_denied" ? AppError.cancelled : AppError.provider(code: 0, message: err) }
        guard v("state") == expectedState else { throw AppError.permissionDenied("OAuth state mismatch") }
        guard let code = v("code") else { throw AppError.decoding("missing authorization code") }
        return code
    }
}

/// Presents Google's sign-in page in an `ASWebAuthenticationSession` (system browser sheet).
@MainActor
final class GoogleSignInCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func signIn() async throws -> GoogleCredential {
        guard let clientID = AppConfig.googleClientID, let scheme = AppConfig.googleRedirectScheme else {
            throw AppError.notConfigured("Google OAuth client ID")
        }
        let pkce = GoogleOAuth.PKCE()
        let state = UUID().uuidString
        let url = GoogleOAuth.authorizationURL(clientID: clientID, scheme: scheme, pkce: pkce, state: state)
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
                if let url { cont.resume(returning: url); return }
                if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    cont.resume(throwing: AppError.cancelled)
                } else {
                    cont.resume(throwing: AppError.network(error?.localizedDescription ?? "sign-in failed"))
                }
            }
            // Ephemeral: every "Add account" can pick a different Google account; no shared Safari cookies.
            s.prefersEphemeralWebBrowserSession = true
            s.presentationContextProvider = self
            session = s
            if !s.start() { cont.resume(throwing: AppError.unsupported("could not start sign-in session")) }
        }
        let code = try GoogleOAuth.parseCallback(callback, expectedState: state)
        return try await GoogleOAuth.exchange(code: code, clientID: clientID, scheme: scheme, verifier: pkce.verifier)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

/// Serialises token refreshes per account and persists refreshed tokens in the Keychain.
actor GoogleTokenStore {
    private let accountID: UUID
    private let keychain: KeychainStore
    private var cached: GoogleCredential?
    private var refreshing: Task<GoogleCredential, Error>?

    init(accountID: UUID, keychain: KeychainStore = KeychainStore()) {
        self.accountID = accountID
        self.keychain = keychain
    }

    func save(_ cred: GoogleCredential) throws {
        cached = cred
        try keychain.setCodable(cred, for: KeychainStore.credentialKey(accountID))
    }

    func credential() -> GoogleCredential? {
        if let cached { return cached }
        cached = keychain.codable(GoogleCredential.self, for: KeychainStore.credentialKey(accountID))
        return cached
    }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let cred = credential() else { throw AppError.notAuthenticated }
        if !forceRefresh, cred.expiresAt > Date().addingTimeInterval(90) { return cred.accessToken }
        if let refreshing { return try await refreshing.value.accessToken }
        guard let clientID = AppConfig.googleClientID ?? ProcessInfo.processInfo.environment["ICIPA_GOOGLE_TEST_CLIENT_ID"] else {
            throw AppError.notConfigured("Google OAuth client ID")
        }
        let task = Task { try await GoogleOAuth.refresh(cred, clientID: clientID) }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        try save(fresh)
        return fresh.accessToken
    }

    func clear() async {
        if let c = credential() { await GoogleOAuth.revoke(c.refreshToken) }
        cached = nil
        keychain.remove(KeychainStore.credentialKey(accountID))
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
