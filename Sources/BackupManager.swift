import UIKit
import WebKit
import UniformTypeIdentifiers

struct BackupCookieItem: Codable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expiresDate: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool

    init(from cookie: HTTPCookie) {
        self.name = cookie.name
        self.value = cookie.value
        self.domain = cookie.domain
        self.path = cookie.path
        self.expiresDate = cookie.expiresDate
        self.isSecure = cookie.isSecure
        self.isHTTPOnly = cookie.isHTTPOnly
    }

    func toHTTPCookie() -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path
        ]
        if let exp = expiresDate {
            props[.expires] = exp
        }
        if isSecure {
            props[.secure] = "TRUE"
        }
        if isHTTPOnly {
            props[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE"
        }
        return HTTPCookie(properties: props)
    }
}

struct BrowserBackupPackage: Codable {
    var version: Int
    var exportedAt: Date
    var appName: String
    var bookmarks: [BookmarkItem]
    var homeShortcuts: [HomeShortcutItem]
    var history: [BrowserHistoryItem]?
    var cookies: [BackupCookieItem]?
    var userScripts: [UserScript]
    var scriptData: [String: String]
    var customUserAgents: [UserAgentItem]
    var adBlockSubscriptions: [AdBlockSubscription]
    var customAdBlockRules: String
    var lockedCookieDomains: [String]
    var searchEngine: String
    var trustedInsecureHosts: [String]?
}

final class BackupManager {
    static let shared = BackupManager()
    private init() {}

