//
//  Models.swift
//  SimpleBrowser
//

import Foundation
import UIKit
import WebKit

// MARK: - 自定义轻触反馈按钮
open class TouchButton: UIButton {
    public var hitTestInsets = UIEdgeInsets.zero

    open override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if hitTestInsets == .zero {
            return super.point(inside: point, with: event)
        }
        let hitFrame = bounds.inset(by: hitTestInsets)
        return hitFrame.contains(point)
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

// MARK: - 书签模型（支持多级目录树）
public struct BookmarkItem: Codable, Equatable {
    public let id: String
    public var title: String
    public var url: String
    public var parentId: String?
    public var isFolder: Bool
    public var createdAt: Date

    public var urlString: String {
        return url
    }

    public init(id: String = UUID().uuidString, title: String, url: String = "", parentId: String? = nil, isFolder: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.parentId = parentId
        self.isFolder = isFolder
        self.createdAt = createdAt
    }
}

// MARK: - 书签持久化管理器
public final class BookmarkStore {
    public static let shared = BookmarkStore()
    private let key = "SimpleBrowserBookmarksTree_V2"

    public private(set) var bookmarks: [BookmarkItem] = []

    private init() {
        loadBookmarks()
        if bookmarks.isEmpty {
            createDefaultBookmarks()
        }
    }

    private func createDefaultBookmarks() {
        let defaults: [(String, String)] = [
            ("GitHub", "https://github.com"),
            ("Google", "https://www.google.com"),
            ("哔哩哔哩", "https://www.bilibili.com"),
            ("Bing 搜索", "https://cn.bing.com"),
            ("V2EX", "https://www.v2ex.com")
        ]
        for (t, u) in defaults {
            bookmarks.append(BookmarkItem(title: t, url: u, parentId: nil, isFolder: false))
        }
        saveBookmarks()
    }

    public func getItems(in parentId: String?) -> [BookmarkItem] {
        return bookmarks.filter { $0.parentId == parentId }.sorted { (b1, b2) in
            if b1.isFolder != b2.isFolder {
                return b1.isFolder && !b2.isFolder
            }
            return b1.createdAt > b2.createdAt
        }
    }

    public func getNodes(inParent parentId: String?) -> [BookmarkItem] {
        return getItems(in: parentId)
    }

    public func loadAllNodes() -> [BookmarkItem] {
        return bookmarks
    }

    public func getAllFolders() -> [BookmarkItem] {
        return bookmarks.filter { $0.isFolder }
    }

    public func addBookmark(title: String, url: String, parentId: String? = nil) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "网页书签" : title
        let item = BookmarkItem(title: cleanTitle, url: url, parentId: parentId, isFolder: false)
        bookmarks.append(item)
        saveBookmarks()

