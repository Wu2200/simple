import UIKit
import WebKit

// MARK: - 主域名聚合数据模型
public struct PrimaryDomainGroup {
    public let rootDomain: String
    public var records: [WKWebsiteDataRecord]

    public var allDataTypes: Set<String> {
        var types = Set<String>()
        for r in records {
            types.formUnion(r.dataTypes)
        }
        return types
    }

    public var hasAnyLocked: Bool {
        return records.contains { CookieLockStore.shared.isLocked(domain: $0.displayName) }
    }

    public var isFullyLocked: Bool {
        guard !records.isEmpty else { return false }
        return records.allSatisfy { CookieLockStore.shared.isLocked(domain: $0.displayName) }
    }

    public var lockedCount: Int {
        return records.filter { CookieLockStore.shared.isLocked(domain: $0.displayName) }.count
    }

    public var hasCookies: Bool {
        return records.contains { $0.dataTypes.contains(WKWebsiteDataTypeCookies) }
    }
}

// MARK: - 网站数据管理主页面（仅展示主域名）
final class WebsiteDataViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchController = UISearchController(searchResultsController: nil)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var allRawRecords: [WKWebsiteDataRecord] = []
    private var domainGroups: [PrimaryDomainGroup] = []
    private var filteredGroups: [PrimaryDomainGroup] = []

    private var isSearching: Bool {
        return searchController.isActive && !(searchController.searchBar.text?.isEmpty ?? true)
    }

    private let headerDescriptionLabel: UILabel = {
        let label = UILabel()
        label.text = "数据可能会减少跟踪，但也可能允许网站退出登录。点击主域名可展开查看其名下的所有子域名与关联域名，并可单独对其锁定。"
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupSearch()
        loadWebsiteData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuildGroups()
    }

    private func setupUI() {
        title = "管理网站数据"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "移除",
            style: .plain,
            target: self,
            action: #selector(handleRemoveAction)
        )

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(WebsiteDataUnifiedCell.self, forCellReuseIdentifier: WebsiteDataUnifiedCell.reuseIdentifier)
        tableView.rowHeight = 64
        view.addSubview(tableView)

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)

        let headerView = UIView()
        headerDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(headerDescriptionLabel)

        NSLayoutConstraint.activate([
            headerDescriptionLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 8),
            headerDescriptionLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            headerDescriptionLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),
            headerDescriptionLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -8),

            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        headerView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 60)
        tableView.tableHeaderView = headerView
    }

    private func setupSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜索主域名或数据类型（如 cookie）"
        navigationItem.searchController = searchController
        definesPresentationContext = true
    }

    private func loadWebsiteData() {
        activityIndicator.startAnimating()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { [weak self] records in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.activityIndicator.stopAnimating()
                self.allRawRecords = records
                self.rebuildGroups()
            }
        }
    }

    private func rebuildGroups() {
        var dict: [String: [WKWebsiteDataRecord]] = [:]
        for record in allRawRecords {
            let root = DomainRelationEngine.extractRootDomain(from: record.displayName)
            dict[root, default: []].append(record)
        }

        var groups: [PrimaryDomainGroup] = []
        for (root, recs) in dict {
            groups.append(PrimaryDomainGroup(rootDomain: root, records: recs))
        }

        domainGroups = groups.sorted { (g1, g2) -> Bool in
            if g1.hasAnyLocked != g2.hasAnyLocked {
                return g1.hasAnyLocked && !g2.hasAnyLocked
            }
            if g1.hasCookies != g2.hasCookies {
                return g1.hasCookies && !g2.hasCookies
            }
            return g1.rootDomain.localizedStandardCompare(g2.rootDomain) == .orderedAscending
        }

        if isSearching {
            updateSearchResults(for: searchController)
        } else {
            tableView.reloadData()
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        guard let text = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else {
            filteredGroups = []
            tableView.reloadData()
            return
        }

        filteredGroups = domainGroups.filter { group in
            let hostMatch = group.rootDomain.lowercased().contains(text)
            let subHostMatch = group.records.contains { $0.displayName.lowercased().contains(text) }
            let typeString = WebsiteDataUnifiedCell.formatDataTypes(group.allDataTypes).lowercased()
            let typeMatch = typeString.contains(text)
            return hostMatch || subHostMatch || typeMatch
        }
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return isSearching ? filteredGroups.count : domainGroups.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: WebsiteDataUnifiedCell.reuseIdentifier, for: indexPath) as? WebsiteDataUnifiedCell else {
            return UITableViewCell()
        }
        let group = isSearching ? filteredGroups[indexPath.row] : domainGroups[indexPath.row]
        cell.configureForGroup(group: group)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let group = isSearching ? filteredGroups[indexPath.row] : domainGroups[indexPath.row]
        let relatedRecords = DomainRelationEngine.findRelatedRecords(for: group.rootDomain, in: allRawRecords)

        let detailVC = WebsiteRelatedDomainsViewController(
            rootDomain: group.rootDomain,
            allMatchedRecords: relatedRecords,
            onDismiss: { [weak self] in
                self?.rebuildGroups()
            }
        )
        navigationController?.pushViewController(detailVC, animated: true)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let group = isSearching ? filteredGroups[indexPath.row] : domainGroups[indexPath.row]

        let deleteAction = UIContextualAction(style: .destructive, title: "移除未锁定") { [weak self] (_, _, completion) in
            guard let self = self else { return }
            let unlocked = group.records.filter { !CookieLockStore.shared.isLocked(domain: $0.displayName) }
            if unlocked.isEmpty {
                let alert = UIAlertController(title: "域名已被锁定", message: "该主域名下的所有子域名均处于锁定保护状态，无法直接移除。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "确定", style: .default))
                self.present(alert, animated: true)
                completion(false)
                return
            }

            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            WKWebsiteDataStore.default().removeData(ofTypes: types, for: unlocked) {
                DispatchQueue.main.async {
                    self.loadWebsiteData()
                    completion(true)
                }
            }
        }

        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    @objc private func handleRemoveAction() {
        let alert = UIAlertController(title: "移除网站数据", message: "已锁定的域名受到严格保护，不会被删除。", preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "移除所有未锁定数据", style: .destructive, handler: { [weak self] _ in
            self?.removeUnlockedData()
        }))

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(alert, animated: true)
    }

    private func removeUnlockedData() {
        let unlocked = allRawRecords.filter { !CookieLockStore.shared.isLocked(domain: $0.displayName) }
        guard !unlocked.isEmpty else { return }

        activityIndicator.startAnimating()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, for: unlocked) { [weak self] in
            DispatchQueue.main.async {
                self?.loadWebsiteData()
            }
        }
    }
}

