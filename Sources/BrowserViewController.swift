import UIKit
import WebKit

// MARK: - 主浏览器控制器
final class BrowserViewController: UIViewController, UITextFieldDelegate, TabItemDelegate {

    // UI 组件
    private let webContainerView = UIView()
    private let bottomBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let bottomToolbar = UIStackView()

    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let tabsButton = UIButton(type: .system)
    private let pluginButton = UIButton(type: .system)
    private let menuButton = UIButton(type: .system)

    // 底部胶囊地址栏
    private let addressContentView = UIView()
    private let lockButton = UIButton(type: .system)
    private let addressField = UITextField()
    private let expandButton = UIButton(type: .system)
    private let rightActionBtn = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .default)

    private weak var currentToastView: UIView?
    private var calloutMenu: AddressCalloutMenuView?

    // 主页视图
    private let homeContainerView = UIView()
    private let homeSearchCard = UIView()
    private let homeSearchField = UITextField()
    private let shortcutsLabel = UILabel()
    private let shortcutsContainer = UIStackView()

    // 标签页管理
    private var tabs: [TabItem] = []
    private var activeTabIndex: Int = 0

    private var activeTab: TabItem? {
        guard !tabs.isEmpty, activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    private var isAdBlockEnabled: Bool = true
    private var isNightModeEnabled: Bool = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        setupLayout()
        setupBottomBar()
        setupAddressBarInteractions()
        setupHomeView()
        setupNotifications()

        createNewTab(url: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    private func setupLayout() {
        webContainerView.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        homeContainerView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(webContainerView)
        view.addSubview(homeContainerView)
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            webContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            webContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainerView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            homeContainerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            homeContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            homeContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            homeContainerView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 88)
        ])
    }

    private func setupBottomBar() {
        let barContent = bottomBar.contentView

        addressContentView.translatesAutoresizingMaskIntoConstraints = false
        addressContentView.backgroundColor = UIColor(white: 0.95, alpha: 0.85)
        addressContentView.layer.cornerRadius = 21
        addressContentView.layer.cornerCurve = .continuous
        addressContentView.clipsToBounds = true
        barContent.addSubview(addressContentView)

        lockButton.translatesAutoresizingMaskIntoConstraints = false
        lockButton.setImage(UIImage(systemName: "lock.fill"), for: .normal)
        lockButton.tintColor = UIColor(red: 0.28, green: 0.28, blue: 0.32, alpha: 1.0)
        lockButton.addTarget(self, action: #selector(handleLockTapped), for: .touchUpInside)
        addressContentView.addSubview(lockButton)

        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.font = .systemFont(ofSize: 14.5, weight: .regular)
        addressField.textColor = .label
        addressField.placeholder = "搜索或输入网址"
        addressField.autocorrectionType = .no
        addressField.autocapitalizationType = .none
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.clearButtonMode = .never
        addressField.delegate = self
        addressContentView.addSubview(addressField)

        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right"), for: .normal)
        expandButton.tintColor = UIColor(red: 0.28, green: 0.28, blue: 0.32, alpha: 1.0)
        expandButton.addTarget(self, action: #selector(handleExpandURLEditor), for: .touchUpInside)
        addressContentView.addSubview(expandButton)

        rightActionBtn.translatesAutoresizingMaskIntoConstraints = false
        rightActionBtn.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        rightActionBtn.tintColor = UIColor(red: 0.28, green: 0.28, blue: 0.32, alpha: 1.0)
        rightActionBtn.addTarget(self, action: #selector(handleRightActionBtn), for: .touchUpInside)
        addressContentView.addSubview(rightActionBtn)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = UIColor(red: 0.08, green: 0.42, blue: 0.92, alpha: 1.0)
        progressView.trackTintColor = .clear
        progressView.alpha = 0
        addressContentView.addSubview(progressView)

        bottomToolbar.translatesAutoresizingMaskIntoConstraints = false
        bottomToolbar.axis = .horizontal
        bottomToolbar.distribution = .equalSpacing
        bottomToolbar.alignment = .center
        barContent.addSubview(bottomToolbar)

        let tintColor = UIColor(red: 0.28, green: 0.28, blue: 0.32, alpha: 1.0)
        let cfg = UIImage.SymbolConfiguration(pointSize: 16.5, weight: .medium)
        let smallCfg = UIImage.SymbolConfiguration(pointSize: 15.0, weight: .medium)

        backButton.setImage(UIImage(systemName: "chevron.left", withConfiguration: cfg), for: .normal)
        forwardButton.setImage(UIImage(systemName: "chevron.right", withConfiguration: cfg), for: .normal)
        tabsButton.setImage(UIImage(systemName: "square.on.square", withConfiguration: smallCfg), for: .normal)
        pluginButton.setImage(UIImage(systemName: "puzzlepiece.extension", withConfiguration: smallCfg), for: .normal)
        menuButton.setImage(UIImage(systemName: "line.3.horizontal", withConfiguration: cfg), for: .normal)

        [backButton, forwardButton, tabsButton, pluginButton, menuButton].forEach { btn in
            btn.tintColor = tintColor
            btn.translatesAutoresizingMaskIntoConstraints = false
            bottomToolbar.addArrangedSubview(btn)
        }

        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        forwardButton.addTarget(self, action: #selector(handleForward), for: .touchUpInside)
        tabsButton.addTarget(self, action: #selector(handleTabs), for: .touchUpInside)
        pluginButton.addTarget(self, action: #selector(handlePlugin), for: .touchUpInside)
        menuButton.addTarget(self, action: #selector(handleMenu), for: .touchUpInside)

        NSLayoutConstraint.activate([
            addressContentView.topAnchor.constraint(equalTo: barContent.topAnchor, constant: 6),
            addressContentView.leadingAnchor.constraint(equalTo: barContent.leadingAnchor, constant: 14),
            addressContentView.trailingAnchor.constraint(equalTo: barContent.trailingAnchor, constant: -14),
            addressContentView.heightAnchor.constraint(equalToConstant: 42),

            lockButton.leadingAnchor.constraint(equalTo: addressContentView.leadingAnchor, constant: 10),
            lockButton.centerYAnchor.constraint(equalTo: addressContentView.centerYAnchor),
            lockButton.widthAnchor.constraint(equalToConstant: 24),
            lockButton.heightAnchor.constraint(equalToConstant: 24),

            addressField.leadingAnchor.constraint(equalTo: lockButton.trailingAnchor, constant: 8),
            addressField.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor, constant: -6),
            addressField.centerYAnchor.constraint(equalTo: addressContentView.centerYAnchor),
            addressField.heightAnchor.constraint(equalToConstant: 36),

            expandButton.trailingAnchor.constraint(equalTo: rightActionBtn.leadingAnchor, constant: -6),
            expandButton.centerYAnchor.constraint(equalTo: addressContentView.centerYAnchor),
            expandButton.widthAnchor.constraint(equalToConstant: 24),
            expandButton.heightAnchor.constraint(equalToConstant: 24),

            rightActionBtn.trailingAnchor.constraint(equalTo: addressContentView.trailingAnchor, constant: -10),
            rightActionBtn.centerYAnchor.constraint(equalTo: addressContentView.centerYAnchor),
            rightActionBtn.widthAnchor.constraint(equalToConstant: 24),
            rightActionBtn.heightAnchor.constraint(equalToConstant: 24),

            progressView.leadingAnchor.constraint(equalTo: addressContentView.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: addressContentView.trailingAnchor),
            progressView.bottomAnchor.constraint(equalTo: addressContentView.bottomAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2.5),

            bottomToolbar.topAnchor.constraint(equalTo: addressContentView.bottomAnchor, constant: 6),
            bottomToolbar.leadingAnchor.constraint(equalTo: barContent.leadingAnchor, constant: 24),
            bottomToolbar.trailingAnchor.constraint(equalTo: barContent.trailingAnchor, constant: -24),
            bottomToolbar.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func setupAddressBarInteractions() {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleAddressLongPress(_:)))
        addressContentView.addGestureRecognizer(longPress)
    }

    private func setupHomeView() {
        homeSearchCard.translatesAutoresizingMaskIntoConstraints = false
        homeSearchCard.backgroundColor = .secondarySystemGroupedBackground
        homeSearchCard.layer.cornerRadius = 24
        homeSearchCard.layer.cornerCurve = .continuous
        homeSearchCard.layer.shadowColor = UIColor.black.cgColor
        homeSearchCard.layer.shadowOpacity = 0.05
        homeSearchCard.layer.shadowOffset = CGSize(width: 0, height: 4)
        homeSearchCard.layer.shadowRadius = 12
        homeContainerView.addSubview(homeSearchCard)

        let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        searchIcon.tintColor = .tertiaryLabel
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        homeSearchCard.addSubview(searchIcon)

        homeSearchField.translatesAutoresizingMaskIntoConstraints = false
        homeSearchField.font = .systemFont(ofSize: 16, weight: .regular)
        homeSearchField.placeholder = "搜索或输入网址"
        homeSearchField.autocorrectionType = .no
        homeSearchField.autocapitalizationType = .none
        homeSearchField.returnKeyType = .go
        homeSearchField.delegate = self
        homeSearchCard.addSubview(homeSearchField)

        shortcutsLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutsLabel.text = "常用站点"
        shortcutsLabel.font = .systemFont(ofSize: 14, weight: .medium)
        shortcutsLabel.textColor = .secondaryLabel
        homeContainerView.addSubview(shortcutsLabel)

        shortcutsContainer.translatesAutoresizingMaskIntoConstraints = false
        shortcutsContainer.axis = .vertical
        shortcutsContainer.spacing = 16
        shortcutsContainer.alignment = .fill
        shortcutsContainer.distribution = .fillEqually
        homeContainerView.addSubview(shortcutsContainer)

        NSLayoutConstraint.activate([
            homeSearchCard.topAnchor.constraint(equalTo: homeContainerView.topAnchor, constant: 60),
            homeSearchCard.leadingAnchor.constraint(equalTo: homeContainerView.leadingAnchor, constant: 20),
            homeSearchCard.trailingAnchor.constraint(equalTo: homeContainerView.trailingAnchor, constant: -20),
            homeSearchCard.heightAnchor.constraint(equalToConstant: 52),

            searchIcon.leadingAnchor.constraint(equalTo: homeSearchCard.leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: homeSearchCard.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 18),
            searchIcon.heightAnchor.constraint(equalToConstant: 18),

            homeSearchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 12),
            homeSearchField.trailingAnchor.constraint(equalTo: homeSearchCard.trailingAnchor, constant: -16),
            homeSearchField.centerYAnchor.constraint(equalTo: homeSearchCard.centerYAnchor),
            homeSearchField.heightAnchor.constraint(equalToConstant: 44),

            shortcutsLabel.topAnchor.constraint(equalTo: homeSearchCard.bottomAnchor, constant: 36),
            shortcutsLabel.leadingAnchor.constraint(equalTo: homeContainerView.leadingAnchor, constant: 24),

            shortcutsContainer.topAnchor.constraint(equalTo: shortcutsLabel.bottomAnchor, constant: 16),
            shortcutsContainer.leadingAnchor.constraint(equalTo: homeContainerView.leadingAnchor, constant: 20),
            shortcutsContainer.trailingAnchor.constraint(equalTo: homeContainerView.trailingAnchor, constant: -20)
        ])

        renderHomeShortcuts()
    }

    private func renderHomeShortcuts() {
        shortcutsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = HomeShortcutStore.shared.shortcuts

        let row1 = UIStackView()
        row1.axis = .horizontal
        row1.distribution = .fillEqually
        row1.alignment = .center

        let row2 = UIStackView()
        row2.axis = .horizontal
        row2.distribution = .fillEqually
        row2.alignment = .center

        shortcutsContainer.addArrangedSubview(row1)
        shortcutsContainer.addArrangedSubview(row2)

        for (index, item) in items.prefix(8).enumerated() {
            let cell = createShortcutCell(item: item)
            if index < 4 {
                row1.addArrangedSubview(cell)
            } else {
                row2.addArrangedSubview(cell)
            }
        }
    }

    private func createShortcutCell(item: HomeShortcutItem) -> UIView {
        let container = UIView()
        let iconWrap = UIView()
        iconWrap.translatesAutoresizingMaskIntoConstraints = false
        iconWrap.layer.cornerRadius = 14
        iconWrap.layer.cornerCurve = .continuous
        iconWrap.backgroundColor = .secondarySystemGroupedBackground
        iconWrap.layer.shadowColor = UIColor.black.cgColor
        iconWrap.layer.shadowOpacity = 0.04
        iconWrap.layer.shadowOffset = CGSize(width: 0, height: 2)
        iconWrap.layer.shadowRadius = 4
        container.addSubview(iconWrap)

        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .scaleAspectFit
        iv.layer.cornerRadius = 8
        iv.clipsToBounds = true
        iconWrap.addSubview(iv)

        let lbl = UILabel()
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.text = item.title
        lbl.font = .systemFont(ofSize: 12, weight: .regular)
        lbl.textColor = .label
        lbl.textAlignment = .center
        container.addSubview(lbl)

        NSLayoutConstraint.activate([
            iconWrap.topAnchor.constraint(equalTo: container.topAnchor),
            iconWrap.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconWrap.widthAnchor.constraint(equalToConstant: 52),
            iconWrap.heightAnchor.constraint(equalToConstant: 52),

            iv.centerXAnchor.constraint(equalTo: iconWrap.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: iconWrap.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 28),
            iv.heightAnchor.constraint(equalToConstant: 28),

            lbl.topAnchor.constraint(equalTo: iconWrap.bottomAnchor, constant: 6),
            lbl.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            lbl.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            lbl.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        if let host = URL(string: item.url)?.host {
            FaviconLoader.shared.loadFavicon(for: host) { [weak iv] img in
                iv?.image = img ?? UIImage(systemName: "globe")
            }
        } else {
            iv.image = UIImage(systemName: "globe")
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleShortcutTap(_:)))
        container.addGestureRecognizer(tap)
        container.isUserInteractionEnabled = true
        objc_setAssociatedObject(container, "shortcut_item", item, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleShortcutLongPress(_:)))
        container.addGestureRecognizer(longPress)

        return container
    }

    @objc private func handleShortcutTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view,
              let item = objc_getAssociatedObject(view, "shortcut_item") as? HomeShortcutItem else { return }
        loadInputText(item.url)
    }

    @objc private func handleShortcutLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let view = gesture.view,
              let item = objc_getAssociatedObject(view, "shortcut_item") as? HomeShortcutItem else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let alert = UIAlertController(title: item.title, message: item.url, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "编辑快捷方式", style: .default, handler: { [weak self] _ in
            self?.promptEditShortcut(item: item)
        }))
        alert.addAction(UIAlertAction(title: "删除该快捷方式", style: .destructive, handler: { [weak self] _ in
            HomeShortcutStore.shared.deleteShortcut(id: item.id)
            self?.renderHomeShortcuts()
            self?.showToastNotice("已删除快捷方式")
        }))
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func promptEditShortcut(item: HomeShortcutItem) {
        let alert = UIAlertController(title: "编辑常用站点", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "网站名称"
            tf.text = item.title
        }
        alert.addTextField { tf in
            tf.placeholder = "网址链接"
            tf.text = item.url
            tf.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "保存", style: .default, handler: { [weak self] _ in
            let newTitle = alert.textFields?[0].text ?? item.title
            let newUrl = alert.textFields?[1].text ?? item.url
            HomeShortcutStore.shared.updateShortcut(id: item.id, title: newTitle, url: newUrl)
            self?.renderHomeShortcuts()
            self?.showToastNotice("快捷方式已更新")
        }))
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func handleExpandURLEditor() {
        let currentText = addressField.text ?? ""
        let editorVC = ExpandedURLEditorViewController(initialText: currentText) { [weak self] updatedText in
            guard let self = self else { return }
            self.addressField.text = updatedText
            self.loadInputText(updatedText)
        }
        present(editorVC, animated: true)
    }

    @objc private func handleAddressLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        view.endEditing(true)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        calloutMenu?.removeFromSuperview()

        let currentText = addressField.text ?? ""
        let menu = AddressCalloutMenuView(
            onCopy: { [weak self] in
                guard let self = self else { return }
                UIPasteboard.general.string = currentText
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            },
            onPaste: { [weak self] in
                guard let self = self else { return }
                if let str = UIPasteboard.general.string {
                    self.addressField.text = str
                }
            },
            onEdit: { [weak self] in
                guard let self = self else { return }
                self.addressField.becomeFirstResponder()
                self.addressField.selectAll(nil)
            },
            onPasteAndGo: { [weak self] in
                guard let self = self else { return }
                if let str = UIPasteboard.general.string {
                    self.addressField.text = str
                    self.loadInputText(str)
                }
            }
        )

        menu.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(menu)
        self.calloutMenu = menu

        NSLayoutConstraint.activate([
            menu.centerXAnchor.constraint(equalTo: addressContentView.centerXAnchor),
            menu.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -8)
        ])

        menu.animateIn()
    }

    func createNewTab(url: URL? = nil) {
        let tab = TabItem()
        tab.delegate = self
        tabs.append(tab)
        activeTabIndex = tabs.count - 1

        webContainerView.subviews.forEach { $0.removeFromSuperview() }
        tab.webView.translatesAutoresizingMaskIntoConstraints = false
        webContainerView.addSubview(tab.webView)

        NSLayoutConstraint.activate([
            tab.webView.topAnchor.constraint(equalTo: webContainerView.topAnchor),
            tab.webView.leadingAnchor.constraint(equalTo: webContainerView.leadingAnchor),
            tab.webView.trailingAnchor.constraint(equalTo: webContainerView.trailingAnchor),
            tab.webView.bottomAnchor.constraint(equalTo: webContainerView.bottomAnchor)
        ])

        if let url = url {
            homeContainerView.isHidden = true
            tab.load(url: url)
        } else {
            homeContainerView.isHidden = false
            addressField.text = ""
        }
        updateAddressRightButtons()
    }

    func loadInputText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        homeContainerView.isHidden = true
        SearchHistoryStore.shared.addHistory(trimmed)

        let targetURL: URL
        if trimmed.lowercased().starts(with: "http://") || trimmed.lowercased().starts(with: "https://") {
            targetURL = URL(string: trimmed) ?? URL(string: "https://www.google.com/search?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            targetURL = URL(string: "https://\(trimmed)")!
        } else {
            targetURL = URL(string: "https://www.google.com/search?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!
        }

        addressField.text = targetURL.absoluteString
        activeTab?.load(url: targetURL)
        updateAddressRightButtons()
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        calloutMenu?.dismissAnimated()
        rightActionBtn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            textField.selectAll(nil)
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        updateAddressRightButtons()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        loadInputText(textField.text ?? "")
        return true
    }

    private func updateAddressRightButtons() {
        guard let tab = activeTab else {
            rightActionBtn.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
            return
        }
        if tab.isLoading {
            rightActionBtn.setImage(UIImage(systemName: "xmark"), for: .normal)
        } else {
            rightActionBtn.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        }
    }

    @objc private func handleRightActionBtn() {
        if addressField.isFirstResponder {
            addressField.text = ""
            return
        }
        guard let tab = activeTab else { return }
        if tab.isLoading {
            tab.stopLoading()
        } else {
            tab.reload()
        }
    }

    @objc private func handleLockTapped() {
        let host = activeTab?.currentURL?.host ?? "当前网站"
        let alert = UIAlertController(title: "网站设置与安全", message: host, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "查看网站存储数据", style: .default, handler: { [weak self] _ in
            let vc = WebsiteDataManagerViewController()
            self?.present(UINavigationController(rootViewController: vc), animated: true)
        }))
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - TabItemDelegate 回调
    func tabDidUpdate(_ tab: TabItem) {
        guard tab == activeTab else { return }
        let progress = tab.estimatedProgress
        if tab.isLoading {
            progressView.alpha = 1.0
            progressView.setProgress(Float(max(progress, 0.1)), animated: true)
        } else {
            UIView.animate(withDuration: 0.2, animations: {
                self.progressView.alpha = 0
            }) { _ in
                self.progressView.setProgress(0, animated: false)
            }
        }
        updateAddressRightButtons()
        if let url = tab.currentURL {
            addressField.text = url.absoluteString
            BrowserHistoryStore.shared.record(title: tab.title, url: url.absoluteString)
        }
    }

    func tabDidFail(_ tab: TabItem, error: Error) {
        guard tab == activeTab else { return }
        updateAddressRightButtons()
    }

    func tabProcessTerminated(_ tab: TabItem) {
        guard tab == activeTab else { return }
        tab.reload()
    }

    func tabRequestGoBack(_ tab: TabItem) {
        handleBack()
    }

    func tabRequestNewTab(_ tab: TabItem, url: URL?) {
        createNewTab(url: url)
    }

    // 底部按键
    @objc private func handleBack() {
        activeTab?.goBack()
    }

    @objc private func handleForward() {
        activeTab?.goForward()
    }

    @objc private func handleTabs() {
        let gridVC = TabGridViewController(tabs: tabs, activeIndex: activeTabIndex)
        gridVC.onSelectTab = { [weak self] idx in
            self?.switchToTab(at: idx)
        }
        gridVC.onCloseTab = { [weak self] idx in
            self?.closeTab(at: idx)
        }
        gridVC.onNewTab = { [weak self] in
            self?.createNewTab(url: nil)
        }
        present(gridVC, animated: true)
    }

    private func switchToTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeTabIndex = index
        let tab = tabs[index]

        webContainerView.subviews.forEach { $0.removeFromSuperview() }
        tab.webView.translatesAutoresizingMaskIntoConstraints = false
        webContainerView.addSubview(tab.webView)

        NSLayoutConstraint.activate([
            tab.webView.topAnchor.constraint(equalTo: webContainerView.topAnchor),
            tab.webView.leadingAnchor.constraint(equalTo: webContainerView.leadingAnchor),
            tab.webView.trailingAnchor.constraint(equalTo: webContainerView.trailingAnchor),
            tab.webView.bottomAnchor.constraint(equalTo: webContainerView.bottomAnchor)
        ])

        if let url = tab.currentURL {
            homeContainerView.isHidden = true
            addressField.text = url.absoluteString
        } else {
            homeContainerView.isHidden = false
            addressField.text = ""
        }
        updateAddressRightButtons()
    }

    private func closeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            createNewTab(url: nil)
        } else {
            let next = min(index, tabs.count - 1)
            switchToTab(at: next)
        }
    }

    @objc private func handlePlugin() {
        let vc = CustomBottomSheetViewController(title: nil, isGrid: false)
        let items = [
            CustomBottomSheetItem(iconName: "exclamationmark.triangle", title: "未匹配到脚本", dismissOnTap: false, action: {}),
            CustomBottomSheetItem(iconName: "arrow.down.circle", title: "搜索适合当前网站的脚本", action: { [weak self] in
                guard let host = self?.activeTab?.currentURL?.host else { return }
                self?.loadInputText("https://greasyfork.org/zh-CN/scripts/by-site/\(host)")
            }),
            CustomBottomSheetItem(iconName: "gearshape", title: "用户脚本管理", action: { [weak self] in
                let manager = UserScriptManagerViewController()
                self?.present(UINavigationController(rootViewController: manager), animated: true)
            })
        ]
        vc.setItems(items)
        present(vc, animated: true)
    }

    @objc private func handleMenu() {
        let vc = CustomBottomSheetViewController(title: nil, isGrid: true)
        let isDesktop = UserAgentStore.shared.isCurrentDesktop

        let page1: [CustomBottomSheetItem] = [
            CustomBottomSheetItem(iconName: "star", title: "书签/历史", action: { [weak self] in
                let histVC = BrowserHistoryViewController()
                histVC.onSelectURL = { url in
                    self?.loadInputText(url)
                }
                self?.present(UINavigationController(rootViewController: histVC), animated: true)
            }),
            CustomBottomSheetItem(
                iconName: "display",
                title: "电脑版",
                hasSwitch: true,
                isSwitchOn: isDesktop,
                dismissOnTap: false,
                action: { [weak self] in
                    let targetUA = isDesktop ? "builtin_mobile_safari" : "builtin_desktop_safari"
                    UserAgentStore.shared.setActive(id: targetUA)
                    self?.activeTab?.reload()
                },
                longPressAction: { [weak self] in
                    self?.openUserAgentSettings()
                }
            ),
            CustomBottomSheetItem(iconName: "folder.badge.gearshape", title: "下载管理", action: { [weak self] in
                let dlVC = DownloadManagerViewController()
                self?.present(UINavigationController(rootViewController: dlVC), animated: true)
            }),
            CustomBottomSheetItem(
                iconName: "moon.stars",
                title: "夜间模式",
                hasSwitch: true,
                isSwitchOn: self.isNightModeEnabled,
                dismissOnTap: false,
                action: { [weak self] in
                    guard let self = self else { return }
                    self.isNightModeEnabled.toggle()
                    self.applyNightMode()
                }
            ),
            CustomBottomSheetItem(customImage: self.createAddBookmarkVectorIcon(), title: "添加", action: { [weak self] in
                self?.promptAddAction()
            }),
            CustomBottomSheetItem(iconName: "arrow.up.left.and.arrow.down.right", title: "全屏浏览", action: { [weak self] in
                self?.toggleFullScreen()
            }),
            CustomBottomSheetItem(
                iconName: "shield.lefthalf.filled",
                title: "广告过滤",
                hasSwitch: true,
                isSwitchOn: self.isAdBlockEnabled,
                dismissOnTap: false,
                action: { [weak self] in
                    guard let self = self else { return }
                    self.isAdBlockEnabled.toggle()
                    self.activeTab?.setAdBlockEnabled(self.isAdBlockEnabled)
                },
                longPressAction: { [weak self] in
                    let adVC = AdBlockManagerViewController()
                    self?.present(UINavigationController(rootViewController: adVC), animated: true)
                }
            ),
            CustomBottomSheetItem(iconName: "trash", title: "清除数据", action: { [weak self] in
                let cleanVC = CleanDataSelectionViewController()
                self?.present(UINavigationController(rootViewController: cleanVC), animated: true)
            })
        ]

        let page2: [CustomBottomSheetItem] = [
            CustomBottomSheetItem(iconName: "puzzlepiece.extension", title: "扩展脚本", action: { [weak self] in
                let manager = UserScriptManagerViewController()
                self?.present(UINavigationController(rootViewController: manager), animated: true)
            }),
            CustomBottomSheetItem(iconName: "person.crop.rectangle", title: "标识设置", action: { [weak self] in
                self?.openUserAgentSettings()
            }),
            CustomBottomSheetItem(iconName: "magnifyingglass", title: "搜索引擎", action: { [weak self] in
                self?.showToastNotice("默认使用 Google 引擎")
            }),
            CustomBottomSheetItem(iconName: "doc.plaintext", title: "提取正文", action: { [weak self] in
                self?.extractPageText()
            })
        ]

        vc.setItems(page1 + page2)
        present(vc, animated: true)
    }

    private func promptAddAction() {
        guard let url = activeTab?.currentURL?.absoluteString, !url.isEmpty else {
            showToastNotice("当前无网页可添加")
            return
        }
        let title = activeTab?.title ?? "我的网页"

        let sheet = UIAlertController(title: "添加选项", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "添加到书签", style: .default, handler: { [weak self] _ in
            BookmarkStore.shared.addBookmark(title: title, url: url, parentId: nil)
            self?.showToastNotice("已添加到书签")
        }))
        sheet.addAction(UIAlertAction(title: "添加到主页常用站点", style: .default, handler: { [weak self] _ in
            HomeShortcutStore.shared.addShortcut(title: title, url: url)
            self?.renderHomeShortcuts()
            self?.showToastNotice("已添加到主页")
        }))
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }

    private func toggleFullScreen() {
        let isHidden = bottomBar.isHidden
        bottomBar.isHidden = !isHidden
    }

    private func applyNightMode() {
        let js = isNightModeEnabled ?
            "document.documentElement.style.filter = 'invert(0.9) hue-rotate(180deg)';" :
            "document.documentElement.style.filter = '';"
        activeTab?.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func extractPageText() {
        activeTab?.webView.evaluateJavaScript("document.body.innerText") { [weak self] res, _ in
            let text = (res as? String) ?? "提取失败"
            let alert = UIAlertController(title: "网页正文内容", message: nil, preferredStyle: .alert)
            alert.addTextField { tf in
                tf.text = text
            }
            alert.addAction(UIAlertAction(title: "复制", style: .default, handler: { _ in
                UIPasteboard.general.string = text
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }))
            alert.addAction(UIAlertAction(title: "关闭", style: .cancel))
            self?.present(alert, animated: true)
        }
    }

    private func openUserAgentSettings() {
        let vc = UserAgentManagerViewController()
        present(UINavigationController(rootViewController: vc), animated: true)
    }

    private func createAddBookmarkVectorIcon() -> UIImage {
        let sz = CGSize(width: 24, height: 24)
        let renderer = UIGraphicsImageRenderer(size: sz)
        return renderer.image { _ in
            let star = UIImage(systemName: "star")?.withTintColor(UIColor(red: 0.28, green: 0.28, blue: 0.32, alpha: 1.0))
            star?.draw(in: CGRect(x: 1, y: 1, width: 18, height: 18))
            let plus = UIImage(systemName: "plus.circle.fill")?.withTintColor(UIColor(red: 0.28, green: 0.28, blue: 0.32, alpha: 1.0))
            plus?.draw(in: CGRect(x: 12, y: 12, width: 12, height: 12))
        }
    }

    func showToastNotice(_ msg: String) {
        currentToastView?.layer.removeAllAnimations()
        currentToastView?.removeFromSuperview()

        let toast = UIView()
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.backgroundColor = .white
        toast.layer.cornerRadius = 20
        toast.layer.borderWidth = 0.5
        toast.layer.borderColor = UIColor(white: 0.88, alpha: 1.0).cgColor
        toast.layer.shadowColor = UIColor.black.cgColor
        toast.layer.shadowOpacity = 0.08
        toast.layer.shadowOffset = CGSize(width: 0, height: 4)
        toast.layer.shadowRadius = 10

        let lbl = UILabel()
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.text = msg
        lbl.font = .systemFont(ofSize: 14, weight: .medium)
        lbl.textColor = UIColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1.0)
        lbl.textAlignment = .center
        toast.addSubview(lbl)

        view.addSubview(toast)
        self.currentToastView = toast

        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -16),
            toast.heightAnchor.constraint(equalToConstant: 40),

            lbl.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 18),
            lbl.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -18),
            lbl.centerYAnchor.constraint(equalTo: toast.centerYAnchor)
        ])

        toast.alpha = 0
        toast.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)

        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: .curveEaseOut, animations: {
            toast.alpha = 1.0
            toast.transform = .identity
        }) { _ in
            UIView.animate(withDuration: 0.2, delay: 1.8, options: .curveEaseIn, animations: {
                toast.alpha = 0
                toast.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
            }) { _ in
                toast.removeFromSuperview()
            }
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleDownloadPrompt(_:)), name: NSNotification.Name("PromptDownloadConfirmationNotification"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDownloadStarted), name: NSNotification.Name("DownloadStartedNotification"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDownloadFinished), name: NSNotification.Name("DownloadFinishedNotification"), object: nil)
    }

    @objc private func handleDownloadPrompt(_ notif: Notification) {
        guard let url = notif.userInfo?["url"] as? URL else { return }
        let filename = notif.userInfo?["filename"] as? String ?? url.lastPathComponent

        let alert = UIAlertController(title: "是否下载该文件？", message: "\(filename)\n来源: \(url.host ?? "")", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "下载文件", style: .default, handler: { [weak self] _ in
            self?.activeTab?.startRealDownload(url: url, filename: filename)
        }))
        alert.addAction(UIAlertAction(title: "复制下载链接", style: .default, handler: { [weak self] _ in
            UIPasteboard.general.string = url.absoluteString
            self?.showToastNotice("已复制下载链接")
        }))
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func handleDownloadStarted() {
        showToastNotice("开始下载文件...")
    }

    @objc private func handleDownloadFinished() {
        showToastNotice("下载完成，已存入下载管理")
    }
}

