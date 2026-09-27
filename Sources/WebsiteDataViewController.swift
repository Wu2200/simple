import UIKit
import WebKit

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
        let isPushed = (navigationController?.viewControllers.count ?? 0) > 1
        let leftItem: UIBarButtonItem
        if isPushed {
            let backImage = UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
            leftItem = UIBarButtonItem(image: backImage, style: .plain, target: self, action: #selector(handleDone))
        } else {
            leftItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleDone))
        }
        navigationItem.leftBarButtonItem = leftItem

        let removeButton = UIBarButtonItem(title: "移除", style: .plain, target: self, action: #selector(handleRemoveAction))
        removeButton.tintColor = .systemRed
        navigationItem.rightBarButtonItem = removeButton
    }

    private func setupHeaderView() {
        let header = UIView()
        header.backgroundColor = .clear

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "锁定的站点数据在清理时将被完整保留，绝不退出登录。点击主域名可查看名下所有子域名；支持左滑直接「锁定全站」或逐个锁定。"
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
        if let nav = navigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func handleRemoveAction() {
        let alert = UIAlertController(title: "移除网站数据", message: "已锁定的站点受到严格保护，不会被删除。", preferredStyle: .actionSheet)

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
        let isGroupLocked = group.hasLocked

        let toggleLockAction = UIContextualAction(
            style: .normal,
            title: isGroupLocked ? "解锁全站" : "锁定全站"
        ) { [weak self] _, _, completion in
            guard let self = self else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if isGroupLocked {
                CookieLockStore.shared.unlockMainGroup(mainDomain: group.mainDomain, allRecords: group.records)
            } else {
                CookieLockStore.shared.lockMainGroup(mainDomain: group.mainDomain, allRecords: group.records)
            }
            self.loadData()
            completion(true)
        }
        toggleLockAction.backgroundColor = isGroupLocked ? .systemGray : UIColor(red: 0.12, green: 0.65, blue: 0.45, alpha: 1.0)

        let deleteAction = UIContextualAction(style: .destructive, title: "移除未锁定") { [weak self] _, _, completion in
            guard let self = self else { return }
            let unlocked = group.records.filter { !CookieLockStore.shared.isLocked(domain: $0.displayName) }

            if unlocked.isEmpty {
                let alert = UIAlertController(title: "站点已被锁定", message: "该主域名下的所有域名均处于锁定保护状态，无法直接移除。", preferredStyle: .alert)
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

        return UISwipeActionsConfiguration(actions: [deleteAction, toggleLockAction])
    }
}

// MARK: - 关联域名管理页面 (二级详情页 - 支持全选锁定与逐项锁定)

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
        updateRightBarButton()
    }

    private func updateRightBarButton() {
        let allLocked = records.allSatisfy { CookieLockStore.shared.isLocked(domain: $0.displayName) }
        let title = allLocked ? "全部解锁" : "全部锁定"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: title,
            style: .plain,
            target: self,
            action: #selector(handleToggleAllLock)
        )
    }

    @objc private func handleToggleAllLock() {
        let allLocked = records.allSatisfy { CookieLockStore.shared.isLocked(domain: $0.displayName) }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if allLocked {
            CookieLockStore.shared.unlockMainGroup(mainDomain: mainDomain, allRecords: records)
        } else {
            CookieLockStore.shared.lockMainGroup(mainDomain: mainDomain, allRecords: records)
        }
        updateRightBarButton()
        tableView.reloadData()
    }

    private func setupHeaderView() {
        let header = UIView()
        header.backgroundColor = .clear

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "主站点 [ \(mainDomain) ] 共有 \(records.count) 个域名。点击单项可切换锁定；右上角支持一键全选锁定。已锁定的站点数据在清理时受到保护，登录状态绝不丢失。"
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
        updateRightBarButton()

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
                self.updateRightBarButton()
                completion(true)
            }
        }

        let lockActionTitle = isLocked ? "解锁" : "锁定"
        let lockAction = UIContextualAction(style: .normal, title: lockActionTitle) { [weak self] _, _, completion in
            CookieLockStore.shared.toggleLock(domain: record.displayName)
            self?.updateRightBarButton()
            self?.tableView.reloadRows(at: [indexPath], with: .automatic)
            completion(true)
        }
        lockAction.backgroundColor = isLocked ? .systemGray : UIColor(red: 0.12, green: 0.65, blue: 0.45, alpha: 1.0)

        return UISwipeActionsConfiguration(actions: [deleteAction, lockAction])
    }
}

