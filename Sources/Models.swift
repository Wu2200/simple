import Foundation
import UIKit
import WebKit

// MARK: - 基础触控反馈按钮
class TouchButton: UIButton {
    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
                self.alpha = self.isHighlighted ? 0.75 : 1.0
            }
        }
    }
}

// MARK: - 书签模型（支持多级目录树）
struct BookmarkItem: Codable, Equatable {
    let id: String
    var title: String
    var url: String
    var parentId: String?
    var isFolder: Bool
    var createdAt: Date

    init(id: String = UUID().uuidString, title: String, url: String = "", parentId: String? = nil, isFolder: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.parentId = parentId
        self.isFolder = isFolder
        self.createdAt = createdAt
    }
}

// MARK: - 书签持久化管理器
final class BookmarkStore {
    static let shared = BookmarkStore()
    private let key = "SimpleBrowserBookmarksTree_V2"

    private(set) var bookmarks: [BookmarkItem] = []

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
            ("Bing 搜索", "https://www.bing.com"),
            ("V2EX", "https://www.v2ex.com")
        ]
        for (t, u) in defaults {
            bookmarks.append(BookmarkItem(title: t, url: u, parentId: nil, isFolder: false))
        }
        saveBookmarks()
    }

    func getItems(in parentId: String?) -> [BookmarkItem] {
        return bookmarks.filter { $0.parentId == parentId }.sorted { (b1, b2) in
            if b1.isFolder != b2.isFolder {
                return b1.isFolder && !b2.isFolder
            }
            return b1.createdAt > b2.createdAt
        }
    }

    func getAllFolders() -> [BookmarkItem] {
        return bookmarks.filter { $0.isFolder }
    }

    func addBookmark(title: String, url: String, parentId: String? = nil) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "网页书签" : title
        let item = BookmarkItem(title: cleanTitle, url: url, parentId: parentId, isFolder: false)
        bookmarks.append(item)
        saveBookmarks()

        if let host = URL(string: url)?.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }
    }

    func createFolder(title: String, parentId: String? = nil) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新建文件夹" : title
        let item = BookmarkItem(title: cleanTitle, url: "", parentId: parentId, isFolder: true)
        bookmarks.append(item)
        saveBookmarks()
    }

    func updateItem(id: String, title: String, url: String) {
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

    func deleteItem(id: String) {
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

    func countChildren(of folderId: String) -> Int {
        return bookmarks.filter { $0.parentId == folderId }.count
    }

    func exportToAlookHTML() -> String {
        var html = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n"
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
    func importFromAlookHTML(_ html: String) -> Int {
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

// MARK: - 主页快捷方式
struct HomeShortcutItem: Codable, Equatable {
    let id: String
    var title: String
    var url: String
    var iconColorHex: String

    init(id: String = UUID().uuidString, title: String, url: String, iconColorHex: String = "#007AFF") {
        self.id = id
        self.title = title
        self.url = url
        self.iconColorHex = iconColorHex
    }
}

final class HomeShortcutStore {
    static let shared = HomeShortcutStore()
    private let key = "SimpleBrowserHomeShortcuts_V2"

    private(set) var shortcuts: [HomeShortcutItem] = []

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

    func addShortcut(title: String, url: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "常用站点" : title
        let item = HomeShortcutItem(title: cleanTitle, url: url)
        shortcuts.append(item)
        saveShortcuts()

        if let host = URL(string: url)?.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }
    }

    func updateShortcut(id: String, title: String, url: String) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        shortcuts[index].title = title
        shortcuts[index].url = url
        saveShortcuts()

        if let host = URL(string: url)?.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }
    }

    func deleteShortcut(id: String) {
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

// MARK: - 历史记录
struct HistoryItem: Codable, Equatable {
    let id: String
    let title: String
    let url: String
    let timestamp: Date

    init(id: String = UUID().uuidString, title: String, url: String, timestamp: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.timestamp = timestamp
    }
}

final class BrowserHistoryStore {
    static let shared = BrowserHistoryStore()
    private let key = "SimpleBrowserHistoryList"
    private(set) var history: [HistoryItem] = []

    private init() {
        loadHistory()
    }

    func record(title: String, url: String) {
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

    func clearAll() {
        history.removeAll()
        saveHistory()
    }

    func deleteItem(id: String) {
        history.removeAll { $0.id == id }
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = list
        }
    }
}

// MARK: - 搜索历史
final class SearchHistoryStore {
    static let shared = SearchHistoryStore()
    private let key = "SimpleBrowserSearchKeywords"
    private(set) var history: [String] = []

    private init() {
        history = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func addHistory(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.removeAll { $0 == trimmed }
        history.insert(trimmed, at: 0)
        if history.count > 50 {
            history = Array(history.prefix(50))
        }
        UserDefaults.standard.set(history, forKey: key)
    }

    func clearAll() {
        history.removeAll()
        UserDefaults.standard.set(history, forKey: key)
    }
}

// MARK: - Favicon 加载器
final class FaviconLoader {
    static let shared = FaviconLoader()
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

    func preloadFavicon(for host: String) {
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

    func loadFavicon(for host: String, completion: @escaping (UIImage?) -> Void) {
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

// MARK: - 清理数据类型与引擎
enum CleanDataType: String, CaseIterable {
    case cache = "网页缓存文件"
    case history = "搜索与浏览历史记录"
    case loginAndData = "登录与本地数据"
    case scriptData = "用户脚本缓存数据"
}

enum WebsiteCleaner {
    static func clean(options: Set<CleanDataType>, completion: @escaping () -> Void) {
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
}

// MARK: - 域名锁定存储
final class CookieLockStore {
    static let shared = CookieLockStore()
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

    func isLocked(host: String) -> Bool {
        return lockedHosts.contains(host.lowercased())
    }

    func toggleLock(host: String) -> Bool {
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

    func lock(host: String) {
        var set = lockedHosts
        set.insert(host.lowercased())
        lockedHosts = set
    }

    func unlock(host: String) {
        var set = lockedHosts
        set.remove(host.lowercased())
        lockedHosts = set
    }
}

typealias WebsiteLockManager = CookieLockStore

// MARK: - UA 模型与存储
struct UserAgentPreset: Codable, Equatable {
    let id: String
    var name: String
    var ua: String
    var isDesktop: Bool

    init(id: String = UUID().uuidString, name: String, ua: String, isDesktop: Bool) {
        self.id = id
        self.name = name
        self.ua = ua
        self.isDesktop = isDesktop
    }
}

final class UserAgentStore {
    static let shared = UserAgentStore()
    private let customMobileKey = "CustomMobileUserAgents_V4"
    private let customDesktopKey = "CustomDesktopUserAgents_V4"
    private let activeMobileIdKey = "ActiveMobileUAId_V4"
    private let activeDesktopIdKey = "ActiveDesktopUAId_V4"
    private let isDesktopModeKey = "IsBrowserDesktopModeEnabled_V4"

    static let defaultMobileSafari = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
    static let defaultMacSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"

    let presetMobileItems: [UserAgentPreset] = [
        UserAgentPreset(id: "preset_mobile_safari", name: "iOS 16 Safari", ua: defaultMobileSafari, isDesktop: false),
        UserAgentPreset(id: "preset_mobile_chrome", name: "iOS Chrome", ua: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/116.0.5845.177 Mobile/15E148 Safari/604.1", isDesktop: false),
        UserAgentPreset(id: "preset_mobile_ipad", name: "iPad Safari", ua: "Mozilla/5.0 (iPad; CPU OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1", isDesktop: false),
        UserAgentPreset(id: "preset_mobile_android", name: "Android Chrome", ua: "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36", isDesktop: false)
    ]

    let presetDesktopItems: [UserAgentPreset] = [
        UserAgentPreset(id: "preset_desktop_chrome", name: "macOS Chrome", ua: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36", isDesktop: true),
        UserAgentPreset(id: "preset_desktop_safari", name: "macOS Safari", ua: defaultMacSafari, isDesktop: true),
        UserAgentPreset(id: "preset_desktop_win_chrome", name: "Windows 11 Chrome", ua: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36", isDesktop: true),
        UserAgentPreset(id: "preset_desktop_edge", name: "Windows 11 Edge", ua: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36 Edg/116.0.1938.81", isDesktop: true)
    ]

    private(set) var customMobileItems: [UserAgentPreset] = []
    private(set) var customDesktopItems: [UserAgentPreset] = []

    var activeMobilePresetId: String {
        get { UserDefaults.standard.string(forKey: activeMobileIdKey) ?? "preset_mobile_safari" }
        set { UserDefaults.standard.set(newValue, forKey: activeMobileIdKey) }
    }

    var activeDesktopPresetId: String {
        get { UserDefaults.standard.string(forKey: activeDesktopIdKey) ?? "preset_desktop_safari" }
        set { UserDefaults.standard.set(newValue, forKey: activeDesktopIdKey) }
    }

    var isCurrentDesktop: Bool {
        get { UserDefaults.standard.bool(forKey: isDesktopModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: isDesktopModeKey) }
    }

    var currentUA: String {
        if isCurrentDesktop {
            let all = presetDesktopItems + customDesktopItems
            return all.first(where: { $0.id == activeDesktopPresetId })?.ua ?? Self.defaultMacSafari
        } else {
            let all = presetMobileItems + customMobileItems
            return all.first(where: { $0.id == activeMobilePresetId })?.ua ?? Self.defaultMobileSafari
        }
    }

    private init() {
        loadCustomPresets()
    }

    func addCustomPreset(name: String, ua: String, isDesktop: Bool) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUA = ua.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanUA.isEmpty else { return }

        let item = UserAgentPreset(name: cleanName, ua: cleanUA, isDesktop: isDesktop)
        if isDesktop {
            customDesktopItems.append(item)
            activeDesktopPresetId = item.id
        } else {
            customMobileItems.append(item)
            activeMobilePresetId = item.id
        }
        saveCustomPresets()
        NotificationCenter.default.post(name: NSNotification.Name("UserAgentDidChangeNotification"), object: nil)
    }

    func deleteCustomPreset(id: String, isDesktop: Bool) {
        if isDesktop {
            customDesktopItems.removeAll { $0.id == id }
            if activeDesktopPresetId == id {
                activeDesktopPresetId = "preset_desktop_safari"
            }
        } else {
            customMobileItems.removeAll { $0.id == id }
            if activeMobilePresetId == id {
                activeMobilePresetId = "preset_mobile_safari"
            }
        }
        saveCustomPresets()
        NotificationCenter.default.post(name: NSNotification.Name("UserAgentDidChangeNotification"), object: nil)
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
        if let d1 = UserDefaults.standard.data(forKey: customMobileKey),
           let list = try? JSONDecoder().decode([UserAgentPreset].self, from: d1) {
            customMobileItems = list
        }
        if let d2 = UserDefaults.standard.data(forKey: customDesktopKey),
           let list = try? JSONDecoder().decode([UserAgentPreset].self, from: d2) {
            customDesktopItems = list
        }
    }
}

// MARK: - 底部 Sheet Item
struct CustomBottomSheetItem {
    let iconName: String
    let customImage: UIImage?
    let title: String
    let hasSwitch: Bool
    var isSwitchOn: Bool
    let dismissOnTap: Bool
    let action: () -> Void
    let longPressAction: (() -> Void)?

    init(
        iconName: String = "",
        customImage: UIImage? = nil,
        title: String,
        hasSwitch: Bool = false,
        isSwitchOn: Bool = false,
        dismissOnTap: Bool = true,
        action: @escaping () -> Void,
        longPressAction: (() -> Void)? = nil
    ) {
        self.iconName = iconName
        self.customImage = customImage
        self.title = title
        self.hasSwitch = hasSwitch
        self.isSwitchOn = isSwitchOn
        self.dismissOnTap = dismissOnTap
        self.action = action
        self.longPressAction = longPressAction
    }
}