        if let host = URL(string: url)?.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }
    }

    public func addBookmark(title: String, urlString: String, parentId: String? = nil) {
        addBookmark(title: title, url: urlString, parentId: parentId)
    }

    @discardableResult
    public func createFolder(title: String, parentId: String? = nil) -> BookmarkItem {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新建文件夹" : title
        let item = BookmarkItem(title: cleanTitle, url: "", parentId: parentId, isFolder: true)
        bookmarks.append(item)
        saveBookmarks()
        return item
    }

    public func updateItem(id: String, title: String, url: String) {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[idx].title = title
        if !bookmarks[idx].isFolder {
            bookmarks[idx].url = url
            if let host = URL(string: url)?.host {
                FaviconLoader.shared.preloadFavicon(for: host)
            }
        }
        saveBookmarks()
    }

    public func updateNode(id: String, title: String, urlString: String?) {
        updateItem(id: id, title: title, url: urlString ?? "")
    }

    public func deleteItem(id: String) {
        var idsToDelete = Set<String>([id])
        var queue = [id]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let children = bookmarks.filter { $0.parentId == current }.map { $0.id }
            idsToDelete.formUnion(children)
            queue.append(contentsOf: children)
        }
        bookmarks.removeAll { idsToDelete.contains($0.id) }
        saveBookmarks()
    }

    public func deleteNode(id: String) {
        deleteItem(id: id)
    }

    public func clearBookmarks() {
        bookmarks.removeAll()
        saveBookmarks()
    }

    public func countChildren(of folderId: String) -> Int {
        return bookmarks.filter { $0.parentId == folderId }.count
    }

    public func exportToAlookHTML() -> String {
        var html = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n"
        html += "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n"
        html += "<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n"

        func buildDL(parentId: String?) -> String {
            var sub = ""
            let items = getItems(in: parentId)
            for item in items {
                if item.isFolder {
                    sub += "    <DT><H3>\(item.title)</H3>\n    <DL><p>\n"
                    sub += buildDL(parentId: item.id)
                    sub += "    </DL><p>\n"
                } else {
                    sub += "    <DT><A HREF=\"\(item.url)\">\(item.title)</A>\n"
                }
            }
            return sub
        }

        html += buildDL(parentId: nil)
        html += "</DL><p>\n"
        return html
    }

    public func importFromAlookHTML(_ html: String) -> Int {
        let lines = html.components(separatedBy: .newlines)
        var count = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("<A HREF=") {
                if let hrefRange = trimmed.range(of: "HREF=\""),
                   let endHref = trimmed[hrefRange.upperBound...].range(of: "\"") {
                    let urlStr = String(trimmed[hrefRange.upperBound..<endHref.lowerBound])
                    var titleStr = "书签"
                    if let closeA = trimmed.range(of: "\">"),
                       let endA = trimmed.range(of: "</A>") {
                        titleStr = String(trimmed[closeA.upperBound..<endA.lowerBound])
                    }
                    if !urlStr.isEmpty {
                        addBookmark(title: titleStr, url: urlStr, parentId: nil)
                        count += 1
                    }
                }
            }
        }
        return count
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadBookmarks() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([BookmarkItem].self, from: data) {
            bookmarks = list
        }
    }
}

// MARK: - 主页常用站点快捷方式存储
public struct HomeShortcutItem: Codable, Equatable {
    public let id: String
    public var title: String
    public var url: String
    public var iconColorHex: String

    public init(id: String = UUID().uuidString, title: String, url: String, iconColorHex: String = "#007AFF") {
        self.id = id
        self.title = title
        self.url = url
        self.iconColorHex = iconColorHex
    }
}

public final class HomeShortcutStore {
    public static let shared = HomeShortcutStore()
    private let key = "SimpleBrowserHomeShortcuts_V2"

    public private(set) var shortcuts: [HomeShortcutItem] = []

    private init() {
        loadShortcuts()
        if shortcuts.isEmpty {
            createDefaultShortcuts()
        }
    }

    private func createDefaultShortcuts() {
        shortcuts = [
            HomeShortcutItem(title: "百度", url: "https://www.baidu.com", iconColorHex: "#2932E1"),
            HomeShortcutItem(title: "必应", url: "https://cn.bing.com", iconColorHex: "#008080"),
            HomeShortcutItem(title: "GitHub", url: "https://github.com", iconColorHex: "#24292E"),
            HomeShortcutItem(title: "哔哩哔哩", url: "https://www.bilibili.com", iconColorHex: "#FB7299"),
            HomeShortcutItem(title: "知乎", url: "https://www.zhihu.com", iconColorHex: "#0066FF"),
            HomeShortcutItem(title: "掘金", url: "https://juejin.cn", iconColorHex: "#1E80FF"),
            HomeShortcutItem(title: "维基百科", url: "https://zh.wikipedia.org", iconColorHex: "#636466"),
            HomeShortcutItem(title: "V2EX", url: "https://www.v2ex.com", iconColorHex: "#333333")
        ]
        saveShortcuts()
    }

    public func addShortcut(title: String, url: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "常用站点" : title
        let item = HomeShortcutItem(title: cleanTitle, url: url)
        shortcuts.append(item)
        saveShortcuts()

        if let host = URL(string: url)?.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }
    }

    public func updateShortcut(id: String, title: String, url: String) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        shortcuts[index].title = title
        shortcuts[index].url = url
        saveShortcuts()

        if let host = URL(string: url)?.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }
    }

    public func deleteShortcut(id: String) {
        shortcuts.removeAll { $0.id == id }
        saveShortcuts()
    }

    private func saveShortcuts() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadShortcuts() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([HomeShortcutItem].self, from: data) {
            shortcuts = list
        }
    }
}

