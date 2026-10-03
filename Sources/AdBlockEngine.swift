import UIKit
import WebKit

struct AdBlockSubscription: Codable, Equatable {
    var id: String
    var name: String
    var urlString: String
    var isEnabled: Bool
    var lastUpdated: Date?
    var ruleCount: Int
}

final class AdBlockManager {
    static let shared = AdBlockManager()

    static let customSourceId = "__custom_rules__"

    private let enabledKey = "adblock_enabled_v2"
    private let subscriptionsKey = "adblock_subscriptions_v2"
    private let customRulesKey = "adblock_custom_rules_v2"
    private let identifierPrefix = "SimpleAdBlockRule"

    private let nativeRuleChunkSize = 8000
    private let maximumCosmeticRulesPerSource = 30000
    private let maximumCompilationDuration: TimeInterval = 180
    private let autoUpdateInterval: TimeInterval = 86400
    private let autoUpdateRetryCooldown: TimeInterval = 1800

    private var attachedWebViews = NSHashTable<WKWebView>.weakObjects()
    private var compiledListsBySource: [String: [WKContentRuleList]] = [:]
    private var cosmeticScriptsBySource: [String: [WKUserScript]] = [:]
    private var metadataBySource: [String: AdBlockCompiledSourceMetadata] = [:]
    private var updatingSourceIds = Set<String>()
    private var updateStatusBySource: [String: String] = [:]
    private var lastAutoUpdateAttemptBySource: [String: Date] = [:]
    private let parseQueue = DispatchQueue(label: "SimpleBrowser.AdBlockParser", qos: .userInitiated)
    private let stateLock = NSLock()