// MARK: - 自定义网站数据单元格

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
    private var mobilePresets: [UserAgentItem] = []
    private var desktopPresets: [UserAgentItem] = []
    private var customMobileItems: [UserAgentItem] = []
    private var customDesktopItems: [UserAgentItem] = []

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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "AddUARowCell")

        navigationItem.rightBarButtonItem = nil
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(handleDone)
        )

        loadData()
    }

    private func loadData() {
        mobilePresets = UserAgentStore.shared.loadMobileItems()
        desktopPresets = UserAgentStore.shared.loadDesktopItems()
        let allCustom = UserAgentStore.shared.loadCustomItems()
        customMobileItems = allCustom.filter { $0.category == .mobile }
        customDesktopItems = allCustom.filter { $0.category == .desktop }
        tableView.reloadData()
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    private func showAddCustomUA(category: UserAgentCategory) {
        let isMobile = category == .mobile
        let title = isMobile ? "添加自定义移动版标识" : "添加自定义电脑版标识"
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { tf in tf.placeholder = "标识名称" }
        alert.addTextField { tf in
            tf.placeholder = "User-Agent 字符串"
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "添加", style: .default) { [weak self] _ in
            guard let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let ua = alert.textFields?[1].text?.trimmingCharacters(in: .whitespaces), !ua.isEmpty else { return }

            UserAgentStore.shared.addCustomItem(name: name, uaString: ua, category: category)
            self?.loadData()
            let allCustom = UserAgentStore.shared.loadCustomItems()
            if let newItem = allCustom.last(where: { $0.name == name && $0.category == category }) {
                if isMobile {
                    UserAgentStore.shared.setSelectedMobileId(newItem.id)
                    UserAgentStore.shared.currentMode = .mobile
                } else {
                    UserAgentStore.shared.setSelectedDesktopId(newItem.id)
                    UserAgentStore.shared.currentMode = .desktop
                }
                self?.onUASelected?(newItem)
                self?.dismiss(animated: true)
            }
        })
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
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
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

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? "移动版标识" : "电脑版标识"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return mobilePresets.count + customMobileItems.count + 1
        } else {
            return desktopPresets.count + customDesktopItems.count + 1
        }
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let presetsCount = (indexPath.section == 0) ? mobilePresets.count : desktopPresets.count
        let customsCount = (indexPath.section == 0) ? customMobileItems.count : customDesktopItems.count
        if indexPath.row == presetsCount + customsCount {
            return 48
        }
        return 68
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let isMobile = (indexPath.section == 0)
        let presets = isMobile ? mobilePresets : desktopPresets
        let customs = isMobile ? customMobileItems : customDesktopItems
        let totalItems = presets.count + customs.count

        if indexPath.row == totalItems {
            let cell = tableView.dequeueReusableCell(withIdentifier: "AddUARowCell", for: indexPath)
            var config = cell.defaultContentConfiguration()
            config.text = isMobile ? "+ 添加自定义移动版标识" : "+ 添加自定义电脑版标识"
            config.textProperties.color = .systemBlue
            config.textProperties.alignment = .center
            config.textProperties.font = .systemFont(ofSize: 15, weight: .medium)
            cell.contentConfiguration = config
            cell.backgroundColor = .secondarySystemGroupedBackground
            cell.layer.cornerRadius = 12
            cell.clipsToBounds = true
            cell.selectionStyle = .default
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "UserAgentCardCell", for: indexPath) as! UserAgentCardCell
        let item: UserAgentItem
        if indexPath.row < presets.count {
            item = presets[indexPath.row]
        } else {
            item = customs[indexPath.row - presets.count]
        }

        let isSelected: Bool
        if isMobile {
            isSelected = (item.id == UserAgentStore.shared.getSelectedMobileId() && UserAgentStore.shared.currentMode == .mobile)
        } else {
            isSelected = (item.id == UserAgentStore.shared.getSelectedDesktopId() && UserAgentStore.shared.currentMode == .desktop)
        }

        cell.configure(item: item, isSelected: isSelected)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let isMobile = (indexPath.section == 0)
        let presets = isMobile ? mobilePresets : desktopPresets
        let customs = isMobile ? customMobileItems : customDesktopItems
        let totalItems = presets.count + customs.count

        if indexPath.row == totalItems {
            showAddCustomUA(category: isMobile ? .mobile : .desktop)
            return
        }

        let item: UserAgentItem
        if indexPath.row < presets.count {
            item = presets[indexPath.row]
        } else {
            item = customs[indexPath.row - presets.count]
        }

        if isMobile {
            UserAgentStore.shared.setSelectedMobileId(item.id)
            UserAgentStore.shared.currentMode = .mobile
        } else {
            UserAgentStore.shared.setSelectedDesktopId(item.id)
            UserAgentStore.shared.currentMode = .desktop
        }
        tableView.reloadData()

        onUASelected?(item)
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let isMobile = (indexPath.section == 0)
        let presets = isMobile ? mobilePresets : desktopPresets
        let customs = isMobile ? customMobileItems : customDesktopItems
        let totalItems = presets.count + customs.count

        if indexPath.row == totalItems {
            return nil
        }

        if indexPath.row < presets.count {
            let item = presets[indexPath.row]
            let editAction = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, completion in
                self?.showEditUAAlert(item: item)
                completion(true)
            }
            editAction.backgroundColor = .systemBlue
            return UISwipeActionsConfiguration(actions: [editAction])
        }

        let customIndex = indexPath.row - presets.count
        let item = customs[customIndex]

        let editAction = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, completion in
            self?.showEditUAAlert(item: item)
            completion(true)
        }
        editAction.backgroundColor = .systemBlue

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            UserAgentStore.shared.deleteCustomItem(id: item.id)
            self?.loadData()
            let currentItem = UserAgentStore.shared.getSelectedItem()
            self?.onUASelected?(currentItem)
            completion(true)
        }

        return UISwipeActionsConfiguration(actions: [deleteAction, editAction])
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
