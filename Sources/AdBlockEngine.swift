import Foundation
import WebKit

struct AdBlockSubscription: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var url: String
    var isEnabled: Bool
    var rulesCount: Int
    var lastUpdated: Date?
    var chunkCount: Int

    init(id: UUID = UUID(), name: String, url: String, isEnabled: Bool = true, rulesCount: Int = 0, lastUpdated: Date? = nil, chunkCount: Int = 0) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.rulesCount = rulesCount
        self.lastUpdated = lastUpdated
        self.chunkCount = chunkCount
    }
}

struct IncompatibleRuleRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var originalRule: String
    var reason: String

    init(id: UUID = UUID(), originalRule: String, reason: String) {
        self.id = id
        self.originalRule = originalRule
        self.reason = reason
    }
}

final class AdBlockEngine: NSObject {
    static let shared = AdBlockEngine()

    private(set) var subscriptions: [AdBlockSubscription] = []
    private(set) var incompatibleRules: [IncompatibleRuleRecord] = []
    private(set) var isCompiling: Bool = false

    var onProgressUpdate: ((String, Int, Int) -> Void)?
    var onSubscriptionsChanged: (() -> Void)?
    var onIncompatibleRulesChanged: (() -> Void)?

    private override init() {
        super.init()
        loadSubscriptions()
        loadIncompatibleRules()
        if subscriptions.isEmpty {
            purgeAllDiskStorage()
        } else {
            purgeOrphanedStorage()
        }
    }

