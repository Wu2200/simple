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
    var metadataRuleCount: Int
    var diskStoreIdentifiers: [String]
    var orphanStoreIdentifiers: [String]
    var totalSandboxBytes: UInt64
    var documentsBytes: UInt64
    var webKitBytes: UInt64
    var cachesBytes: UInt64
    var appSupportBytes: UInt64
    var tmpBytes: UInt64
    var largeArtifacts: [SandboxFileItem]

    var physicalFootprintString: String {
        ByteCountFormatter.string(fromByteCount: Int64(physicalFootprintBytes), countStyle: .memory)
    }

    var residentSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(residentSizeBytes), countStyle: .memory)
    }

    var totalSandboxSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalSandboxBytes), countStyle: .file)
    }

    var documentsSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(documentsBytes), countStyle: .file)
    }

    var webKitSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(webKitBytes), countStyle: .file)
    }

    var cachesSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(cachesBytes), countStyle: .file)
    }

    var appSupportSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(appSupportBytes), countStyle: .file)
    }

    var tmpSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(tmpBytes), countStyle: .file)
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
    private let metadataKey = "adblock_compiled_metadata_v11"
    private let identifierPrefix = "SimpleBrowserAdBlockV11"
    private let diagnosticKey = "adblock_unsupported_rules_v1"

    private let targetChunkSize = 8000
    private let autoUpdateInterval: TimeInterval = 86400
    private let autoUpdateRetryCooldown: TimeInterval = 1800

    private var attachedWebViews = NSHashTable<WKWebView>.weakObjects()
    private var compiledListsBySource: [String: [WKContentRuleList]] = [:]
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
            "adblock_compiled_metadata_v10",
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
        stateLock.unlock()

        for sourceId in compiledListsCopy.keys.sorted() {
            if sourceId != Self.customSourceId && !enabledSubs.contains(sourceId) {
                continue
            }
            for ruleList in compiledListsCopy[sourceId] ?? [] {
                controller.add(ruleList)
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

            let (chunks, totalCount, skippedCount) = autoreleasepool {
                self.parseRulesAndChunk(text: text, sourceId: sourceId)
            }

            self.setUpdateStatus(
                sourceId: sourceId,
                status: "正在编译规则…"
            )

            self.compileChunksFaultTolerant(
                chunks: chunks,
                sourceId: sourceId,
                totalCount: totalCount,
                skippedCount: skippedCount,
                completion: completion
            )
        }
    }

    private func parseRulesAndChunk(
        text: String,
        sourceId: String
    ) -> (chunks: [[(raw: String, dict: [String: Any])]], totalCount: Int, skippedCount: Int) {
        var validRules: [(raw: String, dict: [String: Any])] = []
        var totalCount = 0
        var skippedCount = 0

        text.enumerateLines { line, _ in
            autoreleasepool {
                let parsedList = self.parseLineRules(line)
                if parsedList.isEmpty {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty &&
                        !trimmed.hasPrefix("!") &&
                        !trimmed.hasPrefix("！") &&
                        !trimmed.hasPrefix("[") {
                        skippedCount += 1
                    }
                } else {
                    for item in parsedList {
                        validRules.append(item)
                        totalCount += 1
                    }
                }
            }
        }

        var chunks: [[(raw: String, dict: [String: Any])]] = []
        if validRules.isEmpty {
            return (chunks, totalCount, skippedCount)
        }

        for i in stride(from: 0, to: validRules.count, by: targetChunkSize) {
            let end = min(i + targetChunkSize, validRules.count)
            chunks.append(Array(validRules[i..<end]))
        }

        return (chunks, totalCount, skippedCount)
    }

    private func compileChunksFaultTolerant(
        chunks: [[(raw: String, dict: [String: Any])]],
        sourceId: String,
        totalCount: Int,
        skippedCount: Int,
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
        var dynamicallySkipped = 0

        func processChunkIndex(_ chunkIndex: Int) {
            guard chunkIndex < chunks.count else {
                self.removeOldRuleLists(for: sourceId)

                let finalRuleCount = max(0, totalCount - dynamicallySkipped)
                let finalSkippedCount = skippedCount + dynamicallySkipped

                let metadata = AdBlockCompiledSourceMetadata(
                    sourceId: sourceId,
                    ruleListIdentifiers: compiledIdentifiers,
                    ruleCount: finalRuleCount,
                    skippedRuleCount: finalSkippedCount
                )

                self.stateLock.lock()
                self.metadataBySource[sourceId] = metadata
                self.compiledListsBySource[sourceId] = compiledLists
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

                    let unsupportedCount = self?.unsupportedRuleCount(sourceId: sourceId) ?? 0
                    let message: String?
                    if unsupportedCount > 0 {
                        message = "已更新，\(unsupportedCount) 条非标规则被过滤"
                    } else if finalSkippedCount > 0 {
                        message = "已更新，跳过 \(finalSkippedCount) 条不兼容规则"
                    } else {
                        message = nil
                    }
                    completion?(true, message)
                }
                return
            }

            self.setUpdateStatus(
                sourceId: sourceId,
                status: "正在编译规则 \(chunkIndex + 1)/\(chunks.count)…"
            )

            let chunkRules = chunks[chunkIndex]
            let identifier = "\(self.identifierPrefix).\(sourceId.replacingOccurrences(of: "-", with: "")).\(version).\(chunkIndex)"

            self.compileRuleSliceSafely(
                rules: chunkRules,
                identifier: identifier,
                sourceId: sourceId
            ) { ruleList, skippedInSlice in
                dynamicallySkipped += skippedInSlice
                if let ruleList = ruleList {
                    compiledLists.append(ruleList)
                    compiledIdentifiers.append(identifier)
                }
                processChunkIndex(chunkIndex + 1)
            }
        }

        processChunkIndex(0)
    }

    private func compileRuleSliceSafely(
        rules: [(raw: String, dict: [String: Any])],
        identifier: String,
        sourceId: String,
        completion: @escaping (WKContentRuleList?, Int) -> Void
    ) {
        guard !rules.isEmpty else {
            completion(nil, 0)
            return
        }

        guard let json = autoreleasepool(invoking: { self.jsonString(from: rules.map(\.dict)) }) else {
            completion(nil, rules.count)
            return
        }

        DispatchQueue.main.async {
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { [weak self] ruleList, error in
                guard let self = self else { return }

                if let ruleList = ruleList {
                    self.parseQueue.async {
                        completion(ruleList, 0)
                    }
                    return
                }

                self.isolateAndRecoverValidRules(
                    rules: rules,
                    sourceId: sourceId
                ) { recoveredRules, discardedCount in
                    guard !recoveredRules.isEmpty else {
                        self.parseQueue.async {
                            completion(nil, discardedCount)
                        }
                        return
                    }

                    guard let recoveredJson = self.jsonString(from: recoveredRules.map(\.dict)) else {
                        self.parseQueue.async {
                            completion(nil, discardedCount + recoveredRules.count)
                        }
                        return
                    }

                    DispatchQueue.main.async {
                        WKContentRuleListStore.default().compileContentRuleList(
                            forIdentifier: identifier,
                            encodedContentRuleList: recoveredJson
                        ) { finalRuleList, _ in
                            self.parseQueue.async {
                                completion(finalRuleList, discardedCount)
                            }
                        }
                    }
                }
            }
        }
    }

    private func isolateAndRecoverValidRules(
        rules: [(raw: String, dict: [String: Any])],
        sourceId: String,
        completion: @escaping ([(raw: String, dict: [String: Any])], Int) -> Void
    ) {
        func filterSlice(
            slice: [(raw: String, dict: [String: Any])],
            depth: Int,
            finish: @escaping ([(raw: String, dict: [String: Any])], Int) -> Void
        ) {
            guard !slice.isEmpty else {
                finish([], 0)
                return
            }

            if slice.count == 1 || depth >= 8 {
                for item in slice {
                    self.recordUnsupportedRule(
                        sourceId: sourceId,
                        rawRule: item.raw,
                        compiledRule: item.dict,
                        error: "WebKit 无法解析该规则语法"
                    )
                }
                finish([], slice.count)
                return
            }

            guard let json = self.jsonString(from: slice.map(\.dict)) else {
                finish([], slice.count)
                return
            }

            let tempId = "\(self.identifierPrefix).probe.\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            DispatchQueue.main.async {
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: tempId,
                    encodedContentRuleList: json
                ) { list, error in
                    if let _ = list {
                        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: tempId, completionHandler: { _ in })
                        self.parseQueue.async {
                            finish(slice, 0)
                        }
                    } else {
                        let mid = slice.count / 2
                        let left = Array(slice[0..<mid])
                        let right = Array(slice[mid..<slice.count])

                        self.parseQueue.async {
                            filterSlice(slice: left, depth: depth + 1) { leftValid, leftSkipped in
                                filterSlice(slice: right, depth: depth + 1) { rightValid, rightSkipped in
                                    finish(leftValid + rightValid, leftSkipped + rightSkipped)
                                }
                            }
                        }
                    }
                }
            }
        }

        parseQueue.async {
            filterSlice(slice: rules, depth: 0, finish: completion)
        }
    }

    private func deactivateSource(id sourceId: String) {
        removeOldRuleLists(for: sourceId)
        stateLock.lock()
        metadataBySource.removeValue(forKey: sourceId)
        compiledListsBySource.removeValue(forKey: sourceId)
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
              !pattern.contains("[:"),
              !pattern.contains("\\K") else {
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
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 2048,
              !trimmed.contains("\u{0000}"),
              !trimmed.contains("{"),
              !trimmed.contains("}"),
              !trimmed.contains("<"),
              !trimmed.contains(">style"),
              !trimmed.contains(":has("),
              !trimmed.contains(":has-text("),
              !trimmed.contains(":-abp-"),
              !trimmed.contains(":matches-css("),
              !trimmed.contains(":xpath("),
              !trimmed.contains("[-ext-") else {
            return false
        }

        var brackets = 0
        var parens = 0
        for char in trimmed {
            if char == "[" { brackets += 1 }
            else if char == "]" { brackets -= 1; if brackets < 0 { return false } }
            else if char == "(" { parens += 1 }
            else if char == ")" { parens -= 1; if parens < 0 { return false } }
        }
        if brackets != 0 || parens != 0 {
            return false
        }
        return true
    }

    private func parseLineRules(_ rawLine: String) -> [(raw: String, dict: [String: Any])] {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty,
              !line.hasPrefix("!"),
              !line.hasPrefix("！"),
              !line.hasPrefix("[") else {
            return []
        }

        if line.contains("##+js") || line.contains("#%#") || line.contains("##^") {
            return []
        }

        if line.contains("#@#") {
            return []
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
            let individualSelectors = splitSelectorList(selectorsText)

            var results: [(raw: String, dict: [String: Any])] = []

            for sel in individualSelectors {
                guard isValidCssSelector(sel) else { continue }

                var trigger: [String: Any] = [
                    "url-filter": ".*"
                ]

                if !parsedDomains.include.isEmpty {
                    trigger["if-domain"] = parsedDomains.include
                }
                if !parsedDomains.exclude.isEmpty {
                    trigger["unless-domain"] = parsedDomains.exclude
                }

                let ruleDict: [String: Any] = [
                    "trigger": trigger,
                    "action": [
                        "type": "css-display-none",
                        "selector": sel
                    ]
                ]

                results.append((raw: rawLine, dict: ruleDict))
            }

            return results
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
            return []
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
                    return []
                }
                let domains = normalizedDomains(from: domainStr, separator: "|")
                includeDomains.append(contentsOf: domains.include)
                excludeDomains.append(contentsOf: domains.exclude)
            } else if option.hasPrefix("denyallow=") {
                let domainStr = String(option.dropFirst(10))
                if domainStr.contains("/") {
                    return []
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
                return []
            }
        }

        let filter: String
        if rawPattern.hasPrefix("/") && rawPattern.hasSuffix("/") && rawPattern.count > 2 {
            filter = String(rawPattern.dropFirst().dropLast())
        } else {
            filter = urlFilterPattern(from: rawPattern)
        }

        guard isValidWebKitPattern(filter) else {
            return []
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

        return [(raw: rawLine, dict: rule)]
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
        rawRule: String,
        compiledRule: [String: Any],
        error: String
    ) {
        stateLock.lock()
        var items = unsupportedRulesBySource[sourceId] ?? []

        if items.count < 100 && !items.contains(where: { $0.rawRule == rawRule }) {
            let compiledJSON = jsonString(from: [compiledRule]) ?? ""
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
            self.stateLock.unlock()

            let homeURL = URL(fileURLWithPath: NSHomeDirectory())
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let webKitURL = libraryURL.appendingPathComponent("WebKit")
            let appSupportURL = libraryURL.appendingPathComponent("Application Support")
            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())

            let totalSandboxBytes = calculateDirectorySize(at: homeURL)
            let docBytes = calculateDirectorySize(at: documentsURL)
            let cacheBytes = calculateDirectorySize(at: cachesURL)
            let webKitBytes = calculateDirectorySize(at: webKitURL)
            let appSupportBytes = calculateDirectorySize(at: appSupportURL)
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

            DispatchQueue.main.async {
                WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { allIds in
                    let storeIds = allIds ?? []
                    let orphanIds = storeIds.filter { !activeIdentifiers.contains($0) }

                    let report = AdBlockMemoryReport(
                        physicalFootprintBytes: memory.footprint,
                        residentSizeBytes: memory.resident,
                        activeSubscriptionCount: self.loadSubscriptions().count,
                        inMemoryRuleListCount: inMemoryRuleCount,
                        metadataRuleCount: metadataRuleCount,
                        diskStoreIdentifiers: storeIds,
                        orphanStoreIdentifiers: orphanIds,
                        totalSandboxBytes: totalSandboxBytes,
                        documentsBytes: docBytes,
                        webKitBytes: webKitBytes,
                        cachesBytes: cacheBytes,
                        appSupportBytes: appSupportBytes,
                        tmpBytes: tmpBytes,
                        largeArtifacts: largeFiles
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

    private func purgeDiskArtifacts() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let activeSourceIds = Set(loadSubscriptions().map(\.id) + [Self.customSourceId])

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

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
        if let tmpFiles = try? FileManager.default.contentsOfDirectory(at: tmpURL, includingPropertiesForKeys: nil) {
            for fileURL in tmpFiles {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func cleanMemoryResidue(completion: ((AdBlockMemoryReport) -> Void)? = nil) {
        parseQueue.async { [weak self] () -> Void in
            guard let self = self else { return }
            self.purgeDiskArtifacts()

            DispatchQueue.main.async {
                WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { (identifiers: [String]?) in
                    let list: [String] = identifiers ?? []
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
                        self.metadataBySource.removeAll()
                        self.stateLock.unlock()

                        self.saveMetadata([:])

                        WebsiteCleaner.shared.cleanCacheOnly {
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
