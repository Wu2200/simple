import UIKit
import WebKit

// MARK: - 清理数据选择视图控制器
final class CleanDataSelectionViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var selectedTypes: Set<CleanDataType> = Set(CleanDataType.allCases)

    private let orderedTypes: [CleanDataType] = [
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "确定清理", style: .done, target: self, action: #selector(handleConfirm))

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 54
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

    @objc private func handleConfirm() {
        WebsiteCleaner.clean(options: selectedTypes) { [weak self] in
            DispatchQueue.main.async {
                self?.dismiss(animated: true)
            }
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return orderedTypes.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "CleanCell")
        cell.backgroundColor = .secondarySystemGroupedBackground

        let type = orderedTypes[indexPath.row]
        cell.textLabel?.text = type.rawValue
        cell.textLabel?.font = .systemFont(ofSize: 15.5, weight: .regular)

        let isSelected = selectedTypes.contains(type)
        cell.accessoryType = isSelected ? .checkmark : .none

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let type = orderedTypes[indexPath.row]

        if selectedTypes.contains(type) {
            selectedTypes.remove(type)
        } else {
            selectedTypes.insert(type)
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }
}

// 兼容外部历史别名引用
typealias CleanDataViewController = CleanDataSelectionViewController
