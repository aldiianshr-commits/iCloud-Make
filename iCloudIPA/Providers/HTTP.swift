import Foundation

/// Small helpers shared by provider adapters.
enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60 * 60 * 6
        c.waitsForConnectivity = true
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return c.urlSessionConfiguration(applyingNetworkPolicy: NetworkPolicy.current)
    }()

    /// RFC 3986 unreserved characters only; everything else is percent-encoded.
    static let unreserved: CharacterSet = {
        var c = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        c.insert(charactersIn: "-._~")
        return c
    }()

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    static func query(_ params: [String: String]) -> String {
        params.sorted { $0.key < $1.key }.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&")
    }

    static func formBody(_ params: [String: String]) -> Data {
        Data(query(params).utf8)
    }

    static func url(_ base: String, _ params: [String: String] = [:]) -> URL {
        guard !params.isEmpty else { return URL(string: base)! }
        let sep = base.contains("?") ? "&" : "?"
        return URL(string: base + sep + query(params))!
    }

    /// Performs a request and maps transport errors to `AppError`.
    static func send(_ request: URLRequest, session: URLSession = HTTP.session) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: request)
            guard let http = resp as? HTTPURLResponse else { throw AppError.network("no HTTP response") }
            return (data, http)
        } catch let e as URLError {
            if e.code == .cancelled { throw AppError.cancelled }
            throw AppError.network(e.localizedDescription)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder.api.decode(T.self, from: data)
        } catch {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            throw AppError.decoding("\(T.self): \(error.localizedDescription) — \(snippet)")
        }
    }
}

extension JSONDecoder {
    static let api: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = RFC3339.parse(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
        }
        return d
    }()
}

enum RFC3339 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ s: String) -> Date? { withFraction.date(from: s) ?? plain.date(from: s) }
    static func string(_ d: Date) -> String { plain.string(from: d) }
}

/// Wi-Fi / cellular policy applied to transfer sessions.
enum NetworkPolicy {
    static var current: Bool { UserDefaults.standard.object(forKey: "settings.allowCellular") as? Bool ?? true }
}

extension URLSessionConfiguration {
    func urlSessionConfiguration(applyingNetworkPolicy allowCellular: Bool) -> URLSession {
        allowsCellularAccess = allowCellular
        allowsExpensiveNetworkAccess = allowCellular
        allowsConstrainedNetworkAccess = allowCellular
        return URLSession(configuration: self)
    }
}

/// A session honouring the *current* cellular setting (created per transfer, cheap to make).
enum TransferSession {
    static func make(allowCellular: Bool = NetworkPolicy.current) -> URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 60 * 60 * 12
        c.waitsForConnectivity = true
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        return c.urlSessionConfiguration(applyingNetworkPolicy: allowCellular)
    }
}