    private func getBaseDirectory() -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("AdBlock", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func loadSubscriptions() {
        let file = getBaseDirectory().appendingPathComponent("subscriptions.json")
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([AdBlockSubscription].self, from: data) else {
            subscriptions = []
            return
        }
        subscriptions = list
    }

    func saveSubscriptions() {
        let file = getBaseDirectory().appendingPathComponent("subscriptions.json")
        if let data = try? JSONEncoder().encode(subscriptions) {
            try? data.write(to: file)
        }
    }

    private func loadIncompatibleRules() {
        let file = getBaseDirectory().appendingPathComponent("incompatible.json")
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([IncompatibleRuleRecord].self, from: data) else {
            incompatibleRules = []
            return
        }
        incompatibleRules = list
    }

    func saveIncompatibleRules() {
        let file = getBaseDirectory().appendingPathComponent("incompatible.json")
        if let data = try? JSONEncoder().encode(incompatibleRules) {
            try? data.write(to: file)
        }
    }

    func addSubscription(name: String, url: String, completion: (() -> Void)? = nil) {
        let sub = AdBlockSubscription(name: name, url: url)
        subscriptions.append(sub)
        saveSubscriptions()
        onSubscriptionsChanged?()
        completion?()
    }

    func deleteSubscription(at index: Int, completion: (() -> Void)? = nil) {
        guard subscriptions.indices.contains(index) else {
            completion?()
            return
        }
        let sub = subscriptions.remove(at: index)
        saveSubscriptions()
        onSubscriptionsChanged?()
        removeSubscriptionChunks(sub) { [weak self] in
            guard let self = self else {
                completion?()
                return
            }
            if self.subscriptions.isEmpty {
                self.incompatibleRules.removeAll()
                self.saveIncompatibleRules()
                self.onIncompatibleRulesChanged?()
                self.purgeAllDiskStorage(completion: completion)
            } else {
                self.purgeOrphanedStorage(completion: completion)
            }
        }
    }

    func deleteSubscription(id: UUID, completion: (() -> Void)? = nil) {
        if let index = subscriptions.firstIndex(where: { $0.id == id }) {
            deleteSubscription(at: index, completion: completion)
        } else {
            completion?()
        }
    }

    func removeSubscription(_ subscription: AdBlockSubscription, completion: (() -> Void)? = nil) {
        deleteSubscription(id: subscription.id, completion: completion)
    }

    func deleteAllSubscriptions(completion: (() -> Void)? = nil) {
        subscriptions.removeAll()
        incompatibleRules.removeAll()
        saveSubscriptions()
        saveIncompatibleRules()
        onSubscriptionsChanged?()
        onIncompatibleRulesChanged?()
        purgeAllDiskStorage(completion: completion)
    }

    func clearAllRuleStorage(completion: (() -> Void)? = nil) {
        deleteAllSubscriptions(completion: completion)
    }

    private func removeSubscriptionChunks(_ subscription: AdBlockSubscription, completion: @escaping () -> Void) {
        let store = WKContentRuleListStore.default()
        let prefix = "simple_ab_\(subscription.id.uuidString)_"
        store.getAvailableContentRuleListIdentifiers { allIds in
            guard let allIds = allIds else {
                completion()
                return
            }
            let targets = allIds.filter { $0.hasPrefix(prefix) }
            if targets.isEmpty {
                completion()
                return
            }
            let group = DispatchGroup()
            for id in targets {
                group.enter()
                store.removeContentRuleList(forIdentifier: id) { _ in
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                completion()
            }
        }
    }

    func purgeOrphanedStorage(completion: (() -> Void)? = nil) {
        var validIdentifiers = Set<String>()
        for sub in subscriptions {
            for i in 0..<sub.chunkCount {
                validIdentifiers.insert("simple_ab_\(sub.id.uuidString)_\(i)")
            }
        }
        let store = WKContentRuleListStore.default()
        store.getAvailableContentRuleListIdentifiers { [weak self] allIds in
            guard let allIds = allIds else {
                completion?()
                return
            }
            let group = DispatchGroup()
            for id in allIds where id.hasPrefix("simple_ab_") {
                if !validIdentifiers.contains(id) {
                    group.enter()
                    store.removeContentRuleList(forIdentifier: id) { _ in
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) {
                self?.cleanCacheFiles()
                completion?()
            }
        }
    }

    func purgeAllDiskStorage(completion: (() -> Void)? = nil) {
        let store = WKContentRuleListStore.default()
        store.getAvailableContentRuleListIdentifiers { [weak self] allIds in
            let group = DispatchGroup()
            if let allIds = allIds {
                for id in allIds {
                    group.enter()
                    store.removeContentRuleList(forIdentifier: id) { _ in
                        group.leave()
                    }
                }
            }
            group.notify(queue: .global(qos: .utility)) {
                self?.deepCleanDirectories()
                DispatchQueue.main.async {
                    completion?()
                }
            }
        }
    }

    private func cleanCacheFiles() {
        let fileManager = FileManager.default
        if let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let adblockCache = cachesURL.appendingPathComponent("AdBlockCache")
            try? fileManager.removeItem(at: adblockCache)
        }
    }

    private func deepCleanDirectories() {
        let fileManager = FileManager.default
        if let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            if let enumerator = fileManager.enumerator(at: libraryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                var targets: [URL] = []
                for case let url as URL in enumerator {
                    if url.lastPathComponent == "ContentRuleLists" {
                        targets.append(url)
                    }
                }
                for url in targets {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
        if let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let adblockCache = cachesURL.appendingPathComponent("AdBlockCache")
            try? fileManager.removeItem(at: adblockCache)
        }
        let cacheDir = getBaseDirectory().appendingPathComponent("Cache")
        try? fileManager.removeItem(at: cacheDir)
    }

    func updateSubscription(_ subscription: AdBlockSubscription, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: subscription.url) else {
            completion(false)
            return
        }
        isCompiling = true
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil, let text = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async {
                    self?.isCompiling = false
                    completion(false)
                }
                return
            }
            self.compileSubscription(subscription, rawText: text) { success in
                DispatchQueue.main.async {
                    self.isCompiling = false
                    completion(success)
                }
            }
        }
        task.resume()
    }

    func updateAllSubscriptions(completion: @escaping () -> Void) {
        let items = subscriptions
        guard !items.isEmpty else {
            completion()
            return
        }
        var index = 0
        func next() {
            if index >= items.count {
                completion()
                return
            }
            let item = items[index]
            index += 1
            updateSubscription(item) { _ in
                next()
            }
        }
        next()
    }

    func compileSubscription(_ subscription: AdBlockSubscription, rawText: String, completion: @escaping (Bool) -> Void) {
        let lines = rawText.components(separatedBy: .newlines)
        var parsedRules: [[String: Any]] = []
        var detectedIncompatible: [IncompatibleRuleRecord] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("!") || trimmed.hasPrefix("[") {
                continue
            }
            if let ruleDict = convertLineToRule(trimmed) {
                parsedRules.append(ruleDict)
            } else {
                if detectedIncompatible.count < 300 {
                    detectedIncompatible.append(IncompatibleRuleRecord(originalRule: trimmed, reason: "语法暂不支持"))
                }
            }
        }

        DispatchQueue.main.async {
            self.incompatibleRules = detectedIncompatible
            self.saveIncompatibleRules()
            self.onIncompatibleRulesChanged?()
        }

        let chunkSize = 8000
        var chunks: [[[String: Any]]] = []
        var currentChunk: [[String: Any]] = []

        for rule in parsedRules {
            currentChunk.append(rule)
            if currentChunk.count >= chunkSize {
                chunks.append(currentChunk)
                currentChunk = []
            }
        }
        if !currentChunk.isEmpty || chunks.isEmpty {
            chunks.append(currentChunk)
        }

        let totalChunks = chunks.count
        var compiledChunks = 0
        let store = WKContentRuleListStore.default()

        func compileNext(chunkIndex: Int) {
            if chunkIndex >= totalChunks {
                DispatchQueue.main.async {
                    if let idx = self.subscriptions.firstIndex(where: { $0.id == subscription.id }) {
                        self.subscriptions[idx].rulesCount = parsedRules.count
                        self.subscriptions[idx].lastUpdated = Date()
                        self.subscriptions[idx].chunkCount = totalChunks
                        self.saveSubscriptions()
                        self.onSubscriptionsChanged?()
                    }
                    self.purgeOrphanedStorage {
                        completion(true)
                    }
                }
                return
            }

            DispatchQueue.main.async {
                self.onProgressUpdate?(subscription.name, chunkIndex + 1, totalChunks)
            }

            let chunkData = chunks[chunkIndex]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: chunkData, options: []),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                completion(false)
                return
            }

