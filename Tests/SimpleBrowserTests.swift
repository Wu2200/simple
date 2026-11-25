import XCTest
import CryptoKit
import WebKit
@testable import SimpleBrowser

private final class MockOpenListURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var requestHandler: ((URLRequest, Data?) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 {
                    break
                }
                data.append(buffer, count: read)
            }
            bodyData = data
        }

        Self.lock.lock()
        let handler = Self.requestHandler
        Self.lock.unlock()

        guard let handler = handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockOpenList", code: -1))
            return
        }

        do {
            let (response, data) = try handler(request, bodyData)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class SimpleBrowserTests: XCTestCase {
    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private func buildStoredZip(entries: [(name: String, content: Data)]) -> Data {
        var zipData = Data()
        var centralDirectory = Data()
        var localOffsets: [UInt32] = []

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let localOffset = UInt32(zipData.count)
            localOffsets.append(localOffset)

            appendUInt32LE(0x04034b50, to: &zipData)
            appendUInt16LE(20, to: &zipData)
            appendUInt16LE(0, to: &zipData)
            appendUInt16LE(0, to: &zipData)
            appendUInt16LE(0, to: &zipData)
            appendUInt16LE(0, to: &zipData)
            appendUInt32LE(0, to: &zipData)
            appendUInt32LE(UInt32(entry.content.count), to: &zipData)
            appendUInt32LE(UInt32(entry.content.count), to: &zipData)
            appendUInt16LE(UInt16(nameData.count), to: &zipData)
            appendUInt16LE(0, to: &zipData)
            zipData.append(nameData)
            zipData.append(entry.content)
        }

        let cdOffset = UInt32(zipData.count)
        for (index, entry) in entries.enumerated() {
            let nameData = Data(entry.name.utf8)
            appendUInt32LE(0x02014b50, to: &centralDirectory)
            appendUInt16LE(20, to: &centralDirectory)
            appendUInt16LE(20, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt32LE(0, to: &centralDirectory)
            appendUInt32LE(UInt32(entry.content.count), to: &centralDirectory)
            appendUInt32LE(UInt32(entry.content.count), to: &centralDirectory)
            appendUInt16LE(UInt16(nameData.count), to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt32LE(0, to: &centralDirectory)
            appendUInt32LE(localOffsets[index], to: &centralDirectory)
            centralDirectory.append(nameData)
        }

        zipData.append(centralDirectory)
        appendUInt32LE(0x06054b50, to: &zipData)
        appendUInt16LE(0, to: &zipData)
        appendUInt16LE(0, to: &zipData)
        appendUInt16LE(UInt16(entries.count), to: &zipData)
        appendUInt16LE(UInt16(entries.count), to: &zipData)
        appendUInt32LE(UInt32(centralDirectory.count), to: &zipData)
        appendUInt32LE(cdOffset, to: &zipData)
        appendUInt16LE(0, to: &zipData)
        return zipData
    }

    private func makeMockOpenListSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockOpenListURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func jsonHTTPResponse(url: URL, statusCode: Int = 200, object: [String: Any]) -> (HTTPURLResponse, Data) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (response, data)
    }

    func testZipExtractorBlocksPathTraversalAndSiblingPrefixBypass() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("ZipTest_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        let targetDir = sandbox.appendingPathComponent("extract", isDirectory: true)
        let siblingDir = sandbox.appendingPathComponent("extract_evil", isDirectory: true)
        let archiveURL = sandbox.appendingPathComponent("sample.zip")

        let zipData = buildStoredZip(entries: [
            (name: "nested/hello.txt", content: Data("ok".utf8)),
            (name: "../escaped.txt", content: Data("bad1".utf8)),
            (name: "../extract_evil/pwn.txt", content: Data("bad2".utf8)),
            (name: "/abs.txt", content: Data("bad3".utf8))
        ])
        try zipData.write(to: archiveURL)

        try ZipExtractor.unzip(archiveURL: archiveURL, destinationURL: targetDir)

        let extractedFile = targetDir.appendingPathComponent("nested/hello.txt")
        XCTAssertTrue(fm.fileExists(atPath: extractedFile.path))
        XCTAssertEqual(try Data(contentsOf: extractedFile), Data("ok".utf8))
        XCTAssertFalse(fm.fileExists(atPath: sandbox.appendingPathComponent("escaped.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: siblingDir.appendingPathComponent("pwn.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: targetDir.appendingPathComponent("abs.txt").path))
    }

    func testAdBlockRuleParsingAndValidation() {
        let manager = AdBlockManager.shared

        let blockResult = manager.parseRule("||ads.example.com^$script,third-party")
        XCTAssertFalse(blockResult.isUnsupported)
        XCTAssertFalse(blockResult.isException)
        let trigger = blockResult.networkRule?["trigger"] as? [String: Any]
        XCTAssertEqual(trigger?["resource-type"] as? [String], ["script"])
        XCTAssertEqual(trigger?["load-type"] as? [String], ["third-party"])

        let broadException = manager.parseRule("@@||*^")
        XCTAssertTrue(broadException.isUnsupported)
        XCTAssertNil(broadException.networkRule)

        let cosmetic = manager.parseRule("example.com,~sub.example.com##.ad-banner")
        XCTAssertFalse(cosmetic.isUnsupported)
        XCTAssertEqual(cosmetic.cosmeticRules.count, 1)
        XCTAssertEqual(cosmetic.cosmeticRules.first?.domains, ["example.com"])
        XCTAssertEqual(cosmetic.cosmeticRules.first?.excludedDomains, ["sub.example.com"])
        XCTAssertEqual(cosmetic.cosmeticRules.first?.selector, ".ad-banner")

        let scriptlet = manager.parseRule("example.com##+js(set, foo, true)")
        XCTAssertTrue(scriptlet.isUnsupported)

        XCTAssertFalse(manager.isValidWebKitPattern("https://example.com/(?<=a)b"))
        XCTAssertFalse(manager.isValidWebKitPattern("\\d+"))
        XCTAssertTrue(manager.isValidWebKitPattern("^[a-z]+://([^/:]+\\.)?example\\.com"))
        XCTAssertFalse(manager.isValidWebKitDomain("*.example.com"))
        XCTAssertTrue(manager.isValidWebKitDomain("sub.example.com"))
    }

    func testDomainRelationAndCookieBoundaryMatching() {
        XCTAssertEqual(DomainRelationEngine.rootDomain(of: "api.v2.example.com"), "example.com")
        XCTAssertEqual(DomainRelationEngine.rootDomain(of: "news.sina.com.cn"), "sina.com.cn")
        XCTAssertEqual(DomainRelationEngine.rootDomain(of: "www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(DomainRelationEngine.rootDomain(of: "192.168.1.10"), "192.168.1.10")
        XCTAssertTrue(DomainRelationEngine.areDomainsAssociated("m.baidu.com", "tieba.baidu.com"))
        XCTAssertFalse(DomainRelationEngine.areDomainsAssociated("baidu.com", "google.com"))

        XCTAssertTrue(WebsiteCleaner.cookieDomain(".t.co", matchesRecordDomain: "t.co"))
        XCTAssertTrue(WebsiteCleaner.cookieDomain(".api.t.co", matchesRecordDomain: "t.co"))
        XCTAssertFalse(WebsiteCleaner.cookieDomain(".account.com", matchesRecordDomain: "t.co"))
        XCTAssertFalse(WebsiteCleaner.cookieDomain(".best.co", matchesRecordDomain: "t.co"))
    }

    func testUserScriptMetadataAndURLMatching() {
        let code = """
        // ==UserScript==
        // @name Example Script
        // @name:zh-CN 示例脚本
        // @namespace https://example.com
        // @version 1.2.3
        // @match https://*.example.com/app/*
        // @exclude https://admin.example.com/*
        // @run-at document-end
        // ==/UserScript==
        """

        let meta = UserScriptStore.shared.parseMetadata(from: code)
        XCTAssertEqual(meta.name, "示例脚本")
        XCTAssertEqual(meta.version, "1.2.3")
        XCTAssertEqual(meta.runAt, "document-end")
        XCTAssertTrue(UserScriptStore.shared.doesUrlMatchPattern(urlString: "https://sub.example.com/app/home", pattern: "https://*.example.com/app/*"))
        XCTAssertFalse(UserScriptStore.shared.doesUrlMatchPattern(urlString: "https://sub.example.com/other", pattern: "https://*.example.com/app/*"))

        let script = UserScript(
            id: "test-script",
            name: meta.name,
            matchPattern: meta.match,
            code: code,
            isEnabled: true,
            runAt: meta.runAt
        )
        XCTAssertTrue(UserScriptStore.shared.isScriptMatching(script: script, urlString: "https://sub.example.com/app/index"))
        XCTAssertFalse(UserScriptStore.shared.isScriptMatching(script: script, urlString: "https://admin.example.com/app/index"))
    }

    func testEncryptedBackupRoundTripAndTamperDetection() throws {
        let package = BrowserBackupPackage(
            version: 2,
            exportedAt: Date(timeIntervalSince1970: 1700000000),
            appName: "SimpleBrowser",
            bookmarks: [BookmarkItem(id: "b1", title: "Example", urlString: "https://example.com")],
            homeShortcuts: [HomeShortcutItem(id: "s1", title: "Example", urlString: "https://example.com")],
            history: nil,
            cookies: nil,
            userScripts: [],
            scriptData: ["script1": "{\"flag\":true}"],
            customUserAgents: [],
            adBlockSubscriptions: [],
            customAdBlockRules: "||ads.example.com^",
            lockedCookieDomains: ["example.com"],
            searchEngine: SearchEngine.google.rawValue,
            trustedInsecureHosts: []
        )

        let encryptedData = try BackupManager.shared.encryptBackupPackage(package, password: "secret-password")
        let inspected = try BackupManager.shared.inspectBackupData(encryptedData)

        guard case .encrypted(var envelope) = inspected else {
            XCTFail("Expected encrypted backup envelope")
            return
        }

        let restored = try BackupManager.shared.decryptBackupEnvelope(envelope, password: "secret-password")
        XCTAssertEqual(restored.bookmarks.first?.urlString, "https://example.com")
        XCTAssertEqual(restored.customAdBlockRules, "||ads.example.com^")
        XCTAssertEqual(restored.lockedCookieDomains, ["example.com"])

        XCTAssertThrowsError(try BackupManager.shared.decryptBackupEnvelope(envelope, password: "wrong-password")) { error in
            if case CryptoKitError.authenticationFailure = error {
                return
            }
            XCTFail("Expected CryptoKitError.authenticationFailure, got \(error)")
        }

        envelope.ciphertext[0] ^= 0xff
        XCTAssertThrowsError(try BackupManager.shared.decryptBackupEnvelope(envelope, password: "secret-password"))
    }

    func testTabItemForwardFromHomeAndExplicitLoadReset() {
        let tab = TabItem()
        XCTAssertTrue(tab.isOnHome)
        XCTAssertFalse(tab.canNavigateForwardFromHome)

        let pageURL = URL(string: "https://example.com/article")!
        tab.prepareForExplicitLoad(url: pageURL)
        tab.title = "Example Article"
        XCTAssertFalse(tab.isOnHome)
        XCTAssertFalse(tab.canNavigateForwardFromHome)

        tab.navigateToHome()
        XCTAssertTrue(tab.isOnHome)
        XCTAssertEqual(tab.title, "主页")
        XCTAssertNil(tab.snapshot)
        XCTAssertTrue(tab.canNavigateForwardFromHome)

        tab.navigateToHome()
        XCTAssertTrue(tab.isOnHome)
        XCTAssertTrue(tab.canNavigateForwardFromHome)

        let forwardResult = tab.prepareForwardNavigationFromHome()
        XCTAssertEqual(forwardResult, .needsLoad(pageURL))
        XCTAssertFalse(tab.isOnHome)
        XCTAssertEqual(tab.url, pageURL)
        XCTAssertEqual(tab.title, "Example Article")
        XCTAssertFalse(tab.canNavigateForwardFromHome)

        tab.navigateToHome()
        XCTAssertTrue(tab.canNavigateForwardFromHome)

        let nextURL = URL(string: "https://example.org/new")!
        tab.prepareForExplicitLoad(url: nextURL)
        XCTAssertFalse(tab.isOnHome)
        XCTAssertEqual(tab.url, nextURL)
        XCTAssertFalse(tab.canNavigateForwardFromHome)
    }

    func testBrowserViewControllerBackToHomeAndForwardAgain() {
        let vc = BrowserViewController()
        vc.loadViewIfNeeded()

        vc.showHomeUI()
        XCTAssertGreaterThan(vc.homeView.alpha, 0.5)
        XCTAssertFalse(vc.backButton.isEnabled)
        XCTAssertFalse(vc.forwardButton.isEnabled)

        let pageURL = URL(string: "https://example.com/home-test")!
        vc.load(url: pageURL)
        XCTAssertLessThan(vc.homeView.alpha, 0.5)
        XCTAssertTrue(vc.backButton.isEnabled)
        XCTAssertFalse(vc.forwardButton.isEnabled)
        XCTAssertEqual(vc.activeTab.url, pageURL)

        vc.goBack()
        XCTAssertGreaterThan(vc.homeView.alpha, 0.5)
        XCTAssertTrue(vc.activeTab.isOnHome)
        XCTAssertEqual(vc.activeTab.title, "主页")
        XCTAssertFalse(vc.backButton.isEnabled)
        XCTAssertTrue(vc.forwardButton.isEnabled)

        vc.goForward()
        XCTAssertLessThan(vc.homeView.alpha, 0.5)
        XCTAssertFalse(vc.activeTab.isOnHome)
        XCTAssertEqual(vc.activeTab.url, pageURL)
        XCTAssertTrue(vc.backButton.isEnabled)
        XCTAssertFalse(vc.forwardButton.isEnabled)
    }

    func testAdBlockCosmeticScriptPreparationAndCustomRuleCompilation() {
        let manager = AdBlockManager.shared
        let metadata = AdBlockCompiledSourceMetadata(
            sourceId: "test-source",
            ruleListIdentifiers: [],
            ruleCount: 3,
            skippedRuleCount: 0,
            cosmeticRules: [
                AdBlockCosmeticRule(domains: [], excludedDomains: [], selector: ".global-ad"),
                AdBlockCosmeticRule(domains: ["example.com"], excludedDomains: ["sub.example.com"], selector: ".sponsored")
            ],
            cosmeticExceptions: [
                AdBlockCosmeticException(domains: ["example.com"], selector: ".allowed-ad")
            ],
            contentHash: "hash-test"
        )

        let bgExpectation = expectation(description: "prepare cosmetic scripts on background queue")
        var prepared: AdBlockManager.PreparedCosmeticScripts?
        DispatchQueue.global(qos: .userInitiated).async {
            prepared = manager.prepareCosmeticScripts(metadata: metadata)
            bgExpectation.fulfill()
        }
        wait(for: [bgExpectation], timeout: 5.0)

        XCTAssertNotNil(prepared)
        XCTAssertNotNil(prepared?.exceptionSource)
        XCTAssertEqual(prepared?.scriptSources.count, 1)
        XCTAssertGreaterThan(prepared?.totalChars ?? 0, 0)

        let originalRules = manager.getCustomRules()
        let wasEnabled = manager.isEnabled
        manager.isEnabled = true

        let saveExpectation = expectation(description: "save custom cosmetic rules")
        var saveSuccess = false
        manager.saveCustomRules("example.com##.ad-banner\nexample.com#@#.allow-banner") { success, _ in
            saveSuccess = success
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 10.0)

        XCTAssertTrue(saveSuccess)
        let activeScripts = manager.activeCosmeticScripts(for: "example.com")
        XCTAssertEqual(activeScripts.count, 3)
        XCTAssertTrue(activeScripts.allSatisfy { $0.injectionTime == .atDocumentStart })

        let restoreExpectation = expectation(description: "restore original custom rules")
        manager.saveCustomRules(originalRules) { _, _ in
            restoreExpectation.fulfill()
        }
        wait(for: [restoreExpectation], timeout: 10.0)
        manager.isEnabled = wasEnabled
    }

    func testTabItemHandlesBackgroundUserScriptsUpdatedNotification() {
        let tab = TabItem()
        let notifiedExpectation = expectation(description: "background notification handled on main thread")

        DispatchQueue.global(qos: .userInitiated).async {
            NotificationCenter.default.post(name: UserScriptStore.didUpdateScriptsNotification, object: nil)
            DispatchQueue.main.async {
                notifiedExpectation.fulfill()
            }
        }

        wait(for: [notifiedExpectation], timeout: 5.0)
        tab.destroy()
    }

    func testAutoBackupDefaultsAndPathNormalization() {
        let defaults = OpenListBackupConfig.defaultConfig()
        XCTAssertEqual(defaults.intervalHours, 24)
        XCTAssertFalse(defaults.isEnabled)
        XCTAssertEqual(defaults.remoteDirectory, "/SimpleBrowserBackups")
        XCTAssertEqual(AutoBackupManager.defaultRetryDelay, 60.0)

        XCTAssertEqual(OpenListClient.normalizeRemoteDirectory("  backups\\browser/  "), "/backups/browser")
        XCTAssertEqual(OpenListClient.normalizeRemoteDirectory("///"), "/")
        XCTAssertEqual(OpenListClient.fullRemoteFilePath(directory: "备份/浏览器", fileName: "backup.json"), "/备份/浏览器/backup.json")
        XCTAssertEqual(OpenListClient.encodeOpenListPathHeader("/备份/a b.json"), "/%E5%A4%87%E4%BB%BD/a%20b.json")

        let apiURL = OpenListClient.normalizeServerURL("192.168.1.10:5244/")
        XCTAssertEqual(apiURL?.absoluteString, "http://192.168.1.10:5244")
        XCTAssertEqual(OpenListClient.detectProtocolMode(for: apiURL!), .openListAPI)

        let davURL = OpenListClient.normalizeServerURL("https://pan.example.com/dav/")
        XCTAssertEqual(OpenListClient.detectProtocolMode(for: davURL!), .webDAV)
    }

    func testOpenListClientAPILoginMkdirAndTokenRefreshUpload() {
        let client = OpenListClient(session: makeMockOpenListSession())
        var loginCount = 0
        var mkdirPaths: [String] = []
        var putAttempts = 0
        var uploadedBody: Data?
        var uploadedFilePathHeader: String?
        var uploadedAuthHeader: String?

        MockOpenListURLProtocol.lock.lock()
        MockOpenListURLProtocol.requestHandler = { [self] request, body in
            let url = request.url!
            let path = url.path

            if path.hasSuffix("/api/auth/login") {
                loginCount += 1
                let token = loginCount == 1 ? "stale-jwt-token" : "fresh-jwt-token"
                return jsonHTTPResponse(url: url, object: ["code": 200, "message": "success", "data": ["token": token]])
            }

            if path.hasSuffix("/api/fs/get") {
                return jsonHTTPResponse(url: url, object: ["code": 500, "message": "object not found"])
            }

            if path.hasSuffix("/api/fs/mkdir") {
                if let body = body,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let dirPath = json["path"] as? String {
                    mkdirPaths.append(dirPath)
                }
                return jsonHTTPResponse(url: url, object: ["code": 200, "message": "success"])
            }

            if path.hasSuffix("/api/fs/put") {
                putAttempts += 1
                let auth = request.value(forHTTPHeaderField: "Authorization")
                if putAttempts == 1 && auth == "stale-jwt-token" {
                    return jsonHTTPResponse(url: url, object: ["code": 401, "message": "token expired"])
                }
                uploadedAuthHeader = auth
                uploadedFilePathHeader = request.value(forHTTPHeaderField: "File-Path")
                uploadedBody = body
                return jsonHTTPResponse(url: url, object: ["code": 200, "message": "success"])
            }

            return jsonHTTPResponse(url: url, statusCode: 404, object: ["code": 404, "message": "not found"])
        }
        MockOpenListURLProtocol.lock.unlock()
        defer {
            MockOpenListURLProtocol.lock.lock()
            MockOpenListURLProtocol.requestHandler = nil
            MockOpenListURLProtocol.lock.unlock()
        }

        let payload = Data("{\"hello\":\"openlist\"}".utf8)
        let exp = expectation(description: "OpenList API upload with token refresh")
        var resultPath: String?
        var resultError: Error?

        client.uploadFile(
            data: payload,
            fileName: "Simple_Backup.json",
            serverURLString: "https://pan.example.com/sub",
            username: "admin",
            passwordOrToken: "secret",
            remoteDirectory: "浏览器/备份"
        ) { result in
            switch result {
            case .success(let path):
                resultPath = path
            case .failure(let error):
                resultError = error
            }
            exp.fulfill()
        }

        wait(for: [exp], timeout: 5.0)

        XCTAssertNil(resultError)
        XCTAssertEqual(resultPath, "/浏览器/备份/Simple_Backup.json")
        XCTAssertEqual(loginCount, 2)
        XCTAssertEqual(mkdirPaths, ["/浏览器", "/浏览器/备份"])
        XCTAssertEqual(putAttempts, 2)
        XCTAssertEqual(uploadedAuthHeader, "fresh-jwt-token")
        XCTAssertEqual(uploadedFilePathHeader, "/%E6%B5%8F%E8%A7%88%E5%99%A8/%E5%A4%87%E4%BB%BD/Simple_Backup.json")
        XCTAssertEqual(uploadedBody, payload)
    }

    func testOpenListClientWebDAVUpload() {
        let client = OpenListClient(session: makeMockOpenListSession())
        var mkcolURLs: [String] = []
        var putURL: String?
        var putAuth: String?

        MockOpenListURLProtocol.lock.lock()
        MockOpenListURLProtocol.requestHandler = { request, _ in
            let url = request.url!
            if request.httpMethod == "MKCOL" {
                mkcolURLs.append(url.path)
                return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
            if request.httpMethod == "PUT" {
                putURL = url.path
                putAuth = request.value(forHTTPHeaderField: "Authorization")
                return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: url, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        MockOpenListURLProtocol.lock.unlock()
        defer {
            MockOpenListURLProtocol.lock.lock()
            MockOpenListURLProtocol.requestHandler = nil
            MockOpenListURLProtocol.lock.unlock()
        }

        let exp = expectation(description: "WebDAV upload")
        var uploadedPath: String?

        client.uploadFile(
            data: Data("{}".utf8),
            fileName: "backup.json",
            serverURLString: "https://pan.example.com/dav",
            username: "davuser",
            passwordOrToken: "davpass",
            remoteDirectory: "/Backups/Browser"
        ) { result in
            if case .success(let path) = result {
                uploadedPath = path
            }
            exp.fulfill()
        }

        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(uploadedPath, "/Backups/Browser/backup.json")
        XCTAssertEqual(mkcolURLs, ["/dav/Backups", "/dav/Backups/Browser"])
        XCTAssertEqual(putURL, "/dav/Backups/Browser/backup.json")
        let expectedBasic = "Basic " + Data("davuser:davpass".utf8).base64EncodedString()
        XCTAssertEqual(putAuth, expectedBasic)
    }

    func testAutoBackupFailureSchedulesRetryAndRecovers() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("AutoBackupTest_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("config.json")
        let credStore = InMemoryCredentialStore()
        let client = OpenListClient(session: makeMockOpenListSession())

        var uploadAttempt = 0
        let firstFailureExp = expectation(description: "first upload fails")
        let retrySuccessExp = expectation(description: "retry upload succeeds")

        MockOpenListURLProtocol.lock.lock()
        MockOpenListURLProtocol.requestHandler = { [self] request, _ in
            let url = request.url!
            if url.path.hasSuffix("/api/fs/get") {
                return jsonHTTPResponse(url: url, object: ["code": 200, "data": ["is_dir": true]])
            }
            if url.path.hasSuffix("/api/fs/put") {
                uploadAttempt += 1
                if uploadAttempt == 1 {
                    return jsonHTTPResponse(url: url, statusCode: 503, object: ["code": 503, "message": "temporary unavailable"])
                }
                return jsonHTTPResponse(url: url, object: ["code": 200, "message": "success"])
            }
            return jsonHTTPResponse(url: url, statusCode: 404, object: ["code": 404, "message": "not found"])
        }
        MockOpenListURLProtocol.lock.unlock()
        defer {
            MockOpenListURLProtocol.lock.lock()
            MockOpenListURLProtocol.requestHandler = nil
            MockOpenListURLProtocol.lock.unlock()
        }

        let manager = AutoBackupManager(
            configFileURL: configURL,
            credentialStore: credStore,
            client: client,
            retryDelay: 0.25,
            maxAutomaticRetries: 3,
            enableBackgroundTasks: false,
            backupDataGenerator: { _, completion in
                completion(.success(("SimpleBrowser_Backup_test.json", Data("{\"ok\":true}".utf8))))
            }
        )

        var sawFailureStatus = false
        let observer = NotificationCenter.default.addObserver(
            forName: AutoBackupManager.statusDidChangeNotification,
            object: manager,
            queue: .main
        ) { _ in
            let snap = manager.statusSnapshot
            if !snap.isUploading && snap.config.lastErrorMessage != nil && snap.isWaitingForRetry && !sawFailureStatus {
                sawFailureStatus = true
                XCTAssertNotNil(snap.pendingRetryDate)
                XCTAssertEqual(snap.retryAttemptCount, 1)
                firstFailureExp.fulfill()
            } else if !snap.isUploading && snap.config.lastSuccessDate != nil && snap.config.lastErrorMessage == nil && !snap.isWaitingForRetry {
                retrySuccessExp.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        manager.updateConfiguration(
            isEnabled: true,
            serverURL: "https://pan.example.com",
            username: "",
            passwordOrToken: "static-api-token",
            remoteDirectory: "/Backups",
            intervalHours: 24,
            backupPassword: "",
            triggerIfDue: true
        )

        wait(for: [firstFailureExp, retrySuccessExp], timeout: 5.0)

        let finalSnapshot = manager.statusSnapshot
        XCTAssertEqual(uploadAttempt, 2)
        XCTAssertNotNil(finalSnapshot.config.lastSuccessDate)
        XCTAssertNil(finalSnapshot.config.lastErrorMessage)
        XCTAssertFalse(finalSnapshot.isWaitingForRetry)
        XCTAssertEqual(finalSnapshot.config.lastUploadedFileName, "SimpleBrowser_Backup_test.json")
    }
}
