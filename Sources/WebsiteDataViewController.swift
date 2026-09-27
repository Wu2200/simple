import UIKit
import WebKit

public struct DomainDataGroup {
    public let displayName: String
    public var records: [WKWebsiteDataRecord]
    public var dataTypes: Set<String>

    public init(displayName: String, records: [WKWebsiteDataRecord] = [], dataTypes: Set<String> = []) {
        self.displayName = displayName
        self.records = records
        self.dataTypes = dataTypes
    }
}

public final class WebsiteDataManagerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {

    private var allGroups: [DomainDataGroup] = []
    private var filteredGroups: [DomainDataGroup] = []
    private let searchController = UISearchController(searchResultsController: nil)

    private let tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "没有找到网站数据"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 15)
        label.isHidden = true
        return label
    }()

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "管理网站数据"
        view.backgroundColor = .systemGroupedBackground

        setupNavigationBar()
        setupSearchController()
        setupLayout()

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DomainCell")

        loadWebsiteData()
    }

    private func setupNavigationBar() {
        if let nav = navigationController, nav.viewControllers.count > 1 {
            let backButton = UIBarButtonItem(
                image: UIImage(systemName: "chevron.left"),
                style: .plain,
                target: self,
                action: #selector(handleBack)
            )
            navigationItem.leftBarButtonItem = backButton
        } else {
            let doneButton = UIBarButtonItem(
                title: "完成",
                style: .done,
                target: self,
                action: #selector(handleBack)
            )
            navigationItem.leftBarButtonItem = doneButton
        }

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "全部清除",
            style: .plain,
            target: self,
            action: #selector(handleClearAllTapped)
        )
    }

    @objc private func handleBack() {
        if let nav = navigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    private func setupSearchController() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜索网站域名"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    private func setupLayout() {
        view.addSubview(tableView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func loadWebsiteData() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { [weak self] records in
            DispatchQueue.main.async {
                self?.aggregateRecords(records)
            }
        }
    }

    private func aggregateRecords(_ records: [WKWebsiteDataRecord]) {
        var groupMap: [String: DomainDataGroup] = [:]
        for record in records {
            let name = record.displayName
            if var existing = groupMap[name] {
                existing.records.append(record)
                existing.dataTypes.formUnion(record.dataTypes)
                groupMap[name] = existing
            } else {
                groupMap[name] = DomainDataGroup(displayName: name, records: [record], dataTypes: record.dataTypes)
            }
        }

        allGroups = groupMap.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        applySearchFilter()
    }

    public func updateSearchResults(for searchController: UISearchController) {
        applySearchFilter()
    }

    private func applySearchFilter() {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if query.isEmpty {
            filteredGroups = allGroups
        } else {
            filteredGroups = allGroups.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
        }
        emptyLabel.isHidden = !filteredGroups.isEmpty
        tableView.reloadData()
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filteredGroups.count
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let group = filteredGroups[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "DomainCell")
        cell.textLabel?.text = group.displayName
        cell.textLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)

        var typeDescriptions: [String] = []
        if group.dataTypes.contains(WKWebsiteDataTypeCookies) { typeDescriptions.append("Cookies") }
        if group.dataTypes.contains(WKWebsiteDataTypeDiskCache) || group.dataTypes.contains(WKWebsiteDataTypeMemoryCache) { typeDescriptions.append("缓存") }
        if group.dataTypes.contains(WKWebsiteDataTypeLocalStorage) { typeDescriptions.append("本地存储") }
        if group.dataTypes.contains(WKWebsiteDataTypeIndexedDBDatabases) { typeDescriptions.append("数据库") }

        cell.detailTextLabel?.text = typeDescriptions.isEmpty ? "网站数据" : typeDescriptions.joined(separator: " · ")
        cell.detailTextLabel?.textColor = .secondaryLabel
        return cell
    }

    public func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    public func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }

        let group = filteredGroups[indexPath.row]
        let types = group.dataTypes
        let records = group.records

        WKWebsiteDataStore.default().removeData(ofTypes: types, for: records) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.allGroups.removeAll { $0.displayName == group.displayName }
                self.filteredGroups.remove(at: indexPath.row)
                tableView.deleteRows(at: [indexPath], with: .automatic)
                self.emptyLabel.isHidden = !self.filteredGroups.isEmpty
                NotificationCenter.default.post(name: NSNotification.Name("WebsiteDataClearedNotification"), object: nil)
            }
        }
    }

    @objc private func handleClearAllTapped() {
        guard !allGroups.isEmpty else { return }

        let alert = UIAlertController(
            title: "全部清除",
            message: "确定要清除所有网站的数据与Cookies吗？",
            preferredStyle: .actionSheet
        )

        let confirm = UIAlertAction(title: "全部清除", style: .destructive) { [weak self] _ in
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            let allRecords = self?.allGroups.flatMap { $0.records } ?? []
            WKWebsiteDataStore.default().removeData(ofTypes: types, for: allRecords) {
                DispatchQueue.main.async {
                    self?.allGroups.removeAll()
                    self?.filteredGroups.removeAll()
                    self?.tableView.reloadData()
                    self?.emptyLabel.isHidden = false
                    NotificationCenter.default.post(name: NSNotification.Name("WebsiteDataClearedNotification"), object: nil)
                }
            }
        }

        let cancel = UIAlertAction(title: "取消", style: .cancel)
        alert.addAction(confirm)
        alert.addAction(cancel)

        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }

        present(alert, animated: true)
    }
}