// MARK: - 浏览器历史记录
public struct HistoryItem: Codable, Equatable {
    public let id: String
    public let title: String
    public let url: String
    public let timestamp: Date

    public var urlString: String { url }
    public var visitedAt: Date { timestamp }

    public init(id: String = UUID().uuidString, title: String, url: String, timestamp: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.timestamp = timestamp
    }
}

public typealias BrowserHistoryItem = HistoryItem

public final class BrowserHistoryStore {
    public static let shared = BrowserHistoryStore()
    private let key = "SimpleBrowserHistoryList"
    public private(set) var history: [HistoryItem] = []

    private init() {
        loadHistoryData()
    }

    public func record(title: String, url: String) {
        guard !url.isEmpty, !url.starts(with: "about:") else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url : title
        history.removeAll { $0.url == url }
        let item = HistoryItem(title: cleanTitle, url: url, timestamp: Date())
        history.insert(item, at: 0)
        if history.count > 1000 {
            history = Array(history.prefix(1000))
        }
        saveHistory()

        if let host = URL(string: url)?.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }
    }

    public func loadHistory() -> [HistoryItem] {
        return history
    }

    public func clearAll() {
        history.removeAll()
        saveHistory()
    }

    public func clearHistory() {
        clearAll()
    }

    public func deleteItem(id: String) {
        history.removeAll { $0.id == id }
        saveHistory()
    }

    public func delete(id: String) {
        deleteItem(id: id)
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadHistoryData() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = list
        }
    }
}

// MARK: - 搜索历史记录
public final class SearchHistoryStore {
    public static let shared = SearchHistoryStore()
    private let key = "SimpleBrowserSearchKeywords"
    public private(set) var history: [String] = []

    private init() {
        history = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    public func addHistory(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.removeAll { $0 == trimmed }
        history.insert(trimmed, at: 0)
        if history.count > 50 {
            history = Array(history.prefix(50))
        }
        UserDefaults.standard.set(history, forKey: key)
    }

    public func clearAll() {
        history.removeAll()
        UserDefaults.standard.set(history, forKey: key)
    }
}

// MARK: - 网站 Logo 本地预加载与磁盘缓存
public final class FaviconLoader {
    public static let shared = FaviconLoader()
    private let memCache = NSCache<NSString, UIImage>()
    private let diskQueue = DispatchQueue(label: "com.browser.faviconQueue", qos: .utility)

    private var diskPath: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let folder = dir.appendingPathComponent("Favicons", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    private init() {
        memCache.countLimit = 200
    }

    public func cachedFavicon(for host: String) -> UIImage? {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return nil }
        if let img = memCache.object(forKey: clean as NSString) {
            return img
        }
        let fileURL = diskPath.appendingPathComponent("\(clean.hashValue).png")
        if FileManager.default.fileExists(atPath: fileURL.path),
           let img = UIImage(contentsOfFile: fileURL.path) {
            memCache.setObject(img, forKey: clean as NSString)
            return img
        }
        return nil
    }

    public func preloadFavicon(for host: String) {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return }

        if memCache.object(forKey: clean as NSString) != nil { return }

        let fileURL = diskPath.appendingPathComponent("\(clean.hashValue).png")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let img = UIImage(contentsOfFile: fileURL.path) {
                memCache.setObject(img, forKey: clean as NSString)
                return
            }
        }

