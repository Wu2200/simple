import UIKit
import WebKit

public final class CleanDataViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let cleanButton = UIButton(type: .system)

    private struct Option {
        let title: String
        let subtitle: String
        var isSelected: Bool
    }

    private var options: [Option] = [
        Option(title: "历史记录", subtitle: "清除已访问网页的历史记录", isSelected: true),
        Option(title: "缓存文件", subtitle: "清除临时网页缓存、图像及文件", isSelected: true),
        Option(title: "Cookies 及网站数据", subtitle: "包括网站登录状态与 Cookie", isSelected: true),
        Option(title: "本地存储 (LocalStorage)", subtitle: "清除离线存储和网站偏好", isSelected: true)
    ]

    private var isCleaning = false

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "清除浏览数据"
        view.backgroundColor = .systemGroupedBackground

        setupNavigationBar()
        setupUI()
    }

    private func setupNavigationBar() {
        let cancelItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(handleCancel))
        navigationItem.leftBarButtonItem = cancelItem
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }

    private func setupUI() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "CleanOptionCell")
        view.addSubview(tableView)

        cleanButton.translatesAutoresizingMaskIntoConstraints = false
        cleanButton.setTitle("立即清理", for: .normal)
        cleanButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        cleanButton.backgroundColor = .systemRed
        cleanButton.tintColor = .white
        cleanButton.layer.cornerRadius = 12
        cleanButton.addTarget(self, action: #selector(handleClean), for: .touchUpInside)
        view.addSubview(cleanButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: cleanButton.topAnchor, constant: -16),

            cleanButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            cleanButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            cleanButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            cleanButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }

    @objc private func handleClean() {
        guard !isCleaning else { return }
        isCleaning = true
        cleanButton.isEnabled = false
        cleanButton.setTitle("正在清理...", for: .normal)

        var types: Set<String> = []
        if options[0].isSelected {
            HistoryManager.shared.clearAllHistory()
        }
        if options[1].isSelected {
            types.insert(WKWebsiteDataTypeDiskCache)
            types.insert(WKWebsiteDataTypeMemoryCache)
        }
        if options[2].isSelected {
            types.insert(WKWebsiteDataTypeCookies)
        }
        if options[3].isSelected {
            types.insert(WKWebsiteDataTypeLocalStorage)
            types.insert(WKWebsiteDataTypeSessionStorage)
            types.insert(WKWebsiteDataTypeIndexedDBDatabases)
            types.insert(WKWebsiteDataTypeWebSQLDatabases)
        }

        WebsiteDataManager.shared.cleanData(types: types) { [weak self] in
            DispatchQueue.main.async {
                self?.isCleaning = false
                self?.cleanButton.isEnabled = true
                self?.cleanButton.setTitle("立即清理", for: .normal)
                self?.dismiss(animated: true) {
                    NotificationCenter.default.post(name: .didCleanWebsiteData, object: nil)
                }
            }
        }
    }

    @objc private func openWebsiteDataManager() {
        let managerVC = WebsiteDataManagerViewController()
        if let nav = navigationController {
            nav.pushViewController(managerVC, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: managerVC)
            present(nav, animated: true)
        }
    }

    public func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? options.count : 1
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "CleanOptionCell", for: indexPath)
        if indexPath.section == 0 {
            let opt = options[indexPath.row]
            var config = cell.defaultContentConfiguration()
            config.text = opt.title
            config.secondaryText = opt.subtitle
            config.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = config
            cell.accessoryType = opt.isSelected ? .checkmark : .none
            return cell
        } else {
            var config = cell.defaultContentConfiguration()
            config.text = "管理网站数据"
            config.textProperties.color = .label
            cell.contentConfiguration = config
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            options[indexPath.row].isSelected.toggle()
            tableView.reloadRows(at: [indexPath], with: .none)
        } else {
            openWebsiteDataManager()
        }
    }
}
