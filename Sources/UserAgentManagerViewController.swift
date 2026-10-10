import UIKit

enum UserAgentCategory: String, Codable {
    case mobile
    case desktop
    case custom
}

struct UserAgentItem: Codable, Equatable {
    var id: String
    var name: String
    var uaString: String
    var isCustom: Bool
    var category: UserAgentCategory
}

final class UserAgentStore {
    static let shared = UserAgentStore()
    private let keyCustomItems = "browser_ua_custom_items_v5"
    private let keySelectedMobileId = "browser_ua_selected_mobile_id_v6"
    private let keySelectedDesktopId = "browser_ua_selected_desktop_id_v6"
    private let keyCurrentMode = "browser_ua_current_mode_v6"

    private let defaultMobileItems: [UserAgentItem] = [
        UserAgentItem(
            id: "default_safari",
            name: "iPhone Safari",
            uaString: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
            isCustom: false,
            category: .mobile
        ),
        UserAgentItem(
            id: "default_chrome",
            name: "iPhone Chrome",
            uaString: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/125.0.6422.80 Mobile/15E148 Safari/604.1",
            isCustom: false,
            category: .mobile
        ),
        UserAgentItem(
            id: "default_ipad",
            name: "iPad Safari",
            uaString: "Mozilla/5.0 (iPad; CPU OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
            isCustom: false,
            category: .mobile
        ),
        UserAgentItem(
            id: "default_android_chrome",
            name: "Android Chrome",
            uaString: "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36",
            isCustom: false,
            category: .mobile
        )
    ]

    private let defaultDesktopItems: [UserAgentItem] = [
        UserAgentItem(
            id: "default_mac",
            name: "macOS Chrome",
            uaString: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            isCustom: false,
            category: .desktop
        ),
        UserAgentItem(
            id: "default_mac_safari",
            name: "macOS Safari",
            uaString: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15",
            isCustom: false,
            category: .desktop
        ),
        UserAgentItem(
            id: "default_win_chrome",
            name: "Windows Chrome",
            uaString: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            isCustom: false,
            category: .desktop
        ),
        UserAgentItem(
            id: "default_win_edge",
            name: "Windows Edge",
            uaString: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36 Edg/125.0.0.0",
            isCustom: false,
            category: .desktop
        )
    ]

    private init() {}

    var currentMode: UserAgentCategory {
        get {
            guard let raw = UserDefaults.standard.string(forKey: keyCurrentMode),
                  let cat = UserAgentCategory(rawValue: raw) else {
                return .mobile
            }
            return cat
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: keyCurrentMode)
        }
    }

    func loadMobileItems() -> [UserAgentItem] {
        return defaultMobileItems
    }

    func loadDesktopItems() -> [UserAgentItem] {
        return defaultDesktopItems
    }

    func loadCustomItems() -> [UserAgentItem] {
        if let data = UserDefaults.standard.data(forKey: keyCustomItems),
           let customs = try? JSONDecoder().decode([UserAgentItem].self, from: data) {
            return customs
        }
        return []
    }

    func loadAllItems() -> [UserAgentItem] {
        var items = defaultMobileItems + defaultDesktopItems
        items.append(contentsOf: loadCustomItems())
        return items
    }

    func addCustomItem(name: String, uaString: String, category: UserAgentCategory = .mobile) {
        var customs = loadCustomItems()
        let newItem = UserAgentItem(id: UUID().uuidString, name: name, uaString: uaString, isCustom: true, category: category)
        customs.append(newItem)
        if let data = try? JSONEncoder().encode(customs) {
            UserDefaults.standard.set(data, forKey: keyCustomItems)
        }
    }

    func updateCustomItem(id: String, name: String, uaString: String) {
        var customs = loadCustomItems()
        if let idx = customs.firstIndex(where: { $0.id == id }) {
            customs[idx].name = name
            customs[idx].uaString = uaString
            if let data = try? JSONEncoder().encode(customs) {
                UserDefaults.standard.set(data, forKey: keyCustomItems)
            }
        }
    }

    func deleteCustomItem(id: String) {
        var customs = loadCustomItems()
        customs.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(customs) {
            UserDefaults.standard.set(data, forKey: keyCustomItems)
        }
        if getSelectedMobileId() == id {
            setSelectedMobileId(defaultMobileItems[0].id)
        }
        if getSelectedDesktopId() == id {
            setSelectedDesktopId(defaultDesktopItems[0].id)
        }
    }

    func getSelectedMobileId() -> String {
        return UserDefaults.standard.string(forKey: keySelectedMobileId) ?? defaultMobileItems[0].id
    }

    func setSelectedMobileId(_ id: String) {
        UserDefaults.standard.set(id, forKey: keySelectedMobileId)
    }

    func getSelectedDesktopId() -> String {
        return UserDefaults.standard.string(forKey: keySelectedDesktopId) ?? defaultDesktopItems[0].id
    }

    func setSelectedDesktopId(_ id: String) {
        UserDefaults.standard.set(id, forKey: keySelectedDesktopId)
    }

    func getSelectedUA() -> String {
        let all = loadAllItems()
        let selId = (currentMode == .desktop) ? getSelectedDesktopId() : getSelectedMobileId()
        let defaultItem = (currentMode == .desktop) ? defaultDesktopItems[0] : defaultMobileItems[0]
        return all.first { $0.id == selId }?.uaString ?? defaultItem.uaString
    }

    func getSelectedItem() -> UserAgentItem {
        let all = loadAllItems()
        let selId = (currentMode == .desktop) ? getSelectedDesktopId() : getSelectedMobileId()
        let defaultItem = (currentMode == .desktop) ? defaultDesktopItems[0] : defaultMobileItems[0]
        return all.first { $0.id == selId } ?? defaultItem
    }
}

