import XCTest
@testable import iCloudIPA

final class GoogleOAuthTests: XCTestCase {
    /// RFC 7636 Appendix B test vector.
    func testPKCEChallengeMatchesRFCVector() {
        let pkce = GoogleOAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let random = GoogleOAuth.PKCE()
        XCTAssertGreaterThanOrEqual(random.verifier.count, 43)
        XCTAssertLessThanOrEqual(random.verifier.count, 128)
    }

    func testAuthorizationURLContainsRequiredParameters() throws {
        let pkce = GoogleOAuth.PKCE(verifier: "v" + String(repeating: "x", count: 50))
        let url = GoogleOAuth.authorizationURL(clientID: "123-abc.apps.googleusercontent.com", scheme: "com.googleusercontent.apps.123-abc", pkce: pkce, state: "S1")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], pkce.challenge)
        XCTAssertEqual(items["redirect_uri"], "com.googleusercontent.apps.123-abc:/oauth2redirect")
        XCTAssertEqual(items["state"], "S1")
        XCTAssertTrue(items["scope"]?.contains("https://www.googleapis.com/auth/drive") == true)
    }

    func testCallbackParsing() throws {
        let ok = URL(string: "com.googleusercontent.apps.1:/oauth2redirect?state=S&code=4/abc")!
        XCTAssertEqual(try GoogleOAuth.parseCallback(ok, expectedState: "S"), "4/abc")
        XCTAssertThrowsError(try GoogleOAuth.parseCallback(ok, expectedState: "OTHER"))
        let denied = URL(string: "com.googleusercontent.apps.1:/oauth2redirect?error=access_denied&state=S")!
        XCTAssertThrowsError(try GoogleOAuth.parseCallback(denied, expectedState: "S")) { XCTAssertEqual($0 as? AppError, .cancelled) }
    }

    func testTokenErrorMapping() {
        let data = Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8)
        XCTAssertEqual(GoogleOAuth.mapTokenError(data, status: 400), .sessionExpired)
    }

    func testFormBodyEncodesReservedCharacters() {
        let body = String(data: HTTP.formBody(["a": "1+2 3&x=y"]), encoding: .utf8)
        XCTAssertEqual(body, "a=1%2B2%203%26x%3Dy")
    }
}

final class GoogleDriveParsingTests: XCTestCase {
    func testDriveFileDecoding() throws {
        let json = """
        {"files":[{"id":"f1","name":"photo.jpg","mimeType":"image/jpeg","size":"2048","md5Checksum":"abc","modifiedTime":"2026-01-02T03:04:05.123Z",
        "createdTime":"2026-01-01T00:00:00Z","parents":["p1"],"trashed":false},
        {"id":"d1","name":"Folder","mimeType":"application/vnd.google-apps.folder","parents":["root"]}],"nextPageToken":"t2"}
        """
        let list = try HTTP.decode(GoogleDriveProvider.FileList.self, Data(json.utf8))
        XCTAssertEqual(list.nextPageToken, "t2")
        let file = list.files[0].item
        XCTAssertEqual(file.size, 2048)
        XCTAssertEqual(file.parentID, "p1")
        XCTAssertEqual(file.md5, "abc")
        XCTAssertNotNil(file.modifiedAt)
        XCTAssertEqual(file.category, .photo)
        XCTAssertTrue(list.files[1].item.isFolder)
        XCTAssertEqual(list.files[1].item.size, 0)
    }

    func testRangeHeaderAndQueryEscaping() {
        XCTAssertEqual(GoogleDriveProvider.parseRangeHeader("bytes=0-524287"), 524287)
        XCTAssertNil(GoogleDriveProvider.parseRangeHeader(nil))
        XCTAssertEqual(GoogleDriveProvider.escape("Abian's \\ file"), "Abian\\'s \\\\ file")
        XCTAssertEqual(GoogleDriveProvider.chunkSize % (256 * 1024), 0, "Drive requires 256 KiB multiples")
    }

    func testExportFormatsForGoogleDocs() {
        XCTAssertEqual(GoogleDriveProvider.exportFormat(for: "application/vnd.google-apps.document")?.ext, "docx")
        XCTAssertEqual(GoogleDriveProvider.exportFormat(for: "application/vnd.google-apps.spreadsheet")?.ext, "xlsx")
        XCTAssertEqual(GoogleDriveProvider.exportFormat(for: "application/vnd.google-apps.presentation")?.ext, "pptx")
        XCTAssertEqual(GoogleDriveProvider.exportFormat(for: "application/vnd.google-apps.form")?.ext, "pdf")
        XCTAssertNil(GoogleDriveProvider.exportFormat(for: "application/vnd.google-apps.folder"))
        XCTAssertNil(GoogleDriveProvider.exportFormat(for: "image/png"))
    }

