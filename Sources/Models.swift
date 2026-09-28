import UIKit
import WebKit

// MARK: - 主域名聚合数据模型

struct MainDomainGroup {
    let mainDomain: String
    var records: [WKWebsiteDataRecord]

    var allDataTypes: Set<String> {
        var types = Set<String>()
        for r in records {
            types.formUnion(r.dataTypes)
        }
        return types
    }

    var hasLocked: Bool {
        return CookieLockStore.shared.isLocked(domain: mainDomain) || records.contains { CookieLockStore.shared.isLocked(domain: $0.displayName) }
    }

    var allLocked: Bool {
        return !records.isEmpty && records.allSatisfy { CookieLockStore.shared.isLocked(domain: $0.displayName) }
    }

    var hasCookies: Bool {
        return records.contains { $0.dataTypes.contains(WKWebsiteDataTypeCookies) }
    }
}

// MARK: - 关联域名拓扑识别引擎

enum DomainRelationEngine {
    static let companionMap: [(keyword: String, targetRoot: String)] = [
        ("oaistatic.com", "chatgpt.com"),
        ("oaiusercontent.com", "chatgpt.com"),
        ("githubassets.com", "github.com"),
        ("githubusercontent.com", "github.com"),
        ("hdslb.com", "bilibili.com"),
        ("bilivideo.com", "bilibili.com"),
        ("bdstatic.com", "baidu.com"),
        ("baidupcs.com", "baidu.com"),
        ("gstatic.com", "google.com"),
        ("googleusercontent.com", "google.com"),
        ("googleapis.com", "google.com"),
        ("googlevideo.com", "youtube.com"),
        ("ytimg.com", "youtube.com"),
        ("zhimg.com", "zhihu.com"),
        ("uxengine.net", "v2ex.com")
    ]

    static func rootDomain(of domain: String) -> String {
        let clean = domain.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let parts = clean.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return clean }

        if parts.allSatisfy({ Int($0) != nil }) && parts.count == 4 {
            return clean
        }
        if clean.contains(":") {
            return clean
        }

        let multiSuffixes: Set<String> = [
            "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
            "co.uk", "org.uk", "me.uk", "co.jp", "ne.jp",
            "com.hk", "org.hk", "com.tw", "com.au", "co.nz"
        ]

        if parts.count >= 3 {
            let lastTwo = "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
            if multiSuffixes.contains(lastTwo) {
                return "\(parts[parts.count - 3]).\(lastTwo)"
            }
        }

        return "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
    }

    static func areDomainsAssociated(_ d1: String, _ d2: String) -> Bool {
        let r1 = rootDomain(of: d1)
        let r2 = rootDomain(of: d2)
        if !r1.isEmpty && r1 == r2 { return true }

        for item in companionMap {
            let itemKeyRoot = rootDomain(of: item.keyword)
            let itemTarRoot = rootDomain(of: item.targetRoot)

            let match1 = (r1 == itemKeyRoot || r1 == itemTarRoot)
            let match2 = (r2 == itemKeyRoot || r2 == itemTarRoot)
            if match1 && match2 {
                return true
            }
        }
        return false
    }

    static func groupRecordsIntoMainDomains(_ records: [WKWebsiteDataRecord]) -> [MainDomainGroup] {
        var dict: [String: [WKWebsiteDataRecord]] = [:]

        for record in records {
            let host = record.displayName.trimmingCharacters(in: .whitespaces).lowercased()
            let root = rootDomain(of: host)
            dict[root, default: []].append(record)
        }

        for item in companionMap {
            let compRoot = rootDomain(of: item.keyword)
            let targetRoot = rootDomain(of: item.targetRoot)
            if let compRecs = dict[compRoot], dict[targetRoot] != nil {
                dict[targetRoot]?.append(contentsOf: compRecs)
                dict.removeValue(forKey: compRoot)
            }
        }

        var groups: [MainDomainGroup] = []
        for (mainDomain, groupRecords) in dict {
            var seen = Set<String>()
            var uniqueRecords: [WKWebsiteDataRecord] = []
            for r in groupRecords {
                if !seen.contains(r.displayName) {
                    seen.insert(r.displayName)
                    uniqueRecords.append(r)
                }
            }

            let sortedRecords = uniqueRecords.sorted { r1, r2 in
                let h1 = r1.displayName.lowercased()
                let h2 = r2.displayName.lowercased()
                if h1 == mainDomain { return true }
                if h2 == mainDomain { return false }
                let lock1 = CookieLockStore.shared.isLocked(domain: r1.displayName)
                let lock2 = CookieLockStore.shared.isLocked(domain: r2.displayName)
                if lock1 != lock2 { return lock1 && !lock2 }
                let c1 = r1.dataTypes.contains(WKWebsiteDataTypeCookies)
                let c2 = r2.dataTypes.contains(WKWebsiteDataTypeCookies)
                if c1 != c2 { return c1 && !c2 }
                return h1 < h2
            }

            groups.append(MainDomainGroup(mainDomain: mainDomain, records: sortedRecords))
        }

        return groups.sorted { g1, g2 in
            let lock1 = g1.hasLocked
            let lock2 = g2.hasLocked
            if lock1 != lock2 { return lock1 && !lock2 }
            let cookie1 = g1.hasCookies
            let cookie2 = g2.hasCookies
            if cookie1 != cookie2 { return cookie1 && !cookie2 }
            return g1.mainDomain.localizedCaseInsensitiveCompare(g2.mainDomain) == .orderedAscending
        }
    }
}

// MARK: - 基础模型定义

struct UserScript: Codable {
    var id: String
    var name: String
    var matchPattern: String
    var code: String
    var isEnabled: Bool
}

enum UserAgentCategory: String, Codable {
    case mobile
    case desktop
    case custom
}

struct UserAgentItem: Codable, Equatable {
    var id: String
    var name: String
    var uaString: String
    var isCustom: Bool
    var category: UserAgentCategory
}

struct RegisteredMenuCommand {
    let scriptId: String
    let cmdId: Int
    let caption: String
}

enum CleanOption: Int, Hashable, CaseIterable {
    case cache = 0
    case loginAndData = 1
    case searchHistory = 2
    case scriptData = 3
}

enum CustomBottomSheetLayout {
    case grid
    case list
}

enum SearchEngine: String, CaseIterable, Codable {
    case google = "google"
    case bing = "bing"
    case yandex = "yandex"

