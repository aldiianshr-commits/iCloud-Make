import Foundation
import CryptoKit
import UniformTypeIdentifiers
import os

// MARK: - Logging

enum Log {
    static let app = Logger(subsystem: AppConfig.bundleID, category: "app")
    static let transfer = Logger(subsystem: AppConfig.bundleID, category: "transfer")
    static let backup = Logger(subsystem: AppConfig.bundleID, category: "backup")
    static let provider = Logger(subsystem: AppConfig.bundleID, category: "provider")
    static let security = Logger(subsystem: AppConfig.bundleID, category: "security")
}

// MARK: - Errors

enum AppError: LocalizedError, Equatable {
    case notConfigured(String)
    case notAuthenticated
    case sessionExpired
    case permissionDenied(String)
    case network(String)
    case http(status: Int, message: String)
    case provider(code: Int, message: String)
    case notFound(String)
    case integrityCheckFailed(String)
    case insufficientSpace
    case unsupported(String)
    case cancelled
    case decoding(String)
    case crypto(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return LF("%@ is not configured in this build.", what)
        case .notAuthenticated: return L("Account is not signed in.")
        case .sessionExpired: return L("The session has expired. Please sign in again.")
        case .permissionDenied(let what): return LF("Permission denied: %@", what)
        case .network(let m): return LF("Network error: %@", m)
        case .http(let s, let m): return "HTTP \(s): \(m)"
        case .provider(let c, let m): return LF("Provider error %d: %@", c, m)
        case .notFound(let m): return LF("Not found: %@", m)
        case .integrityCheckFailed(let m): return LF("Integrity check failed: %@", m)
        case .insufficientSpace: return L("Not enough free space in any connected account.")
        case .unsupported(let m): return LF("Not supported: %@", m)
        case .cancelled: return L("Cancelled")
        case .decoding(let m): return LF("Unexpected response: %@", m)
        case .crypto(let m): return LF("Encryption error: %@", m)
        case .io(let m): return LF("File error: %@", m)
        }
    }

    /// Whether retrying the same operation may succeed.
    var isTransient: Bool {
        switch self {
        case .network: return true
        case .http(let s, _): return s == 408 || s == 429 || (500...599).contains(s)
        default: return false
        }
    }
}

// MARK: - Retry

struct RetryPolicy {
    var maxAttempts: Int = 4
    var baseDelay: TimeInterval = 1.0
    var maxDelay: TimeInterval = 30

    /// Exponential backoff with deterministic upper bound (jitter applied by caller if wanted).
    func delay(forAttempt attempt: Int) -> TimeInterval {
        min(maxDelay, baseDelay * pow(2, Double(max(0, attempt - 1))))
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let e = error as? AppError { return e.isTransient }
        if let u = error as? URLError {
            switch u.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                 .dnsLookupFailed, .cannotFindHost, .internationalRoamingOff, .dataNotAllowed:
                return true
            default: return false
            }
        }
        return false
    }

    func run<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await operation()
            } catch {
                if Task.isCancelled { throw AppError.cancelled }
                guard attempt < maxAttempts, Self.isRetryable(error) else { throw error }
                let wait = delay(forAttempt: attempt) * Double.random(in: 0.8...1.2)
                Log.transfer.info("retry \(attempt) after \(wait, format: .fixed(precision: 1))s: \(error.localizedDescription, privacy: .public)")
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }
}

// MARK: - Hashing

enum FileHasher {
    static let chunk = 1 << 20

    static func md5Hex(of url: URL) throws -> String {
        var hasher = Insecure.MD5()
        try stream(url) { hasher.update(data: $0) }
        return hasher.finalize().hexString
    }

    static func sha256Hex(of url: URL) throws -> String {
        var hasher = SHA256()
        try stream(url) { hasher.update(data: $0) }
        return hasher.finalize().hexString
    }

    static func md5Hex(of data: Data) -> String { Insecure.MD5.hash(data: data).hexString }
    static func sha256Hex(of data: Data) -> String { SHA256.hash(data: data).hexString }

