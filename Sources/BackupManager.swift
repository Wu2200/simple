import UIKit
import WebKit
import UniformTypeIdentifiers
import CryptoKit
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

struct EncryptedBackupEnvelope: Codable {
    var format: String
    var version: Int
    var iterations: Int
    var salt: Data
    var nonce: Data
    var ciphertext: Data
    var tag: Data
}

enum BackupInspectionResult {
    case plain(BrowserBackupPackage)
    case encrypted(EncryptedBackupEnvelope)
}

final class BackupManager {
    static let shared = BackupManager()
    private static let encryptedFormatIdentifier = "SimpleBrowserEncryptedBackup"
    private static let defaultPBKDF2Iterations = 60000
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

    private static func deriveKey(password: String, salt: Data, iterations: Int) -> SymmetricKey {
        let key = SymmetricKey(data: Data(password.utf8))
        var blockIndexData = Data(count: 4)
        var bigEndian = UInt32(1).bigEndian
        withUnsafeBytes(of: &bigEndian) { raw in
            blockIndexData.replaceSubrange(0..<4, with: raw)
        }

        var input = salt
        input.append(blockIndexData)

        var u = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
        var dk = u
        if iterations > 1 {
            for _ in 1..<iterations {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                dk.withUnsafeMutableBytes { (dkBytes: UnsafeMutableRawBufferPointer) in
                    u.withUnsafeBytes { (uBytes: UnsafeRawBufferPointer) in
                        for idx in 0..<dkBytes.count {
                            dkBytes[idx] ^= uBytes[idx]
                        }
                    }
                }
            }
        }
        return SymmetricKey(data: dk)
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
            DispatchQueue.global(qos: .userInitiated).async {
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
    }

    func encryptBackupPackage(_ package: BrowserBackupPackage, password: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let plainData = try encoder.encode(package)

        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let iterations = Self.defaultPBKDF2Iterations
        let key = Self.deriveKey(password: password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plainData, using: key)

        let envelope = EncryptedBackupEnvelope(
            format: Self.encryptedFormatIdentifier,
            version: 1,
            iterations: iterations,
            salt: salt,
            nonce: Data(sealed.nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )

        let envelopeEncoder = JSONEncoder()
        envelopeEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try envelopeEncoder.encode(envelope)
    }

    func decryptBackupEnvelope(_ envelope: EncryptedBackupEnvelope, password: String) throws -> BrowserBackupPackage {
        guard envelope.iterations >= 1000 && envelope.iterations <= 500000 else {
            throw NSError(domain: "BackupManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "加密备份参数异常"])
        }
        let key = Self.deriveKey(password: password, salt: envelope.salt, iterations: envelope.iterations)
        let nonce = try AES.GCM.Nonce(data: envelope.nonce)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: envelope.ciphertext, tag: envelope.tag)
        let plainData = try AES.GCM.open(sealed, using: key)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BrowserBackupPackage.self, from: plainData)
    }

    func exportEncryptedBackupFile(password: String, completion: @escaping (Result<URL, Error>) -> Void) {
        let appName = currentApplicationName()
        createBackupPackage { package in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let outputData = try self.encryptBackupPackage(package, password: password)

                    let df = DateFormatter()
                    df.dateFormat = "yyyyMMdd_HHmmss"
                    let timestamp = df.string(from: Date())
                    let filename = "\(appName)_EncryptedBackup_\(timestamp).json"

                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                    try outputData.write(to: tempURL, options: .atomic)
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
    }

    func inspectBackupData(_ data: Data) throws -> BackupInspectionResult {
        if let envelope = try? JSONDecoder().decode(EncryptedBackupEnvelope.self, from: data),
           envelope.format == Self.encryptedFormatIdentifier {
            return .encrypted(envelope)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(BrowserBackupPackage.self, from: data)
        return .plain(package)
    }

    func restore(fromEncryptedEnvelope envelope: EncryptedBackupEnvelope, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let package = try self.decryptBackupEnvelope(envelope, password: password)
                self.applyBackupPackage(package, completion: completion)
            } catch CryptoKitError.authenticationFailure {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "BackupManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "备份密码错误或文件已被篡改"])))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func restore(from package: BrowserBackupPackage, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.applyBackupPackage(package, completion: completion)
        }
    }

    func restore(from fileURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let package = try decoder.decode(BrowserBackupPackage.self, from: data)
                self.applyBackupPackage(package, completion: completion)
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private func applyBackupPackage(_ package: BrowserBackupPackage, completion: @escaping (Result<Void, Error>) -> Void) {
        BookmarkStore.shared.saveAllNodes(package.bookmarks)
        HomeShortcutStore.shared.saveAllShortcuts(package.homeShortcuts)

        if let hist = package.history {
            BrowserHistoryStore.shared.saveAllHistory(hist)
        }

        UserScriptStore.shared.saveScripts(package.userScripts)

        ScriptDataStore.shared.clearAllScriptData()
        for (scriptId, jsonStr) in package.scriptData {
            if let data = jsonStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in dict {
                    ScriptDataStore.shared.setValue(scriptId: scriptId, name: k, value: v)
                }
            }
        }

        UserAgentStore.shared.restoreCustomItems(package.customUserAgents)

        AdBlockManager.shared.saveSubscriptions(package.adBlockSubscriptions)
        AdBlockManager.shared.restoreCustomRulesFromBackup(package.customAdBlockRules)
        CookieLockStore.shared.restoreLockedDomains(package.lockedCookieDomains)

        if let engine = SearchEngine(rawValue: package.searchEngine) {
            SearchEngineStore.shared.currentEngine = engine
        }

        if let trustedHosts = package.trustedInsecureHosts {
            CertificateTrustStore.shared.restoreTrustedHosts(trustedHosts)
        }

        let cookiesToRestore = package.cookies?.compactMap { $0.toHTTPCookie() } ?? []
        for cookie in cookiesToRestore {
            HTTPCookieStorage.shared.setCookie(cookie)
        }

        DispatchQueue.main.async {
            let cookieStore = WKWebsiteDataStore.default().httpCookieStore
            let group = DispatchGroup()

            for cookie in cookiesToRestore {
                group.enter()
                cookieStore.setCookie(cookie) {
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                completion(.success(()))
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
            self?.presentExportModePicker()
        })

        sheet.addAction(UIAlertAction(title: "恢复文件", style: .default) { [weak self] _ in
            self?.presentDocumentPickerForRestore()
        })

        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }

    private func presentExportModePicker() {
        let sheet = UIAlertController(
            title: "选择导出方式",
            message: "备份中包含网站登录 Cookies 与脚本数据，建议使用密码加密导出以保护隐私安全。",
            preferredStyle: .actionSheet
        )

        sheet.addAction(UIAlertAction(title: "加密导出（推荐）", style: .default) { [weak self] _ in
            self?.promptEncryptedBackupPassword()
        })

        sheet.addAction(UIAlertAction(title: "明文导出 (JSON)", style: .default) { [weak self] _ in
            self?.performExportBackup()
        })

        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }

    private func promptEncryptedBackupPassword() {
        let alert = UIAlertController(
            title: "设置备份密码",
            message: "请输入用于加密备份文件的密码（至少 4 个字符），恢复时需要此密码。",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.placeholder = "输入密码"
            tf.isSecureTextEntry = true
        }
        alert.addTextField { tf in
            tf.placeholder = "再次确认密码"
            tf.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "加密并导出", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { return }
            let pwd1 = alert?.textFields?[0].text ?? ""
            let pwd2 = alert?.textFields?[1].text ?? ""
            guard pwd1.count >= 4 else {
                self.showToastNotice("密码长度不能少于 4 位")
                return
            }
            guard pwd1 == pwd2 else {
                self.showToastNotice("两次输入的密码不一致")
                return
            }
            self.performExportEncryptedBackup(password: pwd1)
        })
        present(alert, animated: true)
    }

    private func presentExportedFile(_ fileURL: URL) {
        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = self.view
            popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        self.present(activityVC, animated: true)
    }

    func performExportBackup() {
        BackupManager.shared.exportBackupFile { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let fileURL):
                self.presentExportedFile(fileURL)
            case .failure(let error):
                self.showToastNotice("导出备份失败: \(error.localizedDescription)")
            }
        }
    }

