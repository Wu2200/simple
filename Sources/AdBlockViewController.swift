import UIKit

final class UnsupportedRulesViewController: UIViewController {
    private let textView = UITextView()
    private let text: String

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "不兼容规则诊断"
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "复制全部",
            style: .plain,
            target: self,
            action: #selector(handleCopyAll)
        )

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.layoutManager.allowsNonContiguousLayout = true

        let maxDisplayLength = 30000
        if text.count > maxDisplayLength {
            let endIndex = text.index(text.startIndex, offsetBy: maxDisplayLength)
            let preview = String(text[..<endIndex])
            textView.text = "提示：内容较多，当前仅预览部分规则。可点击右上角复制全部获取完整内容。\n\n" + preview + "\n\n更多内容请点击右上角复制全部"
        } else {
            textView.text = text
        }

        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func handleCopyAll() {
        UIPasteboard.general.string = text
        let alert = UIAlertController(title: "已复制", message: "不兼容规则已全部复制到剪贴板", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}

final class AdBlockManagerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private var subscriptions: [AdBlockSubscription] = []
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var statusRefreshTimer: Timer?

    var onRulesChanged: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "广告拦截"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleDone))

        setupInterface()
        loadData()

        statusRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: 0.8,
            repeats: true
        ) { [weak self] _ in
            self?.refreshVisibleStatus()
        }
    }

    deinit {
        statusRefreshTimer?.invalidate()
    }

    private func setupInterface() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "AdBlockCell")

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func loadData() {
        subscriptions = AdBlockManager.shared.loadSubscriptions()
        tableView.reloadData()
    }

    private func refreshVisibleStatus() {
        subscriptions = AdBlockManager.shared.loadSubscriptions()

        guard let indexPaths = tableView.indexPathsForVisibleRows else { return }

        for indexPath in indexPaths {
            guard let cell = tableView.cellForRow(at: indexPath) else { continue }

            if indexPath.section == 1 {
                if indexPath.row < subscriptions.count {
                    let subscription = subscriptions[indexPath.row]
                    if AdBlockManager.shared.isUpdating(sourceId: subscription.id) {
                        cell.detailTextLabel?.text = AdBlockManager.shared.updateStatus(sourceId: subscription.id) ?? "更新中…"
                        cell.accessoryType = .none
                    } else {
                        if let date = subscription.lastUpdated {
                            let formatter = DateFormatter()
                            formatter.dateFormat = "MM-dd HH:mm"
                            cell.detailTextLabel?.text = "\(subscription.ruleCount) 条 | \(formatter.string(from: date))"
                        } else {
                            cell.detailTextLabel?.text = "尚未更新"
                        }
                    }
                }
            } else if indexPath.section == 2 {
                let sourceId = AdBlockManager.customSourceId
                if AdBlockManager.shared.isUpdating(sourceId: sourceId) {
                    cell.detailTextLabel?.text = AdBlockManager.shared.updateStatus(sourceId: sourceId) ?? "自定义规则更新中…"
                } else {
                    let count = AdBlockManager.shared.ruleCount(sourceId: sourceId)
                    cell.detailTextLabel?.text = "自定义规则：\(count) 条"
                }
            }
            cell.setNeedsLayout()
        }
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return 3
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 1 }
        if section == 1 { return subscriptions.count + 1 }
        return 1
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return "总开关" }
        if section == 1 { return "规则订阅" }
        if section == 2 { return "自定义规则" }
        return nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "AdBlockCell")

        if indexPath.section == 0 {
            cell.textLabel?.text = "启用广告拦截"

            let toggle = UISwitch()
            toggle.isOn = AdBlockManager.shared.isEnabled
            toggle.addTarget(self, action: #selector(handleMasterToggle(_:)), for: .valueChanged)

            cell.accessoryView = toggle
            cell.selectionStyle = .none
            return cell
        }

        if indexPath.section == 1 {
            if indexPath.row < subscriptions.count {
                let subscription = subscriptions[indexPath.row]
                cell.textLabel?.text = subscription.name

                let toggle = UISwitch()
                toggle.isOn = subscription.isEnabled
                toggle.tag = indexPath.row
                toggle.addTarget(self, action: #selector(handleSubscriptionToggle(_:)), for: .valueChanged)
                cell.accessoryView = toggle

                if AdBlockManager.shared.isUpdating(sourceId: subscription.id) {
                    cell.detailTextLabel?.text = AdBlockManager.shared.updateStatus(
                        sourceId: subscription.id
                    ) ?? "更新中…"
                } else if let date = subscription.lastUpdated {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "MM-dd HH:mm"
                    cell.detailTextLabel?.text = "\(subscription.ruleCount) 条 | \(formatter.string(from: date))"
                } else {
                    cell.detailTextLabel?.text = "尚未更新"
                }
            } else {
                cell.textLabel?.text = "添加新订阅链接…"
                cell.textLabel?.textColor = .systemBlue
                cell.detailTextLabel?.text = nil
                cell.accessoryView = nil
            }

            return cell
        }

        let sourceId = AdBlockManager.customSourceId
        let count = AdBlockManager.shared.ruleCount(sourceId: sourceId)

        cell.textLabel?.text = "编辑自定义过滤规则"

        if AdBlockManager.shared.isUpdating(sourceId: sourceId) {
            cell.detailTextLabel?.text = AdBlockManager.shared.updateStatus(
                sourceId: sourceId
            ) ?? "自定义规则更新中…"
        } else {
            cell.detailTextLabel?.text = "自定义规则：\(count) 条"
        }

        cell.accessoryType = .disclosureIndicator
        return cell
    }

    @objc private func handleMasterToggle(_ sender: UISwitch) {
        AdBlockManager.shared.isEnabled = sender.isOn
        onRulesChanged?()
    }

    @objc private func handleSubscriptionToggle(_ sender: UISwitch) {
        let index = sender.tag
        guard index < subscriptions.count else { return }
        let subscription = subscriptions[index]
        AdBlockManager.shared.toggleSubscription(id: subscription.id, isEnabled: sender.isOn)
        onRulesChanged?()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.section == 1 {
            if indexPath.row < subscriptions.count {
                let subscription = subscriptions[indexPath.row]
                showSubscriptionDetail(subscription)
            } else {
                showAddSubscriptionAlert()
            }
        } else if indexPath.section == 2 {
            let sourceId = AdBlockManager.customSourceId
            let unsupportedCount = AdBlockManager.shared.unsupportedRuleCount(sourceId: sourceId)

            if unsupportedCount > 0 {
                let alert = UIAlertController(title: "自定义规则", message: nil, preferredStyle: .actionSheet)
                alert.addAction(UIAlertAction(title: "编辑规则", style: .default) { [weak self] _ in
                    self?.openCustomRuleEditor()
                })
                alert.addAction(UIAlertAction(title: "查看不兼容规则", style: .default) { [weak self] _ in
                    let text = AdBlockManager.shared.unsupportedRulesText(sourceId: sourceId)
                    let vc = UnsupportedRulesViewController(text: text)
                    self?.navigationController?.pushViewController(vc, animated: true)
                })
                alert.addAction(UIAlertAction(title: "取消", style: .cancel))
                present(alert, animated: true)
            } else {
                openCustomRuleEditor()
            }
        }
    }

    private func openCustomRuleEditor() {
        let customVC = CustomRuleEditorViewController()
        customVC.onSaved = { [weak self] in
            self?.loadData()
            self?.onRulesChanged?()
        }
        navigationController?.pushViewController(customVC, animated: true)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1,
              indexPath.row < subscriptions.count else {
            return nil
        }

        let subscription = subscriptions[indexPath.row]

        guard !AdBlockManager.shared.isUpdating(sourceId: subscription.id) else {
            return nil
        }

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            guard let self = self else {
                completion(false)
                return
            }

            self.subscriptions.removeAll { $0.id == subscription.id }
            tableView.deleteRows(at: [indexPath], with: .automatic)

            AdBlockManager.shared.deleteSubscription(id: subscription.id)
            completion(true)
        }

        let editAction = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, completion in
            self?.showEditSubscriptionAlert(subscription)
            completion(true)
        }

        editAction.backgroundColor = .systemBlue

        return UISwipeActionsConfiguration(actions: [deleteAction, editAction])
    }

    private func showEditSubscriptionAlert(_ subscription: AdBlockSubscription) {
        let alert = UIAlertController(title: "编辑规则订阅", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "订阅名称"
            tf.text = subscription.name
        }
        alert.addTextField { tf in
            tf.placeholder = "订阅 URL"
            tf.text = subscription.urlString
        }

        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
            guard let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let urlStr = alert.textFields?[1].text?.trimmingCharacters(in: .whitespaces), !urlStr.isEmpty else { return }

            AdBlockManager.shared.updateSubscription(id: subscription.id, name: name, urlString: urlStr)
            self?.loadData()
            self?.onRulesChanged?()
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showSubscriptionDetail(_ subscription: AdBlockSubscription) {
        let alert = UIAlertController(title: subscription.name, message: subscription.urlString, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "立即更新规则", style: .default) { [weak self] _ in
            guard let self = self else {
                return
            }

            self.loadData()

            AdBlockManager.shared.fetchSubscription(subscription) { [weak self] success, count, errorMessage in
                guard let self = self else {
                    return
                }

                self.loadData()

                let message: String

                if success {
                    if let errorMessage = errorMessage, !errorMessage.isEmpty {
                        message = "更新完成，共加载 \(count) 条规则。\n\(errorMessage)\n刷新页面后生效。"
                    } else {
                        message = "更新完成，共加载 \(count) 条规则。刷新页面后生效。"
                    }
                } else {
                    message = errorMessage ?? "规则更新失败，未返回具体原因"
                }

                let result = UIAlertController(
                    title: success ? "规则更新完成" : "规则更新失败",
                    message: message,
                    preferredStyle: .alert
                )

                result.addAction(UIAlertAction(title: "确定", style: .default))
                self.present(result, animated: true)
                self.onRulesChanged?()
            }
        })

        let unsupportedCount = AdBlockManager.shared.unsupportedRuleCount(sourceId: subscription.id)
        if unsupportedCount > 0 {
            alert.addAction(UIAlertAction(title: "查看不兼容规则", style: .default) { [weak self] _ in
                let text = AdBlockManager.shared.unsupportedRulesText(sourceId: subscription.id)
                let vc = UnsupportedRulesViewController(text: text)
                self?.navigationController?.pushViewController(vc, animated: true)
            })
        }

        alert.addAction(UIAlertAction(title: "删除订阅", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.subscriptions.removeAll { $0.id == subscription.id }
            AdBlockManager.shared.deleteSubscription(id: subscription.id)
            self.loadData()
            self.onRulesChanged?()
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showAddSubscriptionAlert() {
        let alert = UIAlertController(title: "添加规则订阅", message: "请输入规则订阅地址", preferredStyle: .alert)
        alert.addTextField { tf in tf.placeholder = "订阅名称" }
        alert.addTextField { tf in tf.placeholder = "订阅地址" }

        alert.addAction(UIAlertAction(title: "添加并更新", style: .default) { [weak self] _ in
            guard let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let urlStr = alert.textFields?[1].text?.trimmingCharacters(in: .whitespaces), !urlStr.isEmpty else { return }

            let subscription = AdBlockManager.shared.addSubscription(name: name, urlString: urlStr)
            self?.loadData()

            AdBlockManager.shared.fetchSubscription(subscription) { [weak self] success, count, errorMessage in
                guard let self = self else {
                    return
                }

                self.loadData()

                let message: String

                if success {
                    if let errorMessage = errorMessage, !errorMessage.isEmpty {
                        message = "更新完成，共加载 \(count) 条规则。\n\(errorMessage)\n刷新页面后生效。"
                    } else {
                        message = "更新完成，共加载 \(count) 条规则。刷新页面后生效。"
                    }
                } else {
                    message = errorMessage ?? "规则更新失败，未返回具体原因"
                }

                let result = UIAlertController(
                    title: success ? "规则更新完成" : "规则更新失败",
                    message: message,
                    preferredStyle: .alert
                )

                result.addAction(UIAlertAction(title: "确定", style: .default))
                self.present(result, animated: true)
                self.onRulesChanged?()
            }
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}

final class CustomRuleEditorViewController: UIViewController {
    private let textView = UITextView()
    var onSaved: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "自定义过滤规则"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", style: .done, target: self, action: #selector(handleSave))

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 12
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.text = AdBlockManager.shared.getCustomRules()

        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    @objc private func handleSave() {
        let rules = textView.text ?? ""

        navigationItem.rightBarButtonItem?.isEnabled = false

        AdBlockManager.shared.saveCustomRules(rules) { [weak self] success, message in
            guard let self = self else {
                return
            }

            self.navigationItem.rightBarButtonItem?.isEnabled = true

            if success {
                self.onSaved?()
                self.navigationController?.popViewController(animated: true)
                return
            }

            let alert = UIAlertController(
                title: "保存失败",
                message: message ?? "自定义规则无法完成编译",
                preferredStyle: .alert
            )

            alert.addAction(UIAlertAction(title: "确定", style: .default))
            self.present(alert, animated: true)
        }
    }
}