// MARK: - 展开网址编辑器控制器
final class ExpandedURLEditorViewController: UIViewController, UITextViewDelegate {
    private let initialText: String
    private let onCommit: (String) -> Void
    private let textView = UITextView()

    init(initialText: String, onCommit: @escaping (String) -> Void) {
        self.initialText = initialText
        self.onCommit = onCommit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        if let sheet = sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
        }

        let nav = UINavigationBar()
        nav.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nav)

        let item = UINavigationItem(title: "编辑网址")
        item.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(handleCancel))
        item.rightBarButtonItem = UIBarButtonItem(title: "前往", style: .done, target: self, action: #selector(handleGo))
        nav.items = [item]

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .systemFont(ofSize: 15.5)
        textView.text = initialText
        textView.layer.cornerRadius = 14
        textView.clipsToBounds = true
        textView.delegate = self
        textView.keyboardType = .webSearch
        textView.returnKeyType = .go
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo: view.topAnchor),
            nav.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nav.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            textView.topAnchor.constraint(equalTo: nav.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
        textView.selectAll(nil)
    }

    @objc private func handleCancel() { dismiss(animated: true) }

    @objc private func handleGo() {
        let text = textView.text ?? ""
        dismiss(animated: true) { [weak self] in
            self?.onCommit(text)
        }
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" {
            handleGo()
            return false
        }
        return true
    }
}

