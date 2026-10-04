import UIKit
import WebKit
import Darwin
import CryptoKit

struct AdBlockSubscription: Codable, Equatable {
    var id: String
    var name: String
    var urlString: String
    var isEnabled: Bool
    var lastUpdated: Date?
    var ruleCount: Int
}

struct AdBlockMemoryReport {
    var physicalFootprintBytes: UInt64
    var residentSizeBytes: UInt64
    var activeSubscriptionCount: Int
    var inMemoryRuleListCount: Int
    var inMemoryUserScriptCount: Int
    var inMemoryUserScriptChars: Int
    var metadataRuleCount: Int
    var diskStoreIdentifiers: [String]
    var orphanStoreIdentifiers: [String]
    var subscriptionFilesBytes: UInt64
    var tmpBytes: UInt64

    var physicalFootprintString: String {
        ByteCountFormatter.string(fromByteCount: Int64(physicalFootprintBytes), countStyle: .memory)
    }

    var residentSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(residentSizeBytes), countStyle: .memory)
    }

    var subscriptionFilesSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(subscriptionFilesBytes), countStyle: .file)
    }

    var tmpSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(tmpBytes), countStyle: .file)
    }

    var userScriptsEstimatedSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(inMemoryUserScriptChars * 2), countStyle: .memory)
    }
}

private func releaseSystemHeapPressure() {
    typealias PressureReliefFunction = @convention(c) (UnsafeMutableRawPointer?, Int) -> Int32
    if let handle = dlopen(nil, RTLD_NOW) {
        if let symbol = dlsym(handle, "malloc_zone_pressure_relief") {
            let function = unsafeBitCast(symbol, to: PressureReliefFunction.self)
            _ = function(nil, 0)
        }
        dlclose(handle)
    }
}

private func currentProcessMemory() -> (footprint: UInt64, resident: UInt64) {
    var vmInfo = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &vmInfo) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    let footprint = result == KERN_SUCCESS ? UInt64(vmInfo.phys_footprint) : 0

    var basicInfo = mach_task_basic_info()
    var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let basicResult = withUnsafeMutablePointer(to: &basicInfo) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
        }
    }
    let resident = basicResult == KERN_SUCCESS ? UInt64(basicInfo.resident_size) : 0

    return (footprint, resident)
}