final class UserAgentManagerViewController: UITableViewController {
    private var mobilePresets: [UserAgentItem] = []
    private var desktopPresets: [UserAgentItem] = []
    private var customMobileItems: [UserAgentItem] = []
    private var customDesktopItems: [UserAgentItem] = []

    var onUASelected: ((UserAgentItem) -> Void)?

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "浏览器标识"
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemGroupedBackground
        tableView.register(UserAgentCardCell.self, forCellReuseIdentifier: "UserAgentCardCell")
        tableView.register(AddUserAgentCardCell.self, forCellReuseIdentifier: "AddUserAgentCardCell")

        navigationItem.rightBarButtonItem = nil
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(handleDone)
        )

        loadData()
    }

    private func loadData() {
        mobilePresets = UserAgentStore.shared.loadMobileItems()
        desktopPresets = UserAgentStore.shared.loadDesktopItems()
        let allCustom = UserAgentStore.shared.loadCustomItems()
        customMobileItems = allCustom.filter { $0.category == .mobile }
        customDesktopItems = allCustom.filter { $0.category == .desktop }
        tableView.reloadData()
    }

    @objc private func handleDone() {
        onUASelected?(UserAgentStore.shared.getSelectedItem())
        dismiss(animated: true)
    }

    private func showAddCustomUA(category: UserAgentCategory) {
        let isMobile = category == .mobile
        let title = isMobile ? "添加自定义移动版标识" : "添加自定义电脑版标识"
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { tf in tf.placeholder = "标识名称" }
        alert.addTextField { tf in
            tf.placeholder = "User-Agent 字符串"
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "添加", style: .default) { [weak self] _ in
            guard let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let ua = alert.textFields?[1].text?.trimmingCharacters(in: .whitespaces), !ua.isEmpty else { return }
            UserAgentStore.shared.addCustomItem(name: name, uaString: ua, category: category)
            self?.loadData()
            let allCustom = UserAgentStore.shared.loadCustomItems()
            if let newItem = allCustom.last(where: { $0.name == name && $0.category == category }) {
                if isMobile {
                    UserAgentStore.shared.setSelectedMobileId(newItem.id)
                } else {
                    UserAgentStore.shared.setSelectedDesktopId(newItem.id)
                }
                self?.tableView.reloadData()
                self?.onUASelected?(UserAgentStore.shared.getSelectedItem())
            }
        })
        present(alert, animated: true)
    }

    private func showEditUAAlert(item: UserAgentItem) {
        let alert = UIAlertController(title: "编辑标识", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "标识名称"
            tf.text = item.name
        }
        alert.addTextField { tf in
            tf.placeholder = "User-Agent 字符串"
            tf.text = item.uaString
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
            guard let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let ua = alert.textFields?[1].text?.trimmingCharacters(in: .whitespaces), !ua.isEmpty else { return }
            if item.isCustom {
                UserAgentStore.shared.updateCustomItem(id: item.id, name: name, uaString: ua)
            } else {
                UserAgentStore.shared.addCustomItem(name: name, uaString: ua, category: item.category)
                let allCustom = UserAgentStore.shared.loadCustomItems()
                if let added = allCustom.last(where: { $0.name == name && $0.category == item.category }) {
                    if item.category == .mobile {
                        UserAgentStore.shared.setSelectedMobileId(added.id)
                    } else {
                        UserAgentStore.shared.setSelectedDesktopId(added.id)
                    }
                }
            }
            self?.loadData()
            let currentItem = UserAgentStore.shared.getSelectedItem()
            self?.onUASelected?(currentItem)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? "移动版标识" : "电脑版标识"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return mobilePresets.count + customMobileItems.count + 1
        } else {
            return desktopPresets.count + customDesktopItems.count + 1
        }
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let presetsCount = (indexPath.section == 0) ? mobilePresets.count : desktopPresets.count
        let customsCount = (indexPath.section == 0) ? customMobileItems.count : customDesktopItems.count
        if indexPath.row == presetsCount + customsCount {
            return 52
        }
        return 68
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let isMobile = (indexPath.section == 0)
        let presets = isMobile ? mobilePresets : desktopPresets
        let customs = isMobile ? customMobileItems : customDesktopItems
        let totalItems = presets.count + customs.count

        if indexPath.row == totalItems {
            let cell = tableView.dequeueReusableCell(withIdentifier: "AddUserAgentCardCell", for: indexPath) as! AddUserAgentCardCell
            cell.configure(isMobile: isMobile)
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "UserAgentCardCell", for: indexPath) as! UserAgentCardCell
        let item: UserAgentItem
        if indexPath.row < presets.count {
            item = presets[indexPath.row]
        } else {
            item = customs[indexPath.row - presets.count]
        }

        let isSelected: Bool
        if isMobile {
            isSelected = (item.id == UserAgentStore.shared.getSelectedMobileId())
        } else {
            isSelected = (item.id == UserAgentStore.shared.getSelectedDesktopId())
        }

        cell.configure(item: item, isSelected: isSelected)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let isMobile = (indexPath.section == 0)
        let presets = isMobile ? mobilePresets : desktopPresets
        let customs = isMobile ? customMobileItems : customDesktopItems
        let totalItems = presets.count + customs.count

        if indexPath.row == totalItems {
            showAddCustomUA(category: isMobile ? .mobile : .desktop)
            return
        }

        let item: UserAgentItem
        if indexPath.row < presets.count {
            item = presets[indexPath.row]
        } else {
            item = customs[indexPath.row - presets.count]
        }

        if isMobile {
            UserAgentStore.shared.setSelectedMobileId(item.id)
        } else {
            UserAgentStore.shared.setSelectedDesktopId(item.id)
        }

        tableView.reloadData()
        onUASelected?(UserAgentStore.shared.getSelectedItem())
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let isMobile = (indexPath.section == 0)
        let presets = isMobile ? mobilePresets : desktopPresets
        let customs = isMobile ? customMobileItems : customDesktopItems
        let totalItems = presets.count + customs.count

        if indexPath.row == totalItems {
            return nil
        }

        if indexPath.row < presets.count {
            let item = presets[indexPath.row]
            let editAction = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, completion in
                self?.showEditUAAlert(item: item)
                completion(true)
            }
            editAction.backgroundColor = .systemBlue
            return UISwipeActionsConfiguration(actions: [editAction])
        }

        let customIndex = indexPath.row - presets.count
        let item = customs[customIndex]
        let editAction = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, completion in
            self?.showEditUAAlert(item: item)
            completion(true)
        }
        editAction.backgroundColor = .systemBlue

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            UserAgentStore.shared.deleteCustomItem(id: item.id)
            self?.loadData()
            let currentItem = UserAgentStore.shared.getSelectedItem()
            self?.onUASelected?(currentItem)
            completion(true)
        }

        return UISwipeActionsConfiguration(actions: [deleteAction, editAction])
    }
}