        diskQueue.async {
            guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(clean)&sz=64") else { return }
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                try? data.write(to: fileURL)
                self.memCache.setObject(img, forKey: clean as NSString)
            }
        }
    }

    public func loadFavicon(for host: String, completion: @escaping (UIImage?) -> Void) {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else {
            completion(nil)
            return
        }

        if let cached = memCache.object(forKey: clean as NSString) {
            completion(cached)
            return
        }

        let fileURL = diskPath.appendingPathComponent("\(clean.hashValue).png")
        diskQueue.async {
            if FileManager.default.fileExists(atPath: fileURL.path),
               let img = UIImage(contentsOfFile: fileURL.path) {
                self.memCache.setObject(img, forKey: clean as NSString)
                DispatchQueue.main.async { completion(img) }
                return
            }

            guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(clean)&sz=64") else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                try? data.write(to: fileURL)
                self.memCache.setObject(img, forKey: clean as NSString)
                DispatchQueue.main.async { completion(img) }
            } else {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}

// MARK: - 网站数据清除操作类型
public enum CleanOption: Int, CaseIterable {
    case cache = 0
    case searchHistory = 1
    case loginAndData = 2
    case scriptData = 3
}

public enum CleanDataType: String, CaseIterable {
    case cache = "网页缓存文件"
    case history = "搜索与浏览历史记录"
    case loginAndData = "登录与本地数据"
    case scriptData = "用户脚本缓存数据"
}

// MARK: - 网站数据原子清除引擎
public final class WebsiteCleaner {
    public static let shared = WebsiteCleaner()
    private init() {}

    public static func clean(options: Set<CleanDataType>, completion: @escaping () -> Void) {
        shared.clean(options: options, completion: completion)
    }

    public func clean(options: Set<CleanDataType>, completion: @escaping () -> Void) {
        var dataTypesToRemove = Set<String>()

        if options.contains(.cache) {
            dataTypesToRemove.insert(WKWebsiteDataTypeDiskCache)
            dataTypesToRemove.insert(WKWebsiteDataTypeMemoryCache)
            URLCache.shared.removeAllCachedResponses()
        }

        if options.contains(.history) {
            BrowserHistoryStore.shared.clearAll()
            SearchHistoryStore.shared.clearAll()
        }

        if options.contains(.loginAndData) {
            dataTypesToRemove.insert(WKWebsiteDataTypeCookies)
            dataTypesToRemove.insert(WKWebsiteDataTypeLocalStorage)
            dataTypesToRemove.insert(WKWebsiteDataTypeIndexedDBDatabases)
            dataTypesToRemove.insert(WKWebsiteDataTypeWebSQLDatabases)
            dataTypesToRemove.insert(WKWebsiteDataTypeSessionStorage)
        }

        if options.contains(.scriptData) {
            let defaults = UserDefaults.standard
            let dict = defaults.dictionaryRepresentation()
            for key in dict.keys where key.hasPrefix("GM_DATA_") {
                defaults.removeObject(forKey: key)
            }
        }

        if !dataTypesToRemove.isEmpty {
            let store = WKWebsiteDataStore.default()
            store.fetchDataRecords(ofTypes: dataTypesToRemove) { records in
                let targetRecords = records.filter { !CookieLockStore.shared.isLocked(host: $0.displayName) }
                if targetRecords.isEmpty {
                    completion()
                    return
                }
                store.removeData(ofTypes: dataTypesToRemove, for: targetRecords) {
                    completion()
                }
            }
        } else {
            completion()
        }
    }

    public func cleanUnprotectedLoginAndData(completion: @escaping () -> Void) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: types) { records in
            let unprotected = records.filter { !CookieLockStore.shared.isLocked(host: $0.displayName) }
            if unprotected.isEmpty {
                completion()
                return
            }
            store.removeData(ofTypes: types, for: unprotected) {
                completion()
            }
        }
    }

    public func cleanSingleDomain(record: WKWebsiteDataRecord, cacheOnly: Bool, completion: @escaping () -> Void) {
        let types = cacheOnly ? Set([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]) : record.dataTypes
        WKWebsiteDataStore.default().removeData(ofTypes: types, for: [record]) {
            completion()
        }
    }
}

// MARK: - 域名独立加锁持久化管理器
public final class CookieLockStore {
    public static let shared = CookieLockStore()
    private let key = "LockedWebsiteDomainsList"