// MARK: - 关联域名管理二级页面（逐个单项锁定）
final class WebsiteRelatedDomainsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let rootDomain: String
    private var records: [WKWebsiteDataRecord]
    private let onDismiss: () -> Void
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    init(rootDomain: String, allMatchedRecords: [WKWebsiteDataRecord], onDismiss: @escaping () -> Void) {
        self.rootDomain = rootDomain
        self.records = allMatchedRecords
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onDismiss()
    }

    private func setupUI() {
        title = rootDomain
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = nil

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(WebsiteDataUnifiedCell.self, forCellReuseIdentifier: WebsiteDataUnifiedCell.reuseIdentifier)
        tableView.rowHeight = 64
        view.addSubview(tableView)

        let headerView = UIView()
        let infoLabel = UILabel()
        infoLabel.text = "主站点 [ \(rootDomain) ] 下共发现 \(records.count) 个域名。每个域名均须单独点击进行锁定或解锁，已锁定的域名在清理缓存时受到保护。"
        infoLabel.font = .systemFont(ofSize: 13, weight: .regular)
        infoLabel.textColor = .secondaryLabel
        infoLabel.numberOfLines = 0
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(infoLabel)

        NSLayoutConstraint.activate([
            infoLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 10),
            infoLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            infoLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),
            infoLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -10),

            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        headerView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 68)
        tableView.tableHeaderView = headerView
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return records.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: WebsiteDataUnifiedCell.reuseIdentifier, for: indexPath) as? WebsiteDataUnifiedCell else {
            return UITableViewCell()
        }
        let record = records[indexPath.row]
        let isLocked = CookieLockStore.shared.isLocked(domain: record.displayName)
        cell.configureForSingleRecord(record: record, isLocked: isLocked)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let record = records[indexPath.row]
        _ = CookieLockStore.shared.toggleLock(domain: record.displayName)

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let record = records[indexPath.row]
        let isLocked = CookieLockStore.shared.isLocked(domain: record.displayName)

        let lockAction = UIContextualAction(style: .normal, title: isLocked ? "解锁" : "锁定") { [weak self] (_, _, completion) in
            _ = CookieLockStore.shared.toggleLock(domain: record.displayName)
            self?.tableView.reloadRows(at: [indexPath], with: .automatic)
            completion(true)
        }
        lockAction.backgroundColor = isLocked ? .systemGray : UIColor(red: 0.12, green: 0.72, blue: 0.53, alpha: 1.0)

        let deleteAction = UIContextualAction(style: .destructive, title: "移除") { [weak self] (_, _, completion) in
            guard let self = self else { return }
            if CookieLockStore.shared.isLocked(domain: record.displayName) {
                let alert = UIAlertController(title: "域名已被锁定", message: "若要移除该域名的数据，请先解除锁定。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "确定", style: .default))
                self.present(alert, animated: true)
                completion(false)
                return
            }
            WKWebsiteDataStore.default().removeData(ofTypes: record.dataTypes, for: [record]) {
                DispatchQueue.main.async {
                    self.records.remove(at: indexPath.row)
                    self.tableView.deleteRows(at: [indexPath], with: .fade)
                    completion(true)
                }
            }
        }

        return UISwipeActionsConfiguration(actions: [deleteAction, lockAction])
    }
}

