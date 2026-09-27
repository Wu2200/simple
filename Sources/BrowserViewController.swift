import UIKit
import WebKit

public final class BrowserViewController: UIViewController, UITextFieldDelegate, WKNavigationDelegate, WKUIDelegate {

    // MARK: - 属性
    public var tabs: [TabItem] = []
    public var activeTabIndex: Int = 0 {
        didSet {
            guard !tabs.isEmpty, activeTabIndex >= 0, activeTabIndex < tabs.count else { return }
            switchActiveWebView()
        }
    }

    public var activeTab: TabItem? {
        guard !tabs.isEmpty, activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    private var activeWebView: WKWebView? {
        return activeTab?.webView
    }

    // MARK: - UI 组件
    private let webContainerView = UIView()
    private let bottomToolbar = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))

    private let addressContentView = UIView()
    private let addressField = UITextField()
    private let progressView = UIProgressView(progressViewStyle: .default)

    private let leftLockIcon = UIButton(type: .system)
    private let rightExpandButton = UIButton(type: .system)
    private let rightRefreshButton = UIButton(type: .system)
    private let rightClearButton = UIButton(type: .system)

    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let tabsButton = UIButton(type: .system)
    private let pluginButton = UIButton(type: .system)
    private let moreMenuButton = UIButton(type: .system)

    // 主页专属视图
    private let homeContainerView = UIView()
    private let homeSearchField = UITextField()
    private var homeShortcutsCollectionView: UICollectionView!

    // 网页长按横向指示气泡菜单
    private var calloutMenu: AddressCalloutMenuView?

    // 观察者
    private var estimatedProgressObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupHomeView()
        setupDownloadObservers()
        initInitialTab()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateAddressBar()
        homeShortcutsCollectionView?.reloadData()
    }

    // MARK: - 布局构建
    private func setupUI() {
        view.backgroundColor = .systemBackground

        webContainerView.translatesAutoresizingMaskIntoConstraints = false
        bottomToolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webContainerView)
        view.addSubview(bottomToolbar)

        setupAddressBar()
        setupBottomButtons()

        NSLayoutConstraint.activate([
            webContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            webContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainerView.bottomAnchor.constraint(equalTo: bottomToolbar.topAnchor),

            bottomToolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomToolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomToolbar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomToolbar.heightAnchor.constraint(equalToConstant: 88)
        ])
    }

    private func setupAddressBar() {
        addressContentView.translatesAutoresizingMaskIntoConstraints = false
        addressContentView.backgroundColor = .secondarySystemBackground
        addressContentView.layer.cornerRadius = 22
        addressContentView.layer.cornerCurve = .continuous
        addressContentView.clipsToBounds = true
        bottomToolbar.contentView.addSubview(addressContentView)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleAddressLongPress(_:)))
        addressContentView.addGestureRecognizer(longPress)

        leftLockIcon.translatesAutoresizingMaskIntoConstraints = false
        leftLockIcon.setImage(UIImage(systemName: "shield.fill")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)), for: .normal)
        leftLockIcon.tintColor = UIColor(red: 0.12, green: 0.72, blue: 0.53, alpha: 1.0)
        leftLockIcon.addTarget(self, action: #selector(handleLockIconTapped), for: .touchUpInside)
        addressContentView.addSubview(leftLockIcon)

        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.font = .systemFont(ofSize: 15.5, weight: .regular)
        addressField.textColor = .label
        addressField.returnKeyType = .go
        addressField.autocorrectionType = .no
        addressField.autocapitalizationType = .none
        addressField.delegate = self
        addressField.placeholder = "搜索或输入网址"
        addressContentView.addSubview(addressField)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = .systemBlue
        progressView.trackTintColor = .clear
        progressView.alpha = 0
        addressContentView.addSubview(progressView)

        rightExpandButton.translatesAutoresizingMaskIntoConstraints = false
        rightExpandButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)), for: .normal)
        rightExpandButton.tintColor = UIColor(red: 0.28, green: 0.28, blue: 0.31, alpha: 1.0)
        rightExpandButton.addTarget(self, action: #selector(handleExpandAddress), for: .touchUpInside)
        addressContentView.addSubview(rightExpandButton)

        rightRefreshButton.translatesAutoresizingMaskIntoConstraints = false
        rightRefreshButton.setImage(UIImage(systemName: "arrow.clockwise")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)), for: .normal)
        rightRefreshButton.tintColor = UIColor(red: 0.28, green: 0.28, blue: 0.31, alpha: 1.0)
        rightRefreshButton.addTarget(self, action: #selector(handleRefreshOrStop), for: .touchUpInside)
        addressContentView.addSubview(rightRefreshButton)

        rightClearButton.translatesAutoresizingMaskIntoConstraints = false
        rightClearButton.setImage(UIImage(systemName: "xmark.circle.fill")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)), for: .normal)
        rightClearButton.tintColor = .systemGray2
        rightClearButton.isHidden = true
        rightClearButton.addTarget(self, action: #selector(handleClearText), for: .touchUpInside)
        addressContentView.addSubview(rightClearButton)

        NSLayoutConstraint.activate([
            addressContentView.topAnchor.constraint(equalTo: bottomToolbar.contentView.topAnchor, constant: 6),
            addressContentView.leadingAnchor.constraint(equalTo: bottomToolbar.contentView.leadingAnchor, constant: 14),
            addressContentView.trailingAnchor.constraint(equalTo: bottomToolbar.contentView.trailingAnchor, constant: -14),
            addressContentView.heightAnchor.constraint(equalToConstant: 44),

            leftLockIcon.leadingAnchor.constraint(equalTo: addressContentView.leadingAnchor, constant: 12),
            leftLockIcon.centerYAnchor.constraint(equalTo: addressContentView.centerYAnchor),
            leftLockIcon.widthAnchor.constraint(equalToConstant: 22),
            leftLockIcon.heightAnchor.constraint(equalToConstant: 22),

            addressField.leadingAnchor.constraint(equalTo: leftLockIcon.trailingAnchor, constant: 8),
            addressField.trailingAnchor.constraint(equalTo: addressContentView.trailingAnchor, constant: -68),
            addressField.topAnchor.constraint(equalTo: addressContentView.topAnchor),
            addressField.bottomAnchor.constraint(equalTo: addressContentView.bottomAnchor),

            progressView.leadingAnchor.constraint(equalTo: addressContentView.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: addressContentView.trailingAnchor),
            progressView.bottomAnchor.constraint(equalTo: addressContentView.bottomAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2.5),

            rightClearButton.trailingAnchor.constraint(equalTo: addressContentView.trailingAnchor, constant: -10),
            rightClearButton.centerYAnchor.constraint(equalTo: addressContentView.centerYAnchor),
            rightClearButton.widthAnchor.constraint(equalToConstant: 24),
            rightClearButton.heightAnchor.constraint(equalToConstant: 24),

            rightRefreshButton.trailingAnchor.constraint(equalTo: addressContentView.trailingAnchor, constant: -10),
            rightRefreshButton.centerYAnchor.constraint(equalTo: addressContentView.centerYAnchor),
            rightRefreshButton.widthAnchor.constraint(equalToConstant: 24),
            rightRefreshButton.heightAnchor.constraint(equalToConstant: 24),

            rightExpandButton.trailingAnchor.constraint(equalTo: rightRefreshButton.leadingAnchor, constant: -6),
            rightExpandButton.centerYAnchor.constraint(equalTo: addressContentView.centerYAnchor),
            rightExpandButton.widthAnchor.constraint(equalToConstant: 24),
            rightExpandButton.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func setupBottomButtons() {
        let graphite = UIColor(red: 0.28, green: 0.28, blue: 0.31, alpha: 1.0)
        let standardConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let smallConfig = UIImage.SymbolConfiguration(pointSize: 16.2, weight: .regular)

        backButton.setImage(UIImage(systemName: "chevron.backward", withConfiguration: standardConfig), for: .normal)
        backButton.tintColor = graphite
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)

        forwardButton.setImage(UIImage(systemName: "chevron.forward", withConfiguration: standardConfig), for: .normal)
        forwardButton.tintColor = graphite
        forwardButton.addTarget(self, action: #selector(handleForward), for: .touchUpInside)

        tabsButton.setImage(UIImage(systemName: "square.on.square", withConfiguration: smallConfig), for: .normal)
        tabsButton.tintColor = graphite
        tabsButton.addTarget(self, action: #selector(handleOpenTabs), for: .touchUpInside)

        pluginButton.setImage(UIImage(systemName: "puzzlepiece.extension", withConfiguration: smallConfig), for: .normal)
        pluginButton.tintColor = graphite
        pluginButton.addTarget(self, action: #selector(handleOpenScripts), for: .touchUpInside)

        moreMenuButton.setImage(UIImage(systemName: "line.3.horizontal", withConfiguration: standardConfig), for: .normal)
        moreMenuButton.tintColor = graphite
        moreMenuButton.addTarget(self, action: #selector(handleOpenMoreMenu), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [backButton, forwardButton, tabsButton, pluginButton, moreMenuButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.distribution = .equalSpacing
        stack.alignment = .center
        bottomToolbar.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: addressContentView.bottomAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: bottomToolbar.contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: bottomToolbar.contentView.trailingAnchor, constant: -24),
            stack.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func setupHomeView() {
        homeContainerView.translatesAutoresizingMaskIntoConstraints = false
        homeContainerView.backgroundColor = .systemGroupedBackground
        webContainerView.addSubview(homeContainerView)

        let searchCard = UIView()
        searchCard.translatesAutoresizingMaskIntoConstraints = false
        searchCard.backgroundColor = .secondarySystemGroupedBackground
        searchCard.layer.cornerRadius = 16
        searchCard.layer.cornerCurve = .continuous
        homeContainerView.addSubview(searchCard)

        let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.tintColor = .systemGray2
        searchCard.addSubview(searchIcon)

        homeSearchField.translatesAutoresizingMaskIntoConstraints = false
        homeSearchField.font = .systemFont(ofSize: 16, weight: .regular)
        homeSearchField.textColor = .label
        homeSearchField.placeholder = "搜索或输入网址"
        homeSearchField.returnKeyType = .go
        homeSearchField.delegate = self
        searchCard.addSubview(homeSearchField)

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "常用站点"
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .secondaryLabel
        homeContainerView.addSubview(titleLabel)

        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 68, height: 80)
        layout.minimumLineSpacing = 16
        layout.minimumInteritemSpacing = (view.bounds.width - 40 - (68 * 4)) / 3

        homeShortcutsCollectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        homeShortcutsCollectionView.translatesAutoresizingMaskIntoConstraints = false
        homeShortcutsCollectionView.backgroundColor = .clear
        homeShortcutsCollectionView.dataSource = self
        homeShortcutsCollectionView.delegate = self
        homeShortcutsCollectionView.register(HomeShortcutCell.self, forCellWithReuseIdentifier: HomeShortcutCell.reuseId)
        homeContainerView.addSubview(homeShortcutsCollectionView)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleShortcutLongPress(_:)))
        homeShortcutsCollectionView.addGestureRecognizer(longPress)

        NSLayoutConstraint.activate([
            homeContainerView.topAnchor.constraint(equalTo: webContainerView.topAnchor),
            homeContainerView.leadingAnchor.constraint(equalTo: webContainerView.leadingAnchor),
            homeContainerView.trailingAnchor.constraint(equalTo: webContainerView.trailingAnchor),
            homeContainerView.bottomAnchor.constraint(equalTo: webContainerView.bottomAnchor),

            searchCard.topAnchor.constraint(equalTo: homeContainerView.safeAreaLayoutGuide.topAnchor, constant: 36),
            searchCard.leadingAnchor.constraint(equalTo: homeContainerView.leadingAnchor, constant: 18),
            searchCard.trailingAnchor.constraint(equalTo: homeContainerView.trailingAnchor, constant: -18),
            searchCard.heightAnchor.constraint(equalToConstant: 48),

            searchIcon.leadingAnchor.constraint(equalTo: searchCard.leadingAnchor, constant: 14),
            searchIcon.centerYAnchor.constraint(equalTo: searchCard.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 18),
            searchIcon.heightAnchor.constraint(equalToConstant: 18),

            homeSearchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            homeSearchField.trailingAnchor.constraint(equalTo: searchCard.trailingAnchor, constant: -14),
            homeSearchField.topAnchor.constraint(equalTo: searchCard.topAnchor),
            homeSearchField.bottomAnchor.constraint(equalTo: searchCard.bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: searchCard.bottomAnchor, constant: 32),
            titleLabel.leadingAnchor.constraint(equalTo: homeContainerView.leadingAnchor, constant: 22),

            homeShortcutsCollectionView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            homeShortcutsCollectionView.leadingAnchor.constraint(equalTo: homeContainerView.leadingAnchor, constant: 20),
            homeShortcutsCollectionView.trailingAnchor.constraint(equalTo: homeContainerView.trailingAnchor, constant: -20),
            homeShortcutsCollectionView.bottomAnchor.constraint(equalTo: homeContainerView.bottomAnchor)
        ])
    }

    // MARK: - 下载通知与手动弹窗确认
    private func setupDownloadObservers() {
        // 手动确认下载弹窗通知
        NotificationCenter.default.addObserver(self, selector: #selector(handleDownloadPrompt(_:)), name: DownloadCoordinator.promptNotification, object: nil)
        // 下载启动通知
        NotificationCenter.default.addObserver(self, selector: #selector(handleDownloadStarted(_:)), name: DownloadCoordinator.startedNotification, object: nil)
        // 下载完成通知
        NotificationCenter.default.addObserver(self, selector: #selector(handleDownloadFinished(_:)), name: DownloadCoordinator.finishedNotification, object: nil)
        // 下载失败通知
        NotificationCenter.default.addObserver(self, selector: #selector(handleDownloadFailed(_:)), name: DownloadCoordinator.failedNotification, object: nil)
    }

    @objc private func handleDownloadPrompt(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let url = userInfo["url"] as? URL,
              let filename = userInfo["filename"] as? String else { return }

        let alert = UIAlertController(
            title: "下载文件",
            message: "\(filename)\n\n来源: \(url.host ?? url.absoluteString)",
            preferredStyle: .alert
        )

        let downloadAction = UIAlertAction(title: "下载文件", style: .default) { _ in
            DownloadCoordinator.shared.startDownload(url: url, filename: filename)
        }

        let copyAction = UIAlertAction(title: "复制下载链接", style: .default) { [weak self] _ in
            UIPasteboard.general.string = url.absoluteString
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.showToast(message: "已复制下载链接")
        }

        let cancelAction = UIAlertAction(title: "取消", style: .cancel)

        alert.addAction(downloadAction)
        alert.addAction(copyAction)
        alert.addAction(cancelAction)

        present(alert, animated: true)
    }

    @objc private func handleDownloadStarted(_ notification: Notification) {
        guard let filename = notification.userInfo?["filename"] as? String else { return }
        showToast(message: "开始下载: \(filename)")
    }

    @objc private func handleDownloadFinished(_ notification: Notification) {
        guard let filename = notification.userInfo?["filename"] as? String else { return }
        showToast(message: "下载完成: \(filename)")
    }

    @objc private func handleDownloadFailed(_ notification: Notification) {
        guard let filename = notification.userInfo?["filename"] as? String else { return }
        showToast(message: "下载失败: \(filename)")
    }

    // MARK: - 纯白极简卡片 Toast 提示框（纯白底色、柔和微阴影、深灰文字）
    public func showToast(message: String) {
        let toast = UIView()
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.backgroundColor = .white
        toast.layer.cornerRadius = 18
        toast.layer.cornerCurve = .continuous
        toast.layer.borderWidth = 0.5
        toast.layer.borderColor = UIColor(white: 0.90, alpha: 1.0).cgColor

        // 柔和微阴影
        toast.layer.shadowColor = UIColor.black.cgColor
        toast.layer.shadowOpacity = 0.08
        toast.layer.shadowOffset = CGSize(width: 0, height: 4)
        toast.layer.shadowRadius = 10

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = message
        label.font = .systemFont(ofSize: 13.5, weight: .medium)
        label.textColor = UIColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1.0)
        label.textAlignment = .center
        toast.addSubview(label)

        view.addSubview(toast)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: toast.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: toast.bottomAnchor, constant: -9),
            label.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -18),

            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: bottomToolbar.topAnchor, constant: -16)
        ])

        toast.alpha = 0
        toast.transform = CGAffineTransform(translationX: 0, y: 10).scaledBy(x: 0.96, y: 0.96)

        UIView.animate(withDuration: 0.26, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: .curveEaseOut) {
            toast.alpha = 1.0
            toast.transform = .identity
        } completion: { _ in
            UIView.animate(withDuration: 0.22, delay: 1.8, options: .curveEaseIn) {
                toast.alpha = 0
                toast.transform = CGAffineTransform(translationX: 0, y: -6)
            } completion: { _ in
                toast.removeFromSuperview()
            }
        }
    }

    // MARK: - 标签页与 WebView 控制
    private func initInitialTab() {
        let initialTab = TabItem(title: "新标签页", url: nil)
        tabs = [initialTab]
        activeTabIndex = 0
    }

    private func switchActiveWebView() {
        webContainerView.subviews.forEach { if $0 !== homeContainerView { $0.removeFromSuperview() } }

        guard let tab = activeTab else { return }
        let wv = tab.webView
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.uiDelegate = self
        webContainerView.insertSubview(wv, belowSubview: homeContainerView)

        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: webContainerView.topAnchor),
            wv.leadingAnchor.constraint(equalTo: webContainerView.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: webContainerView.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: webContainerView.bottomAnchor)
        ])

        bindObservations(for: wv)
        updateAddressBar()
    }

    private func bindObservations(for wv: WKWebView) {
        estimatedProgressObservation?.invalidate()
        urlObservation?.invalidate()
        titleObservation?.invalidate()

        estimatedProgressObservation = wv.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                self?.progressView.alpha = (webView.estimatedProgress >= 1.0) ? 0 : 1.0
                self?.progressView.setProgress(Float(webView.estimatedProgress), animated: true)
                if webView.estimatedProgress >= 1.0 {
                    UIView.animate(withDuration: 0.25, delay: 0.15, options: .curveEaseOut) {
                        self?.progressView.alpha = 0
                    } completion: { _ in
                        self?.progressView.setProgress(0, animated: false)
                    }
                }
            }
        }

        urlObservation = wv.observe(\.url, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                self?.updateAddressBar()
            }
        }

        titleObservation = wv.observe(\.title, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self, let tab = self.activeTab else { return }
                tab.title = webView.title?.isEmpty == false ? webView.title! : "新标签页"
            }
        }
    }

    private func updateAddressBar() {
        guard let wv = activeWebView else {
            homeContainerView.isHidden = false
            addressField.text = ""
            rightRefreshButton.isHidden = true
            return
        }

        if let currentURL = wv.url, currentURL.absoluteString != "about:blank" {
            homeContainerView.isHidden = true
            addressField.text = currentURL.absoluteString
            rightRefreshButton.isHidden = false
            rightRefreshButton.setImage(UIImage(systemName: wv.isLoading ? "xmark" : "arrow.clockwise"), for: .normal)
        } else {
            homeContainerView.isHidden = false
            addressField.text = ""
            rightRefreshButton.isHidden = true
        }

        backButton.isEnabled = wv.canGoBack
        forwardButton.isEnabled = wv.canGoForward
    }

    // MARK: - 地址栏动作
    @objc private func handleBack() {
        activeWebView?.goBack()
    }

    @objc private func handleForward() {
        activeWebView?.goForward()
    }

    @objc private func handleRefreshOrStop() {
        guard let wv = activeWebView else { return }
        if wv.isLoading {
            wv.stopLoading()
        } else {
            wv.reload()
        }
    }

    @objc private func handleClearText() {
        addressField.text = ""
    }

    @objc private func handleExpandAddress() {
        let currentText = addressField.text ?? ""
        let editorVC = ExpandedURLEditorViewController(initialText: currentText) { [weak self] newURLString in
            self?.loadInput(newURLString)
        }
        let nav = UINavigationController(rootViewController: editorVC)
        present(nav, animated: true)
    }

    @objc private func handleLockIconTapped() {
        let websiteVC = WebsiteDataViewController()
        let nav = UINavigationController(rootViewController: websiteVC)
        present(nav, animated: true)
    }

    // MARK: - 地址栏长按横向指示气泡
    @objc private func handleAddressLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        view.endEditing(true)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        calloutMenu?.dismiss(animated: false)

        let menu = AddressCalloutMenuView()
        menu.onActionSelected = { [weak self] action in
            self?.executeCalloutAction(action)
        }
        menu.show(in: view, pointingTo: addressContentView)
        calloutMenu = menu
    }

    private func executeCalloutAction(_ action: AddressCalloutMenuView.ActionType) {
        switch action {
        case .copy:
            let textToCopy = addressField.text ?? ""
            UIPasteboard.general.string = textToCopy
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

        case .paste:
            if let pasteText = UIPasteboard.general.string {
                addressField.text = pasteText
                addressField.becomeFirstResponder()
            }

        case .edit:
            addressField.becomeFirstResponder()
            addressField.selectAll(nil)

        case .pasteAndGo:
            if let pasteText = UIPasteboard.general.string {
                addressField.text = pasteText
                loadInput(pasteText)
            }
        }
    }

    // MARK: - 更多菜单与下载管理
    @objc private func handleOpenMoreMenu() {
        var firstPageItems: [CustomBottomSheetItem] = []
        var secondPageItems: [CustomBottomSheetItem] = []

        // 1. 书签/历史
        firstPageItems.append(CustomBottomSheetItem(title: "书签/历史", iconName: "star", action: { [weak self] in
            let historyVC = BrowserHistoryViewController()
            historyVC.onSelectURL = { url in
                self?.loadInput(url.absoluteString)
            }
            let nav = UINavigationController(rootViewController: historyVC)
            self?.present(nav, animated: true)
        }))

        // 2. 下载管理
        firstPageItems.append(CustomBottomSheetItem(title: "下载管理", iconName: "arrow.down.circle", action: { [weak self] in
            let downloadVC = DownloadManagerViewController()
            let nav = UINavigationController(rootViewController: downloadVC)
            self?.present(nav, animated: true)
        }))

        // 3. 电脑版
        let isDesktop = activeTab?.isDesktopMode ?? false
        firstPageItems.append(CustomBottomSheetItem(title: "电脑版", iconName: "desktopcomputer", isSwitchOn: isDesktop, action: { [weak self] in
            guard let self = self, let tab = self.activeTab else { return }
            tab.isDesktopMode.toggle()
            tab.webView.customUserAgent = tab.isDesktopMode ? DesktopUAManager.desktopUA : nil
            tab.reload()
        }))

        // 4. 夜间模式
        firstPageItems.append(CustomBottomSheetItem(title: "夜间模式", iconName: "moon.stars", isSwitchOn: false, action: {
            // 就地切换
        }))

        // 5. 添加（书签或主页快捷方式）
        firstPageItems.append(CustomBottomSheetItem(title: "添加", iconName: "star.fill", customImage: UIImage(systemName: "star.badge.plus") ?? UIImage(systemName: "star"), action: { [weak self] in
            self?.handleAddBookmarkOrShortcut()
        }))

        // 6. 全屏浏览
        firstPageItems.append(CustomBottomSheetItem(title: "全屏浏览", iconName: "arrow.up.left.and.arrow.down.right", action: { [weak self] in
            self?.toggleFullscreen()
        }))

        // 7. 广告过滤
        let isAdBlockOn = AdBlocker.shared.isEnabled
        firstPageItems.append(CustomBottomSheetItem(title: "广告过滤", iconName: "shield.lefthalf.filled", isSwitchOn: isAdBlockOn, action: { [weak self] in
            AdBlocker.shared.isEnabled.toggle()
            self?.activeTab?.reload()
        }))

        // 8. 清除数据
        firstPageItems.append(CustomBottomSheetItem(title: "清除数据", iconName: "trash", action: { [weak self] in
            let cleanVC = CleanDataViewController()
            let nav = UINavigationController(rootViewController: cleanVC)
            self?.present(nav, animated: true)
        }))

        // 第二页
        // 9. 扩展脚本
        secondPageItems.append(CustomBottomSheetItem(title: "扩展脚本", iconName: "puzzlepiece.extension", action: { [weak self] in
            self?.handleOpenScripts()
        }))

        // 10. 标识设置
        secondPageItems.append(CustomBottomSheetItem(title: "标识设置", iconName: "person.badge.shield.checkmark", action: { [weak self] in
            // UA 设置
        }))

        // 11. 搜索引擎
        secondPageItems.append(CustomBottomSheetItem(title: "搜索引擎", iconName: "magnifyingglass", action: { [weak self] in
            // 切换搜索引擎
        }))

        // 12. 提取正文
        secondPageItems.append(CustomBottomSheetItem(title: "提取正文", iconName: "doc.plaintext", action: { [weak self] in
            self?.extractPageText()
        }))

        let sheetVC = CustomBottomSheetViewController(pages: [firstPageItems, secondPageItems])
        if let sheet = sheetVC.sheetPresentationController {
            sheet.detents = [.custom(resolver: { _ in 260 })]
            sheet.prefersGrabberVisible = true
        }
        present(sheetVC, animated: true)
    }

    private func handleAddBookmarkOrShortcut() {
        guard let url = activeWebView?.url, url.absoluteString != "about:blank" else {
            showToast(message: "当前页面不可添加")
            return
        }

        let title = activeWebView?.title ?? url.host ?? "网页"

        let alert = UIAlertController(title: "添加到", message: "\(title)", preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "添加到书签", style: .default, handler: { [weak self] _ in
            BookmarkStore.shared.addBookmark(title: title, urlString: url.absoluteString)
            self?.showToast(message: "已添加到书签")
        }))

        alert.addAction(UIAlertAction(title: "添加到主页", style: .default, handler: { [weak self] _ in
            HomeShortcutStore.shared.addShortcut(title: title, urlString: url.absoluteString)
            self?.homeShortcutsCollectionView?.reloadData()
            self?.showToast(message: "已添加到主页")
        }))

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func toggleFullscreen() {
        let isHidden = bottomToolbar.isHidden
        UIView.animate(withDuration: 0.25) {
            self.bottomToolbar.isHidden = !isHidden
        }
    }

    private func extractPageText() {
        activeWebView?.evaluateJavaScript("document.body.innerText") { [weak self] result, _ in
            guard let self = self, let text = result as? String, !text.isEmpty else { return }
            let alert = UIAlertController(title: "网页正文", message: String(text.prefix(600)), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "复制", style: .default, handler: { _ in
                UIPasteboard.general.string = text
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }))
            alert.addAction(UIAlertAction(title: "关闭", style: .cancel))
            self.present(alert, animated: true)
        }
    }

    @objc private func handleOpenTabs() {
        let gridVC = TabGridViewController(tabs: tabs, activeIndex: activeTabIndex)
        gridVC.delegate = self
        let nav = UINavigationController(rootViewController: gridVC)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    @objc private func handleOpenScripts() {
        let scriptVC = UserScriptManagerViewController()
        let nav = UINavigationController(rootViewController: scriptVC)
        present(nav, animated: true)
    }

    // MARK: - 加载与搜索
    public func loadInput(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let targetURL: URL
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            targetURL = URL(string: trimmed) ?? SearchEngineManager.shared.currentEngine.searchURL(for: trimmed)
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            targetURL = URL(string: "https://\(trimmed)") ?? SearchEngineManager.shared.currentEngine.searchURL(for: trimmed)
        } else {
            targetURL = SearchEngineManager.shared.currentEngine.searchURL(for: trimmed)
        }

        homeContainerView.isHidden = true
        activeWebView?.load(URLRequest(url: targetURL))
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        if let text = textField.text, !text.isEmpty {
            loadInput(text)
        }
        return true
    }

    public func textFieldDidBeginEditing(_ textField: UITextField) {
        if textField === addressField {
            rightClearButton.isHidden = false
            rightRefreshButton.isHidden = true
            rightExpandButton.isHidden = true
        }
    }

    public func textFieldDidEndEditing(_ textField: UITextField) {
        if textField === addressField {
            rightClearButton.isHidden = true
            rightRefreshButton.isHidden = false
            rightExpandButton.isHidden = false
        }
    }
}