// MARK: - 长按地址栏气泡菜单
final class AddressCalloutMenuView: UIView {
    private let onCopy: () -> Void
    private let onPaste: () -> Void
    private let onEdit: () -> Void
    private let onPasteAndGo: () -> Void

    init(onCopy: @escaping () -> Void, onPaste: @escaping () -> Void, onEdit: @escaping () -> Void, onPasteAndGo: @escaping () -> Void) {
        self.onCopy = onCopy
        self.onPaste = onPaste
        self.onEdit = onEdit
        self.onPasteAndGo = onPasteAndGo
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        backgroundColor = .clear

        let bubble = UIView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.backgroundColor = .white
        bubble.layer.cornerRadius = 14
        bubble.layer.shadowColor = UIColor.black.cgColor
        bubble.layer.shadowOpacity = 0.12
        bubble.layer.shadowOffset = CGSize(width: 0, height: 4)
        bubble.layer.shadowRadius = 12
        addSubview(bubble)

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillProportionally
        bubble.addSubview(stack)

        let b1 = makeBtn(title: "拷贝", action: #selector(actCopy))
        let b2 = makeBtn(title: "粘贴", action: #selector(actPaste))
        let b3 = makeBtn(title: "编辑", action: #selector(actEdit))
        let b4 = makeBtn(title: "粘贴并前往", action: #selector(actPasteAndGo))

        [b1, sep(), b2, sep(), b3, sep(), b4].forEach { stack.addArrangedSubview($0) }

        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.leadingAnchor.constraint(equalTo: leadingAnchor),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            bubble.heightAnchor.constraint(equalToConstant: 44),

            stack.topAnchor.constraint(equalTo: bubble.topAnchor),
            stack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor)
        ])
    }

    private func makeBtn(title: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.setTitleColor(UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0), for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 14.5)
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    private func sep() -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor(white: 0.88, alpha: 1.0)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        return v
    }

