import XCTest
@testable import iCloudIPA

/// Live integration tests against the real services. They run only when credentials are supplied
/// (CI secrets or local scheme environment) and are skipped otherwise — they never fake success.
///
/// Google Drive: ICIPA_GOOGLE_TEST_CLIENT_ID + ICIPA_GOOGLE_TEST_REFRESH_TOKEN
/// TeraBox:      ICIPA_TERABOX_TEST_NDUS (session cookie of a test account)
final class LiveGoogleDriveTests: XCTestCase {
    func testDriveRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let refresh = env["ICIPA_GOOGLE_TEST_REFRESH_TOKEN"], !refresh.isEmpty,
              let client = env["ICIPA_GOOGLE_TEST_CLIENT_ID"], !client.isEmpty else {
            throw XCTSkip("Google Drive credentials not provided")
        }
        try XCTSkipUnless(TestSupport.keychainAvailable, "Keychain not available for this test host")
        let id = UUID()
        let tokens = GoogleTokenStore(accountID: id)
        try await tokens.save(GoogleCredential(accessToken: "", refreshToken: refresh, expiresAt: .distantPast, scope: ""))
        let drive = GoogleDriveProvider(accountID: id, tokens: tokens)
        defer { KeychainStore().remove(KeychainStore.credentialKey(id)) }

        let info = try await drive.accountInfo()
        XCTAssertFalse(info.email.isEmpty)
        let quota = try await drive.quota()
        XCTAssertGreaterThan(quota.used, -1)

        let folder = try await drive.createFolder(name: "iCloudIPA-test-\(UUID().uuidString.prefix(8))", in: drive.rootFolder)
        let payload = TestSupport.randomData(9 * 1024 * 1024 + 123) // > 1 chunk, exercises resumable upload
        let file = try TestSupport.tempFile(payload, name: "live.bin")
        let up = try await TransferManager.upload(localFile: file, name: "live.bin", provider: drive, folder: RemoteFolder(item: folder), encrypt: false, handle: nil, progress: nil)
        XCTAssertTrue(up.verified)
        let renamed = try await drive.rename(up.item, to: "live-renamed.bin")
        XCTAssertEqual(renamed.name, "live-renamed.bin")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = try await TransferManager.download(renamed, provider: drive, to: dir, progress: nil)
        XCTAssertEqual(try Data(contentsOf: local), payload)
        let found = try await drive.search("live-renamed")
        XCTAssertTrue(found.contains { $0.id == renamed.id })
        try await drive.delete(RemoteItem(id: folder.id, name: folder.name, isFolder: true, size: 0), permanently: true)
    }
}

final class LiveTeraBoxTests: XCTestCase {
    func testTeraBoxSessionListAndQuota() async throws {
        guard let ndus = ProcessInfo.processInfo.environment["ICIPA_TERABOX_TEST_NDUS"], !ndus.isEmpty else {
            throw XCTSkip("TeraBox test session not provided")
        }
        try XCTSkipUnless(TestSupport.keychainAvailable, "Keychain not available for this test host")
        let id = UUID()
        let session = TeraBoxSession(cookies: ["ndus": ndus], userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", jsToken: nil, bdstoken: nil,
                                     host: AppConfig.teraBoxHost, capturedAt: Date())
        let tb = TeraBoxProvider(accountID: id, session: session)
        try tb.store(session)
        defer { KeychainStore().remove(KeychainStore.credentialKey(id)) }
        try await tb.refreshTokens()
        let q = try await tb.quota()
        XCTAssertGreaterThan(q.total ?? 0, 0)
        _ = try await tb.list(folder: tb.rootFolder)
    }
}