// MARK: - 主页常用站点 CollectionView & 长按编辑
extension BrowserViewController: UICollectionViewDataSource, UICollectionViewDelegate {

    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return HomeShortcutStore.shared.shortcuts.count
    }

    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: HomeShortcutCell.reuseId, for: indexPath) as? HomeShortcutCell else {
            return UICollectionViewCell()
        }
        let item = HomeShortcutStore.shared.shortcuts[indexPath.item]
        cell.configure(with: item)
        return cell
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let item = HomeShortcutStore.shared.shortcuts[indexPath.item]
        loadInput(item.urlString)
    }

    @objc private func handleShortcutLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: homeShortcutsCollectionView)
        guard let indexPath = homeShortcutsCollectionView.indexPathForItem(at: point) else { return }
        let item = HomeShortcutStore.shared.shortcuts[indexPath.item]

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let alert = UIAlertController(title: item.title, message: item.urlString, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "编辑", style: .default, handler: { [weak self] _ in
            self?.promptEditShortcut(item: item)
        }))

        alert.addAction(UIAlertAction(title: "删除", style: .destructive, handler: { [weak self] _ in
            HomeShortcutStore.shared.deleteShortcut(id: item.id)
            self?.homeShortcutsCollectionView?.reloadData()
            self?.showToast(message: "已删除常用站点")
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
            tf.placeholder = "网站地址 (URL)"
            tf.text = item.urlString
            tf.keyboardType = .URL
        }

        alert.addAction(UIAlertAction(title: "保存", style: .default, handler: { [weak self] _ in
            guard let title = alert.textFields?[0].text, !title.isEmpty,
                  let url = alert.textFields?[1].text, !url.isEmpty else { return }
            HomeShortcutStore.shared.updateShortcut(id: item.id, title: title, url: url)
            self?.homeShortcutsCollectionView?.reloadData()
            self?.showToast(message: "已保存修改")
        }))

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - TabGridViewControllerDelegate
extension BrowserViewController: TabGridViewControllerDelegate {
    public func tabGridDidSelectTab(at index: Int) {
        activeTabIndex = index
    }

    public func tabGridDidCloseTab(at index: Int) {
        tabs.remove(at: index)
        if tabs.isEmpty {
            initInitialTab()
        } else if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else {
            switchActiveWebView()
        }
    }

    public func tabGridDidCreateNewTab() {
        let newTab = TabItem(title: "新标签页", url: nil)
        tabs.append(newTab)
        activeTabIndex = tabs.count - 1
    }
}

// MARK: - 主页常用站点 Cell
public final class HomeShortcutCell: UICollectionViewCell {
    public static let reuseId = "HomeShortcutCell"

    private let iconContainer = UIView()
    private let iconImageView = UIImageView()
    private let titleLabel = UILabel()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.backgroundColor = .secondarySystemBackground
        iconContainer.layer.cornerRadius = 16
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.clipsToBounds = true
        contentView.addSubview(iconContainer)

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.contentMode = .scaleAspectFit
        iconContainer.addSubview(iconImageView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            iconContainer.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 54),
            iconContainer.heightAnchor.constraint(equalToConstant: 54),

            iconImageView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 28),
            iconImageView.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
    }

    public func configure(with item: HomeShortcutItem) {
        titleLabel.text = item.title
        iconImageView.image = UIImage(systemName: "globe")
        iconImageView.tintColor = .systemGray2

        if let host = URL(string: item.urlString)?.host {
            FaviconCacheManager.shared.loadFavicon(for: host) { [weak self] img in
                if let img = img {
                    self?.iconImageView.image = img
                }
            }
        }
    }
}