    func animateIn() {
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: .curveEaseOut, animations: {
            self.alpha = 1.0
            self.transform = .identity
        })
    }

    func dismissAnimated() {
        UIView.animate(withDuration: 0.15, animations: {
            self.alpha = 0
            self.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }) { _ in
            self.removeFromSuperview()
        }
    }

    @objc private func actCopy() { dismissAnimated(); onCopy() }
    @objc private func actPaste() { dismissAnimated(); onPaste() }
    @objc private func actEdit() { dismissAnimated(); onEdit() }
    @objc private func actPasteAndGo() { dismissAnimated(); onPasteAndGo() }
}

// MARK: - 下载管理视图控制器
final class DownloadManagerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var files: [URL] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "下载管理"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleDone))

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        loadFiles()
    }

    private func loadFiles() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dlFolder = docs.appendingPathComponent("Downloads", isDirectory: true)
        if let list = try? fm.contentsOfDirectory(at: dlFolder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: .skipsHiddenFiles) {
            files = list.sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                return d1 > d2
            }
        }
        tableView.reloadData()
    }

    @objc private func handleDone() { dismiss(animated: true) }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return files.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "DLCell")
        let file = files[indexPath.row]
        cell.textLabel?.text = file.lastPathComponent
        cell.imageView?.image = UIImage(systemName: "doc")
        let sz = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        cell.detailTextLabel?.text = ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let file = files[indexPath.row]
        let activity = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        present(activity, animated: true)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let del = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            guard let self = self else { return }
            let file = self.files[indexPath.row]
            try? FileManager.default.removeItem(at: file)
            self.files.remove(at: indexPath.row)
            self.tableView.deleteRows(at: [indexPath], with: .automatic)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [del])
    }
}