    func performExportEncryptedBackup(password: String) {
        BackupManager.shared.exportEncryptedBackupFile(password: password) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let fileURL):
                self.presentExportedFile(fileURL)
            case .failure(let error):
                self.showToastNotice("加密导出失败: \(error.localizedDescription)")
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
        let fileData: Data
        do {
            fileData = try Data(contentsOf: selectedURL)
        } catch {
            if shouldAccess {
                selectedURL.stopAccessingSecurityScopedResource()
            }
            let errAlert = UIAlertController(
                title: "读取失败",
                message: "无法读取所选备份文件：\(error.localizedDescription)",
                preferredStyle: .alert
            )
            errAlert.addAction(UIAlertAction(title: "确定", style: .default))
            present(errAlert, animated: true)
            return
        }
        if shouldAccess {
            selectedURL.stopAccessingSecurityScopedResource()
        }

        do {
            let inspection = try BackupManager.shared.inspectBackupData(fileData)
            switch inspection {
            case .plain(let package):
                confirmRestorePlainBackup(package)
            case .encrypted(let envelope):
                promptPasswordAndRestoreEncryptedBackup(envelope)
            }
        } catch {
            let errAlert = UIAlertController(
                title: "恢复失败",
                message: "备份文件解析错误或格式无效：\(error.localizedDescription)",
                preferredStyle: .alert
            )
            errAlert.addAction(UIAlertAction(title: "确定", style: .default))
            present(errAlert, animated: true)
        }
    }

    private func confirmRestorePlainBackup(_ package: BrowserBackupPackage) {
        let alert = UIAlertController(
            title: "恢复备份确认",
            message: "确定要从选择的备份文件恢复吗？\n当前的所有数据将被该备份文件恢复替换。",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "确认恢复", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            BackupManager.shared.restore(from: package) { [weak self] result in
                self?.handleBackupRestoreCompletion(result)
            }
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func promptPasswordAndRestoreEncryptedBackup(_ envelope: EncryptedBackupEnvelope, errorMessage: String? = nil) {
        let msg = errorMessage ?? "该备份文件已加密，请输入密码并确认恢复。\n注意：当前的所有数据将被该备份文件恢复替换。"
        let alert = UIAlertController(
            title: "解锁加密备份",
            message: msg,
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.placeholder = "请输入备份密码"
            tf.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "解密并恢复", style: .destructive) { [weak self, weak alert] _ in
            guard let self = self else { return }
            let password = alert?.textFields?.first?.text ?? ""
            BackupManager.shared.restore(fromEncryptedEnvelope: envelope, password: password) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    self.handleBackupRestoreCompletion(.success(()))
                case .failure(let error):
                    self.promptPasswordAndRestoreEncryptedBackup(envelope, errorMessage: error.localizedDescription)
                }
            }
        })
        present(alert, animated: true)
    }

    private func handleBackupRestoreCompletion(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            reloadHomeShortcuts()
            activeTab.reloadUserScripts()
            AdBlockManager.shared.reloadAfterBackupRestore()
            showToastNotice("数据恢复成功")
        case .failure(let error):
            let errAlert = UIAlertController(
                title: "恢复失败",
                message: "备份文件解析错误或格式无效：\(error.localizedDescription)",
                preferredStyle: .alert
            )
            errAlert.addAction(UIAlertAction(title: "确定", style: .default))
            present(errAlert, animated: true)
        }
    }
}
