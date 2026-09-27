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

        alert.addAction(UIAlertAction(title: "全部清空(包含已锁定)", style: .destructive) { [weak self] _ in
            let confirmAlert = UIAlertController(
                title: "确认全部清空",
                message: "此操作将无视锁定保护，彻底删除所有网站的数据与登录信息。",
                preferredStyle: .alert
            )
            confirmAlert.addAction(UIAlertAction(title: "取消", style: .cancel))
            confirmAlert.addAction(UIAlertAction(title: "确定清空", style: .destructive) { _ in
                let types = WKWebsiteDataStore.allWebsiteDataTypes()
                WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { records in
                    WKWebsiteDataStore.default().removeData(ofTypes: types, for: records) {
                        DispatchQueue.main.async {
                            self?.loadData()
                        }
                    }
                }
            })
            self?.present(confirmAlert, animated: true)
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
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

// MARK: - 辅助控制器保持完整性

final class DomainSettingsViewController: UITableViewController {
    private let domain: String
    var onSettingsChanged: (() -> Void)?
    var onExtractText: (() -> Void)?

    init(domain: String, onSettingsChanged: (() -> Void)?) {
        self.domain = domain
        self.onSettingsChanged = onSettingsChanged
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = domain
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleDone))
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? 3 : 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)

        if indexPath.section == 0 {
            let switchView = UISwitch()
            switchView.tag = indexPath.row

            if indexPath.row == 0 {
                cell.textLabel?.text = "视频悬窗"
                switchView.isOn = DomainSettingsStore.shared.getBool(domain: domain, setting: "videoPopout", defaultVal: false)
                switchView.isEnabled = false
            } else if indexPath.row == 1 {
                cell.textLabel?.text = "广告过滤"
                switchView.isOn = DomainSettingsStore.shared.getBool(domain: domain, setting: "adBlock", defaultVal: true)
                switchView.isEnabled = true
                switchView.addTarget(self, action: #selector(handleSwitchChanged(_:)), for: .valueChanged)
            } else if indexPath.row == 2 {
                cell.textLabel?.text = "用户脚本"
                switchView.isOn = DomainSettingsStore.shared.getBool(domain: domain, setting: "userScripts", defaultVal: true)
                switchView.isEnabled = true
                switchView.addTarget(self, action: #selector(handleSwitchChanged(_:)), for: .valueChanged)
            }
            cell.accessoryView = switchView
        } else {
            cell.textLabel?.text = "获取网页所有文字"
            cell.textLabel?.textColor = .systemBlue
            cell.textLabel?.textAlignment = .center
        }

        return cell
    }

    @objc private func handleSwitchChanged(_ sender: UISwitch) {
        if sender.tag == 1 {
            DomainSettingsStore.shared.setBool(domain: domain, setting: "adBlock", value: sender.isOn)
            onSettingsChanged?()
        } else if sender.tag == 2 {
            DomainSettingsStore.shared.setBool(domain: domain, setting: "userScripts", value: sender.isOn)
            onSettingsChanged?()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 {
            dismiss(animated: true) { [weak self] in
                self?.onExtractText?()
            }
        }
    }
}

final class UserAgentManagerViewController: UITableViewController {
    private var mobileItems: [UserAgentItem] = []
    private var desktopItems: [UserAgentItem] = []
    private var customItems: [UserAgentItem] = []

    var onUASelected: ((UserAgentItem) -> Void)?

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "浏览器标识"
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemGroupedBackground
        tableView.register(UserAgentCardCell.self, forCellReuseIdentifier: "UserAgentCardCell")

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(handleAddCustomUA)
        )
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(handleDone)
        )

        loadData()
    }

    private func loadData() {
        mobileItems = UserAgentStore.shared.loadMobileItems()
        desktopItems = UserAgentStore.shared.loadDesktopItems()
        customItems = UserAgentStore.shared.loadCustomItems()
        tableView.reloadData()
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    @objc private func handleAddCustomUA() {
        let alert = UIAlertController(title: "添加自定义标识", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in tf.placeholder = "标识名称" }
        alert.addTextField { tf in tf.placeholder = "User-Agent 字符串" }

        alert.addAction(UIAlertAction(title: "保存为移动版", style: .default) { [weak self] _ in
            guard let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let ua = alert.textFields?[1].text?.trimmingCharacters(in: .whitespaces), !ua.isEmpty else { return }

            UserAgentStore.shared.addCustomItem(name: name, uaString: ua, category: .mobile)
            self?.loadData()
        })
        alert.addAction(UIAlertAction(title: "保存为电脑版", style: .default) { [weak self] _ in
            guard let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let ua = alert.textFields?[1].text?.trimmingCharacters(in: .whitespaces), !ua.isEmpty else { return }

            UserAgentStore.shared.addCustomItem(name: name, uaString: ua, category: .desktop)
            self?.loadData()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showEditUAAlert(item: UserAgentItem) {
        let alert = UIAlertController(title: "编辑标识", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "标识名称"
            tf.text = item.name
        }
        alert.addTextField { tf in
            tf.placeholder = "User-Agent 字符串"
            tf.text = item.uaString
        }

        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
            guard let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let ua = alert.textFields?[1].text?.trimmingCharacters(in: .whitespaces), !ua.isEmpty else { return }

            if item.isCustom {
                UserAgentStore.shared.updateCustomItem(id: item.id, name: name, uaString: ua)
            } else {
                UserAgentStore.shared.addCustomItem(name: name, uaString: ua, category: item.category)
            }
            self?.loadData()
            let currentItem = UserAgentStore.shared.getSelectedItem()
            self?.onUASelected?(currentItem)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func item(for indexPath: IndexPath) -> UserAgentItem {
        switch indexPath.section {
        case 0:
            return mobileItems[indexPath.row]
        case 1:
            return desktopItems[indexPath.row]
        default:
            return customItems[indexPath.row]
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return customItems.isEmpty ? 2 : 3
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0:
            return "移动版标识"
        case 1:
            return "电脑版标识"
        default:
            return "自定义标识"
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:
            return mobileItems.count
        case 1:
            return desktopItems.count
        default:
            return customItems.count
        }
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 68
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "UserAgentCardCell", for: indexPath) as! UserAgentCardCell
        let item = self.item(for: indexPath)
        let isSelected: Bool
        if indexPath.section == 0 {
            isSelected = (item.id == UserAgentStore.shared.getSelectedMobileId())
        } else if indexPath.section == 1 {
            isSelected = (item.id == UserAgentStore.shared.getSelectedDesktopId())
        } else {
            if item.category == .desktop {
                isSelected = (item.id == UserAgentStore.shared.getSelectedDesktopId())
            } else {
                isSelected = (item.id == UserAgentStore.shared.getSelectedMobileId())
            }
        }
        cell.configure(item: item, isSelected: isSelected)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = self.item(for: indexPath)
        if indexPath.section == 0 {
            UserAgentStore.shared.setSelectedMobileId(item.id)
            UserAgentStore.shared.currentMode = .mobile
        } else if indexPath.section == 1 {
            UserAgentStore.shared.setSelectedDesktopId(item.id)
            UserAgentStore.shared.currentMode = .desktop
        } else {
            if item.category == .desktop {
                UserAgentStore.shared.setSelectedDesktopId(item.id)
                UserAgentStore.shared.currentMode = .desktop
            } else {
                UserAgentStore.shared.setSelectedMobileId(item.id)
                UserAgentStore.shared.currentMode = .mobile
            }
        }
        tableView.reloadData()

        onUASelected?(item)
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item = self.item(for: indexPath)

        let editAction = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, completion in
            self?.showEditUAAlert(item: item)
            completion(true)
        }
        editAction.backgroundColor = .systemBlue

        if item.isCustom {
            let deleteAction = UIContextualAction(style: .normal, title: "删除") { [weak self] _, _, completion in
                UserAgentStore.shared.deleteCustomItem(id: item.id)
                self?.loadData()
                let currentItem = UserAgentStore.shared.getSelectedItem()
                self?.onUASelected?(currentItem)
                completion(true)
            }
            deleteAction.backgroundColor = .systemRed
            return UISwipeActionsConfiguration(actions: [deleteAction, editAction])
        } else {
            return UISwipeActionsConfiguration(actions: [editAction])
        }
    }
}

final class UserAgentCardCell: UITableViewCell {
    private let cardView = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let checkmarkImageView = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .secondarySystemGroupedBackground
        cardView.layer.cornerRadius = 12
        cardView.clipsToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.lineBreakMode = .byTruncatingTail

        checkmarkImageView.translatesAutoresizingMaskIntoConstraints = false
        checkmarkImageView.image = UIImage(systemName: "checkmark.circle.fill")
        checkmarkImageView.tintColor = .systemBlue
        checkmarkImageView.contentMode = .scaleAspectFit

        cardView.addSubview(titleLabel)
        cardView.addSubview(subtitleLabel)
        cardView.addSubview(checkmarkImageView)
        contentView.addSubview(cardView)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),

            checkmarkImageView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            checkmarkImageView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            checkmarkImageView.widthAnchor.constraint(equalToConstant: 20),
            checkmarkImageView.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: checkmarkImageView.leadingAnchor, constant: -12),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: checkmarkImageView.leadingAnchor, constant: -12),
            subtitleLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(item: UserAgentItem, isSelected: Bool) {
        titleLabel.text = item.name
        subtitleLabel.text = item.uaString
        checkmarkImageView.isHidden = !isSelected
    }
}

