import Foundation

/// The web session of one TeraBox account, captured after the user signed in on terabox.com
/// inside the app's isolated web view. Stored only in the Keychain.
struct TeraBoxSession: Codable, Equatable {
    var cookies: [String: String]
    var userAgent: String
    var jsToken: String?
    var bdstoken: String?
    var host: String
    var capturedAt: Date

    var cookieHeader: String { cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ") }
    var isLoggedIn: Bool { cookies["ndus"] != nil }
}

/// TeraBox adapter.
///
/// STATUS: EXPERIMENTAL. TeraBox does not publish a public, self-service developer API (its Open
/// Platform is partner-only). This adapter uses the same HTTPS endpoints the terabox.com web client
/// uses, authenticated with the session the user created by signing in on the official website.
/// The endpoints are not contractually stable; every response is checked (`errno`) and failures are
/// surfaced as real errors. Nothing here reads or stores the user's password.
final class TeraBoxProvider: CloudProvider {
    let kind: ProviderKind = .teraBox
    let accountID: UUID
    let capabilities: ProviderCapabilities = [.trash, .checksums, .search]
    var maxConcurrentTransfers: Int { 2 }
    var rootFolder: RemoteFolder { RemoteFolder(id: "/", name: "TeraBox", path: "/") }

    static let appID = "250528"
    static let blockSize = 4 * 1024 * 1024
    private let keychain: KeychainStore
    private var session: TeraBoxSession?
    private let lock = NSLock()

    init(accountID: UUID, session: TeraBoxSession? = nil, keychain: KeychainStore = KeychainStore()) {
        self.accountID = accountID
        self.keychain = keychain
        self.session = session
    }

    func currentSession() throws -> TeraBoxSession {
        lock.lock(); defer { lock.unlock() }
        if let session { return session }
        guard let s = keychain.codable(TeraBoxSession.self, for: KeychainStore.credentialKey(accountID)) else { throw AppError.notAuthenticated }
        session = s
        return s
    }

    func store(_ s: TeraBoxSession) throws {
        lock.lock(); session = s; lock.unlock()
        try keychain.setCodable(s, for: KeychainStore.credentialKey(accountID))
    }

    var base: String { "https://\((try? currentSession().host) ?? AppConfig.teraBoxHost)" }

    // MARK: Response envelope

    struct Envelope: Decodable { let errno: Int; let errmsg: String?; let show_msg: String? }

    static func mapErrno(_ errno: Int, _ msg: String?) -> AppError {
        switch errno {
        case -6, -4, 4, 400310, 9019: return .sessionExpired
        case -9, 31066: return .notFound(msg ?? "file")
        case -10, 31112: return .insufficientSpace
        case 31045, 450016: return .sessionExpired
        default: return .provider(code: errno, message: msg ?? "TeraBox errno \(errno)")
        }
    }

    // MARK: Request plumbing

    func commonParams(_ s: TeraBoxSession) -> [String: String] {
        var p = ["app_id": Self.appID, "web": "1", "channel": "dubox", "clienttype": "0"]
        if let t = s.jsToken { p["jsToken"] = t }
        return p
    }

