import UIKit
import WebKit

// MARK: - 广告拦截规则引擎
final class AdBlocker {
    static let shared = AdBlocker()

    private let rulesKey = "AdBlockCustomRulesList_V1"
    private var rules: [String] = []

    init() {
        loadRules()
    }

    func loadRules() {
        rules = UserDefaults.standard.stringArray(forKey: rulesKey) ?? [
            "*googleads*",
            "*doubleclick.net*",
            "*pagead*",
            "*adservice*",
            "*adsystem*"
        ]
    }

    func saveRules(_ newRules: [String]) {
        rules = newRules
        UserDefaults.standard.set(rules, forKey: rulesKey)
    }

    func getRules() -> [String] {
        return rules
    }

    func addRule(_ rule: String) {
        let clean = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !rules.contains(clean) else { return }
        rules.append(clean)
        saveRules(rules)
    }

    func deleteRule(at index: Int) {
        guard index >= 0, index < rules.count else { return }
        rules.remove(at: index)
        saveRules(rules)
    }
}

// MARK: - 广告规则管理控制器
final class AdBlockerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var rules: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "广告过滤规则"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(handleAddRule))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleDone))

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "RuleCell")
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        loadRules()
    }

    private func loadRules() {
        rules = AdBlocker.shared.getRules()
        tableView.reloadData()
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    @objc private func handleAddRule() {
        let alert = UIAlertController(title: "添加拦截规则", message: "支持域名或通配符（如 *adservice*）", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "规则表达式"
        }
        alert.addAction(UIAlertAction(title: "添加", style: .default, handler: { [weak self] _ in
            guard let text = alert.textFields?.first?.text, !text.isEmpty else { return }
            AdBlocker.shared.addRule(text)
            self?.loadRules()
        }))
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rules.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "RuleCell", for: indexPath)
        cell.textLabel?.text = rules[indexPath.row]
        cell.textLabel?.font = .systemFont(ofSize: 15, weight: .regular)
        cell.imageView?.image = UIImage(systemName: "shield.slash")
        cell.imageView?.tintColor = UIColor(red: 0.28, green: 0.28, blue: 0.32, alpha: 1.0)
        return cell
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] (_, _, completion) in
            AdBlocker.shared.deleteRule(at: indexPath.row)
            self?.rules.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .fade)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}
