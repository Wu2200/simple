import UIKit
import WebKit

public class WebsiteDataManagerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchController = UISearchController(searchResultsController: nil)
    private var allRecords: [WebsiteRecord] = []
    private var filteredRecords: [WebsiteRecord] = []

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "管理网站数据"
        view.backgroundColor = .systemGroupedBackground

        setupNavigationBar()
        setupTableView()
        setupSearchController()
        loadData()
    }

    private func setupNavigationBar() {
        // 带有层级时显示返回，确保退回清除数据页面；单独呈现时显示关闭
        let isPushed = (navigationController?.viewControllers.count ?? 0) > 1
        let backTitle = isPushed ? "返回" : "完成"
        let backItem = UIBarButtonItem(title: backTitle, style: .plain, target: self, action: #selector(handleBack))
        navigationItem.leftBarButtonItem = backItem

        let clearAllItem = UIBarButtonItem(title: "全部移除", style: .plain, target: self, action: #selector(handleClearAll))
        clearAllItem.tintColor = .systemRed
        navigationItem.rightBarButtonItem = clearAllItem
    }

    @objc private func handleBack() {
        if let nav = navigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func handleClearAll() {
        guard !allRecords.isEmpty else { return }
        let alert = UIAlertController(title: "移除所有网站数据", message: "这可能会退出某些网站的登录状态。", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "全部移除", style: .destructive, handler: { [weak self] _ in
            WebsiteDataManager.shared.clearAllData {
                DispatchQueue.main.async {
                    self?.loadData()
                    NotificationCenter.default.post(name: .didCleanWebsiteData, object: nil)
                }
            }
        }))
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "RecordCell")
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupSearchController() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜索网站"
        navigationItem.searchController = searchController
        definesPresentationContext = true
    }

    private func loadData() {
        WebsiteDataManager.shared.fetchWebsiteRecords { [weak self] records in
            DispatchQueue.main.async {
                self?.allRecords = records
                self?.filteredRecords = records
                self?.tableView.reloadData()
            }
        }
    }

    public func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if query.isEmpty {
            filteredRecords = allRecords
        } else {
            filteredRecords = allRecords.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
        }
        tableView.reloadData()
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filteredRecords.count
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "RecordCell", for: indexPath)
        let record = filteredRecords[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = record.displayName
        content.secondaryText = record.dataTypesDescription
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        return cell
    }

    public func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let record = filteredRecords[indexPath.row]
        WebsiteDataManager.shared.removeRecord(record) { [weak self] in
            DispatchQueue.main.async {
                self?.loadData()
                NotificationCenter.default.post(name: .didCleanWebsiteData, object: nil)
            }
        }
    }
}

// MARK: - 浏览器标识 (UA) 设置控制器（彻底移除独立自定义板块，直接内置在对应板块下）

public final class UserAgentViewController: UITableViewController {