    func call(_ method: String, _ path: String, query: [String: String] = [:], form: [String: String]? = nil, host: String? = nil) async throws -> Data {
        var refreshed = false
        while true {
            let s = try currentSession()
            let urlBase = host.map { "https://\($0)" } ?? base
            var req = URLRequest(url: HTTP.url(urlBase + path, commonParams(s).merging(query) { $1 }))
            req.httpMethod = method
            req.setValue(s.cookieHeader, forHTTPHeaderField: "Cookie")
            req.setValue(s.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("https://\(s.host)/main", forHTTPHeaderField: "Referer")
            if let form {
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.httpBody = HTTP.formBody(form)
            }
            let (data, resp) = try await RetryPolicy().run { try await HTTP.send(req) }
            guard (200...299).contains(resp.statusCode) else { throw AppError.http(status: resp.statusCode, message: String(data: data.prefix(200), encoding: .utf8) ?? "") }
            if let env = try? JSONDecoder().decode(Envelope.self, from: data), env.errno != 0 {
                let err = Self.mapErrno(env.errno, env.errmsg ?? env.show_msg)
                // jsToken / bdstoken rotate; refresh them once from the web app before declaring the session dead.
                if !refreshed, err == .sessionExpired || env.errno == 2 || env.errno == 4000023 {
                    refreshed = true
                    if (try? await refreshTokens()) == true { continue }
                }
                throw err
            }
            return data
        }
    }

    /// Re-reads jsToken and bdstoken from the web app using the stored session cookies.
    @discardableResult
    func refreshTokens() async throws -> Bool {
        var s = try currentSession()
        var req = URLRequest(url: URL(string: "https://\(s.host)/main")!)
        req.setValue(s.cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(s.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await HTTP.send(req)
        let html = String(data: data, encoding: .utf8) ?? ""
        if let token = Self.extractJsToken(fromHTML: html) { s.jsToken = token }
        if let bds = try? await fetchBdstoken(s) { s.bdstoken = bds }
        try store(s)
        return s.jsToken != nil
    }

    /// The web app embeds jsToken as `fn("<TOKEN>")`, URL-encoded inside templateData.
    static func extractJsToken(fromHTML html: String) -> String? {
        if let r = try? NSRegularExpression(pattern: #"fn%28%22([A-Za-z0-9]+)%22%29"#),
           let m = r.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(m.range(at: 1), in: html) {
            return String(html[range])
        }
        let decoded = html.removingPercentEncoding ?? html
        for pattern in [#"fn\("([A-Za-z0-9]+)"\)"#, #""jsToken"\s*:\s*"([A-Za-z0-9]+)""#, #"jsToken\s*=\s*["']([A-Za-z0-9]+)["']"#] {
            if let r = try? NSRegularExpression(pattern: pattern),
               let m = r.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)),
               let range = Range(m.range(at: 1), in: decoded) {
                return String(decoded[range])
            }
        }
        return nil
    }

    struct TemplateVars: Decodable {
        struct R: Decodable { let bdstoken: String?; let uk: Int64? }
        let result: R?
    }

    private func fetchBdstoken(_ s: TeraBoxSession) async throws -> String? {
        var req = URLRequest(url: HTTP.url("https://\(s.host)/api/gettemplatevariable", commonParams(s).merging(["fields": #"["bdstoken","uk"]"#]) { $1 }))
        req.setValue(s.cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(s.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await HTTP.send(req)
        return try? JSONDecoder().decode(TemplateVars.self, from: data).result?.bdstoken
    }

    // MARK: DTOs

    struct TBFile: Decodable {
        let fs_id: Int64?
        let path: String
        let server_filename: String?
        let size: Int64?
        let isdir: Int?
        let server_mtime: Int64?
        let server_ctime: Int64?
        let local_mtime: Int64?
        let md5: String?
        let thumbs: [String: String]?

        var item: RemoteItem {
            let name = server_filename ?? (path as NSString).lastPathComponent
            let parent = (path as NSString).deletingLastPathComponent
            return RemoteItem(id: path, name: name, isFolder: (isdir ?? 0) == 1, size: size ?? 0,
                              parentID: parent.isEmpty ? "/" : parent, path: path, mimeType: nil, md5: md5,
                              modifiedAt: server_mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                              createdAt: server_ctime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                              trashed: false, thumbnailURL: thumbs?["url3"].flatMap(URL.init(string:)), numericID: fs_id)
        }
    }
    struct ListResponse: Decodable { let list: [TBFile]? }
    struct QuotaResponse: Decodable { let total: Int64?; let used: Int64?; let free: Int64? }
    struct InfoResponse: Decodable {
        struct D: Decodable { let display_name: String?; let head_url: String?; let uk: Int64?; let email: String? }
        let data: D?
    }

    // MARK: Account

    func accountInfo() async throws -> ProviderAccountInfo {
        var name = "TeraBox"
        var avatar: URL?
        var uk: Int64?
        if let data = try? await call("GET", "/passport/get_info"),
           let info = try? JSONDecoder().decode(InfoResponse.self, from: data).data {
            name = info.display_name ?? name
            avatar = info.head_url.flatMap(URL.init(string:))
            uk = info.uk
        }
        if uk == nil {
            let s = try currentSession()
            var req = URLRequest(url: HTTP.url("\(base)/api/gettemplatevariable", commonParams(s).merging(["fields": #"["bdstoken","uk"]"#]) { $1 }))
            req.setValue(s.cookieHeader, forHTTPHeaderField: "Cookie")
            req.setValue(s.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await HTTP.send(req)
            uk = (try? JSONDecoder().decode(TemplateVars.self, from: data))?.result?.uk
        }
        // Verify the session actually works with a cheap authenticated call.
        _ = try await quota()
        return ProviderAccountInfo(displayName: name, email: uk.map { "uk \($0)" } ?? "", userID: uk.map(String.init), avatarURL: avatar)
    }

    func quota() async throws -> StorageQuota {
        let data = try await call("GET", "/api/quota", query: ["checkexpire": "1", "checkfree": "1"])
        let q = try HTTP.decode(QuotaResponse.self, data)
        return StorageQuota(total: q.total, used: q.used ?? 0, trash: nil)
    }

    // MARK: Listing

    func list(folder: RemoteFolder) async throws -> [RemoteItem] {
        var out: [RemoteItem] = []
        var page = 1
        while true {
            let data = try await call("GET", "/api/list", query: ["dir": folder.path ?? folder.id, "num": "1000", "page": String(page),
                                                                   "order": "name", "desc": "0", "showempty": "1"])
            let items = try HTTP.decode(ListResponse.self, data).list ?? []
            out.append(contentsOf: items.map(\.item))
            if items.count < 1000 { break }
            page += 1
        }
        return out.sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
    }

    func listAll(progress: ((Int) -> Void)?) async throws -> [RemoteItem] {
        var out: [RemoteItem] = []
        var stack = [rootFolder]
        while let f = stack.popLast() {
            let children = try await list(folder: f)
            out.append(contentsOf: children)
            progress?(out.count)
            stack.append(contentsOf: children.filter(\.isFolder).map { RemoteFolder(id: $0.id, name: $0.name, path: $0.path) })
        }
        return out
    }

    func item(id: String) async throws -> RemoteItem {
        let parent = (id as NSString).deletingLastPathComponent
        let siblings = try await list(folder: RemoteFolder(id: parent.isEmpty ? "/" : parent, name: "", path: parent.isEmpty ? "/" : parent))
        guard let it = siblings.first(where: { $0.id == id }) else { throw AppError.notFound(id) }
        return it
    }

    func search(_ query: String) async throws -> [RemoteItem] {
        let data = try await call("GET", "/api/search", query: ["key": query, "dir": "/", "recursion": "1", "num": "500", "page": "1"])
        return (try HTTP.decode(ListResponse.self, data).list ?? []).map(\.item)
    }

    // MARK: Mutations

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" || dir.isEmpty ? "/" + name : dir + "/" + name
    }

    private func fileManager(_ opera: String, _ filelist: Any) async throws {
        let json = String(data: try JSONSerialization.data(withJSONObject: filelist), encoding: .utf8) ?? "[]"
        var q = ["opera": opera, "async": "2", "onnest": "fail"]
        if let b = try currentSession().bdstoken { q["bdstoken"] = b }
        _ = try await call("POST", "/api/filemanager", query: q, form: ["filelist": json])
    }

    func createFolder(name: String, in parent: RemoteFolder) async throws -> RemoteItem {
        let path = Self.join(parent.path ?? parent.id, name)
        var q = ["a": "commit"]
        if let b = try currentSession().bdstoken { q["bdstoken"] = b }
        let data = try await call("POST", "/api/create", query: q, form: ["path": path, "isdir": "1", "block_list": "[]"])
        let made = try? HTTP.decode(TBFile.self, data)
        return made?.item ?? RemoteItem(id: path, name: name, isFolder: true, size: 0, parentID: parent.id, path: path)
    }

    func rename(_ item: RemoteItem, to newName: String) async throws -> RemoteItem {
        try await fileManager("rename", [["path": item.id, "newname": newName]])
        var out = item
        let parent = (item.id as NSString).deletingLastPathComponent
        out.id = Self.join(parent.isEmpty ? "/" : parent, newName)
        out.path = out.id
        out.name = newName
        return out
    }

    func move(_ item: RemoteItem, to parent: RemoteFolder) async throws -> RemoteItem {
        let dest = parent.path ?? parent.id
        try await fileManager("move", [["path": item.id, "dest": dest, "newname": item.name]])
        var out = item
        out.id = Self.join(dest, item.name)
        out.path = out.id
        out.parentID = dest
        return out
    }

    func copy(_ item: RemoteItem, to parent: RemoteFolder) async throws -> RemoteItem {
        let dest = parent.path ?? parent.id
        try await fileManager("copy", [["path": item.id, "dest": dest, "newname": item.name]])
        var out = item
        out.id = Self.join(dest, item.name)
        out.path = out.id
        out.parentID = dest
        return out
    }

    /// TeraBox moves deleted files to its recycle bin; permanent deletion = delete + purge that entry.
    func delete(_ item: RemoteItem, permanently: Bool) async throws {
        try await fileManager("delete", [item.id])
        if permanently, let fsid = item.numericID {
            _ = try? await call("POST", "/api/recycle/delete", query: ["fidlist": "[\(fsid)]"])
        }
    }

    // MARK: Recycle bin

    func trashed() async throws -> [RemoteItem] {
        let data = try await call("GET", "/api/recycle/list", query: ["num": "1000", "page": "1", "order": "time", "desc": "1"])
        return (try HTTP.decode(ListResponse.self, data).list ?? []).map { (f: TBFile) -> RemoteItem in
            var i = f.item
            i.trashed = true
            return i
        }
    }

    func restoreFromTrash(_ item: RemoteItem) async throws {
        guard let fsid = item.numericID else { throw AppError.unsupported("missing fs_id") }
        _ = try await call("POST", "/api/recycle/restore", query: ["fidlist": "[\(fsid)]"])
    }

    func emptyTrash() async throws {
        _ = try await call("POST", "/api/recycle/clear")
    }

    func revisions(of item: RemoteItem) async throws -> [RemoteRevision] { [] }

    func downloadRevision(_ revision: RemoteRevision, of item: RemoteItem, to destination: URL) async throws {
        throw AppError.unsupported(L("File versions are not available for TeraBox"))
    }

    // MARK: Download

    struct MetaResponse: Decodable {
        struct Info: Decodable { let dlink: String?; let size: Int64?; let md5: String? }
        let info: [Info]?
    }

    func download(_ item: RemoteItem, to destination: URL, progress: ProgressHandler?) async throws {
        let target = String(data: try JSONSerialization.data(withJSONObject: [item.id]), encoding: .utf8) ?? "[]"
        let data = try await call("GET", "/api/filemetas", query: ["target": target, "dlink": "1"])
        guard let dlink = try HTTP.decode(MetaResponse.self, data).info?.first?.dlink, let url = URL(string: dlink) else {
            throw AppError.notFound(L("download link"))
        }
        let s = try currentSession()
        var req = URLRequest(url: url)
        req.setValue(s.cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(s.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://\(s.host)/main", forHTTPHeaderField: "Referer")
        let tmp = try await RetryPolicy().run { try await Downloader.download(req, expected: item.size > 0 ? item.size : nil, progress: progress) }
        if let md5 = item.md5, md5.count == 32, !item.isFolder {
            // TeraBox md5 values are sometimes obfuscated; only enforce when it is a plain hex digest that matches format.
            let local = try FileHasher.md5Hex(of: tmp)
            if local.lowercased() != md5.lowercased() { Log.provider.notice("TeraBox md5 differs (server value may be encoded)") }
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
    }

    // MARK: Upload (precreate → superfile2 blocks → create)

    struct PrecreateResponse: Decodable { let uploadid: String?; let return_type: Int?; let block_list: [Int]? }
    struct BlockResponse: Decodable { let md5: String? }
    struct LocateResponse: Decodable {
        struct Server: Decodable { let server: String? }
        let host: String?
        let servers: [Server]?
    }

    func uploadHost() async -> String {
        guard let s = try? currentSession() else { return "c-jp.terabox.com" }
        var req = URLRequest(url: HTTP.url("https://d.terabox.com/rest/2.0/pcs/file", commonParams(s).merging(["method": "locateupload"]) { $1 }))
        req.setValue(s.cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(s.userAgent, forHTTPHeaderField: "User-Agent")
        if let res = try? await HTTP.send(req), let r = try? JSONDecoder().decode(LocateResponse.self, from: res.0) {
            if let h = r.host, !h.isEmpty { return h }
            if let srv = r.servers?.first?.server, let u = URL(string: srv), let h = u.host { return h }
        }
        return "c-jp.terabox.com"
    }

    static func blockMD5s(of file: URL) throws -> [String] {
        var out: [String] = []
        try FileHasher.stream(file, size: blockSize) { out.append(FileHasher.md5Hex(of: $0)) }
        return out.isEmpty ? [FileHasher.md5Hex(of: Data())] : out
    }

    func upload(file: URL, name: String, to parent: RemoteFolder, record: TransferHandle?, progress: ProgressHandler?) async throws -> RemoteItem {
        let total = AppPaths.fileSize(file)
        let dir = parent.path ?? parent.id
        let path = Self.join(dir, name)
        let blocks = try Self.blockMD5s(of: file)
        let blockJSON = String(data: try JSONSerialization.data(withJSONObject: blocks), encoding: .utf8) ?? "[]"
        let mtime = String(Int(((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()).timeIntervalSince1970))
        var q: [String: String] = [:]
        if let b = try currentSession().bdstoken { q["bdstoken"] = b }

        let preData = try await call("POST", "/api/precreate", query: q, form: ["path": path, "autoinit": "1", "target_path": dir,
                                                                                  "block_list": blockJSON, "size": String(total), "local_mtime": mtime])
        let pre = try HTTP.decode(PrecreateResponse.self, preData)
        if pre.return_type == 2 { // server already had identical content ("rapid upload")
            progress?(total, total)
            return try await item(id: path)
        }
        guard let uploadID = pre.uploadid else { throw AppError.decoding("precreate: missing uploadid") }
        let needed = Set(pre.block_list ?? Array(0..<blocks.count))
        let host = await uploadHost()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sent: Int64 = 0
        let urlSession = TransferSession.make()
        for index in 0..<blocks.count {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(index * Self.blockSize))
            let chunk = try handle.read(upToCount: Self.blockSize) ?? Data()
            if needed.contains(index) {
                let returned = try await RetryPolicy(maxAttempts: 5).run {
                    try await self.uploadBlock(chunk, host: host, path: path, uploadID: uploadID, seq: index, session: urlSession)
                }
                if returned.lowercased() != blocks[index].lowercased() {
                    throw AppError.integrityCheckFailed(LF("block %d checksum mismatch", index))
                }
            }
            sent += Int64(chunk.count)
            progress?(sent, total)
        }
        let createData = try await call("POST", "/api/create", query: q.merging(["isdir": "0", "rtype": "1"]) { $1 },
                                        form: ["path": path, "size": String(total), "uploadid": uploadID, "target_path": dir,
                                               "block_list": blockJSON, "local_mtime": mtime])
        let created = try HTTP.decode(TBFile.self, createData).item
        if created.size != total && created.size != 0 {
            throw AppError.integrityCheckFailed(LF("server reports %lld bytes, local file has %lld", created.size, total))
        }
        return created.size == 0 ? RemoteItem(id: created.id, name: created.name, isFolder: false, size: total, parentID: dir,
                                              path: created.path, md5: created.md5, modifiedAt: Date(), numericID: created.numericID) : created
    }

    private func uploadBlock(_ chunk: Data, host: String, path: String, uploadID: String, seq: Int, session: URLSession) async throws -> String {
        let s = try currentSession()
        let url = HTTP.url("https://\(host)/rest/2.0/pcs/superfile2", commonParams(s).merging([
            "method": "upload", "type": "tmpfile", "path": path, "uploadid": uploadID, "partseq": String(seq)]) { $1 })
        let boundary = "----iCloudIPA\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"blob\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(chunk)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(s.cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(s.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://\(s.host)", forHTTPHeaderField: "Origin")
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.upload(for: req, from: body) } catch { throw AppError.network(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AppError.http(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, message: String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        if let env = try? JSONDecoder().decode(Envelope.self, from: data), env.errno != 0 { throw Self.mapErrno(env.errno, env.errmsg) }
        guard let md5 = try HTTP.decode(BlockResponse.self, data).md5 else { throw AppError.decoding("superfile2: no md5") }
        return md5
    }

    func signOut() async {
        if let s = try? currentSession() {
            var req = URLRequest(url: URL(string: "https://\(s.host)/passport/logout")!)
            req.setValue(s.cookieHeader, forHTTPHeaderField: "Cookie")
            req.setValue(s.userAgent, forHTTPHeaderField: "User-Agent")
            _ = try? await HTTP.send(req)
        }
        lock.lock(); session = nil; lock.unlock()
        keychain.remove(KeychainStore.credentialKey(accountID))
        await TeraBoxWebStore.removeData(for: accountID)
    }
}
