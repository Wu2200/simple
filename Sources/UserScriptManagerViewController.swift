import UIKit

struct UserScript: Codable {
    var id: String
    var name: String
    var matchPattern: String
    var code: String
    var isEnabled: Bool
}

struct RegisteredMenuCommand {
    let scriptId: String
    let cmdId: Int
    let caption: String
}

final class UserScriptStore {
    static let shared = UserScriptStore()
    private let key = "user_tampermonkey_scripts_v5"

    private init() {}

    func loadScripts() -> [UserScript] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let scripts = try? JSONDecoder().decode([UserScript].self, from: data) else {
            return []
        }
        return scripts
    }

    func saveScripts(_ scripts: [UserScript]) {
        if let data = try? JSONEncoder().encode(scripts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func isHostExcluded(_ host: String, for script: UserScript) -> Bool {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanHost.isEmpty else { return false }
        let rawPatterns = script.matchPattern.components(separatedBy: CharacterSet(charactersIn: ",\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let excludePatterns = rawPatterns.filter { $0.hasPrefix("!") }.map {
            String($0.dropFirst()).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }

        for ex in excludePatterns {
            if doesHost(cleanHost, matchPattern: ex) {
                return true
            }
        }
        return false
    }

    func excludeHost(_ host: String, for script: inout UserScript) {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanHost.isEmpty else { return }
        let excludeToken = "!\(cleanHost)"
        let parts = script.matchPattern.components(separatedBy: CharacterSet(charactersIn: ",\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.contains(where: { $0.lowercased() == excludeToken }) {
            return
        }
        var updated = parts
        if updated.isEmpty {
            updated.append("*")
        }
        updated.append(excludeToken)
        script.matchPattern = updated.joined(separator: ", ")
    }

    func removeExcludedHost(_ host: String, for script: inout UserScript) {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanHost.isEmpty else { return }
        let parts = script.matchPattern.components(separatedBy: CharacterSet(charactersIn: ",\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let updated = parts.filter { part in
            guard part.hasPrefix("!") else { return true }
            let ex = String(part.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !ex.isEmpty else { return false }
            return !doesHost(cleanHost, matchPattern: ex)
        }
        script.matchPattern = updated.isEmpty ? "*" : updated.joined(separator: ", ")
    }

    func isScriptApplicableForPanel(script: UserScript, urlString: String) -> Bool {
        guard let url = URL(string: urlString), let rawHost = url.host, !rawHost.isEmpty else {
            return false
        }
        let host = rawHost.lowercased()

        let rawPatterns = script.matchPattern.components(separatedBy: CharacterSet(charactersIn: ",\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let includePatterns = rawPatterns.filter { !$0.hasPrefix("!") }
        if includePatterns.isEmpty || includePatterns.contains("*") || includePatterns.contains("<all_urls>") {
            return true
        }

        for pattern in includePatterns {
            if doesHost(host, matchPattern: pattern) {
                return true
            }
        }

        return false
    }

    func parseMetadata(from code: String) -> (name: String, match: String) {
        var nameMap: [String: String] = [:]
        var matches: [String] = []
        let doubleSlash = String(repeating: "/", count: 2)

        let lines = code.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(doubleSlash) else { continue }
            let content = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard content.hasPrefix("@") else { continue }

            let components = content.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard components.count >= 2 else { continue }

            let tag = components[0]
            let val = components.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)

            if tag.hasPrefix("@name") {
                nameMap[tag] = val
            } else if tag == "@match" || tag == "@include" {
                if !val.isEmpty && !matches.contains(val) {
                    matches.append(val)
                }
            } else if tag == "@exclude" || tag == "@exclude-match" {
                let exVal = "!" + val
                if !val.isEmpty && !matches.contains(exVal) {
                    matches.append(exVal)
                }
            }
        }

        let preferredName = nameMap["@name:zh-CN"] ?? nameMap["@name:zh"] ?? nameMap["@name:zh-TW"] ?? nameMap["@name"] ?? "未命名脚本"
        let preferredMatch = matches.isEmpty ? "*" : matches.joined(separator: ", ")

        return (preferredName, preferredMatch)
    }

    private func doesHost(_ host: String, matchPattern rawPattern: String) -> Bool {
        if rawPattern == "*" || rawPattern == "<all_urls>" {
            return true
        }

        let schemeSeparator = ":" + String(repeating: "/", count: 2)
        var p = rawPattern.lowercased()
        if let schemeRange = p.range(of: schemeSeparator) {
            p = String(p[schemeRange.upperBound...])
        }
        if let slashIndex = p.firstIndex(of: "/") {
            p = String(p[..<slashIndex])
        }
        p = p.trimmingCharacters(in: .whitespaces)

        if p == "*" || p.isEmpty {
            return true
        }

        if p.hasPrefix("*.") {
            let suffix = String(p.dropFirst(2))
            return host == suffix || host.hasSuffix("." + suffix)
        } else if p.hasPrefix("*") {
            let suffix = String(p.dropFirst(1))
            return host.hasSuffix(suffix)
        } else {
            return host == p || host.hasSuffix("." + p)
        }
    }

    func isScriptMatching(script: UserScript, urlString: String) -> Bool {
        guard script.isEnabled else { return false }

        guard let url = URL(string: urlString), let rawHost = url.host, !rawHost.isEmpty else {
            return false
        }
        let host = rawHost.lowercased()

        let scriptEnabled = DomainSettingsStore.shared.getBool(domain: host, setting: "userScripts", defaultVal: true)
        if !scriptEnabled { return false }

        let rawPatterns = script.matchPattern.components(separatedBy: CharacterSet(charactersIn: ",\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let excludePatterns = rawPatterns.filter { $0.hasPrefix("!") }.map {
            String($0.dropFirst()).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }

        for ex in excludePatterns {
            if doesHost(host, matchPattern: ex) {
                return false
            }
        }

        let includePatterns = rawPatterns.filter { !$0.hasPrefix("!") }
        if includePatterns.isEmpty || includePatterns.contains("*") || includePatterns.contains("<all_urls>") {
            return true
        }

        for pattern in includePatterns {
            if doesHost(host, matchPattern: pattern) {
                return true
            }
        }

        return false
    }
}

final class ScriptDataStore {
    static let shared = ScriptDataStore()
    private init() {}

    private func makeKey(_ scriptId: String, _ name: String) -> String {
        return "GM_DATA_\(scriptId)_\(name)"
    }

    func getValue(scriptId: String, name: String) -> Any? {
        return UserDefaults.standard.object(forKey: makeKey(scriptId, name))
    }

    func setValue(scriptId: String, name: String, value: Any) {
        UserDefaults.standard.set(value, forKey: makeKey(scriptId, name))
    }

    func deleteValue(scriptId: String, name: String) {
        UserDefaults.standard.removeObject(forKey: makeKey(scriptId, name))
    }

    func clearDataForScript(scriptId: String) {
        let prefix = "GM_DATA_\(scriptId)_"
        for (k, _) in UserDefaults.standard.dictionaryRepresentation() {
            if k.hasPrefix(prefix) {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
    }

    func clearAllScriptData() {
        let prefix = "GM_DATA_"
        for (k, _) in UserDefaults.standard.dictionaryRepresentation() {
            if k.hasPrefix(prefix) {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
    }

    func getAllValuesJSON(scriptId: String) -> String {
        let prefix = "GM_DATA_\(scriptId)_"
        var dict: [String: Any] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() {
            if k.hasPrefix(prefix) {
                let name = String(k.dropFirst(prefix.count))
                dict[name] = v
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}

final class UserScriptManagerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    private var allScripts: [UserScript] = []
    private var filteredScripts: [UserScript] = []

    var onScriptsUpdated: (() -> Void)?

    private let searchField = UITextField()
    private let tableView = UITableView(frame: .zero, style: .plain)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1.0)
        setupInterface()
        loadData()
    }

    private func setupInterface() {
        let headerView = UIView()
        headerView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.text = "管理面板"

        let addButton = TouchButton()
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        addButton.tintColor = .systemRed
        addButton.addTarget(self, action: #selector(handleAddScript), for: .touchUpInside)

        let closeButton = TouchButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
        closeButton.tintColor = .tertiaryLabel
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)

        headerView.addSubview(titleLabel)
        headerView.addSubview(addButton)
        headerView.addSubview(closeButton)

        let searchContainer = UIView()
        searchContainer.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.backgroundColor = UIColor(white: 0.9, alpha: 0.5)
        searchContainer.layer.cornerRadius = 10
        searchContainer.clipsToBounds = true

        let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.tintColor = .secondaryLabel

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholder = "搜索"
        searchField.font = .systemFont(ofSize: 15)
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(handleSearchChanged), for: .editingChanged)

        searchContainer.addSubview(searchIcon)
        searchContainer.addSubview(searchField)

        let sectionHeader = UILabel()
        sectionHeader.translatesAutoresizingMaskIntoConstraints = false
        sectionHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        sectionHeader.textColor = .secondaryLabel
        sectionHeader.text = "USERSCRIPT"

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UserScriptRowCell.self, forCellReuseIdentifier: "UserScriptRowCell")

        view.addSubview(headerView)
        view.addSubview(searchContainer)
        view.addSubview(sectionHeader)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            headerView.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            addButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -16),
            addButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 28),
            addButton.heightAnchor.constraint(equalToConstant: 28),

            searchContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 14),
            searchContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            searchContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            searchContainer.heightAnchor.constraint(equalToConstant: 36),

            searchIcon.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 10),
            searchIcon.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -10),
            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor),

            sectionHeader.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 16),
            sectionHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),

            tableView.topAnchor.constraint(equalTo: sectionHeader.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10)
        ])
    }

    private func loadData() {
        allScripts = UserScriptStore.shared.loadScripts()
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.text?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if query.isEmpty {
            filteredScripts = allScripts
        } else {
            filteredScripts = allScripts.filter { $0.name.lowercased().contains(query) || $0.matchPattern.lowercased().contains(query) }
        }
        tableView.reloadData()
    }

    @objc private func handleSearchChanged() {
        applyFilter()
    }

    @objc private func handleAddScript() {
        let editor = UserScriptEditorViewController(script: nil)
        editor.onSave = { [weak self] newScript in
            self?.allScripts.append(newScript)
            UserScriptStore.shared.saveScripts(self?.allScripts ?? [])
            self?.loadData()
            self?.onScriptsUpdated?()
        }
        let nav = UINavigationController(rootViewController: editor)
        present(nav, animated: true)
    }

    @objc private func handleClose() {
        dismiss(animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filteredScripts.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 74
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "UserScriptRowCell", for: indexPath) as! UserScriptRowCell
        let script = filteredScripts[indexPath.row]
        cell.configure(script: script, index: indexPath.row)
        cell.onToggle = { [weak self] isEnabled in
            guard let self = self else { return }
            if let idx = self.allScripts.firstIndex(where: { $0.id == script.id }) {
                self.allScripts[idx].isEnabled = isEnabled
                UserScriptStore.shared.saveScripts(self.allScripts)
                self.onScriptsUpdated?()
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let script = filteredScripts[indexPath.row]
        let editor = UserScriptEditorViewController(script: script)
        editor.onSave = { [weak self] updatedScript in
            if let idx = self?.allScripts.firstIndex(where: { $0.id == updatedScript.id }) {
                self?.allScripts[idx] = updatedScript
                UserScriptStore.shared.saveScripts(self?.allScripts ?? [])
                self?.loadData()
                self?.onScriptsUpdated?()
            }
        }
        let nav = UINavigationController(rootViewController: editor)
        present(nav, animated: true)
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let script = filteredScripts[indexPath.row]
            ScriptDataStore.shared.clearDataForScript(scriptId: script.id)
            allScripts.removeAll { $0.id == script.id }
            UserScriptStore.shared.saveScripts(allScripts)
            applyFilter()
            onScriptsUpdated?()
        }
    }
}

