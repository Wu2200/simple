import UIKit
import WebKit

public class BrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, TabGridDelegate, UrlEditSheetDelegate {

    // MARK: - Properties
    public var tabs: [TabItem] = []
    public var currentTabIndex: Int = 0

    public var currentTab: TabItem? {
        guard currentTabIndex >= 0 && currentTabIndex < tabs.count else { return nil }
        return tabs[currentTabIndex]
    }

    public var webView: WKWebView!

    // UI 组件
    private let topBar = UIView()
    private let urlContainer = UIView()
    private let urlLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)

    private let bottomToolbar = UIView()
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let tabsButton = UIButton(type: .system)
    private let homeButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)

    public let homeView = UIView()
    public var isShowingHome: Bool = true

    // MARK: - Lifecycle
    public override func viewDidLoad() {
        super.viewDidLoad()
        setupWebView()
        setupTopBar()
        setupBottomToolbar()
        setupHomeView()
        setupNotifications()

        // 初始化默认标签
        if tabs.isEmpty {
            let firstTab = TabItem(url: nil, title: "新标签页")
            tabs.append(firstTab)
            currentTabIndex = 0
        }

        applyCurrentTab()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleUserAgentChanged), name: .userAgentDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDataCleaned), name: .didCleanWebsiteData, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - WebView Setup
    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        view.addSubview(webView)

        webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)
        webView.addObserver(self, forKeyPath: "title", options: .new, context: nil)
        webView.addObserver(self, forKeyPath: "URL", options: .new, context: nil)
        webView.addObserver(self, forKeyPath: "canGoBack", options: .new, context: nil)
        webView.addObserver(self, forKeyPath: "canGoForward", options: .new, context: nil)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 52),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -48)
        ])
    }

    // MARK: - Top & Bottom Bars
    private func setupTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.backgroundColor = .systemBackground
        view.addSubview(topBar)

        urlContainer.translatesAutoresizingMaskIntoConstraints = false
        urlContainer.backgroundColor = UIColor { trait in
            return trait.userInterfaceStyle == .dark ? UIColor(white: 0.16, alpha: 1.0) : UIColor(white: 0.94, alpha: 1.0)
        }
        urlContainer.layer.cornerRadius = 10
        urlContainer.layer.masksToBounds = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleUrlTapped))
        urlContainer.addGestureRecognizer(tap)
        topBar.addSubview(urlContainer)

        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.font = UIFont.systemFont(ofSize: 15)
        urlLabel.textAlignment = .center
        urlLabel.lineBreakMode = .byTruncatingTail
        urlLabel.text = "搜索或输入网址"
        urlLabel.textColor = .secondaryLabel
        urlContainer.addSubview(urlLabel)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = .clear
        progressView.progressTintColor = .systemBlue
        progressView.isHidden = true
        topBar.addSubview(progressView)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 52),

            urlContainer.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            urlContainer.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            urlContainer.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            urlContainer.heightAnchor.constraint(equalToConstant: 38),

            urlLabel.leadingAnchor.constraint(equalTo: urlContainer.leadingAnchor, constant: 12),
            urlLabel.trailingAnchor.constraint(equalTo: urlContainer.trailingAnchor, constant: -12),
            urlLabel.centerYAnchor.constraint(equalTo: urlContainer.centerYAnchor),

            progressView.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            progressView.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2)
        ])
    }

    private func setupBottomToolbar() {
        bottomToolbar.translatesAutoresizingMaskIntoConstraints = false
        bottomToolbar.backgroundColor = .systemBackground
        view.addSubview(bottomToolbar)

        let stack = UIStackView(arrangedSubviews: [backButton, forwardButton, tabsButton, homeButton, moreButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.distribution = .fillEqually
        stack.alignment = .center
        bottomToolbar.addSubview(stack)

        backButton.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
        forwardButton.setImage(UIImage(systemName: "chevron.forward"), for: .normal)
        tabsButton.setImage(UIImage(systemName: "square.on.square"), for: .normal)
        homeButton.setImage(UIImage(systemName: "house"), for: .normal)
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)

        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        forwardButton.addTarget(self, action: #selector(handleForward), for: .touchUpInside)
        tabsButton.addTarget(self, action: #selector(handleTabs), for: .touchUpInside)
        homeButton.addTarget(self, action: #selector(handleHome), for: .touchUpInside)
        moreButton.addTarget(self, action: #selector(handleMore), for: .touchUpInside)

        updateNavButtons()

        NSLayoutConstraint.activate([
            bottomToolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bottomToolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomToolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomToolbar.heightAnchor.constraint(equalToConstant: 48),

            stack.topAnchor.constraint(equalTo: bottomToolbar.topAnchor),
            stack.leadingAnchor.constraint(equalTo: bottomToolbar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bottomToolbar.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomToolbar.bottomAnchor)
        ])
    }

    private func setupHomeView() {
        homeView.translatesAutoresizingMaskIntoConstraints = false
        homeView.backgroundColor = .systemBackground
        view.addSubview(homeView)

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Simple Browser"
        title.font = UIFont.systemFont(ofSize: 26, weight: .bold)
        title.textColor = .label
        homeView.addSubview(title)

        NSLayoutConstraint.activate([
            homeView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            homeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            homeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            homeView.bottomAnchor.constraint(equalTo: bottomToolbar.topAnchor),

            title.centerXAnchor.constraint(equalTo: homeView.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: homeView.centerYAnchor, constant: -40)
        ])
    }

    // MARK: - UI Switch
    private func showHomeUI() {
        isShowingHome = true
        homeView.isHidden = false
        webView.isHidden = true
        urlLabel.text = "搜索或输入网址"
        urlLabel.textColor = .secondaryLabel
        updateNavButtons()
    }

    private func showBrowserUI() {
        isShowingHome = false
        homeView.isHidden = true
        webView.isHidden = false
        updateNavButtons()
    }

    // MARK: - Notifications Handling (绝不跳回主页，只在当前页面刷新)
    @objc private func handleUserAgentChanged() {
        let ua = WebsiteDataManager.shared.currentUserAgent()
        currentTab?.customUserAgent = ua.isEmpty ? nil : ua
        webView.customUserAgent = ua.isEmpty ? nil : ua

        // 仅在当前处于网页状态时进行当前页刷新，绝对不退回主页
        if !isShowingHome, let currentURL = currentTab?.url ?? webView.url, currentURL.absoluteString != "about:blank" {
            webView.reload()
        }
    }

    @objc private func handleDataCleaned() {
        // 缓存与数据清理完成，仅在当前处于网页状态时进行当前页刷新，绝对不退回主页
        if !isShowingHome, let currentURL = currentTab?.url ?? webView.url, currentURL.absoluteString != "about:blank" {
            webView.reload()
        }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Web 进程清理或终止时，若当前存在网页，自动原地恢复当前页面，绝不退回主页
        if !isShowingHome, let url = currentTab?.url ?? webView.url, url.absoluteString != "about:blank" {
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - Navigation Actions
    @objc private func handleBack() {
        if webView.canGoBack {
            webView.goBack()
        }
    }

    @objc private func handleForward() {
        if webView.canGoForward {
            webView.goForward()
        }
    }

    @objc private func handleHome() {
        currentTab?.url = nil
        currentTab?.title = "新标签页"
        showHomeUI()
    }

    @objc private func handleTabs() {
        captureCurrentTabSnapshot()
        let tabGridVC = TabGridViewController(tabs: tabs, selectedIndex: currentTabIndex)
        tabGridVC.delegate = self
        tabGridVC.modalPresentationStyle = .pageSheet
        if let sheet = tabGridVC.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 20
        }
        present(tabGridVC, animated: true)
    }

    @objc private func handleMore() {
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "浏览器标识 (UA)", style: .default, handler: { [weak self] _ in
            let uaVC = UserAgentViewController()
            let nav = UINavigationController(rootViewController: uaVC)
            self?.present(nav, animated: true)
        }))
        alert.addAction(UIAlertAction(title: "清除数据", style: .default, handler: { [weak self] _ in
            let cleanVC = CleanDataViewController()
            let nav = UINavigationController(rootViewController: cleanVC)
            nav.modalPresentationStyle = .pageSheet
            if let sheet = nav.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
            }
            self?.present(nav, animated: true)
        }))
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func handleUrlTapped() {
        let currentText = isShowingHome ? "" : (webView.url?.absoluteString ?? "")
        let editVC = UrlEditSheetViewController(currentText: currentText)
        editVC.delegate = self
        present(editVC, animated: true)
    }

    public func urlEditSheetDidConfirm(text: String) {
        guard !text.isEmpty else { return }
        loadURLString(text)
    }

    public func loadURLString(_ string: String) {
        showBrowserUI()
        let targetURL: URL
        if string.lowercased().hasPrefix("http://") || string.lowercased().hasPrefix("https://") {
            targetURL = URL(string: string) ?? URL(string: "https://www.google.com/search?q=\(string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!
        } else if string.contains(".") && !string.contains(" ") {
            targetURL = URL(string: "https://" + string) ?? URL(string: "https://www.google.com/search?q=\(string)")!
        } else {
            let encoded = string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            targetURL = URL(string: "https://www.google.com/search?q=\(encoded)")!
        }

        currentTab?.url = targetURL
        webView.load(URLRequest(url: targetURL))
    }

    private func applyCurrentTab() {
        guard let tab = currentTab else { return }
        let ua = WebsiteDataManager.shared.currentUserAgent()
        webView.customUserAgent = ua.isEmpty ? nil : ua

        if let url = tab.url {
            showBrowserUI()
            webView.load(URLRequest(url: url))
        } else {
            showHomeUI()
        }
    }

    private func captureCurrentTabSnapshot() {
        guard !isShowingHome else {
            currentTab?.snapshot = nil
            return
        }
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        let image = renderer.image { _ in
            webView.drawHierarchy(in: webView.bounds, afterScreenUpdates: false)
        }
        currentTab?.snapshot = image
    }

    private func updateNavButtons() {
        backButton.isEnabled = !isShowingHome && webView.canGoBack
        forwardButton.isEnabled = !isShowingHome && webView.canGoForward
    }

    // MARK: - TabGridDelegate
    public func tabGridDidSelectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        currentTabIndex = index
        applyCurrentTab()
    }

    public func tabGridDidCloseTab(_ tab: TabItem, at index: Int) {
        // 关闭标签由 TabGridViewController 统一管理
    }

    public func tabGridDidRequestNewTab() {
        let newTab = TabItem(url: nil, title: "新标签页")
        tabs.append(newTab)
        currentTabIndex = tabs.count - 1
        applyCurrentTab()
    }

    public func tabGridDidRequestCloseAllTabs() {
        tabs.removeAll()
        tabGridDidRequestNewTab()
    }

    // MARK: - KVO
    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "estimatedProgress" {
            progressView.progress = Float(webView.estimatedProgress)
            progressView.isHidden = webView.estimatedProgress >= 1.0
        } else if keyPath == "title" {
            if let title = webView.title, !title.isEmpty, !isShowingHome {
                currentTab?.title = title
            }
        } else if keyPath == "URL" {
            if let url = webView.url, !isShowingHome {
                currentTab?.url = url
                urlLabel.text = url.host ?? url.absoluteString
                urlLabel.textColor = .label
            }
        } else if keyPath == "canGoBack" || keyPath == "canGoForward" {
            updateNavButtons()
        }
    }
}
