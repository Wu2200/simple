import UIKit
import WebKit

public typealias WebsiteDataViewController = WebsiteDataManagerViewController

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
        return records.contains { CookieLockStore.shared.isLocked(domain: $0.displayName) }
    }

    var allLocked: Bool {
        return !records.isEmpty && records.allSatisfy { CookieLockStore.shared.isLocked(domain: $0.displayName) }
    }

    var hasCookies: Bool {
        return records.contains { $0.dataTypes.contains(WKWebsiteDataTypeCookies) }
    }
}

// MARK: - 管理网站数据主页面（仅展示主域名）

final class WebsiteDataManagerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {
    private var allGroups: [MainDomainGroup] = []
    private var filteredGroups: [MainDomainGroup] = []
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let searchController = UISearchController(searchResultsController: nil)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "管理网站数据"

        setupNavigationBar()
        setupHeaderView()
        setupTableView()
        setupSearchController()
        loadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadData()
    }

    private func setupNavigationBar() {
        let backImage = UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: backImage, style: .plain, target: self, action: #selector(handleDone))

        let removeButton = UIBarButtonItem(title: "移除", style: .plain, target: self, action: #selector(handleRemoveAction))
        removeButton.tintColor = .systemRed
        navigationItem.rightBarButtonItem = removeButton
    }

    private func setupHeaderView() {
        let header = UIView()
        header.backgroundColor = .clear

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "数据可能会减少跟踪，但也可能允许网站退出登录。点击主域名可查看名下的所有子域名与关联域名，域名需单独逐个锁定。"
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.numberOfLines = 0

        header.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16)
        ])

        let targetSize = CGSize(width: UIScreen.main.bounds.width, height: UIView.layoutFittingCompressedSize.height)
        let size = header.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        header.frame = CGRect(x: 0, y: 0, width: size.width, height: max(size.height, 46))
        tableView.tableHeaderView = header
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .systemBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(WebsiteDataDetailCell.self, forCellReuseIdentifier: WebsiteDataDetailCell.reuseIdentifier)
        tableView.rowHeight = 64
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 60, bottom: 0, right: 0)

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func setupSearchController() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜索主域名或数据类型(如Cookie)"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    private func loadData() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { [weak self] records in
            DispatchQueue.main.async {
                self?.allGroups = DomainRelationEngine.groupRecordsIntoMainDomains(records)
                self?.updateSearchResults(for: self?.searchController ?? UISearchController())
            }
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let searchText = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if searchText.isEmpty {
            filteredGroups = allGroups
        } else {
            filteredGroups = allGroups.filter { group in
                let mainMatches = group.mainDomain.lowercased().contains(searchText)
                let subMatches = group.records.contains { $0.displayName.lowercased().contains(searchText) }
                let typeMatches = WebsiteDataDetailCell.formatDataTypes(group.allDataTypes).lowercased().contains(searchText)
                return mainMatches || subMatches || typeMatches
            }
        }
        tableView.reloadData()
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    @objc private func handleRemoveAction() {
        let alert = UIAlertController(title: "移除网站数据", message: "已锁定的域名受到严格保护，不会被删除。", preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "移除所有未锁定数据", style: .destructive) { [weak self] _ in
            WebsiteCleaner.shared.cleanUnprotectedLoginAndData {
                self?.loadData()
            }
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(alert, animated: true)
    }

    // MARK: - UITableViewDataSource & Delegate

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filteredGroups.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: WebsiteDataDetailCell.reuseIdentifier, for: indexPath) as? WebsiteDataDetailCell else {
            return UITableViewCell()
        }
        let group = filteredGroups[indexPath.row]
        let countText = group.records.count > 1 ? "\(group.records.count)个域名" : ""
        cell.configureForMainGroup(group: group, countText: countText)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < filteredGroups.count else { return }
        let group = filteredGroups[indexPath.row]

        let detailVC = WebsiteRelatedDomainsViewController(mainDomain: group.mainDomain, records: group.records) { [weak self] in
            self?.loadData()
        }
        navigationController?.pushViewController(detailVC, animated: true)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.row < filteredGroups.count else { return nil }
        let group = filteredGroups[indexPath.row]

        let deleteAction = UIContextualAction(style: .destructive, title: "移除未锁定") { [weak self] _, _, completion in
            guard let self = self else { return }
            let unlocked = group.records.filter { !CookieLockStore.shared.isLocked(domain: $0.displayName) }

            if unlocked.isEmpty {
                let alert = UIAlertController(title: "域名已被锁定", message: "该主域名下的所有域名均处于锁定保护状态，无法直接移除。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "确定", style: .default))
                self.present(alert, animated: true)
                completion(false)
                return
            }

            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            WKWebsiteDataStore.default().removeData(ofTypes: types, for: unlocked) {
                DispatchQueue.main.async {
                    self.loadData()
                    completion(true)
                }
            }
        }

        return UISwipeActionsConfiguration(actions: [deleteAction])
    }
}