    private var lockedHosts: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: key) ?? []
            return Set(arr.map { $0.lowercased() })
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: key)
        }
    }

    private init() {}

    public func isLocked(host: String) -> Bool {
        let clean = host.lowercased()
        return lockedHosts.contains(clean)
    }

    public func isLocked(domain: String) -> Bool {
        return isLocked(host: domain)
    }

    public func toggleLock(host: String) -> Bool {
        var set = lockedHosts
        let clean = host.lowercased()
        let result: Bool
        if set.contains(clean) {
            set.remove(clean)
            result = false
        } else {
            set.insert(clean)
            result = true
        }
        lockedHosts = set
        return result
    }

    public func toggleLock(domain: String) -> Bool {
        return toggleLock(host: domain)
    }

    public func lock(host: String) {
        var set = lockedHosts
        set.insert(host.lowercased())
        lockedHosts = set
    }

    public func unlock(host: String) {
        var set = lockedHosts
        set.remove(host.lowercased())
        lockedHosts = set
    }
}

// MARK: - 域名自定义设置管理
public final class DomainSettingsStore {
    public static let shared = DomainSettingsStore()
    private let keyPrefix = "domain_settings_"

    private init() {}

    public func getBool(domain: String, setting: String, defaultVal: Bool) -> Bool {
        let host = domain.lowercased()
        let key = "\(keyPrefix)\(host)_\(setting)"
        if UserDefaults.standard.object(forKey: key) == nil {
            return defaultVal
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    public func setBool(domain: String, setting: String, val: Bool) {
        let host = domain.lowercased()
        let key = "\(keyPrefix)\(host)_\(setting)"
        UserDefaults.standard.set(val, forKey: key)
    }
}

// MARK: - 用户脚本模型与存储
public struct UserScript: Codable, Equatable {
    public var id: String
    public var name: String
    public var matchPattern: String
    public var code: String
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, name: String, matchPattern: String, code: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.matchPattern = matchPattern
        self.code = code
        self.isEnabled = isEnabled
    }
}

public struct RegisteredMenuCommand {
    public let scriptId: String
    public let cmdId: Int
    public let caption: String

    public init(scriptId: String, cmdId: Int, caption: String) {
        self.scriptId = scriptId
        self.cmdId = cmdId
        self.caption = caption
    }
}

public final class UserScriptStore {
    public static let shared = UserScriptStore()
    private let key = "SimpleBrowserUserScripts_V2"

    private init() {}

    public func loadScripts() -> [UserScript] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([UserScript].self, from: data) else {
            return []
        }
        return list
    }