    static func stream(_ url: URL, size: Int = chunk, _ body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: size), !data.isEmpty {
            try body(data)
        }
    }
}

extension Sequence where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}


// MARK: - Formatting

enum Fmt {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.locale = Localizer.shared.locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.locale = Localizer.shared.locale
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func percent(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }
}

// MARK: - File types

enum FileCategory: String, CaseIterable, Codable, Identifiable {
    case photo, video, audio, pdf, document, spreadsheet, presentation, archive, text, code, app, folder, other
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .photo: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .presentation: return "rectangle.on.rectangle.angled"
        case .archive: return "doc.zipper"
        case .text: return "text.alignleft"
        case .code: return "curlybraces"
        case .app: return "app.badge"
        case .folder: return "folder.fill"
        case .other: return "doc"
        }
    }

    var title: String {
        switch self {
        case .photo: return L("Photos")
        case .video: return L("Videos")
        case .audio: return L("Audio")
        case .pdf: return "PDF"
        case .document: return L("Documents")
        case .spreadsheet: return L("Spreadsheets")
        case .presentation: return L("Presentations")
        case .archive: return L("Archives")
        case .text: return L("Text")
        case .code: return "JSON/XML"
        case .app: return "IPA"
        case .folder: return L("Folders")
        case .other: return L("Other")
        }
    }

    static func from(filename: String, mimeType: String? = nil, isFolder: Bool = false) -> FileCategory {
        if isFolder { return .folder }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp", "dng", "raw": return .photo
        case "mp4", "mov", "m4v", "avi", "mkv", "3gp", "webm", "hevc": return .video
        case "mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "ogg", "opus", "caf": return .audio
        case "pdf": return .pdf
        case "doc", "docx", "pages", "rtf", "odt": return .document
        case "xls", "xlsx", "numbers", "csv", "ods": return .spreadsheet
        case "ppt", "pptx", "key", "odp": return .presentation
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz": return .archive
        case "txt", "md", "log", "ics", "vcf": return .text
        case "json", "xml", "plist", "yaml", "yml", "html", "htm", "swift", "js", "css": return .code
        case "ipa": return .app
        default: break
        }
        if let m = mimeType {
            if m.hasPrefix("image/") { return .photo }
            if m.hasPrefix("video/") { return .video }
            if m.hasPrefix("audio/") { return .audio }
            if m == "application/vnd.google-apps.folder" { return .folder }
            if m.hasPrefix("application/vnd.google-apps.document") { return .document }
            if m.hasPrefix("application/vnd.google-apps.spreadsheet") { return .spreadsheet }
            if m.hasPrefix("application/vnd.google-apps.presentation") { return .presentation }
            if m.hasPrefix("text/") { return .text }
        }
        return .other
    }
}

enum MIME {
    static func type(forFilename name: String) -> String {
        let ext = (name as NSString).pathExtension
        if let t = UTType(filenameExtension: ext), let m = t.preferredMIMEType { return m }
        switch ext.lowercased() {
        case "ipa": return "application/octet-stream"
        case "rar": return "application/vnd.rar"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Paths

enum AppPaths {
    static var applicationSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iCloudIPA", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Visible in the Files app ("On My iPhone ▸ iCloud IPA").
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var downloads: URL { ensure(documents.appendingPathComponent("Downloads", isDirectory: true)) }
    static var restored: URL { ensure(documents.appendingPathComponent("Restored", isDirectory: true)) }

    static var staging: URL { ensure(FileManager.default.temporaryDirectory.appendingPathComponent("staging", isDirectory: true)) }

    static func tempFile(_ name: String = UUID().uuidString) -> URL {
        staging.appendingPathComponent(name)
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Returns a URL in `dir` that does not collide with an existing file ("name (2).ext").
    static func uniqueURL(in dir: URL, name: String) -> URL {
        var candidate = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let n = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(n)
            i += 1
        }
        return candidate
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "untitled" : cleaned
    }
}