    func testErrorMapping() {
        let quota = Data(#"{"error":{"code":403,"message":"The user's Drive storage quota has been exceeded."}}"#.utf8)
        XCTAssertEqual(GoogleDriveProvider.mapError(quota, 403), .insufficientSpace)
        XCTAssertEqual(GoogleDriveProvider.mapError(Data(), 401), .sessionExpired)
        XCTAssertTrue(GoogleDriveProvider.mapError(Data(), 503).isTransient)
    }
}

final class TeraBoxParsingTests: XCTestCase {
    func testJsTokenExtraction() {
        let html = #"<script>var templateData = decodeURIComponent("%7B%22jsToken%22%3A%22x%22%7D");eval(decodeURIComponent(`fn%28%22ABCDEF0123456789%22%29`))</script>"#
        XCTAssertEqual(TeraBoxProvider.extractJsToken(fromHTML: html), "ABCDEF0123456789")
        XCTAssertEqual(TeraBoxProvider.extractJsToken(fromHTML: #"window.jsToken = "TOKEN42";"#), "TOKEN42")
        XCTAssertNil(TeraBoxProvider.extractJsToken(fromHTML: "<html></html>"))
    }

    func testListDecodingAndPaths() throws {
        let json = #"{"errno":0,"list":[{"fs_id":123,"path":"/Docs/a.pdf","server_filename":"a.pdf","size":10,"isdir":0,"server_mtime":1700000000,"md5":"m"},{"fs_id":5,"path":"/Docs/Sub","server_filename":"Sub","isdir":1}]}"#
        let list = try HTTP.decode(TeraBoxProvider.ListResponse.self, Data(json.utf8)).list ?? []
        XCTAssertEqual(list.count, 2)
        let file = list[0].item
        XCTAssertEqual(file.id, "/Docs/a.pdf")
        XCTAssertEqual(file.parentID, "/Docs")
        XCTAssertEqual(file.numericID, 123)
        XCTAssertEqual(file.category, .pdf)
        XCTAssertTrue(list[1].item.isFolder)
        XCTAssertEqual(TeraBoxProvider.join("/", "x"), "/x")
        XCTAssertEqual(TeraBoxProvider.join("/a", "x"), "/a/x")
    }

    func testErrnoMapping() {
        XCTAssertEqual(TeraBoxProvider.mapErrno(-6, nil), .sessionExpired)
        if case .notFound = TeraBoxProvider.mapErrno(-9, nil) {} else { XCTFail("expected notFound") }
        XCTAssertEqual(TeraBoxProvider.mapErrno(-10, nil), .insufficientSpace)
    }

    func testBlockChecksumsUse4MiBBlocks() throws {
        let data = TestSupport.randomData(TeraBoxProvider.blockSize * 2 + 100)
        let url = try TestSupport.tempFile(data)
        let blocks = try TeraBoxProvider.blockMD5s(of: url)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], FileHasher.md5Hex(of: data.prefix(TeraBoxProvider.blockSize)))
        XCTAssertEqual(blocks[2], FileHasher.md5Hex(of: data.suffix(100)))
        let empty = try TestSupport.tempFile(Data())
        XCTAssertEqual(try TeraBoxProvider.blockMD5s(of: empty), ["d41d8cd98f00b204e9800998ecf8427e"])
    }

    func testSessionCookieHeader() {
        let s = TeraBoxSession(cookies: ["ndus": "N", "csrfToken": "C"], userAgent: "UA", jsToken: nil, bdstoken: nil, host: "www.terabox.com", capturedAt: Date())
        XCTAssertEqual(s.cookieHeader, "csrfToken=C; ndus=N")
        XCTAssertTrue(s.isLoggedIn)
        XCTAssertTrue(TeraBoxWebStore.isTeraBoxDomain(".terabox.com"))
        XCTAssertTrue(TeraBoxWebStore.isTeraBoxDomain("www.1024tera.com"))
        XCTAssertFalse(TeraBoxWebStore.isTeraBoxDomain("google.com"))
    }
}

final class UtilityTests: XCTestCase {
    func testFileCategories() {
        XCTAssertEqual(FileCategory.from(filename: "IMG_0001.HEIC"), .photo)
        XCTAssertEqual(FileCategory.from(filename: "a.MOV"), .video)
        XCTAssertEqual(FileCategory.from(filename: "report.docx"), .document)
        XCTAssertEqual(FileCategory.from(filename: "budget.xlsx"), .spreadsheet)
        XCTAssertEqual(FileCategory.from(filename: "deck.pptx"), .presentation)
        XCTAssertEqual(FileCategory.from(filename: "x.rar"), .archive)
        XCTAssertEqual(FileCategory.from(filename: "app.ipa"), .app)
        XCTAssertEqual(FileCategory.from(filename: "data.json"), .code)
        XCTAssertEqual(FileCategory.from(filename: "x", mimeType: "audio/mpeg"), .audio)
        XCTAssertEqual(FileCategory.from(filename: "x", isFolder: true), .folder)
    }

    func testRetryPolicy() async throws {
        var attempts = 0
        let value = try await RetryPolicy(maxAttempts: 3, baseDelay: 0.01).run { () async throws -> Int in
            attempts += 1
            if attempts < 3 { throw AppError.network("flaky") }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(attempts, 3)

        attempts = 0
        do {
            _ = try await RetryPolicy(maxAttempts: 3, baseDelay: 0.01).run { () async throws -> Int in
                attempts += 1
                throw AppError.notFound("x")
            }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(attempts, 1, "non-transient errors are not retried")
        }
        XCTAssertEqual(RetryPolicy(baseDelay: 1, maxDelay: 30).delay(forAttempt: 10), 30)
    }

    func testUniqueURLAndSanitize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = AppPaths.uniqueURL(in: dir, name: "a.txt")
        try Data().write(to: first)
        XCTAssertEqual(AppPaths.uniqueURL(in: dir, name: "a.txt").lastPathComponent, "a (2).txt")
        XCTAssertEqual(AppPaths.sanitize("a/b:c?"), "a_b_c_")
        XCTAssertEqual(AppPaths.sanitize("   "), "untitled")
    }

    func testIndonesianLocalizationCoversFormatSpecifiers() throws {
        let path = try XCTUnwrap(Bundle(for: AccountManager.self).path(forResource: "id", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(bundle.localizedString(forKey: "Backup Now", value: nil, table: "Localizable"), "Cadangkan Sekarang")
        let f = bundle.localizedString(forKey: "%d uploaded, %d unchanged, %d failed", value: nil, table: "Localizable")
        XCTAssertEqual(String(format: f, 1, 2, 3), "1 diunggah, 2 tidak berubah, 3 gagal")
    }
}
