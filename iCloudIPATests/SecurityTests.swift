import XCTest
import CryptoKit
@testable import iCloudIPA

final class EncryptionTests: XCTestCase {
    let key = SymmetricKey(size: .bits256)

    private func roundTrip(_ data: Data, chunk: Int = 1024) throws -> (Data, URL) {
        let input = try TestSupport.tempFile(data)
        let enc = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dec = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileEncryptor.encrypt(file: input, to: enc, key: key, chunkSize: chunk)
        try FileEncryptor.decrypt(file: enc, to: dec, key: key)
        return (try Data(contentsOf: dec), enc)
    }

    func testRoundTripEmptySmallAndMultiChunk() throws {
        for size in [0, 1, 1023, 1024, 1025, 10_000] {
            let data = TestSupport.randomData(size)
            let (out, enc) = try roundTrip(data)
            XCTAssertEqual(out, data, "size \(size)")
            XCTAssertTrue(FileEncryptor.isEncrypted(enc))
            if size > 16 { XCTAssertNil(try Data(contentsOf: enc).range(of: data.prefix(16)), "plaintext must not appear in ciphertext") }
        }
    }

    func testWrongKeyFails() throws {
        let input = try TestSupport.tempFile(TestSupport.randomData(5000))
        let enc = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileEncryptor.encrypt(file: input, to: enc, key: key, chunkSize: 1024)
        let dec = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try FileEncryptor.decrypt(file: enc, to: dec, key: SymmetricKey(size: .bits256)))
    }

    func testTamperingAndTruncationAreDetected() throws {
        let input = try TestSupport.tempFile(TestSupport.randomData(5000))
        let enc = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileEncryptor.encrypt(file: input, to: enc, key: key, chunkSize: 1024)
        var bytes = try Data(contentsOf: enc)

        var flipped = bytes
        flipped[200] ^= 0xFF
        let tampered = try TestSupport.tempFile(flipped)
        XCTAssertThrowsError(try FileEncryptor.decrypt(file: tampered, to: tampered.appendingPathExtension("out"), key: key))

        // Drop the final chunk entirely: the previous chunk was not sealed as "final".
        let chunkRecord = 4 + 1024 + 28
        let lastLen = bytes.count - 13 - 4 * chunkRecord
        bytes.removeLast(lastLen)
        let truncated = try TestSupport.tempFile(bytes)
        XCTAssertThrowsError(try FileEncryptor.decrypt(file: truncated, to: truncated.appendingPathExtension("out"), key: key))
    }

    func testSealOpenSmallPayload() throws {
        let data = Data("manifest".utf8)
        XCTAssertEqual(try FileEncryptor.open(FileEncryptor.seal(data, key: key), key: key), data)
    }

    func testRecoveryKeyRoundTripAndChecksum() throws {
        let raw = TestSupport.randomData(32)
        let text = KeyManager.encodeRecoveryKey(raw)
        XCTAssertEqual(text.split(separator: "-").count, 18)
        XCTAssertEqual(try KeyManager.decodeRecoveryKey(text), raw)
        XCTAssertEqual(try KeyManager.decodeRecoveryKey(text.lowercased().replacingOccurrences(of: "-", with: " ")), raw)
        var broken = Array(text)
        broken[0] = broken[0] == "A" ? "B" : "A"
        XCTAssertThrowsError(try KeyManager.decodeRecoveryKey(String(broken)))
        XCTAssertThrowsError(try KeyManager.decodeRecoveryKey("short"))
    }

    func testKeychainStoreRoundTrip() throws {
        try XCTSkipUnless(TestSupport.keychainAvailable, "Keychain not available for this test host")
        let k = KeychainStore(service: "icloudipa.tests")
        try k.set(Data("secret".utf8), for: "a")
        XCTAssertEqual(k.data(for: "a"), Data("secret".utf8))
        try k.set(Data("updated".utf8), for: "a")
        XCTAssertEqual(k.data(for: "a"), Data("updated".utf8))
        k.remove("a")
        XCTAssertNil(k.data(for: "a"))
    }
}

final class HashingTests: XCTestCase {
    func testKnownVectors() throws {
        XCTAssertEqual(FileHasher.md5Hex(of: Data("abc".utf8)), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(FileHasher.sha256Hex(of: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let url = try TestSupport.tempFile(Data("abc".utf8))
        XCTAssertEqual(try FileHasher.md5Hex(of: url), "900150983cd24fb0d6963f7d28e17f72")
    }

    func testStreamingMatchesInMemory() throws {
        let data = TestSupport.randomData(3 * FileHasher.chunk + 17)
        let url = try TestSupport.tempFile(data)
        XCTAssertEqual(try FileHasher.md5Hex(of: url), FileHasher.md5Hex(of: data))
        XCTAssertEqual(try FileHasher.sha256Hex(of: url), FileHasher.sha256Hex(of: data))
    }
}

/// Face ID / passcode lock state machine with a fake authenticator.
@MainActor
final class AppLockTests: XCTestCase {
    final class FakeAuth: DeviceAuthenticator {
        var result: Result<Void, AppError> = .success(())
        var calls = 0
        var biometryName: String { "Face ID" }
        var canAuthenticate = true
        func authenticate(reason: String) async -> Result<Void, AppError> { calls += 1; return result }
    }

    func makeSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    func testEnableRequiresAuthenticationAndLocksAfterGrace() async {
        let settings = makeSettings()
        let auth = FakeAuth()
        let lock = AppLockManager(settings: settings, authenticator: auth)
        XCTAssertFalse(lock.isLocked)

        auth.result = .failure(.permissionDenied("no"))
        let enabledWithoutAuth = await lock.setLockEnabled(true)
        XCTAssertFalse(enabledWithoutAuth)
        XCTAssertFalse(settings.appLockEnabled)

        auth.result = .success(())
        let enabled = await lock.setLockEnabled(true)
        XCTAssertTrue(enabled)
        XCTAssertTrue(settings.appLockEnabled)

        settings.lockGraceSeconds = 60
        let t0 = Date()
        lock.didEnterBackground(now: t0)
        lock.willEnterForeground(now: t0.addingTimeInterval(30))
        XCTAssertFalse(lock.isLocked, "within grace period")
        lock.didEnterBackground(now: t0)
        lock.willEnterForeground(now: t0.addingTimeInterval(61))
        XCTAssertTrue(lock.isLocked)

        lock.lastError = nil
        auth.result = .failure(.cancelled)
        await lock.unlock()
        XCTAssertTrue(lock.isLocked)
        XCTAssertNil(lock.lastError, "cancel is not an error")
        auth.result = .success(())
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
    }

    func testProtectedFolderUnlockIsPerSession() async {
        let auth = FakeAuth()
        let lock = AppLockManager(settings: makeSettings(), authenticator: auth)
        let ok = await lock.unlockFolder("acc|f1", name: "Private")
        XCTAssertTrue(ok)
        _ = await lock.unlockFolder("acc|f1", name: "Private")
        XCTAssertEqual(auth.calls, 1, "already unlocked in this session")
        lock.didEnterBackground()
        XCTAssertFalse(lock.isFolderUnlocked("acc|f1"))
    }
}