    public init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "浏览器标识"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "UACell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "AddUACell")
    }

    public override func numberOfSections(in tableView: UITableView) -> Int {
        return 2 // 0: 移动版标识, 1: 电脑版标识
    }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? "手机版标识 (移动端)" : "电脑版标识 (桌面端)"
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return WebsiteDataManager.shared.presetMobileUAs.count + WebsiteDataManager.shared.customMobileUAs.count + 1
        } else {
            return WebsiteDataManager.shared.presetDesktopUAs.count + WebsiteDataManager.shared.customDesktopUAs.count + 1
        }
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let isMobile = (indexPath.section == 0)
        let presets = isMobile ? WebsiteDataManager.shared.presetMobileUAs : WebsiteDataManager.shared.presetDesktopUAs
        let customs = isMobile ? WebsiteDataManager.shared.customMobileUAs : WebsiteDataManager.shared.customDesktopUAs
        let activeId = isMobile ? WebsiteDataManager.shared.selectedMobileUAId : WebsiteDataManager.shared.selectedDesktopUAId
        let isCurrentMode = isMobile ? !WebsiteDataManager.shared.isDesktopMode : WebsiteDataManager.shared.isDesktopMode

        if indexPath.row < presets.count {
            let item = presets[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "UACell", for: indexPath)
            var config = cell.defaultContentConfiguration()
            config.text = item.name
            config.secondaryText = item.value
            config.secondaryTextProperties.numberOfLines = 1
            config.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = config
            cell.accessoryType = (item.id == activeId && isCurrentMode) ? .checkmark : .none
            return cell
        }

        let customIdx = indexPath.row - presets.count
        if customIdx < customs.count {
            let item = customs[customIdx]
            let cell = tableView.dequeueReusableCell(withIdentifier: "UACell", for: indexPath)
            var config = cell.defaultContentConfiguration()
            config.text = item.name
            config.secondaryText = item.value
            config.secondaryTextProperties.numberOfLines = 1
            config.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = config
            cell.accessoryType = (item.id == activeId && isCurrentMode) ? .checkmark : .none
            return cell
        }

        // 对应板块底部的添加自定义按钮
        let addCell = tableView.dequeueReusableCell(withIdentifier: "AddUACell", for: indexPath)
        var config = addCell.defaultContentConfiguration()
        config.text = isMobile ? "+ 添加自定义手机版标识" : "+ 添加自定义电脑版标识"
        config.textProperties.color = .systemBlue
        addCell.contentConfiguration = config
        addCell.accessoryType = .none
        return addCell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let isMobile = (indexPath.section == 0)
        let presets = isMobile ? WebsiteDataManager.shared.presetMobileUAs : WebsiteDataManager.shared.presetDesktopUAs
        let customs = isMobile ? WebsiteDataManager.shared.customMobileUAs : WebsiteDataManager.shared.customDesktopUAs

        if indexPath.row < presets.count {
            let item = presets[indexPath.row]
            if isMobile {
                WebsiteDataManager.shared.selectedMobileUAId = item.id
                WebsiteDataManager.shared.isDesktopMode = false
            } else {
                WebsiteDataManager.shared.selectedDesktopUAId = item.id
                WebsiteDataManager.shared.isDesktopMode = true
            }
            tableView.reloadData()
            NotificationCenter.default.post(name: .userAgentDidChange, object: nil)
            return
        }

        let customIdx = indexPath.row - presets.count
        if customIdx < customs.count {
            let item = customs[customIdx]
            if isMobile {
                WebsiteDataManager.shared.selectedMobileUAId = item.id
                WebsiteDataManager.shared.isDesktopMode = false
            } else {
                WebsiteDataManager.shared.selectedDesktopUAId = item.id
                WebsiteDataManager.shared.isDesktopMode = true
            }
            tableView.reloadData()
            NotificationCenter.default.post(name: .userAgentDidChange, object: nil)
            return
        }

        // 点击添加
        showAddUADialog(isMobile: isMobile)
    }

    public override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        let isMobile = (indexPath.section == 0)
        let presetsCount = isMobile ? WebsiteDataManager.shared.presetMobileUAs.count : WebsiteDataManager.shared.presetDesktopUAs.count
        let customsCount = isMobile ? WebsiteDataManager.shared.customMobileUAs.count : WebsiteDataManager.shared.customDesktopUAs.count
        return indexPath.row >= presetsCount && indexPath.row < (presetsCount + customsCount)
    }

    public override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let isMobile = (indexPath.section == 0)
        let presetsCount = isMobile ? WebsiteDataManager.shared.presetMobileUAs.count : WebsiteDataManager.shared.presetDesktopUAs.count
        let customIdx = indexPath.row - presetsCount

        if isMobile {
            let item = WebsiteDataManager.shared.customMobileUAs.remove(at: customIdx)
            WebsiteDataManager.shared.saveCustomMobileUAs()
            if WebsiteDataManager.shared.selectedMobileUAId == item.id {
                WebsiteDataManager.shared.selectedMobileUAId = WebsiteDataManager.shared.presetMobileUAs.first?.id ?? ""
            }
        } else {
            let item = WebsiteDataManager.shared.customDesktopUAs.remove(at: customIdx)
            WebsiteDataManager.shared.saveCustomDesktopUAs()
            if WebsiteDataManager.shared.selectedDesktopUAId == item.id {
                WebsiteDataManager.shared.selectedDesktopUAId = WebsiteDataManager.shared.presetDesktopUAs.first?.id ?? ""
            }
        }
        tableView.reloadData()
        NotificationCenter.default.post(name: .userAgentDidChange, object: nil)
    }

    private func showAddUADialog(isMobile: Bool) {
        let alert = UIAlertController(
            title: isMobile ? "添加自定义手机版标识" : "添加自定义电脑版标识",
            message: "请输入名称和 User-Agent 字符串",
            preferredStyle: .alert
        )
        alert.addTextField { $0.placeholder = "标识名称 (例如：手机客户端)" }
        alert.addTextField {
            $0.placeholder = "User-Agent 字符串"
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "添加", style: .default, handler: { [weak self] _ in
            guard let self = self else { return }
            let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let value = alert.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, !value.isEmpty else { return }

            let item = CustomUserAgent(id: UUID().uuidString, name: name, value: value)
            if isMobile {
                WebsiteDataManager.shared.customMobileUAs.append(item)
                WebsiteDataManager.shared.saveCustomMobileUAs()
                WebsiteDataManager.shared.selectedMobileUAId = item.id
                WebsiteDataManager.shared.isDesktopMode = false
            } else {
                WebsiteDataManager.shared.customDesktopUAs.append(item)
                WebsiteDataManager.shared.saveCustomDesktopUAs()
                WebsiteDataManager.shared.selectedDesktopUAId = item.id
                WebsiteDataManager.shared.isDesktopMode = true
            }
            self.tableView.reloadData()
            NotificationCenter.default.post(name: .userAgentDidChange, object: nil)
        }))
        present(alert, animated: true)
    }
}
