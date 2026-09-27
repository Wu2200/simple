import Foundation
import UIKit
import WebKit

// MARK: - 书签模型（支持多级目录树）
public struct BookmarkItem: Codable, Equatable {
    public let id: String
    public var title: String
    public var url: String
    public var urlString: String {
        get { return url }
        set { url = newValue }
    }
    public var parentId: String?
    public var isFolder: Bool
    public var createdAt: Date

    public init(id: String = UUID().uuidString, title: String, url: String = "", parentId: String? = nil, isFolder: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.parentId = parentId
        self.isFolder = isFolder
        self.createdAt = createdAt
    }

    public init(id: String = UUID().uuidString, title: String, urlString: String, parentId: String? = nil, isFolder: Bool = false, createdAt: Date = Date()) {
        self.init(id: id, title: title, url: urlString, parentId: parentId, isFolder: isFolder, createdAt: createdAt)
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

    public func createFolder(title: String, parentId: String? = nil) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新建文件夹" : title
        let item = BookmarkItem(title: cleanTitle, url: "", parentId: parentId, isFolder: true)
        bookmarks.append(item)
        saveBookmarks()
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

    public func updateNode(id: String, title: String, urlString: String? = nil) {
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

    @discardableResult
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
public struct BrowserHistoryItem: Codable, Equatable {
    public var id: String
    public var title: String
    public var urlString: String
    public var visitedAt: Date

    public var url: String {
        get { urlString }
        set { urlString = newValue }
    }
    public var timestamp: Date {
        get { visitedAt }
        set { visitedAt = newValue }
    }

    public init(id: String = UUID().uuidString, title: String, urlString: String, visitedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.visitedAt = visitedAt
    }

    public init(id: String = UUID().uuidString, title: String, url: String, timestamp: Date = Date()) {
        self.id = id
        self.title = title
        self.urlString = url
        self.visitedAt = timestamp
    }
}

public typealias HistoryItem = BrowserHistoryItem

public final class BrowserHistoryStore {
    public static let shared = BrowserHistoryStore()
    private let key = "browser_visit_history_v1"
    private let maximumCount = 500

    public private(set) var history: [BrowserHistoryItem] = []

    private init() {
        history = loadHistory()
    }

    public func loadHistory() -> [BrowserHistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([BrowserHistoryItem].self, from: data) else {
            return []
        }
        return items
    }

    public func record(url: URL, title: String) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return }
        record(title: title, url: url.absoluteString)
    }

    public func record(title: String, url: String) {
        guard !url.isEmpty, !url.starts(with: "about:") else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url : title
        var items = loadHistory()
        items.removeAll { $0.urlString == url }
        let item = BrowserHistoryItem(
            id: UUID().uuidString,
            title: cleanTitle,
            urlString: url,
            visitedAt: Date()
        )
        items.insert(item, at: 0)
        if items.count > maximumCount {
            items = Array(items.prefix(maximumCount))
        }
        history = items
        saveHistory(items)

        if let host = URL(string: url)?.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }
    }

    public func delete(id: String) {
        var items = loadHistory()
        items.removeAll { $0.id == id }
        history = items
        saveHistory(items)
    }

    public func deleteItem(id: String) {
        delete(id: id)
    }