    public func saveScripts(_ scripts: [UserScript]) {
        if let data = try? JSONEncoder().encode(scripts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public func isScriptMatching(script: UserScript, urlString: String) -> Bool {
        guard script.isEnabled else { return false }
        let pattern = script.matchPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern == "*" || pattern == "*://*/*" || pattern.isEmpty {
            return true
        }
        if pattern.hasPrefix("*://") {
            let hostAndPath = String(pattern.dropFirst(4))
            let parts = hostAndPath.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let hostPart = String(parts[0]).replacingOccurrences(of: "*.", with: "")
            if let targetHost = URL(string: urlString)?.host?.lowercased() {
                return targetHost == hostPart || targetHost.hasSuffix("." + hostPart)
            }
        }
        return urlString.contains(pattern)
    }
}

public final class ScriptDataStore {
    public static let shared = ScriptDataStore()
    private let prefix = "GM_DATA_"

    private init() {}

    public func setValue(scriptId: String, name: String, value: Any) {
        let key = "\(prefix)\(scriptId)_\(name)"
        UserDefaults.standard.set(value, forKey: key)
    }

    public func deleteValue(scriptId: String, name: String) {
        let key = "\(prefix)\(scriptId)_\(name)"
        UserDefaults.standard.removeObject(forKey: key)
    }

    public func getAllValuesJSON(scriptId: String) -> String {
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        var values: [String: Any] = [:]
        let targetPrefix = "\(prefix)\(scriptId)_"
        for (k, v) in defaults where k.hasPrefix(targetPrefix) {
            let name = String(k.dropFirst(targetPrefix.count))
            values[name] = v
        }
        if let data = try? JSONSerialization.data(withJSONObject: values, options: []),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{}"
    }

    public func clearDataForScript(scriptId: String) {
        let defaults = UserDefaults.standard
        let targetPrefix = "\(prefix)\(scriptId)_"
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(targetPrefix) {
            defaults.removeObject(forKey: k)
        }
    }
}

// MARK: - 浏览器标识（User-Agent）模型与存储（手机版与电脑版独立默认设置）
public enum UserAgentCategory: String, Codable {
    case mobile
    case desktop
}

public struct UserAgentPreset: Codable, Equatable {
    public let id: String
    public var name: String
    public var ua: String
    public var isDesktop: Bool

    public var category: UserAgentCategory {
        return isDesktop ? .desktop : .mobile
    }

    public init(id: String = UUID().uuidString, name: String, ua: String, isDesktop: Bool) {
        self.id = id
        self.name = name
        self.ua = ua
        self.isDesktop = isDesktop
    }
}

public final class UserAgentStore {
    public static let shared = UserAgentStore()
    private let customUAsKey = "CustomUserAgents_V4"
    private let activeMobileUAIdKey = "ActiveMobileUAId_V4"
    private let activeDesktopUAIdKey = "ActiveDesktopUAId_V4"
    private let isDesktopModeEnabledKey = "IsDesktopModeEnabled_V4"

    public static let defaultMobileSafari = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
    public static let defaultMobileChrome = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/116.0.5845.177 Mobile/15E148 Safari/604.1"
    public static let defaultiPadSafari = "Mozilla/5.0 (iPad; CPU OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
    public static let defaultAndroidChrome = "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36"

    public static let defaultMacChrome = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36"
    public static let defaultMacSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"
    public static let defaultWindowsChrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36"
    public static let defaultWindowsEdge = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36 Edg/116.0.1938.81"

    // 纯粹名称，无任何括号注释
    public let presetMobileItems: [UserAgentPreset] = [
        UserAgentPreset(id: "preset_mobile_safari", name: "iOS 16 Safari", ua: defaultMobileSafari, isDesktop: false),
        UserAgentPreset(id: "preset_mobile_chrome", name: "iOS Chrome", ua: defaultMobileChrome, isDesktop: false),
        UserAgentPreset(id: "preset_mobile_ipad", name: "iPad Safari", ua: defaultiPadSafari, isDesktop: false),
        UserAgentPreset(id: "preset_mobile_android", name: "Android Chrome", ua: defaultAndroidChrome, isDesktop: false)
    ]

    public let presetDesktopItems: [UserAgentPreset] = [
        UserAgentPreset(id: "preset_desktop_chrome", name: "macOS Chrome", ua: defaultMacChrome, isDesktop: true),
        UserAgentPreset(id: "preset_desktop_safari", name: "macOS Safari", ua: defaultMacSafari, isDesktop: true),
        UserAgentPreset(id: "preset_desktop_win_chrome", name: "Windows 11 Chrome", ua: defaultWindowsChrome, isDesktop: true),
        UserAgentPreset(id: "preset_desktop_win_edge", name: "Windows 11 Edge", ua: defaultWindowsEdge, isDesktop: true)
    ]

    public private(set) var customMobileItems: [UserAgentPreset] = []
    public private(set) var customDesktopItems: [UserAgentPreset] = []

    public var isDesktopMode: Bool {
        get {
            return UserDefaults.standard.bool(forKey: isDesktopModeEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: isDesktopModeEnabledKey)
            NotificationCenter.default.post(name: NSNotification.Name("UserAgentDidChangeNotification"), object: nil)
        }
    }

    public var activeMobilePresetId: String {
        return UserDefaults.standard.string(forKey: activeMobileUAIdKey) ?? "preset_mobile_safari"
    }

    public var activeDesktopPresetId: String {
        return UserDefaults.standard.string(forKey: activeDesktopUAIdKey) ?? "preset_desktop_chrome"
    }

    public var currentUA: String {
        return getSelectedUA()
    }

    public func getSelectedUA() -> String {
        return getSelectedItem().ua
    }

    public func getSelectedItem() -> UserAgentPreset {
        if isDesktopMode {
            let id = activeDesktopPresetId
            let allDesktop = presetDesktopItems + customDesktopItems
            return allDesktop.first(where: { $0.id == id }) ?? presetDesktopItems[0]
        } else {
            let id = activeMobilePresetId
            let allMobile = presetMobileItems + customMobileItems
            return allMobile.first(where: { $0.id == id }) ?? presetMobileItems[0]
        }
    }

    private init() {
        loadCustomPresets()
    }

    public func setActiveMobileUA(id: String) {
        UserDefaults.standard.set(id, forKey: activeMobileUAIdKey)
        NotificationCenter.default.post(name: NSNotification.Name("UserAgentDidChangeNotification"), object: nil)
    }

    public func setActiveDesktopUA(id: String) {
        UserDefaults.standard.set(id, forKey: activeDesktopUAIdKey)
        NotificationCenter.default.post(name: NSNotification.Name("UserAgentDidChangeNotification"), object: nil)
    }

    public func addCustomPreset(name: String, ua: String, isDesktop: Bool) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUA = ua.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedUA.isEmpty else { return }

        let item = UserAgentPreset(name: trimmedName, ua: trimmedUA, isDesktop: isDesktop)
        if isDesktop {
            customDesktopItems.append(item)
            saveCustomPresets()
            setActiveDesktopUA(id: item.id)
        } else {
            customMobileItems.append(item)
            saveCustomPresets()
            setActiveMobileUA(id: item.id)
        }
    }

    public func deleteCustomPreset(id: String) {
        if let idx = customMobileItems.firstIndex(where: { $0.id == id }) {
            customMobileItems.remove(at: idx)
            saveCustomPresets()
            if activeMobilePresetId == id {
                setActiveMobileUA(id: "preset_mobile_safari")
            }
        } else if let idx = customDesktopItems.firstIndex(where: { $0.id == id }) {
            customDesktopItems.remove(at: idx)
            saveCustomPresets()
            if activeDesktopPresetId == id {
                setActiveDesktopUA(id: "preset_desktop_chrome")
            }
        }
    }

    private func saveCustomPresets() {
        let all = customMobileItems + customDesktopItems
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: customUAsKey)
        }
    }

    private func loadCustomPresets() {
        guard let data = UserDefaults.standard.data(forKey: customUAsKey),
              let list = try? JSONDecoder().decode([UserAgentPreset].self, from: data) else { return }
        customMobileItems = list.filter { !$0.isDesktop }
        customDesktopItems = list.filter { $0.isDesktop }
    }
}