    var name: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing"
        case .yandex: return "Yandex"
        }
    }

    func searchURL(query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        switch self {
        case .google:
            return URL(string: "https://www.google.com/search?q=\(encoded)")
        case .bing:
            return URL(string: "https://www.bing.com/search?q=\(encoded)")
        case .yandex:
            return URL(string: "https://yandex.com/search/?text=\(encoded)")
        }
    }
}

final class SearchEngineStore {
    static let shared = SearchEngineStore()
    private let key = "browser_selected_search_engine_v1"
    private init() {}

    var currentEngine: SearchEngine {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let engine = SearchEngine(rawValue: raw) else {
                return .google
            }
            return engine
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}

struct BookmarkItem: Codable, Equatable {
    var id: String
    var title: String
    var urlString: String
    var isFolder: Bool
    var parentId: String?
    var createdAt: Date
    var order: Int

    init(
        id: String = UUID().uuidString,
        title: String,
        urlString: String = "",
        isFolder: Bool = false,
        parentId: String? = nil,
        createdAt: Date = Date(),
        order: Int = 0
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.isFolder = isFolder
        self.parentId = parentId
        self.createdAt = createdAt
        self.order = order
    }
}

final class BookmarkStore {
    static let shared = BookmarkStore()
    private let keyTree = "browser_bookmarks_tree_v3"
    private let keyLegacy = "browser_bookmarks_v1"
    private init() {
        migrateLegacyIfNeeded()
    }

    private func migrateLegacyIfNeeded() {
        if UserDefaults.standard.data(forKey: keyTree) == nil {
            if let oldData = UserDefaults.standard.data(forKey: keyLegacy) {
                struct LegacyBookmarkItem: Codable {
                    var id: String
                    var title: String
                    var urlString: String
                    var createdAt: Date
                }
                if let oldItems = try? JSONDecoder().decode([LegacyBookmarkItem].self, from: oldData), !oldItems.isEmpty {
                    var newNodes: [BookmarkItem] = []
                    for (index, old) in oldItems.enumerated() {
                        newNodes.append(BookmarkItem(
                            id: old.id,
                            title: old.title,
                            urlString: old.urlString,
                            isFolder: false,
                            parentId: nil,
                            createdAt: old.createdAt,
                            order: index
                        ))
                    }
                    saveNodes(newNodes)
                }
            }
        }
    }

    func loadAllNodes() -> [BookmarkItem] {
        guard let data = UserDefaults.standard.data(forKey: keyTree),
              let nodes = try? JSONDecoder().decode([BookmarkItem].self, from: data) else {
            return []
        }
        return nodes.sorted { $0.order < $1.order }
    }

    func loadBookmarks() -> [BookmarkItem] {
        return loadAllNodes()
    }

    func getNodes(inParent parentId: String?) -> [BookmarkItem] {
        let all = loadAllNodes()
        let matching = all.filter { $0.parentId == parentId }
        return matching.sorted {
            if $0.isFolder != $1.isFolder {
                return $0.isFolder && !$1.isFolder
            }
            return $0.order < $1.order
        }
    }

    func getAllFolders() -> [BookmarkItem] {
        return loadAllNodes().filter { $0.isFolder }
    }

    func getNode(id: String) -> BookmarkItem? {
        return loadAllNodes().first { $0.id == id }
    }

    func countChildren(of folderId: String) -> Int {
        return loadAllNodes().filter { $0.parentId == folderId }.count
    }

    func addBookmark(title: String, urlString: String, parentId: String? = nil) {
        var all = loadAllNodes()
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (URL(string: urlString)?.host ?? urlString) : title
        let maxOrder = all.filter { $0.parentId == parentId }.map { $0.order }.max() ?? -1
        let item = BookmarkItem(
            id: UUID().uuidString,
            title: resolvedTitle,
            urlString: urlString,
            isFolder: false,
            parentId: parentId,
            createdAt: Date(),
            order: maxOrder + 1
        )
        all.append(item)
        saveNodes(all)
        if let url = URL(string: urlString), let host = url.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }
    }

    func createFolder(title: String, parentId: String? = nil) -> BookmarkItem {
        var all = loadAllNodes()
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新建文件夹" : title
        let maxOrder = all.filter { $0.parentId == parentId }.map { $0.order }.max() ?? -1
        let folder = BookmarkItem(
            id: UUID().uuidString,
            title: cleanTitle,
            urlString: "",
            isFolder: true,
            parentId: parentId,
            createdAt: Date(),
            order: maxOrder + 1
        )
        all.append(folder)
        saveNodes(all)
        return folder
    }

    func updateNode(id: String, title: String, urlString: String? = nil) {
        var all = loadAllNodes()
        if let idx = all.firstIndex(where: { $0.id == id }) {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanTitle.isEmpty {
                all[idx].title = cleanTitle
            }
            if let u = urlString, !all[idx].isFolder {
                all[idx].urlString = u.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            saveNodes(all)
        }
    }

    func deleteNode(id: String) {
        var all = loadAllNodes()
        var idsToDelete: Set<String> = [id]
        var queue: [String] = [id]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let children = all.filter { $0.parentId == current }.map { $0.id }
            idsToDelete.formUnion(children)
            queue.append(contentsOf: children)
        }
        all.removeAll { idsToDelete.contains($0.id) }
        saveNodes(all)
    }

    func deleteBookmark(id: String) {
        deleteNode(id: id)
    }

    func isBookmarked(urlString: String) -> Bool {
        return loadAllNodes().contains { !$0.isFolder && $0.urlString == urlString }
    }

    func clearBookmarks() {
        UserDefaults.standard.removeObject(forKey: keyTree)
        UserDefaults.standard.removeObject(forKey: keyLegacy)
    }

    func saveAllNodes(_ items: [BookmarkItem]) {
        saveNodes(items)
    }

    private func saveNodes(_ items: [BookmarkItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: keyTree)
    }