final class UserScriptRowCell: UITableViewCell {
    private let cardView = UIView()
    private let iconView = UIView()
    private let iconLabel = UILabel()
    private let nameLabel = UILabel()
    private let matchLabel = UILabel()
    private let toggleSwitch = UISwitch()

    var onToggle: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .white
        cardView.layer.cornerRadius = 16
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOpacity = 0.04
        cardView.layer.shadowRadius = 8
        cardView.layer.shadowOffset = CGSize(width: 0, height: 2)
        cardView.clipsToBounds = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.backgroundColor = UIColor(white: 0.95, alpha: 1.0)
        iconView.layer.cornerRadius = 12
        iconView.clipsToBounds = true

        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.font = .systemFont(ofSize: 18, weight: .bold)
        iconLabel.textColor = .systemRed
        iconLabel.textAlignment = .center

        iconView.addSubview(iconLabel)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 15, weight: .bold)
        nameLabel.textColor = .label

        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        matchLabel.font = .systemFont(ofSize: 12, weight: .regular)
        matchLabel.textColor = .secondaryLabel
        matchLabel.lineBreakMode = .byTruncatingTail

        toggleSwitch.translatesAutoresizingMaskIntoConstraints = false
        toggleSwitch.onTintColor = .systemRed
        toggleSwitch.addTarget(self, action: #selector(handleSwitch), for: .valueChanged)

        let labelStack = UIStackView(arrangedSubviews: [nameLabel, matchLabel])
        labelStack.translatesAutoresizingMaskIntoConstraints = false
        labelStack.axis = .vertical
        labelStack.spacing = 3

        cardView.addSubview(iconView)
        cardView.addSubview(labelStack)
        cardView.addSubview(toggleSwitch)

        contentView.addSubview(cardView)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),

            iconView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 42),
            iconView.heightAnchor.constraint(equalToConstant: 42),

            iconLabel.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            iconLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            labelStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            labelStack.trailingAnchor.constraint(equalTo: toggleSwitch.leadingAnchor, constant: -10),
            labelStack.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),

            toggleSwitch.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            toggleSwitch.centerYAnchor.constraint(equalTo: cardView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(script: UserScript, index: Int) {
        nameLabel.text = script.name
        matchLabel.text = "匹配: \(script.matchPattern)"
        toggleSwitch.isOn = script.isEnabled

        let firstChar = String(script.name.prefix(1))
        iconLabel.text = firstChar.isEmpty ? "网" : firstChar

        let colors: [UIColor] = [.systemRed, .systemOrange, .systemBlue, .systemPurple, .systemTeal]
        iconLabel.textColor = colors[index % colors.count]
    }

    @objc private func handleSwitch() {
        onToggle?(toggleSwitch.isOn)
    }
}

