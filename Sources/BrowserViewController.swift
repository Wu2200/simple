import UIKit
import WebKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let browserVC = BrowserViewController()
        window.rootViewController = browserVC
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

public final class ExpandedURLEditorViewController: UIViewController, UITextViewDelegate {

    public var onConfirm: ((String) -> Void)?
    private var initialText: String

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "搜索或输入网址"
        label.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        label.textAlignment = .center
        return label
    }()

    private let cancelButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle("取消", for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        return btn
    }()

    private let goButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle("前往", for: .normal)
        btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        return btn
    }()

    private let containerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor { trait in
            return trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.16, alpha: 1.0)
                : UIColor(white: 0.94, alpha: 1.0)
        }
        view.layer.cornerRadius = 14
        view.layer.masksToBounds = true
        return view
    }()

    private let textView: UITextView = {
        let tv = UITextView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.font = UIFont.systemFont(ofSize: 16)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        tv.keyboardType = .URL
        tv.autocapitalizationType = .none
        tv.autocorrectionType = .no
        tv.returnKeyType = .go
        return tv
    }()

    public init(currentText: String) {
        self.initialText = currentText
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.initialText = ""
        super.init(coder: coder)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor { trait in
            return trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.12, alpha: 1.0)
                : UIColor(white: 0.98, alpha: 1.0)
        }

        if let sheet = self.sheetPresentationController {
            if #available(iOS 16.0, *) {
                let customSmallDetent = UISheetPresentationController.Detent.custom(identifier: .init("smallHalf")) { _ in
                    return 240
                }
                sheet.detents = [customSmallDetent]
            } else {
                sheet.detents = [.medium()]
            }
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 20
        }

        view.addSubview(cancelButton)
        view.addSubview(titleLabel)
        view.addSubview(goButton)
        view.addSubview(containerView)
        containerView.addSubview(textView)

        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            cancelButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            cancelButton.heightAnchor.constraint(equalToConstant: 32),

            goButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            goButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            goButton.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),

            containerView.topAnchor.constraint(equalTo: cancelButton.bottomAnchor, constant: 12),
            containerView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            containerView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            containerView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),

            textView.topAnchor.constraint(equalTo: containerView.topAnchor),
            textView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        cancelButton.addTarget(self, action: #selector(handleCancel), for: .touchUpInside)
        goButton.addTarget(self, action: #selector(handleGo), for: .touchUpInside)
        textView.delegate = self
        textView.text = initialText
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
        if !textView.text.isEmpty {
            textView.selectAll(nil)
        }
    }

    @objc private func handleCancel() {
        textView.resignFirstResponder()
        dismiss(animated: true)
    }

    @objc private func handleGo() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        textView.resignFirstResponder()
        dismiss(animated: true) { [weak self] in
            self?.onConfirm?(text)
        }
    }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" {
            handleGo()
            return false
        }
        return true
    }
}

public final class BrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UITextFieldDelegate, TabGridViewControllerDelegate {

    private var tabManager = TabManager()
    private var isBrowserActive: Bool = false
    private var isDesktopMode: Bool = false

