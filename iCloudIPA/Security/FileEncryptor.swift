import Foundation
import CryptoKit

/// Manages the 256-bit master key used for client-side encryption.
/// The key is stored in the Keychain (this device only). Users can export it as a recovery key
/// so encrypted backups can be restored on another device.
final class KeyManager {
    static let shared = KeyManager()
    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    var hasKey: Bool { keychain.data(for: KeychainStore.masterKey) != nil }

    func masterKey() throws -> SymmetricKey {
        if let d = keychain.data(for: KeychainStore.masterKey) { return SymmetricKey(data: d) }
        let key = SymmetricKey(size: .bits256)
        try keychain.set(key.withUnsafeBytes { Data($0) }, for: KeychainStore.masterKey)
        Log.security.info("generated new master key")
        return key
    }

    /// Recovery key: uppercase hex of the raw key plus a 4-byte SHA-256 checksum, grouped in blocks of 4.
    func exportRecoveryKey() throws -> String {
        let raw = try masterKey().withUnsafeBytes { Data($0) }
        return Self.encodeRecoveryKey(raw)
    }

    func importRecoveryKey(_ text: String) throws {
        let raw = try Self.decodeRecoveryKey(text)
        try keychain.set(raw, for: KeychainStore.masterKey)
    }

    static func encodeRecoveryKey(_ raw: Data) -> String {
        let check = Data(SHA256.hash(data: raw).prefix(4))
        let hex = (raw + check).hexString.uppercased()
        return stride(from: 0, to: hex.count, by: 4).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: "-")
    }

    static func decodeRecoveryKey(_ text: String) throws -> Data {
        let hex = text.uppercased().filter { "0123456789ABCDEF".contains($0) }
        guard hex.count == 72 else { throw AppError.crypto(L("Invalid recovery key")) }
        var bytes = [UInt8]()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { throw AppError.crypto(L("Invalid recovery key")) }
            bytes.append(b)
            idx = next
        }
        let all = Data(bytes)
        let raw = all.prefix(32)
        guard Data(SHA256.hash(data: raw).prefix(4)) == all.suffix(4) else { throw AppError.crypto(L("Recovery key checksum mismatch")) }
        return Data(raw)
    }
}

/// Streaming AES-256-GCM file encryption.
///
/// Layout: "ICIPAENC" | version(1) | chunkSize(UInt32 BE) | { sealedLength(UInt32 BE) | nonce+ciphertext+tag }*
/// Each chunk's AAD binds header, chunk index and a final-chunk flag, so chunks cannot be reordered,
/// dropped or truncated without detection.
enum FileEncryptor {
    static let magic = Data("ICIPAENC".utf8)
    static let version: UInt8 = 1
    static let defaultChunkSize = 1 << 20
    static let encryptedExtension = "icipaenc"

    static func isEncrypted(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: magic.count)) == magic
    }

    static func encrypt(file input: URL, to output: URL, key: SymmetricKey, chunkSize: Int = defaultChunkSize) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let reader = try FileHandle(forReadingFrom: input)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? reader.close(); try? writer.close() }

        var header = magic
        header.append(version)
        header.append(contentsOf: UInt32(chunkSize).bigEndianBytes)
        try writer.write(contentsOf: header)

        var index: UInt64 = 0
        var current = try reader.read(upToCount: chunkSize) ?? Data()
        repeat {
            let next = try reader.read(upToCount: chunkSize) ?? Data()
            let isFinal = next.isEmpty
            let sealed = try AES.GCM.seal(current, using: key, authenticating: aad(header: header, index: index, final: isFinal))
            guard let combined = sealed.combined else { throw AppError.crypto("seal failed") }
            try writer.write(contentsOf: UInt32(combined.count).bigEndianBytes)
            try writer.write(contentsOf: combined)
            index += 1
            current = next
            if isFinal { break }
        } while true
    }

    static func decrypt(file input: URL, to output: URL, key: SymmetricKey) throws {
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        guard let head = try reader.read(upToCount: magic.count + 5), head.count == magic.count + 5,
              head.prefix(magic.count) == magic else { throw AppError.crypto(L("Not an iCloud IPA encrypted file")) }
        guard head[magic.count] == version else { throw AppError.crypto("unsupported version \(head[magic.count])") }
        let chunkSize = Int(UInt32(bigEndianBytes: head.suffix(4)))
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }

        var index: UInt64 = 0
        var pending = try readChunk(reader)
        guard pending != nil else { throw AppError.crypto(L("Encrypted file is truncated")) }
        while let chunk = pending {
            let next = try readChunk(reader)
            let isFinal = next == nil
            guard chunk.count <= chunkSize + 28 else { throw AppError.crypto("chunk too large") }
            let box = try AES.GCM.SealedBox(combined: chunk)
            do {
                let plain = try AES.GCM.open(box, using: key, authenticating: aad(header: Data(head), index: index, final: isFinal))
                try writer.write(contentsOf: plain)
            } catch {
                throw AppError.crypto(L("Decryption failed — wrong key or corrupted file"))
            }
            index += 1
            pending = next
        }
    }

    private static func readChunk(_ h: FileHandle) throws -> Data? {
        guard let lenData = try h.read(upToCount: 4), lenData.count == 4 else { return nil }
        let len = Int(UInt32(bigEndianBytes: lenData))
        guard let body = try h.read(upToCount: len), body.count == len else { throw AppError.crypto(L("Encrypted file is truncated")) }
        return body
    }

    private static func aad(header: Data, index: UInt64, final: Bool) -> Data {
        var d = header
        withUnsafeBytes(of: index.bigEndian) { d.append(contentsOf: $0) }
        d.append(final ? 1 : 0)
        return d
    }

    /// Encrypts a small in-memory payload (used for manifests and settings exports).
    static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let c = try AES.GCM.seal(data, using: key).combined else { throw AppError.crypto("seal failed") }
        return magic + c
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        guard data.prefix(magic.count) == magic else { throw AppError.crypto("bad header") }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(magic.count)), using: key)
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8(truncatingIfNeeded: self >> 24), UInt8(truncatingIfNeeded: self >> 16), UInt8(truncatingIfNeeded: self >> 8), UInt8(truncatingIfNeeded: self)]
    }

    init<D: DataProtocol>(bigEndianBytes d: D) {
        let b = Array(d)
        self = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }
}
