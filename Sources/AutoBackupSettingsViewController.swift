import UIKit

final class AutoBackupSettingsViewController: UITableViewController, UITextFieldDelegate {
    private var draftConfig: OpenListBackupConfig
    private var draftServerSecret: String
    private var draftBackupPassword: String
    private var isTestingConnection = false
    private var statusRefreshTimer: Timer?
    private var lastRenderedStatusText: String?
    private var lastRenderedSuccessText: String?
    private var lastRenderedUploading = false

    private weak var serverURLField: UITextField?
    private weak var usernameField: UITextField?
    private weak var passwordOrTokenField: UITextField?
    private weak var remoteDirectoryField: UITextField?
    private weak var backupPasswordField: UITextField?

    init() {
        self.draftConfig = AutoBackupManager.shared.currentConfig
        self.draftServerSecret = AutoBackupManager.shared.currentServerSecret
        self.draftBackupPassword = AutoBackupManager.shared.currentBackupEncryptionPassword
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        self.draftConfig = AutoBackupManager.shared.currentConfig
        self.draftServerSecret = AutoBackupManager.shared.currentServerSecret
        self.draftBackupPassword = AutoBackupManager.shared.currentBackupEncryptionPassword
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "自动备份"
        view.backgroundColor = .systemGroupedBackground
        tableView.keyboardDismissMode = .onDrag

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "关闭",
            style: .plain,
            target: self,
            action: #selector(handleClose)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "保存",
            style: .done,
            target: self,
            action: #selector(handleSave)
        )

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tableView.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStatusDidChange),
            name: AutoBackupManager.statusDidChangeNotification,
            object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshLiveStatusDisplay(force: true)
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshLiveStatusDisplay(force: false)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = nil
    }

    deinit {
        statusRefreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func handleClose() {
        dismiss(animated: true)
    }

    @objc private func handleStatusDidChange() {
        let latest = AutoBackupManager.shared.currentConfig
        draftConfig.backupFileName = latest.backupFileName
        draftConfig.lastSuccessDate = latest.lastSuccessDate
        draftConfig.lastAttemptDate = latest.lastAttemptDate
        draftConfig.lastErrorMessage = latest.lastErrorMessage
        draftConfig.lastUploadedFileName = latest.lastUploadedFileName
        refreshLiveStatusDisplay(force: true)
    }

    private func syncDraftFieldsFromInputs() {
        if let text = serverURLField?.text {
            draftConfig.serverURL = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let text = usernameField?.text {
            draftConfig.username = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let text = passwordOrTokenField?.text {
            draftServerSecret = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let text = remoteDirectoryField?.text {
            draftConfig.remoteDirectory = OpenListClient.normalizeRemoteDirectory(text)
        }
        if let text = backupPasswordField?.text {
            draftBackupPassword = text
        }
    }

    private func validateDraftConfigurationForUpload() -> String? {
        syncDraftFieldsFromInputs()
        guard let serverURL = OpenListClient.normalizeServerURL(draftConfig.serverURL), !draftConfig.serverURL.isEmpty else {
            return "请输入有效的 OpenList 服务器地址"
        }
        let mode = OpenListClient.detectProtocolMode(for: serverURL)
        if mode == .openListAPI && draftServerSecret.isEmpty {
            return "请输入 OpenList 密码或 API Token"
        }
        return nil
    }

    @objc private func handleSave() {
        dismissKeyboard()
        syncDraftFieldsFromInputs()

        if draftConfig.isEnabled, let validationError = validateDraftConfigurationForUpload() {
            showAlert(title: "无法启用自动备份", message: validationError)
            return
        }

        AutoBackupManager.shared.updateConfiguration(
            isEnabled: draftConfig.isEnabled,
            serverURL: draftConfig.serverURL,
            username: draftConfig.username,
            passwordOrToken: draftServerSecret,
            remoteDirectory: draftConfig.remoteDirectory,
            intervalHours: draftConfig.intervalHours,
            backupPassword: draftBackupPassword,
            triggerIfDue: true
        )

        dismiss(animated: true)
    }

    @objc private func handleEnabledSwitchChanged(_ sender: UISwitch) {
        draftConfig.isEnabled = sender.isOn
        refreshLiveStatusDisplay(force: true)
    }

    @objc private func handleTextFieldChanged(_ textField: UITextField) {
        let value = textField.text ?? ""
        switch textField.tag {
        case 100:
            draftConfig.serverURL = value
        case 101:
            draftConfig.username = value
        case 102:
            draftServerSecret = value
        case 103:
            draftConfig.remoteDirectory = value
        case 104:
            draftBackupPassword = value
        default:
            break
        }
    }

    private func refreshLiveStatusDisplay(force: Bool) {
        guard isViewLoaded else { return }
        let snapshot = AutoBackupManager.shared.statusSnapshot
        let successText = snapshot.config.lastSuccessDate.map { formattedDate($0) } ?? "尚未备份"
        let (statusText, _) = statusTextAndColor()

        if !force &&
            lastRenderedStatusText == statusText &&
            lastRenderedSuccessText == successText &&
            lastRenderedUploading == snapshot.isUploading {
            return
        }

        lastRenderedStatusText = statusText
        lastRenderedSuccessText = successText
        lastRenderedUploading = snapshot.isUploading

        tableView.reloadRows(
            at: [
                IndexPath(row: 3, section: 0),
                IndexPath(row: 4, section: 0),
                IndexPath(row: 0, section: 2),
                IndexPath(row: 1, section: 2)
            ],
            with: .none
        )
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func statusTextAndColor() -> (String, UIColor) {
        let snapshot = AutoBackupManager.shared.statusSnapshot

        if snapshot.isUploading {
            return ("正在打包并上传备份…", .systemBlue)
        }

        if let retryDate = snapshot.pendingRetryDate {
            let remaining = max(1, Int(ceil(retryDate.timeIntervalSinceNow)))
            if let errorMsg = snapshot.config.lastErrorMessage, !errorMsg.isEmpty {
                return ("上传失败，\(remaining) 秒后自动重试\n\(errorMsg)", .systemOrange)
            }
            return ("上传失败，\(remaining) 秒后自动重试", .systemOrange)
        }

        if let errorMsg = snapshot.config.lastErrorMessage, !errorMsg.isEmpty {
            return ("上次上传失败：\(errorMsg)", .systemRed)
        }

        if !draftConfig.isEnabled {
            return ("未开启自动备份", .secondaryLabel)
        }

        if !snapshot.config.isEnabled {
            return ("点击右上角保存后生效", .systemBlue)
        }

        if let nextDate = snapshot.nextScheduledDate {
            if nextDate <= Date() {
                return ("等待执行备份", .systemBlue)
            }
            return ("下次备份：\(formattedDate(nextDate))", .secondaryLabel)
        }

        return ("已启用", .secondaryLabel)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 3
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:
            return 5
        case 1:
            return 5
        case 2:
            return 2
        default:
            return 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0:
            return "定时设置与状态"
        case 1:
            return "OpenList 服务器"
        case 2:
            return "操作"
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 1 {
            return "支持填写 OpenList 站点地址与账号密码，或将用户名留空并在密码栏填入 API Token；若地址包含 /dav 路径将自动使用 WebDAV 上传。"
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            if indexPath.row == 0 {
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                cell.selectionStyle = .none
                cell.textLabel?.text = "启用自动备份"
                let toggle = UISwitch()
                toggle.isOn = draftConfig.isEnabled
                toggle.addTarget(self, action: #selector(handleEnabledSwitchChanged(_:)), for: .valueChanged)
                cell.accessoryView = toggle
                return cell
            }

            if indexPath.row == 1 {
                let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
                cell.textLabel?.text = "备份间隔"
                cell.detailTextLabel?.text = "\(draftConfig.intervalHours) 小时"
                cell.accessoryType = .disclosureIndicator
                return cell
            }

            if indexPath.row == 2 {
                let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
                cell.selectionStyle = .none
                cell.textLabel?.text = "备份文件名"
                cell.detailTextLabel?.text = draftConfig.backupFileName
                cell.detailTextLabel?.lineBreakMode = .byTruncatingMiddle
                return cell
            }

            if indexPath.row == 3 {
                let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
                cell.selectionStyle = .none
                cell.textLabel?.text = "上次上传成功"
                let snapshot = AutoBackupManager.shared.statusSnapshot
                if let lastSuccess = snapshot.config.lastSuccessDate {
                    cell.detailTextLabel?.text = formattedDate(lastSuccess)
                } else {
                    cell.detailTextLabel?.text = "尚未备份"
                }
                return cell
            }

            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.textLabel?.text = "备份状态"
            let (statusText, statusColor) = statusTextAndColor()
            cell.detailTextLabel?.text = statusText
            cell.detailTextLabel?.textColor = statusColor
            cell.detailTextLabel?.numberOfLines = 0
            return cell
        }

        if indexPath.section == 1 {
            let cell = AutoBackupInputCell()
            switch indexPath.row {
            case 0:
                cell.configure(
                    title: "服务器地址",
                    placeholder: "https://pan.example.com",
                    text: draftConfig.serverURL,
                    keyboardType: .URL,
                    isSecure: false,
                    tag: 100,
                    delegate: self,
                    target: self,
                    editingChangedAction: #selector(handleTextFieldChanged(_:))
                )
                serverURLField = cell.textField
            case 1:
                cell.configure(
                    title: "用户名",
                    placeholder: "使用 Token 时可留空",
                    text: draftConfig.username,
                    keyboardType: .asciiCapable,
                    isSecure: false,
                    tag: 101,
                    delegate: self,
                    target: self,
                    editingChangedAction: #selector(handleTextFieldChanged(_:))
                )
                usernameField = cell.textField
            case 2:
                cell.configure(
                    title: "密码或 Token",
                    placeholder: "输入密码或 API Token",
                    text: draftServerSecret,
                    keyboardType: .asciiCapable,
                    isSecure: true,
                    tag: 102,
                    delegate: self,
                    target: self,
                    editingChangedAction: #selector(handleTextFieldChanged(_:))
                )
                passwordOrTokenField = cell.textField
            case 3:
                cell.configure(
                    title: "上传路径",
                    placeholder: "/SimpleBrowserBackups",
                    text: draftConfig.remoteDirectory,
                    keyboardType: .default,
                    isSecure: false,
                    tag: 103,
                    delegate: self,
                    target: self,
                    editingChangedAction: #selector(handleTextFieldChanged(_:))
                )
                remoteDirectoryField = cell.textField
            default:
                cell.configure(
                    title: "加密密码",
                    placeholder: "留空则上传明文备份",
                    text: draftBackupPassword,
                    keyboardType: .default,
                    isSecure: true,
                    tag: 104,
                    delegate: self,
                    target: self,
                    editingChangedAction: #selector(handleTextFieldChanged(_:))
                )
                backupPasswordField = cell.textField
            }
            return cell
        }

        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.textAlignment = .center
        cell.textLabel?.font = .systemFont(ofSize: 16, weight: .medium)

        let isUploading = AutoBackupManager.shared.statusSnapshot.isUploading
        if indexPath.row == 0 {
            cell.textLabel?.text = isTestingConnection ? "正在测试连接…" : "测试连接"
            cell.textLabel?.textColor = isTestingConnection ? .secondaryLabel : .systemBlue
            cell.selectionStyle = isTestingConnection ? .none : .default
        } else {
            cell.textLabel?.text = isUploading ? "正在上传备份…" : "立即备份"
            cell.textLabel?.textColor = isUploading ? .secondaryLabel : .systemBlue
            cell.selectionStyle = isUploading ? .none : .default
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.section == 0 && indexPath.row == 1 {
            dismissKeyboard()
            showIntervalPicker()
            return
        }

        if indexPath.section == 2 {
            dismissKeyboard()
            if indexPath.row == 0 {
                handleTestConnection()
            } else {
                handleManualBackup()
            }
        }
    }

    private func showIntervalPicker() {
        let sheet = UIAlertController(title: "选择备份间隔", message: nil, preferredStyle: .actionSheet)
        let presets = [1, 2, 4, 6, 12, 24, 48, 72, 168]

        for hours in presets {
            let title = hours == draftConfig.intervalHours ? "\(hours) 小时 ✓" : "\(hours) 小时"
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.draftConfig.intervalHours = hours
                self?.tableView.reloadRows(at: [IndexPath(row: 1, section: 0)], with: .none)
                self?.refreshLiveStatusDisplay(force: true)
            })
        }

        sheet.addAction(UIAlertAction(title: "自定义小时数", style: .default) { [weak self] _ in
            self?.promptCustomIntervalHours()
        })

        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = sheet.popoverPresentationController {
            let rect = tableView.rectForRow(at: IndexPath(row: 1, section: 0))
            popover.sourceView = tableView
            popover.sourceRect = rect
        }

        present(sheet, animated: true)
    }

    private func promptCustomIntervalHours() {
        let alert = UIAlertController(title: "自定义备份间隔", message: "请输入备份间隔小时数，支持 1 到 8760 小时", preferredStyle: .alert)
        alert.addTextField { [weak self] tf in
            tf.placeholder = "24"
            tf.keyboardType = .numberPad
            if let hours = self?.draftConfig.intervalHours {
                tf.text = "\(hours)"
            }
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { return }
            let raw = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let hours = Int(raw), hours >= 1, hours <= 8760 else {
                self.showAlert(title: "输入无效", message: "请输入 1 到 8760 之间的整数小时")
                return
            }
            self.draftConfig.intervalHours = hours
            self.tableView.reloadRows(at: [IndexPath(row: 1, section: 0)], with: .none)
            self.refreshLiveStatusDisplay(force: true)
        })
        present(alert, animated: true)
    }

    private func handleTestConnection() {
        guard !isTestingConnection else { return }
        if let validationError = validateDraftConfigurationForUpload() {
            showAlert(title: "配置不完整", message: validationError)
            return
        }

        isTestingConnection = true
        tableView.reloadRows(at: [IndexPath(row: 0, section: 2)], with: .none)

        AutoBackupManager.shared.testConnection(
            serverURL: draftConfig.serverURL,
            username: draftConfig.username,
            passwordOrToken: draftServerSecret,
            remoteDirectory: draftConfig.remoteDirectory
        ) { [weak self] result in
            guard let self = self else { return }
            self.isTestingConnection = false
            self.tableView.reloadRows(at: [IndexPath(row: 0, section: 2)], with: .none)

            switch result {
            case .success(let message):
                self.showAlert(title: "测试成功", message: message)
            case .failure(let error):
                self.showAlert(title: "连接失败", message: error.localizedDescription)
            }
        }
    }

    private func handleManualBackup() {
        guard !AutoBackupManager.shared.statusSnapshot.isUploading else { return }
        if let validationError = validateDraftConfigurationForUpload() {
            showAlert(title: "配置不完整", message: validationError)
            return
        }

        AutoBackupManager.shared.triggerManualBackup(
            overrideConfig: draftConfig,
            passwordOrToken: draftServerSecret,
            backupPassword: draftBackupPassword
        ) { [weak self] result in
            guard let self = self else { return }
            self.refreshLiveStatusDisplay(force: true)
            switch result {
            case .success(let remotePath):
                self.showAlert(title: "备份成功", message: "已上传至 \(remotePath)")
            case .failure(let error):
                let retrySuffix = AutoBackupManager.shared.statusSnapshot.isWaitingForRetry
                    ? "\n系统将在 1 分钟后自动重试。"
                    : ""
                self.showAlert(title: "上传失败", message: "\(error.localizedDescription)\(retrySuffix)")
            }
        }
        refreshLiveStatusDisplay(force: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        let value = textField.text ?? ""
        switch textField.tag {
        case 100:
            draftConfig.serverURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
        case 101:
            draftConfig.username = value.trimmingCharacters(in: .whitespacesAndNewlines)
        case 102:
            draftServerSecret = value.trimmingCharacters(in: .whitespacesAndNewlines)
        case 103:
            draftConfig.remoteDirectory = OpenListClient.normalizeRemoteDirectory(value)
            textField.text = draftConfig.remoteDirectory
        case 104:
            draftBackupPassword = value
        default:
            break
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        switch textField.tag {
        case 100:
            usernameField?.becomeFirstResponder()
        case 101:
            passwordOrTokenField?.becomeFirstResponder()
        case 102:
            remoteDirectoryField?.becomeFirstResponder()
        case 103:
            backupPasswordField?.becomeFirstResponder()
        default:
            textField.resignFirstResponder()
        }
        return true
    }
}

private final class AutoBackupInputCell: UITableViewCell {
    private let titleLabel = UILabel()
    let textField = UITextField()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15.5, weight: .regular)
        titleLabel.textColor = .label
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .systemFont(ofSize: 15.5, weight: .regular)
        textField.textColor = .label
        textField.textAlignment = .right
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.clearButtonMode = .whileEditing
        textField.returnKeyType = .next

        contentView.addSubview(titleLabel)
        contentView.addSubview(textField)

        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            textField.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            textField.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        placeholder: String,
        text: String,
        keyboardType: UIKeyboardType,
        isSecure: Bool,
        tag: Int,
        delegate: UITextFieldDelegate,
        target: Any?,
        editingChangedAction: Selector
    ) {
        titleLabel.text = title
        textField.placeholder = placeholder
        textField.text = text
        textField.keyboardType = keyboardType
        textField.isSecureTextEntry = isSecure
        textField.tag = tag
        textField.delegate = delegate
        textField.removeTarget(target, action: editingChangedAction, for: .editingChanged)
        textField.addTarget(target, action: editingChangedAction, for: .editingChanged)
        textField.returnKeyType = tag == 104 ? .done : .next
    }
}