    func exportToAlookHTML() -> String {
        var html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>

        """
        html += generateFolderHTML(parentId: nil, indent: 4)
        html += "</DL><p>\n"
        return html
    }

    private func generateFolderHTML(parentId: String?, indent: Int) -> String {
        let spaces = String(repeating: " ", count: indent)
        let nodes = getNodes(inParent: parentId)
        var result = ""
        for node in nodes {
            let timestamp = Int(node.createdAt.timeIntervalSince1970)
            if node.isFolder {
                result += "\(spaces)<DT><H3 ADD_DATE=\"\(timestamp)\">\(escapeXML(node.title))</H3>\n"
                result += "\(spaces)<DL><p>\n"
                result += generateFolderHTML(parentId: node.id, indent: indent + 4)
                result += "\(spaces)</DL><p>\n"
            } else {
                result += "\(spaces)<DT><A HREF=\"\(escapeXML(node.urlString))\" ADD_DATE=\"\(timestamp)\">\(escapeXML(node.title))</A>\n"
            }
        }
        return result
    }

    private func escapeXML(_ str: String) -> String {
        return str.replacingOccurrences(of: "&", with: "&amp;")
                  .replacingOccurrences(of: "<", with: "&lt;")
                  .replacingOccurrences(of: ">", with: "&gt;")
                  .replacingOccurrences(of: "\"", with: "&quot;")
    }

    func importFromAlookHTML(_ html: String) {
        var parentStack: [String?] = [nil]
        let lines = html.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.contains("</DL>") || trimmed.contains("</dl>") {
                if parentStack.count > 1 {
                    parentStack.removeLast()
                }
            } else if trimmed.contains("<H3") || trimmed.contains("<h3") {
                if let title = extractContentBetween(in: trimmed, start: ">", end: "</") {
                    let clean = title.components(separatedBy: ">").last ?? title
                    let currentParent = parentStack.last ?? nil
                    let folder = createFolder(title: clean, parentId: currentParent)
                    parentStack.append(folder.id)
                }
            } else if trimmed.contains("<A ") || trimmed.contains("<a ") {
                let urlStr = extractAttribute(in: trimmed, attr: "HREF") ?? extractAttribute(in: trimmed, attr: "href") ?? ""
                let title = extractContentBetween(in: trimmed, start: ">", end: "</") ?? (URL(string: urlStr)?.host ?? urlStr)
                let cleanTitle = title.components(separatedBy: ">").last ?? title
                if !urlStr.isEmpty {
                    let currentParent = parentStack.last ?? nil
                    addBookmark(title: cleanTitle, urlString: urlStr, parentId: currentParent)
                }
            }
        }
    }

    private func extractAttribute(in line: String, attr: String) -> String? {
        guard let range = line.range(of: "\(attr)=\"", options: .caseInsensitive) else { return nil }
        let sub = line[range.upperBound...]
        guard let endRange = sub.range(of: "\"") else { return nil }
        return String(sub[..<endRange.lowerBound])
    }

    private func extractContentBetween(in line: String, start: String, end: String) -> String? {
        guard let startRange = line.range(of: start) else { return nil }
        let sub = line[startRange.upperBound...]
        guard let endRange = sub.range(of: end) else { return nil }
        return String(sub[..<endRange.lowerBound])
    }
}

// MARK: - 主页快捷方式模型与存储 (支持自定义上传图片 Logo)

struct HomeShortcutItem: Codable, Equatable {
    var id: String
    var title: String
    var urlString: String
    var customIconData: Data?

    init(id: String, title: String, urlString: String, customIconData: Data? = nil) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.customIconData = customIconData
    }
}

final class HomeShortcutStore {
    static let shared = HomeShortcutStore()
    private let key = "browser_home_shortcuts_v2"

    private let defaultItems: [HomeShortcutItem] = [
        HomeShortcutItem(id: "1", title: "百度", urlString: "https://www.baidu.com"),
        HomeShortcutItem(id: "2", title: "必应", urlString: "https://www.bing.com"),
        HomeShortcutItem(id: "3", title: "GitHub", urlString: "https://github.com"),
        HomeShortcutItem(id: "4", title: "哔哩哔哩", urlString: "https://www.bilibili.com"),
        HomeShortcutItem(id: "5", title: "知乎", urlString: "https://www.zhihu.com"),
        HomeShortcutItem(id: "6", title: "掘金", urlString: "https://juejin.cn"),
        HomeShortcutItem(id: "7", title: "维基百科", urlString: "https://zh.wikipedia.org"),
        HomeShortcutItem(id: "8", title: "V2EX", urlString: "https://www.v2ex.com")
    ]

    private init() {}

    func loadShortcuts() -> [HomeShortcutItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([HomeShortcutItem].self, from: data),
              !items.isEmpty else {
            return defaultItems
        }
        return items
    }

    func addShortcut(title: String, urlString: String, customIconData: Data? = nil) {
        var items = loadShortcuts()
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = cleanTitle.isEmpty ? (URL(string: urlString)?.host ?? urlString) : cleanTitle
        items.removeAll { $0.urlString == urlString }
        items.append(HomeShortcutItem(id: UUID().uuidString, title: resolvedTitle, urlString: urlString, customIconData: customIconData))
        saveShortcuts(items)
        if customIconData == nil, let url = URL(string: urlString), let host = url.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }
    }

    func updateShortcut(id: String, title: String, urlString: String, customIconData: Data? = nil) {
        var items = loadShortcuts()
        if let idx = items.firstIndex(where: { $0.id == id }) {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = cleanTitle.isEmpty ? (URL(string: urlString)?.host ?? urlString) : cleanTitle
            items[idx].title = resolvedTitle
            items[idx].urlString = urlString
            if let customIconData = customIconData {
                items[idx].customIconData = customIconData
            }
            saveShortcuts(items)
            if items[idx].customIconData == nil, let url = URL(string: urlString), let host = url.host {
                FaviconLoader.shared.preloadFavicon(for: host)
            }
        }
    }

    func updateShortcutIcon(id: String, customIconData: Data?) {
        var items = loadShortcuts()
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].customIconData = customIconData
            saveShortcuts(items)
        }
    }

    func deleteShortcut(id: String) {
        var items = loadShortcuts()
        items.removeAll { $0.id == id }
        saveShortcuts(items)
    }

    func saveAllShortcuts(_ items: [HomeShortcutItem]) {
        saveShortcuts(items)
    }

    private func saveShortcuts(_ items: [HomeShortcutItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct CustomBottomSheetItem {
    let title: String
    var iconName: String? = nil
    var customImage: UIImage? = nil
    var isDestructive: Bool = false
    var isSwitchOn: Bool? = nil
    var dismissOnTap: Bool = true
    let handler: (() -> Void)?
    let longPressHandler: (() -> Void)?

    init(
        title: String,
        iconName: String? = nil,
        customImage: UIImage? = nil,
        isDestructive: Bool = false,
        isSwitchOn: Bool? = nil,
        dismissOnTap: Bool = true,
        handler: (() -> Void)?,
        longPressHandler: (() -> Void)? = nil
    ) {
        self.title = title
        self.iconName = iconName
        self.customImage = customImage
        self.isDestructive = isDestructive
        self.isSwitchOn = isSwitchOn
        self.dismissOnTap = dismissOnTap
        self.handler = handler
        self.longPressHandler = longPressHandler
    }
}

final class UserAgentStore {
    static let shared = UserAgentStore()
    private let keyCustomItems = "browser_ua_custom_items_v5"
    private let keySelectedMobileId = "browser_ua_selected_mobile_id_v6"
    private let keySelectedDesktopId = "browser_ua_selected_desktop_id_v6"
    private let keyCurrentMode = "browser_ua_current_mode_v6"

    private let defaultMobileItems: [UserAgentItem] = [
        UserAgentItem(
            id: "default_safari",
            name: "iPhone Safari",
            uaString: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
            isCustom: false,
            category: .mobile
        ),
        UserAgentItem(
            id: "default_chrome",
            name: "iPhone Chrome",
            uaString: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/125.0.6422.80 Mobile/15E148 Safari/604.1",
            isCustom: false,
            category: .mobile
        ),
        UserAgentItem(
            id: "default_ipad",
            name: "iPad Safari",
            uaString: "Mozilla/5.0 (iPad; CPU OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
            isCustom: false,
            category: .mobile
        ),
        UserAgentItem(
            id: "default_android_chrome",
            name: "Android Chrome",
            uaString: "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36",
            isCustom: false,
            category: .mobile
        )
    ]

    private let defaultDesktopItems: [UserAgentItem] = [
        UserAgentItem(
            id: "default_mac",
            name: "macOS Chrome",
            uaString: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            isCustom: false,
            category: .desktop
        ),
        UserAgentItem(
            id: "default_mac_safari",
            name: "macOS Safari",
            uaString: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15",
            isCustom: false,
            category: .desktop
        ),
        UserAgentItem(
            id: "default_win_chrome",
            name: "Windows Chrome",
            uaString: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            isCustom: false,
            category: .desktop
        ),
        UserAgentItem(
            id: "default_win_edge",
            name: "Windows Edge",
            uaString: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36 Edg/125.0.0.0",
            isCustom: false,
            category: .desktop
        )
    ]

    private init() {}

    var currentMode: UserAgentCategory {
        get {
            guard let raw = UserDefaults.standard.string(forKey: keyCurrentMode),
                  let cat = UserAgentCategory(rawValue: raw) else {
                return .mobile
            }
            return cat
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: keyCurrentMode)
        }
    }

    func loadMobileItems() -> [UserAgentItem] {
        return defaultMobileItems
    }

    func loadDesktopItems() -> [UserAgentItem] {
        return defaultDesktopItems
    }

    func loadCustomItems() -> [UserAgentItem] {
        if let data = UserDefaults.standard.data(forKey: keyCustomItems),
           let customs = try? JSONDecoder().decode([UserAgentItem].self, from: data) {
            return customs
        }
        return []
    }

    func loadAllItems() -> [UserAgentItem] {
        var items = defaultMobileItems + defaultDesktopItems
        items.append(contentsOf: loadCustomItems())
        return items
    }

    func addCustomItem(name: String, uaString: String, category: UserAgentCategory = .mobile) {
        var customs = loadCustomItems()
        let newItem = UserAgentItem(id: UUID().uuidString, name: name, uaString: uaString, isCustom: true, category: category)
        customs.append(newItem)
        if let data = try? JSONEncoder().encode(customs) {
            UserDefaults.standard.set(data, forKey: keyCustomItems)
        }
    }

    func updateCustomItem(id: String, name: String, uaString: String) {
        var customs = loadCustomItems()
        if let idx = customs.firstIndex(where: { $0.id == id }) {
            customs[idx].name = name
            customs[idx].uaString = uaString
            if let data = try? JSONEncoder().encode(customs) {
                UserDefaults.standard.set(data, forKey: keyCustomItems)
            }
        }
    }

    func deleteCustomItem(id: String) {
        var customs = loadCustomItems()
        customs.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(customs) {
            UserDefaults.standard.set(data, forKey: keyCustomItems)
        }
        if getSelectedMobileId() == id {
            setSelectedMobileId(defaultMobileItems[0].id)
        }
        if getSelectedDesktopId() == id {
            setSelectedDesktopId(defaultDesktopItems[0].id)
        }
    }

    func getSelectedMobileId() -> String {
        return UserDefaults.standard.string(forKey: keySelectedMobileId) ?? defaultMobileItems[0].id
    }

    func setSelectedMobileId(_ id: String) {
        UserDefaults.standard.set(id, forKey: keySelectedMobileId)
    }

    func getSelectedDesktopId() -> String {
        return UserDefaults.standard.string(forKey: keySelectedDesktopId) ?? defaultDesktopItems[0].id
    }

    func setSelectedDesktopId(_ id: String) {
        UserDefaults.standard.set(id, forKey: keySelectedDesktopId)
    }

    func getSelectedUA() -> String {
        let all = loadAllItems()
        let selId = (currentMode == .desktop) ? getSelectedDesktopId() : getSelectedMobileId()
        let defaultItem = (currentMode == .desktop) ? defaultDesktopItems[0] : defaultMobileItems[0]
        return all.first { $0.id == selId }?.uaString ?? defaultItem.uaString
    }

    func getSelectedItem() -> UserAgentItem {
        let all = loadAllItems()
        let selId = (currentMode == .desktop) ? getSelectedDesktopId() : getSelectedMobileId()
        let defaultItem = (currentMode == .desktop) ? defaultDesktopItems[0] : defaultMobileItems[0]
        return all.first { $0.id == selId } ?? defaultItem
    }
}

final class EyeProtectionManager {
    static let shared = EyeProtectionManager()

    private let enabledKey = "eye_protection_enabled_v1"
    private let levelKey = "eye_protection_level_v2"
    private var overlayView: UIView?

    enum Level: Int, CaseIterable {
        case low = 0
        case medium = 1
        case high = 2

        var alpha: CGFloat {
            switch self {
            case .low:
                return 0.245
            case .medium:
                return 0.35
            case .high:
                return 0.455
            }
        }

        var title: String {
            switch self {
            case .low:
                return "低强度"
            case .medium:
                return "中强度"
            case .high:
                return "高强度"
            }
        }
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    var level: Level {
        get {
            Level(rawValue: UserDefaults.standard.integer(forKey: levelKey)) ?? .medium
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: levelKey)
        }
    }

    private init() {}

    func restoreState(in window: UIWindow?) {
        guard isEnabled else { return }
        applyOverlay(in: window)
    }

    func toggle(in window: UIWindow?) {
        isEnabled.toggle()
        if isEnabled {
            applyOverlay(in: window)
        } else {
            removeOverlay()
        }
    }

    func setLevel(_ newLevel: Level, in window: UIWindow?) {
        level = newLevel
        isEnabled = true
        applyOverlay(in: window)
    }

    private func applyOverlay(in window: UIWindow?) {
        removeOverlay()
        guard let window = window else { return }
        let overlay = UIView(frame: window.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.black.withAlphaComponent(level.alpha)
        overlay.isUserInteractionEnabled = false
        window.addSubview(overlay)
        overlayView = overlay
    }

    private func removeOverlay() {
        overlayView?.removeFromSuperview()
        overlayView = nil
    }
}

final class DomainSettingsStore {
    static let shared = DomainSettingsStore()
    private init() {}

    private func makeKey(_ domain: String, _ setting: String) -> String {
        return "DOMAIN_SETTING_\(domain.lowercased())_\(setting)"
    }

    func getBool(domain: String, setting: String, defaultVal: Bool = true) -> Bool {
        let k = makeKey(domain, setting)
        if UserDefaults.standard.object(forKey: k) == nil {
            return defaultVal
        }
        return UserDefaults.standard.bool(forKey: k)
    }

    func setBool(domain: String, setting: String, value: Bool) {
        UserDefaults.standard.set(value, forKey: makeKey(domain, setting))
    }
}

// MARK: - Cookie 与网站登录数据锁定管理器 (支持单个域名精确独立锁定，清理时保护登录凭据)

final class CookieLockStore {
    static let shared = CookieLockStore()
    private let key = "locked_cookie_domains_v2"

    private init() {}

    func getLockedDomains() -> [String] {
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// 严格精确匹配：针对 UI 显示与单个域名的独立锁定状态，绝不隐式强制连带其他域名
    func isLocked(domain: String) -> Bool {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !clean.isEmpty else { return false }
        let locked = getLockedDomains().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return locked.contains(clean)
    }

    /// 登录凭据保护判定：用于清理时识别该 Cookie 是否属于用户锁定的网站认证范围
    func isCookieProtected(cookieDomain: String) -> Bool {
        let locked = getLockedDomains().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        if locked.isEmpty { return false }
        let cleanCookie = cookieDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !cleanCookie.isEmpty else { return false }

        for l in locked {
            // 1. 完全精确匹配
            if cleanCookie == l { return true }
            // 2. Cookie 属于锁定站点的父域或主域（例如锁定 accounts.google.com，保护 .google.com 的核心认证 Cookie）
            if l.hasSuffix("." + cleanCookie) { return true }
            // 3. Cookie 属于锁定站点的子域（例如锁定 google.com，保护 accounts.google.com 的 Cookie）
            if cleanCookie.hasSuffix("." + l) { return true }
            // 4. 同一主根域保护（例如锁定 google.com，保护 accounts.google.com 的 Cookie）
            let r1 = DomainRelationEngine.rootDomain(of: cleanCookie)
            let r2 = DomainRelationEngine.rootDomain(of: l)
            if !r1.isEmpty && r1 == r2 { return true }
            // 5. 伴随认证关联（如 gstatic.com / google.com）
            if DomainRelationEngine.areDomainsAssociated(cleanCookie, l) { return true }
        }
        return false
    }

    /// 登录记录保护判定：用于清理 WKWebsiteDataRecord 时识别是否包含受保护登录数据
    func isRecordLoginProtected(recordDisplayName: String) -> Bool {
        let cleanName = recordDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !cleanName.isEmpty else { return false }
        let locked = getLockedDomains().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }

        for l in locked {
            if cleanName == l { return true }
            if l.hasSuffix("." + cleanName) || cleanName.hasSuffix("." + l) { return true }
            let r1 = DomainRelationEngine.rootDomain(of: cleanName)
            let r2 = DomainRelationEngine.rootDomain(of: l)
            if !r1.isEmpty && r1 == r2 { return true }
            if DomainRelationEngine.areDomainsAssociated(cleanName, l) { return true }
        }
        return false
    }

    func lock(domain: String) {
        var locked = getLockedDomains()
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if !clean.isEmpty && !locked.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == clean }) {
            locked.append(clean)
            UserDefaults.standard.set(locked, forKey: key)
        }
    }

    func unlock(domain: String) {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var locked = getLockedDomains()
        locked.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == clean }
        UserDefaults.standard.set(locked, forKey: key)
    }

    func toggleLock(domain: String) {
        if isLocked(domain: domain) {
            unlock(domain: domain)
        } else {
            lock(domain: domain)
        }
    }

    func lockAll(domains: [String]) {
        for d in domains {
            lock(domain: d)
        }
    }

    func unlockAll(domains: [String]) {
        for d in domains {
            unlock(domain: d)
        }
    }
}

final class SearchHistoryStore {
    static let shared = SearchHistoryStore()
    private let key = "browser_search_history_v1"

    private init() {}

    func getHistory() -> [String] {
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func addHistory(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = getHistory()
        history.removeAll { $0 == trimmed }
        history.insert(trimmed, at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
        UserDefaults.standard.set(history, forKey: key)
    }

    func clearHistory() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

struct BrowserHistoryItem: Codable, Equatable {
    var id: String
    var title: String
    var urlString: String
    var visitedAt: Date
}

final class BrowserHistoryStore {
    static let shared = BrowserHistoryStore()

    private let key = "browser_visit_history_v1"
    private let maximumCount = 500

    private init() {}

    func loadHistory() -> [BrowserHistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([BrowserHistoryItem].self, from: data) else {
            return []
        }
        return items
    }

    func record(url: URL, title: String) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            return
        }

        if let host = url.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }

        var items = loadHistory()
        let urlString = url.absoluteString
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (url.host ?? urlString)
            : title

        items.removeAll { $0.urlString == urlString }
        items.insert(
            BrowserHistoryItem(
                id: UUID().uuidString,
                title: resolvedTitle,
                urlString: urlString,
                visitedAt: Date()
            ),
            at: 0
        )

        if items.count > maximumCount {
            items = Array(items.prefix(maximumCount))
        }

        saveHistory(items)
    }

    func delete(id: String) {
        var items = loadHistory()
        items.removeAll { $0.id == id }
        saveHistory(items)
    }

    func clearHistory() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func saveHistory(_ items: [BrowserHistoryItem]) {
        guard let data = try? JSONEncoder().encode(items) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct BrowserTabSessionItem: Codable {
    var urlString: String?
    var title: String
}

struct BrowserSession: Codable {
    var tabs: [BrowserTabSessionItem]
    var activeIndex: Int
}

final class BrowserSessionStore {
    static let shared = BrowserSessionStore()

    private let key = "browser_tab_session_v1"
    private let maximumTabCount = 30

    private init() {}

    func loadSession() -> BrowserSession? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let session = try? JSONDecoder().decode(BrowserSession.self, from: data),
              !session.tabs.isEmpty else {
            return nil
        }
        return session
    }

    func saveSession(tabs: [BrowserTabSessionItem], activeIndex: Int) {
        let limitedTabs = Array(tabs.prefix(maximumTabCount))
        guard !limitedTabs.isEmpty else {
            clearSession()
            return
        }

        let safeIndex = min(max(0, activeIndex), limitedTabs.count - 1)
        let session = BrowserSession(tabs: limitedTabs, activeIndex: safeIndex)

        guard let data = try? JSONEncoder().encode(session) else {
            return
        }

        UserDefaults.standard.set(data, forKey: key)
    }

    func clearSession() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

final class UserScriptStore {
    static let shared = UserScriptStore()
    private let key = "user_tampermonkey_scripts_v5"

    private init() {}

    func loadScripts() -> [UserScript] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let scripts = try? JSONDecoder().decode([UserScript].self, from: data) else {
            return []
        }
        return scripts
    }

    func saveScripts(_ scripts: [UserScript]) {
        if let data = try? JSONEncoder().encode(scripts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func parseMetadata(from code: String) -> (name: String, match: String) {
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
            let val = components.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)

            if tag.hasPrefix("@name") {
                nameMap[tag] = val
            } else if tag == "@match" || tag == "@include" {
                if !val.isEmpty && !matches.contains(val) {
                    matches.append(val)
                }
            }
        }

        let preferredName = nameMap["@name:zh-CN"] ?? nameMap["@name:zh"] ?? nameMap["@name:zh-TW"] ?? nameMap["@name"] ?? "未命名脚本"
        let preferredMatch = matches.isEmpty ? "*" : matches.joined(separator: ", ")

        return (preferredName, preferredMatch)
    }

    func isScriptMatching(script: UserScript, urlString: String) -> Bool {
        guard script.isEnabled else { return false }

        if let url = URL(string: urlString), let host = url.host {
            let scriptEnabled = DomainSettingsStore.shared.getBool(domain: host, setting: "userScripts", defaultVal: true)
            if !scriptEnabled { return false }
        }

        let rawPatterns = script.matchPattern.components(separatedBy: CharacterSet(charactersIn: ",\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if rawPatterns.isEmpty || rawPatterns.contains("*") || rawPatterns.contains("<all_urls>") {
            return true
        }

        guard let url = URL(string: urlString), let host = url.host?.lowercased() else {
            return false
        }

        for pattern in rawPatterns {
            if pattern == "*" || pattern == "<all_urls>" {
                return true
            }

            var p = pattern.lowercased()
            if let schemeRange = p.range(of: "://") {
                p = String(p[schemeRange.upperBound...])
            }
            if let slashIndex = p.firstIndex(of: "/") {
                p = String(p[..<slashIndex])
            }
            p = p.trimmingCharacters(in: .whitespaces)

            if p == "*" || p.isEmpty {
                return true
            }

            if p.hasPrefix("*.") {
                let suffix = String(p.dropFirst(2))
                if host == suffix || host.hasSuffix("." + suffix) {
                    return true
                }
            } else if p.hasPrefix("*") {
                let suffix = String(p.dropFirst(1))
                if host.hasSuffix(suffix) {
                    return true
                }
            } else {
                if host == p || host.hasSuffix("." + p) {
                    return true
                }
            }
        }

        return false
    }
}

final class ScriptDataStore {
    static let shared = ScriptDataStore()
    private init() {}

    private func makeKey(_ scriptId: String, _ name: String) -> String {
        return "GM_DATA_\(scriptId)_\(name)"
    }

    func getValue(scriptId: String, name: String) -> Any? {
        return UserDefaults.standard.object(forKey: makeKey(scriptId, name))
    }

    func setValue(scriptId: String, name: String, value: Any) {
        UserDefaults.standard.set(value, forKey: makeKey(scriptId, name))
    }

    func deleteValue(scriptId: String, name: String) {
        UserDefaults.standard.removeObject(forKey: makeKey(scriptId, name))
    }

    func clearDataForScript(scriptId: String) {
        let prefix = "GM_DATA_\(scriptId)_"
        for (k, _) in UserDefaults.standard.dictionaryRepresentation() {
            if k.hasPrefix(prefix) {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
    }

    func clearAllScriptData() {
        let prefix = "GM_DATA_"
        for (k, _) in UserDefaults.standard.dictionaryRepresentation() {
            if k.hasPrefix(prefix) {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
    }

    func getAllValuesJSON(scriptId: String) -> String {
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

// MARK: - 严密网站数据清理引擎 (网页缓存彻底清空，登录凭据受锁定保护)

final class WebsiteCleaner {
    static let shared = WebsiteCleaner()
    private init() {}

    static let cacheDataTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
        WKWebsiteDataTypeFetchCache
    ]

    static let nonCookieLoginDataTypes: Set<String> = [
        WKWebsiteDataTypeLocalStorage,
        WKWebsiteDataTypeIndexedDBDatabases,
        WKWebsiteDataTypeWebSQLDatabases,
        WKWebsiteDataTypeSessionStorage
    ]

    func clean(
        cache: Bool,
        loginAndData: Bool,
        completion: (() -> Void)? = nil
    ) {
        // 1. 系统 URL 缓存彻底清理
        URLCache.shared.removeAllCachedResponses()

        let store = WKWebsiteDataStore.default()
        let group = DispatchGroup()

        // 2. 勾选了网页缓存：所有网站（无论是否锁定）的网页缓存、图片临时文件全部无差别彻底清空！
        if cache {
            group.enter()
            store.removeData(ofTypes: Self.cacheDataTypes, modifiedSince: .distantPast) {
                group.leave()
            }
        }

        // 3. 勾选了登录与本地数据：严格识别锁定名单，锁定的网站保留其登录 Cookies 和本地数据库，未锁定的予以清除
        if loginAndData {
            group.enter()

            // 清理系统 HTTPCookieStorage（排除锁定的 Cookie）
            if let sharedCookies = HTTPCookieStorage.shared.cookies {
                for c in sharedCookies {
                    if !CookieLockStore.shared.isCookieProtected(cookieDomain: c.domain) {
                        HTTPCookieStorage.shared.deleteCookie(c)
                    }
                }
            }

            // 获取 WebKit 记录并按锁定状态精准过滤（绝对不将 WKWebsiteDataTypeCookies 传给 removeData，避免 WebKit 底层级联清空 Cookie Jar）
            store.fetchDataRecords(ofTypes: Self.nonCookieLoginDataTypes) { records in
                let unprotectedRecords = records.filter { record in
                    !CookieLockStore.shared.isRecordLoginProtected(recordDisplayName: record.displayName)
                }

                let subGroup = DispatchGroup()

                if !unprotectedRecords.isEmpty {
                    subGroup.enter()
                    store.removeData(ofTypes: Self.nonCookieLoginDataTypes, for: unprotectedRecords) {
                        subGroup.leave()
                    }
                }

                // 逐个匹配清理 CookieStore，受保护登录凭据完整留存
                subGroup.enter()
                store.httpCookieStore.getAllCookies { cookies in
                    let cookieGroup = DispatchGroup()
                    for c in cookies {
                        if !CookieLockStore.shared.isCookieProtected(cookieDomain: c.domain) {
                            cookieGroup.enter()
                            store.httpCookieStore.delete(c) {
                                cookieGroup.leave()
                            }
                        }
                    }
                    cookieGroup.notify(queue: .main) {
                        subGroup.leave()
                    }
                }

                subGroup.notify(queue: .main) {
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            completion?()
        }
    }

    func cleanCacheOnly(completion: (() -> Void)? = nil) {
        clean(cache: true, loginAndData: false, completion: completion)
    }

    func cleanUnprotectedLoginAndData(completion: (() -> Void)? = nil) {
        clean(cache: true, loginAndData: true, completion: completion)
    }

    func cleanSingleDomain(record: WKWebsiteDataRecord, cacheOnly: Bool, completion: (() -> Void)? = nil) {
        let store = WKWebsiteDataStore.default()

        if cacheOnly {
            store.removeData(ofTypes: Self.cacheDataTypes, for: [record]) {
                DispatchQueue.main.async {
                    completion?()
                }
            }
        } else {
            let nonCookieTypes = Self.nonCookieLoginDataTypes.union(Self.cacheDataTypes)
            store.removeData(ofTypes: nonCookieTypes, for: [record]) {
                store.httpCookieStore.getAllCookies { cookies in
                    let group = DispatchGroup()
                    for c in cookies where !CookieLockStore.shared.isCookieProtected(cookieDomain: c.domain) &&
                                          (c.domain.contains(record.displayName) || record.displayName.contains(c.domain)) {
                        group.enter()
                        store.httpCookieStore.delete(c) {
                            group.leave()
                        }
                    }
                    group.notify(queue: .main) {
                        completion?()
                    }
                }
            }
        }
    }
}

// MARK: - 高画质网站图标引擎 (原生 Apple Touch Icon、高可用多源并发竞速与双向缓存)

final class FaviconLoader {
    static let shared = FaviconLoader()
    private let cache = NSCache<NSString, UIImage>()
    private let diskCacheURL: URL = {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("FaviconDiskCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    private var inFlightMap: [String: [(UIImage?) -> Void]] = [:]
    private let mapLock = NSLock()

    private init() {
        cache.countLimit = 300
    }

    private func diskPath(for cleanDomain: String) -> URL {
        let safeName = cleanDomain.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return diskCacheURL.appendingPathComponent("\(safeName).png")
    }

    func cachedFavicon(for domain: String) -> UIImage? {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return nil }

        if let img = memoryOrDiskImage(for: clean) {
            return img
        }

        if clean.hasPrefix("www.") {
            let noWww = String(clean.dropFirst(4))
            if let img = memoryOrDiskImage(for: noWww) {
                cache.setObject(img, forKey: clean as NSString)
                return img
            }
        } else {
            let withWww = "www." + clean
            if let img = memoryOrDiskImage(for: withWww) {
                cache.setObject(img, forKey: clean as NSString)
                return img
            }
        }

        let root = DomainRelationEngine.rootDomain(of: clean)
        if root != clean && !root.isEmpty, let img = memoryOrDiskImage(for: root) {
            cache.setObject(img, forKey: clean as NSString)
            return img
        }

        return nil
    }

    private func memoryOrDiskImage(for domainKey: String) -> UIImage? {
        if let cached = cache.object(forKey: domainKey as NSString) {
            return cached
        }
        let fileURL = diskPath(for: domainKey)
        if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
            cache.setObject(image, forKey: domainKey as NSString)
            return image
        }
        return nil
    }

    func saveHighResIcon(data: Data, for domain: String) {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty, let image = UIImage(data: data) else { return }

        var domainsToSave: Set<String> = [clean]
        let root = DomainRelationEngine.rootDomain(of: clean)
        if !root.isEmpty { domainsToSave.insert(root) }
        if clean.hasPrefix("www.") {
            domainsToSave.insert(String(clean.dropFirst(4)))
        } else {
            domainsToSave.insert("www." + clean)
        }

        for d in domainsToSave {
            cache.setObject(image, forKey: d as NSString)
            let fileURL = diskPath(for: d)
            try? data.write(to: fileURL)
        }
    }

    func preloadFavicon(for domain: String) {
        loadFavicon(for: domain) { _ in }
    }

    func loadFavicon(for domain: String, completion: @escaping (UIImage?) -> Void) {
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanDomain.isEmpty else {
            completion(nil)
            return
        }

        if let cached = cachedFavicon(for: cleanDomain) {
            completion(cached)
            return
        }

        mapLock.lock()
        if inFlightMap[cleanDomain] != nil {
            inFlightMap[cleanDomain]?.append(completion)
            mapLock.unlock()
            return
        }
        inFlightMap[cleanDomain] = [completion]
        mapLock.unlock()

        let root = DomainRelationEngine.rootDomain(of: cleanDomain)

        var candidateURLs: [String] = []
        candidateURLs.append("https://\(cleanDomain)/apple-touch-icon.png")
        candidateURLs.append("https://\(cleanDomain)/favicon.ico")
        if root != cleanDomain && !root.isEmpty {
            candidateURLs.append("https://\(root)/apple-touch-icon.png")
            candidateURLs.append("https://\(root)/favicon.ico")
        }
        // 高速国内免翻墙 CDN 聚合源（优先极速返回高质量图标）
        candidateURLs.append("https://api.iowen.cn/favicon/\(cleanDomain).png")
        candidateURLs.append("https://favicon.im/\(cleanDomain)?larger=true")
        if root != cleanDomain && !root.isEmpty {
            candidateURLs.append("https://api.iowen.cn/favicon/\(root).png")
        }
        // 国际备用源
        candidateURLs.append("https://www.google.com/s2/favicons?sz=128&domain=\(cleanDomain)")

        performConcurrentFetch(cleanDomain: cleanDomain, urls: candidateURLs)
    }

    private func performConcurrentFetch(cleanDomain: String, urls: [String]) {
        var isFinished = false
        var bestImage: UIImage?
        var bestData: Data?
        let session = URLSession.shared
        let lock = NSLock()
        let group = DispatchGroup()

        func finish(with image: UIImage?, data: Data?) {
            lock.lock()
            if isFinished {
                lock.unlock()
                return
            }
            isFinished = true
            lock.unlock()

            if let data = data, image != nil {
                self.saveHighResIcon(data: data, for: cleanDomain)
            }

            self.mapLock.lock()
            let callbacks = self.inFlightMap.removeValue(forKey: cleanDomain) ?? []
            self.mapLock.unlock()

            DispatchQueue.main.async {
                for cb in callbacks {
                    cb(image)
                }
            }
        }

        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            group.enter()

            var req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 3.2)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

            session.dataTask(with: req) { data, response, _ in
                defer { group.leave() }

                lock.lock()
                if isFinished {
                    lock.unlock()
                    return
                }
                lock.unlock()

                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let data = data, data.count > 100,
                      let img = UIImage(data: data), img.size.width >= 16 else {
                    return
                }

                if img.size.width >= 48 {
                    finish(with: img, data: data)
                    return
                }

                lock.lock()
                if bestImage == nil {
                    bestImage = img
                    bestData = data
                }
                lock.unlock()
            }.resume()
        }

        group.notify(queue: .global()) {
            lock.lock()
            let finalImage = bestImage
            let finalData = bestData
            let done = isFinished
            lock.unlock()

            if !done {
                finish(with: finalImage, data: finalData)
            }
        }
    }
}

// MARK: - 完整浏览器数据备份与恢复引擎

struct BrowserBackupPackage: Codable {
    var version: Int
    var exportedAt: Date
    var appName: String
    var bookmarks: [BookmarkItem]
    var homeShortcuts: [HomeShortcutItem]
    var userScripts: [UserScript]
    var scriptData: [String: String]
    var customUserAgents: [UserAgentItem]
    var adBlockSubscriptions: [AdBlockSubscription]
    var customAdBlockRules: String
    var lockedCookieDomains: [String]
    var searchEngine: String
}

final class BackupManager {
    static let shared = BackupManager()
    private init() {}

    func createBackupPackage() -> BrowserBackupPackage {
        let bookmarks = BookmarkStore.shared.loadAllNodes()
        let shortcuts = HomeShortcutStore.shared.loadShortcuts()
        let scripts = UserScriptStore.shared.loadScripts()

        var scriptDataMap: [String: String] = [:]
        for script in scripts {
            let json = ScriptDataStore.shared.getAllValuesJSON(scriptId: script.id)
            if json != "{}" {
                scriptDataMap[script.id] = json
            }
        }

        let customUAs = UserAgentStore.shared.loadCustomItems()
        let subscriptions = AdBlockManager.shared.loadSubscriptions()
        let customRules = AdBlockManager.shared.getCustomRules()
        let lockedDomains = CookieLockStore.shared.getLockedDomains()
        let searchEngine = SearchEngineStore.shared.currentEngine.rawValue

        return BrowserBackupPackage(
            version: 1,
            exportedAt: Date(),
            appName: "SimpleBrowser",
            bookmarks: bookmarks,
            homeShortcuts: shortcuts,
            userScripts: scripts,
            scriptData: scriptDataMap,
            customUserAgents: customUAs,
            adBlockSubscriptions: subscriptions,
            customAdBlockRules: customRules,
            lockedCookieDomains: lockedDomains,
            searchEngine: searchEngine
        )
    }

    func exportBackupFile() throws -> URL {
        let package = createBackupPackage()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(package)

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = df.string(from: Date())
        let filename = "SimpleBrowser_Backup_\(timestamp).json"

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: tempURL, options: .atomic)
        return tempURL
    }

    func restore(from fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(BrowserBackupPackage.self, from: data)

        // 1. 恢复书签
        BookmarkStore.shared.saveAllNodes(package.bookmarks)

        // 2. 恢复主页快捷方式（含自定义图标）
        HomeShortcutStore.shared.saveAllShortcuts(package.homeShortcuts)

        // 3. 恢复用户脚本
        UserScriptStore.shared.saveScripts(package.userScripts)

        // 4. 恢复脚本数据
        for (scriptId, jsonStr) in package.scriptData {
            if let data = jsonStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in dict {
                    ScriptDataStore.shared.setValue(scriptId: scriptId, name: k, value: v)
                }
            }
        }

        // 5. 恢复自定义 UA
        if let dataUA = try? JSONEncoder().encode(package.customUserAgents) {
            UserDefaults.standard.set(dataUA, forKey: "browser_ua_custom_items_v5")
        }

        // 6. 恢复广告拦截规则订阅与自定义规则
        AdBlockManager.shared.saveSubscriptions(package.adBlockSubscriptions)
        UserDefaults.standard.set(package.customAdBlockRules, forKey: "adblock_custom_rules_v2")

        // 7. 恢复锁定域名
        UserDefaults.standard.set(package.lockedCookieDomains, forKey: "locked_cookie_domains_v2")

        // 8. 恢复搜索引擎
        if let engine = SearchEngine(rawValue: package.searchEngine) {
            SearchEngineStore.shared.currentEngine = engine
        }
    }
}