            let chunkId = "simple_ab_\(subscription.id.uuidString)_\(chunkIndex)"
            store.compileContentRuleList(forIdentifier: chunkId, encodedContentRuleList: jsonString) { _, error in
                if error != nil {
                    DispatchQueue.main.async {
                        completion(false)
                    }
                    return
                }
                compiledChunks += 1
                compileNext(chunkIndex: chunkIndex + 1)
            }
        }

        compileNext(chunkIndex: 0)
    }

    private func convertLineToRule(_ line: String) -> [String: Any]? {
        if line.contains("##") {
            let parts = line.components(separatedBy: "##")
            guard parts.count == 2 else { return nil }
            let domainPart = parts[0].trimmingCharacters(in: .whitespaces)
            let selector = parts[1].trimmingCharacters(in: .whitespaces)
            guard !selector.isEmpty else { return nil }
            var trigger: [String: Any] = ["url-filter": ".*"]
            if !domainPart.isEmpty {
                let domains = domainPart.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let positiveDomains = domains.filter { !$0.hasPrefix("~") }
                let negativeDomains = domains.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) }
                if !positiveDomains.isEmpty {
                    trigger["if-domain"] = positiveDomains
                } else if !negativeDomains.isEmpty {
                    trigger["unless-domain"] = negativeDomains
                }
            }
            return [
                "action": ["type": "css-display-none", "selector": selector],
                "trigger": trigger
            ]
        }

        var isWhitelist = false
        var ruleBody = line
        if ruleBody.hasPrefix("@@") {
            isWhitelist = true
            ruleBody = String(ruleBody.dropFirst(2))
        }

        var options: [String] = []
        if let optIndex = ruleBody.firstIndex(of: "$") {
            let optString = String(ruleBody[ruleBody.index(after: optIndex)...])
            options = optString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            ruleBody = String(ruleBody[..<optIndex])
        }

        var urlFilter = ""
        if ruleBody.hasPrefix("||") {
            var domain = String(ruleBody.dropFirst(2))
            if domain.hasSuffix("^") {
                domain = String(domain.dropLast())
            }
            let escapedDomain = NSRegularExpression.escapedPattern(for: domain)
            urlFilter = "^[htpsw]+:\\/\\/([a-z0-9-]+\\.)?" + escapedDomain + "([\\/:&\\?].*)?$"
        } else if ruleBody.hasPrefix("|") && ruleBody.hasSuffix("|") {
            let raw = String(ruleBody.dropFirst().dropLast())
            urlFilter = "^" + NSRegularExpression.escapedPattern(for: raw) + "$"
        } else if ruleBody.hasPrefix("|") {
            let raw = String(ruleBody.dropFirst())
            urlFilter = "^" + NSRegularExpression.escapedPattern(for: raw)
        } else if ruleBody.hasSuffix("|") {
            let raw = String(ruleBody.dropLast())
            urlFilter = NSRegularExpression.escapedPattern(for: raw) + "$"
        } else {
            let cleaned = ruleBody.replacingOccurrences(of: "^", with: "")
            urlFilter = NSRegularExpression.escapedPattern(for: cleaned)
        }

        guard !urlFilter.isEmpty else { return nil }

        var trigger: [String: Any] = [
            "url-filter": urlFilter,
            "url-filter-is-case-sensitive": false
        ]

        var resourceTypes: [String] = []
        for opt in options {
            if opt.hasPrefix("domain=") {
                let domStr = String(opt.dropFirst(7))
                let domList = domStr.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let positive = domList.filter { !$0.hasPrefix("~") }
                let negative = domList.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) }
                if !positive.isEmpty {
                    trigger["if-domain"] = positive
                } else if !negative.isEmpty {
                    trigger["unless-domain"] = negative
                }
            } else if opt == "third-party" || opt == "3p" {
                trigger["load-type"] = ["third-party"]
            } else if opt == "~third-party" || opt == "~3p" {
                trigger["load-type"] = ["first-party"]
            } else if opt == "script" {
                resourceTypes.append("script")
            } else if opt == "image" {
                resourceTypes.append("image")
            } else if opt == "stylesheet" || opt == "css" {
                resourceTypes.append("style-sheet")
            } else if opt == "xmlhttprequest" || opt == "xhr" {
                resourceTypes.append("raw")
            } else if opt == "media" {
                resourceTypes.append("media")
            } else if opt == "subdocument" {
                resourceTypes.append("document")
            } else if opt == "font" {
                resourceTypes.append("font")
            }
        }

        if !resourceTypes.isEmpty {
            trigger["resource-type"] = resourceTypes
        }

        let actionType = isWhitelist ? "ignore-previous-rules" : "block"
        return [
            "action": ["type": actionType],
            "trigger": trigger
        ]
    }

    func applyRules(to userContentController: WKUserContentController, completion: (() -> Void)? = nil) {
        userContentController.removeAllContentRuleLists()
        let enabledList = subscriptions.filter { $0.isEnabled }
        if enabledList.isEmpty {
            completion?()
            return
        }
        let store = WKContentRuleListStore.default()
        let group = DispatchGroup()
        for sub in enabledList {
            for i in 0..<sub.chunkCount {
                let chunkId = "simple_ab_\(sub.id.uuidString)_\(i)"
                group.enter()
                store.lookUpContentRuleList(forIdentifier: chunkId) { ruleList, _ in
                    if let ruleList = ruleList {
                        DispatchQueue.main.async {
                            userContentController.add(ruleList)
                        }
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            completion?()
        }
    }

    func removeAllRules(from userContentController: WKUserContentController) {
        userContentController.removeAllContentRuleLists()
    }
}