final class UserAgentCardCell: UITableViewCell {
    private let cardView = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let checkmarkImageView = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .secondarySystemGroupedBackground
        cardView.layer.cornerRadius = 12
        cardView.clipsToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.lineBreakMode = .byTruncatingTail

        checkmarkImageView.translatesAutoresizingMaskIntoConstraints = false
        checkmarkImageView.image = UIImage(systemName: "checkmark.circle.fill")
        checkmarkImageView.tintColor = .systemBlue
        checkmarkImageView.contentMode = .scaleAspectFit

        cardView.addSubview(titleLabel)
        cardView.addSubview(subtitleLabel)
        cardView.addSubview(checkmarkImageView)
        contentView.addSubview(cardView)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),

            checkmarkImageView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            checkmarkImageView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            checkmarkImageView.widthAnchor.constraint(equalToConstant: 20),
            checkmarkImageView.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: checkmarkImageView.leadingAnchor, constant: -12),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: checkmarkImageView.leadingAnchor, constant: -12),
            subtitleLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(item: UserAgentItem, isSelected: Bool) {
        titleLabel.text = item.name
        subtitleLabel.text = item.uaString
        checkmarkImageView.isHidden = !isSelected
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        UIView.animate(withDuration: 0.15) {
            self.cardView.alpha = highlighted ? 0.7 : 1.0
        }
    }
}

final class AddUserAgentCardCell: UITableViewCell {
    private let cardView = UIView()
    private let iconImageView = UIImageView()
    private let titleLabel = UILabel()
    private let contentStack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .secondarySystemGroupedBackground
        cardView.layer.cornerRadius = 12
        cardView.clipsToBounds = true

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.image = UIImage(
            systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        iconImageView.tintColor = .systemBlue
        iconImageView.contentMode = .scaleAspectFit

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .systemBlue

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 6
        contentStack.addArrangedSubview(iconImageView)
        contentStack.addArrangedSubview(titleLabel)

        cardView.addSubview(contentStack)
        contentView.addSubview(cardView)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),

            contentStack.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),

            iconImageView.widthAnchor.constraint(equalToConstant: 16),
            iconImageView.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(isMobile: Bool) {
        titleLabel.text = isMobile ? "添加自定义移动版标识" : "添加自定义电脑版标识"
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        UIView.animate(withDuration: 0.15) {
            self.cardView.alpha = highlighted ? 0.7 : 1.0
        }
    }
}
