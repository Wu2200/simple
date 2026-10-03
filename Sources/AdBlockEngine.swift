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
    private let identifierPrefix = "SimpleBlockRule"

    private let nativeRuleChunkSize = 2500
    private let maximumRulesPerSource = 20000
    private let maximumCosmeticSelectors = 3000
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
        cleanupOrphanRuleLists()

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
            status: "正在解析自定义规则"
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
            status: "正在下载订阅"
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 60
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
                    completion(false, 0, "订阅文件保存失败")
                }
                return
            }

            self.setUpdateStatus(
                sourceId: subscription.id,
                status: "正在解析规则"
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

    private func makeRuleIdentifier(sourceId: String, index: Int) -> String {
        let cleanId = String(sourceId.filter { $0.isLetter || $0.isNumber }.prefix(16))
        return "\(identifierPrefix)_\(cleanId)_\(index)"
    }

    private func cleanupOrphanRuleLists() {
        let activeSubs = loadSubscriptions()
        var validCleanIds = Set(activeSubs.map { String($0.id.filter { $0.isLetter || $0.isNumber }.prefix(16)) })
        validCleanIds.insert(String(Self.customSourceId.filter { $0.isLetter || $0.isNumber }.prefix(16)))

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
                status: "正在解析规则"
            )
        }

        parseQueue.async { [weak self] in
            guard let self = self else { return }

            let (chunkJSONs, cosmeticScript, ruleCount, skippedCount) = self.streamParseSource(text: text)

            self.setUpdateStatus(
                sourceId: sourceId,
                status: "正在编译规则"
            )

            self.applyCompiledSource(
                sourceId: sourceId,
                chunkJSONs: chunkJSONs,
                cosmeticScript: cosmeticScript,
                ruleCount: ruleCount,
                skippedCount: skippedCount,
                completion: completion
            )
        }
    }

    private func applyCompiledSource(
        sourceId: String,
        chunkJSONs: [String],
        cosmeticScript: String,
        ruleCount: Int,
        skippedCount: Int,
        completion: ((Bool, String?) -> Void)?
    ) {
        if !cosmeticScript.isEmpty {
            try? cosmeticScript.write(
                to: cosmeticScriptFileURL(sourceId: sourceId),
                atomically: true,
                encoding: .utf8
            )
            let userScript = WKUserScript(
                source: cosmeticScript,
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

        let newIdentifiers = (0..<chunkJSONs.count).map { makeRuleIdentifier(sourceId: sourceId, index: $0) }

        stateLock.lock()
        let oldMetadata = metadataBySource[sourceId]
        stateLock.unlock()

        let oldIdentifiers = Set(oldMetadata?.ruleListIdentifiers ?? [])
        let identifiersToRemove = oldIdentifiers.subtracting(newIdentifiers)

        for oldId in identifiersToRemove {
            DispatchQueue.main.async {
                WKContentRuleListStore.default().removeContentRuleList(forIdentifier: oldId) { _ in }
            }
        }

        guard !chunkJSONs.isEmpty else {
            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                ruleListIdentifiers: [],
                ruleCount: ruleCount,
                skippedRuleCount: skippedCount
            )

            stateLock.lock()
            metadataBySource[sourceId] = metadata
            compiledListsBySource.removeValue(forKey: sourceId)
            updatingSourceIds.remove(sourceId)
            stateLock.unlock()

            saveMetadata(metadata)
            deleteDiagnosticFile(sourceId: sourceId)

            DispatchQueue.main.async { [weak self] in
                self?.setUpdateStatus(sourceId: sourceId, status: nil)
                self?.applyRulesToAttachedWebViews()
                completion?(true, nil)
            }
            return
        }

        compileChunksSequentially(
            identifiers: newIdentifiers,
            jsons: chunkJSONs,
            sourceId: sourceId,
            index: 0,
            compiledLists: []
        ) { [weak self] lists in
            guard let self = self else { return }

            guard !lists.isEmpty || !cosmeticScript.isEmpty else {
                self.stateLock.lock()
                self.updatingSourceIds.remove(sourceId)
                self.stateLock.unlock()
                self.setUpdateStatus(sourceId: sourceId, status: nil)
                DispatchQueue.main.async {
                    completion?(false, "规则编译失败")
                }
                return
            }

            let successfulIdentifiers = (0..<lists.count).map { self.makeRuleIdentifier(sourceId: sourceId, index: $0) }

            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                ruleListIdentifiers: successfulIdentifiers,
                ruleCount: ruleCount,
                skippedRuleCount: skippedCount
            )

            self.stateLock.lock()
            self.metadataBySource[sourceId] = metadata
            self.compiledListsBySource[sourceId] = lists
            self.updatingSourceIds.remove(sourceId)
            stateLock.unlock()

            self.saveMetadata(metadata)
            self.deleteDiagnosticFile(sourceId: sourceId)

            DispatchQueue.main.async { [weak self] in
                self?.setUpdateStatus(sourceId: sourceId, status: nil)
                self?.applyRulesToAttachedWebViews()

                let message: String?
                if skippedCount > 0 {
                    message = "已更新，跳过 \(skippedCount) 条不兼容规则"
                } else {
                    message = nil
                }

                completion?(true, message)
            }
        }
    }

    private func compileChunksSequentially(
        identifiers: [String],
        jsons: [String],
        sourceId: String,
        index: Int,
        compiledLists: [WKContentRuleList],
        completion: @escaping ([WKContentRuleList]) -> Void
    ) {
        guard index < identifiers.count else {
            completion(compiledLists)
            return
        }

        setUpdateStatus(
            sourceId: sourceId,
            status: "正在编译规则 \(index + 1)/\(identifiers.count)"
        )

        let identifier = identifiers[index]
        let json = jsons[index]

        DispatchQueue.main.async {
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { [weak self] ruleList, error in
                self?.parseQueue.async {
                    var nextLists = compiledLists
                    if let ruleList = ruleList {
                        nextLists.append(ruleList)
                    }
                    self?.compileChunksSequentially(
                        identifiers: identifiers,
                        jsons: jsons,
                        sourceId: sourceId,
                        index: index + 1,
                        compiledLists: nextLists,
                        completion: completion
                    )
                }
            }
        }
    }

    private func deactivateSource(id sourceId: String) {
        stateLock.lock()
        let oldMetadata = metadataBySource.removeValue(forKey: sourceId)
        compiledListsBySource.removeValue(forKey: sourceId)
        cosmeticScriptsBySource.removeValue(forKey: sourceId)
        updatingSourceIds.remove(sourceId)
        updateStatusBySource.removeValue(forKey: sourceId)
        lastAutoUpdateAttemptBySource.removeValue(forKey: sourceId)
        stateLock.unlock()

        setUpdateStatus(sourceId: sourceId, status: nil)

        applyRulesToAttachedWebViews()

        let cleanId = String(sourceId.filter { $0.isLetter || $0.isNumber }.prefix(16))
        let targetPrefix = "\(identifierPrefix)_\(cleanId)_"

        DispatchQueue.main.async {
            WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { identifiers in
                guard let identifiers = identifiers else { return }
                for id in identifiers where id.hasPrefix(targetPrefix) {
                    WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in }
                }
            }
        }

        if let oldIdentifiers = oldMetadata?.ruleListIdentifiers {
            for oldId in oldIdentifiers {
                DispatchQueue.main.async {
                    WKContentRuleListStore.default().removeContentRuleList(forIdentifier: oldId) { _ in }
                }
            }
        }

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

    private func streamParseSource(text: String) -> (chunkJSONs: [String], cosmeticScript: String, ruleCount: Int, skippedCount: Int) {
        var chunkJSONs: [String] = []
        var currentChunkBuffer = "["
        var currentChunkRuleCount = 0
        var totalRuleCount = 0
        var totalSkippedCount = 0

        var cosmeticSelectors: [String] = []
        cosmeticSelectors.reserveCapacity(maximumCosmeticSelectors)

        text.enumerateLines { line, stop in
            autoreleasepool {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.hasPrefix("!"),
                      !trimmed.hasPrefix("！"),
                      !trimmed.hasPrefix("[") else {
                    return
                }

                if trimmed.contains("##+js") || trimmed.contains("#%#") || trimmed.contains("#@#") {
                    totalSkippedCount += 1
                    return
                }

                if let hashRange = trimmed.range(of: "##") {
                    let selector = String(trimmed[hashRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if Self.isValidCosmeticSelector(selector) {
                        if cosmeticSelectors.count < self.maximumCosmeticSelectors {
                            cosmeticSelectors.append(selector)
                            totalRuleCount += 1
                        }
                    } else {
                        totalSkippedCount += 1
                    }
                    return
                }

                if totalRuleCount >= self.maximumRulesPerSource {
                    return
                }

                guard let ruleJSON = Self.parseLineToJSON(trimmed) else {
                    totalSkippedCount += 1
                    return
                }

                if currentChunkRuleCount > 0 {
                    currentChunkBuffer.append(",")
                }
                currentChunkBuffer.append(ruleJSON)
                currentChunkRuleCount += 1
                totalRuleCount += 1

                if currentChunkRuleCount >= self.nativeRuleChunkSize {
                    currentChunkBuffer.append("]")
                    chunkJSONs.append(currentChunkBuffer)
                    currentChunkBuffer = "["
                    currentChunkRuleCount = 0
                }
            }
        }

        if currentChunkRuleCount > 0 {
            currentChunkBuffer.append("]")
            chunkJSONs.append(currentChunkBuffer)
        }

        let cosmeticScript: String
        if !cosmeticSelectors.isEmpty {
            let combinedCSS = cosmeticSelectors.map { "\($0){display:none!important;visibility:hidden!important;pointer-events:none!important;}" }.joined()
            let escapedCSS = Self.escapeJSON(combinedCSS)
            cosmeticScript = """
            (function() {
                var css = \(escapedCSS);
                if (!css) return;
                var styleId = '__simple_adblock_style__';
                function apply() {
                    var style = document.getElementById(styleId);
                    if (!style) {
                        style = document.createElement('style');
                        style.id = styleId;
                        style.type = 'text/css';
                        (document.head || document.documentElement).appendChild(style);
                    }
                    style.textContent = css;
                }
                if (document.readyState === 'loading') {
                    document.addEventListener('DOMContentLoaded', apply, { once: true });
                } else {
                    apply();
                }
            })();
            """
        } else {
            cosmeticScript = ""
        }

        return (chunkJSONs, cosmeticScript, totalRuleCount, totalSkippedCount)
    }

    private static func isValidCosmeticSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty,
              selector.count <= 256,
              !selector.contains("\u{0000}"),
              !selector.contains("{"),
              !selector.contains("}"),
              !selector.contains("<"),
              !selector.contains(">") else {
            return false
        }
        return true
    }

    private static func parseLineToJSON(_ rawLine: String) -> String? {
        var line = rawLine
        let isException = line.hasPrefix("@@")
        if isException {
            line = String(line.dropFirst(2))
        }

        let parts = line.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPattern = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPattern.isEmpty else { return nil }

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
                if domainStr.contains("/") { return nil }
                let domains = parseNormalizedDomains(domainStr, separator: "|")
                includeDomains.append(contentsOf: domains.include)
                excludeDomains.append(contentsOf: domains.exclude)
            } else if option.hasPrefix("denyallow=") {
                let domainStr = String(option.dropFirst(10))
                if domainStr.contains("/") { return nil }
                let domains = parseNormalizedDomains(domainStr, separator: "|")
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
                }
            } else if option == "badfilter" || option.hasPrefix("removeparam") || option.hasPrefix("csp") {
                return nil
            }
        }

        let filter: String
        if rawPattern.hasPrefix("/") && rawPattern.hasSuffix("/") && rawPattern.count > 2 {
            filter = String(rawPattern.dropFirst().dropLast())
        } else {
            filter = urlFilterPattern(from: rawPattern)
        }

        guard isValidPattern(filter) else { return nil }

        let cleanInc = cleanDomainList(includeDomains)
        let cleanExc = cleanDomainList(excludeDomains)
        let cleanRes = Array(Set(resourceTypes)).sorted()
        let cleanLoad = Array(Set(loadTypes)).sorted()

        var s = "{\"trigger\":{\"url-filter\":"
        s.append(escapeJSON(filter))

        if isCaseSensitive {
            s.append(",\"url-filter-is-case-sensitive\":true")
        }

        if !cleanInc.isEmpty {
            s.append(",\"if-domain\":[")
            for (i, d) in cleanInc.enumerated() {
                if i > 0 { s.append(",") }
                s.append(escapeJSON(d))
            }
            s.append("]")
        }

        if !cleanExc.isEmpty {
            s.append(",\"unless-domain\":[")
            for (i, d) in cleanExc.enumerated() {
                if i > 0 { s.append(",") }
                s.append(escapeJSON(d))
            }
            s.append("]")
        }

        if !cleanRes.isEmpty {
            s.append(",\"resource-type\":[")
            for (i, r) in cleanRes.enumerated() {
                if i > 0 { s.append(",") }
                s.append(escapeJSON(r))
            }
            s.append("]")
        }

        if !cleanLoad.isEmpty {
            s.append(",\"load-type\":[")
            for (i, l) in cleanLoad.enumerated() {
                if i > 0 { s.append(",") }
                s.append(escapeJSON(l))
            }
            s.append("]")
        }

        s.append("},\"action\":{\"type\":")
        s.append(isException ? "\"ignore-previous-rules\"}}" : "\"block\"}}")

        return s
    }

    private static func isValidPattern(_ pattern: String) -> Bool {
        guard !pattern.isEmpty,
              pattern.count <= 256,
              pattern.allSatisfy({ $0.isASCII }),
              !pattern.contains("(?"),
              !pattern.contains("[:") else {
            return false
        }
        return (try? NSRegularExpression(pattern: pattern)) != nil
    }

    private static func cleanDomainList(_ list: [String]) -> [String] {
        var result: [String] = []
        for item in list {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty,
                  trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
                  !trimmed.hasPrefix("."),
                  !trimmed.hasSuffix("."),
                  !trimmed.contains("..") else {
                continue
            }
            if !result.contains(trimmed) {
                result.append(trimmed)
            }
        }
        return result.sorted()
    }

    private static func parseNormalizedDomains(_ text: String, separator: Character) -> (include: [String], exclude: [String]) {
        var include: [String] = []
        var exclude: [String] = []

        for rawValue in text.split(separator: separator) {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty, value != "*" else { continue }

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

    private static func urlFilterPattern(from pattern: String) -> String {
        var p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return ".*" }

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

    private static func escapeJSON(_ string: String) -> String {
        var buffer = "\""
        buffer.reserveCapacity(string.count + 4)
        for char in string {
            switch char {
            case "\"": buffer.append("\\\"")
            case "\\": buffer.append("\\\\")
            case "\n": buffer.append("\\n")
            case "\r": buffer.append("\\r")
            case "\t": buffer.append("\\t")
            default:
                if let ascii = char.asciiValue, ascii >= 32 && ascii <= 126 {
                    buffer.append(char)
                }
            }
        }
        buffer.append("\"")
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

    private func loadDiagnosticRulesFromDisk(sourceId: String) -> [AdBlockUnsupportedRule] {
        let file = diagnosticFileURL(sourceId: sourceId)
        guard let data = try? Data(contentsOf: file),
              let rules = try? JSONDecoder().decode([AdBlockUnsupportedRule].self, from: data) else {
            return []
        }
        return rules
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

private struct AdBlockUnsupportedRule: Codable {
    var rawRule: String
    var compiledJSON: String
    var errorDescription: String
}
