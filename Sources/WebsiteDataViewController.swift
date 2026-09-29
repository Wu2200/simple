import UIKit
import WebKit

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
        label.text = "锁定的域名仅保护其登录状态，网页缓存文件仍会正常清理以避免积攒占用存储。点击进入可独立锁定或解锁各具体域名。"
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
        searchController.searchBar.placeholder = "搜索主域名或数据类型"
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
        let alert = UIAlertController(title: "移除网站数据", message: "已锁定的站点受到严格保护，登录数据不会被删除。", preferredStyle: .actionSheet)

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
        let isMainLocked = CookieLockStore.shared.isLocked(domain: group.mainDomain)

        let toggleLockAction = UIContextualAction(
            style: .normal,
            title: isMainLocked ? "解锁主域" : "锁定主域"
        ) { [weak self] _, _, completion in
            guard let self = self else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            CookieLockStore.shared.toggleLock(domain: group.mainDomain)
            self.loadData()
            completion(true)
        }
        toggleLockAction.backgroundColor = isMainLocked ? .systemGray : UIColor(red: 0.12, green: 0.65, blue: 0.45, alpha: 1.0)

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
        let allLocked = !records.isEmpty && records.allSatisfy { CookieLockStore.shared.isLocked(domain: $0.displayName) }
        let title = allLocked ? "全部解锁" : "全部锁定"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: title,
            style: .plain,
            target: self,
            action: #selector(handleToggleAllLock)
        )
    }

    @objc private func handleToggleAllLock() {
        let allLocked = !records.isEmpty && records.allSatisfy { CookieLockStore.shared.isLocked(domain: $0.displayName) }
        let allNames = records.map { $0.displayName }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if allLocked {
            CookieLockStore.shared.unlockAll(domains: allNames)
            CookieLockStore.shared.unlock(domain: mainDomain)
        } else {
            CookieLockStore.shared.lockAll(domains: allNames)
            CookieLockStore.shared.lock(domain: mainDomain)
        }
        updateRightBarButton()
        tableView.reloadData()
    }

    private func setupHeaderView() {
        let header = UIView()
        header.backgroundColor = .clear

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "主站点共 \(records.count) 个域名。点击单项可独立切换锁定；锁定的站点仅保护登录凭据，缓存文件在清理时仍会被正常释放。"
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

final class DomainSettingsViewController: UITableViewController {
    private let domain: String
    var onSettingsChanged: (() -> Void)?
    var onFullscreenChanged: ((Bool) -> Void)?
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
        return section == 0 ? 4 : 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)

        if indexPath.section == 0 {
            let switchView = UISwitch()
            switchView.tag = indexPath.row

            if indexPath.row == 0 {
                cell.textLabel?.text = "全屏浏览"
                switchView.isOn = DomainSettingsStore.shared.getBool(domain: domain, setting: "autoFullscreen", defaultVal: false)
                switchView.isEnabled = true
                switchView.addTarget(self, action: #selector(handleSwitchChanged(_:)), for: .valueChanged)
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
            } else if indexPath.row == 3 {
                cell.textLabel?.text = "信任网站证书"
                switchView.isOn = CertificateTrustStore.shared.isHostTrusted(domain)
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
        if sender.tag == 0 {
            DomainSettingsStore.shared.setBool(domain: domain, setting: "autoFullscreen", value: sender.isOn)
            onFullscreenChanged?(sender.isOn)
        } else if sender.tag == 1 {
            DomainSettingsStore.shared.setBool(domain: domain, setting: "adBlock", value: sender.isOn)
            onSettingsChanged?()
        } else if sender.tag == 2 {
            DomainSettingsStore.shared.setBool(domain: domain, setting: "userScripts", value: sender.isOn)
            onSettingsChanged?()
        } else if sender.tag == 3 {
            if sender.isOn {
                CertificateTrustStore.shared.trustHost(domain)
            } else {
                CertificateTrustStore.shared.untrustHost(domain)
            }
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
