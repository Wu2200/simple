import UIKit

// MARK: - 清除数据选择控制器
final class CleanDataViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var selectedOptions: Set<CleanDataType> = Set(CleanDataType.allCases)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "清除浏览数据"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(handleCancel))

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "CleanOptionCell")
        view.addSubview(tableView)

        let footer = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 90))
        let cleanBtn = UIButton(type: .system)
        cleanBtn.setTitle("确定清理", for: .normal)
        cleanBtn.setTitleColor(.white, for: .normal)
        cleanBtn.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        cleanBtn.backgroundColor = .systemRed
        cleanBtn.layer.cornerRadius = 14
        cleanBtn.layer.cornerCurve = .continuous
        cleanBtn.translatesAutoresizingMaskIntoConstraints = false
        cleanBtn.addTarget(self, action: #selector(handleExecuteClean), for: .touchUpInside)
        footer.addSubview(cleanBtn)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            cleanBtn.topAnchor.constraint(equalTo: footer.topAnchor, constant: 20),
            cleanBtn.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            cleanBtn.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -20),
            cleanBtn.heightAnchor.constraint(equalToConstant: 48)
        ])

        tableView.tableFooterView = footer
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }

    @objc private func handleExecuteClean() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        WebsiteCleaner.clean(options: selectedOptions) { [weak self] in
            DispatchQueue.main.async {
                self?.dismiss(animated: true)
            }
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return CleanDataType.allCases.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "CleanOptionCell", for: indexPath)
        let item = CleanDataType.allCases[indexPath.row]
        cell.textLabel?.text = item.rawValue
        cell.textLabel?.font = .systemFont(ofSize: 15.5, weight: .regular)
        cell.backgroundColor = .secondarySystemGroupedBackground

        if selectedOptions.contains(item) {
            cell.accessoryType = .checkmark
            cell.tintColor = UIColor(red: 0.08, green: 0.42, blue: 0.92, alpha: 1.0)
        } else {
            cell.accessoryType = .none
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = CleanDataType.allCases[indexPath.row]
        if selectedOptions.contains(item) {
            selectedOptions.remove(item)
        } else {
            selectedOptions.insert(item)
        }
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }
}