    func currentApplicationName() -> String {
        let bundle = Bundle.main
        let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? "SimpleBrowser"
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "SimpleBrowser"
        }
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let sanitized = trimmed.components(separatedBy: invalidCharacters).joined()
        return sanitized.isEmpty ? "SimpleBrowser" : sanitized
    }

    func createBackupPackage(completion: @escaping (BrowserBackupPackage) -> Void) {
        let appName = currentApplicationName()
        let bookmarks = BookmarkStore.shared.loadAllNodes()
        let shortcuts = HomeShortcutStore.shared.loadShortcuts()
        let history = BrowserHistoryStore.shared.loadHistory()
        let scripts = UserScriptStore.shared.loadScripts()

        var scriptDataMap: [String: String] = [:]
        for script in scripts {
            let json = ScriptDataStore.shared.getAllValuesJSON(scriptId: script.id)
            if json != "{}" {
                scriptDataMap[script.id] = json
            }
        }

        let customUAs = UserAgentStore.shared.loadCustomItems()
        let subscriptions = AdBlockManager.shared.loadSubscriptions()
        let customRules = AdBlockManager.shared.getCustomRules()
        let lockedDomains = CookieLockStore.shared.getLockedDomains()
        let searchEngine = SearchEngineStore.shared.currentEngine.rawValue
        let trustedInsecureHosts = CertificateTrustStore.shared.getAllTrustedHosts()

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var cookieMap: [String: BackupCookieItem] = [:]
            for c in cookies {
                let key = "\(c.domain)_\(c.path)_\(c.name)"
                cookieMap[key] = BackupCookieItem(from: c)
            }
            if let sharedCookies = HTTPCookieStorage.shared.cookies {
                for c in sharedCookies {
                    let key = "\(c.domain)_\(c.path)_\(c.name)"
                    if cookieMap[key] == nil {
                        cookieMap[key] = BackupCookieItem(from: c)
                    }
                }
            }
            let backupCookies = Array(cookieMap.values)

            let package = BrowserBackupPackage(
                version: 2,
                exportedAt: Date(),
                appName: appName,
                bookmarks: bookmarks,
                homeShortcuts: shortcuts,
                history: history,
                cookies: backupCookies,
                userScripts: scripts,
                scriptData: scriptDataMap,
                customUserAgents: customUAs,
                adBlockSubscriptions: subscriptions,
                customAdBlockRules: customRules,
                lockedCookieDomains: lockedDomains,
                searchEngine: searchEngine,
                trustedInsecureHosts: trustedInsecureHosts
            )
            completion(package)
        }
    }

    func exportBackupFile(completion: @escaping (Result<URL, Error>) -> Void) {
        let appName = currentApplicationName()
        createBackupPackage { package in
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(package)

                let df = DateFormatter()
                df.dateFormat = "yyyyMMdd_HHmmss"
                let timestamp = df.string(from: Date())
                let filename = "\(appName)_Backup_\(timestamp).json"

                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try data.write(to: tempURL, options: .atomic)
                DispatchQueue.main.async {
                    completion(.success(tempURL))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func restore(from fileURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let package = try decoder.decode(BrowserBackupPackage.self, from: data)

                BookmarkStore.shared.saveAllNodes(package.bookmarks)
                HomeShortcutStore.shared.saveAllShortcuts(package.homeShortcuts)

                if let hist = package.history {
                    BrowserHistoryStore.shared.saveAllHistory(hist)
                }

                UserScriptStore.shared.saveScripts(package.userScripts)

                for (scriptId, jsonStr) in package.scriptData {
                    if let data = jsonStr.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        for (k, v) in dict {
                            ScriptDataStore.shared.setValue(scriptId: scriptId, name: k, value: v)
                        }
                    }
                }

                if let dataUA = try? JSONEncoder().encode(package.customUserAgents) {
                    UserDefaults.standard.set(dataUA, forKey: "browser_ua_custom_items_v5")
                }

                AdBlockManager.shared.saveSubscriptions(package.adBlockSubscriptions)
                UserDefaults.standard.set(package.customAdBlockRules, forKey: "adblock_custom_rules_v2")
                UserDefaults.standard.set(package.lockedCookieDomains, forKey: "locked_cookie_domains_v2")

                if let engine = SearchEngine(rawValue: package.searchEngine) {
                    SearchEngineStore.shared.currentEngine = engine
                }

                if let trustedHosts = package.trustedInsecureHosts {
                    CertificateTrustStore.shared.restoreTrustedHosts(trustedHosts)
                }

                let cookiesToRestore = package.cookies?.compactMap { $0.toHTTPCookie() } ?? []
                let cookieStore = WKWebsiteDataStore.default().httpCookieStore
                let group = DispatchGroup()

                for cookie in cookiesToRestore {
                    group.enter()
                    cookieStore.setCookie(cookie) {
                        group.leave()
                    }
                    HTTPCookieStorage.shared.setCookie(cookie)
                }

                group.notify(queue: .main) {
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
}

extension BrowserViewController {
    func showBackupActionSheet() {
        let sheet = UIAlertController(
            title: "数据备份与恢复",
            message: "可将书签、主页站点、浏览记录、网站登录信息、脚本与拦截规则等打包导出，或使用备份文件进行恢复。",
            preferredStyle: .actionSheet
        )

        sheet.addAction(UIAlertAction(title: "备份文件", style: .default) { [weak self] _ in
            self?.performExportBackup()
        })

        sheet.addAction(UIAlertAction(title: "恢复文件", style: .default) { [weak self] _ in
            self?.presentDocumentPickerForRestore()
        })

        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }

    func performExportBackup() {
        BackupManager.shared.exportBackupFile { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let fileURL):
                let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                if let popover = activityVC.popoverPresentationController {
                    popover.sourceView = self.view
                    popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
                self.present(activityVC, animated: true)
            case .failure(let error):
                self.showToastNotice("导出备份失败: \(error.localizedDescription)")
            }
        }
    }

    func presentDocumentPickerForRestore() {
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .data, .item], asCopy: true)
        } else {
            picker = UIDocumentPickerViewController(documentTypes: ["public.json", "public.item"], in: .import)
        }
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let selectedURL = urls.first else { return }
        let shouldAccess = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if shouldAccess {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }

        let alert = UIAlertController(
            title: "恢复备份确认",
            message: "确定要从选择的备份文件恢复吗？\n当前的所有数据将被该备份文件恢复替换。",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "确认恢复", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            BackupManager.shared.restore(from: selectedURL) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    self.reloadHomeShortcuts()
                    self.activeTab.reloadUserScripts()
                    AdBlockManager.shared.applyRules(to: self.activeTab.webView)
                    self.showToastNotice("数据恢复成功")
                case .failure(let error):
                    let errAlert = UIAlertController(
                        title: "恢复失败",
                        message: "备份文件解析错误或格式无效：\(error.localizedDescription)",
                        preferredStyle: .alert
                    )
                    errAlert.addAction(UIAlertAction(title: "确定", style: .default))
                    self.present(errAlert, animated: true)
                }
            }
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}
