import UIKit
import UniformTypeIdentifiers

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

    func saveAllHistory(_ items: [BrowserHistoryItem]) {
        saveHistory(items)
    }

    private func saveHistory(_ items: [BrowserHistoryItem]) {
        guard let data = try? JSONEncoder().encode(items) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct HistorySection {
    let title: String
    let items: [BrowserHistoryItem]
}

final class BrowserHistoryViewController: UITableViewController, UISearchResultsUpdating, UIDocumentPickerDelegate {
    private var allHistoryItems: [BrowserHistoryItem] = []
    private var currentFolderNodes: [BookmarkItem] = []
    private var sections: [HistorySection] = []

    private var currentSegment: Int = 0
    private let folderId: String?
    private let folderTitle: String?

    private let searchController = UISearchController(searchResultsController: nil)
    private let segmentedControl = UISegmentedControl(items: ["书签", "历史"])

    var onSelectURL: ((URL) -> Void)?

    init(initialSegment: Int = 0, folderId: String? = nil, folderTitle: String? = nil) {
        self.currentSegment = initialSegment
        self.folderId = folderId
        self.folderTitle = folderTitle
        super.init(style: .insetGrouped)
    }

    convenience init() {
        self.init(initialSegment: 0, folderId: nil, folderTitle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()

        segmentedControl.selectedSegmentIndex = currentSegment
        segmentedControl.addTarget(self, action: #selector(handleSegmentChange(_:)), for: .valueChanged)

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "BrowserRecordCell")

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = currentSegment == 0 ? "搜索书签" : "搜索历史记录"

        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false

        updateNavigationBars()
        loadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadData()
    }

    private func updateNavigationBars() {
        if let folderTitle = folderTitle {
            title = folderTitle
            navigationItem.titleView = nil

            let addMenu = UIMenu(title: "", children: [
                UIAction(title: "新建子文件夹", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
                    self?.promptCreateFolder()
                },
                UIAction(title: "添加书签", image: UIImage(systemName: "bookmark.circle")) { [weak self] _ in
                    self?.promptAddBookmark()
                }
            ])
            let addButtonItem = UIBarButtonItem(image: UIImage(systemName: "plus"), menu: addMenu)

            let moreMenu = UIMenu(title: "", children: [
                UIAction(title: "导出 HTML 书签", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    self?.exportAlookBookmarks()
                },
                UIAction(title: "清空此文件夹", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.confirmClearCurrentFolder()
                }
            ])
            let moreButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: moreMenu)

            navigationItem.rightBarButtonItems = [moreButtonItem, addButtonItem]
        } else if currentSegment == 0 {
            title = nil
            navigationItem.titleView = segmentedControl
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: "完成",
                style: .done,
                target: self,
                action: #selector(handleClose)
            )

            let addMenu = UIMenu(title: "", children: [
                UIAction(title: "新建文件夹", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
                    self?.promptCreateFolder()
                },
                UIAction(title: "添加书签", image: UIImage(systemName: "bookmark.circle")) { [weak self] _ in
                    self?.promptAddBookmark()
                }
            ])
            let addButtonItem = UIBarButtonItem(image: UIImage(systemName: "plus"), menu: addMenu)

            let moreMenu = UIMenu(title: "", children: [
                UIAction(title: "导出 HTML 书签", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    self?.exportAlookBookmarks()
                },
                UIAction(title: "导入 HTML 书签", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                    self?.importAlookBookmarks()
                },
                UIAction(title: "清空所有书签", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.confirmClearBookmarks()
                }
            ])
            let moreButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: moreMenu)

            navigationItem.rightBarButtonItems = [moreButtonItem, addButtonItem]
        } else {
            title = nil
            navigationItem.titleView = segmentedControl
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: "完成",
                style: .done,
                target: self,
                action: #selector(handleClose)
            )
            navigationItem.rightBarButtonItems = [
                UIBarButtonItem(
                    title: "清空",
                    style: .plain,
                    target: self,
                    action: #selector(confirmClearHistory)
                )
            ]
        }
    }

    @objc private func handleSegmentChange(_ sender: UISegmentedControl) {
        currentSegment = sender.selectedSegmentIndex
        searchController.searchBar.placeholder = currentSegment == 0 ? "搜索书签" : "搜索历史记录"
        updateNavigationBars()
        loadData()
    }

    private func loadData() {
        let query = searchController.searchBar.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if currentSegment == 0 {
            if query.isEmpty {
                currentFolderNodes = BookmarkStore.shared.getNodes(inParent: folderId)
            } else {
                currentFolderNodes = BookmarkStore.shared.loadAllNodes().filter {
                    $0.title.lowercased().contains(query) || $0.urlString.lowercased().contains(query)
                }
            }
            tableView.reloadData()
        } else {
            allHistoryItems = BrowserHistoryStore.shared.loadHistory()
            filterAndGroupHistory(query: query)
        }
    }

    private func filterAndGroupHistory(query: String) {
        let filtered: [BrowserHistoryItem]
        if query.isEmpty {
            filtered = allHistoryItems
        } else {
            filtered = allHistoryItems.filter {
                $0.title.lowercased().contains(query) ||
                $0.urlString.lowercased().contains(query)
            }
        }

        var todayItems: [BrowserHistoryItem] = []
        var yesterdayItems: [BrowserHistoryItem] = []
        var earlierItems: [BrowserHistoryItem] = []

        let calendar = Calendar.current

        for item in filtered {
            if calendar.isDateInToday(item.visitedAt) {
                todayItems.append(item)
            } else if calendar.isDateInYesterday(item.visitedAt) {
                yesterdayItems.append(item)
            } else {
                earlierItems.append(item)
            }
        }

        var newSections: [HistorySection] = []
        if !todayItems.isEmpty {
            newSections.append(HistorySection(title: "今天", items: todayItems))
        }
        if !yesterdayItems.isEmpty {
            newSections.append(HistorySection(title: "昨天", items: yesterdayItems))
        }
        if !earlierItems.isEmpty {
            newSections.append(HistorySection(title: "更早", items: earlierItems))
        }

        self.sections = newSections
        tableView.reloadData()
    }

    @objc private func handleClose() {
        dismiss(animated: true)
    }

    private func promptCreateFolder() {
        let alert = UIAlertController(title: folderId == nil ? "新建文件夹" : "新建子文件夹", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "文件夹名称"
            tf.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "创建", style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            _ = BookmarkStore.shared.createFolder(title: name, parentId: self?.folderId)
            self?.loadData()
        })
        present(alert, animated: true)
    }

    private func promptAddBookmark() {
        let alert = UIAlertController(title: "添加书签", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "书签名称"
            tf.clearButtonMode = .whileEditing
        }
        alert.addTextField { tf in
            tf.placeholder = "网址"
            tf.keyboardType = .URL
            tf.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "添加", style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?[0].text,
                  let urlStr = alert?.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !urlStr.isEmpty else { return }
            let resolvedUrl = (urlStr.hasPrefix("http://") || urlStr.hasPrefix("https://")) ? urlStr : "https://" + urlStr
            BookmarkStore.shared.addBookmark(title: name, urlString: resolvedUrl, parentId: self?.folderId)
            self?.loadData()
        })
        present(alert, animated: true)
    }

    private func exportAlookBookmarks() {
        let htmlContent = BookmarkStore.shared.exportToAlookHTML()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("bookmarks.html")
        do {
            try htmlContent.write(to: tempURL, atomically: true, encoding: .utf8)
            let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            present(activityVC, animated: true)
        } catch {
            let alert = UIAlertController(title: "导出失败", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好的", style: .default))
            present(alert, animated: true)
        }
    }

    private func importAlookBookmarks() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.html, .plainText], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let shouldStopAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if let data = try? Data(contentsOf: url),
           let htmlString = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
            BookmarkStore.shared.importFromAlookHTML(htmlString)
            loadData()
            let alert = UIAlertController(title: "导入成功", message: "书签与文件夹已成功导入", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好的", style: .default))
            present(alert, animated: true)
        } else {
            let alert = UIAlertController(title: "导入失败", message: "无法读取书签 HTML 文件内容", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好的", style: .default))
            present(alert, animated: true)
        }
    }

    private func confirmClearBookmarks() {
        let alert = UIAlertController(title: "清空书签", message: "确定要清空全部收藏的书签和文件夹吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            BookmarkStore.shared.clearBookmarks()
            self?.loadData()
        })
        present(alert, animated: true)
    }

    private func confirmClearCurrentFolder() {
        guard let fId = folderId else { return }
        let alert = UIAlertController(title: "清空文件夹", message: "确定要删除此文件夹中的所有内容吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            let children = BookmarkStore.shared.getNodes(inParent: fId)
            for child in children {
                BookmarkStore.shared.deleteNode(id: child.id)
            }
            self?.loadData()
        })
        present(alert, animated: true)
    }

    @objc private func confirmClearHistory() {
        let alert = UIAlertController(title: "清空历史记录", message: "确定要清空全部浏览历史记录吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            BrowserHistoryStore.shared.clearHistory()
            self?.loadData()
        })
        present(alert, animated: true)
    }

    func updateSearchResults(for searchController: UISearchController) {
        loadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        if currentSegment == 0 {
            return 1
        }
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if currentSegment == 0 {
            return currentFolderNodes.count
        }
        return sections[section].items.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if currentSegment == 0 {
            if !currentFolderNodes.isEmpty && folderId == nil {
                return "我的书签"
            }
            return nil
        }
        return sections[section].title
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: "BrowserRecordCell",
            for: indexPath
        )

        var content = cell.defaultContentConfiguration()

        if currentSegment == 0 {
            let item = currentFolderNodes[indexPath.row]
            content.text = item.title
            content.textProperties.numberOfLines = 1

            if item.isFolder {
                let count = BookmarkStore.shared.countChildren(of: item.id)
                content.secondaryText = "\(count) 个项目"
                content.secondaryTextProperties.numberOfLines = 1
                content.image = UIImage(systemName: "folder.fill")
                content.imageProperties.tintColor = .systemYellow
                content.imageProperties.maximumSize = CGSize(width: 24, height: 24)
                cell.accessoryType = .disclosureIndicator
            } else {
                content.secondaryText = item.urlString
                content.secondaryTextProperties.numberOfLines = 1

                let host = URL(string: item.urlString)?.host ?? ""
                if let cached = FaviconLoader.shared.cachedFavicon(for: host) {
                    content.image = cached
                    content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
                    content.imageProperties.cornerRadius = 4
                } else {
                    content.image = UIImage(systemName: "bookmark.fill")
                    content.imageProperties.tintColor = .systemBlue
                    content.imageProperties.maximumSize = CGSize(width: 22, height: 22)

                    if !host.isEmpty {
                        FaviconLoader.shared.loadFavicon(for: host) { [weak tableView] image in
                            guard let image = image else { return }
                            DispatchQueue.main.async {
                                if let currentCell = tableView?.cellForRow(at: indexPath) {
                                    var updatedContent = currentCell.defaultContentConfiguration()
                                    updatedContent.text = item.title
                                    updatedContent.secondaryText = item.urlString
                                    updatedContent.secondaryTextProperties.numberOfLines = 1
                                    updatedContent.textProperties.numberOfLines = 1
                                    updatedContent.image = image
                                    updatedContent.imageProperties.maximumSize = CGSize(width: 22, height: 22)
                                    updatedContent.imageProperties.cornerRadius = 4
                                    currentCell.contentConfiguration = updatedContent
                                }
                            }
                        }
                    }
                }
                cell.accessoryType = .none
            }
        } else {
            let item = sections[indexPath.section].items[indexPath.row]
            content.text = item.title
            content.secondaryText = "\(item.urlString)\n\(formattedDate(item.visitedAt))"
            content.secondaryTextProperties.numberOfLines = 2
            content.textProperties.numberOfLines = 1

            let host = URL(string: item.urlString)?.host ?? ""
            if let cached = FaviconLoader.shared.cachedFavicon(for: host) {
                content.image = cached
                content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
                content.imageProperties.cornerRadius = 4
            } else {
                content.image = UIImage(systemName: "globe")
                content.imageProperties.tintColor = .secondaryLabel
                content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
                content.imageProperties.cornerRadius = 4

                if !host.isEmpty {
                    FaviconLoader.shared.loadFavicon(for: host) { [weak tableView] image in
                        guard let image = image else { return }
                        DispatchQueue.main.async {
                            if let currentCell = tableView?.cellForRow(at: indexPath) {
                                var updatedContent = currentCell.defaultContentConfiguration()
                                updatedContent.text = item.title
                                updatedContent.secondaryText = "\(item.urlString)\n\(self.formattedDate(item.visitedAt))"
                                updatedContent.secondaryTextProperties.numberOfLines = 2
                                updatedContent.textProperties.numberOfLines = 1
                                updatedContent.image = image
                                updatedContent.imageProperties.maximumSize = CGSize(width: 22, height: 22)
                                updatedContent.imageProperties.cornerRadius = 4
                                currentCell.contentConfiguration = updatedContent
                            }
                        }
                    }
                }
            }
            cell.accessoryType = .disclosureIndicator
        }

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(
        _ tableView: UITableView,
        didSelectRowAt indexPath: IndexPath
    ) {
        tableView.deselectRow(at: indexPath, animated: true)

        if currentSegment == 0 {
            guard indexPath.row < currentFolderNodes.count else { return }
            let item = currentFolderNodes[indexPath.row]
            if item.isFolder {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let subFolderVC = BrowserHistoryViewController(
                    initialSegment: 0,
                    folderId: item.id,
                    folderTitle: item.title
                )
                subFolderVC.onSelectURL = onSelectURL
                if let nav = navigationController {
                    nav.pushViewController(subFolderVC, animated: true)
                } else {
                    let nav = UINavigationController(rootViewController: subFolderVC)
                    present(nav, animated: true)
                }
            } else {
                guard let url = URL(string: item.urlString) else { return }
                (navigationController ?? self).dismiss(animated: true) { [weak self] in
                    self?.onSelectURL?(url)
                }
            }
        } else {
            guard indexPath.section < sections.count, indexPath.row < sections[indexPath.section].items.count else { return }
            let item = sections[indexPath.section].items[indexPath.row]
            guard let url = URL(string: item.urlString) else { return }
            (navigationController ?? self).dismiss(animated: true) { [weak self] in
                self?.onSelectURL?(url)
            }
        }
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        if currentSegment == 0 {
            guard indexPath.row < currentFolderNodes.count else { return nil }
            let node = currentFolderNodes[indexPath.row]

            let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
                BookmarkStore.shared.deleteNode(id: node.id)
                self?.loadData()
                completion(true)
            }

            let editAction = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, completion in
                self?.showEditNodeAlert(node: node)
                completion(true)
            }
            editAction.backgroundColor = .systemBlue

            return UISwipeActionsConfiguration(actions: [deleteAction, editAction])
        } else {
            let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
                guard let self = self else { return }
                let item = self.sections[indexPath.section].items[indexPath.row]
                BrowserHistoryStore.shared.delete(id: item.id)
                self.loadData()
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [deleteAction])
        }
    }

    private func showEditNodeAlert(node: BookmarkItem) {
        let alert = UIAlertController(title: node.isFolder ? "重命名文件夹" : "编辑书签", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = node.isFolder ? "文件夹名称" : "书签标题"
            tf.text = node.title
            tf.clearButtonMode = .whileEditing
        }
        if !node.isFolder {
            alert.addTextField { tf in
                tf.placeholder = "网址"
                tf.text = node.urlString
                tf.keyboardType = .URL
                tf.clearButtonMode = .whileEditing
            }
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let title = alert?.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return }
            let urlString = alert?.textFields?.indices.contains(1) == true ? alert?.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            BookmarkStore.shared.updateNode(id: node.id, title: title, urlString: urlString)
            self?.loadData()
        })
        present(alert, animated: true)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