public struct CustomUserAgentItem: Codable, Equatable {
    public let id: String
    public var name: String
    public var value: String
    public var isMobile: Bool

    public init(id: String = UUID().uuidString, name: String, value: String, isMobile: Bool) {
        self.id = id
        self.name = name
        self.value = value
        self.isMobile = isMobile
    }
}

public final class UserAgentManager {
    public static let shared = UserAgentManager()

    private let customUAsKey = "SimpleBrowser.CustomUAs.List"
    private let activeMobileIdKey = "SimpleBrowser.ActiveMobileUAId"
    private let activeDesktopIdKey = "SimpleBrowser.ActiveDesktopUAId"

    public let presetMobileUAs: [CustomUserAgentItem] = [
        CustomUserAgentItem(id: "preset_m_safari", name: "iPhone (Safari 默认)", value: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1", isMobile: true),
        CustomUserAgentItem(id: "preset_m_chrome", name: "iPhone (Chrome Mobile)", value: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/123.0.6312.52 Mobile/15E148 Safari/604.1", isMobile: true),
        CustomUserAgentItem(id: "preset_m_android", name: "Android (Pixel Chrome)", value: "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.6312.80 Mobile Safari/537.36", isMobile: true)
    ]

    public let presetDesktopUAs: [CustomUserAgentItem] = [
        CustomUserAgentItem(id: "preset_d_mac", name: "Mac (Safari 默认)", value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15", isMobile: false),
        CustomUserAgentItem(id: "preset_d_win_chrome", name: "Windows (Chrome)", value: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36", isMobile: false),
        CustomUserAgentItem(id: "preset_d_win_edge", name: "Windows (Edge)", value: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36 Edg/123.0.2420.65", isMobile: false)
    ]

    private init() {}

    public func getCustomUAs() -> [CustomUserAgentItem] {
        guard let data = UserDefaults.standard.data(forKey: customUAsKey),
              let list = try? JSONDecoder().decode([CustomUserAgentItem].self, from: data) else {
            return []
        }
        return list
    }

    public func saveCustomUAs(_ list: [CustomUserAgentItem]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: customUAsKey)
        }
    }

    public func getActiveMobileId() -> String {
        return UserDefaults.standard.string(forKey: activeMobileIdKey) ?? presetMobileUAs[0].id
    }

    public func setActiveMobileId(_ id: String) {
        UserDefaults.standard.set(id, forKey: activeMobileIdKey)
    }

    public func getActiveDesktopId() -> String {
        return UserDefaults.standard.string(forKey: activeDesktopIdKey) ?? presetDesktopUAs[0].id
    }

    public func setActiveDesktopId(_ id: String) {
        UserDefaults.standard.set(id, forKey: activeDesktopIdKey)
    }

    public func getCurrentUserAgent(isDesktopMode: Bool) -> String {
        if isDesktopMode {
            let activeId = getActiveDesktopId()
            let all = presetDesktopUAs + getCustomUAs().filter { !$0.isMobile }
            return all.first(where: { $0.id == activeId })?.value ?? presetDesktopUAs[0].value
        } else {
            let activeId = getActiveMobileId()
            let all = presetMobileUAs + getCustomUAs().filter { $0.isMobile }
            return all.first(where: { $0.id == activeId })?.value ?? presetMobileUAs[0].value
        }
    }
}

public final class UserAgentSettingsViewController: UITableViewController {

    public var onSelectionChanged: (() -> Void)?

    private var customMobileUAs: [CustomUserAgentItem] = []
    private var customDesktopUAs: [CustomUserAgentItem] = []

    public init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "浏览器标识 (UA)"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleDone))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "UACell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "AddCell")
        loadData()
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    private func loadData() {
        let allCustom = UserAgentManager.shared.getCustomUAs()
        customMobileUAs = allCustom.filter { $0.isMobile }
        customDesktopUAs = allCustom.filter { !$0.isMobile }
        tableView.reloadData()
    }

    public override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? "移动版标识 (手机端)" : "电脑版标识 (桌面端)"
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return UserAgentManager.shared.presetMobileUAs.count + customMobileUAs.count + 1
        } else {
            return UserAgentManager.shared.presetDesktopUAs.count + customDesktopUAs.count + 1
        }
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let isMobileSection = (indexPath.section == 0)
        let presets = isMobileSection ? UserAgentManager.shared.presetMobileUAs : UserAgentManager.shared.presetDesktopUAs
        let customs = isMobileSection ? customMobileUAs : customDesktopUAs
        let activeId = isMobileSection ? UserAgentManager.shared.getActiveMobileId() : UserAgentAgentManagerActiveDesktopId()