// MARK: - 浏览器标识管理控制器
final class UserAgentManagerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let store = UserAgentStore.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "浏览器标识 (UA)"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleDone))

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func handleDone() { dismiss(animated: true) }

    func numberOfSections(in tableView: UITableView) -> Int {
        return UserAgentCategory.allCases.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return UserAgentCategory.allCases[section].rawValue
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let cat = UserAgentCategory.allCases[section]
        return store.items.filter { $0.category == cat }.count + 1
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "UACell")
        let cat = UserAgentCategory.allCases[indexPath.section]
        let catItems = store.items.filter { $0.category == cat }

        if indexPath.row == catItems.count {
            cell.textLabel?.text = "+ 添加自定义标识"
            cell.textLabel?.textColor = UIColor(red: 0.08, green: 0.42, blue: 0.92, alpha: 1.0)
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            return cell
        }

        let item = catItems[indexPath.row]
        cell.textLabel?.text = item.name
        cell.detailTextLabel?.text = item.userAgent
        cell.accessoryType = (item.id == store.activeItem.id) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let cat = UserAgentCategory.allCases[indexPath.section]
        let catItems = store.items.filter { $0.category == cat }

        if indexPath.row == catItems.count {
            promptAdd(category: cat)
            return
        }

        let item = catItems[indexPath.row]
        store.setActive(id: item.id)
        tableView.reloadData()
    }

    private func promptAdd(category: UserAgentCategory) {
        let alert = UIAlertController(title: "添加标识", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "标识名称" }
        alert.addTextField { $0.placeholder = "User-Agent 字符串" }
        alert.addAction(UIAlertAction(title: "保存", style: .default, handler: { [weak self] _ in
            let name = alert.textFields?[0].text ?? "自定义"
            let ua = alert.textFields?[1].text ?? ""
            self?.store.addItem(name: name, userAgent: ua, category: category)
            self?.tableView.reloadData()
        }))
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}
