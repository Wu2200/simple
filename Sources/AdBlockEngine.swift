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

struct SandboxFileItem {
    var name: String
    var sizeBytes: UInt64
    var path: String

    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
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
    var documentsBytes: UInt64
    var cachesBytes: UInt64
    var tmpBytes: UInt64
    var largeArtifacts: [SandboxFileItem]
    var urlCacheMemoryBytes: Int
    var urlCacheDiskBytes: Int

    var physicalFootprintString: String {
        ByteCountFormatter.string(fromByteCount: Int64(physicalFootprintBytes), countStyle: .memory)
    }

    var residentSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(residentSizeBytes), countStyle: .memory)
    }

    var documentsSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(documentsBytes), countStyle: .file)
    }

    var cachesSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(cachesBytes), countStyle: .file)
    }

    var tmpSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(tmpBytes), countStyle: .file)
    }

    var userScriptsEstimatedSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(inMemoryUserScriptChars * 2), countStyle: .memory)
    }

    var urlCacheMemoryString: String {
        ByteCountFormatter.string(fromByteCount: Int64(urlCacheMemoryBytes), countStyle: .memory)
    }

    var urlCacheDiskString: String {
        ByteCountFormatter.string(fromByteCount: Int64(urlCacheDiskBytes), countStyle: .file)
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

private func calculateDirectorySize(at url: URL) -> UInt64 {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return 0
    }

    var total: UInt64 = 0
    for case let fileURL as URL in enumerator {
        if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
           values.isRegularFile == true,
           let size = values.fileSize {
            total += UInt64(size)
        }
    }
    return total
}

final class AdBlockManager {
    static let shared = AdBlockManager()

    static let customSourceId = "__custom_rules__"

    private let enabledKey = "adblock_enabled_v2"
    private let subscriptionsKey = "adblock_subscriptions_v2"
    private let customRulesKey = "adblock_custom_rules_v2"
    private let metadataKey = "adblock_compiled_metadata_v10"
    private let identifierPrefix = "SimpleBrowserAdBlockV10"
    private let diagnosticKey = "adblock_unsupported_rules_v1"

    private let maxRulesPerChunk = 25000
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

