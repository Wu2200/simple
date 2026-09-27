import UIKit

struct HistorySection {
    let title: String
    let items: [BrowserHistoryItem]
}

final class BrowserHistoryViewController: UITableViewController, UISearchResultsUpdating {
    private var allHistoryItems: [BrowserHistoryItem] = []
    private var allBookmarkItems: [BookmarkItem] = []
    private var sections: [HistorySection] = []
    private var currentSegment: Int = 0 // 0: 书签, 1: 历史
    private let searchController = UISearchController(searchResultsController: nil)
    private let segmentedControl = UISegmentedControl(items: ["书签", "历史"])

    var onSelectURL: ((URL) -> Void)?

    init(initialSegment: Int = 0) {
        self.currentSegment = initialSegment
        super.init(style: .insetGrouped)
    }

    convenience init() {
        self.init(initialSegment: 0)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()

        segmentedControl.selectedSegmentIndex = currentSegment
        segmentedControl.addTarget(self, action: #selector(handleSegmentChange(_:)), for: .valueChanged)
        navigationItem.titleView = segmentedControl

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "BrowserRecordCell")

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = currentSegment == 0 ? "搜索书签" : "搜索历史记录"

        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(handleClose)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "清空",
            style: .plain,
            target: self,
            action: #selector(handleClear)
        )

        loadData()
    }

    @objc private func handleSegmentChange(_ sender: UISegmentedControl) {
        currentSegment = sender.selectedSegmentIndex
        searchController.searchBar.placeholder = currentSegment == 0 ? "搜索书签" : "搜索历史记录"
        loadData()
    }

    private func loadData() {
        let query = searchController.searchBar.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if currentSegment == 0 {
            allBookmarkItems = BookmarkStore.shared.loadBookmarks()
            filterBookmarks(query: query)
        } else {
            allHistoryItems = BrowserHistoryStore.shared.loadHistory()
            filterAndGroupHistory(query: query)
        }
    }

    private func filterBookmarks(query: String) {
        if !query.isEmpty {
            allBookmarkItems = BookmarkStore.shared.loadBookmarks().filter {
                $0.title.lowercased().contains(query) || $0.urlString.lowercased().contains(query)
            }
        }
        tableView.reloadData()
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

    @objc private func handleClear() {
        let isBookmark = (currentSegment == 0)
        let alert = UIAlertController(
            title: isBookmark ? "清空书签" : "清空历史记录",
            message: isBookmark ? "确定要清空全部收藏的书签吗？" : "确定要清空全部浏览历史记录吗？",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            if isBookmark {
                BookmarkStore.shared.clearBookmarks()
            } else {
                BrowserHistoryStore.shared.clearHistory()
            }
            self?.loadData()
        })

        present(alert, animated: true)
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if currentSegment == 0 {
            filterBookmarks(query: query)
        } else {
            filterAndGroupHistory(query: query)
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        if currentSegment == 0 {
            return 1
        }
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if currentSegment == 0 {
            return allBookmarkItems.count
        }
        return sections[section].items.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if currentSegment == 0 {
            return allBookmarkItems.isEmpty ? nil : "我的书签"
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
            let item = allBookmarkItems[indexPath.row]
            content.text = item.title
            content.secondaryText = item.urlString
            content.secondaryTextProperties.numberOfLines = 1
            content.textProperties.numberOfLines = 1
            content.image = UIImage(systemName: "star.fill")
            content.imageProperties.tintColor = .systemYellow
            content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
        } else {
            let item = sections[indexPath.section].items[indexPath.row]
            content.text = item.title
            content.secondaryText = "\(item.urlString)\n\(formattedDate(item.visitedAt))"
            content.secondaryTextProperties.numberOfLines = 2
            content.textProperties.numberOfLines = 1
            content.image = UIImage(systemName: "globe")
            content.imageProperties.tintColor = .secondaryLabel
            content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
            content.imageProperties.cornerRadius = 4

            if let url = URL(string: item.urlString), let host = url.host {
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

        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(
        _ tableView: UITableView,
        didSelectRowAt indexPath: IndexPath
    ) {
        tableView.deselectRow(at: indexPath, animated: true)

        let targetURLString: String
        if currentSegment == 0 {
            guard indexPath.row < allBookmarkItems.count else { return }
            targetURLString = allBookmarkItems[indexPath.row].urlString
        } else {
            guard indexPath.section < sections.count, indexPath.row < sections[indexPath.section].items.count else { return }
            targetURLString = sections[indexPath.section].items[indexPath.row].urlString
        }

        guard let url = URL(string: targetURLString) else {
            return
        }

        dismiss(animated: true) { [weak self] in
            self?.onSelectURL?(url)
        }
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let isBookmark = (currentSegment == 0)
        let deleteAction = UIContextualAction(
            style: .destructive,
            title: "删除"
        ) { [weak self] _, _, completion in
            guard let self = self else { return }
            if isBookmark {
                let item = self.allBookmarkItems[indexPath.row]
                BookmarkStore.shared.deleteBookmark(id: item.id)
            } else {
                let item = self.sections[indexPath.section].items[indexPath.row]
                BrowserHistoryStore.shared.delete(id: item.id)
            }
            self.loadData()
            completion(true)
        }

        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