// MARK: - 统一网站数据卡片 Cell
final class WebsiteDataUnifiedCell: UITableViewCell {

    static let reuseIdentifier = "WebsiteDataUnifiedCell"

    private let faviconImageView = UIImageView()
    private let domainLabel = UILabel()
    private let lockBadge = UIView()
    private let lockIconImageView = UIImageView()
    private let dataTypesLabel = UILabel()
    private let rightBadgeLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = .secondarySystemGroupedBackground

        faviconImageView.translatesAutoresizingMaskIntoConstraints = false
        faviconImageView.layer.cornerRadius = 6
        faviconImageView.clipsToBounds = true
        faviconImageView.contentMode = .scaleAspectFit
        contentView.addSubview(faviconImageView)

        domainLabel.translatesAutoresizingMaskIntoConstraints = false
        domainLabel.font = .systemFont(ofSize: 15.5, weight: .medium)
        domainLabel.textColor = .label
        contentView.addSubview(domainLabel)

        lockBadge.translatesAutoresizingMaskIntoConstraints = false
        lockBadge.backgroundColor = UIColor(red: 0.12, green: 0.72, blue: 0.53, alpha: 1.0)
        lockBadge.layer.cornerRadius = 8
        lockBadge.clipsToBounds = true
        contentView.addSubview(lockBadge)

        lockIconImageView.translatesAutoresizingMaskIntoConstraints = false
        lockIconImageView.image = UIImage(systemName: "lock.fill")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        lockIconImageView.tintColor = .white
        lockIconImageView.contentMode = .scaleAspectFit
        lockBadge.addSubview(lockIconImageView)

