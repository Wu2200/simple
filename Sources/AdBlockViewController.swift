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

final class AdBlockMemoryDetailViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var report: AdBlockMemoryReport?
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "内存与存储诊断"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "深度清理",
            style: .plain,
            target: self,
            action: #selector(handleDeepClean)
        )

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "MemoryDetailCell")

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        fetchData()
    }

    private func fetchData() {
        AdBlockManager.shared.scanMemoryUsage { [weak self] rep in
            self?.report = rep
            self?.tableView.reloadData()
        }
    }

    @objc private func handleDeepClean() {
        navigationItem.rightBarButtonItem?.isEnabled = false
        title = "正在清理…"

        AdBlockManager.shared.cleanMemoryResidue { [weak self] rep in
            guard let self = self else { return }
            self.title = "内存与存储诊断"
            self.navigationItem.rightBarButtonItem?.isEnabled = true
            self.report = rep
            self.tableView.reloadData()

            let alert = UIAlertController(
                title: "清理完成",
                message: "已彻底清空旧碎片规则库、重置紧凑规则、删除沙盒构建归档残留与网页缓存。\n当前物理内存: \(rep.physicalFootprintString)\n底层规则库已压缩至: \(rep.diskStoreIdentifiers.count) 个",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "确定", style: .default))
            self.present(alert, animated: true)
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        let hasArtifacts = !(report?.largeArtifacts.isEmpty ?? true)
        return hasArtifacts ? 5 : 4
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:
            return 2
        case 1:
            return 3
        case 2:
            return 2
        case 3:
            return 5
        case 4:
            return report?.largeArtifacts.count ?? 0
        default:
            return 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0:
            return "系统运行内存"
        case 1:
            return "广告拦截引擎"
        case 2:
            return "底层规则库"
        case 3:
            return "应用沙盒占用"
        case 4:
            return "检测到的沙盒大文件"
        default:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 2 {
            return "规则库已按紧凑规范合并编译。点击右上角深度清理可清空旧残留并重新优化。"
        }
        if section == 3 {
            return "系统设置中的文稿与数据由以上目录大小总和构成。"
        }
        return nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: "MemoryDetailCell")
        cell.selectionStyle = .none

        guard let r = report else {
            cell.textLabel?.text = "正在全面扫描沙盒与内存…"
            cell.detailTextLabel?.text = nil
            return cell
        }

        switch indexPath.section {
        case 0:
            if indexPath.row == 0 {
                cell.textLabel?.text = "物理内存占用"
                cell.detailTextLabel?.text = r.physicalFootprintString
            } else {
                cell.textLabel?.text = "常驻内存"
                cell.detailTextLabel?.text = r.residentSizeString
            }
        case 1:
            if indexPath.row == 0 {
                cell.textLabel?.text = "内存规则列表对象"
                cell.detailTextLabel?.text = "\(r.inMemoryRuleListCount) 组"
            } else if indexPath.row == 1 {
                cell.textLabel?.text = "已加载规则总数"
                cell.detailTextLabel?.text = "\(r.metadataRuleCount) 条"
            } else {
                cell.textLabel?.text = "启用规则订阅"
                cell.detailTextLabel?.text = "\(r.activeSubscriptionCount) 个"
            }
        case 2:
            if indexPath.row == 0 {
                cell.textLabel?.text = "已注册底层规则库"
                cell.detailTextLabel?.text = "\(r.diskStoreIdentifiers.count) 个"
                cell.detailTextLabel?.textColor = r.diskStoreIdentifiers.count > 10 ? .systemRed : .secondaryLabel
            } else {
                cell.textLabel?.text = "孤儿规则库"
                cell.detailTextLabel?.text = "\(r.orphanStoreIdentifiers.count) 个"
                cell.detailTextLabel?.textColor = r.orphanStoreIdentifiers.isEmpty ? .secondaryLabel : .systemRed
            }
        case 3:
            if indexPath.row == 0 {
                cell.textLabel?.text = "沙盒总大小"
                cell.detailTextLabel?.text = r.totalSandboxSizeString
            } else if indexPath.row == 1 {
                cell.textLabel?.text = "文稿目录"
                cell.detailTextLabel?.text = r.documentsSizeString
            } else if indexPath.row == 2 {
                cell.textLabel?.text = "网页离线与规则数据"
                cell.detailTextLabel?.text = r.webKitSizeString
            } else if indexPath.row == 3 {
                cell.textLabel?.text = "缓存目录"
                cell.detailTextLabel?.text = r.cachesSizeString
            } else {
                cell.textLabel?.text = "临时目录"
                cell.detailTextLabel?.text = r.tmpSizeString
            }
        case 4:
            let item = r.largeArtifacts[indexPath.row]
            cell.textLabel?.text = item.name
            cell.textLabel?.font = .systemFont(ofSize: 14)
            cell.detailTextLabel?.text = item.sizeString
            cell.detailTextLabel?.textColor = .systemOrange
        default:
            break
        }

        return cell
    }
}

