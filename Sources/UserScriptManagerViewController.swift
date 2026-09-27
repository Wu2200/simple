import UIKit

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