// MARK: - 底部 Sheet 菜单模型
public enum CustomBottomSheetLayout {
    case list
    case grid
}

public struct CustomBottomSheetItem {
    public let iconName: String?
    public let customImage: UIImage?
    public let title: String
    public let hasSwitch: Bool
    public var isSwitchOn: Bool?
    public let dismissOnTap: Bool
    public let isDestructive: Bool
    public let action: (() -> Void)?
    public let longPressAction: (() -> Void)?
    public var handler: (() -> Void)? { action }
    public var longPressHandler: (() -> Void)? { longPressAction }

    public init(
        iconName: String? = nil,
        customImage: UIImage? = nil,
        title: String,
        hasSwitch: Bool = false,
        isSwitchOn: Bool? = nil,
        dismissOnTap: Bool = true,
        isDestructive: Bool = false,
        action: (() -> Void)? = nil,
        longPressAction: (() -> Void)? = nil
    ) {
        self.iconName = iconName
        self.customImage = customImage
        self.title = title
        self.hasSwitch = hasSwitch
        self.isSwitchOn = isSwitchOn
        self.dismissOnTap = dismissOnTap
        self.isDestructive = isDestructive
        self.action = action
        self.longPressAction = longPressAction
    }

    public init(
        iconName: String,
        title: String,
        hasSwitch: Bool = false,
        isSwitchOn: Bool = false,
        dismissOnTap: Bool = true,
        action: @escaping () -> Void,
        longPressAction: (() -> Void)? = nil
    ) {
        self.iconName = iconName
        self.customImage = nil
        self.title = title
        self.hasSwitch = hasSwitch
        self.isSwitchOn = isSwitchOn
        self.dismissOnTap = dismissOnTap
        self.isDestructive = false
        self.action = action
        self.longPressAction = longPressAction
    }
}
