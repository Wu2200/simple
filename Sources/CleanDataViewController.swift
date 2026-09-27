import UIKit
import WebKit

// MARK: - 清理数据选择控制器
final class CleanDataViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var selectedOptions: Set<CleanDataType> = Set(CleanDataType.allCases)

    private let optionsList: [CleanDataType] = [
        .cache,
        .history,
        .loginAndData,
        .scriptData
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "清除浏览数据"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(handleCancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "确定清理", style: .done, target: self, action: #selector(handleConfirmClean))
        navigationItem.rightBarButtonItem?.tintColor = .systemRed

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 56
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }

    @objc private func handleConfirmClean() {
        guard !selectedOptions.isEmpty else {
            dismiss(animated: true)
            return
        }

        WebsiteCleaner.clean(options: selectedOptions) { [weak self] in
            DispatchQueue.main.async {
                self?.dismiss(animated: true)
            }
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return optionsList.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "CleanOptionCell")
        cell.backgroundColor = .secondarySystemGroupedBackground

        let option = optionsList[indexPath.row]
        cell.textLabel?.text = option.rawValue
        cell.textLabel?.font = .systemFont(ofSize: 16, weight: .regular)

        switch option {
        case .cache:
            cell.detailTextLabel?.text = "临时文件、已缓存的图片和网页资源"
            cell.imageView?.image = UIImage(systemName: "internaldrive")
        case .history:
            cell.detailTextLabel?.text = "访问过的网页记录与地址栏搜索词"
            cell.imageView?.image = UIImage(systemName: "clock")
        case .loginAndData:
            cell.detailTextLabel?.text = "Cookie 与本地数据库（已锁定的网站数据除外）"
            cell.imageView?.image = UIImage(systemName: "person.crop.circle.badge.checkmark")
        case .scriptData:
            cell.detailTextLabel?.text = "油猴脚本存储在本地的数据缓存"
            cell.imageView?.image = UIImage(systemName: "puzzlepiece.extension")
        }

        cell.imageView?.tintColor = UIColor(red: 0.08, green: 0.42, blue: 0.92, alpha: 1.0)
        cell.detailTextLabel?.textColor = .secondaryLabel

        if selectedOptions.contains(option) {
            cell.accessoryType = .checkmark
            cell.tintColor = UIColor(red: 0.08, green: 0.42, blue: 0.92, alpha: 1.0)
        } else {
            cell.accessoryType = .none
        }

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let option = optionsList[indexPath.row]
        if selectedOptions.contains(option) {
            selectedOptions.remove(option)
        } else {
            selectedOptions.insert(option)
        }
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }
}