// MARK: - 悬浮横向指示气泡菜单（带三角小箭头）
public final class AddressCalloutMenuView: UIView {

    public enum ActionType: String {
        case copy = "拷贝"
        case paste = "粘贴"
        case edit = "编辑"
        case pasteAndGo = "粘贴并前往"
    }

    public var onActionSelected: ((ActionType) -> Void)?

    private let bubbleView = UIView()
    private let arrowLayer = CAShapeLayer()

    public init() {
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = .clear

        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.backgroundColor = .white
        bubbleView.layer.cornerRadius = 14
        bubbleView.layer.cornerCurve = .continuous
        bubbleView.layer.borderWidth = 0.5
        bubbleView.layer.borderColor = UIColor(white: 0.88, alpha: 1.0).cgColor
        bubbleView.layer.shadowColor = UIColor.black.cgColor
        bubbleView.layer.shadowOpacity = 0.12
        bubbleView.layer.shadowOffset = CGSize(width: 0, height: 4)
        bubbleView.layer.shadowRadius = 12
        addSubview(bubbleView)

        let actions: [ActionType] = [.copy, .paste, .edit, .pasteAndGo]
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillProportionally
        stack.spacing = 0
        bubbleView.addSubview(stack)

        for (index, action) in actions.enumerated() {
            let btn = UIButton(type: .system)
            btn.setTitle(action.rawValue, for: .normal)
            btn.setTitleColor(UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0), for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 14.5, weight: .regular)
            btn.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
            btn.addAction(UIAction { [weak self] _ in
                self?.onActionSelected?(action)
                self?.dismiss(animated: true)
            }, for: .touchUpInside)
            stack.addArrangedSubview(btn)

            if index < actions.count - 1 {
                let sep = UIView()
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.backgroundColor = UIColor(white: 0.90, alpha: 1.0)
                sep.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
                sep.heightAnchor.constraint(equalToConstant: 20).isActive = true
                stack.addArrangedSubview(sep)
            }
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bubbleView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor),

