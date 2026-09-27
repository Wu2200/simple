import UIKit
import WebKit

// MARK: - 广告拦截规则模型
struct AdBlockRuleItem: Codable {
    let id: String
    var domain: String
    var isEnabled: Bool

    init(id: String = UUID().uuidString, domain: String, isEnabled: Bool = true) {
        self.id = id
        self.domain = domain
        self.isEnabled = isEnabled
    }
}

// MARK: - 广告拦截管理器控制器
final class AdBlockManagerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var rules: [AdBlockRuleItem] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "广告过滤规则"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(handleAddRule))

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 52
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        loadDefaultRules()
    }

    private func loadDefaultRules() {
        rules = [
            AdBlockRuleItem(domain: "googleads.g.doubleclick.net"),
            AdBlockRuleItem(domain: "pagead2.googlesyndication.com"),
            AdBlockRuleItem(domain: "adservice.google.com")
        ]
        tableView.reloadData()
    }

    @objc private func handleAddRule() {
        let alert = UIAlertController(title: "添加过滤域名", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "例如：ad.example.com"
            tf.autocorrectionType = .no
            tf.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "添加", style: .default, handler: { [weak self] _ in
            guard let text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            self?.rules.append(AdBlockRuleItem(domain: text))
            self?.tableView.reloadData()
        }))
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rules.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "AdRuleCell")
        cell.backgroundColor = .secondarySystemGroupedBackground

        let rule = rules[indexPath.row]
        cell.textLabel?.text = rule.domain
        cell.textLabel?.font = .systemFont(ofSize: 15, weight: .regular)

        let sw = UISwitch()
        sw.isOn = rule.isEnabled
        sw.tag = indexPath.row
        sw.addTarget(self, action: #selector(handleSwitch(_:)), for: .valueChanged)
        cell.accessoryView = sw

        return cell
    }

    @objc private func handleSwitch(_ sender: UISwitch) {
        let index = sender.tag
        guard index < rules.count else { return }
        rules[index].isEnabled = sender.isOn
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] (_, _, completion) in
            self?.rules.remove(at: indexPath.row)
            self?.tableView.deleteRows(at: [indexPath], with: .fade)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

// 兼容外部别名
typealias AdBlockerViewController = AdBlockManagerViewController
