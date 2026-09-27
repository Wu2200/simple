import UIKit
import WebKit

public struct CleanOptionItem {
    public let type: WebsiteDataType
    public let title: String
    public let detail: String
    public var isSelected: Bool

    public init(type: WebsiteDataType, title: String, detail: String, isSelected: Bool = true) {
        self.type = type
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
    }
}

public final class CleanDataViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    public var onDataCleared: (() -> Void)?

    private var options: [CleanOptionItem] = [
        CleanOptionItem(type: .history, title: "浏览历史记录", detail: "已访问网页的历史记录", isSelected: true),
        CleanOptionItem(type: .cache, title: "缓存文件与临时文件", detail: "网页临时资源与离线页面缓存", isSelected: true),
        CleanOptionItem(type: .cookies, title: "Cookies 与登录状态", detail: "网站登录信息与偏好设置", isSelected: false),
        CleanOptionItem(type: .localStorage, title: "本地存储与网站数据库", detail: "IndexedDB 与 WebSQL 本地存储", isSelected: true)
    ]

    private let tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()

    private let bottomActionContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        return view
    }()

    private let clearButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle("立即清除所选数据", for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        btn.backgroundColor = .systemRed
        btn.setTitleColor(.white, for: .normal)
        btn.layer.cornerRadius = 12
        btn.layer.masksToBounds = true
        return btn
    }()

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "清除浏览数据"
        view.backgroundColor = .systemGroupedBackground

        setupNavigationBar()
        setupLayout()

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "OptionCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ManageDataCell")

        clearButton.addTarget(self, action: #selector(handleClearButtonTapped), for: .touchUpInside)
    }

    private func setupNavigationBar() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(handleDone)
        )
    }

    private func setupLayout() {
        view.addSubview(tableView)
        view.addSubview(bottomActionContainer)
        bottomActionContainer.addSubview(clearButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomActionContainer.topAnchor),

            bottomActionContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomActionContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomActionContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bottomActionContainer.heightAnchor.constraint(equalToConstant: 72),

            clearButton.topAnchor.constraint(equalTo: bottomActionContainer.topAnchor, constant: 10),
            clearButton.leadingAnchor.constraint(equalTo: bottomActionContainer.leadingAnchor, constant: 16),
            clearButton.trailingAnchor.constraint(equalTo: bottomActionContainer.trailingAnchor, constant: -16),
            clearButton.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    public func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? options.count : 1
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? "选择要清除的类型" : "网站细化管理"
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let item = options[indexPath.row]
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "OptionCell")
            cell.textLabel?.text = item.title
            cell.textLabel?.font = UIFont.systemFont(ofSize: 16)
            cell.detailTextLabel?.text = item.detail
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.accessoryType = item.isSelected ? .checkmark : .none
            cell.selectionStyle = .none
            return cell
        } else {
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "ManageDataCell")
            cell.textLabel?.text = "管理网站数据"
            cell.textLabel?.font = UIFont.systemFont(ofSize: 16)
            cell.detailTextLabel?.text = "查看各域名缓存与Cookies"
            cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 14)
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.section == 0 {
            options[indexPath.row].isSelected.toggle()
            tableView.reloadRows(at: [indexPath], with: .none)
            updateClearButtonState()
        } else {
            let managerVC = WebsiteDataManagerViewController()
            navigationController?.pushViewController(managerVC, animated: true)
        }
    }

    private func updateClearButtonState() {
        let hasSelected = options.contains(where: { $0.isSelected })
        clearButton.isEnabled = hasSelected
        clearButton.backgroundColor = hasSelected ? .systemRed : .systemGray4
    }

    @objc private func handleClearButtonTapped() {
        let selectedItems = options.filter { $0.isSelected }
        guard !selectedItems.isEmpty else { return }

        let alert = UIAlertController(
            title: "确认清除",
            message: "确定要清除选中的数据吗？此操作无法撤销。",
            preferredStyle: .actionSheet
        )

        let confirmAction = UIAlertAction(title: "立即清除", style: .destructive) { [weak self] _ in
            self?.performDataClearing(selectedItems: selectedItems)
        }
        let cancelAction = UIAlertAction(title: "取消", style: .cancel)

        alert.addAction(confirmAction)
        alert.addAction(cancelAction)

        if let popover = alert.popoverPresentationController {
            popover.sourceView = clearButton
            popover.sourceRect = clearButton.bounds
        }

        present(alert, animated: true)
    }

    private func performDataClearing(selectedItems: [CleanOptionItem]) {
        clearButton.isEnabled = false
        clearButton.setTitle("正在清除...", for: .normal)

        var recordTypes = Set<String>()
        for item in selectedItems {
            switch item.type {
            case .history:
                HistoryStore.shared.clearAll()
            case .cache:
                recordTypes.insert(WKWebsiteDataTypeDiskCache)
                recordTypes.insert(WKWebsiteDataTypeMemoryCache)
                recordTypes.insert(WKWebsiteDataTypeOfflineWebApplicationCache)
            case .cookies:
                recordTypes.insert(WKWebsiteDataTypeCookies)
            case .localStorage:
                recordTypes.insert(WKWebsiteDataTypeLocalStorage)
                recordTypes.insert(WKWebsiteDataTypeIndexedDBDatabases)
                recordTypes.insert(WKWebsiteDataTypeWebSQLDatabases)
            }
        }

        let finishHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                NotificationCenter.default.post(name: NSNotification.Name("WebsiteDataClearedNotification"), object: nil)
                self.onDataCleared?()

                self.clearButton.isEnabled = true
                self.clearButton.setTitle("立即清除所选数据", for: .normal)

                let tipAlert = UIAlertController(title: "清除完成", message: "选中的浏览数据已成功清除。", preferredStyle: .alert)
                tipAlert.addAction(UIAlertAction(title: "好的", style: .default))
                self.present(tipAlert, animated: true)
            }
        }

        if recordTypes.isEmpty {
            finishHandler()
        } else {
            let dataStore = WKWebsiteDataStore.default()
            dataStore.fetchDataRecords(ofTypes: recordTypes) { records in
                dataStore.removeData(ofTypes: recordTypes, for: records) {
                    finishHandler()
                }
            }
        }
    }
}