// MARK: - 关联域名管理页面 (二级详情页 - 仅支持逐个单项锁定)

final class WebsiteRelatedDomainsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let mainDomain: String
    private var records: [WKWebsiteDataRecord]
    private let onDataChanged: () -> Void
    private let tableView = UITableView(frame: .zero, style: .plain)

    init(mainDomain: String, records: [WKWebsiteDataRecord], onDataChanged: @escaping () -> Void) {
        self.mainDomain = mainDomain
        self.records = records
        self.onDataChanged = onDataChanged
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = mainDomain

        setupNavigationBar()
        setupHeaderView()
        setupTableView()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onDataChanged()
    }

    private func setupNavigationBar() {
        navigationItem.rightBarButtonItem = nil
    }

    private func setupHeaderView() {
        let header = UIView()
        header.backgroundColor = .clear

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "主站点 [ \(mainDomain) ] 共有 \(records.count) 个域名。点击任意域名可对其单独锁定或解锁，锁定的网站数据在清理时将被保留。"
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.numberOfLines = 0

        header.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16)
        ])

        let targetSize = CGSize(width: UIScreen.main.bounds.width, height: UIView.layoutFittingCompressedSize.height)
        let size = header.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        header.frame = CGRect(x: 0, y: 0, width: size.width, height: max(size.height, 46))
        tableView.tableHeaderView = header
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .systemBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(WebsiteDataDetailCell.self, forCellReuseIdentifier: WebsiteDataDetailCell.reuseIdentifier)
        tableView.rowHeight = 64
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 60, bottom: 0, right: 0)

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    // MARK: - UITableViewDataSource & Delegate

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return records.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: WebsiteDataDetailCell.reuseIdentifier, for: indexPath) as? WebsiteDataDetailCell else {
            return UITableViewCell()
        }
        let record = records[indexPath.row]
        let isLocked = CookieLockStore.shared.isLocked(domain: record.displayName)
        cell.configure(record: record, isLocked: isLocked, showChevron: false, countText: "")
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < records.count else { return }
        let record = records[indexPath.row]

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        CookieLockStore.shared.toggleLock(domain: record.displayName)

        if let cell = tableView.cellForRow(at: indexPath) as? WebsiteDataDetailCell {
            let isLocked = CookieLockStore.shared.isLocked(domain: record.displayName)
            cell.configure(record: record, isLocked: isLocked, showChevron: false, countText: "")
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.row < records.count else { return nil }
        let record = records[indexPath.row]
        let isLocked = CookieLockStore.shared.isLocked(domain: record.displayName)

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            WebsiteCleaner.shared.cleanSingleDomain(record: record, cacheOnly: false) {
                guard let self = self else { return }
                self.records.removeAll { $0.displayName == record.displayName }
                self.tableView.reloadData()
                completion(true)
            }
        }

        let lockActionTitle = isLocked ? "解锁" : "锁定"
        let lockAction = UIContextualAction(style: .normal, title: lockActionTitle) { [weak self] _, _, completion in
            CookieLockStore.shared.toggleLock(domain: record.displayName)
            self?.tableView.reloadRows(at: [indexPath], with: .automatic)
            completion(true)
        }
        lockAction.backgroundColor = isLocked ? .systemGray : UIColor(red: 0.12, green: 0.65, blue: 0.45, alpha: 1.0)

        return UISwipeActionsConfiguration(actions: [deleteAction, lockAction])
    }
}