final class AdBlockManagerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private var subscriptions: [AdBlockSubscription] = []
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var statusRefreshTimer: Timer?
    private var currentMemoryFootprintString = "检测中…"

    var onRulesChanged: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "广告拦截"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleDone))

        setupInterface()
        loadData()
        refreshMemoryStatus()

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

    private func refreshMemoryStatus() {
        AdBlockManager.shared.scanMemoryUsage { [weak self] rep in
            self?.currentMemoryFootprintString = rep.physicalFootprintString
            self?.tableView.reloadSections(IndexSet(integer: 3), with: .none)
        }
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
        return 4
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 1 }
        if section == 1 { return subscriptions.count + 1 }
        if section == 2 { return 1 }
        return 2
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return "总开关" }
        if section == 1 { return "规则订阅" }
        if section == 2 { return "自定义规则" }
        if section == 3 { return "内存诊断与清理" }
        return nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: "AdBlockCell")

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
            let subCell = UITableViewCell(style: .subtitle, reuseIdentifier: "AdBlockCell")
            if indexPath.row < subscriptions.count {
                let subscription = subscriptions[indexPath.row]
                subCell.textLabel?.text = subscription.name

                let toggle = UISwitch()
                toggle.isOn = subscription.isEnabled
                toggle.tag = indexPath.row
                toggle.addTarget(self, action: #selector(handleSubscriptionToggle(_:)), for: .valueChanged)
                subCell.accessoryView = toggle

                if AdBlockManager.shared.isUpdating(sourceId: subscription.id) {
                    subCell.detailTextLabel?.text = AdBlockManager.shared.updateStatus(
                        sourceId: subscription.id
                    ) ?? "更新中…"
                } else if let date = subscription.lastUpdated {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "MM-dd HH:mm"
                    subCell.detailTextLabel?.text = "\(subscription.ruleCount) 条 | \(formatter.string(from: date))"
                } else {
                    subCell.detailTextLabel?.text = "尚未更新"
                }
            } else {
                subCell.textLabel?.text = "添加新订阅链接"
                subCell.textLabel?.textColor = .systemBlue
                subCell.detailTextLabel?.text = nil
                subCell.accessoryView = nil
            }

            return subCell
        }

        if indexPath.section == 2 {
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

        if indexPath.row == 0 {
            cell.textLabel?.text = "应用物理内存"
            cell.detailTextLabel?.text = currentMemoryFootprintString
            cell.selectionStyle = .none
        } else {
            cell.textLabel?.text = "深度清理内存残留"
            cell.textLabel?.textColor = .systemBlue
            cell.accessoryType = .disclosureIndicator
        }

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
        } else if indexPath.section == 3 {
            if indexPath.row == 1 {
                let detailVC = AdBlockMemoryDetailViewController()
                navigationController?.pushViewController(detailVC, animated: true)
            }
        }
    }

    private func openCustomRuleEditor() {
        let customVC = CustomRuleEditorViewController()
        customVC.onSaved = { [weak self] in
            self?.loadData()
            self?.onRulesChanged?()
            self?.refreshMemoryStatus()
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
            self.refreshMemoryStatus()
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
            self?.refreshMemoryStatus()
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
                self.refreshMemoryStatus()

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
            self.refreshMemoryStatus()
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
                self.refreshMemoryStatus()

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