        if indexPath.row < presets.count {
            let item = presets[indexPath.row]
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "UACell")
            cell.textLabel?.text = item.name
            cell.textLabel?.font = UIFont.systemFont(ofSize: 16)
            cell.detailTextLabel?.text = item.value
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.accessoryType = (item.id == activeId) ? .checkmark : .none
            return cell
        }

        let customIndex = indexPath.row - presets.count
        if customIndex < customs.count {
            let item = customs[customIndex]
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "UACell")
            cell.textLabel?.text = item.name
            cell.textLabel?.font = UIFont.systemFont(ofSize: 16)
            cell.detailTextLabel?.text = item.value
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.accessoryType = (item.id == activeId) ? .checkmark : .none
            return cell
        }

        let addCell = tableView.dequeueReusableCell(withIdentifier: "AddCell", for: indexPath)
        addCell.textLabel?.text = isMobileSection ? "+ 添加自定义移动版标识" : "+ 添加自定义电脑版标识"
        addCell.textLabel?.textColor = view.tintColor
        addCell.accessoryType = .none
        return addCell
    }

    private func UserAgentAgentManagerActiveDesktopId() -> String {
        return UserAgentManager.shared.getActiveDesktopId()
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let isMobileSection = (indexPath.section == 0)
        let presets = isMobileSection ? UserAgentManager.shared.presetMobileUAs : UserAgentManager.shared.presetDesktopUAs
        let customs = isMobileSection ? customMobileUAs : customDesktopUAs

        if indexPath.row < presets.count {
            let item = presets[indexPath.row]
            if isMobileSection {
                UserAgentManager.shared.setActiveMobileId(item.id)
            } else {
                UserAgentManager.shared.setActiveDesktopId(item.id)
            }
            tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)
            NotificationCenter.default.post(name: NSNotification.Name("UserAgentChangedNotification"), object: nil)
            onSelectionChanged?()
            return
        }

        let customIndex = indexPath.row - presets.count
        if customIndex < customs.count {
            let item = customs[customIndex]
            if isMobileSection {
                UserAgentManager.shared.setActiveMobileId(item.id)
            } else {
                UserAgentManager.shared.setActiveDesktopId(item.id)
            }
            tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)
            NotificationCenter.default.post(name: NSNotification.Name("UserAgentChangedNotification"), object: nil)
            onSelectionChanged?()
            return
        }

        showAddCustomDialog(isMobile: isMobileSection)
    }

    public override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        let isMobileSection = (indexPath.section == 0)
        let presetsCount = isMobileSection ? UserAgentManager.shared.presetMobileUAs.count : UserAgentManager.shared.presetDesktopUAs.count
        let customsCount = isMobileSection ? customMobileUAs.count : customDesktopUAs.count
        return indexPath.row >= presetsCount && indexPath.row < (presetsCount + customsCount)
    }

    public override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }

        let isMobileSection = (indexPath.section == 0)
        let presetsCount = isMobileSection ? UserAgentManager.shared.presetMobileUAs.count : UserAgentManager.shared.presetDesktopUAs.count
        let customIndex = indexPath.row - presetsCount

        var allCustom = UserAgentManager.shared.getCustomUAs()
        if isMobileSection {
            let deleted = customMobileUAs.remove(at: customIndex)
            allCustom.removeAll { $0.id == deleted.id }
            if UserAgentManager.shared.getActiveMobileId() == deleted.id {
                UserAgentManager.shared.setActiveMobileId(UserAgentManager.shared.presetMobileUAs[0].id)
            }
        } else {
            let deleted = customDesktopUAs.remove(at: customIndex)
            allCustom.removeAll { $0.id == deleted.id }
            if UserAgentManager.shared.getActiveDesktopId() == deleted.id {
                UserAgentManager.shared.setActiveDesktopId(UserAgentManager.shared.presetDesktopUAs[0].id)
            }
        }

        UserAgentManager.shared.saveCustomUAs(allCustom)
        tableView.deleteRows(at: [indexPath], with: .automatic)
        NotificationCenter.default.post(name: NSNotification.Name("UserAgentChangedNotification"), object: nil)
        onSelectionChanged?()
    }

    private func showAddCustomDialog(isMobile: Bool) {
        let alert = UIAlertController(
            title: isMobile ? "添加自定义移动版标识" : "添加自定义电脑版标识",
            message: "请输入标识名称及完整的 User-Agent 字符串",
            preferredStyle: .alert
        )

        alert.addTextField { tf in
            tf.placeholder = "标识名称 (例如：手机客户端)"
        }
        alert.addTextField { tf in
            tf.placeholder = "User-Agent 字符串"
            tf.autocorrectionType = .no
            tf.autocapitalizationType = .none
        }

        let cancel = UIAlertAction(title: "取消", style: .cancel)
        let save = UIAlertAction(title: "添加", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let value = alert.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, !value.isEmpty else { return }

            let newItem = CustomUserAgentItem(name: name, value: value, isMobile: isMobile)
            var allCustom = UserAgentManager.shared.getCustomUAs()
            allCustom.append(newItem)
            UserAgentManager.shared.saveCustomUAs(allCustom)

            if isMobile {
                self.customMobileUAs.append(newItem)
                UserAgentManager.shared.setActiveMobileId(newItem.id)
                self.tableView.reloadSections(IndexSet(integer: 0), with: .automatic)
            } else {
                self.customDesktopUAs.append(newItem)
                UserAgentManager.shared.setActiveDesktopId(newItem.id)
                self.tableView.reloadSections(IndexSet(integer: 1), with: .automatic)
            }

            NotificationCenter.default.post(name: NSNotification.Name("UserAgentChangedNotification"), object: nil)
            self.onSelectionChanged?()
        }

        alert.addAction(cancel)
        alert.addAction(save)
        present(alert, animated: true)
    }
}
