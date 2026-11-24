import XCTest
import CryptoKit
import WebKit
@testable import SimpleBrowser

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
}