final class UserScriptEditorViewController: UIViewController {
    private var script: UserScript?
    var onSave: ((UserScript) -> Void)?

    private let nameField = UITextField()
    private let matchField = UITextView()
    private let textView = UITextView()

    init(script: UserScript?) {
        self.script = script
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = script == nil ? "新建油猴脚本" : "编辑脚本"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "保存",
            style: .done,
            target: self,
            action: #selector(handleSave)
        )
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: self,
            action: #selector(handleCancel)
        )

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.backgroundColor = .secondarySystemGroupedBackground
        nameField.layer.cornerRadius = 10
        nameField.clipsToBounds = true
        nameField.placeholder = "脚本名称"
        nameField.font = .systemFont(ofSize: 15)

        let namePadding = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        nameField.leftView = namePadding
        nameField.leftViewMode = .always

        matchField.translatesAutoresizingMaskIntoConstraints = false
        matchField.backgroundColor = .secondarySystemGroupedBackground
        matchField.layer.cornerRadius = 10
        matchField.clipsToBounds = true
        matchField.font = .systemFont(ofSize: 14)
        matchField.textColor = .label
        matchField.autocapitalizationType = .none
        matchField.autocorrectionType = .no
        matchField.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 12
        textView.clipsToBounds = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)

        if let currentScript = script {
            nameField.text = currentScript.name
            matchField.text = currentScript.matchPattern
            textView.text = currentScript.code
        } else {
            let defaultCode = "(function() {\n    'use strict';\n})();"
            textView.text = defaultCode
            let parsed = UserScriptStore.shared.parseMetadata(from: defaultCode)
            nameField.text = parsed.name == "未命名脚本" ? "" : parsed.name
            matchField.text = parsed.match
        }

        view.addSubview(nameField)
        view.addSubview(matchField)
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            nameField.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            nameField.heightAnchor.constraint(equalToConstant: 42),

            matchField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 10),
            matchField.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            matchField.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            matchField.heightAnchor.constraint(equalToConstant: 54),

            textView.topAnchor.constraint(equalTo: matchField.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    @objc private func handleSave() {
        let codeText = textView.text ?? ""
        var nameText = nameField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        var matchText = matchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let parsed = UserScriptStore.shared.parseMetadata(from: codeText)
        if nameText.isEmpty { nameText = parsed.name }
        if matchText.isEmpty { matchText = parsed.match }

        let item = UserScript(
            id: script?.id ?? UUID().uuidString,
            name: nameText,
            matchPattern: matchText,
            code: codeText,
            isEnabled: script?.isEnabled ?? true
        )

        onSave?(item)
        dismiss(animated: true)
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }
}