        dataTypesLabel.translatesAutoresizingMaskIntoConstraints = false
        dataTypesLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        dataTypesLabel.textColor = .secondaryLabel
        contentView.addSubview(dataTypesLabel)

        rightBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        rightBadgeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        rightBadgeLabel.textColor = .tertiaryLabel
        contentView.addSubview(rightBadgeLabel)

        NSLayoutConstraint.activate([
            faviconImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            faviconImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            faviconImageView.widthAnchor.constraint(equalToConstant: 28),
            faviconImageView.heightAnchor.constraint(equalToConstant: 28),

            domainLabel.leadingAnchor.constraint(equalTo: faviconImageView.trailingAnchor, constant: 12),
            domainLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            domainLabel.trailingAnchor.constraint(lessThanOrEqualTo: lockBadge.leadingAnchor, constant: -6),

            lockBadge.centerYAnchor.constraint(equalTo: domainLabel.centerYAnchor),
            lockBadge.trailingAnchor.constraint(lessThanOrEqualTo: rightBadgeLabel.leadingAnchor, constant: -8),
            lockBadge.widthAnchor.constraint(equalToConstant: 16),
            lockBadge.heightAnchor.constraint(equalToConstant: 16),

            lockIconImageView.centerXAnchor.constraint(equalTo: lockBadge.centerXAnchor),
            lockIconImageView.centerYAnchor.constraint(equalTo: lockBadge.centerYAnchor),
            lockIconImageView.widthAnchor.constraint(equalToConstant: 10),
            lockIconImageView.heightAnchor.constraint(equalToConstant: 10),

            dataTypesLabel.leadingAnchor.constraint(equalTo: domainLabel.leadingAnchor),
            dataTypesLabel.topAnchor.constraint(equalTo: domainLabel.bottomAnchor, constant: 4),
            dataTypesLabel.trailingAnchor.constraint(equalTo: rightBadgeLabel.leadingAnchor, constant: -8),

            rightBadgeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            rightBadgeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    func configureForGroup(group: PrimaryDomainGroup) {
        domainLabel.text = group.rootDomain
        dataTypesLabel.text = Self.formatDataTypes(group.allDataTypes)

        if group.isFullyLocked {
            lockBadge.isHidden = false
            lockBadge.backgroundColor = UIColor(red: 0.12, green: 0.72, blue: 0.53, alpha: 1.0)
            domainLabel.textColor = UIColor(red: 0.12, green: 0.72, blue: 0.53, alpha: 1.0)
        } else if group.hasAnyLocked {
            lockBadge.isHidden = false
            lockBadge.backgroundColor = .systemOrange
            domainLabel.textColor = .label
        } else {
            lockBadge.isHidden = true
            domainLabel.textColor = .label
        }

        accessoryType = .disclosureIndicator
        rightBadgeLabel.text = "\(group.records.count) 个域名"
        rightBadgeLabel.isHidden = false

        faviconImageView.image = UIImage(systemName: "globe")
        faviconImageView.tintColor = .systemGray3
        loadFavicon(for: group.rootDomain)
    }

    func configureForSingleRecord(record: WKWebsiteDataRecord, isLocked: Bool) {
        domainLabel.text = record.displayName
        dataTypesLabel.text = Self.formatDataTypes(record.dataTypes)

        if isLocked {
            lockBadge.isHidden = false
            lockBadge.backgroundColor = UIColor(red: 0.12, green: 0.72, blue: 0.53, alpha: 1.0)
            domainLabel.textColor = UIColor(red: 0.12, green: 0.72, blue: 0.53, alpha: 1.0)
        } else {
            lockBadge.isHidden = true
            domainLabel.textColor = .label
        }

        accessoryType = .none
        rightBadgeLabel.text = ""
        rightBadgeLabel.isHidden = true

        faviconImageView.image = UIImage(systemName: "globe")
        faviconImageView.tintColor = .systemGray3
        loadFavicon(for: record.displayName)
    }

    private func loadFavicon(for host: String) {
        let clean = host.lowercased()
        guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(clean)&sz=64") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data, let img = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self.faviconImageView.image = img
            }
        }.resume()
    }

