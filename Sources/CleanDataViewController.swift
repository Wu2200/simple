import UIKit
import WebKit

final class CleanDataSelectionViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var selectedTypes: Set<CleanDataType> = [.cache, .history, .loginAndData, .scriptData]

    private let items: [CleanDataType] = [
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

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: self,
            action: #selector(handleCancel)
        )

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "CleanOptionCell")
        tableView.rowHeight = 52
        view.addSubview(tableView)

        let footerView = UIView()
        let cleanButton = UIButton(type: .system)
        cleanButton.translatesAutoresizingMaskIntoConstraints = false
        cleanButton.setTitle("立即清除", for: .normal)
        cleanButton.titleLabel?.font = .systemFont(ofSize: 16.5, weight: .semibold)
        cleanButton.setTitleColor(.white, for: .normal)
        cleanButton.backgroundColor = .systemRed
        cleanButton.layer.cornerRadius = 14
        cleanButton.layer.cornerCurve = .continuous
        cleanButton.addTarget(self, action: #selector(handleClean), for: .touchUpInside)
        footerView.addSubview(cleanButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            cleanButton.topAnchor.constraint(equalTo: footerView.topAnchor, constant: 24),
            cleanButton.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: 16),
            cleanButton.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -16),
            cleanButton.heightAnchor.constraint(equalToConstant: 50)
        ])

        footerView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 90)
        tableView.tableFooterView = footerView
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }

    @objc private func handleClean() {
        guard !selectedTypes.isEmpty else {
            dismiss(animated: true)
            return
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        WebsiteCleaner.clean(options: selectedTypes) { [weak self] in
            DispatchQueue.main.async {
                self?.dismiss(animated: true)
            }
        }
    }

    // MARK: - UITableViewDataSource
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "CleanOptionCell", for: indexPath)
        let item = items[indexPath.row]
        cell.backgroundColor = .secondarySystemGroupedBackground
        cell.textLabel?.text = item.rawValue
        cell.textLabel?.font = .systemFont(ofSize: 16, weight: .regular)
        cell.accessoryType = selectedTypes.contains(item) ? .checkmark : .none
        cell.tintColor = UIColor(red: 0.08, green: 0.42, blue: 0.92, alpha: 1.0)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = items[indexPath.row]
        if selectedTypes.contains(item) {
            selectedTypes.remove(item)
        } else {
            selectedTypes.insert(item)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }
}
