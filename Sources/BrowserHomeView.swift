import UIKit

struct HomeShortcutItem: Codable, Equatable {
    var id: String
    var title: String
    var urlString: String
    var customIconData: Data?

    init(id: String, title: String, urlString: String, customIconData: Data? = nil) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.customIconData = customIconData
    }
}

final class HomeShortcutStore {
    static let shared = HomeShortcutStore()
    private let key = "browser_home_shortcuts_v2"

    private let defaultItems: [HomeShortcutItem] = [
        HomeShortcutItem(id: "1", title: "百度", urlString: "https://www.baidu.com"),
        HomeShortcutItem(id: "2", title: "必应", urlString: "https://www.bing.com"),
        HomeShortcutItem(id: "3", title: "GitHub", urlString: "https://github.com"),
        HomeShortcutItem(id: "4", title: "哔哩哔哩", urlString: "https://www.bilibili.com"),
        HomeShortcutItem(id: "5", title: "知乎", urlString: "https://www.zhihu.com"),
        HomeShortcutItem(id: "6", title: "掘金", urlString: "https://juejin.cn"),
        HomeShortcutItem(id: "7", title: "维基百科", urlString: "https://zh.wikipedia.org"),
        HomeShortcutItem(id: "8", title: "V2EX", urlString: "https://www.v2ex.com")
    ]

    private init() {}

    func loadShortcuts() -> [HomeShortcutItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([HomeShortcutItem].self, from: data),
              !items.isEmpty else {
            return defaultItems
        }
        return items
    }