    static func formatDataTypes(_ types: Set<String>) -> String {
        var items: [String] = []
        if types.contains(WKWebsiteDataTypeCookies) {
            items.append("Cookies")
        }
        if types.contains(WKWebsiteDataTypeDiskCache) {
            items.append("磁盘缓存")
        }
        if types.contains(WKWebsiteDataTypeMemoryCache) {
            items.append("内存缓存")
        }
        if types.contains(WKWebsiteDataTypeIndexedDBDatabases) {
            items.append("索引数据库")
        }
        if types.contains(WKWebsiteDataTypeLocalStorage) {
            items.append("本地存储")
        }
        if types.contains(WKWebsiteDataTypeSessionStorage) {
            items.append("会话存储")
        }
        if types.contains(WKWebsiteDataTypeWebSQLDatabases) {
            items.append("WebSQL")
        }
        if items.isEmpty {
            return "本地网站数据"
        }
        return items.joined(separator: ", ")
    }
}

// MARK: - 关联域名拓扑识别引擎
public enum DomainRelationEngine {

    public static func findRelatedRecords(for rootDomain: String, in records: [WKWebsiteDataRecord]) -> [WKWebsiteDataRecord] {
        var matched: [WKWebsiteDataRecord] = []
        for record in records {
            let host = record.displayName
            let hostRoot = extractRootDomain(from: host)
            if hostRoot == rootDomain || host == rootDomain || isKnownRelatedService(h1: rootDomain, h2: host) {
                matched.append(record)
            }
        }

        return matched.sorted { (r1, r2) -> Bool in
            if r1.displayName == rootDomain { return true }
            if r2.displayName == rootDomain { return false }
            let l1 = CookieLockStore.shared.isLocked(domain: r1.displayName)
            let l2 = CookieLockStore.shared.isLocked(domain: r2.displayName)
            if l1 != l2 { return l1 && !l2 }
            let c1 = r1.dataTypes.contains(WKWebsiteDataTypeCookies)
            let c2 = r2.dataTypes.contains(WKWebsiteDataTypeCookies)
            if c1 != c2 { return c1 && !c2 }
            return r1.displayName < r2.displayName
        }
    }

    public static func extractRootDomain(from host: String) -> String {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = clean.split(separator: ".")
        guard parts.count >= 2 else { return clean }

        if parts.allSatisfy({ Int($0) != nil }) && parts.count == 4 {
            return clean
        }

        if parts.count >= 3 {
            let lastTwo = "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
            let secondLevelSuffixes: Set<String> = [
                "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
                "co.uk", "org.uk", "me.uk",
                "co.jp", "ne.jp",
                "com.hk", "org.hk",
                "com.tw", "org.tw"
            ]
            if secondLevelSuffixes.contains(lastTwo) {
                return "\(parts[parts.count - 3]).\(lastTwo)"
            }
        }

        return "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
    }

    private static func isKnownRelatedService(h1: String, h2: String) -> Bool {
        let pair = [h1.lowercased(), h2.lowercased()]
        if pair.contains(where: { $0.contains("chatgpt.com") }) && pair.contains(where: { $0.contains("oaistatic.com") || $0.contains("openai.com") }) {
            return true
        }
        if pair.contains(where: { $0.contains("github.com") }) && pair.contains(where: { $0.contains("githubassets.com") }) {
            return true
        }
        if pair.contains(where: { $0.contains("bilibili.com") }) && pair.contains(where: { $0.contains("hdslb.com") || $0.contains("bilivideo.com") }) {
            return true
        }
        if pair.contains(where: { $0.contains("google.com") }) && pair.contains(where: { $0.contains("gstatic.com") || $0.contains("googleusercontent.com") }) {
            return true
        }
        return false
    }
}
