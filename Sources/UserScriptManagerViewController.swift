import UIKit

// MARK: - 用户脚本模型
struct UserScript: Codable, Equatable {
    let id: String
    var name: String
    var match: String
    var code: String
    var isEnabled: Bool

    init(id: String = UUID().uuidString, name: String, match: String, code: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.match = match
        self.code = code
        self.isEnabled = isEnabled
    }
}

// MARK: - 脚本持久化管理器
final class UserScriptStore {
    static let shared = UserScriptStore()
    private let key = "UserScriptsList_V1"

    private(set) var scripts: [UserScript] = []

    private init() {
        loadScripts()
    }

    func addScript(_ script: UserScript) {
        scripts.append(script)
        saveScripts()
    }

    func updateScript(_ script: UserScript) {
        guard let idx = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        scripts[idx] = script
        saveScripts()
    }

    func deleteScript(id: String) {
        scripts.removeAll { $0.id == id }
        saveScripts()
    }

    func toggleScript(id: String) {
        guard let idx = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[idx].isEnabled.toggle()
        saveScripts()
    }

    private func saveScripts() {
        if let data = try? JSONEncoder().encode(scripts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadScripts() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([UserScript].self, from: data) {
            scripts = list
        }
    }
}

// MARK: - 脚本管理器视图控制器
final class UserScriptManagerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var scripts: [UserScript] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "用户脚本管理"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(handleAdd))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleDone))

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ScriptCell")
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        loadScripts()
    }

    private func loadScripts() {
        scripts = UserScriptStore.shared.scripts
        tableView.reloadData()
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    @objc private func handleAdd() {
        let editor = UserScriptEditorViewController(script: nil) { [weak self] newScript in
            UserScriptStore.shared.addScript(newScript)
            self?.loadScripts()
        }
        present(UINavigationController(rootViewController: editor), animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return scripts.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ScriptCell", for: indexPath)
        let item = scripts[indexPath.row]

        cell.textLabel?.text = item.name
        cell.textLabel?.font = .systemFont(ofSize: 15.5, weight: .medium)
        cell.backgroundColor = .secondarySystemGroupedBackground

        let sw = UISwitch()
        sw.isOn = item.isEnabled
        sw.tag = indexPath.row
        sw.addTarget(self, action: #selector(handleSwitch(_:)), for: .valueChanged)
        cell.accessoryView = sw

        return cell
    }

    @objc private func handleSwitch(_ sender: UISwitch) {
        let script = scripts[sender.tag]
        UserScriptStore.shared.toggleScript(id: script.id)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let script = scripts[indexPath.row]
        let editor = UserScriptEditorViewController(script: script) { [weak self] updated in
            UserScriptStore.shared.updateScript(updated)
            self?.loadScripts()
        }
        present(UINavigationController(rootViewController: editor), animated: true)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let script = scripts[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] (_, _, completion) in
            UserScriptStore.shared.deleteScript(id: script.id)
            self?.scripts.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .fade)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

// MARK: - 脚本代码编辑控制器
final class UserScriptEditorViewController: UIViewController {

    private let script: UserScript?
    private let onSave: (UserScript) -> Void

    private let nameField = UITextField()
    private let matchField = UITextField()
    private let codeTextView = UITextView()

    init(script: UserScript?, onSave: @escaping (UserScript) -> Void) {
        self.script = script
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = script == nil ? "新建脚本" : "编辑脚本"
        view.backgroundColor = .systemBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(handleCancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", style: .done, target: self, action: #selector(handleSave))

        setupUI()
    }

    private func setupUI() {
        let nameCard = UIView()
        nameCard.translatesAutoresizingMaskIntoConstraints = false
        nameCard.backgroundColor = .secondarySystemBackground
        nameCard.layer.cornerRadius = 10
        view.addSubview(nameCard)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholder = "脚本名称"
        nameField.text = script?.name
        nameField.font = .systemFont(ofSize: 15)
        nameCard.addSubview(nameField)

        let matchCard = UIView()
        matchCard.translatesAutoresizingMaskIntoConstraints = false
        matchCard.backgroundColor = .secondarySystemBackground
        matchCard.layer.cornerRadius = 10
        view.addSubview(matchCard)

        matchField.translatesAutoresizingMaskIntoConstraints = false
        matchField.placeholder = "匹配规则 (如: *://*.example.com/*)"
        matchField.text = script?.match
        matchField.font = .systemFont(ofSize: 14)
        matchField.autocapitalizationType = .none
        matchCard.addSubview(matchField)

        codeTextView.translatesAutoresizingMaskIntoConstraints = false
        codeTextView.backgroundColor = .secondarySystemBackground
        codeTextView.layer.cornerRadius = 10
        codeTextView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        codeTextView.autocapitalizationType = .none
        codeTextView.autocorrectionType = .no
        codeTextView.text = script?.code ?? "// ==UserScript==\n// @name         New Script\n// @match        *://*/*\n// ==/UserScript==\n\nconsole.log('Hello');\n"
        view.addSubview(codeTextView)

        NSLayoutConstraint.activate([
            nameCard.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            nameCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            nameCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            nameCard.heightAnchor.constraint(equalToConstant: 44),

            nameField.leadingAnchor.constraint(equalTo: nameCard.leadingAnchor, constant: 12),
            nameField.trailingAnchor.constraint(equalTo: nameCard.trailingAnchor, constant: -12),
            nameField.centerYAnchor.constraint(equalTo: nameCard.centerYAnchor),

            matchCard.topAnchor.constraint(equalTo: nameCard.bottomAnchor, constant: 10),
            matchCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            matchCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            matchCard.heightAnchor.constraint(equalToConstant: 44),

            matchField.leadingAnchor.constraint(equalTo: matchCard.leadingAnchor, constant: 12),
            matchField.trailingAnchor.constraint(equalTo: matchCard.trailingAnchor, constant: -12),
            matchField.centerYAnchor.constraint(equalTo: matchCard.centerYAnchor),

            codeTextView.topAnchor.constraint(equalTo: matchCard.bottomAnchor, constant: 10),
            codeTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            codeTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            codeTextView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12)
        ])
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }

    @objc private func handleSave() {
        let name = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let match = matchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let code = codeTextView.text ?? ""

        let validName = name.isEmpty ? "未命名脚本" : name
        let validMatch = match.isEmpty ? "*://*/*" : match

        let newScript = UserScript(
            id: script?.id ?? UUID().uuidString,
            name: validName,
            match: validMatch,
            code: code,
            isEnabled: script?.isEnabled ?? true
        )

        onSave(newScript)
        dismiss(animated: true)
    }
}