    func addShortcut(title: String, urlString: String, customIconData: Data? = nil) {
        var items = loadShortcuts()
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = cleanTitle.isEmpty ? (URL(string: urlString)?.host ?? urlString) : cleanTitle
        items.removeAll { $0.urlString == urlString }
        items.append(HomeShortcutItem(id: UUID().uuidString, title: resolvedTitle, urlString: urlString, customIconData: customIconData))
        saveShortcuts(items)
        if customIconData == nil, let url = URL(string: urlString), let host = url.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }
    }

    func updateShortcut(id: String, title: String, urlString: String, customIconData: Data? = nil) {
        var items = loadShortcuts()
        if let idx = items.firstIndex(where: { $0.id == id }) {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = cleanTitle.isEmpty ? (URL(string: urlString)?.host ?? urlString) : cleanTitle
            items[idx].title = resolvedTitle
            items[idx].urlString = urlString
            if let customIconData = customIconData {
                items[idx].customIconData = customIconData
            }
            saveShortcuts(items)
            if items[idx].customIconData == nil, let url = URL(string: urlString), let host = url.host {
                FaviconLoader.shared.preloadFavicon(for: host)
            }
        }
    }

    func updateShortcutIcon(id: String, customIconData: Data?) {
        var items = loadShortcuts()
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].customIconData = customIconData
            saveShortcuts(items)
        }
    }

    func deleteShortcut(id: String) {
        var items = loadShortcuts()
        items.removeAll { $0.id == id }
        saveShortcuts(items)
    }

    func saveAllShortcuts(_ items: [HomeShortcutItem]) {
        saveShortcuts(items)
    }

    private func saveShortcuts(_ items: [HomeShortcutItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension BrowserViewController {
    func configureFaviconObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFaviconUpdatedNotification(_:)),
            name: NSNotification.Name("FaviconUpdatedNotification"),
            object: nil
        )
    }

    @objc func handleFaviconUpdatedNotification(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.reloadHomeShortcuts()
        }
    }

    func configureHomeView() {
        homeScrollView.translatesAutoresizingMaskIntoConstraints = false
        homeScrollView.alwaysBounceVertical = true
        homeScrollView.showsVerticalScrollIndicator = false
        homeView.addSubview(homeScrollView)

        NSLayoutConstraint.activate([
            homeScrollView.topAnchor.constraint(equalTo: homeView.topAnchor),
            homeScrollView.leadingAnchor.constraint(equalTo: homeView.leadingAnchor),
            homeScrollView.trailingAnchor.constraint(equalTo: homeView.trailingAnchor),
            homeScrollView.bottomAnchor.constraint(equalTo: homeView.bottomAnchor)
        ])

        let contentContainer = UIView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        homeScrollView.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: homeScrollView.contentLayoutGuide.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: homeScrollView.contentLayoutGuide.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: homeScrollView.contentLayoutGuide.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: homeScrollView.contentLayoutGuide.bottomAnchor),
            contentContainer.widthAnchor.constraint(equalTo: homeScrollView.frameLayoutGuide.widthAnchor)
        ])

        homeSearchContainer.translatesAutoresizingMaskIntoConstraints = false
        homeSearchContainer.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 1.0) : UIColor.white
        }
        homeSearchContainer.layer.cornerRadius = 24
        homeSearchContainer.layer.cornerCurve = .continuous
        homeSearchContainer.layer.shadowColor = UIColor.black.cgColor
        homeSearchContainer.layer.shadowOpacity = 0.04
        homeSearchContainer.layer.shadowRadius = 8
        homeSearchContainer.layer.shadowOffset = CGSize(width: 0, height: 2)

        let searchMagnifier = UIImageView()
        searchMagnifier.translatesAutoresizingMaskIntoConstraints = false
        searchMagnifier.image = UIImage(
            systemName: "magnifyingglass",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        )
        searchMagnifier.tintColor = UIColor(red: 0.50, green: 0.50, blue: 0.53, alpha: 1.0)
        searchMagnifier.isUserInteractionEnabled = false

        homeSearchField.translatesAutoresizingMaskIntoConstraints = false
        homeSearchField.placeholder = "搜索或输入网址"
        homeSearchField.font = .systemFont(ofSize: 15, weight: .regular)
        homeSearchField.textColor = .label
        homeSearchField.delegate = self
        homeSearchField.keyboardType = .webSearch
        homeSearchField.returnKeyType = .go
        homeSearchField.autocapitalizationType = .none
        homeSearchField.autocorrectionType = .no
        homeSearchField.clearButtonMode = .whileEditing

        homeSearchContainer.addSubview(searchMagnifier)
        homeSearchContainer.addSubview(homeSearchField)

        NSLayoutConstraint.activate([
            homeSearchContainer.heightAnchor.constraint(equalToConstant: 48),

            searchMagnifier.leadingAnchor.constraint(equalTo: homeSearchContainer.leadingAnchor, constant: 16),
            searchMagnifier.centerYAnchor.constraint(equalTo: homeSearchContainer.centerYAnchor),
            searchMagnifier.widthAnchor.constraint(equalToConstant: 18),
            searchMagnifier.heightAnchor.constraint(equalToConstant: 18),

            homeSearchField.leadingAnchor.constraint(equalTo: searchMagnifier.trailingAnchor, constant: 10),
            homeSearchField.trailingAnchor.constraint(equalTo: homeSearchContainer.trailingAnchor, constant: -16),
            homeSearchField.topAnchor.constraint(equalTo: homeSearchContainer.topAnchor),
            homeSearchField.bottomAnchor.constraint(equalTo: homeSearchContainer.bottomAnchor)
        ])

        let shortcutsHeader = UILabel()
        shortcutsHeader.translatesAutoresizingMaskIntoConstraints = false
        shortcutsHeader.text = "常用站点"
        shortcutsHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        shortcutsHeader.textColor = UIColor(red: 0.48, green: 0.48, blue: 0.51, alpha: 1.0)

        shortcutsStack.translatesAutoresizingMaskIntoConstraints = false
        shortcutsStack.axis = .vertical
        shortcutsStack.spacing = 14

        contentContainer.addSubview(homeSearchContainer)
        contentContainer.addSubview(shortcutsHeader)
        contentContainer.addSubview(shortcutsStack)

        NSLayoutConstraint.activate([
            homeSearchContainer.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 50),
            homeSearchContainer.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 20),
            homeSearchContainer.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -20),

            shortcutsHeader.topAnchor.constraint(equalTo: homeSearchContainer.bottomAnchor, constant: 32),
            shortcutsHeader.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 24),

            shortcutsStack.topAnchor.constraint(equalTo: shortcutsHeader.bottomAnchor, constant: 14),
            shortcutsStack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 16),
            shortcutsStack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -16),
            shortcutsStack.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -40)
        ])

        reloadHomeShortcuts()
    }

    func reloadHomeShortcuts() {
        for sub in shortcutsStack.arrangedSubviews {
            shortcutsStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        let shortcuts = HomeShortcutStore.shared.loadShortcuts()
        let itemsPerRow = 4
        var currentRow: UIStackView?

        for (idx, item) in shortcuts.enumerated() {
            if idx % itemsPerRow == 0 {
                let row = UIStackView()
                row.axis = .horizontal
                row.distribution = .fillEqually
                row.spacing = 10
                shortcutsStack.addArrangedSubview(row)
                currentRow = row
            }
            let btn = createShortcutButton(shortcut: item, index: idx)
            currentRow?.addArrangedSubview(btn)
        }

        if let lastRow = currentRow {
            let remainder = shortcuts.count % itemsPerRow
            if remainder != 0 {
                let fillersNeeded = itemsPerRow - remainder
                for _ in 0..<fillersNeeded {
                    let filler = UIView()
                    filler.translatesAutoresizingMaskIntoConstraints = false
                    lastRow.addArrangedSubview(filler)
                }
            }
        }
    }

    func createShortcutButton(shortcut: HomeShortcutItem, index: Int) -> TouchButton {
        let button = TouchButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tag = index
        button.addTarget(self, action: #selector(handleShortcutTap(_:)), for: .touchUpInside)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleShortcutLongPress(_:)))
        button.addGestureRecognizer(longPress)

        let iconContainer = UIView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 1.0) : UIColor.white
        }
        iconContainer.layer.cornerRadius = 16
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.layer.shadowColor = UIColor.black.cgColor
        iconContainer.layer.shadowOpacity = 0.04
        iconContainer.layer.shadowRadius = 5
        iconContainer.layer.shadowOffset = CGSize(width: 0, height: 2)
        iconContainer.isUserInteractionEnabled = false

        let iconImageView = UIImageView()
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.layer.cornerRadius = 6
        iconImageView.clipsToBounds = true
        iconImageView.isUserInteractionEnabled = false

        if let customData = shortcut.customIconData, let customImg = UIImage(data: customData) {
            iconImageView.image = customImg
        } else if let url = URL(string: shortcut.urlString), let host = url.host {
            if let cached = FaviconLoader.shared.cachedFavicon(for: host) {
                iconImageView.image = cached
            } else {
                iconImageView.image = UIImage(
                    systemName: "globe",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
                )
                iconImageView.tintColor = .systemBlue
                FaviconLoader.shared.loadFavicon(for: host) { [weak iconImageView] img in
                    if let img = img {
                        DispatchQueue.main.async {
                            iconImageView?.image = img
                        }
                    }
                }
            }
        } else {
            iconImageView.image = UIImage(systemName: "globe")
            iconImageView.tintColor = .systemBlue
        }
        iconContainer.addSubview(iconImageView)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = shortcut.title
        label.font = .systemFont(ofSize: 11.5, weight: .regular)
        label.textColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.88, alpha: 1.0) : UIColor(red: 0.28, green: 0.28, blue: 0.31, alpha: 1.0)
        }
        label.textAlignment = .center
        label.isUserInteractionEnabled = false

        button.addSubview(iconContainer)
        button.addSubview(label)

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 78),

            iconContainer.topAnchor.constraint(equalTo: button.topAnchor),
            iconContainer.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 52),
            iconContainer.heightAnchor.constraint(equalToConstant: 52),

            iconImageView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 32),
            iconImageView.heightAnchor.constraint(equalToConstant: 32),

            label.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            label.bottomAnchor.constraint(lessThanOrEqualTo: button.bottomAnchor)
        ])

        return button
    }

    @objc func handleShortcutTap(_ sender: UIButton) {
        let shortcuts = HomeShortcutStore.shared.loadShortcuts()
        guard shortcuts.indices.contains(sender.tag),
              let url = URL(string: shortcuts[sender.tag].urlString) else { return }
        load(url: url)
    }

    @objc func handleShortcutLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let btn = gesture.view as? UIButton else { return }
        let shortcuts = HomeShortcutStore.shared.loadShortcuts()
        guard shortcuts.indices.contains(btn.tag) else { return }
        let item = shortcuts[btn.tag]

        let alert = UIAlertController(title: "管理站点", message: item.title, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "编辑站点名称与网址", style: .default) { [weak self] _ in
            self?.showEditShortcutAlert(item: item)
        })

        alert.addAction(UIAlertAction(title: "自定义上传图片Logo", style: .default) { [weak self] _ in
            self?.promptChooseCustomIcon(for: item.id)
        })

        if item.customIconData != nil {
            alert.addAction(UIAlertAction(title: "恢复默认网页Logo", style: .default) { [weak self] _ in
                HomeShortcutStore.shared.updateShortcutIcon(id: item.id, customIconData: nil)
                self?.reloadHomeShortcuts()
                self?.showToastNotice("已恢复默认图标")
            })
        }

        alert.addAction(UIAlertAction(title: "删除该快捷方式", style: .destructive) { [weak self] _ in
            HomeShortcutStore.shared.deleteShortcut(id: item.id)
            self?.reloadHomeShortcuts()
            self?.showToastNotice("已从主页移除")
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    func promptChooseCustomIcon(for shortcutId: String) {
        self.editingShortcutIdForCustomIcon = shortcutId
        let picker = UIImagePickerController()
        picker.delegate = self
        picker.sourceType = .photoLibrary
        picker.allowsEditing = true
        present(picker, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        picker.dismiss(animated: true)
        guard let shortcutId = editingShortcutIdForCustomIcon else { return }
        editingShortcutIdForCustomIcon = nil

        let selectedImage = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
        guard let image = selectedImage else { return }

        let targetSize = CGSize(width: 160, height: 160)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        guard let iconData = resizedImage.pngData() ?? resizedImage.jpegData(compressionQuality: 0.85) else {
            return
        }

        HomeShortcutStore.shared.updateShortcutIcon(id: shortcutId, customIconData: iconData)
        reloadHomeShortcuts()
        showToastNotice("Logo 图标已更新")
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        editingShortcutIdForCustomIcon = nil
        picker.dismiss(animated: true)
    }

    func showEditShortcutAlert(item: HomeShortcutItem) {
        let alert = UIAlertController(title: "编辑常用站点", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "网站名称"
            tf.text = item.title
            tf.clearButtonMode = .whileEditing
        }
        alert.addTextField { tf in
            tf.placeholder = "网站地址"
            tf.text = item.urlString
            tf.keyboardType = .URL
            tf.clearButtonMode = .whileEditing
        }

        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?[0].text,
                  let urlStr = alert?.textFields?[1].text,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !urlStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            HomeShortcutStore.shared.updateShortcut(id: item.id, title: name, urlString: urlStr)
            self?.reloadHomeShortcuts()
            self?.showToastNotice("已更新常用站点")
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}
