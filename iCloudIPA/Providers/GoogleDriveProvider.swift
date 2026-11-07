import Foundation

/// Google Drive API v3 adapter (https://developers.google.com/drive/api/reference/rest/v3).
final class GoogleDriveProvider: CloudProvider {
    let kind: ProviderKind = .googleDrive
    let accountID: UUID
    let tokens: GoogleTokenStore
    let capabilities: ProviderCapabilities = [.resumableUpload, .serverSideCopy, .trash, .revisions, .checksums, .search, .changeFeed, .backgroundTransfer]
    var maxConcurrentTransfers: Int { 4 }
    var rootFolder: RemoteFolder { RemoteFolder(id: "root", name: "My Drive", path: "/") }

    static let api = "https://www.googleapis.com/drive/v3"
    static let uploadAPI = "https://www.googleapis.com/upload/drive/v3"
    static let folderMime = "application/vnd.google-apps.folder"
    static let fileFields = "id,name,mimeType,size,md5Checksum,modifiedTime,createdTime,parents,trashed,thumbnailLink"
    /// Upload chunk size: must be a multiple of 256 KiB.
    static let chunkSize = 8 * 256 * 1024 * 4

    init(accountID: UUID, tokens: GoogleTokenStore? = nil) {
        self.accountID = accountID
        self.tokens = tokens ?? GoogleTokenStore(accountID: accountID)
    }

    // MARK: DTOs

    struct DriveFile: Decodable {
        let id: String
        let name: String
        let mimeType: String?
        let size: String?
        let md5Checksum: String?
        let modifiedTime: Date?
        let createdTime: Date?
        let parents: [String]?
        let trashed: Bool?
        let thumbnailLink: String?

        var item: RemoteItem {
            RemoteItem(id: id, name: name, isFolder: mimeType == GoogleDriveProvider.folderMime, size: Int64(size ?? "0") ?? 0,
                       parentID: parents?.first, path: nil, mimeType: mimeType, md5: md5Checksum,
                       modifiedAt: modifiedTime, createdAt: createdTime, trashed: trashed ?? false,
                       thumbnailURL: thumbnailLink.flatMap(URL.init(string:)))
        }
    }

    struct FileList: Decodable { let files: [DriveFile]; let nextPageToken: String? }

    struct About: Decodable {
        struct User: Decodable { let displayName: String?; let emailAddress: String?; let photoLink: String?; let permissionId: String? }
        struct Quota: Decodable { let limit: String?; let usage: String?; let usageInDriveTrash: String? }
        let user: User
        let storageQuota: Quota
    }

    struct RevisionList: Decodable {
        struct Rev: Decodable { let id: String; let modifiedTime: Date?; let size: String?; let md5Checksum: String?; let keepForever: Bool? }
        let revisions: [Rev]?
    }

    struct APIError: Decodable {
        struct Inner: Decodable { let code: Int; let message: String; let status: String? }
        let error: Inner
    }

    // MARK: Request plumbing

