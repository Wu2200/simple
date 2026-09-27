import UIKit
import WebKit

// MARK: - 主域名聚合数据模型
struct PrimaryDomainGroup {
    let rootDomain: String
    var records: [WKWebsiteDataRecord]

    var allDataTypes: Set<String> {
        var types = Set<String>()
        for r in records {
            types.formUnion(r.dataTypes)
        }
        return types
    }

    var hasAnyLocked: Bool {
        return records.contains { CookieLockStore.shared.isLocked(host: $0.displayName) }
    }

    var isFullyLocked: Bool {
        guard !records.isEmpty else { return false }
        return records.allSatisfy { CookieLockStore.shared.isLocked(host: $0.displayName) }
    }

    var hasCookies: Bool {
        return records.contains { $0.dataTypes.contains(WKWebsiteDataTypeCookies) }
    }
}

// MARK: - 网站数据管理视图控制器（只显示主域名）
final class WebsiteDataManagerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchController = UISearchController(searchResultsController: nil)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var allRawRecords: [WKWebsiteDataRecord] = []
    private var domainGroups: [PrimaryDomainGroup] = []
    private var filteredGroups: [PrimaryDomainGroup] = []

    private var isSearching: Bool {
        return searchController.isActive && !(searchController.searchBar.text?.isEmpty ?? true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "管理网站数据"
        view.backgroundColor = .systemGroupedBackground

        setupSearch()
        setupUI()
        loadWebsiteData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuildGroups()
    }

    private func setupSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜索网站主域名"
        navigationItem.searchController = searchController
        definesPresentationContext = true
    }

    private func setupUI() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "移除", style: .plain, target: self, action: #selector(handleRemoveAction))

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(WebsiteDataUnifiedCell.self, forCellReuseIdentifier: WebsiteDataUnifiedCell.reuseIdentifier)
        tableView.rowHeight = 64
        view.addSubview(tableView)

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
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
            group.rootDomain.lowercased().contains(text) ||
            group.records.contains { $0.displayName.lowercased().contains(text) }
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

    @objc private func handleRemoveAction() {
        let alert = UIAlertController(title: "移除网站数据", message: "将移除所有未锁定的网站数据，已锁定的域名受到保护。", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "移除所有未锁定数据", style: .destructive, handler: { [weak self] _ in
            self?.removeUnlockedData()
        }))
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func removeUnlockedData() {
        let unlocked = allRawRecords.filter { !CookieLockStore.shared.isLocked(host: $0.displayName) }
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

// MARK: - 关联域名二级单项锁定控制器
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
        title = rootDomain
        view.backgroundColor = .systemGroupedBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(WebsiteDataUnifiedCell.self, forCellReuseIdentifier: WebsiteDataUnifiedCell.reuseIdentifier)
        tableView.rowHeight = 64
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onDismiss()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return records.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: WebsiteDataUnifiedCell.reuseIdentifier, for: indexPath) as? WebsiteDataUnifiedCell else {
            return UITableViewCell()
        }
        let record = records[indexPath.row]
        let isLocked = CookieLockStore.shared.isLocked(host: record.displayName)
        cell.configureForSingleRecord(record: record, isLocked: isLocked)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let record = records[indexPath.row]
        CookieLockStore.shared.toggleLock(host: record.displayName)

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }
}

// MARK: - 网站数据单元格
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
        FaviconLoader.shared.loadFavicon(for: group.rootDomain) { [weak self] img in
            self?.faviconImageView.image = img ?? UIImage(systemName: "globe")
        }
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
        FaviconLoader.shared.loadFavicon(for: record.displayName) { [weak self] img in
            self?.faviconImageView.image = img ?? UIImage(systemName: "globe")
        }
    }

    static func formatDataTypes(_ types: Set<String>) -> String {
        var items: [String] = []
        if types.contains(WKWebsiteDataTypeCookies) { items.append("Cookies") }
        if types.contains(WKWebsiteDataTypeDiskCache) { items.append("磁盘缓存") }
        if types.contains(WKWebsiteDataTypeMemoryCache) { items.append("内存缓存") }
        if types.contains(WKWebsiteDataTypeIndexedDBDatabases) { items.append("索引数据库") }
        if types.contains(WKWebsiteDataTypeLocalStorage) { items.append("本地存储") }
        if types.contains(WKWebsiteDataTypeSessionStorage) { items.append("会话存储") }
        if types.contains(WKWebsiteDataTypeWebSQLDatabases) { items.append("WebSQL") }
        return items.isEmpty ? "本地网站数据" : items.joined(separator: ", ")
    }
}

// MARK: - 关联域名拓扑识别引擎
enum DomainRelationEngine {

    static func findRelatedRecords(for rootDomain: String, in records: [WKWebsiteDataRecord]) -> [WKWebsiteDataRecord] {
        var matched: [WKWebsiteDataRecord] = []
        for record in records {
            let host = record.displayName
            let hostRoot = extractRootDomain(from: host)
            if hostRoot == rootDomain || host == rootDomain || isKnownRelated(h1: rootDomain, h2: host) {
                matched.append(record)
            }
        }

        return matched.sorted { (r1, r2) -> Bool in
            if r1.displayName == rootDomain { return true }
            if r2.displayName == rootDomain { return false }
            let l1 = CookieLockStore.shared.isLocked(host: r1.displayName)
            let l2 = CookieLockStore.shared.isLocked(host: r2.displayName)
            if l1 != l2 { return l1 && !l2 }
            let c1 = r1.dataTypes.contains(WKWebsiteDataTypeCookies)
            let c2 = r2.dataTypes.contains(WKWebsiteDataTypeCookies)
            if c1 != c2 { return c1 && !c2 }
            return r1.displayName < r2.displayName
        }
    }

    static func extractRootDomain(from host: String) -> String {
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
                "co.uk", "org.uk", "me.uk", "co.jp", "com.hk"
            ]
            if secondLevelSuffixes.contains(lastTwo) {
                return "\(parts[parts.count - 3]).\(lastTwo)"
            }
        }

        return "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
    }

    private static func isKnownRelated(h1: String, h2: String) -> Bool {
        let pair = [h1.lowercased(), h2.lowercased()]
        if pair.contains(where: { $0.contains("chatgpt.com") }) && pair.contains(where: { $0.contains("oaistatic.com") || $0.contains("openai.com") }) {
            return true
        }
        if pair.contains(where: { $0.contains("github.com") }) && pair.contains(where: { $0.contains("githubassets.com") }) {
            return true
        }
        if pair.contains(where: { $0.contains("bilibili.com") }) && pair.contains(where: { $0.contains("hdslb.com") }) {
            return true
        }
        return false
    }
}

// 兼容外部别名
typealias WebsiteDataViewController = WebsiteDataManagerViewController