private func computeContentHash(_ text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
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

    private let nativeRuleChunkSize = 8000
    private let maximumCosmeticRulesPerSource = 300000
    private let cosmeticScriptPayloadLimit = 180000
    private let maximumCompilationDuration: TimeInterval = 180
    private let maximumSingleChunkDuration: TimeInterval = 45
    private let autoUpdateInterval: TimeInterval = 86400
    private let autoUpdateRetryCooldown: TimeInterval = 1800

    private let patternValidationCache = NSCache<NSString, NSNumber>()

    private var attachedWebViews = NSHashTable<WKWebView>.weakObjects()
    private var compiledListsBySource: [String: [WKContentRuleList]] = [:]
    private var cosmeticScriptsBySource: [String: [WKUserScript]] = [:]
    private var cosmeticScriptCharsBySource: [String: Int] = [:]
    private var metadataBySource: [String: AdBlockCompiledSourceMetadata] = [:]
    private var unsupportedRulesBySource: [String: [AdBlockUnsupportedRule]] = [:]
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

    private init() {
        if UserDefaults.standard.object(forKey: enabledKey) == nil {
            UserDefaults.standard.set(true, forKey: enabledKey)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        parseQueue.async { [weak self] () -> Void in
            guard let self = self else { return }
            let meta = self.loadMetadata()
            let unsupp = self.loadUnsupportedRules()
            self.stateLock.lock()
            self.metadataBySource = meta
            self.unsupportedRulesBySource = unsupp
            self.stateLock.unlock()

            self.restorePersistedRules()
        }

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

        let fileURL = subscriptionFileURL(id: id)
        try? FileManager.default.removeItem(at: fileURL)

        cleanTemporaryArtifacts()
        releaseSystemHeapPressure()
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
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmed.isEmpty else {
                DispatchQueue.main.async {
                    self.stateLock.lock()
                    self.updatingSourceIds.remove(subscription.id)
                    self.stateLock.unlock()
                    self.setUpdateStatus(sourceId: subscription.id, status: nil)
                    completion(false, 0, "订阅内容不是有效文本")
                }
                return
            }

            let hash = computeContentHash(text)
            self.stateLock.lock()
            let existingMetadata = self.metadataBySource[subscription.id]
            let existingLists = self.compiledListsBySource[subscription.id]
            self.stateLock.unlock()

            if let meta = existingMetadata, meta.contentHash == hash, let lists = existingLists, !lists.isEmpty || !meta.cosmeticRules.isEmpty {
                DispatchQueue.main.async {
                    self.stateLock.lock()
                    self.updatingSourceIds.remove(subscription.id)
                    self.stateLock.unlock()
                    self.setUpdateStatus(sourceId: subscription.id, status: nil)

                    var subscriptions = self.loadSubscriptions()
                    if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
                        subscriptions[index].lastUpdated = Date()
                        subscriptions[index].ruleCount = meta.ruleCount
                        self.saveSubscriptions(subscriptions)
                    }
                    completion(true, meta.ruleCount, nil)
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

            for (_, metadata) in metadataCopy {
                self.restoreCosmeticScripts(metadata: metadata)
            }
            self.applyRulesToAttachedWebViews()

            for (sourceId, metadata) in metadataCopy {
                if metadata.ruleListIdentifiers.isEmpty {
                    continue
                }

                self.loadRuleListsParallel(identifiers: metadata.ruleListIdentifiers) { [weak self] lists in
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

    private func loadRuleListsParallel(
        identifiers: [String],
        completion: @escaping ([WKContentRuleList]) -> Void
    ) {
        guard !identifiers.isEmpty else {
            completion([])
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var results: [String: WKContentRuleList] = [:]

        for id in identifiers {
            group.enter()
            DispatchQueue.main.async {
                WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: id) { ruleList, _ in
                    if let ruleList = ruleList {
                        lock.lock()
                        results[id] = ruleList
                        lock.unlock()
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: parseQueue) {
            let ordered = identifiers.compactMap { results[$0] }
            completion(ordered)
        }
    }

    private func removeOldRuleLists(for sourceId: String) {
        stateLock.lock()
        let oldIdentifiers = metadataBySource[sourceId]?.ruleListIdentifiers ?? []
        stateLock.unlock()

        for identifier in oldIdentifiers {
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier, completionHandler: { _ in })
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

            let payload: AdBlockSourcePayload = autoreleasepool {
                self.buildSourcePayloadParallel(text: text)
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
        let version = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        guard !payload.networkChunks.isEmpty else {
            removeOldRuleLists(for: sourceId)

            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                ruleListIdentifiers: [],
                ruleCount: payload.ruleCount,
                skippedRuleCount: payload.skippedRuleCount,
                cosmeticRules: payload.cosmeticRules,
                cosmeticExceptions: payload.cosmeticExceptions,
                contentHash: payload.contentHash
            )

            stateLock.lock()
            metadataBySource[sourceId] = metadata
            compiledListsBySource.removeValue(forKey: sourceId)
            cosmeticScriptCharsBySource.removeValue(forKey: sourceId)
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
                    self?.cleanTemporaryArtifacts()
                    releaseSystemHeapPressure()

                    let message = payload.skippedRuleCount > 0
                        ? "已更新，跳过 \(payload.skippedRuleCount) 条不兼容规则"
                        : nil

                    completion?(true, message)
                }
            }
            return
        }

        let deadline = Date().addingTimeInterval(maximumCompilationDuration)

        stateLock.lock()
        unsupportedRulesBySource[sourceId] = []
        stateLock.unlock()

        compileChunks(
            payload.networkChunks,
            sourceId: sourceId,
            version: version,
            index: 0,
            lists: [],
            identifiers: [],
            deadline: deadline
        ) { [weak self] lists, identifiers in
            guard let self = self else { return }

            if lists.isEmpty && payload.cosmeticRules.isEmpty && payload.cosmeticExceptions.isEmpty {
                self.stateLock.lock()
                self.updatingSourceIds.remove(sourceId)
                self.stateLock.unlock()
                self.setUpdateStatus(sourceId: sourceId, status: nil)
                DispatchQueue.main.async {
                    completion?(false, "规则编译超时或所有规则块均不兼容")
                }
                return
            }

            self.removeOldRuleLists(for: sourceId)

            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                ruleListIdentifiers: identifiers,
                ruleCount: payload.ruleCount,
                skippedRuleCount: payload.skippedRuleCount + self.unsupportedRuleCount(sourceId: sourceId),
                cosmeticRules: payload.cosmeticRules,
                cosmeticExceptions: payload.cosmeticExceptions,
                contentHash: payload.contentHash
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
                    self?.cleanTemporaryArtifacts()
                    releaseSystemHeapPressure()

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

    private func compileChunks(
        _ chunks: [[AdBlockNetworkRule]],
        sourceId: String,
        version: String,
        index: Int,
        lists: [WKContentRuleList],
        identifiers: [String],
        deadline: Date,
        completion: @escaping ([WKContentRuleList], [String]) -> Void
    ) {
        guard index < chunks.count else {
            completion(lists, identifiers)
            return
        }

        guard Date() < deadline else {
            let remainingRules = chunks[index...].flatMap { $0 }
            for rule in remainingRules.prefix(50) {
                recordUnsupportedRule(
                    sourceId: sourceId,
                    rule: rule,
                    error: "总编译超时，未提交给 WebKit 编译"
                )
            }
            completion(lists, identifiers)
            return
        }

        setUpdateStatus(
            sourceId: sourceId,
            status: "正在编译规则 \(index + 1)/\(chunks.count)…"
        )

        compileRuleGroup(
            chunks[index],
            sourceId: sourceId,
            version: version,
            groupIdentifier: "\(index)",
            deadline: deadline,
            depth: 0
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
                completion: completion
            )
        }
    }

    private func compileRuleGroup(
        _ rules: [AdBlockNetworkRule],
        sourceId: String,
        version: String,
        groupIdentifier: String,
        deadline: Date,
        depth: Int,
        completion: @escaping ([WKContentRuleList], [String]) -> Void
    ) {
        guard !rules.isEmpty else {
            completion([], [])
            return
        }

        guard Date() < deadline else {
            for rule in rules.prefix(20) {
                recordUnsupportedRule(
                    sourceId: sourceId,
                    rule: rule,
                    error: "编译超时"
                )
            }
            completion([], [])
            return
        }

        guard let json = autoreleasepool(invoking: { jsonString(from: rules.map(\.compiledRule)) }) else {
            for rule in rules.prefix(20) {
                recordUnsupportedRule(
                    sourceId: sourceId,
                    rule: rule,
                    error: "无法生成 JSON"
                )
            }
            completion([], [])
            return
        }

        let identifier = "\(identifierPrefix).\(sourceId.replacingOccurrences(of: "-", with: "")).\(version).\(groupIdentifier)"
        let gate = AdBlockChunkCompilationGate()

        func resolve(ruleList: WKContentRuleList?, error: Error?) {
            gate.resolve {
                guard let ruleList = ruleList else {
                    if rules.count == 1 || depth >= 6 {
                        for rule in rules.prefix(10) {
                            self.recordUnsupportedRule(
                                sourceId: sourceId,
                                rule: rule,
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
                        left,
                        sourceId: sourceId,
                        version: version,
                        groupIdentifier: "\(groupIdentifier)L",
                        deadline: deadline,
                        depth: depth + 1
                    ) { leftLists, leftIdentifiers in
                        self.compileRuleGroup(
                            right,
                            sourceId: sourceId,
                            version: version,
                            groupIdentifier: "\(groupIdentifier)R",
                            deadline: deadline,
                            depth: depth + 1
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
        removeOldRuleLists(for: sourceId)
        stateLock.lock()
        metadataBySource.removeValue(forKey: sourceId)
        compiledListsBySource.removeValue(forKey: sourceId)
        cosmeticScriptsBySource.removeValue(forKey: sourceId)
        cosmeticScriptCharsBySource.removeValue(forKey: sourceId)
        unsupportedRulesBySource.removeValue(forKey: sourceId)
        updatingSourceIds.remove(sourceId)
        let metaCopy = metadataBySource
        let unsuppCopy = unsupportedRulesBySource
        stateLock.unlock()

        setUpdateStatus(sourceId: sourceId, status: nil)
        saveMetadata(metaCopy)
        saveUnsupportedRules(unsuppCopy)
        applyRulesToAttachedWebViews()
        cleanTemporaryArtifacts()
        releaseSystemHeapPressure()
    }

    private func restoreCosmeticScripts(metadata: AdBlockCompiledSourceMetadata) {
        guard !metadata.cosmeticRules.isEmpty || !metadata.cosmeticExceptions.isEmpty else {
            stateLock.lock()
            cosmeticScriptsBySource.removeValue(forKey: metadata.sourceId)
            cosmeticScriptCharsBySource.removeValue(forKey: metadata.sourceId)
            stateLock.unlock()
            return
        }

        let batches = cosmeticRuleBatches(metadata.cosmeticRules)
        var exceptionsPayload: [[String: Any]] = []
        for ex in metadata.cosmeticExceptions {
            exceptionsPayload.append([
                "s": ex.selector,
                "d": ex.domains
            ])
        }
        let exceptionsData = (try? JSONSerialization.data(withJSONObject: exceptionsPayload)) ?? Data()
        let exceptionsJson = String(data: exceptionsData, encoding: .utf8) ?? "[]"

        var totalChars = 0
        var scripts: [WKUserScript] = []

        for (index, rules) in batches.enumerated() {
            var globalList: [String] = []
            var withExcludes: [[String: Any]] = []
            var domainMap: [String: [String]] = [:]

            for rule in rules {
                if rule.domains.isEmpty {
                    if rule.excludedDomains.isEmpty {
                        globalList.append(rule.selector)
                    } else {
                        withExcludes.append([
                            "s": rule.selector,
                            "x": rule.excludedDomains
                        ])
                    }
                } else {
                    for d in rule.domains {
                        var existing = domainMap[d] ?? []
                        existing.append(rule.selector)
                        domainMap[d] = existing
                    }
                }
            }

            let gData = (try? JSONSerialization.data(withJSONObject: globalList)) ?? Data()
            let gJson = String(data: gData, encoding: .utf8) ?? "[]"

            let eData = (try? JSONSerialization.data(withJSONObject: withExcludes)) ?? Data()
            let eJson = String(data: eData, encoding: .utf8) ?? "[]"

            let dData = (try? JSONSerialization.data(withJSONObject: domainMap)) ?? Data()
            let dJson = String(data: dData, encoding: .utf8) ?? "{}"

            let safeSourceId = metadata.sourceId.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
            let batchIdentifier = "\(safeSourceId)_\(index)"
            let exceptionsInjectionCode = (index == 0 && !metadata.cosmeticExceptions.isEmpty)
                ? "core.exceptions = core.exceptions.concat(\(exceptionsJson));"
                : ""

            let source = """
            (function() {
                var host = (location.hostname || '').toLowerCase();
                if (!host) {
                    return;
                }

                if (!window.__sb_ab_core__) {
                    var domainList = [];
                    var parts = host.split('.');
                    for (var i = 0; i < parts.length - 1; i++) {
                        domainList.push(parts.slice(i).join('.'));
                    }
                    var supportsHas = false;
                    try {
                        document.querySelector(':has(*)');
                        supportsHas = true;
                    } catch (_) {
                        supportsHas = false;
                    }
                    window.__sb_ab_core__ = {
                        host: host,
                        domainList: domainList,
                        supportsHas: supportsHas,
                        seen: {},
                        exceptions: [],
                        styleElement: null,
                        fallbackSelectors: [],
                        observerStarted: false,
                        injectCss: function(selectors) {
                            if (!selectors || selectors.length === 0) {
                                return;
                            }
                            var style = window.__sb_ab_core__.styleElement;
                            if (!style) {
                                style = document.getElementById('__simple_browser_adblock_style__');
                            }
                            if (!style) {
                                style = document.createElement('style');
                                style.id = '__simple_browser_adblock_style__';
                                style.type = 'text/css';
                                var root = document.head || document.documentElement;
                                if (root) {
                                    root.appendChild(style);
                                } else {
                                    var obs = new MutationObserver(function() {
                                        var r = document.head || document.documentElement;
                                        if (r) {
                                            obs.disconnect();
                                            r.appendChild(style);
                                        }
                                    });
                                    obs.observe(document, { childList: true, subtree: true });
                                }
                                window.__sb_ab_core__.styleElement = style;
                            }
                            var batchSize = 100;
                            var chunks = [];
                            for (var i = 0; i < selectors.length; i += batchSize) {
                                var slice = selectors.slice(i, i + batchSize);
                                chunks.push(slice.join(',') + '{display:none !important;visibility:hidden !important;pointer-events:none !important;}');
                            }
                            var cssText = chunks.join('\\n');
                            style.textContent = (style.textContent ? style.textContent + '\\n' : '') + cssText;
                        },
                        isWhitelisted: function(sel) {
                            var x = window.__sb_ab_core__.exceptions;
                            if (!x || x.length === 0) {
                                return false;
                            }
                            var h = window.__sb_ab_core__.host;
                            for (var i = 0; i < x.length; i++) {
                                var item = x[i];
                                if (item.s === sel) {
                                    if (!item.d || item.d.length === 0) {
                                        return true;
                                    }
                                    for (var j = 0; j < item.d.length; j++) {
                                        var dm = item.d[j];
                                        if (h === dm || h.endsWith('.' + dm)) {
                                            return true;
                                        }
                                    }
                                }
                            }
                            return false;
                        },
                        addFallback: function(sel) {
                            window.__sb_ab_core__.fallbackSelectors.push(sel);
                            if (!window.__sb_ab_core__.observerStarted) {
                                window.__sb_ab_core__.observerStarted = true;
                                window.__sb_ab_core__.initFallbackObserver();
                            }
                        },
                        initFallbackObserver: function() {
                            function hideEl(el) {
                                if (!el || !el.style) {
                                    return;
                                }
                                el.style.setProperty('display', 'none', 'important');
                                el.style.setProperty('visibility', 'hidden', 'important');
                                el.style.setProperty('pointer-events', 'none', 'important');
                            }
                            function scanScope(scope) {
                                var list = window.__sb_ab_core__.fallbackSelectors;
                                if (!list || list.length === 0 || !scope) {
                                    return;
                                }
                                for (var i = 0; i < list.length; i++) {
                                    var sel = list[i];
                                    var idx = sel.indexOf(':has(');
                                    if (idx < 0 || !sel.endsWith(')')) {
                                        continue;
                                    }
                                    var outer = sel.substring(0, idx).trim() || '*';
                                    var inner = sel.substring(idx + 5, sel.length - 1).trim();
                                    if (!inner) {
                                        continue;
                                    }
                                    var elements = [];
                                    try {
                                        if (scope.matches && scope.matches(outer)) {
                                            elements.push(scope);
                                        }
                                        if (scope.querySelectorAll) {
                                            var found = scope.querySelectorAll(outer);
                                            for (var k = 0; k < found.length; k++) {
                                                elements.push(found[k]);
                                            }
                                        }
                                    } catch (_) {}
                                    for (var j = 0; j < elements.length; j++) {
                                        var el = elements[j];
                                        var matched = false;
                                        try {
                                            if (inner.startsWith('>')) {
                                                matched = el.querySelector(':scope ' + inner) !== null;
                                            } else {
                                                matched = el.querySelector(inner) !== null;
                                            }
                                        } catch (_) {
                                            matched = false;
                                        }
                                        if (matched) {
                                            hideEl(el);
                                        }
                                    }
                                }
                            }
                            var scheduledNodes = [];
                            var scheduledTimer = null;
                            function processScheduled() {
                                scheduledTimer = null;
                                var nodes = scheduledNodes;
                                scheduledNodes = [];
                                for (var i = 0; i < nodes.length; i++) {
                                    scanScope(nodes[i]);
                                }
                            }
                            var observer = new MutationObserver(function(mutations) {
                                for (var i = 0; i < mutations.length; i++) {
                                    var added = mutations[i].addedNodes;
                                    for (var j = 0; j < added.length; j++) {
                                        if (added[j].nodeType === 1) {
                                            scheduledNodes.push(added[j]);
                                        }
                                    }
                                }
                                if (!scheduledTimer && scheduledNodes.length > 0) {
                                    var scheduleFn = window.requestAnimationFrame || function(cb) { setTimeout(cb, 16); };
                                    scheduledTimer = scheduleFn(processScheduled);
                                }
                            });
                            var target = document.documentElement || document;
                            observer.observe(target, { childList: true, subtree: true });
                            if (document.readyState === 'loading') {
                                document.addEventListener('DOMContentLoaded', function() {
                                    scanScope(document.body || document.documentElement);
                                }, { once: true });
                            } else {
                                scanScope(document.body || document.documentElement);
                            }
                        }
                    };
                }

                var core = window.__sb_ab_core__;
                var token = '__sb_ab_\(batchIdentifier)__';
                if (window[token]) {
                    return;
                }
                window[token] = true;

                \(exceptionsInjectionCode)

                var g = \(gJson);
                var e = \(eJson);
                var d = \(dJson);

                var targetSelectors = [];
                function tryAdd(sel) {
                    if (!sel || core.seen[sel]) {
                        return;
                    }
                    core.seen[sel] = true;
                    if (!core.isWhitelisted(sel)) {
                        targetSelectors.push(sel);
                    }
                }

                for (var i = 0; i < g.length; i++) {
                    tryAdd(g[i]);
                }

                for (var i = 0; i < e.length; i++) {
                    var item = e[i];
                    var excluded = false;
                    if (item.x && item.x.length > 0) {
                        for (var j = 0; j < item.x.length; j++) {
                            var ex = item.x[j];
                            if (core.host === ex || core.host.endsWith('.' + ex)) {
                                excluded = true;
                                break;
                            }
                        }
                    }
                    if (!excluded) {
                        tryAdd(item.s);
                    }
                }

                for (var i = 0; i < core.domainList.length; i++) {
                    var list = d[core.domainList[i]];
                    if (list && list.length > 0) {
                        for (var j = 0; j < list.length; j++) {
                            tryAdd(list[j]);
                        }
                    }
                }

                if (targetSelectors.length === 0) {
                    return;
                }

                var cssBatch = [];
                for (var i = 0; i < targetSelectors.length; i++) {
                    var sel = targetSelectors[i];
                    if (sel.indexOf(':has(') !== -1 && !core.supportsHas) {
                        core.addFallback(sel);
                    } else {
                        cssBatch.push(sel);
                    }
                }

                core.injectCss(cssBatch);
            })();
            """

            totalChars += source.count

            let script = WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            scripts.append(script)
        }

        stateLock.lock()
        cosmeticScriptsBySource[metadata.sourceId] = scripts
        cosmeticScriptCharsBySource[metadata.sourceId] = totalChars
        stateLock.unlock()
    }

    private func cosmeticRuleBatches(
        _ rules: [AdBlockCosmeticRule]
    ) -> [[AdBlockCosmeticRule]] {
        let chunkSize = 12000
        return stride(from: 0, to: rules.count, by: chunkSize).map {
            Array(rules[$0..<min($0 + chunkSize, rules.count)])
        }
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

    private func buildSourcePayloadParallel(text: String) -> AdBlockSourcePayload {
        let lines = text.components(separatedBy: .newlines)
        let totalLines = lines.count
        guard totalLines > 0 else {
            return AdBlockSourcePayload(
                networkChunks: [],
                cosmeticRules: [],
                cosmeticExceptions: [],
                ruleCount: 0,
                skippedRuleCount: 0,
                contentHash: nil
            )
        }

        let sliceSize = 10000
        let sliceCount = (totalLines + sliceSize - 1) / sliceSize

        struct IntermediateResult {
            var blockRules: [AdBlockNetworkRule]
            var exceptionRules: [AdBlockNetworkRule]
            var cosmeticRules: [AdBlockCosmeticRule]
            var cosmeticExceptions: [AdBlockCosmeticException]
            var ruleCount: Int
            var skippedRuleCount: Int
        }

        var results = Array<IntermediateResult>(
            repeating: IntermediateResult(
                blockRules: [],
                exceptionRules: [],
                cosmeticRules: [],
                cosmeticExceptions: [],
                ruleCount: 0,
                skippedRuleCount: 0
            ),
            count: sliceCount
        )

        DispatchQueue.concurrentPerform(iterations: sliceCount) { index in
            autoreleasepool {
                let start = index * sliceSize
                let end = min(start + sliceSize, totalLines)
                let subLines = lines[start..<end]

                var blockRules: [AdBlockNetworkRule] = []
                var exceptionRules: [AdBlockNetworkRule] = []
                var cosmeticRules: [AdBlockCosmeticRule] = []
                var cosmeticExceptions: [AdBlockCosmeticException] = []
                var ruleCount = 0
                var skippedRuleCount = 0

                for line in subLines {
                    let result = self.parseRule(line)
                    if let networkRule = result.networkRule {
                        let ruleItem = AdBlockNetworkRule(
                            rawRule: line,
                            compiledRule: networkRule,
                            isException: result.isException
                        )
                        if result.isException {
                            exceptionRules.append(ruleItem)
                        } else {
                            blockRules.append(ruleItem)
                        }
                        ruleCount += 1
                    }

                    if !result.cosmeticRules.isEmpty {
                        for cosmeticRule in result.cosmeticRules {
                            cosmeticRules.append(cosmeticRule)
                            ruleCount += 1
                        }
                    }

                    if !result.cosmeticExceptions.isEmpty {
                        for cosmeticEx in result.cosmeticExceptions {
                            cosmeticExceptions.append(cosmeticEx)
                            ruleCount += 1
                        }
                    }

                    if result.isUnsupported {
                        skippedRuleCount += 1
                    }
                }

                results[index] = IntermediateResult(
                    blockRules: blockRules,
                    exceptionRules: exceptionRules,
                    cosmeticRules: cosmeticRules,
                    cosmeticExceptions: cosmeticExceptions,
                    ruleCount: ruleCount,
                    skippedRuleCount: skippedRuleCount
                )
            }
        }

        var allBlockRules: [AdBlockNetworkRule] = []
        var allExceptionRules: [AdBlockNetworkRule] = []
        var allCosmeticRules: [AdBlockCosmeticRule] = []
        var allCosmeticExceptions: [AdBlockCosmeticException] = []
        var totalRuleCount = 0
        var totalSkipped = 0

        for r in results {
            allBlockRules.append(contentsOf: r.blockRules)
            allExceptionRules.append(contentsOf: r.exceptionRules)
            allCosmeticExceptions.append(contentsOf: r.cosmeticExceptions)

            if allCosmeticRules.count < maximumCosmeticRulesPerSource {
                let remainingSpace = maximumCosmeticRulesPerSource - allCosmeticRules.count
                if r.cosmeticRules.count <= remainingSpace {
                    allCosmeticRules.append(contentsOf: r.cosmeticRules)
                } else {
                    allCosmeticRules.append(contentsOf: r.cosmeticRules.prefix(remainingSpace))
                    totalSkipped += (r.cosmeticRules.count - remainingSpace)
                }
            } else {
                totalSkipped += r.cosmeticRules.count
            }

            totalRuleCount += r.ruleCount
            totalSkipped += r.skippedRuleCount
        }

        var uniqueExceptionRules: [AdBlockNetworkRule] = []
        var seenExceptionRules = Set<String>()
        for rule in allExceptionRules {
            if !seenExceptionRules.contains(rule.rawRule) {
                seenExceptionRules.insert(rule.rawRule)
                uniqueExceptionRules.append(rule)
            }
        }

        var allNetworkChunks: [[AdBlockNetworkRule]] = []
        if !allBlockRules.isEmpty {
            allNetworkChunks = stride(from: 0, to: allBlockRules.count, by: nativeRuleChunkSize).map { start in
                let blockChunk = Array(allBlockRules[start..<min(start + nativeRuleChunkSize, allBlockRules.count)])
                return blockChunk + uniqueExceptionRules
            }
        } else if !uniqueExceptionRules.isEmpty {
            allNetworkChunks = [uniqueExceptionRules]
        }

        let contentHash = computeContentHash(text)

        return AdBlockSourcePayload(
            networkChunks: allNetworkChunks,
            cosmeticRules: allCosmeticRules,
            cosmeticExceptions: allCosmeticExceptions,
            ruleCount: totalRuleCount,
            skippedRuleCount: totalSkipped,
            contentHash: contentHash
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

        let key = pattern as NSString
        if let cached = patternValidationCache.object(forKey: key) {
            return cached.boolValue
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
                if openParens < 0 {
                    patternValidationCache.setObject(NSNumber(value: false), forKey: key)
                    return false
                }
            } else if ch == "[" {
                openBrackets += 1
            } else if ch == "]" {
                openBrackets -= 1
                if openBrackets < 0 {
                    patternValidationCache.setObject(NSNumber(value: false), forKey: key)
                    return false
                }
            }
        }

        if escaped || openParens != 0 || openBrackets != 0 {
            patternValidationCache.setObject(NSNumber(value: false), forKey: key)
            return false
        }

        let isValid = (try? NSRegularExpression(pattern: pattern)) != nil
        patternValidationCache.setObject(NSNumber(value: isValid), forKey: key)
        return isValid
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
            let selectorsText = String(line[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

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

        let rawPattern = String(parts[0])
            .trimmingCharacters(in: .whitespacesAndNewlines)

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

        var trigger: [String: Any] = [
            "url-filter": filter,
            "url-filter-is-case-sensitive": isCaseSensitive
        ]

        if !includeDomains.isEmpty {
            trigger["if-domain"] = Array(Set(includeDomains)).sorted()
        }
        if !excludeDomains.isEmpty {
            trigger["unless-domain"] = Array(Set(excludeDomains)).sorted()
        }

        if !resourceTypes.isEmpty {
            trigger["resource-type"] = Array(Set(resourceTypes)).sorted()
        }

        if !loadTypes.isEmpty {
            trigger["load-type"] = Array(Set(loadTypes)).sorted()
        }

        return AdBlockParsedLine(
            networkRule: [
                "trigger": trigger,
                "action": [
                    "type": isException ? "ignore-previous-rules" : "block"
                ]
            ],
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
        guard text.contains(",") else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }

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

    private func jsonString(from rules: [[String: Any]]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
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
    }

    private func recordUnsupportedRule(
        sourceId: String,
        rule: AdBlockNetworkRule,
        error: String
    ) {
        stateLock.lock()
        var items = unsupportedRulesBySource[sourceId] ?? []

        if items.count < 200 && !items.contains(where: { $0.rawRule == rule.rawRule }) {
            let compiledJSON = jsonString(from: [rule.compiledRule]) ?? ""
            let item = AdBlockUnsupportedRule(
                rawRule: rule.rawRule,
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
    }

    func cleanTemporaryArtifacts() {
        let tmpPath = NSTemporaryDirectory()
        if let files = try? FileManager.default.contentsOfDirectory(atPath: tmpPath) {
            for file in files {
                let fullPath = (tmpPath as NSString).appendingPathComponent(file)
                try? FileManager.default.removeItem(atPath: fullPath)
            }
        }
    }

    func scanPhysicalMemoryOnly() -> String {
        let memory = currentProcessMemory()
        return ByteCountFormatter.string(fromByteCount: Int64(memory.footprint), countStyle: .memory)
    }

    func currentQuickReport() -> AdBlockMemoryReport {
        let memory = currentProcessMemory()

        stateLock.lock()
        var inMemoryRuleCount = 0
        var metadataRuleCount = 0
        var activeIdentifiers: [String] = []
        for metadata in metadataBySource.values {
            activeIdentifiers.append(contentsOf: metadata.ruleListIdentifiers)
            metadataRuleCount += metadata.ruleCount
        }

        for ruleLists in compiledListsBySource.values {
            inMemoryRuleCount += ruleLists.count
        }

        var scriptCount = 0
        for scripts in cosmeticScriptsBySource.values {
            scriptCount += scripts.count
        }
        let scriptChars = cosmeticScriptCharsBySource.values.reduce(0, +)
        stateLock.unlock()

        return AdBlockMemoryReport(
            physicalFootprintBytes: memory.footprint,
            residentSizeBytes: memory.resident,
            activeSubscriptionCount: loadSubscriptions().count,
            inMemoryRuleListCount: inMemoryRuleCount,
            inMemoryUserScriptCount: scriptCount,
            inMemoryUserScriptChars: scriptChars,
            metadataRuleCount: metadataRuleCount,
            diskStoreIdentifiers: activeIdentifiers,
            orphanStoreIdentifiers: [],
            subscriptionFilesBytes: 0,
            tmpBytes: 0
        )
    }

    func scanMemoryUsage(completion: @escaping (AdBlockMemoryReport) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] () -> Void in
            guard let self = self else { return }

            let memory = currentProcessMemory()

            self.stateLock.lock()
            var activeIdentifiers = Set<String>()
            var inMemoryRuleCount = 0
            var metadataRuleCount = 0
            for metadata in self.metadataBySource.values {
                activeIdentifiers.formUnion(metadata.ruleListIdentifiers)
                metadataRuleCount += metadata.ruleCount
            }

            for ruleLists in self.compiledListsBySource.values {
                inMemoryRuleCount += ruleLists.count
            }

            var scriptCount = 0
            for scripts in self.cosmeticScriptsBySource.values {
                scriptCount += scripts.count
            }
            let scriptChars = self.cosmeticScriptCharsBySource.values.reduce(0, +)
            self.stateLock.unlock()

            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            var subscriptionBytes: UInt64 = 0
            if let files = try? FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.fileSizeKey]) {
                for fileURL in files {
                    let name = fileURL.lastPathComponent
                    if name.hasPrefix("adblock_subscription_") && name.hasSuffix(".txt") {
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                           let size = attrs[.size] as? UInt64 {
                            subscriptionBytes += size
                        }
                    }
                }
            }

            let tmpPath = NSTemporaryDirectory()
            var tmpBytes: UInt64 = 0
            if let tmpFiles = try? FileManager.default.contentsOfDirectory(atPath: tmpPath) {
                for file in tmpFiles {
                    let fullPath = (tmpPath as NSString).appendingPathComponent(file)
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                       let size = attrs[.size] as? UInt64 {
                        tmpBytes += size
                    }
                }
            }

            DispatchQueue.main.async {
                WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { (allIds: [String]?) in
                    let storeIds: [String] = allIds ?? []
                    let orphanIds: [String] = storeIds.filter { !activeIdentifiers.contains($0) }

                    let report = AdBlockMemoryReport(
                        physicalFootprintBytes: memory.footprint,
                        residentSizeBytes: memory.resident,
                        activeSubscriptionCount: self.loadSubscriptions().count,
                        inMemoryRuleListCount: inMemoryRuleCount,
                        inMemoryUserScriptCount: scriptCount,
                        inMemoryUserScriptChars: scriptChars,
                        metadataRuleCount: metadataRuleCount,
                        diskStoreIdentifiers: storeIds,
                        orphanStoreIdentifiers: orphanIds,
                        subscriptionFilesBytes: subscriptionBytes,
                        tmpBytes: tmpBytes
                    )

                    completion(report)
                }
            }
        }
    }

    func cleanMemoryResidue(completion: ((AdBlockMemoryReport) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] () -> Void in
            guard let self = self else { return }

            self.cleanTemporaryArtifacts()

            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let activeSourceIds = Set(self.loadSubscriptions().map(\.id) + [Self.customSourceId])

            if let files = try? FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil) {
                for fileURL in files {
                    let name = fileURL.lastPathComponent
                    if name.hasSuffix(".ipa") || name.hasSuffix(".zip") || name.hasSuffix(".log") {
                        try? FileManager.default.removeItem(at: fileURL)
                    } else if name.hasPrefix("adblock_subscription_") && name.hasSuffix(".txt") {
                        let subId = name
                            .replacingOccurrences(of: "adblock_subscription_", with: "")
                            .replacingOccurrences(of: ".txt", with: "")
                        if !activeSourceIds.contains(subId) {
                            try? FileManager.default.removeItem(at: fileURL)
                        }
                    }
                }
            }

            self.stateLock.lock()
            var activeIdentifiers = Set<String>()
            for metadata in self.metadataBySource.values {
                activeIdentifiers.formUnion(metadata.ruleListIdentifiers)
            }
            self.stateLock.unlock()

            DispatchQueue.main.async {
                WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { (identifiers: [String]?) in
                    let list: [String] = identifiers ?? []
                    let group = DispatchGroup()

                    for identifier in list {
                        if !activeIdentifiers.contains(identifier) {
                            group.enter()
                            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in
                                group.leave()
                            }
                        }
                    }

                    group.notify(queue: .main) {
                        URLCache.shared.removeAllCachedResponses()
                        WebsiteCleaner.shared.cleanCacheOnly {
                            releaseSystemHeapPressure()

                            self.scanMemoryUsage { rep in
                                completion?(rep)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct AdBlockCompiledSourceMetadata: Codable {
    var sourceId: String
    var ruleListIdentifiers: [String]
    var ruleCount: Int
    var skippedRuleCount: Int
    var cosmeticRules: [AdBlockCosmeticRule]
    var cosmeticExceptions: [AdBlockCosmeticException]
    var contentHash: String?

    enum CodingKeys: String, CodingKey {
        case sourceId, ruleListIdentifiers, ruleCount, skippedRuleCount, cosmeticRules, cosmeticExceptions, contentHash
    }

    init(
        sourceId: String,
        ruleListIdentifiers: [String],
        ruleCount: Int,
        skippedRuleCount: Int,
        cosmeticRules: [AdBlockCosmeticRule],
        cosmeticExceptions: [AdBlockCosmeticException] = [],
        contentHash: String? = nil
    ) {
        self.sourceId = sourceId
        self.ruleListIdentifiers = ruleListIdentifiers
        self.ruleCount = ruleCount
        self.skippedRuleCount = skippedRuleCount
        self.cosmeticRules = cosmeticRules
        self.cosmeticExceptions = cosmeticExceptions
        self.contentHash = contentHash
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceId = try container.decode(String.self, forKey: .sourceId)
        self.ruleListIdentifiers = try container.decode([String].self, forKey: .ruleListIdentifiers)
        self.ruleCount = try container.decode(Int.self, forKey: .ruleCount)
        self.skippedRuleCount = try container.decode(Int.self, forKey: .skippedRuleCount)
        self.cosmeticRules = try container.decode([AdBlockCosmeticRule].self, forKey: .cosmeticRules)
        self.cosmeticExceptions = try container.decodeIfPresent([AdBlockCosmeticException].self, forKey: .cosmeticExceptions) ?? []
        self.contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
    }
}

private struct AdBlockSourcePayload {
    var networkChunks: [[AdBlockNetworkRule]]
    var cosmeticRules: [AdBlockCosmeticRule]
    var cosmeticExceptions: [AdBlockCosmeticException]
    var ruleCount: Int
    var skippedRuleCount: Int
    var contentHash: String?
}

private struct AdBlockParsedLine {
    var networkRule: [String: Any]?
    var isException: Bool
    var cosmeticRules: [AdBlockCosmeticRule]
    var cosmeticExceptions: [AdBlockCosmeticException]
    var isUnsupported: Bool
}

private struct AdBlockNetworkRule {
    var rawRule: String
    var compiledRule: [String: Any]
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