// MARK: - 关联域名拓扑识别引擎

enum DomainRelationEngine {
    static func groupRecordsIntoMainDomains(_ records: [WKWebsiteDataRecord]) -> [MainDomainGroup] {
        var dict: [String: [WKWebsiteDataRecord]] = [:]

        for record in records {
            let host = record.displayName.trimmingCharacters(in: .whitespaces).lowercased()
            let root = rootDomain(of: host)
            dict[root, default: []].append(record)
        }

        let companionMap: [(keyword: String, targetRoot: String)] = [
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
            ("ytimg.com", "youtube.com"),
            ("zhimg.com", "zhihu.com"),
            ("uxengine.net", "v2ex.com")
        ]

        for item in companionMap {
            if let compRecs = dict[item.keyword], dict[item.targetRoot] != nil {
                dict[item.targetRoot]?.append(contentsOf: compRecs)
                dict.removeValue(forKey: item.keyword)
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

    static func rootDomain(of domain: String) -> String {
        let clean = domain.trimmingCharacters(in: .whitespaces).lowercased()
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
}

// MARK: - 自定义网站数据单元格（对齐截图视觉效果）

final class WebsiteDataDetailCell: UITableViewCell {
    static let reuseIdentifier = "WebsiteDataDetailCell"

    private let logoImageView = UIImageView()
    private let domainLabel = UILabel()
    private let lockBadge = UIView()
    private let lockIcon = UIImageView()
    private let detailLabel = UILabel()
    private let countBadgeLabel = UILabel()
    private var lockBadgeWidthConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear

        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.layer.cornerRadius = 6
        logoImageView.clipsToBounds = true

        domainLabel.translatesAutoresizingMaskIntoConstraints = false
        domainLabel.font = .systemFont(ofSize: 15.5, weight: .semibold)
        domainLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        lockBadge.translatesAutoresizingMaskIntoConstraints = false
        lockBadge.backgroundColor = UIColor(red: 0.12, green: 0.65, blue: 0.45, alpha: 1.0)
        lockBadge.layer.cornerRadius = 8.5
        lockBadge.clipsToBounds = true

        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        let lockConfig = UIImage.SymbolConfiguration(pointSize: 9.5, weight: .bold)
        lockIcon.image = UIImage(systemName: "lock.fill", withConfiguration: lockConfig)
        lockIcon.tintColor = .white
        lockIcon.contentMode = .scaleAspectFit
        lockBadge.addSubview(lockIcon)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        detailLabel.textColor = .secondaryLabel
        detailLabel.lineBreakMode = .byTruncatingTail

        countBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        countBadgeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countBadgeLabel.textColor = .tertiaryLabel
        countBadgeLabel.textAlignment = .right

        contentView.addSubview(logoImageView)
        contentView.addSubview(domainLabel)
        contentView.addSubview(lockBadge)
        contentView.addSubview(detailLabel)
        contentView.addSubview(countBadgeLabel)

        let badgeWidth = lockBadge.widthAnchor.constraint(equalToConstant: 17)
        lockBadgeWidthConstraint = badgeWidth

        NSLayoutConstraint.activate([
            logoImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            logoImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            logoImageView.widthAnchor.constraint(equalToConstant: 28),
            logoImageView.heightAnchor.constraint(equalToConstant: 28),

            domainLabel.leadingAnchor.constraint(equalTo: logoImageView.trailingAnchor, constant: 14),
            domainLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),

            lockBadge.leadingAnchor.constraint(equalTo: domainLabel.trailingAnchor, constant: 6),
            lockBadge.centerYAnchor.constraint(equalTo: domainLabel.centerYAnchor),
            lockBadge.trailingAnchor.constraint(lessThanOrEqualTo: countBadgeLabel.leadingAnchor, constant: -6),
            badgeWidth,
            lockBadge.heightAnchor.constraint(equalToConstant: 17),

            lockIcon.centerXAnchor.constraint(equalTo: lockBadge.centerXAnchor),
            lockIcon.centerYAnchor.constraint(equalTo: lockBadge.centerYAnchor),
            lockIcon.widthAnchor.constraint(equalToConstant: 10),
            lockIcon.heightAnchor.constraint(equalToConstant: 10),

            countBadgeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            countBadgeLabel.centerYAnchor.constraint(equalTo: domainLabel.centerYAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: domainLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: domainLabel.bottomAnchor, constant: 3),
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configureForMainGroup(group: MainDomainGroup, countText: String) {
        domainLabel.text = group.mainDomain
        detailLabel.text = Self.formatDataTypes(group.allDataTypes)
        countBadgeLabel.text = countText
        accessoryType = .disclosureIndicator

        let greenColor = UIColor(red: 0.12, green: 0.65, blue: 0.45, alpha: 1.0)
        if group.hasLocked {
            lockBadge.isHidden = false
            lockBadgeWidthConstraint?.constant = 17
            domainLabel.textColor = group.allLocked ? greenColor : .label
        } else {
            lockBadge.isHidden = true
            lockBadgeWidthConstraint?.constant = 0
            domainLabel.textColor = .label
        }

        loadFavicon(for: group.mainDomain)
    }

    func configure(record: WKWebsiteDataRecord, isLocked: Bool, showChevron: Bool = true, countText: String = "") {
        domainLabel.text = record.displayName
        detailLabel.text = Self.formatDataTypes(record.dataTypes)
        countBadgeLabel.text = countText

        accessoryType = showChevron ? .disclosureIndicator : .none

        let greenColor = UIColor(red: 0.12, green: 0.65, blue: 0.45, alpha: 1.0)
        if isLocked {
            domainLabel.textColor = greenColor
            lockBadge.isHidden = false
            lockBadgeWidthConstraint?.constant = 17
        } else {
            domainLabel.textColor = .label
            lockBadge.isHidden = true
            lockBadgeWidthConstraint?.constant = 0
        }

        loadFavicon(for: record.displayName)
    }

    private func loadFavicon(for domain: String) {
        if let cached = FaviconLoader.shared.cachedFavicon(for: domain) {
            logoImageView.image = cached
        } else {
            logoImageView.image = UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))?.withTintColor(.systemGray3, renderingMode: .alwaysOriginal)
            FaviconLoader.shared.loadFavicon(for: domain) { [weak self] image in
                DispatchQueue.main.async {
                    if let image = image, self?.domainLabel.text == domain {
                        self?.logoImageView.image = image
                    }
                }
            }
        }
    }

    static func formatDataTypes(_ types: Set<String>) -> String {
        var names: [String] = []

        if types.contains(WKWebsiteDataTypeCookies) {
            names.append("Cookies")
        }
        if types.contains(WKWebsiteDataTypeDiskCache) {
            names.append("磁盘缓存")
        }
        if types.contains(WKWebsiteDataTypeMemoryCache) {
            names.append("缓存")
        }
        if types.contains(WKWebsiteDataTypeOfflineWebApplicationCache) {
            names.append("离线缓存")
        }
        if types.contains(WKWebsiteDataTypeIndexedDBDatabases) {
            names.append("索引数据库")
        }
        if types.contains(WKWebsiteDataTypeLocalStorage) {
            names.append("本地存储")
        }
        if types.contains(WKWebsiteDataTypeSessionStorage) {
            names.append("会话存储")
        }
        if types.contains(WKWebsiteDataTypeWebSQLDatabases) {
            names.append("WebSQL")
        }
        for t in types {
            if t.contains("Fetch") && !names.contains("系统缓存") {
                names.append("系统缓存")
            }
        }

        if names.isEmpty {
            return "网站数据"
        }
        return names.joined(separator: ",")
    }
}
