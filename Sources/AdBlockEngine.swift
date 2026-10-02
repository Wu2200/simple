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
    let identifierPrefix = "SimpleBrowserAdBlockV11"
    private let diagnosticKey = "adblock_unsupported_rules_v1"

    private let nativeRuleChunkSize = 8000
    private let maximumCosmeticRulesPerSource = 5000
    private let autoUpdateInterval: TimeInterval = 86400
    private let autoUpdateRetryCooldown: TimeInterval = 1800

    private var attachedWebViews = NSHashTable<WKWebView>.weakObjects()
    private var compiledListsBySource: [String: [WKContentRuleList]] = [:]
    private var cosmeticScriptsBySource: [String: [WKUserScript]] = [:]
    private var metadataBySource: [String: AdBlockCompiledSourceMetadata] = [:]
    private var unsupportedRulesBySource: [String: [AdBlockUnsupportedRule]] = [:]
    private var updatingSourceIds = Set<String>()
    private var updateStatusBySource: [String: String] = [:]
    private var lastAutoUpdateAttemptBySource: [String: Date] = [:]
    private var operationIdBySource: [String: Int] = [:]
    private var activeDownloadTasks: [String: URLSessionDownloadTask] = [:]
    private let parseQueue = DispatchQueue(label: "SimpleBrowser.AdBlockParser", qos: .userInitiated)
    private let stateLock = NSLock()

    private lazy var downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

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

        let activeSubs = loadSubscriptions()
        let activeCustom = getCustomRules().trimmingCharacters(in: .whitespacesAndNewlines)
        if activeSubs.isEmpty && activeCustom.isEmpty {
            cleanResidualData(completion: nil)
        } else {
            cleanupOrphanedSourceFiles(activeSubs: activeSubs)
            restorePersistedRules()
            purgeOrphanedRuleLists(completion: nil)
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

    private func nextOperationId(for sourceId: String) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        let next = (operationIdBySource[sourceId] ?? 0) + 1
        operationIdBySource[sourceId] = next
        return next
    }

    private func cancelOperation(for sourceId: String) {
        stateLock.lock()
        let next = (operationIdBySource[sourceId] ?? 0) + 1
        operationIdBySource[sourceId] = next
        if let task = activeDownloadTasks.removeValue(forKey: sourceId) {
            task.cancel()
        }
        updatingSourceIds.remove(sourceId)
        updateStatusBySource.removeValue(forKey: sourceId)
        stateLock.unlock()
    }

    func isOperationValid(sourceId: String, opId: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operationIdBySource[sourceId] == opId
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
        if subscriptions.isEmpty {
            UserDefaults.standard.removeObject(forKey: subscriptionsKey)
            return
        }

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

        let trimmed = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: customRulesKey)
            deactivateSource(id: Self.customSourceId)
            completion?(true, nil)
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
        cancelOperation(for: id)

        var subscriptions = loadSubscriptions()
        subscriptions.removeAll { $0.id == id }
        saveSubscriptions(subscriptions)

        deleteSubscriptionFile(id: id)
        deactivateSource(id: id)

        let activeSubs = loadSubscriptions()
        let activeCustom = getCustomRules().trimmingCharacters(in: .whitespacesAndNewlines)
        if activeSubs.isEmpty && activeCustom.isEmpty {
            cleanResidualData(completion: nil)
        } else {
            purgeOrphanedRuleLists(completion: nil)
        }
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
            completion(false, 0, "该订阅正在更新，请稍候")
            return
        }
        updatingSourceIds.insert(subscription.id)
        lastAutoUpdateAttemptBySource[subscription.id] = Date()
        stateLock.unlock()

        let opId = nextOperationId(for: subscription.id)

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

        performDownload(url: url, subscriptionId: subscription.id, opId: opId, attempt: 1) { [weak self] success, fileURL, errorMsg in
            guard let self = self else { return }

            guard self.isOperationValid(sourceId: subscription.id, opId: opId) else {
                return
            }

            guard success, let fileURL = fileURL else {
                DispatchQueue.main.async {
                    guard self.isOperationValid(sourceId: subscription.id, opId: opId) else { return }
                    self.stateLock.lock()
                    self.updatingSourceIds.remove(subscription.id)
                    self.stateLock.unlock()
                    self.setUpdateStatus(sourceId: subscription.id, status: nil)
                    completion(false, 0, errorMsg ?? "下载失败")
                }
                return
            }

            let targetURL = self.subscriptionFileURL(id: subscription.id)
            try? FileManager.default.removeItem(at: targetURL)
            do {
                try FileManager.default.moveItem(at: fileURL, to: targetURL)
            } catch {
                do {
                    try FileManager.default.copyItem(at: fileURL, to: targetURL)
                    try? FileManager.default.removeItem(at: fileURL)
                } catch {
                    DispatchQueue.main.async {
                        guard self.isOperationValid(sourceId: subscription.id, opId: opId) else { return }
                        self.stateLock.lock()
                        self.updatingSourceIds.remove(subscription.id)
                        self.stateLock.unlock()
                        self.setUpdateStatus(sourceId: subscription.id, status: nil)
                        completion(false, 0, "保存订阅文件失败")
                    }
                    return
                }
            }

            self.setUpdateStatus(
                sourceId: subscription.id,
                status: "正在解析规则…"
            )

            self.compileSource(id: subscription.id, expectedOperationId: opId) { compSuccess, compMsg in
                DispatchQueue.main.async {
                    guard self.isOperationValid(sourceId: subscription.id, opId: opId) else { return }

                    self.stateLock.lock()
                    self.updatingSourceIds.remove(subscription.id)
                    self.stateLock.unlock()
                    self.setUpdateStatus(sourceId: subscription.id, status: nil)

                    let count = self.ruleCount(sourceId: subscription.id)

                    if compSuccess {
                        var subscriptions = self.loadSubscriptions()
                        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
                            subscriptions[index].lastUpdated = Date()
                            subscriptions[index].ruleCount = count
                            self.saveSubscriptions(subscriptions)
                        }
                    }

                    completion(compSuccess, count, compMsg)
                }
            }
        }
    }

    private func performDownload(
        url: URL,
        subscriptionId: String,
        opId: Int,
        attempt: Int,
        completion: @escaping (Bool, URL?, String?) -> Void
    ) {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 120
        )

        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Version/17.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/plain, */*", forHTTPHeaderField: "Accept")

        let task = downloadSession.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self = self else { return }

            guard self.isOperationValid(sourceId: subscriptionId, opId: opId) else {
                return
            }

            self.stateLock.lock()
            self.activeDownloadTasks.removeValue(forKey: subscriptionId)
            self.stateLock.unlock()

            if let error = error {
                let nsError = error as NSError
                if (nsError.code == NSURLErrorNetworkConnectionLost || nsError.code == NSURLErrorTimedOut) && attempt < 3 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self = self, self.isOperationValid(sourceId: subscriptionId, opId: opId) else { return }
                        self.performDownload(
                            url: url,
                            subscriptionId: subscriptionId,
                            opId: opId,
                            attempt: attempt + 1,
                            completion: completion
                        )
                    }
                    return
                }
                completion(false, nil, error.localizedDescription)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(false, nil, "服务器未返回 HTTP 响应")
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                completion(false, nil, "服务器返回 HTTP \(httpResponse.statusCode)")
                return
            }

            guard let tempURL = tempURL else {
                completion(false, nil, "下载数据为空")
                return
            }

            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let persistentTempURL = cacheDir.appendingPathComponent("dl_\(subscriptionId)_\(UUID().uuidString).tmp")
            try? FileManager.default.removeItem(at: persistentTempURL)

            do {
                try FileManager.default.moveItem(at: tempURL, to: persistentTempURL)
                completion(true, persistentTempURL, nil)
            } catch {
                completion(false, nil, "保存临时下载文件失败")
            }
        }

        stateLock.lock()
        activeDownloadTasks[subscriptionId] = task
        stateLock.unlock()

        task.resume()
    }

    private func cleanupOrphanedSourceFiles(activeSubs: [AdBlockSubscription]) {
        let activeIds = Set(activeSubs.map(\.id))
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }

        for file in files {
            let name = file.lastPathComponent
            if name.hasPrefix("adblock_subscription_") && name.hasSuffix(".txt") {
                let id = String(name.dropFirst("adblock_subscription_".count).dropLast(4))
                if !activeIds.contains(id) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }

        stateLock.lock()
        let metadataIds = Set(metadataBySource.keys)
        for id in metadataIds {
            if id != Self.customSourceId && !activeIds.contains(id) {
                metadataBySource.removeValue(forKey: id)
                unsupportedRulesBySource.removeValue(forKey: id)
            }
        }
        let metaCopy = metadataBySource
        let unsuppCopy = unsupportedRulesBySource
        stateLock.unlock()
        saveMetadata(metaCopy)
        saveUnsupportedRules(unsuppCopy)
    }

    private func restorePersistedRules() {
        parseQueue.async { [weak self] in
            guard let self = self else { return }

            self.stateLock.lock()
            let metadataCopy = self.metadataBySource
            self.stateLock.unlock()

            let enabledSubs = Set(self.loadSubscriptions().filter { $0.isEnabled }.map(\.id))
            let customRulesActive = !self.getCustomRules().trimmingCharacters(in: .whitespacesAndNewlines)

            for sourceId in metadataCopy.keys.sorted() {
                if sourceId == Self.customSourceId && !customRulesActive {
                    continue
                }
                if sourceId != Self.customSourceId && !enabledSubs.contains(sourceId) {
                    continue
                }

                guard let metadata = metadataCopy[sourceId] else {
                    continue
                }

                if metadata.ruleListIdentifiers.isEmpty {
                    self.restoreCosmeticScripts(metadata: metadata)
                    continue
                }

                self.loadRuleListsSequentially(identifiers: metadata.ruleListIdentifiers, index: 0, loaded: []) { [weak self] lists in
                    guard let self = self else { return }

                    if lists.count == metadata.ruleListIdentifiers.count {
                        self.stateLock.lock()
                        self.compiledListsBySource[sourceId] = lists
                        self.stateLock.unlock()
                        self.restoreCosmeticScripts(metadata: metadata)
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

    private func removeRuleLists(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }

        DispatchQueue.main.async {
            for identifier in identifiers {
                WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier, completionHandler: { _ in })
            }
        }
    }

    func purgeOrphanedRuleLists(completion: (() -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                completion?()
                return
            }

            self.stateLock.lock()
            let activeIdentifiers = Set(self.metadataBySource.values.flatMap(\.ruleListIdentifiers))
            self.stateLock.unlock()

            WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { available in
                guard let available = available, !available.isEmpty else {
                    completion?()
                    return
                }

                let toRemove = available.filter { id in
                    (id.hasPrefix("SimpleBrowserAdBlock") || id.hasPrefix("simple_ab_")) && !activeIdentifiers.contains(id)
                }

                guard !toRemove.isEmpty else {
                    completion?()
                    return
                }

                let group = DispatchGroup()
                for identifier in toRemove {
                    group.enter()
                    WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in
                        group.leave()
                    }
                }

                group.notify(queue: .main) {
                    completion?()
                }
            }
        }
    }

    private func deleteSubscriptionFile(id: String) {
        let fileURL = subscriptionFileURL(id: id)
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func cleanAllSubscriptionFilesOnDisk() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files {
            if file.lastPathComponent.hasPrefix("adblock_subscription_") && file.pathExtension == "txt" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func cleanResidualData(completion: (() -> Void)? = nil) {
        stateLock.lock()
        for (_, task) in activeDownloadTasks {
            task.cancel()
        }
        activeDownloadTasks.removeAll()

        for (src, current) in operationIdBySource {
            operationIdBySource[src] = current + 1
        }
        updatingSourceIds.removeAll()
        updateStatusBySource.removeAll()
        lastAutoUpdateAttemptBySource.removeAll()

        let activeSubs = loadSubscriptions()
        let activeCustom = getCustomRules().trimmingCharacters(in: .whitespacesAndNewlines)
        let isCompletelyEmpty = activeSubs.isEmpty && activeCustom.isEmpty

        if isCompletelyEmpty {
            metadataBySource.removeAll()
            compiledListsBySource.removeAll()
            cosmeticScriptsBySource.removeAll()
            unsupportedRulesBySource.removeAll()
            cleanAllSubscriptionFilesOnDisk()
            try? FileManager.default.removeItem(at: metadataFileURL())
            try? FileManager.default.removeItem(at: diagnosticsFileURL())
            UserDefaults.standard.removeObject(forKey: metadataKey)
            UserDefaults.standard.removeObject(forKey: diagnosticKey)
            UserDefaults.standard.removeObject(forKey: subscriptionsKey)
            UserDefaults.standard.removeObject(forKey: customRulesKey)
        }
        stateLock.unlock()

        URLCache.shared.removeAllCachedResponses()

        let types = Set([
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache
        ])
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: Date.distantPast) {}

        purgeOrphanedRuleLists { [weak self] in
            guard let self = self else {
                completion?()
                return
            }
            self.applyRulesToAttachedWebViews()
            malloc_zone_pressure_relief(nil, 0)
            completion?()
        }
    }

    private func sourceFileURL(id sourceId: String) -> URL? {
        if sourceId == Self.customSourceId {
            let text = getCustomRules()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("custom_rules_temp.txt")
            try? text.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        }

        let fileURL = subscriptionFileURL(id: sourceId)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    private func compileSource(
        id sourceId: String,
        expectedOperationId: Int? = nil,
        completion: ((Bool, String?) -> Void)? = nil
    ) {
        let opId = expectedOperationId ?? nextOperationId(for: sourceId)

        stateLock.lock()
        updatingSourceIds.insert(sourceId)
        stateLock.unlock()

        guard let fileURL = sourceFileURL(id: sourceId) else {
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
            autoreleasepool {
                guard let self = self else { return }

                guard self.isOperationValid(sourceId: sourceId, opId: opId) else {
                    return
                }

                guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                    DispatchQueue.main.async {
                        self.stateLock.lock()
                        self.updatingSourceIds.remove(sourceId)
                        self.stateLock.unlock()
                        self.setUpdateStatus(sourceId: sourceId, status: nil)
                        completion?(false, "规则文件无法读取")
                    }
                    return
                }

                let payload = self.buildSourcePayloadStreaming(text: text)

                guard self.isOperationValid(sourceId: sourceId, opId: opId) else {
                    return
                }

                self.setUpdateStatus(
                    sourceId: sourceId,
                    status: "正在编译规则…"
                )

                self.compilePayloadStreaming(
                    payload,
                    sourceId: sourceId,
                    operationId: opId,
                    completion: completion
                )
            }
        }
    }

    private func compilePayloadStreaming(
        _ payload: AdBlockSourcePayloadStreaming,
        sourceId: String,
        operationId: Int,
        completion: ((Bool, String?) -> Void)?
    ) {
        guard isOperationValid(sourceId: sourceId, opId: operationId) else {
            return
        }

        stateLock.lock()
        let previousIdentifiers = metadataBySource[sourceId]?.ruleListIdentifiers ?? []
        stateLock.unlock()

        let version = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        guard !payload.blockChunks.isEmpty || !payload.exceptionRulesJSON.isEmpty else {
            removeRuleLists(identifiers: previousIdentifiers)

            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                ruleListIdentifiers: [],
                ruleCount: payload.ruleCount,
                skippedRuleCount: payload.skippedRuleCount,
                cosmeticRules: payload.cosmeticRules,
                cosmeticExceptions: payload.cosmeticExceptions
            )

            stateLock.lock()
            metadataBySource[sourceId] = metadata
            compiledListsBySource.removeValue(forKey: sourceId)
            unsupportedRulesBySource[sourceId] = []
            let metaCopy = metadataBySource
            let unsuppCopy = unsupportedRulesBySource
            updatingSourceIds.remove(sourceId)
            stateLock.unlock()

            saveMetadata(metaCopy)
            saveUnsupportedRules(unsuppCopy)

            parseQueue.async { [weak self] in
                self?.restoreCosmeticScripts(metadata: metadata)
                DispatchQueue.main.async {
                    self?.setUpdateStatus(sourceId: sourceId, status: nil)
                    self?.applyRulesToAttachedWebViews()
                    self?.purgeOrphanedRuleLists(completion: nil)

                    let message = payload.skippedRuleCount > 0
                        ? "已更新，跳过 \(payload.skippedRuleCount) 条不兼容规则"
                        : nil

                    completion?(true, message)
                }
            }
            return
        }

        stateLock.lock()
        unsupportedRulesBySource[sourceId] = []
        stateLock.unlock()

        let session = StreamingCompilationSession(
            manager: self,
            blockChunks: payload.blockChunks,
            exceptionRules: payload.exceptionRulesJSON,
            sourceId: sourceId,
            operationId: operationId,
            version: version
        )

        session.start { [weak self] lists, identifiers in
            guard let self = self else { return }

            guard self.isOperationValid(sourceId: sourceId, opId: operationId) else {
                self.removeRuleLists(identifiers: identifiers)
                return
            }

            if lists.isEmpty && payload.cosmeticRules.isEmpty && payload.cosmeticExceptions.isEmpty {
                self.removeRuleLists(identifiers: identifiers)
                self.stateLock.lock()
                self.updatingSourceIds.remove(sourceId)
                self.stateLock.unlock()
                self.setUpdateStatus(sourceId: sourceId, status: nil)
                DispatchQueue.main.async {
                    self.purgeOrphanedRuleLists(completion: nil)
                    completion?(false, "规则编译超时或所有规则块均不兼容")
                }
                return
            }

            self.removeRuleLists(identifiers: previousIdentifiers)

            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                ruleListIdentifiers: identifiers,
                ruleCount: payload.ruleCount,
                skippedRuleCount: payload.skippedRuleCount + self.unsupportedRuleCount(sourceId: sourceId),
                cosmeticRules: payload.cosmeticRules,
                cosmeticExceptions: payload.cosmeticExceptions
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

            self.parseQueue.async { [weak self] in
                self?.restoreCosmeticScripts(metadata: metadata)
                DispatchQueue.main.async {
                    self?.setUpdateStatus(sourceId: sourceId, status: nil)
                    self?.applyRulesToAttachedWebViews()
                    self?.purgeOrphanedRuleLists(completion: nil)

                    let unsupportedCount = self?.unsupportedRuleCount(sourceId: sourceId) ?? 0
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

    fileprivate func compileRuleGroup(
        _ json: String,
        sourceId: String,
        operationId: Int,
        identifier: String,
        statusText: String,
        completion: @escaping (WKContentRuleList?, String?) -> Void
    ) {
        guard !json.isEmpty else {
            completion(nil, nil)
            return
        }

        guard isOperationValid(sourceId: sourceId, opId: operationId) else {
            completion(nil, nil)
            return
        }

        setUpdateStatus(sourceId: sourceId, status: statusText)

        var didFinish = false
        var timeoutWorkItem: DispatchWorkItem?

        let finish = { (list: WKContentRuleList?, ident: String?) in
            guard !didFinish else { return }
            didFinish = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            completion(list, ident)
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, !didFinish else { return }
            self.recordUnsupportedRule(
                sourceId: sourceId,
                rawRule: "规则块编译超时",
                compiledJSON: "",
                error: "WebKit 编译单块规则超时，已自动跳过"
            )
            finish(nil, nil)
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: timeout)

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isOperationValid(sourceId: sourceId, opId: operationId), !didFinish else {
                finish(nil, nil)
                return
            }

            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { [weak self] ruleList, error in
                DispatchQueue.main.async {
                    guard let self = self else {
                        finish(nil, nil)
                        return
                    }

                    guard !didFinish else {
                        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in }
                        return
                    }

                    guard self.isOperationValid(sourceId: sourceId, opId: operationId) else {
                        if ruleList != nil {
                            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in }
                        }
                        finish(nil, nil)
                        return
                    }

                    guard let ruleList = ruleList else {
                        self.recordUnsupportedRule(
                            sourceId: sourceId,
                            rawRule: "规则块编译失败",
                            compiledJSON: "",
                            error: self.compilerErrorDescription(error)
                        )
                        finish(nil, nil)
                        return
                    }

                    finish(ruleList, identifier)
                }
            }
        }
    }

    private func deactivateSource(id sourceId: String) {
        cancelOperation(for: sourceId)

        stateLock.lock()
        let identifiersToRemove = metadataBySource[sourceId]?.ruleListIdentifiers ?? []
        metadataBySource.removeValue(forKey: sourceId)
        compiledListsBySource.removeValue(forKey: sourceId)
        cosmeticScriptsBySource.removeValue(forKey: sourceId)
        unsupportedRulesBySource.removeValue(forKey: sourceId)

        let metaCopy = metadataBySource
        let unsuppCopy = unsupportedRulesBySource
        stateLock.unlock()

        setUpdateStatus(sourceId: sourceId, status: nil)
        removeRuleLists(identifiers: identifiersToRemove)
        saveMetadata(metaCopy)
        saveUnsupportedRules(unsuppCopy)

        let activeSubs = loadSubscriptions()
        let activeCustom = getCustomRules().trimmingCharacters(in: .whitespacesAndNewlines)
        if activeSubs.isEmpty && activeCustom.isEmpty {
            cleanResidualData(completion: nil)
        } else {
            applyRulesToAttachedWebViews()
            purgeOrphanedRuleLists(completion: nil)
        }
    }

    private func restoreCosmeticScripts(metadata: AdBlockCompiledSourceMetadata) {
        guard !metadata.cosmeticRules.isEmpty || !metadata.cosmeticExceptions.isEmpty else {
            stateLock.lock()
            cosmeticScriptsBySource.removeValue(forKey: metadata.sourceId)
            stateLock.unlock()
            return
        }

        let batches = cosmeticRuleBatches(metadata.cosmeticRules)
        let exceptionsData = (try? JSONEncoder().encode(metadata.cosmeticExceptions)) ?? Data()
        let exceptionsJson = String(data: exceptionsData, encoding: .utf8) ?? "[]"

        let scripts = batches.compactMap { rules -> WKUserScript? in
            guard let data = try? JSONEncoder().encode(rules),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }

            let source = """
            (function() {
                var rules = \(json);
                var exceptions = \(exceptionsJson);
                var styleId = '__simple_browser_adblock_style__';
                var host = (location.hostname || '').toLowerCase();

                function matchesDomain(rule) {
                    if (rule.excludedDomains && rule.excludedDomains.length > 0) {
                        for (var j = 0; j < rule.excludedDomains.length; j++) {
                            var ex = rule.excludedDomains[j];
                            if (host === ex || host.endsWith('.' + ex)) {
                                return false;
                            }
                        }
                    }
                    if (!rule.domains || rule.domains.length === 0) {
                        return true;
                    }
                    for (var i = 0; i < rule.domains.length; i++) {
                        var domain = rule.domains[i];
                        if (host === domain || host.endsWith('.' + domain)) {
                            return true;
                        }
                    }
                    return false;
                }

                function isSelectorWhitelisted(selector) {
                    if (!exceptions || exceptions.length === 0) {
                        return false;
                    }
                    for (var i = 0; i < exceptions.length; i++) {
                        var ex = exceptions[i];
                        if (ex.selector === selector && matchesDomain(ex)) {
                            return true;
                        }
                    }
                    return false;
                }

                function insertRules() {
                    var style = document.getElementById(styleId);
                    if (!style) {
                        style = document.createElement('style');
                        style.id = styleId;
                        style.type = 'text/css';
                        (document.head || document.documentElement).appendChild(style);
                    }
                    var sheet = style.sheet;
                    if (!sheet) {
                        return;
                    }
                    for (var i = 0; i < rules.length; i++) {
                        var rule = rules[i];
                        if (!matchesDomain(rule) || isSelectorWhitelisted(rule.selector)) {
                            continue;
                        }
                        try {
                            sheet.insertRule(
                                rule.selector + '{display:none !important;visibility:hidden !important;pointer-events:none !important;}',
                                sheet.cssRules.length
                            );
                        } catch (_) {}
                    }
                }

                if (document.readyState === 'loading') {
                    document.addEventListener('DOMContentLoaded', function() {
                        insertRules();
                    }, { once: true });
                } else {
                    insertRules();
                }
            })();
            """

            return WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        }

        stateLock.lock()
        cosmeticScriptsBySource[metadata.sourceId] = scripts
        stateLock.unlock()
    }

    private func cosmeticRuleBatches(
        _ rules: [AdBlockCosmeticRule]
    ) -> [[AdBlockCosmeticRule]] {
        let chunkSize = 1000
        return stride(from: 0, to: rules.count, by: chunkSize).map {
            Array(rules[$0..<min($0 + chunkSize, rules.count)])
        }
    }

    private func buildSourcePayloadStreaming(text: String) -> AdBlockSourcePayloadStreaming {
        var blockChunks: [[String]] = []
        var currentChunk: [String] = []
        var exceptionRules: [String] = []
        var cosmeticRules: [AdBlockCosmeticRule] = []
        var cosmeticExceptions: [AdBlockCosmeticException] = []
        var totalRuleCount = 0
        var totalSkipped = 0

        currentChunk.reserveCapacity(nativeRuleChunkSize)
        cosmeticRules.reserveCapacity(min(5000, maximumCosmeticRulesPerSource))

        text.enumerateLines { line, _ in
            let result = self.parseRuleStreaming(line)

            if let blockRule = result.blockRuleJSON {
                currentChunk.append(blockRule)
                totalRuleCount += 1

                if currentChunk.count >= self.nativeRuleChunkSize {
                    blockChunks.append(currentChunk)
                    currentChunk = []
                    currentChunk.reserveCapacity(self.nativeRuleChunkSize)
                }
            } else if let exRule = result.exceptionRuleJSON {
                exceptionRules.append(exRule)
                totalRuleCount += 1
            }

            if !result.cosmeticRules.isEmpty {
                for cRule in result.cosmeticRules {
                    if cosmeticRules.count < self.maximumCosmeticRulesPerSource {
                        cosmeticRules.append(cRule)
                    } else {
                        totalSkipped += 1
                    }
                    totalRuleCount += 1
                }
            }

            if !result.cosmeticExceptions.isEmpty {
                cosmeticExceptions.append(contentsOf: result.cosmeticExceptions)
                totalRuleCount += result.cosmeticExceptions.count
            }

            if result.isUnsupported {
                totalSkipped += 1
            }
        }

        if !currentChunk.isEmpty {
            blockChunks.append(currentChunk)
        }

        return AdBlockSourcePayloadStreaming(
            blockChunks: blockChunks,
            exceptionRulesJSON: exceptionRules,
            cosmeticRules: cosmeticRules,
            cosmeticExceptions: cosmeticExceptions,
            ruleCount: totalRuleCount,
            skippedRuleCount: totalSkipped
        )
    }

    private func isValidWebKitPattern(_ pattern: String) -> Bool {
        guard !pattern.isEmpty,
              pattern.count < 300,
              !pattern.contains("(?"),
              !pattern.contains("[:"),
              !pattern.contains(".*.*") else {
            return false
        }

        return (try? NSRegularExpression(pattern: pattern)) != nil
    }

    private func parseRuleStreaming(_ rawLine: String) -> AdBlockParsedLineStreaming {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty,
              !line.hasPrefix("!"),
              !line.hasPrefix("！"),
              !line.hasPrefix("[") else {
            return AdBlockParsedLineStreaming(
                blockRuleJSON: nil,
                exceptionRuleJSON: nil,
                cosmeticRules: [],
                cosmeticExceptions: [],
                isUnsupported: false
            )
        }

        if line.contains("##+js") || line.contains("#%#") {
            return AdBlockParsedLineStreaming(
                blockRuleJSON: nil,
                exceptionRuleJSON: nil,
                cosmeticRules: [],
                cosmeticExceptions: [],
                isUnsupported: true
            )
        }

        if line.contains("#@#") {
            guard let range = line.range(of: "#@#") else {
                return AdBlockParsedLineStreaming(
                    blockRuleJSON: nil,
                    exceptionRuleJSON: nil,
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
            return AdBlockParsedLineStreaming(
                blockRuleJSON: nil,
                exceptionRuleJSON: nil,
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
            let selectorsText = String(line[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let parsedDomains = normalizedDomains(from: domainsText)
            let selectors = splitSelectorList(selectorsText)

            let cosmeticRules = selectors.compactMap { selector in
                parseCosmeticRule(selector: selector, domains: parsedDomains.include, excludedDomains: parsedDomains.exclude)
            }

            return AdBlockParsedLineStreaming(
                blockRuleJSON: nil,
                exceptionRuleJSON: nil,
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

        let rawPattern = String(parts[0])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawPattern.isEmpty else {
            return AdBlockParsedLineStreaming(
                blockRuleJSON: nil,
                exceptionRuleJSON: nil,
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
                    return AdBlockParsedLineStreaming(blockRuleJSON: nil, exceptionRuleJSON: nil, cosmeticRules: [], cosmeticExceptions: [], isUnsupported: true)
                }
                let domains = normalizedDomains(from: domainStr, separator: "|")
                includeDomains.append(contentsOf: domains.include)
                excludeDomains.append(contentsOf: domains.exclude)
            } else if option.hasPrefix("denyallow=") {
                let domainStr = String(option.dropFirst(10))
                if domainStr.contains("/") {
                    return AdBlockParsedLineStreaming(blockRuleJSON: nil, exceptionRuleJSON: nil, cosmeticRules: [], cosmeticExceptions: [], isUnsupported: true)
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
                return AdBlockParsedLineStreaming(
                    blockRuleJSON: nil,
                    exceptionRuleJSON: nil,
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
            return AdBlockParsedLineStreaming(
                blockRuleJSON: nil,
                exceptionRuleJSON: nil,
                cosmeticRules: [],
                cosmeticExceptions: [],
                isUnsupported: true
            )
        }

        var triggerParts: [String] = []
        triggerParts.append("\"url-filter\":\"\(escapeJSONString(filter))\"")
        if isCaseSensitive {
            triggerParts.append("\"url-filter-is-case-sensitive\":true")
        }
        if !includeDomains.isEmpty {
            let unique = Array(Set(includeDomains)).sorted()
            let items = unique.map { "\"\(escapeJSONString($0))\"" }.joined(separator: ",")
            triggerParts.append("\"if-domain\":[\(items)]")
        }
        if !excludeDomains.isEmpty {
            let unique = Array(Set(excludeDomains)).sorted()
            let items = unique.map { "\"\(escapeJSONString($0))\"" }.joined(separator: ",")
            triggerParts.append("\"unless-domain\":[\(items)]")
        }
        if !resourceTypes.isEmpty {
            let unique = Array(Set(resourceTypes)).sorted()
            let items = unique.map { "\"\(escapeJSONString($0))\"" }.joined(separator: ",")
            triggerParts.append("\"resource-type\":[\(items)]")
        }
        if !loadTypes.isEmpty {
            let unique = Array(Set(loadTypes)).sorted()
            let items = unique.map { "\"\(escapeJSONString($0))\"" }.joined(separator: ",")
            triggerParts.append("\"load-type\":[\(items)]")
        }

        let triggerStr = "{" + triggerParts.joined(separator: ",") + "}"
        let actionType = isException ? "ignore-previous-rules" : "block"
        let actionStr = "{\"type\":\"\(actionType)\"}"
        let ruleJson = "{\"trigger\":\(triggerStr),\"action\":\(actionStr)}"

        if isException {
            return AdBlockParsedLineStreaming(
                blockRuleJSON: nil,
                exceptionRuleJSON: ruleJson,
                cosmeticRules: [],
                cosmeticExceptions: [],
                isUnsupported: false
            )
        } else {
            return AdBlockParsedLineStreaming(
                blockRuleJSON: ruleJson,
                exceptionRuleJSON: nil,
                cosmeticRules: [],
                cosmeticExceptions: [],
                isUnsupported: false
            )
        }
    }

    private func parseCosmeticRule(
        selector: String,
        domains: [String],
        excludedDomains: [String] = []
    ) -> AdBlockCosmeticRule? {
        let value = selector.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty,
              value.count <= 2048,
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
            var value = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))

            guard !value.isEmpty, value != "*" else {
                continue
            }

            if value.hasPrefix("~") {
                value = String(value.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && !value.contains("/") && !value.contains("*") {
                    exclude.append(value)
                }
            } else {
                if !value.contains("/") && !value.contains("*") {
                    include.append(value)
                }
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

        let specialChars: Set<Character> = ["\\", ".", "+", "?", "*", "$", "(", ")", "[", "]", "{", "}", "|"]
        var escaped = ""
        escaped.reserveCapacity(p.count * 2)

        for char in p {
            if char == "*" {
                escaped.append(".*")
            } else if char == "^" {
                escaped.append("[^a-zA-Z0-9_.-]")
            } else if specialChars.contains(char) {
                escaped.append("\\")
                escaped.append(char)
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
        var result = ""
        result.reserveCapacity(string.count + 8)
        for char in string {
            switch char {
            case "\\":
                result.append("\\\\")
            case "\"":
                result.append("\\\"")
            case "\n":
                result.append("\\n")
            case "\r":
                result.append("\\r")
            case "\t":
                result.append("\\t")
            default:
                result.append(char)
            }
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

    private func metadataFileURL() -> URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let folder = directory.appendingPathComponent("AdBlock", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent("adblock_metadata_v13.json")
    }

    private func diagnosticsFileURL() -> URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let folder = directory.appendingPathComponent("AdBlock", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent("adblock_diagnostics_v13.json")
    }

    private func loadMetadata() -> [String: AdBlockCompiledSourceMetadata] {
        let url = metadataFileURL()
        if let data = try? Data(contentsOf: url),
           let items = try? JSONDecoder().decode([String: AdBlockCompiledSourceMetadata].self, from: data) {
            return items
        }
        if let data = UserDefaults.standard.data(forKey: metadataKey),
           let items = try? JSONDecoder().decode([String: AdBlockCompiledSourceMetadata].self, from: data) {
            UserDefaults.standard.removeObject(forKey: metadataKey)
            saveMetadata(items)
            return items
        }
        return [:]
    }

    private func saveMetadata(
        _ metadata: [String: AdBlockCompiledSourceMetadata]
    ) {
        let url = metadataFileURL()
        if metadata.isEmpty {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: metadataKey)
            return
        }

        guard let data = try? JSONEncoder().encode(metadata) else {
            return
        }

        try? data.write(to: url, options: .atomic)
        UserDefaults.standard.removeObject(forKey: metadataKey)
    }

    private func recordUnsupportedRule(
        sourceId: String,
        rawRule: String,
        compiledJSON: String,
        error: String
    ) {
        stateLock.lock()
        var items = unsupportedRulesBySource[sourceId] ?? []

        if items.count < 50 {
            let item = AdBlockUnsupportedRule(
                rawRule: rawRule,
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
        let url = diagnosticsFileURL()
        if let data = try? Data(contentsOf: url),
           let items = try? JSONDecoder().decode([String: [AdBlockUnsupportedRule]].self, from: data) {
            return items
        }
        if let data = UserDefaults.standard.data(forKey: diagnosticKey),
           let items = try? JSONDecoder().decode([String: [AdBlockUnsupportedRule]].self, from: data) {
            UserDefaults.standard.removeObject(forKey: diagnosticKey)
            saveUnsupportedRules(items)
            return items
        }
        return [:]
    }

    private func saveUnsupportedRules(
        _ rules: [String: [AdBlockUnsupportedRule]]
    ) {
        let url = diagnosticsFileURL()
        if rules.isEmpty {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: diagnosticKey)
            return
        }

        guard let data = try? JSONEncoder().encode(rules) else {
            return
        }

        try? data.write(to: url, options: .atomic)
        UserDefaults.standard.removeObject(forKey: diagnosticKey)
    }
}

private final class StreamingCompilationSession {
    private weak var manager: AdBlockManager?
    private var blockChunks: [[String]]
    private let exceptionRules: [String]
    private let sourceId: String
    private let operationId: Int
    private let version: String
    private let totalCount: Int
    private var lists: [WKContentRuleList] = []
    private var identifiers: [String] = []
    private var onComplete: (([WKContentRuleList], [String]) -> Void)?

    init(
        manager: AdBlockManager,
        blockChunks: [[String]],
        exceptionRules: [String],
        sourceId: String,
        operationId: Int,
        version: String
    ) {
        self.manager = manager
        self.blockChunks = blockChunks
        self.exceptionRules = exceptionRules
        self.sourceId = sourceId
        self.operationId = operationId
        self.version = version
        self.totalCount = blockChunks.isEmpty ? 1 : blockChunks.count
    }

    func start(completion: @escaping ([WKContentRuleList], [String]) -> Void) {
        self.onComplete = completion
        processNextChunk(index: 0)
    }

    private func processNextChunk(index: Int) {
        guard let manager = manager else {
            finish()
            return
        }

        guard index < blockChunks.count else {
            finish()
            return
        }

        guard manager.isOperationValid(sourceId: sourceId, opId: operationId) else {
            finish()
            return
        }

        let chunk = blockChunks[index]
        blockChunks[index] = []

        let combined = chunk + exceptionRules
        guard !combined.isEmpty else {
            processNextChunk(index: index + 1)
            return
        }

        let json = "[" + combined.joined(separator: ",") + "]"
        let identifier = "\(manager.identifierPrefix).\(sourceId.replacingOccurrences(of: "-", with: "")).\(version).\(index)"
        let status = "正在编译规则 (\(index + 1)/\(totalCount))…"

        manager.compileRuleGroup(
            json,
            sourceId: sourceId,
            operationId: operationId,
            identifier: identifier,
            statusText: status
        ) { [weak self] ruleList, ident in
            guard let self = self else { return }

            if let list = ruleList, let ident = ident {
                self.lists.append(list)
                self.identifiers.append(ident)
            }

            self.processNextChunk(index: index + 1)
        }
    }

    private func finish() {
        blockChunks.removeAll()
        let resultLists = lists
        let resultIdentifiers = identifiers
        lists.removeAll()
        identifiers.removeAll()
        onComplete?(resultLists, resultIdentifiers)
        onComplete = nil
    }
}

struct AdBlockCompiledSourceMetadata: Codable {
    var sourceId: String
    var ruleListIdentifiers: [String]
    var ruleCount: Int
    var skippedRuleCount: Int
    var cosmeticRules: [AdBlockCosmeticRule]
    var cosmeticExceptions: [AdBlockCosmeticException]

    enum CodingKeys: String, CodingKey {
        case sourceId, ruleListIdentifiers, ruleCount, skippedRuleCount, cosmeticRules, cosmeticExceptions
    }

    init(
        sourceId: String,
        ruleListIdentifiers: [String],
        ruleCount: Int,
        skippedRuleCount: Int,
        cosmeticRules: [AdBlockCosmeticRule],
        cosmeticExceptions: [AdBlockCosmeticException] = []
    ) {
        self.sourceId = sourceId
        self.ruleListIdentifiers = ruleListIdentifiers
        self.ruleCount = ruleCount
        self.skippedRuleCount = skippedRuleCount
        self.cosmeticRules = cosmeticRules
        self.cosmeticExceptions = cosmeticExceptions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceId = try container.decode(String.self, forKey: .sourceId)
        self.ruleListIdentifiers = try container.decode([String].self, forKey: .ruleListIdentifiers)
        self.ruleCount = try container.decode(Int.self, forKey: .ruleCount)
        self.skippedRuleCount = try container.decode(Int.self, forKey: .skippedRuleCount)
        self.cosmeticRules = try container.decode([AdBlockCosmeticRule].self, forKey: .cosmeticRules)
        self.cosmeticExceptions = try container.decodeIfPresent([AdBlockCosmeticException].self, forKey: .cosmeticExceptions) ?? []
    }
}

private struct AdBlockSourcePayloadStreaming {
    var blockChunks: [[String]]
    var exceptionRulesJSON: [String]
    var cosmeticRules: [AdBlockCosmeticRule]
    var cosmeticExceptions: [AdBlockCosmeticException]
    var ruleCount: Int
    var skippedRuleCount: Int
}

private struct AdBlockParsedLineStreaming {
    var blockRuleJSON: String?
    var exceptionRuleJSON: String?
    var cosmeticRules: [AdBlockCosmeticRule]
    var cosmeticExceptions: [AdBlockCosmeticException]
    var isUnsupported: Bool
}

private struct AdBlockUnsupportedRule: Codable {
    var rawRule: String
    var compiledJSON: String
    var errorDescription: String
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