    public func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
    }

    public func clearAll() {
        clearHistory()
    }

    private func saveHistory(_ items: [BrowserHistoryItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
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

    public func getHistory() -> [String] {
        return history
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

    public func clearHistory() {
        clearAll()
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
        if let cached = memCache.object(forKey: clean as NSString) {
            return cached
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

        if cachedFavicon(for: clean) != nil { return }

        let fileURL = diskPath.appendingPathComponent("\(clean.hashValue).png")
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

        if let cached = cachedFavicon(for: clean) {
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

// MARK: - 网站数据原子清除引擎
public enum WebsiteCleaner {
    public static func clean(options: Set<CleanDataType>, completion: @escaping () -> Void) {
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
                let targetRecords = records.filter { !CookieLockStore.shared.isLocked(domain: $0.displayName) }
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
}

public enum CleanDataType: String, CaseIterable {
    case cache = "网页缓存文件"
    case history = "搜索与浏览历史记录"
    case loginAndData = "登录与本地数据"
    case scriptData = "用户脚本缓存数据"
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

    public func isLocked(domain: String) -> Bool {
        let clean = domain.lowercased()
        return lockedHosts.contains(clean)
    }

    @discardableResult
    public func toggleLock(domain: String) -> Bool {
        var set = lockedHosts
        let clean = domain.lowercased()
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

    public func lock(domain: String) {
        var set = lockedHosts
        set.insert(domain.lowercased())
        lockedHosts = set
    }

    public func unlock(domain: String) {
        var set = lockedHosts
        set.remove(domain.lowercased())
        lockedHosts = set
    }
}

// MARK: - 浏览器标识（User-Agent）模型与存储（手机版与电脑版独立管理）
public struct UserAgentPreset: Codable, Equatable {
    public let id: String
    public var name: String
    public var ua: String
    public var isDesktop: Bool

    public init(id: String = UUID().uuidString, name: String, ua: String, isDesktop: Bool) {
        self.id = id
        self.name = name
        self.ua = ua
        self.isDesktop = isDesktop
    }
}

public final class UserAgentStore {
    public static let shared = UserAgentStore()
    private let customMobileKey = "CustomMobileUserAgents_V4"
    private let customDesktopKey = "CustomDesktopUserAgents_V4"
    private let activeMobileKey = "ActiveMobileUAId_V4"
    private let activeDesktopKey = "ActiveDesktopUAId_V4"
    private let isDesktopModeKey = "IsDesktopModeEnabled_V4"

    public static let defaultMobileSafari = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
    public static let defaultMobileChrome = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/116.0.5845.177 Mobile/15E148 Safari/604.1"
    public static let defaultMobileIPad = "Mozilla/5.0 (iPad; CPU OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
    public static let defaultMobileAndroid = "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

    public static let defaultDesktopChrome = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    public static let defaultDesktopSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"
    public static let defaultDesktopWinChrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    public static let defaultDesktopWinEdge = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"

    public let presetMobileItems: [UserAgentPreset] = [
        UserAgentPreset(id: "preset_mobile_safari", name: "iOS 16 Safari", ua: defaultMobileSafari, isDesktop: false),
        UserAgentPreset(id: "preset_mobile_chrome", name: "iOS Chrome", ua: defaultMobileChrome, isDesktop: false),
        UserAgentPreset(id: "preset_mobile_ipad", name: "iPad Safari", ua: defaultMobileIPad, isDesktop: false),
        UserAgentPreset(id: "preset_mobile_android", name: "Android Chrome", ua: defaultMobileAndroid, isDesktop: false)
    ]

    public let presetDesktopItems: [UserAgentPreset] = [
        UserAgentPreset(id: "preset_desktop_chrome", name: "macOS Chrome", ua: defaultDesktopChrome, isDesktop: true),
        UserAgentPreset(id: "preset_desktop_safari", name: "macOS Safari", ua: defaultDesktopSafari, isDesktop: true),
        UserAgentPreset(id: "preset_desktop_win_chrome", name: "Windows 11 Chrome", ua: defaultDesktopWinChrome, isDesktop: true),
        UserAgentPreset(id: "preset_desktop_win_edge", name: "Windows 11 Edge", ua: defaultDesktopWinEdge, isDesktop: true)
    ]

    public private(set) var customMobileItems: [UserAgentPreset] = []
    public private(set) var customDesktopItems: [UserAgentPreset] = []

    public var activeMobilePresetId: String {
        get { UserDefaults.standard.string(forKey: activeMobileKey) ?? "preset_mobile_safari" }
        set { UserDefaults.standard.set(newValue, forKey: activeMobileKey) }
    }

    public var activeDesktopPresetId: String {
        get { UserDefaults.standard.string(forKey: activeDesktopKey) ?? "preset_desktop_chrome" }
        set { UserDefaults.standard.set(newValue, forKey: activeDesktopKey) }
    }

    public var isDesktopMode: Bool {
        get { UserDefaults.standard.bool(forKey: isDesktopModeKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: isDesktopModeKey)
            NotificationCenter.default.post(name: NSNotification.Name("UserAgentDidChangeNotification"), object: nil)
        }
    }

    public var currentUA: String {
        if isDesktopMode {
            let allDesktop = presetDesktopItems + customDesktopItems
            return allDesktop.first(where: { $0.id == activeDesktopPresetId })?.ua ?? Self.defaultDesktopChrome
        } else {
            let allMobile = presetMobileItems + customMobileItems
            return allMobile.first(where: { $0.id == activeMobilePresetId })?.ua ?? Self.defaultMobileSafari
        }
    }

    private init() {
        loadCustomPresets()
    }

    public func setActiveMobileUA(id: String) {
        activeMobilePresetId = id
        NotificationCenter.default.post(name: NSNotification.Name("UserAgentDidChangeNotification"), object: nil)
    }

    public func setActiveDesktopUA(id: String) {
        activeDesktopPresetId = id
        NotificationCenter.default.post(name: NSNotification.Name("UserAgentDidChangeNotification"), object: nil)
    }

    public func addCustomPreset(name: String, ua: String, isDesktop: Bool) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUA = ua.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedUA.isEmpty else { return }

        let item = UserAgentPreset(name: trimmedName, ua: trimmedUA, isDesktop: isDesktop)
        if isDesktop {
            customDesktopItems.append(item)
            setActiveDesktopUA(id: item.id)
        } else {
            customMobileItems.append(item)
            setActiveMobileUA(id: item.id)
        }
        saveCustomPresets()
    }

    public func deleteCustomPreset(id: String) {
        customMobileItems.removeAll { $0.id == id }
        customDesktopItems.removeAll { $0.id == id }
        saveCustomPresets()

        if activeMobilePresetId == id {
            setActiveMobileUA(id: "preset_mobile_safari")
        }
        if activeDesktopPresetId == id {
            setActiveDesktopUA(id: "preset_desktop_chrome")
        }
    }

    private func saveCustomPresets() {
        if let d1 = try? JSONEncoder().encode(customMobileItems) {
            UserDefaults.standard.set(d1, forKey: customMobileKey)
        }
        if let d2 = try? JSONEncoder().encode(customDesktopItems) {
            UserDefaults.standard.set(d2, forKey: customDesktopKey)
        }
    }

    private func loadCustomPresets() {
        if let data = UserDefaults.standard.data(forKey: customMobileKey),
           let list = try? JSONDecoder().decode([UserAgentPreset].self, from: data) {
            customMobileItems = list
        }
        if let data = UserDefaults.standard.data(forKey: customDesktopKey),
           let list = try? JSONDecoder().decode([UserAgentPreset].self, from: data) {
            customDesktopItems = list
        }
    }
}

// MARK: - 基础组件
open class TouchButton: UIButton {
    public var hitTestInsets: UIEdgeInsets = .zero

    public convenience init() {
        self.init(frame: .zero)
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    open override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if hitTestInsets == .zero {
            return super.point(inside: point, with: event)
        }
        let hitFrame = bounds.inset(by: hitTestInsets)
        return hitFrame.contains(point)
    }
}

// MARK: - 底部 Sheet 布局与模型
public enum CustomBottomSheetLayout {
    case grid
    case list
}

public struct CustomBottomSheetItem {
    public var title: String
    public var iconName: String?
    public var customImage: UIImage?
    public var isDestructive: Bool
    public var hasSwitch: Bool
    public var isSwitchOn: Bool?
    public var dismissOnTap: Bool
    public var handler: (() -> Void)?
    public var longPressHandler: (() -> Void)?

    public var action: (() -> Void)? {
        get { handler }
        set { handler = newValue }
    }
    public var longPressAction: (() -> Void)? {
        get { longPressHandler }
        set { longPressHandler = newValue }
    }

    public init(
        title: String,
        iconName: String? = nil,
        customImage: UIImage? = nil,
        isDestructive: Bool = false,
        hasSwitch: Bool = false,
        isSwitchOn: Bool? = nil,
        dismissOnTap: Bool = true,
        handler: (() -> Void)? = nil,
        longPressHandler: (() -> Void)? = nil
    ) {
        self.title = title
        self.iconName = iconName
        self.customImage = customImage
        self.isDestructive = isDestructive
        self.hasSwitch = hasSwitch
        self.isSwitchOn = isSwitchOn
        self.dismissOnTap = dismissOnTap
        self.handler = handler
        self.longPressHandler = longPressHandler
    }

    public init(
        iconName: String?,
        title: String,
        isDestructive: Bool = false,
        hasSwitch: Bool = false,
        isSwitchOn: Bool? = nil,
        dismissOnTap: Bool = true,
        action: (() -> Void)? = nil,
        longPressAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.iconName = iconName
        self.customImage = nil
        self.isDestructive = isDestructive
        self.hasSwitch = hasSwitch
        self.isSwitchOn = isSwitchOn
        self.dismissOnTap = dismissOnTap
        self.handler = action
        self.longPressHandler = longPressAction
    }

    public init(
        customImage: UIImage?,
        title: String,
        isDestructive: Bool = false,
        hasSwitch: Bool = false,
        isSwitchOn: Bool? = nil,
        dismissOnTap: Bool = true,
        action: (() -> Void)? = nil,
        longPressAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.iconName = nil
        self.customImage = customImage
        self.isDestructive = isDestructive
        self.hasSwitch = hasSwitch
        self.isSwitchOn = isSwitchOn
        self.dismissOnTap = dismissOnTap
        self.handler = action
        self.longPressHandler = longPressAction
    }
}

// MARK: - 用户脚本模型与存储
public struct UserScript: Codable, Equatable {
    public var id: String
    public var name: String
    public var matchPattern: String
    public var code: String
    public var isEnabled: Bool

    public init(name: String, matchPattern: String = "*", code: String = "", isEnabled: Bool = true, id: String = UUID().uuidString) {
        self.id = id
        self.name = name
        self.matchPattern = matchPattern
        self.code = code
        self.isEnabled = isEnabled
    }

    public init(id: String, name: String, matchPattern: String = "*", code: String = "", isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.matchPattern = matchPattern
        self.code = code
        self.isEnabled = isEnabled
    }
}

public final class UserScriptStore {
    public static let shared = UserScriptStore()
    private let key = "user_tampermonkey_scripts_v5"

    private init() {}

    public func loadScripts() -> [UserScript] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let scripts = try? JSONDecoder().decode([UserScript].self, from: data) else {
            return []
        }
        return scripts
    }

    public func saveScripts(_ scripts: [UserScript]) {
        if let data = try? JSONEncoder().encode(scripts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public func parseMetadata(from code: String) -> (name: String, match: String) {
        var nameMap: [String: String] = [:]
        var matches: [String] = []

        let lines = code.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") else { continue }
            let content = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard content.hasPrefix("@") else { continue }

            let components = content.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard components.count >= 2 else { continue }

            let tag = components[0]
            let val = components.dropFirst().joined(separator: " ")

            if tag.hasPrefix("@name") {
                nameMap[tag] = val
            } else if tag == "@match" || tag == "@include" {
                matches.append(val)
            }
        }

        let preferredName = nameMap["@name:zh-CN"] ?? nameMap["@name:zh"] ?? nameMap["@name:zh-TW"] ?? nameMap["@name"] ?? "未命名脚本"
        let preferredMatch = matches.first ?? "*"

        return (preferredName, preferredMatch)
    }

    public func isScriptMatching(script: UserScript, urlString: String) -> Bool {
        guard script.isEnabled else { return false }

        if let url = URL(string: urlString), let host = url.host {
            let scriptEnabled = DomainSettingsStore.shared.getBool(domain: host, setting: "userScripts", defaultVal: true)
            if !scriptEnabled { return false }
        }

        if script.matchPattern == "*" || script.matchPattern.isEmpty { return true }
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return true }
        let pattern = script.matchPattern.lowercased()
            .replacingOccurrences(of: "*://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .components(separatedBy: "/").first ?? script.matchPattern
        let domainPattern = pattern.replacingOccurrences(of: "*.", with: "").replacingOccurrences(of: "*", with: "")
        if domainPattern.isEmpty { return true }
        return host == domainPattern || host.hasSuffix("." + domainPattern)
    }
}

// MARK: - 用户脚本本地存储管理器
public final class ScriptDataStore {
    public static let shared = ScriptDataStore()
    private init() {}

    private func makeKey(_ scriptId: String, _ name: String) -> String {
        return "GM_DATA_\(scriptId)_\(name)"
    }

    public func getValue(scriptId: String, name: String) -> Any? {
        return UserDefaults.standard.object(forKey: makeKey(scriptId, name))
    }

    public func setValue(scriptId: String, name: String, value: Any) {
        UserDefaults.standard.set(value, forKey: makeKey(scriptId, name))
    }

    public func deleteValue(scriptId: String, name: String) {
        UserDefaults.standard.removeObject(forKey: makeKey(scriptId, name))
    }

    public func clearDataForScript(scriptId: String) {
        let prefix = "GM_DATA_\(scriptId)_"
        for (k, _) in UserDefaults.standard.dictionaryRepresentation() {
            if k.hasPrefix(prefix) {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
    }

    public func clearAllScriptData() {
        let prefix = "GM_DATA_"
        for (k, _) in UserDefaults.standard.dictionaryRepresentation() {
            if k.hasPrefix(prefix) {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
    }

    public func getAllValuesJSON(scriptId: String) -> String {
        let prefix = "GM_DATA_\(scriptId)_"
        var dict: [String: Any] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() {
            if k.hasPrefix(prefix) {
                let name = String(k.dropFirst(prefix.count))
                dict[name] = v
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}

// MARK: - 域名单独配置持久化管理器
public final class DomainSettingsStore {
    public static let shared = DomainSettingsStore()
    private init() {}

    private func makeKey(_ domain: String, _ setting: String) -> String {
        return "DOMAIN_SETTING_\(domain.lowercased())_\(setting)"
    }

    public func getBool(domain: String, setting: String, defaultVal: Bool = true) -> Bool {
        let k = makeKey(domain, setting)
        if UserDefaults.standard.object(forKey: k) == nil {
            return defaultVal
        }
        return UserDefaults.standard.bool(forKey: k)
    }

    public func setBool(domain: String, setting: String, value: Bool) {
        UserDefaults.standard.set(value, forKey: makeKey(domain, setting))
    }
}