    var isEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            applyRulesToAttachedWebViews()
            if newValue {
                checkAndAutoUpdateSubscriptions()
            }
        }
    }

    private var storageDirectoryURL: URL {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = urls[0].appendingPathComponent("AdBlockEngine", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir
    }

    private func metadataFileURL(sourceId: String) -> URL {
        storageDirectoryURL.appendingPathComponent("meta_\(sourceId).json")
    }

    private func cosmeticScriptFileURL(sourceId: String) -> URL {
        storageDirectoryURL.appendingPathComponent("cosmetic_\(sourceId).js")
    }

    private func diagnosticFileURL(sourceId: String) -> URL {
        storageDirectoryURL.appendingPathComponent("diag_\(sourceId).json")
    }

    private func subscriptionFileURL(id: String) -> URL {
        storageDirectoryURL.appendingPathComponent("subscription_\(id).txt")
    }

    private func legacySubscriptionFileURL(id: String) -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("adblock_subscription_\(id).txt")
    }

    private init() {
        if UserDefaults.standard.object(forKey: enabledKey) == nil {
            UserDefaults.standard.set(true, forKey: enabledKey)
        }

        metadataBySource = loadAllMetadataFromDisk()
        restorePersistedRules()
        performGlobalStoreGarbageCollection()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.checkAndAutoUpdateSubscriptions()
        }
    }

    @objc private func handleAppDidBecomeActive() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.checkAndAutoUpdateSubscriptions()
        }
    }

    func checkAndAutoUpdateSubscriptions() {
        guard isEnabled else { return }

        let now = Date()
        let subscriptions = loadSubscriptions()

        let dueSubscriptions = subscriptions.filter { sub in
            guard sub.isEnabled else { return false }

            stateLock.lock()
            let isCurrentlyUpdating = updatingSourceIds.contains(sub.id)
            let lastAttempt = lastAutoUpdateAttemptBySource[sub.id]
            stateLock.unlock()

            if isCurrentlyUpdating {
                return false
            }

            if let lastAttempt = lastAttempt, now.timeIntervalSince(lastAttempt) < autoUpdateRetryCooldown {
                return false
            }

            guard let lastUpdated = sub.lastUpdated else {
                return true
            }

            return now.timeIntervalSince(lastUpdated) >= autoUpdateInterval
        }

        guard !dueSubscriptions.isEmpty else { return }
        autoUpdateSequentially(subscriptions: dueSubscriptions, index: 0)
    }

    private func autoUpdateSequentially(subscriptions: [AdBlockSubscription], index: Int) {
        guard index < subscriptions.count, isEnabled else { return }

        let sub = subscriptions[index]
        let now = Date()

        stateLock.lock()
        let isCurrentlyUpdating = updatingSourceIds.contains(sub.id)
        if !isCurrentlyUpdating {
            lastAutoUpdateAttemptBySource[sub.id] = now
        }
        stateLock.unlock()

        if isCurrentlyUpdating {
            autoUpdateSequentially(subscriptions: subscriptions, index: index + 1)
            return
        }

        fetchSubscription(sub) { [weak self] _, _, _ in
            self?.autoUpdateSequentially(subscriptions: subscriptions, index: index + 1)
        }
    }

    func loadSubscriptions() -> [AdBlockSubscription] {
        guard let data = UserDefaults.standard.data(forKey: subscriptionsKey),
              let items = try? JSONDecoder().decode([AdBlockSubscription].self, from: data) else {
            return []
        }

        return items
    }

    func saveSubscriptions(_ subscriptions: [AdBlockSubscription]) {
        guard let data = try? JSONEncoder().encode(subscriptions) else {
            return
        }

        UserDefaults.standard.set(data, forKey: subscriptionsKey)
    }

    func toggleSubscription(id: String, isEnabled: Bool) {
        var subscriptions = loadSubscriptions()
        if let idx = subscriptions.firstIndex(where: { $0.id == id }) {
            subscriptions[idx].isEnabled = isEnabled
            saveSubscriptions(subscriptions)
            if isEnabled {
                compileSource(id: id, completion: nil)
                checkAndAutoUpdateSubscriptions()
            } else {
                deactivateSource(id: id)
            }
        }
    }

    func getCustomRules() -> String {
        UserDefaults.standard.string(forKey: customRulesKey) ?? ""
    }

    func saveCustomRules(
        _ rules: String,
        completion: ((Bool, String?) -> Void)? = nil
    ) {
        stateLock.lock()
        let isUpdating = updatingSourceIds.contains(Self.customSourceId)
        stateLock.unlock()

        guard !isUpdating else {
            completion?(false, "自定义规则正在保存")
            return
        }

        UserDefaults.standard.set(rules, forKey: customRulesKey)
        setUpdateStatus(
            sourceId: Self.customSourceId,
            status: "正在解析自定义规则…"
        )

        compileSource(id: Self.customSourceId) { [weak self] success, message in
            self?.setUpdateStatus(
                sourceId: Self.customSourceId,
                status: nil
            )
            completion?(success, message)
        }
    }

    func updateSubscription(id: String, name: String, urlString: String) {
        var subscriptions = loadSubscriptions()

        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else {
            return
        }

        subscriptions[index].name = name
        subscriptions[index].urlString = urlString
        saveSubscriptions(subscriptions)
    }

    func addSubscription(name: String, urlString: String) -> AdBlockSubscription {
        let subscription = AdBlockSubscription(
            id: UUID().uuidString,
            name: name,
            urlString: urlString,
            isEnabled: true,
            lastUpdated: nil,
            ruleCount: 0
        )

        var subscriptions = loadSubscriptions()
        subscriptions.append(subscription)
        saveSubscriptions(subscriptions)

        return subscription
    }

    func deleteSubscription(id: String) {
        var subscriptions = loadSubscriptions()
        subscriptions.removeAll { $0.id == id }
        saveSubscriptions(subscriptions)
        deactivateSource(id: id)
    }

    func isUpdating(sourceId: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return updatingSourceIds.contains(sourceId)
    }

    func ruleCount(sourceId: String) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return metadataBySource[sourceId]?.ruleCount ?? 0
    }

    func unsupportedRuleCount(sourceId: String) -> Int {
        loadDiagnosticRulesFromDisk(sourceId: sourceId).count
    }

    func unsupportedRulesText(sourceId: String) -> String {
        let rules = loadDiagnosticRulesFromDisk(sourceId: sourceId)
        guard !rules.isEmpty else {
            return "没有检测到不兼容规则。"
        }

        return rules.enumerated().map { index, item in
            let errorText = item.errorDescription.isEmpty ? "未返回具体错误" : item.errorDescription

            return """
            [\(index + 1)]
            原始规则:
            \(item.rawRule)

            转换后的 WebKit 规则:
            \(item.compiledJSON)

            编译错误:
            \(errorText)
            """
        }.joined(separator: "\n\n--------------------\n\n")
    }

    func clearUnsupportedRules(sourceId: String) {
        deleteDiagnosticFile(sourceId: sourceId)
    }

    func updateStatus(sourceId: String) -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return updateStatusBySource[sourceId]
    }

    private func setUpdateStatus(
        sourceId: String,
        status: String?
    ) {
        stateLock.lock()
        if let status = status {
            updateStatusBySource[sourceId] = status
        } else {
            updateStatusBySource.removeValue(forKey: sourceId)
        }
        stateLock.unlock()
    }

    func attach(to webView: WKWebView) {
        attachedWebViews.add(webView)
        applyRules(to: webView)
    }

    func detach(from webView: WKWebView) {
        attachedWebViews.remove(webView)
    }

    func applyRules(to webView: WKWebView) {
        let controller = webView.configuration.userContentController

        controller.removeAllContentRuleLists()
        controller.removeAllUserScripts()

        defer {
            NotificationCenter.default.post(
                name: NSNotification.Name("SimpleAdBlockRulesApplied"),
                object: webView
            )
        }

        guard isEnabled else {
            return
        }

        if let host = webView.url?.host, !DomainSettingsStore.shared.getBool(domain: host, setting: "adBlock", defaultVal: true) {
            return
        }

        let enabledSubs = Set(loadSubscriptions().filter { $0.isEnabled }.map { $0.id })

        stateLock.lock()
        let compiledListsCopy = compiledListsBySource
        let cosmeticScriptsCopy = cosmeticScriptsBySource
        stateLock.unlock()

        for sourceId in compiledListsCopy.keys.sorted() {
            if sourceId != Self.customSourceId && !enabledSubs.contains(sourceId) {
                continue
            }
            for ruleList in compiledListsCopy[sourceId] ?? [] {
                controller.add(ruleList)
            }
        }

        for sourceId in cosmeticScriptsCopy.keys.sorted() {
            if sourceId != Self.customSourceId && !enabledSubs.contains(sourceId) {
                continue
            }
            for script in cosmeticScriptsCopy[sourceId] ?? [] {
                controller.addUserScript(script)
            }
        }
    }

    private func applyRulesToAttachedWebViews() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for webView in self.attachedWebViews.allObjects {
                self.applyRules(to: webView)
            }
        }
    }

    func fetchSubscription(
        _ subscription: AdBlockSubscription,
        completion: @escaping (Bool, Int, String?) -> Void
    ) {
        stateLock.lock()
        if updatingSourceIds.contains(subscription.id) {
            stateLock.unlock()
            completion(false, 0, "该订阅正在更新，请等待当前任务结束")
            return
        }
        updatingSourceIds.insert(subscription.id)
        lastAutoUpdateAttemptBySource[subscription.id] = Date()
        stateLock.unlock()

        guard let url = URL(string: subscription.urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            stateLock.lock()
            updatingSourceIds.remove(subscription.id)
            stateLock.unlock()
            completion(false, 0, "订阅地址无效")
            return
        }

        setUpdateStatus(
            sourceId: subscription.id,
            status: "正在下载订阅…"
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 1800
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 120
        )

        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Version/17.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.stateLock.lock()
                    self.updatingSourceIds.remove(subscription.id)
                    self.stateLock.unlock()
                    self.setUpdateStatus(sourceId: subscription.id, status: nil)
                    completion(false, 0, error.localizedDescription)
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    self.stateLock.lock()
                    self.updatingSourceIds.remove(subscription.id)
                    self.stateLock.unlock()
                    self.setUpdateStatus(sourceId: subscription.id, status: nil)
                    completion(false, 0, "服务器未返回 HTTP 响应")
                }
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                DispatchQueue.main.async {
                    self.stateLock.lock()
                    self.updatingSourceIds.remove(subscription.id)
                    self.stateLock.unlock()
                    self.setUpdateStatus(sourceId: subscription.id, status: nil)
                    completion(false, 0, "服务器返回 HTTP \(httpResponse.statusCode)")
                }
                return
            }

            guard let data = data, !data.isEmpty else {
                DispatchQueue.main.async {
                    self.stateLock.lock()
                    self.updatingSourceIds.remove(subscription.id)
                    self.stateLock.unlock()
                    self.setUpdateStatus(sourceId: subscription.id, status: nil)
                    completion(false, 0, "订阅内容为空")
                }
                return
            }

            let text = String(decoding: data, as: UTF8.self)

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                DispatchQueue.main.async {
                    self.stateLock.lock()
                    self.updatingSourceIds.remove(subscription.id)
                    self.stateLock.unlock()
                    self.setUpdateStatus(sourceId: subscription.id, status: nil)
                    completion(false, 0, "订阅内容不是有效文本")
                }
                return
            }

            do {
                try text.write(
                    to: self.subscriptionFileURL(id: subscription.id),
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                DispatchQueue.main.async {
                    self.stateLock.lock()
                    self.updatingSourceIds.remove(subscription.id)
                    self.stateLock.unlock()
                    self.setUpdateStatus(sourceId: subscription.id, status: nil)
                    completion(false, 0, "订阅文件保存失败：\(error.localizedDescription)")
                }
                return
            }

            self.setUpdateStatus(
                sourceId: subscription.id,
                status: "正在解析规则…"
            )

            self.compileSource(id: subscription.id, isAlreadyUpdating: true) { success, message in
                DispatchQueue.main.async {
                    self.stateLock.lock()
                    self.updatingSourceIds.remove(subscription.id)
                    self.stateLock.unlock()
                    self.setUpdateStatus(sourceId: subscription.id, status: nil)

                    let count = self.ruleCount(sourceId: subscription.id)

                    if success {
                        var subscriptions = self.loadSubscriptions()
                        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
                            subscriptions[index].lastUpdated = Date()
                            subscriptions[index].ruleCount = count
                            self.saveSubscriptions(subscriptions)
                        }
                    }

                    completion(success, count, message)
                }
            }
        }.resume()
    }

    private func restorePersistedRules() {
        parseQueue.async { [weak self] in
            guard let self = self else { return }

            self.stateLock.lock()
            let metadataCopy = self.metadataBySource
            self.stateLock.unlock()

            for sourceId in metadataCopy.keys.sorted() {
                guard let metadata = metadataCopy[sourceId] else {
                    continue
                }

                self.restoreCosmeticScriptFromFile(sourceId: sourceId)

                if metadata.ruleListIdentifiers.isEmpty {
                    continue
                }

                self.loadRuleListsSequentially(identifiers: metadata.ruleListIdentifiers, index: 0, loaded: []) { [weak self] lists in
                    guard let self = self else { return }

                    if lists.count == metadata.ruleListIdentifiers.count {
                        self.stateLock.lock()
                        self.compiledListsBySource[sourceId] = lists
                        self.stateLock.unlock()
                        self.applyRulesToAttachedWebViews()
                    } else {
                        self.compileSource(id: sourceId, completion: nil)
                    }
                }
            }
        }
    }

    private func restoreCosmeticScriptFromFile(sourceId: String) {
        let file = cosmeticScriptFileURL(sourceId: sourceId)
        guard let source = try? String(contentsOf: file, encoding: .utf8), !source.isEmpty else { return }
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        stateLock.lock()
        cosmeticScriptsBySource[sourceId] = [script]
        stateLock.unlock()
    }

    private func loadRuleListsSequentially(
        identifiers: [String],
        index: Int,
        loaded: [WKContentRuleList],
        completion: @escaping ([WKContentRuleList]) -> Void
    ) {
        guard index < identifiers.count else {
            completion(loaded)
            return
        }

        DispatchQueue.main.async {
            WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: identifiers[index]) { [weak self] ruleList, _ in
                self?.parseQueue.async {
                    var nextLoaded = loaded
                    if let rl = ruleList {
                        nextLoaded.append(rl)
                    }
                    self?.loadRuleListsSequentially(
                        identifiers: identifiers,
                        index: index + 1,
                        loaded: nextLoaded,
                        completion: completion
                    )
                }
            }
        }
    }

    private func makeRuleIdentifier(sourceId: String, version: String, group: String) -> String {
        let cleanId = sourceId.replacingOccurrences(of: "-", with: "")
        return "\(identifierPrefix)_\(cleanId)_\(version)_\(group)"
    }

    private func purgeStoreRulesForSource(sourceId: String, keepingIdentifiers: Set<String>, completion: (() -> Void)? = nil) {
        let cleanId = sourceId.replacingOccurrences(of: "-", with: "")
        DispatchQueue.main.async {
            WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { identifiers in
                guard let identifiers = identifiers, !identifiers.isEmpty else {
                    completion?()
                    return
                }

                let group = DispatchGroup()
                for id in identifiers {
                    let matchDot = id.contains(".\(cleanId).")
                    let matchUnderscore = id.contains("_\(cleanId)_")
                    let matchPrefix = id.hasPrefix("Simple") && (matchDot || matchUnderscore)

                    if matchPrefix && !keepingIdentifiers.contains(id) {
                        group.enter()
                        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in
                            group.leave()
                        }
                    }
                }

                group.notify(queue: .main) {
                    completion?()
                }
            }
        }
    }

    private func performGlobalStoreGarbageCollection() {
        let activeSubs = loadSubscriptions()
        var validCleanIds = Set(activeSubs.map { $0.id.replacingOccurrences(of: "-", with: "") })
        validCleanIds.insert(Self.customSourceId.replacingOccurrences(of: "-", with: ""))

        stateLock.lock()
        var activeIdentifiers = Set<String>()
        for metadata in metadataBySource.values {
            activeIdentifiers.formUnion(metadata.ruleListIdentifiers)
        }
        stateLock.unlock()

        DispatchQueue.main.async {
            WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { identifiers in
                guard let identifiers = identifiers else { return }
                for id in identifiers where id.hasPrefix("Simple") {
                    if !activeIdentifiers.contains(id) {
                        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in }
                    }
                }
            }
        }
    }

    private func compileSource(
        id sourceId: String,
        isAlreadyUpdating: Bool = false,
        completion: ((Bool, String?) -> Void)?
    ) {
        stateLock.lock()
        if !isAlreadyUpdating && updatingSourceIds.contains(sourceId) {
            stateLock.unlock()
            completion?(false, "该规则源正在更新")
            return
        }
        updatingSourceIds.insert(sourceId)
        stateLock.unlock()

        guard let text = sourceText(id: sourceId) else {
            deactivateSource(id: sourceId)
            completion?(true, nil)
            return
        }

        if updateStatus(sourceId: sourceId) == nil {
            setUpdateStatus(
                sourceId: sourceId,
                status: "正在解析规则…"
            )
        }

        parseQueue.async { [weak self] in
            guard let self = self else { return }

            let payload = self.buildSourcePayload(text: text)

            self.setUpdateStatus(
                sourceId: sourceId,
                status: "正在编译规则…"
            )

            self.compilePayload(
                payload,
                sourceId: sourceId,
                completion: completion
            )
        }
    }

    private func generateCosmeticScript(
        cosmeticRules: [AdBlockCosmeticRule],
        cosmeticExceptions: [AdBlockCosmeticException]
    ) -> String {
        guard !cosmeticRules.isEmpty || !cosmeticExceptions.isEmpty else { return "" }

        var genericSelectors: [String] = []
        var domainRules: [AdBlockCosmeticRule] = []

        for rule in cosmeticRules {
            if rule.domains.isEmpty && rule.excludedDomains.isEmpty {
                genericSelectors.append(rule.selector)
            } else {
                domainRules.append(rule)
            }
        }

        let genericCSS = genericSelectors.map { "\($0){display:none!important;visibility:hidden!important;pointer-events:none!important;}" }.joined()
        let genericCSSJSON = escapeJSONString(genericCSS)

        let domainRulesData = (try? JSONEncoder().encode(domainRules)) ?? Data()
        let domainRulesJSON = String(data: domainRulesData, encoding: .utf8) ?? "[]"

        let exceptionsData = (try? JSONEncoder().encode(cosmeticExceptions)) ?? Data()
        let exceptionsJSON = String(data: exceptionsData, encoding: .utf8) ?? "[]"

        return """
        (function() {
            var genericCSS = \(genericCSSJSON);
            var domainRules = \(domainRulesJSON);
            var exceptions = \(exceptionsJSON);
            var styleId = '__simple_adblock_style__';
            var host = (location.hostname || '').toLowerCase();

            function matches(r) {
                if (r.excludedDomains && r.excludedDomains.length > 0) {
                    for (var i = 0; i < r.excludedDomains.length; i++) {
                        var ex = r.excludedDomains[i];
                        if (host === ex || host.endsWith('.' + ex)) return false;
                    }
                }
                if (!r.domains || r.domains.length === 0) return true;
                for (var j = 0; j < r.domains.length; j++) {
                    var d = r.domains[j];
                    if (host === d || host.endsWith('.' + d)) return true;
                }
                return false;
            }

            function isExcepted(sel) {
                if (!exceptions || exceptions.length === 0) return false;
                for (var i = 0; i < exceptions.length; i++) {
                    if (exceptions[i].selector === sel && matches(exceptions[i])) return true;
                }
                return false;
            }

            function buildCSS() {
                var css = genericCSS || '';
                for (var i = 0; i < domainRules.length; i++) {
                    var rule = domainRules[i];
                    if (matches(rule) && !isExcepted(rule.selector)) {
                        css += rule.selector + '{display:none!important;visibility:hidden!important;pointer-events:none!important;}';
                    }
                }
                return css;
            }

            function applyCSS() {
                var cssText = buildCSS();
                if (!cssText) return;
                var style = document.getElementById(styleId);
                if (!style) {
                    style = document.createElement('style');
                    style.id = styleId;
                    style.type = 'text/css';
                    (document.head || document.documentElement).appendChild(style);
                }
                style.textContent = cssText;
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', applyCSS, { once: true });
            } else {
                applyCSS();
            }
        })();
        """
    }

    private func compilePayload(
        _ payload: AdBlockSourcePayload,
        sourceId: String,
        completion: ((Bool, String?) -> Void)?
    ) {
        let cosmeticScriptSource = generateCosmeticScript(
            cosmeticRules: payload.cosmeticRules,
            cosmeticExceptions: payload.cosmeticExceptions
        )

        let version = String(Int(Date().timeIntervalSince1970))

        if !cosmeticScriptSource.isEmpty {
            try? cosmeticScriptSource.write(
                to: cosmeticScriptFileURL(sourceId: sourceId),
                atomically: true,
                encoding: .utf8
            )
            let userScript = WKUserScript(
                source: cosmeticScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            stateLock.lock()
            cosmeticScriptsBySource[sourceId] = [userScript]
            stateLock.unlock()
        } else {
            try? FileManager.default.removeItem(at: cosmeticScriptFileURL(sourceId: sourceId))
            stateLock.lock()
            cosmeticScriptsBySource.removeValue(forKey: sourceId)
            stateLock.unlock()
        }

        guard !payload.networkChunks.isEmpty else {
            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                ruleListIdentifiers: [],
                ruleCount: payload.ruleCount,
                skippedRuleCount: payload.skippedRuleCount
            )

            stateLock.lock()
            metadataBySource[sourceId] = metadata
            compiledListsBySource.removeValue(forKey: sourceId)
            updatingSourceIds.remove(sourceId)
            stateLock.unlock()

            saveMetadata(metadata)
            deleteDiagnosticFile(sourceId: sourceId)
            purgeStoreRulesForSource(sourceId: sourceId, keepingIdentifiers: [])

            DispatchQueue.main.async { [weak self] in
                self?.setUpdateStatus(sourceId: sourceId, status: nil)
                self?.applyRulesToAttachedWebViews()

                let message = payload.skippedRuleCount > 0
                    ? "已更新，跳过 \(payload.skippedRuleCount) 条不兼容规则"
                    : nil

                completion?(true, message)
            }
            return
        }

        let deadline = Date().addingTimeInterval(maximumCompilationDuration)
        var diagnosticItems: [AdBlockUnsupportedRule] = []

        compileChunks(
            payload.networkChunks,
            sourceId: sourceId,
            version: version,
            index: 0,
            lists: [],
            identifiers: [],
            deadline: deadline,
            diagnosticCollector: { rule, err in
                if diagnosticItems.count < 50 {
                    let json = serializeRulesToJSONString([rule])
                    diagnosticItems.append(AdBlockUnsupportedRule(rawRule: rule.rawRule, compiledJSON: json, errorDescription: err))
                }
            }
        ) { [weak self] lists, identifiers in
            guard let self = self else { return }

            if lists.isEmpty && cosmeticScriptSource.isEmpty {
                self.stateLock.lock()
                self.updatingSourceIds.remove(sourceId)
                self.stateLock.unlock()
                self.setUpdateStatus(sourceId: sourceId, status: nil)
                DispatchQueue.main.async {
                    completion?(false, "规则编译超时或所有规则块均不兼容")
                }
                return
            }

            let newIdentifiersSet = Set(identifiers)

            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                ruleListIdentifiers: identifiers,
                ruleCount: payload.ruleCount,
                skippedRuleCount: payload.skippedRuleCount + diagnosticItems.count
            )

            self.stateLock.lock()
            self.metadataBySource[sourceId] = metadata
            self.compiledListsBySource[sourceId] = lists
            self.updatingSourceIds.remove(sourceId)
            self.stateLock.unlock()

            self.saveMetadata(metadata)
            self.saveDiagnosticRulesToDisk(sourceId: sourceId, rules: diagnosticItems)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.setUpdateStatus(sourceId: sourceId, status: nil)
                self.applyRulesToAttachedWebViews()
                self.purgeStoreRulesForSource(sourceId: sourceId, keepingIdentifiers: newIdentifiersSet)

                let unsupportedCount = diagnosticItems.count
                let skipped = metadata.skippedRuleCount

                let message: String?
                if unsupportedCount > 0 {
                    message = "已更新，\(unsupportedCount) 条规则未通过 WebKit 编译，可在规则管理页查看详情。"
                } else if skipped > 0 {
                    message = "已更新，跳过 \(skipped) 条无法转换的规则。"
                } else {
                    message = nil
                }

                completion?(true, message)
            }
        }
    }

    private func compileChunks(
        _ chunks: [[AdBlockCompactNetworkRule]],
        sourceId: String,
        version: String,
        index: Int,
        lists: [WKContentRuleList],
        identifiers: [String],
        deadline: Date,
        diagnosticCollector: @escaping (AdBlockCompactNetworkRule, String) -> Void,
        completion: @escaping ([WKContentRuleList], [String]) -> Void
    ) {
        guard index < chunks.count else {
            completion(lists, identifiers)
            return
        }

        guard Date() < deadline else {
            let remainingRules = chunks[index...].flatMap { $0 }
            for rule in remainingRules.prefix(30) {
                diagnosticCollector(rule, "总编译超时，未提交给 WebKit 编译")
            }
            completion(lists, identifiers)
            return
        }

        setUpdateStatus(
            sourceId: sourceId,
            status: "正在编译规则 \(index + 1)/\(chunks.count)…"
        )

        let targetChunk = chunks[index]

        compileRuleGroup(
            targetChunk,
            sourceId: sourceId,
            version: version,
            groupIdentifier: "\(index)",
            deadline: deadline,
            depth: 0,
            diagnosticCollector: diagnosticCollector
        ) { [weak self] ruleLists, ruleIdentifiers in
            guard let self = self else { return }
            self.compileChunks(
                chunks,
                sourceId: sourceId,
                version: version,
                index: index + 1,
                lists: lists + ruleLists,
                identifiers: identifiers + ruleIdentifiers,
                deadline: deadline,
                diagnosticCollector: diagnosticCollector,
                completion: completion
            )
        }
    }

    private func compileRuleGroup(
        _ rules: [AdBlockCompactNetworkRule],
        sourceId: String,
        version: String,
        groupIdentifier: String,
        deadline: Date,
        depth: Int,
        diagnosticCollector: @escaping (AdBlockCompactNetworkRule, String) -> Void,
        completion: @escaping ([WKContentRuleList], [String]) -> Void
    ) {
        guard !rules.isEmpty else {
            completion([], [])
            return
        }

        guard Date() < deadline else {
            for rule in rules.prefix(10) {
                diagnosticCollector(rule, "编译超时")
            }
            completion([], [])
            return
        }

        let json = serializeRulesToJSONString(rules)
        let identifier = makeRuleIdentifier(sourceId: sourceId, version: version, group: groupIdentifier)
        let gate = AdBlockChunkCompilationGate()

        func resolve(ruleList: WKContentRuleList?, error: Error?) {
            gate.resolve {
                guard let ruleList = ruleList else {
                    if rules.count == 1 || depth >= 5 {
                        let errText = self.compilerErrorDescription(error)
                        for rule in rules.prefix(5) {
                            diagnosticCollector(rule, errText)
                        }
                        completion([], [])
                        return
                    }

                    let middle = rules.count / 2
                    let left = Array(rules[..<middle])
                    let right = Array(rules[middle...])

                    self.compileRuleGroup(
                        left,
                        sourceId: sourceId,
                        version: version,
                        groupIdentifier: "\(groupIdentifier)L",
                        deadline: deadline,
                        depth: depth + 1,
                        diagnosticCollector: diagnosticCollector
                    ) { leftLists, leftIdentifiers in
                        self.compileRuleGroup(
                            right,
                            sourceId: sourceId,
                            version: version,
                            groupIdentifier: "\(groupIdentifier)R",
                            deadline: deadline,
                            depth: depth + 1,
                            diagnosticCollector: diagnosticCollector
                        ) { rightLists, rightIdentifiers in
                            completion(
                                leftLists + rightLists,
                                leftIdentifiers + rightIdentifiers
                            )
                        }
                    }
                    return
                }
                completion([ruleList], [identifier])
            }
        }

        DispatchQueue.main.async {
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { ruleList, error in
                resolve(ruleList: ruleList, error: error)
            }
        }
    }

    private func deactivateSource(id sourceId: String) {
        stateLock.lock()
        metadataBySource.removeValue(forKey: sourceId)
        compiledListsBySource.removeValue(forKey: sourceId)
        cosmeticScriptsBySource.removeValue(forKey: sourceId)
        updatingSourceIds.remove(sourceId)
        updateStatusBySource.removeValue(forKey: sourceId)
        lastAutoUpdateAttemptBySource.removeValue(forKey: sourceId)
        stateLock.unlock()

        setUpdateStatus(sourceId: sourceId, status: nil)

        applyRulesToAttachedWebViews()

        purgeStoreRulesForSource(sourceId: sourceId, keepingIdentifiers: [])
        deleteMetadataFile(sourceId: sourceId)
        deleteDiagnosticFile(sourceId: sourceId)
        try? FileManager.default.removeItem(at: cosmeticScriptFileURL(sourceId: sourceId))
        try? FileManager.default.removeItem(at: subscriptionFileURL(id: sourceId))
        try? FileManager.default.removeItem(at: legacySubscriptionFileURL(id: sourceId))
    }

    private func sourceText(id sourceId: String) -> String? {
        if sourceId == Self.customSourceId {
            let text = getCustomRules()
            return text.isEmpty ? nil : text
        }

        let newURL = subscriptionFileURL(id: sourceId)
        if FileManager.default.fileExists(atPath: newURL.path),
           let content = try? String(contentsOf: newURL, encoding: .utf8) {
            return content
        }

        let legacyURL = legacySubscriptionFileURL(id: sourceId)
        if FileManager.default.fileExists(atPath: legacyURL.path),
           let content = try? String(contentsOf: legacyURL, encoding: .utf8) {
            return content
        }

        return nil
    }

    private func buildSourcePayload(text: String) -> AdBlockSourcePayload {
        var blockRules: [AdBlockCompactNetworkRule] = []
        var exceptionRules: [AdBlockCompactNetworkRule] = []
        var cosmeticRules: [AdBlockCosmeticRule] = []
        var cosmeticExceptions: [AdBlockCosmeticException] = []
        var totalRuleCount = 0
        var totalSkipped = 0

        text.enumerateLines { line, _ in
            autoreleasepool {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.hasPrefix("!"),
                      !trimmed.hasPrefix("！"),
                      !trimmed.hasPrefix("[") else {
                    return
                }

                let result = self.parseRule(trimmed)
                if let networkRule = result.networkRule {
                    if result.isException {
                        exceptionRules.append(networkRule)
                    } else {
                        blockRules.append(networkRule)
                    }
                    totalRuleCount += 1
                }

                if !result.cosmeticRules.isEmpty {
                    for cosmeticRule in result.cosmeticRules {
                        if cosmeticRules.count < self.maximumCosmeticRulesPerSource {
                            cosmeticRules.append(cosmeticRule)
                            totalRuleCount += 1
                        } else {
                            totalSkipped += 1
                        }
                    }
                }

                if !result.cosmeticExceptions.isEmpty {
                    for cosmeticEx in result.cosmeticExceptions {
                        cosmeticExceptions.append(cosmeticEx)
                        totalRuleCount += 1
                    }
                }

                if result.isUnsupported {
                    totalSkipped += 1
                }
            }
        }

        var allNetworkChunks: [[AdBlockCompactNetworkRule]] = []
        if !blockRules.isEmpty {
            allNetworkChunks = stride(from: 0, to: blockRules.count, by: nativeRuleChunkSize).map { start in
                let blockChunk = Array(blockRules[start..<min(start + nativeRuleChunkSize, blockRules.count)])
                return blockChunk + exceptionRules
            }
        } else if !exceptionRules.isEmpty {
            allNetworkChunks = [exceptionRules]
        }

        return AdBlockSourcePayload(
            networkChunks: allNetworkChunks,
            cosmeticRules: cosmeticRules,
            cosmeticExceptions: cosmeticExceptions,
            ruleCount: totalRuleCount,
            skippedRuleCount: totalSkipped
        )
    }

    private func isValidWebKitPattern(_ pattern: String) -> Bool {
        guard !pattern.isEmpty,
              pattern.count < 1024,
              pattern.allSatisfy({ $0.isASCII }),
              !pattern.contains("(?"),
              !pattern.contains("[:") else {
            return false
        }

        var openParens = 0
        var openBrackets = 0
        var escaped = false

        for ch in pattern {
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if ch == "(" {
                openParens += 1
            } else if ch == ")" {
                openParens -= 1
                if openParens < 0 { return false }
            } else if ch == "[" {
                openBrackets += 1
            } else if ch == "]" {
                openBrackets -= 1
                if openBrackets < 0 { return false }
            }
        }

        if escaped || openParens != 0 || openBrackets != 0 {
            return false
        }

        return autoreleasepool {
            (try? NSRegularExpression(pattern: pattern)) != nil
        }
    }

    private func parseRule(_ rawLine: String) -> AdBlockParsedLine {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty,
              !line.hasPrefix("!"),
              !line.hasPrefix("！"),
              !line.hasPrefix("[") else {
            return AdBlockParsedLine(
                networkRule: nil,
                isException: false,
                cosmeticRules: [],
                cosmeticExceptions: [],
                isUnsupported: false
            )
        }

        if line.contains("##+js") || line.contains("#%#") {
            return AdBlockParsedLine(
                networkRule: nil,
                isException: false,
                cosmeticRules: [],
                cosmeticExceptions: [],
                isUnsupported: true
            )
        }

        if line.contains("#@#") {
            guard let range = line.range(of: "#@#") else {
                return AdBlockParsedLine(
                    networkRule: nil,
                    isException: false,
                    cosmeticRules: [],
                    cosmeticExceptions: [],
                    isUnsupported: true
                )
            }
            let domainsText = String(line[..<range.lowerBound])
            let selectorsText = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let parsedDomains = normalizedDomains(from: domainsText)
            let selectors = splitSelectorList(selectorsText)
            let exceptions = selectors.compactMap { sel -> AdBlockCosmeticException? in
                let val = sel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !val.isEmpty else { return nil }
                return AdBlockCosmeticException(domains: parsedDomains.include, selector: val)
            }
            return AdBlockParsedLine(
                networkRule: nil,
                isException: false,
                cosmeticRules: [],
                cosmeticExceptions: exceptions,
                isUnsupported: exceptions.isEmpty
            )
        }

        let cosmeticSeparator: String?
        if line.contains("##") {
            cosmeticSeparator = "##"
        } else if line.contains("#?#") {
            cosmeticSeparator = "#?#"
        } else {
            cosmeticSeparator = nil
        }

        if let sep = cosmeticSeparator, let range = line.range(of: sep) {
            let domainsText = String(line[..<range.lowerBound])
            let selectorsText = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            let parsedDomains = normalizedDomains(from: domainsText)
            let selectors = splitSelectorList(selectorsText)

            let cosmeticRules = selectors.compactMap { selector in
                parseCosmeticRule(selector: selector, domains: parsedDomains.include, excludedDomains: parsedDomains.exclude)
            }

            return AdBlockParsedLine(
                networkRule: nil,
                isException: false,
                cosmeticRules: cosmeticRules,
                cosmeticExceptions: [],
                isUnsupported: cosmeticRules.count != selectors.count
            )
        }

        let isException = line.hasPrefix("@@")

        if isException {
            line = String(line.dropFirst(2))
        }

        let parts = line.split(
            separator: "$",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )

        let rawPattern = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawPattern.isEmpty else {
            return AdBlockParsedLine(
                networkRule: nil,
                isException: false,
                cosmeticRules: [],
                cosmeticExceptions: [],
                isUnsupported: true
            )
        }

        let options = parts.count > 1
            ? String(parts[1]).split(separator: ",").map(String.init)
            : []

        var includeDomains: [String] = []
        var excludeDomains: [String] = []
        var resourceTypes: [String] = []
        var loadTypes: [String] = []
        var isCaseSensitive = false

        let allResourceTypes = ["document", "image", "style-sheet", "script", "font", "raw", "media", "popup"]

        for rawOption in options {
            let option = rawOption.trimmingCharacters(in: .whitespacesAndNewlines)

            if option.hasPrefix("domain=") {
                let domainStr = String(option.dropFirst(7))
                if domainStr.contains("/") {
                    return AdBlockParsedLine(networkRule: nil, isException: false, cosmeticRules: [], cosmeticExceptions: [], isUnsupported: true)
                }
                let domains = normalizedDomains(from: domainStr, separator: "|")
                includeDomains.append(contentsOf: domains.include)
                excludeDomains.append(contentsOf: domains.exclude)
            } else if option.hasPrefix("denyallow=") {
                let domainStr = String(option.dropFirst(10))
                if domainStr.contains("/") {
                    return AdBlockParsedLine(networkRule: nil, isException: false, cosmeticRules: [], cosmeticExceptions: [], isUnsupported: true)
                }
                let domains = normalizedDomains(from: domainStr, separator: "|")
                excludeDomains.append(contentsOf: domains.include)
            } else if option == "script" {
                resourceTypes.append("script")
            } else if option == "image" {
                resourceTypes.append("image")
            } else if option == "stylesheet" || option == "css" {
                resourceTypes.append("style-sheet")
            } else if option == "font" {
                resourceTypes.append("font")
            } else if option == "media" {
                resourceTypes.append("media")
            } else if option == "xmlhttprequest" || option == "xhr" || option == "fetch" || option == "ping" {
                resourceTypes.append("raw")
            } else if option == "subdocument" || option == "frame" || option == "document" || option == "doc" {
                resourceTypes.append("document")
            } else if option == "popup" {
                resourceTypes.append("popup")
            } else if option == "third-party" || option == "3p" {
                loadTypes.append("third-party")
            } else if option == "~third-party" || option == "1p" || option == "first-party" {
                loadTypes.append("first-party")
            } else if option == "~first-party" {
                loadTypes.append("third-party")
            } else if option == "match-case" {
                isCaseSensitive = true
            } else if option == "important" || option.hasPrefix("redirect") || option.hasPrefix("rewrite") {
                continue
            } else if option.hasPrefix("~") {
                let negatedType = String(option.dropFirst())
                if negatedType == "image" {
                    resourceTypes.append(contentsOf: allResourceTypes.filter { $0 != "image" })
                } else if negatedType == "script" {
                    resourceTypes.append(contentsOf: allResourceTypes.filter { $0 != "script" })
                } else if negatedType == "stylesheet" || negatedType == "css" {
                    resourceTypes.append(contentsOf: allResourceTypes.filter { $0 != "style-sheet" })
                } else {
                    continue
                }
            } else if option == "badfilter" ||
                        option.hasPrefix("removeparam") ||
                        option.hasPrefix("csp") {
                return AdBlockParsedLine(
                    networkRule: nil,
                    isException: false,
                    cosmeticRules: [],
                    cosmeticExceptions: [],
                    isUnsupported: true
                )
            }
        }

        let filter: String
        if rawPattern.hasPrefix("/") && rawPattern.hasSuffix("/") && rawPattern.count > 2 {
            filter = String(rawPattern.dropFirst().dropLast())
        } else {
            filter = urlFilterPattern(from: rawPattern)
        }

        guard isValidWebKitPattern(filter) else {
            return AdBlockParsedLine(
                networkRule: nil,
                isException: false,
                cosmeticRules: [],
                cosmeticExceptions: [],
                isUnsupported: true
            )
        }

        let compactRule = AdBlockCompactNetworkRule(
            rawRule: rawLine,
            triggerFilter: filter,
            isCaseSensitive: isCaseSensitive,
            includeDomains: Array(Set(includeDomains)).sorted(),
            excludeDomains: Array(Set(excludeDomains)).sorted(),
            resourceTypes: Array(Set(resourceTypes)).sorted(),
            loadTypes: Array(Set(loadTypes)).sorted(),
            isException: isException
        )

        return AdBlockParsedLine(
            networkRule: compactRule,
            isException: isException,
            cosmeticRules: [],
            cosmeticExceptions: [],
            isUnsupported: false
        )
    }

    private func parseCosmeticRule(
        selector: String,
        domains: [String],
        excludedDomains: [String] = []
    ) -> AdBlockCosmeticRule? {
        let value = selector.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty,
              value.count <= 4096,
              !value.contains("\u{0000}"),
              !value.contains("{"),
              !value.contains("}"),
              !value.contains("<"),
              !value.contains(">style") else {
            return nil
        }

        return AdBlockCosmeticRule(
            domains: domains,
            excludedDomains: excludedDomains,
            selector: value
        )
    }

    private func splitSelectorList(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var parenthesesDepth = 0
        var bracketsDepth = 0
        var quote: Character?

        for character in text {
            if let currentQuote = quote {
                current.append(character)

                if character == currentQuote {
                    quote = nil
                }

                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
                continue
            }

            if character == "(" {
                parenthesesDepth += 1
            } else if character == ")" {
                parenthesesDepth = max(0, parenthesesDepth - 1)
            } else if character == "[" {
                bracketsDepth += 1
            } else if character == "]" {
                bracketsDepth = max(0, bracketsDepth - 1)
            }

            if character == "," && parenthesesDepth == 0 && bracketsDepth == 0 {
                let value = current.trimmingCharacters(in: .whitespacesAndNewlines)

                if !value.isEmpty {
                    result.append(value)
                }

                current = ""
            } else {
                current.append(character)
            }
        }

        let value = current.trimmingCharacters(in: .whitespacesAndNewlines)

        if !value.isEmpty {
            result.append(value)
        }

        return result
    }

    private func normalizedDomains(
        from text: String,
        separator: Character = ","
    ) -> (include: [String], exclude: [String]) {
        var include: [String] = []
        var exclude: [String] = []

        for rawValue in text.split(separator: separator) {
            let value = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))

            guard !value.isEmpty, value != "*" else {
                continue
            }

            if value.hasPrefix("~") {
                let domain = String(value.dropFirst())

                if !domain.isEmpty {
                    exclude.append(domain)
                }
            } else {
                include.append(value)
            }
        }

        return (include, exclude)
    }

    private func urlFilterPattern(from pattern: String) -> String {
        var p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return "" }

        var startsWithDomainAnchor = false
        var startsWithStartAnchor = false
        var endsWithEndAnchor = false
        var hasTrailingSeparator = false

        if p.hasPrefix("||") {
            startsWithDomainAnchor = true
            p = String(p.dropFirst(2))
        } else if p.hasPrefix("|") {
            startsWithStartAnchor = true
            p = String(p.dropFirst())
        }

        if p.hasSuffix("|") {
            endsWithEndAnchor = true
            p = String(p.dropLast())
        }

        if p.hasSuffix("^") {
            hasTrailingSeparator = true
            p = String(p.dropLast())
        }

        let specialChars: Set<Character> = [".", "/", "?", "=", "-", "_", ":", "+", "$", "{", "}", "[", "]", "(", ")", "|", "\\"]
        var escaped = ""
        for char in p {
            if char == "*" {
                escaped.append(".*")
            } else if char == "^" {
                escaped.append("[^a-zA-Z0-9_.-]")
            } else if specialChars.contains(char) {
                escaped.append("\\\(char)")
            } else {
                escaped.append(char)
            }
        }

        while escaped.contains(".*.*") {
            escaped = escaped.replacingOccurrences(of: ".*.*", with: ".*")
        }

        var result = ""
        if startsWithDomainAnchor {
            result = "^[a-z]+://([^/:]+\\.)?" + escaped
        } else if startsWithStartAnchor {
            result = "^" + escaped
        } else {
            result = escaped
        }

        if hasTrailingSeparator {
            result.append("[^a-zA-Z0-9_.-]")
        }

        if endsWithEndAnchor {
            result.append("$")
        }

        return result
    }

    private func escapeJSONString(_ string: String) -> String {
        if let data = try? JSONEncoder().encode(string),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\"\(string)\""
    }

    private func serializeRulesToJSONString(_ rules: [AdBlockCompactNetworkRule]) -> String {
        var buffer = "["
        buffer.reserveCapacity(rules.count * 120)

        for (idx, rule) in rules.enumerated() {
            if idx > 0 {
                buffer.append(",")
            }
            buffer.append("{\"trigger\":{\"url-filter\":")
            buffer.append(escapeJSONString(rule.triggerFilter))

            if rule.isCaseSensitive {
                buffer.append(",\"url-filter-is-case-sensitive\":true")
            }

            if !rule.includeDomains.isEmpty {
                buffer.append(",\"if-domain\":[")
                for (dIdx, d) in rule.includeDomains.enumerated() {
                    if dIdx > 0 { buffer.append(",") }
                    buffer.append(escapeJSONString(d))
                }
                buffer.append("]")
            }

            if !rule.excludeDomains.isEmpty {
                buffer.append(",\"unless-domain\":[")
                for (dIdx, d) in rule.excludeDomains.enumerated() {
                    if dIdx > 0 { buffer.append(",") }
                    buffer.append(escapeJSONString(d))
                }
                buffer.append("]")
            }

            if !rule.resourceTypes.isEmpty {
                buffer.append(",\"resource-type\":[")
                for (rIdx, r) in rule.resourceTypes.enumerated() {
                    if rIdx > 0 { buffer.append(",") }
                    buffer.append(escapeJSONString(r))
                }
                buffer.append("]")
            }

            if !rule.loadTypes.isEmpty {
                buffer.append(",\"load-type\":[")
                for (lIdx, l) in rule.loadTypes.enumerated() {
                    if lIdx > 0 { buffer.append(",") }
                    buffer.append(escapeJSONString(l))
                }
                buffer.append("]")
            }

            buffer.append("},\"action\":{\"type\":")
            buffer.append(rule.isException ? "\"ignore-previous-rules\"}}" : "\"block\"}}")
        }

        buffer.append("]")
        return buffer
    }

    private func loadAllMetadataFromDisk() -> [String: AdBlockCompiledSourceMetadata] {
        var result: [String: AdBlockCompiledSourceMetadata] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(at: storageDirectoryURL, includingPropertiesForKeys: nil) else {
            return result
        }
        for file in files where file.lastPathComponent.hasPrefix("meta_") && file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let meta = try? JSONDecoder().decode(AdBlockCompiledSourceMetadata.self, from: data) {
                result[meta.sourceId] = meta
            }
        }
        return result
    }

    private func saveMetadata(_ metadata: AdBlockCompiledSourceMetadata) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metadataFileURL(sourceId: metadata.sourceId), options: .atomic)
    }

    private func deleteMetadataFile(sourceId: String) {
        try? FileManager.default.removeItem(at: metadataFileURL(sourceId: sourceId))
    }

    private func compilerErrorDescription(_ error: Error?) -> String {
        guard let error = error else {
            return "WebKit 未返回具体错误"
        }

        let nsError = error as NSError
        var parts: [String] = [nsError.localizedDescription]

        if !nsError.userInfo.isEmpty {
            parts.append("userInfo: \(nsError.userInfo)")
        }

        return parts.joined(separator: "\n")
    }

    private func loadDiagnosticRulesFromDisk(sourceId: String) -> [AdBlockUnsupportedRule] {
        let file = diagnosticFileURL(sourceId: sourceId)
        guard let data = try? Data(contentsOf: file),
              let rules = try? JSONDecoder().decode([AdBlockUnsupportedRule].self, from: data) else {
            return []
        }
        return rules
    }

    private func saveDiagnosticRulesToDisk(sourceId: String, rules: [AdBlockUnsupportedRule]) {
        let url = diagnosticFileURL(sourceId: sourceId)
        if rules.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func deleteDiagnosticFile(sourceId: String) {
        try? FileManager.default.removeItem(at: diagnosticFileURL(sourceId: sourceId))
    }
}