            bubbleView.centerXAnchor.constraint(equalTo: centerXAnchor),
            bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    public func show(in parentView: UIView, pointingTo targetView: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        parentView.addSubview(self)

        let tapOutside = UITapGestureRecognizer(target: self, action: #selector(handleTapOutside(_:)))
        parentView.addGestureRecognizer(tapOutside)

        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: targetView.centerXAnchor),
            bottomAnchor.constraint(equalTo: targetView.topAnchor, constant: -4)
        ])

        alpha = 0
        transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
            self.alpha = 1.0
            self.transform = .identity
        }
    }

    public func dismiss(animated: Bool) {
        if animated {
            UIView.animate(withDuration: 0.16, options: .curveEaseIn) {
                self.alpha = 0
                self.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            } completion: { _ in
                self.removeFromSuperview()
            }
        } else {
            removeFromSuperview()
        }
    }

    @objc private func handleTapOutside(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if !bounds.contains(point) {
            dismiss(animated: true)
            gesture.view?.removeGestureRecognizer(gesture)
        }
    }
}

// MARK: - 展开式完整网址编辑弹窗
public final class ExpandedURLEditorViewController: UIViewController {

    private let initialText: String
    private let onComplete: (String) -> Void
    private let textView = UITextView()

    public init(initialText: String, onComplete: @escaping (String) -> Void) {
        self.initialText = initialText
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        title = "编辑网址"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(handleCancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "前往", style: .done, target: self, action: #selector(handleDone))

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .systemFont(ofSize: 16, weight: .regular)
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 14
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.text = initialText
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.heightAnchor.constraint(equalToConstant: 160)
        ])

        textView.becomeFirstResponder()
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }

    @objc private func handleDone() {
        let text = textView.text ?? ""
        dismiss(animated: true) { [weak self] in
            self?.onComplete(text)
        }
    }
}
