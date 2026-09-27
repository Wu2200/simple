import UIKit

typealias CleanDataViewController = CleanDataSelectionViewController

final class CleanDataSelectionViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

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
        setupUI()
    }

    private func setupUI() {
        title = "清除浏览数据"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(handleCancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "管理网站数据", style: .plain, target: self, action: #selector(handleManageData))

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        let cleanButton = UIButton(type: .system)
        cleanButton.translatesAutoresizingMaskIntoConstraints = false
        cleanButton.setTitle("立即清除", for: .normal)
        cleanButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        cleanButton.setTitleColor(.white, for: .normal)
        cleanButton.backgroundColor = .systemRed
        cleanButton.layer.cornerRadius = 14
        cleanButton.addTarget(self, action: #selector(handleClean), for: .touchUpInside)
        view.addSubview(cleanButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: cleanButton.topAnchor, constant: -16),

            cleanButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cleanButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            cleanButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            cleanButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }

    @objc private func handleCancel() { dismiss(animated: true) }

    @objc private func handleManageData() {
        let vc = WebsiteDataManagerViewController()
        navigationController?.pushViewController(vc, animated: true)
    }

    @objc private func handleClean() {
        guard !selectedOptions.isEmpty else { return }
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
        let cell = UITableViewCell(style: .default, reuseIdentifier: "CleanOptionCell")
        let item = optionsList[indexPath.row]
        cell.textLabel?.text = item.rawValue
        cell.accessoryType = selectedOptions.contains(item) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = optionsList[indexPath.row]
        if selectedOptions.contains(item) {
            selectedOptions.remove(item)
        } else {
            selectedOptions.insert(item)
        }
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }
}