        cleanupLegacyMetadata()
        metadataBySource = loadMetadata()
        unsupportedRulesBySource = loadUnsupportedRules()
        restorePersistedRules()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.cleanOrphanRuleLists()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.checkAndAutoUpdateSubscriptions()
        }
    }

    private func cleanupLegacyMetadata() {
        let legacyKeys = [
            "adblock_compiled_metadata_v9",
            "adblock_compiled_metadata_v8",
            "adblock_compiled_metadata_v7"
        ]
        for key in legacyKeys {
            UserDefaults.standard.removeObject(forKey: key)
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

        cleanOrphanRuleLists()
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
                guard let metadata = metadataCopy[sourceId], !metadata.ruleListIdentifiers.isEmpty else {
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

            let (chunks, totalCount, skippedCount, hasJsRules) = autoreleasepool {
                self.parseRulesAndChunk(text: text, sourceId: sourceId)
            }

            self.setUpdateStatus(
                sourceId: sourceId,
                status: "正在编译规则…"
            )

            self.compileChunksDirectly(
                chunks: chunks,
                sourceId: sourceId,
                totalCount: totalCount,
                skippedCount: skippedCount,
                hasJsFallback: hasJsRules,
                completion: completion
            )
        }
    }

    private func parseRulesAndChunk(
        text: String,
        sourceId: String
    ) -> (chunks: [[[String: Any]]], totalCount: Int, skippedCount: Int, hasJsRules: Bool) {
        var networkRules: [[String: Any]] = []
        var cosmeticRules: [[String: Any]] = []
        var totalCount = 0
        var skippedCount = 0
        var hasJs = false

        text.enumerateLines { line, _ in
            autoreleasepool {
                let parsed = self.parseSingleLine(line)
                if let net = parsed.networkRule {
                    networkRules.append(net)
                    totalCount += 1
                }
                if let cos = parsed.cosmeticRule {
                    cosmeticRules.append(cos)
                    totalCount += 1
                }
                if parsed.isJsFallback {
                    hasJs = true
                }
                if parsed.isUnsupported {
                    skippedCount += 1
                }
            }
        }

        let combined = networkRules + cosmeticRules
        networkRules.removeAll(keepingCapacity: false)
        cosmeticRules.removeAll(keepingCapacity: false)

        var chunks: [[[String: Any]]] = []
        if combined.isEmpty {
            return (chunks, totalCount, skippedCount, hasJs)
        }

        for i in stride(from: 0, to: combined.count, by: maxRulesPerChunk) {
            let end = min(i + maxRulesPerChunk, combined.count)
            chunks.append(Array(combined[i..<end]))
        }

        return (chunks, totalCount, skippedCount, hasJs)
    }

    private func compileChunksDirectly(
        chunks: [[[String: Any]]],
        sourceId: String,
        totalCount: Int,
        skippedCount: Int,
        hasJsFallback: Bool,
        completion: ((Bool, String?) -> Void)?
    ) {
        guard !chunks.isEmpty else {
            removeOldRuleLists(for: sourceId)
            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                ruleListIdentifiers: [],
                ruleCount: 0,
                skippedRuleCount: skippedCount
            )

            stateLock.lock()
            metadataBySource[sourceId] = metadata
            compiledListsBySource.removeValue(forKey: sourceId)
            cosmeticScriptsBySource.removeValue(forKey: sourceId)
            unsupportedRulesBySource[sourceId] = []
            let metaCopy = metadataBySource
            let unsuppCopy = unsupportedRulesBySource
            updatingSourceIds.remove(sourceId)
            stateLock.unlock()

            saveMetadata(metaCopy)
            saveUnsupportedRules(unsuppCopy)

            DispatchQueue.main.async { [weak self] in
                self?.setUpdateStatus(sourceId: sourceId, status: nil)
                self?.applyRulesToAttachedWebViews()
                releaseSystemHeapPressure()
                completion?(true, nil)
            }
            return
        }

        let version = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var compiledLists: [WKContentRuleList] = []
        var compiledIdentifiers: [String] = []

        func compileIndex(_ index: Int) {
            guard index < chunks.count else {
                self.removeOldRuleLists(for: sourceId)

                let metadata = AdBlockCompiledSourceMetadata(
                    sourceId: sourceId,
                    ruleListIdentifiers: compiledIdentifiers,
                    ruleCount: totalCount,
                    skippedRuleCount: skippedCount
                )

                self.stateLock.lock()
                self.metadataBySource[sourceId] = metadata
                self.compiledListsBySource[sourceId] = compiledLists
                self.cosmeticScriptsBySource.removeValue(forKey: sourceId)
                self.updatingSourceIds.remove(sourceId)
                let metaCopy = self.metadataBySource
                let unsuppCopy = self.unsupportedRulesBySource
                self.stateLock.unlock()

                self.saveMetadata(metaCopy)
                self.saveUnsupportedRules(unsuppCopy)

                DispatchQueue.main.async { [weak self] in
                    self?.setUpdateStatus(sourceId: sourceId, status: nil)
                    self?.applyRulesToAttachedWebViews()
                    releaseSystemHeapPressure()

                    let message: String?
                    if skippedCount > 0 {
                        message = "已更新，跳过 \(skippedCount) 条不兼容规则"
                    } else {
                        message = nil
                    }
                    completion?(true, message)
                }
                return
            }

            self.setUpdateStatus(
                sourceId: sourceId,
                status: "正在编译规则 \(index + 1)/\(chunks.count)…"
            )

            let identifier = "\(self.identifierPrefix).\(sourceId.replacingOccurrences(of: "-", with: "")).\(version).\(index)"
            guard let json = autoreleasepool(invoking: { self.jsonString(from: chunks[index]) }) else {
                compileIndex(index + 1)
                return
            }

            DispatchQueue.main.async {
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: json
                ) { ruleList, error in
                    self.parseQueue.async {
                        if let ruleList = ruleList {
                            compiledLists.append(ruleList)
                            compiledIdentifiers.append(identifier)
                        }
                        compileIndex(index + 1)
                    }
                }
            }
        }

        compileIndex(0)
    }

    private func deactivateSource(id sourceId: String) {
        removeOldRuleLists(for: sourceId)
        stateLock.lock()
        metadataBySource.removeValue(forKey: sourceId)
        compiledListsBySource.removeValue(forKey: sourceId)
        cosmeticScriptsBySource.removeValue(forKey: sourceId)
        unsupportedRulesBySource.removeValue(forKey: sourceId)
        updatingSourceIds.remove(sourceId)
        let metaCopy = metadataBySource
        let unsuppCopy = unsupportedRulesBySource
        stateLock.unlock()

        setUpdateStatus(sourceId: sourceId, status: nil)
        saveMetadata(metaCopy)
        saveUnsupportedRules(unsuppCopy)
        applyRulesToAttachedWebViews()
        releaseSystemHeapPressure()
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

        return (try? NSRegularExpression(pattern: pattern)) != nil
    }

    private func isValidCssSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty,
              selector.count <= 2048,
              !selector.contains("\u{0000}"),
              !selector.contains("{"),
              !selector.contains("}"),
              !selector.contains("<"),
              !selector.contains(">style"),
              !selector.contains(":has(") else {
            return false
        }
        return true
    }

    private func parseSingleLine(_ rawLine: String) -> (networkRule: [String: Any]?, cosmeticRule: [String: Any]?, isJsFallback: Bool, isUnsupported: Bool) {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty,
              !line.hasPrefix("!"),
              !line.hasPrefix("！"),
              !line.hasPrefix("[") else {
            return (nil, nil, false, false)
        }

        if line.contains("##+js") || line.contains("#%#") {
            return (nil, nil, false, true)
        }

        if line.contains("#@#") {
            return (nil, nil, false, false)
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

            if selectorsText.contains(":has(") {
                return (nil, nil, true, false)
            }

            guard isValidCssSelector(selectorsText) else {
                return (nil, nil, false, true)
            }

            let parsedDomains = normalizedDomains(from: domainsText)

            var trigger: [String: Any] = [
                "url-filter": ".*"
            ]

            if !parsedDomains.include.isEmpty {
                trigger["if-domain"] = parsedDomains.include
            }
            if !parsedDomains.exclude.isEmpty {
                trigger["unless-domain"] = parsedDomains.exclude
            }

            let rule: [String: Any] = [
                "trigger": trigger,
                "action": [
                    "type": "css-display-none",
                    "selector": selectorsText
                ]
            ]

            return (nil, rule, false, false)
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
            return (nil, nil, false, true)
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
                    return (nil, nil, false, true)
                }
                let domains = normalizedDomains(from: domainStr, separator: "|")
                includeDomains.append(contentsOf: domains.include)
                excludeDomains.append(contentsOf: domains.exclude)
            } else if option.hasPrefix("denyallow=") {
                let domainStr = String(option.dropFirst(10))
                if domainStr.contains("/") {
                    return (nil, nil, false, true)
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
                }
            } else if option == "badfilter" || option.hasPrefix("removeparam") || option.hasPrefix("csp") {
                return (nil, nil, false, true)
            }
        }

        let filter: String
        if rawPattern.hasPrefix("/") && rawPattern.hasSuffix("/") && rawPattern.count > 2 {
            filter = String(rawPattern.dropFirst().dropLast())
        } else {
            filter = urlFilterPattern(from: rawPattern)
        }

        guard isValidWebKitPattern(filter) else {
            return (nil, nil, false, true)
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

        let rule: [String: Any] = [
            "trigger": trigger,
            "action": [
                "type": isException ? "ignore-previous-rules" : "block"
            ]
        ]

        return (rule, nil, false, false)
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

    func scanMemoryUsage(completion: @escaping (AdBlockMemoryReport) -> Void) {
        parseQueue.async { [weak self] in
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
            var scriptChars = 0
            for scripts in self.cosmeticScriptsBySource.values {
                scriptCount += scripts.count
                for script in scripts {
                    scriptChars += script.source.count
                }
            }
            self.stateLock.unlock()

            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())

            let docBytes = calculateDirectorySize(at: documentsURL)
            let cacheBytes = calculateDirectorySize(at: cachesURL)
            let tmpBytes = calculateDirectorySize(at: tmpURL)

            var largeFiles: [SandboxFileItem] = []
            if let files = try? FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.fileSizeKey]) {
                for fileURL in files {
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                       let size = attrs[.size] as? UInt64,
                       size > 102400 {
                        largeFiles.append(SandboxFileItem(name: fileURL.lastPathComponent, sizeBytes: size, path: fileURL.path))
                    }
                }
            }

            largeFiles.sort { $0.sizeBytes > $1.sizeBytes }

            let cacheMem = URLCache.shared.currentMemoryUsage
            let cacheDisk = URLCache.shared.currentDiskUsage

            DispatchQueue.main.async {
                WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { allIds in
                    let storeIds = allIds ?? []
                    let orphanIds = storeIds.filter { !activeIdentifiers.contains($0) }

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
                        documentsBytes: docBytes,
                        cachesBytes: cacheBytes,
                        tmpBytes: tmpBytes,
                        largeArtifacts: largeFiles,
                        urlCacheMemoryBytes: cacheMem,
                        urlCacheDiskBytes: cacheDisk
                    )

                    completion(report)
                }
            }
        }
    }

    private func cleanOrphanRuleLists() {
        parseQueue.async { [weak self] in
            guard let self = self else { return }

            self.stateLock.lock()
            var activeIdentifiers = Set<String>()
            for metadata in self.metadataBySource.values {
                activeIdentifiers.formUnion(metadata.ruleListIdentifiers)
            }
            let activeSourceIds = Set(self.loadSubscriptions().map(\.id) + [Self.customSourceId])
            self.stateLock.unlock()

            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for fileURL in files {
                    let name = fileURL.lastPathComponent
                    if name.hasPrefix("adblock_subscription_") && name.hasSuffix(".txt") {
                        let subId = name
                            .replacingOccurrences(of: "adblock_subscription_", with: "")
                            .replacingOccurrences(of: ".txt", with: "")
                        if !activeSourceIds.contains(subId) {
                            try? FileManager.default.removeItem(at: fileURL)
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { identifiers in
                    let list = identifiers ?? []
                    for identifier in list {
                        if !activeIdentifiers.contains(identifier) {
                            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier, completionHandler: { _ in })
                        }
                    }
                    releaseSystemHeapPressure()
                }
            }
        }
    }

    func cleanMemoryResidue(completion: ((AdBlockMemoryReport) -> Void)? = nil) {
        parseQueue.async { [weak self] in
            guard let self = self else { return }

            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let activeSourceIds = Set(self.loadSubscriptions().map(\.id) + [Self.customSourceId])

            if let files = try? FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil) {
                for fileURL in files {
                    let name = fileURL.lastPathComponent
                    if name.hasSuffix(".ipa") ||
                        name.hasSuffix(".zip") ||
                        name.hasSuffix(".log") {
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

            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            if let tmpFiles = try? FileManager.default.contentsOfDirectory(at: tmpURL, includingPropertiesForKeys: nil) {
                for fileURL in tmpFiles {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }

            DispatchQueue.main.async {
                WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { [weak self] identifiers in
                    guard let self = self else { return }
                    let list = identifiers ?? []
                    let group = DispatchGroup()

                    for identifier in list {
                        group.enter()
                        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in
                            group.leave()
                        }
                    }

                    group.notify(queue: .main) {
                        self.stateLock.lock()
                        self.compiledListsBySource.removeAll()
                        self.cosmeticScriptsBySource.removeAll()
                        self.metadataBySource.removeAll()
                        self.stateLock.unlock()

                        self.saveMetadata([:])
                        URLCache.shared.removeAllCachedResponses()
                        WebsiteCleaner.shared.cleanCacheOnly()
                        releaseSystemHeapPressure()

                        self.recompileAllActiveSubscriptions {
                            self.scanMemoryUsage { report in
                                completion?(report)
                            }
                        }
                    }
                }
            }
        }
    }

    private func recompileAllActiveSubscriptions(completion: @escaping () -> Void) {
        let subscriptions = loadSubscriptions().filter { $0.isEnabled }
        let group = DispatchGroup()

        for sub in subscriptions {
            group.enter()
            compileSource(id: sub.id) { _, _ in
                group.leave()
            }
        }

        let customRules = getCustomRules()
        if !customRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            group.enter()
            compileSource(id: Self.customSourceId) { _, _ in
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.applyRulesToAttachedWebViews()
            releaseSystemHeapPressure()
            completion()
        }
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
