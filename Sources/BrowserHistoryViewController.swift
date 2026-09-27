import UIKit
import UniformTypeIdentifiers

struct HistorySection {
    let title: String
    let items: [BrowserHistoryItem]
}

final class BrowserHistoryViewController: UITableViewController, UISearchResultsUpdating, UIDocumentPickerDelegate {
    private var allHistoryItems: [BrowserHistoryItem] = []
    private var currentFolderNodes: [BookmarkItem] = []
    private var sections: [HistorySection] = []

    private var currentSegment: Int = 0 // 0: 书签, 1: 历史
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
            // 子文件夹视图：原生系统导航推进
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
            // 书签根视图
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
            // 历史根视图
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
            tf.placeholder = "网址 (https://...)"
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