    func request(_ method: String, _ url: URL, json: Any? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(try await tokens.accessToken(forceRefresh: attempt > 1))", forHTTPHeaderField: "Authorization")
            if let json {
                req.httpBody = try JSONSerialization.data(withJSONObject: json)
                req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            }
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            let (data, resp) = try await HTTP.send(req)
            if resp.statusCode == 401 && attempt == 1 { continue } // token revoked/expired early → refresh once
            if (200...299).contains(resp.statusCode) || resp.statusCode == 308 { return (data, resp) }
            throw Self.mapError(data, resp.statusCode)
        }
    }

    static func mapError(_ data: Data, _ status: Int) -> AppError {
        let message = (try? JSONDecoder().decode(APIError.self, from: data))?.error.message ?? (String(data: data.prefix(300), encoding: .utf8) ?? "")
        switch status {
        case 401: return .sessionExpired
        case 403 where message.lowercased().contains("storage quota"): return .insufficientSpace
        case 403 where message.lowercased().contains("rate limit"): return .http(status: 429, message: message)
        case 404: return .notFound(message)
        default: return .http(status: status, message: message)
        }
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        let (data, _) = try await RetryPolicy().run { try await self.request("GET", HTTP.url(Self.api + path, query)) }
        return try HTTP.decode(T.self, data)
    }

    // MARK: Account

    func accountInfo() async throws -> ProviderAccountInfo {
        let a: About = try await get("/about", ["fields": "user(displayName,emailAddress,photoLink,permissionId),storageQuota(limit,usage,usageInDriveTrash)"])
        return ProviderAccountInfo(displayName: a.user.displayName ?? a.user.emailAddress ?? "Google Drive",
                                   email: a.user.emailAddress ?? "", userID: a.user.permissionId,
                                   avatarURL: a.user.photoLink.flatMap(URL.init(string:)))
    }

    func quota() async throws -> StorageQuota {
        let a: About = try await get("/about", ["fields": "storageQuota(limit,usage,usageInDriveTrash)"])
        return StorageQuota(total: a.storageQuota.limit.flatMap { Int64($0) }, used: Int64(a.storageQuota.usage ?? "0") ?? 0,
                            trash: a.storageQuota.usageInDriveTrash.flatMap { Int64($0) })
    }

    // MARK: Listing

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    func listQuery(_ q: String, orderBy: String? = "folder,name", limit: Int = .max, progress: ((Int) -> Void)? = nil) async throws -> [RemoteItem] {
        var out: [RemoteItem] = []
        var token: String?
        repeat {
            var params = ["q": q, "fields": "nextPageToken,files(\(Self.fileFields))", "pageSize": "1000", "spaces": "drive"]
            if let orderBy { params["orderBy"] = orderBy }
            if let token { params["pageToken"] = token }
            let page: FileList = try await get("/files", params)
            out.append(contentsOf: page.files.map(\.item))
            progress?(out.count)
            token = page.nextPageToken
        } while token != nil && out.count < limit
        return out
    }

    func list(folder: RemoteFolder) async throws -> [RemoteItem] {
        try await listQuery("'\(Self.escape(folder.id))' in parents and trashed = false")
    }

    func listAll(progress: ((Int) -> Void)?) async throws -> [RemoteItem] {
        try await listQuery("trashed = false and 'me' in owners", orderBy: nil, progress: progress)
    }

    func item(id: String) async throws -> RemoteItem {
        let f: DriveFile = try await get("/files/\(id)", ["fields": Self.fileFields])
        return f.item
    }

    func search(_ query: String) async throws -> [RemoteItem] {
        try await listQuery("name contains '\(Self.escape(query))' and trashed = false", orderBy: "folder,modifiedTime desc", limit: 500)
    }

    // MARK: Mutations

    func createFolder(name: String, in parent: RemoteFolder) async throws -> RemoteItem {
        let (data, _) = try await request("POST", HTTP.url(Self.api + "/files", ["fields": Self.fileFields]),
                                          json: ["name": name, "mimeType": Self.folderMime, "parents": [parent.id]])
        return try HTTP.decode(DriveFile.self, data).item
    }

    func rename(_ item: RemoteItem, to newName: String) async throws -> RemoteItem {
        let (data, _) = try await request("PATCH", HTTP.url(Self.api + "/files/\(item.id)", ["fields": Self.fileFields]), json: ["name": newName])
        return try HTTP.decode(DriveFile.self, data).item
    }

    func move(_ item: RemoteItem, to parent: RemoteFolder) async throws -> RemoteItem {
        var q = ["fields": Self.fileFields, "addParents": parent.id]
        var current = item.parentID
        if current == nil { current = try await self.item(id: item.id).parentID }
        if let current { q["removeParents"] = current }
        let (data, _) = try await request("PATCH", HTTP.url(Self.api + "/files/\(item.id)", q), json: [String: String]())
        return try HTTP.decode(DriveFile.self, data).item
    }

    func copy(_ item: RemoteItem, to parent: RemoteFolder) async throws -> RemoteItem {
        if item.isFolder {
            // Drive cannot copy folders server-side: recreate the tree, copying files server-side.
            let newFolder = try await createFolder(name: item.name, in: parent)
            let target = RemoteFolder(id: newFolder.id, name: newFolder.name)
            for child in try await list(folder: RemoteFolder(id: item.id, name: item.name)) {
                _ = try await copy(child, to: target)
            }
            return newFolder
        }
        let (data, _) = try await request("POST", HTTP.url(Self.api + "/files/\(item.id)/copy", ["fields": Self.fileFields]),
                                          json: ["name": item.name, "parents": [parent.id]])
        return try HTTP.decode(DriveFile.self, data).item
    }

    func delete(_ item: RemoteItem, permanently: Bool) async throws {
        if permanently {
            _ = try await request("DELETE", HTTP.url(Self.api + "/files/\(item.id)"))
        } else {
            _ = try await request("PATCH", HTTP.url(Self.api + "/files/\(item.id)", ["fields": "id"]), json: ["trashed": true])
        }
    }

    // MARK: Trash & revisions

    func trashed() async throws -> [RemoteItem] {
        try await listQuery("trashed = true and 'me' in owners", orderBy: "modifiedTime desc", limit: 2000)
    }

    func restoreFromTrash(_ item: RemoteItem) async throws {
        _ = try await request("PATCH", HTTP.url(Self.api + "/files/\(item.id)", ["fields": "id"]), json: ["trashed": false])
    }

    func emptyTrash() async throws {
        _ = try await request("DELETE", HTTP.url(Self.api + "/files/trash"))
    }

    func revisions(of item: RemoteItem) async throws -> [RemoteRevision] {
        guard !item.isFolder else { return [] }
        let r: RevisionList = try await get("/files/\(item.id)/revisions", ["fields": "revisions(id,modifiedTime,size,md5Checksum,keepForever)"])
        return (r.revisions ?? []).map {
            RemoteRevision(id: $0.id, modifiedAt: $0.modifiedTime, size: $0.size.flatMap { Int64($0) }, md5: $0.md5Checksum, keepForever: $0.keepForever ?? false)
        }.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    func downloadRevision(_ revision: RemoteRevision, of item: RemoteItem, to destination: URL) async throws {
        try await downloadURL(HTTP.url(Self.api + "/files/\(item.id)/revisions/\(revision.id)", ["alt": "media"]), to: destination, expected: revision.size, progress: nil)
    }

    // MARK: Download

    /// Google Docs/Sheets/Slides have no binary content; they are exported to Office formats.
    static func exportFormat(for mime: String?) -> (mime: String, ext: String)? {
        switch mime {
        case "application/vnd.google-apps.document": return ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx")
        case "application/vnd.google-apps.spreadsheet": return ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx")
        case "application/vnd.google-apps.presentation": return ("application/vnd.openxmlformats-officedocument.presentationml.presentation", "pptx")
        case "application/vnd.google-apps.drawing": return ("image/png", "png")
        case let m? where m.hasPrefix("application/vnd.google-apps.") && m != folderMime: return ("application/pdf", "pdf")
        default: return nil
        }
    }

    func download(_ item: RemoteItem, to destination: URL, progress: ProgressHandler?) async throws {
        if let export = Self.exportFormat(for: item.mimeType) {
            try await downloadURL(HTTP.url(Self.api + "/files/\(item.id)/export", ["mimeType": export.mime]), to: destination, expected: nil, progress: progress)
        } else {
            try await downloadURL(HTTP.url(Self.api + "/files/\(item.id)", ["alt": "media", "acknowledgeAbuse": "false"]),
                                  to: destination, expected: item.size, progress: progress)
        }
    }

    /// Authorised media request, used by the background URLSession for large downloads.
    func mediaRequest(for item: RemoteItem) async throws -> URLRequest {
        var req = URLRequest(url: HTTP.url(Self.api + "/files/\(item.id)", ["alt": "media"]))
        req.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        return req
    }

    func downloadURL(_ url: URL, to destination: URL, expected: Int64?, progress: ProgressHandler?) async throws {
        try await RetryPolicy().run {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(try await self.tokens.accessToken())", forHTTPHeaderField: "Authorization")
            let tmp = try await Downloader.download(req, expected: expected, progress: progress)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmp, to: destination)
        }
    }

    // MARK: Resumable upload

    func upload(file: URL, name: String, to parent: RemoteFolder, record: TransferHandle?, progress: ProgressHandler?) async throws -> RemoteItem {
        let total = AppPaths.fileSize(file)
        let mime = MIME.type(forFilename: name)
        var sessionURL: URL?
        if let saved = await record?.currentResumeURL() { sessionURL = URL(string: saved) }
        if sessionURL == nil {
            sessionURL = try await startResumableSession(name: name, parent: parent, mime: mime, size: total)
            await record?.setResumeURL(sessionURL?.absoluteString)
        }
        guard var session = sessionURL else { throw AppError.network("no upload session") }

        var offset: Int64 = 0
        var failures = 0
        // Resume: ask Google how many bytes it already has.
        do {
            if let status = try await queryUploadStatus(session, total: total) {
                switch status {
                case .complete(let item): progress?(total, total); return item
                case .offset(let o): offset = o
                }
            }
        } catch AppError.notFound(_) {
            // session expired (they live ~1 week) → start over
            session = try await startResumableSession(name: name, parent: parent, mime: mime, size: total)
            await record?.setResumeURL(session.absoluteString)
        }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let transferSession = TransferSession.make()
        while true {
            try Task.checkCancellation()
            progress?(offset, total)
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
            let end = offset + Int64(chunk.count) - 1
            var req = URLRequest(url: session)
            req.httpMethod = "PUT"
            req.setValue(String(chunk.count), forHTTPHeaderField: "Content-Length")
            if total == 0 {
                req.setValue("bytes */0", forHTTPHeaderField: "Content-Range")
            } else {
                req.setValue("bytes \(offset)-\(end)/\(total)", forHTTPHeaderField: "Content-Range")
            }
            do {
                let (data, resp) = try await transferSession.upload(for: req, from: chunk)
                guard let http = resp as? HTTPURLResponse else { throw AppError.network("no response") }
                switch http.statusCode {
                case 200, 201:
                    progress?(total, total)
                    await record?.setResumeURL(nil)
                    return try HTTP.decode(DriveFile.self, data).item
                case 308:
                    offset = Self.parseRangeHeader(http.value(forHTTPHeaderField: "Range")).map { $0 + 1 } ?? 0
                    failures = 0
                case 404, 410:
                    await record?.setResumeURL(nil)
                    throw AppError.http(status: http.statusCode, message: "upload session expired")
                default:
                    throw Self.mapError(data, http.statusCode)
                }
            } catch {
                failures += 1
                if Task.isCancelled { throw AppError.cancelled }
                guard failures <= 6, RetryPolicy.isRetryable(error) || (error as? URLError) != nil else { throw error }
                try await Task.sleep(nanoseconds: UInt64(RetryPolicy().delay(forAttempt: failures) * 1_000_000_000))
                if let status = try? await queryUploadStatus(session, total: total) {
                    switch status {
                    case .complete(let item): return item
                    case .offset(let o): offset = o
                    }
                }
            }
        }
    }

    enum UploadStatus { case complete(RemoteItem), offset(Int64) }

    func startResumableSession(name: String, parent: RemoteFolder, mime: String, size: Int64) async throws -> URL {
        let (_, resp) = try await RetryPolicy().run {
            try await self.request("POST", HTTP.url(Self.uploadAPI + "/files", ["uploadType": "resumable", "fields": Self.fileFields]),
                                   json: ["name": name, "parents": [parent.id]],
                                   headers: ["X-Upload-Content-Type": mime, "X-Upload-Content-Length": String(size)])
        }
        guard let loc = resp.value(forHTTPHeaderField: "Location"), let url = URL(string: loc) else {
            throw AppError.decoding("missing resumable session Location header")
        }
        return url
    }

    func queryUploadStatus(_ session: URL, total: Int64) async throws -> UploadStatus? {
        var req = URLRequest(url: session)
        req.httpMethod = "PUT"
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        req.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
        let (data, resp) = try await HTTP.send(req)
        switch resp.statusCode {
        case 200, 201: return .complete(try HTTP.decode(DriveFile.self, data).item)
        case 308: return .offset(Self.parseRangeHeader(resp.value(forHTTPHeaderField: "Range")).map { $0 + 1 } ?? 0)
        case 404, 410: throw AppError.notFound("upload session")
        default: return nil
        }
    }

    /// "bytes=0-524287" → 524287
    static func parseRangeHeader(_ header: String?) -> Int64? {
        guard let header, let dash = header.lastIndex(of: "-") else { return nil }
        return Int64(header[header.index(after: dash)...])
    }

    // MARK: Change feed (incremental index sync)

    struct StartToken: Decodable { let startPageToken: String }
    struct ChangeList: Decodable {
        struct Change: Decodable { let fileId: String?; let removed: Bool?; let file: DriveFile? }
        let changes: [Change]
        let nextPageToken: String?
        let newStartPageToken: String?
    }

    func startPageToken() async throws -> String {
        let t: StartToken = try await get("/changes/startPageToken")
        return t.startPageToken
    }

    /// Returns changed items, removed ids and the token to store for next time.
    func changes(since token: String) async throws -> (changed: [RemoteItem], removed: [String], next: String) {
        var changed: [RemoteItem] = []
        var removed: [String] = []
        var page: String? = token
        var newStart = token
        while let p = page {
            let c: ChangeList = try await get("/changes", ["pageToken": p, "pageSize": "1000", "spaces": "drive",
                                                            "fields": "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(Self.fileFields)))"])
            for ch in c.changes {
                if ch.removed == true || ch.file?.trashed == true { if let id = ch.fileId { removed.append(id) } }
                else if let f = ch.file { changed.append(f.item) }
            }
            page = c.nextPageToken
            if let n = c.newStartPageToken { newStart = n }
        }
        return (changed, removed, newStart)
    }

    func signOut() async {
        await tokens.clear()
    }
}

