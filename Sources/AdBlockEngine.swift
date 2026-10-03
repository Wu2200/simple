import UIKit
import WebKit
import Darwin

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
    private let metadataKey = "adblock_compiled_metadata_v9"
    private let identifierPrefix = "SimpleBrowserAdBlockV9"
    private let diagnosticKey = "adblock_unsupported_rules_v1"

    private let nativeRuleChunkSize = 4000
    private let maximumCosmeticRulesPerSource = 20000
    private let maximumCompilationDuration: TimeInterval = 180
    private let autoUpdateInterval: TimeInterval = 86400
    private let autoUpdateRetryCooldown: TimeInterval = 1800

    private var attachedWebViews = NSHashTable<WKWebView>.weakObjects()
    private var compiledListsBySource: [String: [WKContentRuleList]] = [:]
    private var cosmeticScriptsBySource: [String: [WKUserScript]] = [:]
    private var metadataBySource: [String: AdBlockCompiledSourceMetadata] = [:]
    private var unsupportedRulesBySource: [String: [AdBlockUnsupportedRule]] = [:]
    private var updatingSourceIds = Set<String>()
    private var cancelledSourceIds = Set<String>()
    private var updateStatusBySource: [String: String] = [:]
    private var lastAutoUpdateAttemptBySource: [String: Date] = [:]
    private var activeDownloadTasks: [String: URLSessionDataTask] = [:]
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

    private init() {
        if UserDefaults.standard.object(forKey: enabledKey) == nil {
            UserDefaults.standard.set(true, forKey: enabledKey)
        }

        metadataBySource = loadMetadata()
        unsupportedRulesBySource = loadUnsupportedRules()

        let validSubs = loadSubscriptions()
        let customText = getCustomRules().trimmingCharacters(in: .whitespacesAndNewlines)

        if validSubs.isEmpty && customText.isEmpty {
            purgeAllResidualData()
        } else {
            cleanOrphanedMetadataOnStartup()
            cleanupOrphanedRuleLists()
            restorePersistedRules()
        }

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

    private func slotIdentifier(sourceId: String, slotIndex: Int) -> String {
        let cleanId = sourceId.replacingOccurrences(of: "-", with: "")
        return "\(identifierPrefix)_\(cleanId)_\(slotIndex)"
    }

    func purgeAllResidualData(completion: (() -> Void)? = nil) {
        stateLock.lock()
        metadataBySource.removeAll()
        compiledListsBySource.removeAll()
        cosmeticScriptsBySource.removeAll()
        unsupportedRulesBySource.removeAll()
        updatingSourceIds.removeAll()
        updateStatusBySource.removeAll()
        cancelledSourceIds.removeAll()
        for task in activeDownloadTasks.values {
            task.cancel()
        }
        activeDownloadTasks.removeAll()
        stateLock.unlock()

        UserDefaults.standard.removeObject(forKey: metadataKey)
        UserDefaults.standard.removeObject(forKey: diagnosticKey)
        UserDefaults.standard.removeObject(forKey: customRulesKey)
        UserDefaults.standard.synchronize()

        cleanupAllLocalFiles()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                completion?()
                return
            }

            self.applyRulesToAttachedWebViews()

            WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { identifiers in
                guard let available = identifiers, !available.isEmpty else {
                    self.performDeepMemoryRelief()
                    completion?()
                    return
                }

                let group = DispatchGroup()
                for identifier in available {
                    if identifier.hasPrefix("SimpleBrowserAdBlock") || identifier.hasPrefix("simple_ab_") {
                        group.enter()
                        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in
                            group.leave()
                        }
                    }
                }

                group.notify(queue: .main) {
                    self.performDeepMemoryRelief()
                    completion?()
                }
            }
        }
    }

    private func cleanOrphanedMetadataOnStartup() {
        let validSubs = loadSubscriptions()
        let customText = getCustomRules().trimmingCharacters(in: .whitespacesAndNewlines)
        var validIds = Set(validSubs.map(\.id))
        if !customText.isEmpty {
            validIds.insert(Self.customSourceId)
        }

        stateLock.lock()
        var changed = false
        var identifiersToRemove: [String] = []
        for id in Array(metadataBySource.keys) {
            if !validIds.contains(id) {
                if let ids = metadataBySource[id]?.ruleListIdentifiers {
                    identifiersToRemove.append(contentsOf: ids)
                }
                removePhysicalFiles(for: id)
                metadataBySource.removeValue(forKey: id)
                compiledListsBySource.removeValue(forKey: id)
                cosmeticScriptsBySource.removeValue(forKey: id)
                unsupportedRulesBySource.removeValue(forKey: id)
                changed = true
            }
        }
        let metaCopy = metadataBySource
        let unsuppCopy = unsupportedRulesBySource
        stateLock.unlock()

        for identifier in identifiersToRemove {
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in }
        }

        if changed {
            saveMetadata(metaCopy)
            saveUnsupportedRules(unsuppCopy)
            performDeepMemoryRelief()
        }
    }

    private func purgeIfNoRulesRemaining() {
        let subs = loadSubscriptions()
        let customRules = getCustomRules().trimmingCharacters(in: .whitespacesAndNewlines)

        if subs.isEmpty && customRules.isEmpty {
            purgeAllResidualData()
        }
    }

    private func cleanupAllLocalFiles() {
        let rootDirectories = [
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
            URL(fileURLWithPath: NSTemporaryDirectory())
        ].compactMap { $0 }

        for root in rootDirectories {
            guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
                continue
            }

            for fileURL in fileURLs {
                let name = fileURL.lastPathComponent
                if name.hasPrefix("adblock_") || name.contains("SimpleBrowserAdBlock") || name.contains("simple_ab_") {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
    }

    private func removePhysicalFiles(for sourceId: String) {
        try? FileManager.default.removeItem(at: subscriptionFileURL(id: sourceId))
        try? FileManager.default.removeItem(at: cosmeticFileURL(id: sourceId))

        let cleanId = sourceId.replacingOccurrences(of: "-", with: "")
        let searchDirectories = [
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
            URL(fileURLWithPath: NSTemporaryDirectory())
        ].compactMap { $0 }

        for directory in searchDirectories {
            guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }
            for fileURL in fileURLs {
                let filename = fileURL.lastPathComponent
                if filename.contains(cleanId) || filename.contains(sourceId) {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
    }

    func cleanupOrphanedRuleLists(completion: (() -> Void)? = nil) {
        stateLock.lock()
        let validSubs = loadSubscriptions()
        let customText = getCustomRules().trimmingCharacters(in: .whitespacesAndNewlines)
        var activeIds = Set(validSubs.map(\.id))
        if !customText.isEmpty {
            activeIds.insert(Self.customSourceId)
        }

        var activeRuleListIdentifiers = Set<String>()
        for sourceId in activeIds {
            if let ids = metadataBySource[sourceId]?.ruleListIdentifiers {
                activeRuleListIdentifiers.formUnion(ids)
            }
        }
        stateLock.unlock()

        WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { [weak self] identifiers in
            guard let available = identifiers else {
                completion?()
                return
            }

            let group = DispatchGroup()
            for identifier in available {
                let isManaged = identifier.hasPrefix("SimpleBrowserAdBlock") || identifier.hasPrefix("simple_ab_")
                if isManaged && !activeRuleListIdentifiers.contains(identifier) {
                    group.enter()
                    WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) {
                self?.performDeepMemoryRelief()
                completion?()
            }
        }
    }

    private func performDeepMemoryRelief() {
        URLCache.shared.removeAllCachedResponses()
        malloc_zone_pressure_relief(nil, 0)
        WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeDiskCache],
            modifiedSince: .distantPast,
            completionHandler: {}
        )
    }

    private func isSourceActive(_ sourceId: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        if cancelledSourceIds.contains(sourceId) {
            return false
        }

        if sourceId == Self.customSourceId {
            let text = getCustomRules().trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty
        }

        let subscriptions = loadSubscriptions()
        return subscriptions.contains(where: { $0.id == sourceId })
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
        UserDefaults.standard.synchronize()
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

        let trimmed = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: customRulesKey)
            UserDefaults.standard.synchronize()
            deactivateSource(id: Self.customSourceId)
            completion?(true, nil)
            return
        }

        UserDefaults.standard.set(rules, forKey: customRulesKey)
        UserDefaults.standard.synchronize()
        stateLock.lock()
        cancelledSourceIds.remove(Self.customSourceId)
        stateLock.unlock()

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
        stateLock.lock()
        defer { stateLock.unlock() }
        return unsupportedRulesBySource[sourceId]?.count ?? 0
    }

    func unsupportedRulesText(sourceId: String) -> String {
        stateLock.lock()
        let rules = unsupportedRulesBySource[sourceId] ?? []
        stateLock.unlock()

        guard !rules.isEmpty else {
            return "没有检测到不兼容规则。"
        }

        return rules.enumerated().map { index, item in
            let errorText = item.errorDescription.isEmpty ? "未返回具体错误" : item.errorDescription

            return """
            [\(index + 1)]
            规则标识:
            \(item.rawRule)

            转换后的 WebKit 规则:
            \(item.compiledJSON)

            编译错误:
            \(errorText)
            """
        }.joined(separator: "\n\n--------------------\n\n")
    }

    func clearUnsupportedRules(sourceId: String) {
        stateLock.lock()
        unsupportedRulesBySource.removeValue(forKey: sourceId)
        let copy = unsupportedRulesBySource
        stateLock.unlock()
        saveUnsupportedRules(copy)
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
            webView.evaluateJavaScript("""
            (function() {
                var el = document.getElementById('__simple_browser_adblock_style__');
                if (el) el.remove();
            })();
            """, completionHandler: nil)
            return
        }

        if let host = webView.url?.host, !DomainSettingsStore.shared.getBool(domain: host, setting: "adBlock", defaultVal: true) {
            webView.evaluateJavaScript("""
            (function() {
                var el = document.getElementById('__simple_browser_adblock_style__');
                if (el) el.remove();
            })();
            """, completionHandler: nil)
            return
        }

        let enabledSubs = Set(loadSubscriptions().filter { $0.isEnabled }.map { $0.id })

        stateLock.lock()
        let compiledListsCopy = compiledListsBySource
        let cosmeticScriptsCopy = cosmeticScriptsBySource
        stateLock.unlock()

        if compiledListsCopy.isEmpty && cosmeticScriptsCopy.isEmpty {
            webView.evaluateJavaScript("""
            (function() {
                var el = document.getElementById('__simple_browser_adblock_style__');
                if (el) el.remove();
            })();
            """, completionHandler: nil)
            return
        }

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
        cancelledSourceIds.remove(subscription.id)
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
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            defer {
                session.finishTasksAndInvalidate()
            }

            guard let self = self else { return }

            self.stateLock.lock()
            self.activeDownloadTasks.removeValue(forKey: subscription.id)
            let isCancelled = self.cancelledSourceIds.contains(subscription.id)
            self.stateLock.unlock()

            if isCancelled {
                DispatchQueue.main.async {
                    self.setUpdateStatus(sourceId: subscription.id, status: nil)
                    completion(false, 0, "更新已取消")
                }
                return
            }

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

            guard self.isSourceActive(subscription.id) else {
                DispatchQueue.main.async {
                    self.stateLock.lock()
                    self.updatingSourceIds.remove(subscription.id)
                    self.stateLock.unlock()
                    self.setUpdateStatus(sourceId: subscription.id, status: nil)
                    completion(false, 0, "订阅已删除")
                }
                return
            }

            do {
                try data.write(to: self.subscriptionFileURL(id: subscription.id), options: .atomic)
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
        }

        stateLock.lock()
        activeDownloadTasks[subscription.id] = task
        stateLock.unlock()
        task.resume()
    }

    private func restorePersistedRules() {
        parseQueue.async { [weak self] in
            guard let self = self else { return }

            self.stateLock.lock()
            let metadataCopy = self.metadataBySource
            self.stateLock.unlock()

            for sourceId in metadataCopy.keys.sorted() {
                guard let metadata = metadataCopy[sourceId], self.isSourceActive(sourceId) else {
                    continue
                }

                if metadata.ruleListIdentifiers.isEmpty {
                    self.restoreCosmeticScripts(sourceId: sourceId)
                    continue
                }

                self.loadRuleListsSequentially(identifiers: metadata.ruleListIdentifiers, index: 0, loaded: []) { [weak self] lists in
                    guard let self = self else { return }

                    if lists.count == metadata.ruleListIdentifiers.count {
                        self.stateLock.lock()
                        self.compiledListsBySource[sourceId] = lists
                        self.stateLock.unlock()
                        self.restoreCosmeticScripts(sourceId: sourceId)
                        self.applyRulesToAttachedWebViews()
                    } else {
                        self.compileSource(id: sourceId, completion: nil)
                    }
                }
            }
        }
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

        guard isSourceActive(sourceId) else {
            deactivateSource(id: sourceId)
            completion?(true, nil)
            return
        }

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

            guard self.isSourceActive(sourceId) else {
                self.stateLock.lock()
                self.updatingSourceIds.remove(sourceId)
                self.updateStatusBySource.removeValue(forKey: sourceId)
                self.stateLock.unlock()
                return
            }

            let payload = self.buildSourcePayload(text: text)

            guard self.isSourceActive(sourceId) else {
                self.stateLock.lock()
                self.updatingSourceIds.remove(sourceId)
                self.updateStatusBySource.removeValue(forKey: sourceId)
                self.stateLock.unlock()
                return
            }

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

    private func compilePayload(
        _ payload: AdBlockSourcePayload,
        sourceId: String,
        completion: ((Bool, String?) -> Void)?
    ) {
        guard isSourceActive(sourceId) else {
            stateLock.lock()
            updatingSourceIds.remove(sourceId)
            updateStatusBySource.removeValue(forKey: sourceId)
            stateLock.unlock()
            return
        }

        saveCosmeticCache(sourceId: sourceId, rules: payload.cosmeticRules)

        guard !payload.networkChunks.isEmpty else {
            stateLock.lock()
            let oldIdentifiers = metadataBySource[sourceId]?.ruleListIdentifiers ?? []
            stateLock.unlock()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                for id in oldIdentifiers {
                    WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in }
                }

                let metadata = AdBlockCompiledSourceMetadata(
                    sourceId: sourceId,
                    ruleListIdentifiers: [],
                    ruleCount: payload.ruleCount,
                    skippedRuleCount: payload.skippedRuleCount
                )

                self.stateLock.lock()
                self.metadataBySource[sourceId] = metadata
                self.compiledListsBySource.removeValue(forKey: sourceId)
                self.unsupportedRulesBySource[sourceId] = []
                let metaCopy = self.metadataBySource
                let unsuppCopy = self.unsupportedRulesBySource
                self.updatingSourceIds.remove(sourceId)
                self.stateLock.unlock()

                self.saveMetadata(metaCopy)
                self.saveUnsupportedRules(unsuppCopy)
                self.cleanupOrphanedRuleLists()
                self.performDeepMemoryRelief()

                self.parseQueue.async {
                    self.restoreCosmeticScripts(sourceId: sourceId)
                    DispatchQueue.main.async {
                        self.setUpdateStatus(sourceId: sourceId, status: nil)
                        self.applyRulesToAttachedWebViews()

                        let message = payload.skippedRuleCount > 0
                            ? "已更新，跳过 \(payload.skippedRuleCount) 条不兼容规则"
                            : nil

                        completion?(true, message)
                    }
                }
            }
            return
        }

        let deadline = Date().addingTimeInterval(maximumCompilationDuration)

        stateLock.lock()
        unsupportedRulesBySource[sourceId] = []
        stateLock.unlock()

        compileChunks(
            chunks: payload.networkChunks,
            sourceId: sourceId,
            index: 0,
            compiledLists: [],
            compiledIdentifiers: [],
            deadline: deadline
        ) { [weak self] lists, identifiers in
            guard let self = self else { return }

            guard self.isSourceActive(sourceId) else {
                for identifier in identifiers {
                    WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier, completionHandler: { _ in })
                }
                self.stateLock.lock()
                self.updatingSourceIds.remove(sourceId)
                self.updateStatusBySource.removeValue(forKey: sourceId)
                self.stateLock.unlock()
                self.cleanupOrphanedRuleLists()
                self.purgeIfNoRulesRemaining()
                return
            }

            if lists.isEmpty && payload.cosmeticRules.isEmpty {
                self.stateLock.lock()
                self.updatingSourceIds.remove(sourceId)
                self.stateLock.unlock()
                self.setUpdateStatus(sourceId: sourceId, status: nil)
                DispatchQueue.main.async {
                    completion?(false, "规则编译超时或所有规则块均不兼容")
                }
                return
            }

            self.stateLock.lock()
            let oldIdentifiers = self.metadataBySource[sourceId]?.ruleListIdentifiers ?? []
            self.stateLock.unlock()

            let newIdSet = Set(identifiers)
            for id in oldIdentifiers where !newIdSet.contains(id) {
                WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in }
            }

            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                ruleListIdentifiers: identifiers,
                ruleCount: payload.ruleCount,
                skippedRuleCount: payload.skippedRuleCount + self.unsupportedRuleCount(sourceId: sourceId)
            )

            self.stateLock.lock()
            self.metadataBySource[sourceId] = metadata
            self.compiledListsBySource[sourceId] = lists
            self.updatingSourceIds.remove(sourceId)
            let metaCopy = self.metadataBySource
            let unsuppCopy = self.unsupportedRulesBySource
            self.stateLock.unlock()

            self.saveMetadata(metaCopy)
            self.saveUnsupportedRules(unsuppCopy)
            self.cleanupOrphanedRuleLists()
            self.performDeepMemoryRelief()

            self.parseQueue.async {
                self.restoreCosmeticScripts(sourceId: sourceId)
                DispatchQueue.main.async {
                    self.setUpdateStatus(sourceId: sourceId, status: nil)
                    self.applyRulesToAttachedWebViews()

                    let unsupportedCount = self.unsupportedRuleCount(sourceId: sourceId)
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
    }

    private func compileChunks(
        chunks: [[String]],
        sourceId: String,
        index: Int,
        compiledLists: [WKContentRuleList],
        compiledIdentifiers: [String],
        deadline: Date,
        completion: @escaping ([WKContentRuleList], [String]) -> Void
    ) {
        guard isSourceActive(sourceId) else {
            completion([], [])
            return
        }

        guard index < chunks.count else {
            completion(compiledLists, compiledIdentifiers)
            return
        }

        guard Date() < deadline else {
            completion(compiledLists, compiledIdentifiers)
            return
        }

        setUpdateStatus(
            sourceId: sourceId,
            status: "正在编译规则 \(index + 1)/\(chunks.count)…"
        )

        let targetIdentifier = slotIdentifier(sourceId: sourceId, slotIndex: index)
        let chunkRules = chunks[index]

        compileRuleGroup(
            rules: chunkRules,
            sourceId: sourceId,
            identifier: targetIdentifier,
            depth: 0,
            deadline: deadline
        ) { [weak self] subLists, subIdentifiers in
            guard let self = self else { return }

            guard self.isSourceActive(sourceId) else {
                for id in subIdentifiers {
                    WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in }
                }
                completion([], [])
                return
            }

            self.compileChunks(
                chunks: chunks,
                sourceId: sourceId,
                index: index + 1,
                compiledLists: compiledLists + subLists,
                compiledIdentifiers: compiledIdentifiers + subIdentifiers,
                deadline: deadline,
                completion: completion
            )
        }
    }

    private func compileRuleGroup(
        rules: [String],
        sourceId: String,
        identifier: String,
        depth: Int,
        deadline: Date,
        completion: @escaping ([WKContentRuleList], [String]) -> Void
    ) {
        guard isSourceActive(sourceId) else {
            completion([], [])
            return
        }

        guard !rules.isEmpty else {
            completion([], [])
            return
        }

        guard Date() < deadline else {
            completion([], [])
            return
        }

        let json = "[" + rules.joined(separator: ",") + "]"

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            guard self.isSourceActive(sourceId) else {
                completion([], [])
                return
            }

            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { ruleList, error in
                self.parseQueue.async {
                    guard self.isSourceActive(sourceId) else {
                        if ruleList != nil {
                            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in }
                        }
                        completion([], [])
                        return
                    }

                    if let rl = ruleList {
                        completion([rl], [identifier])
                        return
                    }

                    if rules.count <= 1 || depth >= 2 {
                        for rule in rules.prefix(2) {
                            self.recordUnsupportedRule(
                                sourceId: sourceId,
                                rawFilter: rule,
                                compiledJSON: rule,
                                error: self.compilerErrorDescription(error)
                            )
                        }
                        completion([], [])
                        return
                    }

                    let middle = rules.count / 2
                    let left = Array(rules[..<middle])
                    let right = Array(rules[middle...])

                    self.compileRuleGroup(
                        rules: left,
                        sourceId: sourceId,
                        identifier: "\(identifier)A",
                        depth: depth + 1,
                        deadline: deadline
                    ) { leftLists, leftIds in
                        guard self.isSourceActive(sourceId) else {
                            for id in leftIds {
                                WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in }
                            }
                            completion([], [])
                            return
                        }

                        self.compileRuleGroup(
                            rules: right,
                            sourceId: sourceId,
                            identifier: "\(identifier)B",
                            depth: depth + 1,
                            deadline: deadline
                        ) { rightLists, rightIds in
                            guard self.isSourceActive(sourceId) else {
                                for id in leftIds + rightIds {
                                    WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in }
                                }
                                completion([], [])
                                return
                            }

                            completion(leftLists + rightLists, leftIds + rightIds)
                        }
                    }
                }
            }
        }
    }

    private func deactivateSource(id sourceId: String) {
        stateLock.lock()
        activeDownloadTasks[sourceId]?.cancel()
        activeDownloadTasks.removeValue(forKey: sourceId)
        cancelledSourceIds.insert(sourceId)
        updatingSourceIds.remove(sourceId)
        updateStatusBySource.removeValue(forKey: sourceId)

        let identifiersToRemove = metadataBySource[sourceId]?.ruleListIdentifiers ?? []

        metadataBySource.removeValue(forKey: sourceId)
        compiledListsBySource.removeValue(forKey: sourceId)
        cosmeticScriptsBySource.removeValue(forKey: sourceId)
        unsupportedRulesBySource.removeValue(forKey: sourceId)
        let metaCopy = metadataBySource
        let unsuppCopy = unsupportedRulesBySource
        stateLock.unlock()

        removePhysicalFiles(for: sourceId)
        saveMetadata(metaCopy)
        saveUnsupportedRules(unsuppCopy)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.applyRulesToAttachedWebViews()

            let cleanId = sourceId.replacingOccurrences(of: "-", with: "")
            WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { identifiers in
                guard let available = identifiers, !available.isEmpty else {
                    self.purgeIfNoRulesRemaining()
                    self.performDeepMemoryRelief()
                    return
                }

                let targetSet = Set(identifiersToRemove)
                let group = DispatchGroup()
                for id in available {
                    if targetSet.contains(id) || id.contains(cleanId) {
                        group.enter()
                        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in
                            group.leave()
                        }
                    }
                }

                group.notify(queue: .main) {
                    self.cleanupOrphanedRuleLists()
                    self.purgeIfNoRulesRemaining()
                    self.performDeepMemoryRelief()
                }
            }
        }
    }

    private func saveCosmeticCache(
        sourceId: String,
        rules: [AdBlockCosmeticRule]
    ) {
        guard !rules.isEmpty else {
            try? FileManager.default.removeItem(at: cosmeticFileURL(id: sourceId))
            return
        }

        guard let data = try? JSONEncoder().encode(rules) else {
            return
        }
        try? data.write(to: cosmeticFileURL(id: sourceId), options: .atomic)
    }

    private func restoreCosmeticScripts(sourceId: String) {
        guard let data = try? Data(contentsOf: cosmeticFileURL(id: sourceId)),
              let rules = try? JSONDecoder().decode([AdBlockCosmeticRule].self, from: data),
              !rules.isEmpty else {
            stateLock.lock()
            cosmeticScriptsBySource.removeValue(forKey: sourceId)
            stateLock.unlock()
            return
        }

        guard let rulesData = try? JSONEncoder().encode(rules),
              let rulesJson = String(data: rulesData, encoding: .utf8) else {
            return
        }

        let scriptSource = """
        (function() {
            var rules = \(rulesJson);
            var styleId = '__simple_browser_adblock_style__';
            var host = (location.hostname || '').toLowerCase();
            var fallbackSelectors = [];

            function matches(rule) {
                if (rule.excludedDomains && rule.excludedDomains.length > 0) {
                    for (var i = 0; i < rule.excludedDomains.length; i++) {
                        var d = rule.excludedDomains[i];
                        if (host === d || host.endsWith('.' + d)) return false;
                    }
                }
                if (!rule.domains || rule.domains.length === 0) return true;
                for (var j = 0; j < rule.domains.length; j++) {
                    var d2 = rule.domains[j];
                    if (host === d2 || host.endsWith('.' + d2)) return true;
                }
                return false;
            }

            function applyCSS() {
                var style = document.getElementById(styleId);
                if (!style) {
                    style = document.createElement('style');
                    style.id = styleId;
                    style.type = 'text/css';
                    (document.head || document.documentElement).appendChild(style);
                }
                var sheet = style.sheet;
                if (!sheet) return;

                for (var i = 0; i < rules.length; i++) {
                    var r = rules[i];
                    if (!matches(r)) continue;
                    try {
                        sheet.insertRule(r.selector + '{display:none !important;visibility:hidden !important;pointer-events:none !important;}', sheet.cssRules.length);
                    } catch(e) {
                        fallbackSelectors.push(r.selector);
                    }
                }
            }

            function applyFallback() {
                for (var i = 0; i < fallbackSelectors.length; i++) {
                    try {
                        var nodes = document.querySelectorAll(fallbackSelectors[i]);
                        for (var j = 0; j < nodes.length; j++) {
                            nodes[j].style.setProperty('display', 'none', 'important');
                            nodes[j].style.setProperty('visibility', 'hidden', 'important');
                            nodes[j].style.setProperty('pointer-events', 'none', 'important');
                        }
                    } catch(e) {}
                }
            }

            function run() {
                applyCSS();
                if (fallbackSelectors.length > 0) {
                    applyFallback();
                    var obs = new MutationObserver(function() {
                        applyFallback();
                    });
                    obs.observe(document.documentElement || document.body, { childList: true, subtree: true });
                }
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', run, { once: true });
            } else {
                run();
            }
        })();
        """

        let script = WKUserScript(
            source: scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )

        stateLock.lock()
        cosmeticScriptsBySource[sourceId] = [script]
        stateLock.unlock()
    }

    private func sourceText(id sourceId: String) -> String? {
        if sourceId == Self.customSourceId {
            let text = getCustomRules()
            return text.isEmpty ? nil : text
        }

        return try? String(
            contentsOf: subscriptionFileURL(id: sourceId),
            encoding: .utf8
        )
    }

    private func buildSourcePayload(text: String) -> AdBlockSourcePayload {
        var allBlockRules: [String] = []
        var allExceptionRules: [String] = []
        var cosmeticRules: [AdBlockCosmeticRule] = []
        var ruleCount = 0
        var skippedRuleCount = 0
        var lineCount = 0

        text.enumerateLines { line, _ in
            autoreleasepool {
                let parsed = self.parseRuleToJSON(line)
                if let json = parsed.networkJSON {
                    if parsed.isException {
                        allExceptionRules.append(json)
                    } else {
                        allBlockRules.append(json)
                    }
                    ruleCount += 1
                }

                if let cosmetic = parsed.cosmeticRule {
                    if cosmeticRules.count < self.maximumCosmeticRulesPerSource {
                        cosmeticRules.append(cosmetic)
                    } else {
                        skippedRuleCount += 1
                    }
                    ruleCount += 1
                }

                if parsed.isUnsupported {
                    skippedRuleCount += 1
                }
            }

            lineCount += 1
            if lineCount >= 10000 {
                lineCount = 0
                malloc_zone_pressure_relief(nil, 0)
            }
        }

        var allNetworkChunks: [[String]] = []

        if !allBlockRules.isEmpty {
            for start in stride(from: 0, to: allBlockRules.count, by: nativeRuleChunkSize) {
                let chunk = Array(allBlockRules[start..<min(start + nativeRuleChunkSize, allBlockRules.count)])
                allNetworkChunks.append(chunk)
            }
        }

        if !allExceptionRules.isEmpty {
            for start in stride(from: 0, to: allExceptionRules.count, by: nativeRuleChunkSize) {
                let chunk = Array(allExceptionRules[start..<min(start + nativeRuleChunkSize, allExceptionRules.count)])
                allNetworkChunks.append(chunk)
            }
        }

        return AdBlockSourcePayload(
            networkChunks: allNetworkChunks,
            cosmeticRules: cosmeticRules,
            ruleCount: ruleCount,
            skippedRuleCount: skippedRuleCount
        )
    }

    private func isValidDomain(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.count <= 253, !domain.hasPrefix("."), !domain.hasSuffix(".") else {
            return false
        }
        return domain.allSatisfy { ch in
            (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") || ch == "-" || ch == "."
        }
    }

    private func parseRuleToJSON(_ rawLine: String) -> AdBlockParsedLineResult {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty,
              !line.hasPrefix("!"),
              !line.hasPrefix("！"),
              !line.hasPrefix("[") else {
            return AdBlockParsedLineResult(networkJSON: nil, isException: false, cosmeticRule: nil, isUnsupported: false)
        }

        if line.contains("##+js") || line.contains("#%#") {
            return AdBlockParsedLineResult(networkJSON: nil, isException: false, cosmeticRule: nil, isUnsupported: true)
        }

        if line.contains("#@#") {
            return AdBlockParsedLineResult(networkJSON: nil, isException: false, cosmeticRule: nil, isUnsupported: false)
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
            let selectorText = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !selectorText.isEmpty,
                  selectorText.count <= 2048,
                  !selectorText.contains("{"),
                  !selectorText.contains("}"),
                  !selectorText.contains("\u{0000}") else {
                return AdBlockParsedLineResult(networkJSON: nil, isException: false, cosmeticRule: nil, isUnsupported: true)
            }

            let parsedDomains = normalizedDomains(from: domainsText)
            let rule = AdBlockCosmeticRule(
                domains: parsedDomains.include,
                excludedDomains: parsedDomains.exclude,
                selector: selectorText
            )

            return AdBlockParsedLineResult(networkJSON: nil, isException: false, cosmeticRule: rule, isUnsupported: false)
        }

        let isException = line.hasPrefix("@@")
        if isException {
            line = String(line.dropFirst(2))
        }

        let parts = line.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPattern = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawPattern.isEmpty else {
            return AdBlockParsedLineResult(networkJSON: nil, isException: false, cosmeticRule: nil, isUnsupported: true)
        }

        let options = parts.count > 1 ? String(parts[1]).split(separator: ",").map(String.init) : []

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
                    return AdBlockParsedLineResult(networkJSON: nil, isException: false, cosmeticRule: nil, isUnsupported: true)
                }
                let domains = normalizedDomains(from: domainStr, separator: "|")
                includeDomains.append(contentsOf: domains.include)
                excludeDomains.append(contentsOf: domains.exclude)
            } else if option.hasPrefix("denyallow=") {
                let domainStr = String(option.dropFirst(10))
                if domainStr.contains("/") {
                    return AdBlockParsedLineResult(networkJSON: nil, isException: false, cosmeticRule: nil, isUnsupported: true)
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
            } else if option == "badfilter" || option.hasPrefix("removeparam") || option.hasPrefix("csp") {
                return AdBlockParsedLineResult(networkJSON: nil, isException: false, cosmeticRule: nil, isUnsupported: true)
            }
        }

        let filter: String
        if rawPattern.hasPrefix("/") && rawPattern.hasSuffix("/") && rawPattern.count > 2 {
            let inside = String(rawPattern.dropFirst().dropLast())
            if inside.contains("(?") || inside.contains("\\1") || inside.contains("\\2") {
                return AdBlockParsedLineResult(networkJSON: nil, isException: false, cosmeticRule: nil, isUnsupported: true)
            }
            filter = inside
        } else {
            filter = urlFilterPattern(from: rawPattern)
        }

        guard isValidWebKitPattern(filter) else {
            return AdBlockParsedLineResult(networkJSON: nil, isException: false, cosmeticRule: nil, isUnsupported: true)
        }

        let validInclude = includeDomains.filter(isValidDomain)
        let validExclude = excludeDomains.filter(isValidDomain)

        let json = formatNetworkRuleJSON(
            filter: filter,
            isCaseSensitive: isCaseSensitive,
            isException: isException,
            includeDomains: validInclude,
            excludeDomains: validExclude,
            resourceTypes: resourceTypes,
            loadTypes: loadTypes
        )

        return AdBlockParsedLineResult(
            networkJSON: json,
            isException: isException,
            cosmeticRule: nil,
            isUnsupported: false
        )
    }

    private func formatNetworkRuleJSON(
        filter: String,
        isCaseSensitive: Bool,
        isException: Bool,
        includeDomains: [String],
        excludeDomains: [String],
        resourceTypes: [String],
        loadTypes: [String]
    ) -> String {
        var triggerParts: [String] = []
        triggerParts.append("\"url-filter\":\"\(escapeJSONString(filter))\"")
        if isCaseSensitive {
            triggerParts.append("\"url-filter-is-case-sensitive\":true")
        }
        if !includeDomains.isEmpty {
            let unique = Array(Set(includeDomains)).sorted()
            let joined = unique.map { "\"\(escapeJSONString($0))\"" }.joined(separator: ",")
            triggerParts.append("\"if-domain\":[\(joined)]")
        }
        if !excludeDomains.isEmpty {
            let unique = Array(Set(excludeDomains)).sorted()
            let joined = unique.map { "\"\(escapeJSONString($0))\"" }.joined(separator: ",")
            triggerParts.append("\"unless-domain\":[\(joined)]")
        }
        if !resourceTypes.isEmpty {
            let unique = Array(Set(resourceTypes)).sorted()
            let joined = unique.map { "\"\(escapeJSONString($0))\"" }.joined(separator: ",")
            triggerParts.append("\"resource-type\":[\(joined)]")
        }
        if !loadTypes.isEmpty {
            let unique = Array(Set(loadTypes)).sorted()
            let joined = unique.map { "\"\(escapeJSONString($0))\"" }.joined(separator: ",")
            triggerParts.append("\"load-type\":[\(joined)]")
        }

        let actionType = isException ? "ignore-previous-rules" : "block"
        return "{\"trigger\":{\(triggerParts.joined(separator: ","))},\"action\":{\"type\":\"\(actionType)\"}}"
    }

    private func escapeJSONString(_ str: String) -> String {
        var result = ""
        result.reserveCapacity(str.count + 8)
        for scalar in str.unicodeScalars {
            switch scalar {
            case "\"":
                result.append("\\\"")
            case "\\":
                result.append("\\\\")
            case "\n":
                result.append("\\n")
            case "\r":
                result.append("\\r")
            case "\t":
                result.append("\\t")
            default:
                result.append(String(scalar))
            }
        }
        return result
    }

    private func isValidWebKitPattern(_ pattern: String) -> Bool {
        guard !pattern.isEmpty,
              pattern.count < 512,
              pattern.allSatisfy({ $0.isASCII && $0 >= " " && $0.asciiValue! < 127 }),
              !pattern.contains("(?"),
              !pattern.contains("[:"),
              !pattern.contains("\\1"),
              !pattern.contains("\\2"),
              !pattern.contains("\\3") else {
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

        return (try? NSRegularExpression(pattern: pattern)) != nil
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

    private func subscriptionFileURL(id: String) -> URL {
        let directory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        return directory.appendingPathComponent(
            "adblock_subscription_\(id).txt"
        )
    }

    private func cosmeticFileURL(id: String) -> URL {
        let directory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        return directory.appendingPathComponent(
            "adblock_cosmetic_\(id).json"
        )
    }

    private func loadMetadata() -> [String: AdBlockCompiledSourceMetadata] {
        guard let data = UserDefaults.standard.data(forKey: metadataKey),
              let metadata = try? JSONDecoder().decode(
                [String: AdBlockCompiledSourceMetadata].self,
                from: data
              ) else {
            return [:]
        }

        return metadata
    }

    private func saveMetadata(
        _ metadata: [String: AdBlockCompiledSourceMetadata]
    ) {
        guard let data = try? JSONEncoder().encode(metadata) else {
            return
        }

        UserDefaults.standard.set(data, forKey: metadataKey)
        UserDefaults.standard.synchronize()
    }

    private func recordUnsupportedRule(
        sourceId: String,
        rawFilter: String,
        compiledJSON: String,
        error: String
    ) {
        stateLock.lock()
        var items = unsupportedRulesBySource[sourceId] ?? []

        if items.count < 30 {
            let item = AdBlockUnsupportedRule(
                rawRule: rawFilter,
                compiledJSON: compiledJSON,
                errorDescription: error
            )
            items.append(item)
            unsupportedRulesBySource[sourceId] = items
        }
        stateLock.unlock()
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

    private func loadUnsupportedRules() -> [String: [AdBlockUnsupportedRule]] {
        guard let data = UserDefaults.standard.data(forKey: diagnosticKey),
              let items = try? JSONDecoder().decode(
                [String: [AdBlockUnsupportedRule]].self,
                from: data
              ) else {
            return [:]
        }

        return items
    }

    private func saveUnsupportedRules(
        _ rules: [String: [AdBlockUnsupportedRule]]
    ) {
        guard let data = try? JSONEncoder().encode(rules) else {
            return
        }

        UserDefaults.standard.set(data, forKey: diagnosticKey)
        UserDefaults.standard.synchronize()
    }
}

struct AdBlockCompiledSourceMetadata: Codable {
    var sourceId: String
    var ruleListIdentifiers: [String]
    var ruleCount: Int
    var skippedRuleCount: Int

    enum CodingKeys: String, CodingKey {
        case sourceId, ruleListIdentifiers, ruleCount, skippedRuleCount
    }
}

struct AdBlockCosmeticRule: Codable {
    var domains: [String]
    var excludedDomains: [String]
    var selector: String
}

private struct AdBlockSourcePayload {
    var networkChunks: [[String]]
    var cosmeticRules: [AdBlockCosmeticRule]
    var ruleCount: Int
    var skippedRuleCount: Int
}

private struct AdBlockParsedLineResult {
    var networkJSON: String?
    var isException: Bool
    var cosmeticRule: AdBlockCosmeticRule?
    var isUnsupported: Bool
}

private struct AdBlockUnsupportedRule: Codable {
    var rawRule: String
    var compiledJSON: String
    var errorDescription: String
}