final class UserScriptEditorViewController: UIViewController {
    private var script: UserScript?
    var onSave: ((UserScript) -> Void)?

    private let nameField = UITextField()
    private let matchField = UITextField()
    private let textView = UITextView()

    init(script: UserScript?) {
        self.script = script
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = script == nil ? "新建油猴脚本" : "编辑脚本"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "保存",
            style: .done,
            target: self,
            action: #selector(handleSave)
        )
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: self,
            action: #selector(handleCancel)
        )

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.backgroundColor = .secondarySystemGroupedBackground
        nameField.layer.cornerRadius = 10
        nameField.clipsToBounds = true
        nameField.placeholder = "脚本名称"
        nameField.text = script?.name ?? ""
        nameField.font = .systemFont(ofSize: 15)

        let namePadding = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        nameField.leftView = namePadding
        nameField.leftViewMode = .always

        matchField.translatesAutoresizingMaskIntoConstraints = false
        matchField.backgroundColor = .secondarySystemGroupedBackground
        matchField.layer.cornerRadius = 10
        matchField.clipsToBounds = true
        matchField.placeholder = "匹配域名规则 (如 * 或 google.com)"
        matchField.text = script?.matchPattern ?? "*"
        matchField.font = .systemFont(ofSize: 15)

        let matchPadding = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        matchField.leftView = matchPadding
        matchField.leftViewMode = .always

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 12
        textView.clipsToBounds = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.text = script?.code ?? "(function() {\n    'use strict';\n})();"

        view.addSubview(nameField)
        view.addSubview(matchField)
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            nameField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            nameField.heightAnchor.constraint(equalToConstant: 42),

            matchField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 10),
            matchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            matchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            matchField.heightAnchor.constraint(equalToConstant: 42),

            textView.topAnchor.constraint(equalTo: matchField.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    @objc private func handleSave() {
        let codeText = textView.text ?? ""
        var nameText = nameField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        var matchText = matchField.text?.trimmingCharacters(in: .whitespaces) ?? ""

        let parsed = UserScriptStore.shared.parseMetadata(from: codeText)
        if nameText.isEmpty { nameText = parsed.name }
        if matchText.isEmpty { matchText = parsed.match }

        let item = UserScript(
            id: script?.id ?? UUID().uuidString,
            name: nameText,
            matchPattern: matchText,
            code: codeText,
            isEnabled: script?.isEnabled ?? true
        )

        onSave?(item)
        dismiss(animated: true)
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }
}