    private let homeContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        return view
    }()

    private let homeTitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Simple"
        label.font = UIFont.systemFont(ofSize: 40, weight: .bold)
        label.textColor = .label
        label.textAlignment = .center
        return label
    }()

    private let webViewContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        view.alpha = 0
        return view
    }()

    private let bottomToolbar: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        return view
    }()

    private let toolbarSeparator: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .separator
        return view
    }()

    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let tabsButton = UIButton(type: .system)
    private let menuButton = UIButton(type: .system)

    private let urlBarContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor { trait in
            return trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.18, alpha: 1.0)
                : UIColor(white: 0.94, alpha: 1.0)
        }
        view.layer.cornerRadius = 12
        view.layer.masksToBounds = true
        return view
    }()

    private let urlTextField: UITextField = {
        let tf = UITextField()
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.font = UIFont.systemFont(ofSize: 15)
        tf.placeholder = "搜索或输入网址"
        tf.keyboardType = .URL
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        tf.returnKeyType = .go
        tf.clearButtonMode = .whileEditing
        return tf
    }()

    private let progressView: UIProgressView = {
        let pv = UIProgressView(progressViewStyle: .bar)
        pv.translatesAutoresizingMaskIntoConstraints = false
        pv.tintColor = .systemBlue
        pv.trackTintColor = .clear
        pv.alpha = 0
        return pv
    }()

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        setupViews()
        setupBottomToolbar()
        setupNotifications()

        createNewTab(url: nil)
    }

    private func setupViews() {
        view.addSubview(homeContainerView)
        homeContainerView.addSubview(homeTitleLabel)

        view.addSubview(webViewContainerView)
        view.addSubview(progressView)
        view.addSubview(bottomToolbar)
        bottomToolbar.addSubview(toolbarSeparator)

        NSLayoutConstraint.activate([
            homeContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            homeContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            homeContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            homeContainerView.bottomAnchor.constraint(equalTo: bottomToolbar.topAnchor),

            homeTitleLabel.centerXAnchor.constraint(equalTo: homeContainerView.centerXAnchor),
            homeTitleLabel.centerYAnchor.constraint(equalTo: homeContainerView.centerYAnchor, constant: -60),

            webViewContainerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webViewContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webViewContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webViewContainerView.bottomAnchor.constraint(equalTo: bottomToolbar.topAnchor),

            progressView.topAnchor.constraint(equalTo: webViewContainerView.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            bottomToolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomToolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomToolbar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomToolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -48),

            toolbarSeparator.topAnchor.constraint(equalTo: bottomToolbar.topAnchor),
            toolbarSeparator.leadingAnchor.constraint(equalTo: bottomToolbar.leadingAnchor),
            toolbarSeparator.trailingAnchor.constraint(equalTo: bottomToolbar.trailingAnchor),
            toolbarSeparator.heightAnchor.constraint(equalToConstant: 0.5)
        ])
    }

    private func setupBottomToolbar() {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillProportionally
        stack.alignment = .center
        stack.spacing = 8

        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        forwardButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        tabsButton.setImage(UIImage(systemName: "square.on.square"), for: .normal)
        menuButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)

        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        forwardButton.addTarget(self, action: #selector(handleForward), for: .touchUpInside)
        tabsButton.addTarget(self, action: #selector(handleOpenTabs), for: .touchUpInside)
        menuButton.addTarget(self, action: #selector(handleOpenMenu), for: .touchUpInside)

        urlBarContainer.addSubview(urlTextField)
        NSLayoutConstraint.activate([
            urlTextField.leadingAnchor.constraint(equalTo: urlBarContainer.leadingAnchor, constant: 10),
            urlTextField.trailingAnchor.constraint(equalTo: urlBarContainer.trailingAnchor, constant: -10),
            urlTextField.topAnchor.constraint(equalTo: urlBarContainer.topAnchor),
            urlTextField.bottomAnchor.constraint(equalTo: urlBarContainer.bottomAnchor),
            urlBarContainer.heightAnchor.constraint(equalToConstant: 36)
        ])

        urlTextField.delegate = self

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleAddressBarTapped))
        urlBarContainer.addGestureRecognizer(tapGesture)

        stack.addArrangedSubview(backButton)
        stack.addArrangedSubview(forwardButton)
        stack.addArrangedSubview(urlBarContainer)
        stack.addArrangedSubview(tabsButton)
        stack.addArrangedSubview(menuButton)

        bottomToolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bottomToolbar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: bottomToolbar.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: bottomToolbar.topAnchor, constant: 6),
            stack.heightAnchor.constraint(equalToConstant: 36),

            backButton.widthAnchor.constraint(equalToConstant: 36),
            forwardButton.widthAnchor.constraint(equalToConstant: 36),
            tabsButton.widthAnchor.constraint(equalToConstant: 36),
            menuButton.widthAnchor.constraint(equalToConstant: 36)
        ])
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleUserAgentChangedNotification), name: NSNotification.Name("UserAgentChangedNotification"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleWebsiteDataClearedNotification), name: NSNotification.Name("WebsiteDataClearedNotification"), object: nil)
    }

    @objc private func handleAddressBarTapped() {
        let current = urlTextField.text ?? ""
        let editor = ExpandedURLEditorViewController(currentText: current)
        editor.onConfirm = { [weak self] input in
            self?.loadInputString(input)
        }
        present(editor, animated: true)
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let text = textField.text ?? ""
        textField.resignFirstResponder()
        loadInputString(text)
        return true
    }

    private func loadInputString(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let targetURL: URL
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            targetURL = URL(string: trimmed) ?? URL(string: "https://www.google.com/search?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            targetURL = URL(string: "https://\(trimmed)") ?? URL(string: "https://www.google.com/search?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!
        } else {
            targetURL = URL(string: "https://www.google.com/search?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!
        }

        loadURL(targetURL)
    }

    private func loadURL(_ url: URL) {
        guard let activeTab = tabManager.activeTab else { return }
        activeTab.url = url
        applyUserAgentToTab(activeTab)
        activeTab.webView.load(URLRequest(url: url))
        showBrowserUI(animated: true)
    }

    private func showBrowserUI(animated: Bool) {
        isBrowserActive = true
        let animations = {
            self.homeContainerView.alpha = 0
            self.webViewContainerView.alpha = 1
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: animations)
        } else {
            animations()
        }
    }

    private func showHomeUI(animated: Bool) {
        isBrowserActive = false
        urlTextField.text = ""
        let animations = {
            self.homeContainerView.alpha = 1
            self.webViewContainerView.alpha = 0
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: animations)
        } else {
            animations()
        }
    }

    private func createNewTab(url: URL?) {
        let tab = tabManager.createNewTab()
        tab.webView.navigationDelegate = self
        tab.webView.uiDelegate = self
        tab.webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)
        tab.webView.addObserver(self, forKeyPath: #keyPath(WKWebView.title), options: .new, context: nil)
        tab.webView.addObserver(self, forKeyPath: #keyPath(WKWebView.url), options: .new, context: nil)

        switchToTab(tab)

        if let url = url {
            loadURL(url)
        } else {
            showHomeUI(animated: false)
        }
    }

    private func switchToTab(_ tab: TabItem) {
        tabManager.activeTab?.webView.removeFromSuperview()
        tabManager.setActiveTab(tab)

        webViewContainerView.addSubview(tab.webView)
        tab.webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tab.webView.topAnchor.constraint(equalTo: webViewContainerView.topAnchor),
            tab.webView.leadingAnchor.constraint(equalTo: webViewContainerView.leadingAnchor),
            tab.webView.trailingAnchor.constraint(equalTo: webViewContainerView.trailingAnchor),
            tab.webView.bottomAnchor.constraint(equalTo: webViewContainerView.bottomAnchor)
        ])

        if let url = tab.url, !url.isInternalURL {
            urlTextField.text = url.absoluteString
            showBrowserUI(animated: false)
        } else {
            showHomeUI(animated: false)
        }
        updateToolbarButtons()
    }

    private func applyUserAgentToTab(_ tab: TabItem) {
        let ua = UserAgentManager.shared.getCurrentUserAgent(isDesktopMode: isDesktopMode)
        tab.customUserAgent = ua
        tab.webView.customUserAgent = ua
    }

    @objc private func handleUserAgentChangedNotification() {
        guard let activeTab = tabManager.activeTab else { return }
        applyUserAgentToTab(activeTab)

        if isBrowserActive, let currentURL = activeTab.url, !currentURL.isInternalURL {
            showBrowserUI(animated: false)
            activeTab.webView.reload()
        }
    }

    @objc private func handleWebsiteDataClearedNotification() {
        guard let activeTab = tabManager.activeTab else { return }
        if isBrowserActive, let currentURL = activeTab.url, !currentURL.isInternalURL {
            showBrowserUI(animated: false)
            activeTab.webView.load(URLRequest(url: currentURL))
        }
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let webView = object as? WKWebView, webView == tabManager.activeTab?.webView else { return }

        if keyPath == #keyPath(WKWebView.estimatedProgress) {
            let progress = Float(webView.estimatedProgress)
            progressView.progress = progress
            if progress >= 1.0 {
                UIView.animate(withDuration: 0.2, animations: {
                    self.progressView.alpha = 0
                }) { _ in
                    self.progressView.progress = 0
                }
            } else {
                progressView.alpha = 1
            }
        } else if keyPath == #keyPath(WKWebView.title) {
            if let title = webView.title, !title.isEmpty {
                tabManager.activeTab?.title = title
            }
        } else if keyPath == #keyPath(WKWebView.url) {
            if let url = webView.url, !url.isInternalURL {
                urlTextField.text = url.absoluteString
                tabManager.activeTab?.url = url
                if !isBrowserActive {
                    showBrowserUI(animated: false)
                }
            }
        }
        updateToolbarButtons()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateToolbarButtons()
        takeSnapshot(for: tabManager.activeTab)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let currentURL = tabManager.activeTab?.url, !currentURL.isInternalURL {
            showBrowserUI(animated: false)
            webView.load(URLRequest(url: currentURL))
        }
    }

    private func takeSnapshot(for tab: TabItem?) {
        guard let tab = tab else { return }
        let config = WKSnapshotConfiguration()
        tab.webView.takeSnapshot(with: config) { image, _ in
            DispatchQueue.main.async {
                tab.snapshot = image
            }
        }
    }

    private func updateToolbarButtons() {
        guard let activeTab = tabManager.activeTab else { return }
        backButton.isEnabled = activeTab.webView.canGoBack
        forwardButton.isEnabled = activeTab.webView.canGoForward
    }

    @objc private func handleBack() {
        tabManager.activeTab?.webView.goBack()
    }

    @objc private func handleForward() {
        tabManager.activeTab?.webView.goForward()
    }

    @objc private func handleOpenTabs() {
        takeSnapshot(for: tabManager.activeTab)

        let gridVC = TabGridViewController()
        gridVC.delegate = self
        gridVC.tabs = tabManager.tabs
        gridVC.activeTabIndex = tabManager.tabs.firstIndex(where: { $0.id == tabManager.activeTab?.id }) ?? 0

        gridVC.modalPresentationStyle = .pageSheet
        if let sheet = gridVC.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(gridVC, animated: true)
    }

    @objc private func handleOpenMenu() {
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        let uaTitle = isDesktopMode ? "切换到移动版视图" : "切换到桌面版视图"
        alert.addAction(UIAlertAction(title: uaTitle, style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.isDesktopMode.toggle()
            self.handleUserAgentChangedNotification()
        })

        alert.addAction(UIAlertAction(title: "浏览器标识 (UA)", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let uaVC = UserAgentSettingsViewController()
            let nav = UINavigationController(rootViewController: uaVC)
            self.present(nav, animated: true)
        })

        alert.addAction(UIAlertAction(title: "清除浏览数据", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let cleanVC = CleanDataViewController()
            let nav = UINavigationController(rootViewController: cleanVC)
            self.present(nav, animated: true)
        })

        alert.addAction(UIAlertAction(title: "刷新网页", style: .default) { [weak self] _ in
            self?.tabManager.activeTab?.webView.reload()
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = menuButton
            popover.sourceRect = menuButton.bounds
        }

        present(alert, animated: true)
    }

    public func tabGridDidSelectTab(at index: Int) {
        guard index < tabManager.tabs.count else { return }
        switchToTab(tabManager.tabs[index])
    }

    public func tabGridDidCloseTab(at index: Int) {
        guard index < tabManager.tabs.count else { return }
        let tab = tabManager.tabs[index]
        tabManager.closeTab(tab)
        if tabManager.tabs.isEmpty {
            createNewTab(url: nil)
        } else if tabManager.activeTab == nil {
            let nextIndex = min(index, tabManager.tabs.count - 1)
            switchToTab(tabManager.tabs[nextIndex])
        }
    }

    public func tabGridDidCreateNewTab() {
        createNewTab(url: nil)
    }

    public func tabGridDidCloseAllTabs() {
        tabManager.tabs.forEach { tab in
            tab.webView.removeFromSuperview()
        }
        tabManager.tabs.removeAll()
        createNewTab(url: nil)
    }
}