/// Download helper: a URLSession download task streams to disk; progress is observed via KVO.
enum Downloader {
    static func download(_ request: URLRequest, expected: Int64?, progress: ProgressHandler?,
                         session: URLSession = TransferSession.make()) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: request) { location, response, error in
                    if let error {
                        let u = error as? URLError
                        cont.resume(throwing: u?.code == .cancelled ? AppError.cancelled : AppError.network(error.localizedDescription))
                        return
                    }
                    guard let location, let http = response as? HTTPURLResponse else {
                        cont.resume(throwing: AppError.network("no response")); return
                    }
                    guard (200...299).contains(http.statusCode) else {
                        let body = (try? String(contentsOf: location, encoding: .utf8)).map { String($0.prefix(500)) } ?? ""
                        cont.resume(throwing: http.statusCode == 401 ? AppError.sessionExpired
                                    : http.statusCode == 404 ? AppError.notFound(body) : AppError.http(status: http.statusCode, message: body))
                        return
                    }
                    let tmp = AppPaths.tempFile()
                    do {
                        try FileManager.default.moveItem(at: location, to: tmp)
                        let size = AppPaths.fileSize(tmp)
                        if let expected, expected > 0, size != expected {
                            cont.resume(throwing: AppError.integrityCheckFailed(LF("expected %lld bytes, received %lld", expected, size)))
                            return
                        }
                        progress?(size, max(size, expected ?? 0))
                        cont.resume(returning: tmp)
                    } catch {
                        cont.resume(throwing: AppError.io(error.localizedDescription))
                    }
                }
                if let progress {
                    box.observation = task.observe(\.countOfBytesReceived, options: [.new]) { t, _ in
                        let total = expected ?? (t.countOfBytesExpectedToReceive > 0 ? t.countOfBytesExpectedToReceive : 0)
                        progress(t.countOfBytesReceived, total)
                    }
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    final class TaskBox: @unchecked Sendable {
        var task: URLSessionTask?
        var observation: NSKeyValueObservation?
    }
}