struct AdBlockCompiledSourceMetadata: Codable {
    var sourceId: String
    var ruleListIdentifiers: [String]
    var ruleCount: Int
    var skippedRuleCount: Int
}

private struct AdBlockSourcePayload {
    var networkChunks: [[AdBlockCompactNetworkRule]]
    var cosmeticRules: [AdBlockCosmeticRule]
    var cosmeticExceptions: [AdBlockCosmeticException]
    var ruleCount: Int
    var skippedRuleCount: Int
}

private struct AdBlockParsedLine {
    var networkRule: AdBlockCompactNetworkRule?
    var isException: Bool
    var cosmeticRules: [AdBlockCosmeticRule]
    var cosmeticExceptions: [AdBlockCosmeticException]
    var isUnsupported: Bool
}

private struct AdBlockCompactNetworkRule {
    var rawRule: String
    var triggerFilter: String
    var isCaseSensitive: Bool
    var includeDomains: [String]
    var excludeDomains: [String]
    var resourceTypes: [String]
    var loadTypes: [String]
    var isException: Bool
}

private struct AdBlockUnsupportedRule: Codable {
    var rawRule: String
    var compiledJSON: String
    var errorDescription: String
}

private final class AdBlockChunkCompilationGate {
    private let lock = NSLock()
    private var resolved = false

    func resolve(_ handler: () -> Void) {
        lock.lock()

        guard !resolved else {
            lock.unlock()
            return
        }

        resolved = true
        lock.unlock()

        handler()
    }
}

struct AdBlockCosmeticRule: Codable {
    var domains: [String]
    var excludedDomains: [String]
    var selector: String

    enum CodingKeys: String, CodingKey {
        case domains, excludedDomains, selector
    }

    init(domains: [String], excludedDomains: [String] = [], selector: String) {
        self.domains = domains
        self.excludedDomains = excludedDomains
        self.selector = selector
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.domains = try container.decode([String].self, forKey: .domains)
        self.excludedDomains = try container.decodeIfPresent([String].self, forKey: .excludedDomains) ?? []
        self.selector = try container.decode(String.self, forKey: .selector)
    }
}

struct AdBlockCosmeticException: Codable {
    var domains: [String]
    var selector: String
}
