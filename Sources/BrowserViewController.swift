import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = BrowserViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

class TouchButton: UIButton {
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)
    var hitTestInsets: UIEdgeInsets = .zero

    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupFeedback()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupFeedback()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if hitTestInsets == .zero {
            return super.point(inside: point, with: event)
        }
        let enlargedBounds = bounds.inset(by: hitTestInsets)
        return enlargedBounds.contains(point)
    }

    private func setupFeedback() {
        addTarget(self, action: #selector(handleTouchDown), for: .touchDown)
        addTarget(self, action: #selector(handleTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @objc private func handleTouchDown() {
        hapticGenerator.impactOccurred()
        UIView.animate(withDuration: 0.08) {
            self.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        }
    }

    @objc private func handleTouchUp() {
        UIView.animate(withDuration: 0.12) {
            self.transform = .identity
        }
    }
}

final class AddressTextField: UITextField {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) ||
           action == #selector(paste(_:)) ||
           action == #selector(selectAll(_:)) ||
           action == #selector(select(_:)) ||
           action == #selector(cut(_:)) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

private struct QuickNavigationSite {
    let name: String
    let url: String
    let iconName: String
    let tintColor: UIColor
}

final class BrowserViewController: UIViewController, UITextFieldDelegate, TabItemDelegate, UIGestureRecognizerDelegate {
    private var tabs: [TabItem] = []
    private var activeTabIndex = 0
    private var isFullscreen = false
    private var progressObservation: NSKeyValueObservation?

    private var activeTab: TabItem {
        tabs[activeTabIndex]
    }

    private let quickSites: [QuickNavigationSite] = [
        QuickNavigationSite(name: "百度", url: "https://www.baidu.com", iconName: "magnifyingglass", tintColor: .systemBlue),
        QuickNavigationSite(name: "哔哩哔哩", url: "https://www.bilibili.com", iconName: "play.rectangle.fill", tintColor: .systemPink),
        QuickNavigationSite(name: "知乎", url: "https://www.zhihu.com", iconName: "bubble.left.and.bubble.right.fill", tintColor: .systemIndigo),
        QuickNavigationSite(name: "GitHub", url: "https://github.com", iconName: "chevron.left.forwardslash.chevron.right", tintColor: .label),
        QuickNavigationSite(name: "豆瓣", url: "https://www.douban.com", iconName: "film.fill", tintColor: .systemGreen),
        QuickNavigationSite(name: "掘金", url: "https://juejin.cn", iconName: "sparkles", tintColor: .systemTeal)
    ]

    private let webContainer = UIView()
    private let homeView = UIView()
    private let failureOverlayView = UIView()
    private let failureCardView = UIView()
    private let failureIconView = UIImageView()
    private let failureTitleLabel = UILabel()
    private let failureReasonLabel = UILabel()
    private let failureURLLabel = UILabel()
    private let failureBackButton = TouchButton()
    private let failureReloadButton = TouchButton()

    private let editingDimmingView = UIView()

    private let bottomPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let bottomPanelBorder = UIView()
    private let addressContainer = UIView()
    private let lockButton = TouchButton()
    private let addressField = AddressTextField()
    private let refreshButton = TouchButton()
    private let clearButton = TouchButton()
    private let progressView = UIProgressView(progressViewStyle: .default)

    private let navigationStack = UIStackView()
    private let backButton = TouchButton()
    private let forwardButton = TouchButton()
    private let pluginButton = TouchButton()
    private let tabsButton = TouchButton()
    private let tabsCountBadge = UILabel()
    private let moreButton = TouchButton()

    private var bottomPanelBottomConstraint: NSLayoutConstraint?
    private var webTopSafeConstraint: NSLayoutConstraint?
    private var webTopFullscreenConstraint: NSLayoutConstraint?
    private var webBottomPanelConstraint: NSLayoutConstraint?
    private var webBottomFullscreenConstraint: NSLayoutConstraint?

    override var preferredStatusBarStyle: UIStatusBarStyle {
        .darkContent
    }

    override var prefersStatusBarHidden: Bool {
        isFullscreen
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        isFullscreen
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureInterface()
        configureHomeView()
        configureKeyboardObservers()
        configureKeyboardDismissal()
        configureFullscreenExitGesture()
        configureInstallerObserver()
        configureSessionObservers()
        restorePreviousSession()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        EyeProtectionManager.shared.restoreState(in: view.window)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        for (idx, tab) in tabs.enumerated() {
            if idx != activeTabIndex {
                tab.snapshot = nil
            }
        }
    }

    deinit {
        persistCurrentSession()
        NotificationCenter.default.removeObserver(self)
        progressObservation?.invalidate()
    }

    private func resetProgress() {
        progressView.setProgress(0, animated: false)
        progressView.alpha = 0
    }

    private func configureInstallerObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstallUserScriptNotification(_:)),
            name: NSNotification.Name("InstallUserScriptNotification"),
            object: nil
        )
    }

    private func configureSessionObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionPersistenceNotification),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionPersistenceNotification),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc private func handleSessionPersistenceNotification() {
        persistCurrentSession()
    }

    private func restorePreviousSession() {
        guard let session = BrowserSessionStore.shared.loadSession() else {
            createNewTab(loadURL: nil)
            return
        }

        let restoredTabs = session.tabs.map { item -> TabItem in
            let tab = TabItem()
            tab.delegate = self
            tab.restoreSession(
                url: item.urlString.flatMap(URL.init(string:)),
                title: item.title
            )
            return tab
        }

        guard !restoredTabs.isEmpty else {
            createNewTab(loadURL: nil)
            return
        }

        tabs = restoredTabs
        activeTabIndex = min(max(0, session.activeIndex), tabs.count - 1)
        switchTab(to: activeTabIndex)
    }

    private func persistCurrentSession() {
        guard !tabs.isEmpty else {
            BrowserSessionStore.shared.clearSession()
            return
        }

        let items = tabs.map { tab in
            BrowserTabSessionItem(
                urlString: tab.sessionURL()?.absoluteString,
                title: tab.title
            )
        }

        BrowserSessionStore.shared.saveSession(
            tabs: items,
            activeIndex: activeTabIndex
        )
    }

    @objc private func handleInstallUserScriptNotification(_ notification: Notification) {
        guard let scriptURL = notification.object as? URL else { return }

        let task = URLSession.shared.dataTask(with: scriptURL) { [weak self] data, response, error in
            guard let data = data, let code = String(data: data, encoding: .utf8), !code.isEmpty else { return }
            let (parsedName, parsedMatch) = UserScriptStore.shared.parseMetadata(from: code)

            DispatchQueue.main.async {
                let alert = UIAlertController(
                    title: "安装油猴脚本",
                    message: "脚本名称: \(parsedName)\n匹配域名: \(parsedMatch)\n\n是否确定安装此油猴脚本？",
                    preferredStyle: .alert
                )

                alert.addAction(UIAlertAction(title: "安装", style: .default) { _ in
                    var scripts = UserScriptStore.shared.loadScripts()
                    let newScript = UserScript(
                        id: UUID().uuidString,
                        name: parsedName,
                        matchPattern: parsedMatch,
                        code: code,
                        isEnabled: true
                    )
                    scripts.append(newScript)
                    UserScriptStore.shared.saveScripts(scripts)
                    self?.activeTab.reloadUserScripts()
                })
                alert.addAction(UIAlertAction(title: "取消", style: .cancel))

                self?.present(alert, animated: true)
            }
        }
        task.resume()
    }

    private func makeSpacedThreeLinesIcon() -> UIImage {
        let size = CGSize(width: 20, height: 18)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setLineWidth(1.8)
            cg.setLineCap(.round)
            cg.setStrokeColor(UIColor.label.cgColor)

            let yOffsets: [CGFloat] = [2.0, 9.0, 16.0]
            for y in yOffsets {
                cg.move(to: CGPoint(x: 1.5, y: y))
                cg.addLine(to: CGPoint(x: 18.5, y: y))
            }
            cg.strokePath()
        }
        return img.withRenderingMode(.alwaysTemplate)
    }

    private func configureHomeView() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false

        let contentContainer = UIView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        let logoIconView = UIImageView()
        logoIconView.translatesAutoresizingMaskIntoConstraints = false
        logoIconView.image = UIImage(
            systemName: "safari.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 48, weight: .semibold)
        )
        logoIconView.tintColor = .systemBlue
        logoIconView.contentMode = .scaleAspectFit

        let appTitleLabel = UILabel()
        appTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        appTitleLabel.text = "简阅浏览器"
        appTitleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        appTitleLabel.textColor = .label
        appTitleLabel.textAlignment = .center

        let fakeSearchButton = TouchButton()
        fakeSearchButton.translatesAutoresizingMaskIntoConstraints = false
        fakeSearchButton.backgroundColor = .secondarySystemGroupedBackground
        fakeSearchButton.layer.cornerRadius = 20
        fakeSearchButton.layer.borderWidth = 0.5
        fakeSearchButton.layer.borderColor = UIColor.separator.withAlphaComponent(0.3).cgColor
        fakeSearchButton.addTarget(self, action: #selector(activateSearchField), for: .touchUpInside)

        let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)))
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.tintColor = .tertiaryLabel

        let searchPlaceholderLabel = UILabel()
        searchPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        searchPlaceholderLabel.text = "搜索或输入网址…"
        searchPlaceholderLabel.font = .systemFont(ofSize: 14, weight: .regular)
        searchPlaceholderLabel.textColor = .tertiaryLabel

        fakeSearchButton.addSubview(searchIcon)
        fakeSearchButton.addSubview(searchPlaceholderLabel)

        let sectionHeader = UILabel()
        sectionHeader.translatesAutoresizingMaskIntoConstraints = false
        sectionHeader.text = "常用站点"
        sectionHeader.font = .systemFont(ofSize: 14, weight: .semibold)
        sectionHeader.textColor = .secondaryLabel

        let sitesGridStack = UIStackView()
        sitesGridStack.translatesAutoresizingMaskIntoConstraints = false
        sitesGridStack.axis = .vertical
        sitesGridStack.spacing = 14
        sitesGridStack.distribution = .fillEqually

        var rowStack: UIStackView?
        for (idx, site) in quickSites.enumerated() {
            if idx % 3 == 0 {
                rowStack = UIStackView()
                rowStack?.axis = .horizontal
                rowStack?.spacing = 12
                rowStack?.distribution = .fillEqually
                sitesGridStack.addArrangedSubview(rowStack!)
            }

            let siteButton = TouchButton()
            siteButton.translatesAutoresizingMaskIntoConstraints = false
            siteButton.backgroundColor = .secondarySystemGroupedBackground
            siteButton.layer.cornerRadius = 14
            siteButton.layer.borderWidth = 0.5
            siteButton.layer.borderColor = UIColor.separator.withAlphaComponent(0.25).cgColor
            siteButton.tag = idx
            siteButton.addTarget(self, action: #selector(handleQuickSiteTap(_:)), for: .touchUpInside)

            let iconView = UIImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.image = UIImage(systemName: site.iconName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
            iconView.tintColor = site.tintColor
            iconView.contentMode = .scaleAspectFit

            let nameLabel = UILabel()
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.text = site.name
            nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
            nameLabel.textColor = .label
            nameLabel.textAlignment = .center

            siteButton.addSubview(iconView)
            siteButton.addSubview(nameLabel)

            NSLayoutConstraint.activate([
                siteButton.heightAnchor.constraint(equalToConstant: 76),
                iconView.centerXAnchor.constraint(equalTo: siteButton.centerXAnchor),
                iconView.topAnchor.constraint(equalTo: siteButton.topAnchor, constant: 14),
                iconView.widthAnchor.constraint(equalToConstant: 26),
                iconView.heightAnchor.constraint(equalToConstant: 26),

                nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
                nameLabel.leadingAnchor.constraint(equalTo: siteButton.leadingAnchor, constant: 4),
                nameLabel.trailingAnchor.constraint(equalTo: siteButton.trailingAnchor, constant: -4)
            ])

            rowStack?.addArrangedSubview(siteButton)
        }

        homeView.addSubview(scrollView)
        scrollView.addSubview(contentContainer)

        contentContainer.addSubview(logoIconView)
        contentContainer.addSubview(appTitleLabel)
        contentContainer.addSubview(fakeSearchButton)
        contentContainer.addSubview(sectionHeader)
        contentContainer.addSubview(sitesGridStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: homeView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: homeView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: homeView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: homeView.bottomAnchor),

            contentContainer.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentContainer.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            logoIconView.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 36),
            logoIconView.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            logoIconView.widthAnchor.constraint(equalToConstant: 54),
            logoIconView.heightAnchor.constraint(equalToConstant: 54),

            appTitleLabel.topAnchor.constraint(equalTo: logoIconView.bottomAnchor, constant: 10),
            appTitleLabel.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),

            fakeSearchButton.topAnchor.constraint(equalTo: appTitleLabel.bottomAnchor, constant: 28),
            fakeSearchButton.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 20),
            fakeSearchButton.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -20),
            fakeSearchButton.heightAnchor.constraint(equalToConstant: 44),

            searchIcon.leadingAnchor.constraint(equalTo: fakeSearchButton.leadingAnchor, constant: 14),
            searchIcon.centerYAnchor.constraint(equalTo: fakeSearchButton.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 18),
            searchIcon.heightAnchor.constraint(equalToConstant: 18),

            searchPlaceholderLabel.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            searchPlaceholderLabel.centerYAnchor.constraint(equalTo: fakeSearchButton.centerYAnchor),

            sectionHeader.topAnchor.constraint(equalTo: fakeSearchButton.bottomAnchor, constant: 32),
            sectionHeader.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 22),

            sitesGridStack.topAnchor.constraint(equalTo: sectionHeader.bottomAnchor, constant: 12),
            sitesGridStack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 20),
            sitesGridStack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -20),
            sitesGridStack.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -40)
        ])
    }

    @objc private func activateSearchField() {
        addressField.becomeFirstResponder()
    }

    @objc private func handleQuickSiteTap(_ sender: UIButton) {
        guard sender.tag < quickSites.count else { return }
        let site = quickSites[sender.tag]
        if let targetURL = URL(string: site.url) {
            load(url: targetURL)
        }
    }

    private func configureInterface() {
        view.backgroundColor = .systemBackground

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.backgroundColor = .systemBackground

        homeView.translatesAutoresizingMaskIntoConstraints = false
        homeView.backgroundColor = .systemGroupedBackground

        failureOverlayView.translatesAutoresizingMaskIntoConstraints = false
        failureOverlayView.backgroundColor = .systemGroupedBackground
        failureOverlayView.isHidden = true

        failureCardView.translatesAutoresizingMaskIntoConstraints = false
        failureCardView.backgroundColor = .secondarySystemGroupedBackground
        failureCardView.layer.cornerRadius = 18
        failureCardView.layer.borderWidth = 0.5
        failureCardView.layer.borderColor = UIColor.separator.withAlphaComponent(0.25).cgColor
        failureCardView.clipsToBounds = true

        failureIconView.translatesAutoresizingMaskIntoConstraints = false
        failureIconView.image = UIImage(
            systemName: "wifi.exclamationmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .medium)
        )
        failureIconView.tintColor = .systemOrange
        failureIconView.contentMode = .scaleAspectFit

        failureTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        failureTitleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        failureTitleLabel.textColor = .label
        failureTitleLabel.text = "无法连接至此网页"

        failureReasonLabel.translatesAutoresizingMaskIntoConstraints = false
        failureReasonLabel.font = .systemFont(ofSize: 13, weight: .regular)
        failureReasonLabel.textColor = .secondaryLabel
        failureReasonLabel.textAlignment = .center
        failureReasonLabel.numberOfLines = 0
        failureReasonLabel.text = "网络连接受阻，或服务器暂时不可达。"

        failureURLLabel.translatesAutoresizingMaskIntoConstraints = false
        failureURLLabel.font = .systemFont(ofSize: 12, weight: .medium)
        failureURLLabel.textColor = .tertiaryLabel
        failureURLLabel.textAlignment = .center
        failureURLLabel.numberOfLines = 2

        failureBackButton.translatesAutoresizingMaskIntoConstraints = false
        var backConfig = UIButton.Configuration.gray()
        backConfig.title = "返回"
        backConfig.baseForegroundColor = .label
        backConfig.cornerStyle = .capsule
        failureBackButton.configuration = backConfig
        failureBackButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)

        failureReloadButton.translatesAutoresizingMaskIntoConstraints = false
        var reloadConfig = UIButton.Configuration.filled()
        reloadConfig.title = "重试"
        reloadConfig.baseBackgroundColor = .systemBlue
        reloadConfig.baseForegroundColor = .white
        reloadConfig.cornerStyle = .capsule
        failureReloadButton.configuration = reloadConfig
        failureReloadButton.addTarget(self, action: #selector(handleRefreshTap), for: .touchUpInside)

        let btnStack = UIStackView(arrangedSubviews: [failureBackButton, failureReloadButton])
        btnStack.translatesAutoresizingMaskIntoConstraints = false
        btnStack.axis = .horizontal
        btnStack.spacing = 12
        btnStack.distribution = .fillEqually

        failureCardView.addSubview(failureIconView)
        failureCardView.addSubview(failureTitleLabel)
        failureCardView.addSubview(failureReasonLabel)
        failureCardView.addSubview(failureURLLabel)
        failureCardView.addSubview(btnStack)
        failureOverlayView.addSubview(failureCardView)

        NSLayoutConstraint.activate([
            failureCardView.centerYAnchor.constraint(equalTo: failureOverlayView.centerYAnchor, constant: -20),
            failureCardView.leadingAnchor.constraint(equalTo: failureOverlayView.leadingAnchor, constant: 24),
            failureCardView.trailingAnchor.constraint(equalTo: failureOverlayView.trailingAnchor, constant: -24),

            failureIconView.topAnchor.constraint(equalTo: failureCardView.topAnchor, constant: 24),
            failureIconView.centerXAnchor.constraint(equalTo: failureCardView.centerXAnchor),
            failureIconView.widthAnchor.constraint(equalToConstant: 44),
            failureIconView.heightAnchor.constraint(equalToConstant: 44),

            failureTitleLabel.topAnchor.constraint(equalTo: failureIconView.bottomAnchor, constant: 12),
            failureTitleLabel.centerXAnchor.constraint(equalTo: failureCardView.centerXAnchor),

            failureReasonLabel.topAnchor.constraint(equalTo: failureTitleLabel.bottomAnchor, constant: 8),
            failureReasonLabel.leadingAnchor.constraint(equalTo: failureCardView.leadingAnchor, constant: 20),
            failureReasonLabel.trailingAnchor.constraint(equalTo: failureCardView.trailingAnchor, constant: -20),

            failureURLLabel.topAnchor.constraint(equalTo: failureReasonLabel.bottomAnchor, constant: 8),
            failureURLLabel.leadingAnchor.constraint(equalTo: failureCardView.leadingAnchor, constant: 20),
            failureURLLabel.trailingAnchor.constraint(equalTo: failureCardView.trailingAnchor, constant: -20),

            btnStack.topAnchor.constraint(equalTo: failureURLLabel.bottomAnchor, constant: 20),
            btnStack.leadingAnchor.constraint(equalTo: failureCardView.leadingAnchor, constant: 20),
            btnStack.trailingAnchor.constraint(equalTo: failureCardView.trailingAnchor, constant: -20),
            btnStack.heightAnchor.constraint(equalToConstant: 40),
            btnStack.bottomAnchor.constraint(equalTo: failureCardView.bottomAnchor, constant: -20)
        ])

        editingDimmingView.translatesAutoresizingMaskIntoConstraints = false
        editingDimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        editingDimmingView.alpha = 0
        editingDimmingView.isHidden = true
        let dimmingTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        editingDimmingView.addGestureRecognizer(dimmingTap)

        bottomPanel.translatesAutoresizingMaskIntoConstraints = false
        bottomPanel.clipsToBounds = false

        bottomPanelBorder.translatesAutoresizingMaskIntoConstraints = false
        bottomPanelBorder.backgroundColor = UIColor.separator.withAlphaComponent(0.3)

        addressContainer.translatesAutoresizingMaskIntoConstraints = false
        addressContainer.backgroundColor = UIColor.tertiarySystemFill
        addressContainer.layer.cornerRadius = 20
        addressContainer.layer.borderWidth = 0.5
        addressContainer.layer.borderColor = UIColor.separator.withAlphaComponent(0.2).cgColor
        addressContainer.clipsToBounds = true

        lockButton.translatesAutoresizingMaskIntoConstraints = false
        lockButton.tintColor = .secondaryLabel
        lockButton.setImage(
            UIImage(
                systemName: "lock.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            ),
            for: .normal
        )
        lockButton.hitTestInsets = UIEdgeInsets(top: -10, left: -10, bottom: -10, right: -10)
        lockButton.addTarget(self, action: #selector(showSiteDomainSettings), for: .touchUpInside)

        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.delegate = self
        addressField.placeholder = "搜索或输入网址"
        addressField.font = .systemFont(ofSize: 14, weight: .regular)
        addressField.textColor = .label
        addressField.textAlignment = .left
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.clearButtonMode = .never
        addressField.textContentType = .URL
        addressField.addTarget(self, action: #selector(addressFieldDidChange), for: .editingChanged)

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.tintColor = .secondaryLabel
        refreshButton.setImage(
            UIImage(
                systemName: "arrow.clockwise",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            ),
            for: .normal
        )
        refreshButton.addTarget(self, action: #selector(handleRefreshTap), for: .touchUpInside)

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.tintColor = .secondaryLabel
        clearButton.setImage(
            UIImage(
                systemName: "xmark.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            ),
            for: .normal
        )
        clearButton.alpha = 0
        clearButton.isHidden = true
        clearButton.addTarget(self, action: #selector(clearAddressInput), for: .touchUpInside)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = .systemBlue
        progressView.trackTintColor = .clear
        progressView.progress = 0
        progressView.alpha = 0

        navigationStack.translatesAutoresizingMaskIntoConstraints = false
        navigationStack.axis = .horizontal
        navigationStack.alignment = .fill
        navigationStack.distribution = .fillEqually
        navigationStack.spacing = 8

        configureToolbarButton(backButton, imageName: "chevron.left", action: #selector(goBack))
        configureToolbarButton(forwardButton, imageName: "chevron.right", action: #selector(goForward))
        configureToolbarButton(moreButton, imageName: "line.3.horizontal", action: #selector(showMoreMenu))
        configureToolbarButton(tabsButton, imageName: "square.on.square", action: #selector(showTabsManager))
        configureToolbarButton(pluginButton, imageName: "square.3.layers.3d", action: #selector(showPluginPanel))

        tabsCountBadge.translatesAutoresizingMaskIntoConstraints = false
        tabsCountBadge.font = .systemFont(ofSize: 10, weight: .bold)
        tabsCountBadge.textColor = .label
        tabsCountBadge.textAlignment = .center
        tabsButton.addSubview(tabsCountBadge)

        NSLayoutConstraint.activate([
            tabsCountBadge.centerXAnchor.constraint(equalTo: tabsButton.centerXAnchor, constant: 1),
            tabsCountBadge.centerYAnchor.constraint(equalTo: tabsButton.centerYAnchor, constant: 0)
        ])

        let longPressMore = UILongPressGestureRecognizer(target: self, action: #selector(handleMoreButtonLongPress(_:)))
        longPressMore.minimumPressDuration = 0.45
        moreButton.addGestureRecognizer(longPressMore)

        navigationStack.addArrangedSubview(backButton)
        navigationStack.addArrangedSubview(forwardButton)
        navigationStack.addArrangedSubview(moreButton)
        navigationStack.addArrangedSubview(tabsButton)
        navigationStack.addArrangedSubview(pluginButton)

        addressContainer.addSubview(lockButton)
        addressContainer.addSubview(addressField)
        addressContainer.addSubview(refreshButton)
        addressContainer.addSubview(clearButton)
        addressContainer.addSubview(progressView)

        bottomPanel.contentView.addSubview(bottomPanelBorder)
        bottomPanel.contentView.addSubview(addressContainer)
        bottomPanel.contentView.addSubview(navigationStack)

        view.addSubview(webContainer)
        view.addSubview(homeView)
        view.addSubview(failureOverlayView)
        view.addSubview(editingDimmingView)
        view.addSubview(bottomPanel)

        bottomPanelBottomConstraint = bottomPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        webTopSafeConstraint = webContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        webTopFullscreenConstraint = webContainer.topAnchor.constraint(equalTo: view.topAnchor)
        webBottomPanelConstraint = webContainer.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor)
        webBottomFullscreenConstraint = webContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        webTopSafeConstraint?.isActive = true
        webBottomPanelConstraint?.isActive = true

        NSLayoutConstraint.activate([
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            homeView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            homeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            homeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            homeView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),

            failureOverlayView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            failureOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            failureOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            failureOverlayView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),

            editingDimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            editingDimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editingDimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editingDimmingView.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor),

            bottomPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomPanelBottomConstraint!,

            bottomPanelBorder.topAnchor.constraint(equalTo: bottomPanel.topAnchor),
            bottomPanelBorder.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor),
            bottomPanelBorder.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor),
            bottomPanelBorder.heightAnchor.constraint(equalToConstant: 0.5),

            addressContainer.topAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: 8),
            addressContainer.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor, constant: 14),
            addressContainer.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor, constant: -14),
            addressContainer.heightAnchor.constraint(equalToConstant: 40),

            lockButton.leadingAnchor.constraint(equalTo: addressContainer.leadingAnchor, constant: 10),
            lockButton.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            lockButton.widthAnchor.constraint(equalToConstant: 22),
            lockButton.heightAnchor.constraint(equalToConstant: 22),

            addressField.leadingAnchor.constraint(equalTo: lockButton.trailingAnchor, constant: 6),
            addressField.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -6),
            addressField.topAnchor.constraint(equalTo: addressContainer.topAnchor),
            addressField.bottomAnchor.constraint(equalTo: addressContainer.bottomAnchor),

            progressView.leadingAnchor.constraint(equalTo: addressContainer.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor),
            progressView.bottomAnchor.constraint(equalTo: addressContainer.bottomAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2.5),

            refreshButton.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor, constant: -10),
            refreshButton.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 22),
            refreshButton.heightAnchor.constraint(equalToConstant: 22),

            clearButton.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor, constant: -10),
            clearButton.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 22),
            clearButton.heightAnchor.constraint(equalToConstant: 22),

            navigationStack.topAnchor.constraint(equalTo: addressContainer.bottomAnchor, constant: 6),
            navigationStack.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor, constant: 14),
            navigationStack.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor, constant: -14),
            navigationStack.bottomAnchor.constraint(equalTo: bottomPanel.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            navigationStack.heightAnchor.constraint(equalToConstant: 38)
        ])
    }

    @objc private func handleMoreButtonLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showCleanDataMenu()
    }

    private func showToastNotice(_ text: String) {
        let toast = UILabel()
        toast.text = "  \(text)  "
        toast.font = .systemFont(ofSize: 13, weight: .medium)
        toast.textColor = .white
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        toast.layer.cornerRadius = 14
        toast.clipsToBounds = true
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.alpha = 0

        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: -14),
            toast.heightAnchor.constraint(equalToConstant: 34)
        ])

        UIView.animate(withDuration: 0.18) { toast.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            UIView.animate(withDuration: 0.2, animations: { toast.alpha = 0 }) { _ in
                toast.removeFromSuperview()
            }
        }
    }

    private func configureToolbarButton(_ button: TouchButton, imageName: String, action: Selector?) {
        var configuration = UIButton.Configuration.plain()
        if imageName == "line.3.horizontal" {
            configuration.image = makeSpacedThreeLinesIcon()
        } else {
            configuration.image = UIImage(
                systemName: imageName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            )
        }
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)

        button.configuration = configuration
        button.backgroundColor = .clear
        button.clipsToBounds = false
        if let action = action {
            button.addTarget(self, action: action, for: .touchUpInside)
        }
    }

    private func configureKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    private func configureKeyboardDismissal() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        view.addGestureRecognizer(tapGesture)
    }

    private func configureFullscreenExitGesture() {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleFullscreenExitGesture(_:)))
        gesture.minimumPressDuration = 2.0
        gesture.numberOfTouchesRequired = 2
        gesture.cancelsTouchesInView = false
        view.addGestureRecognizer(gesture)
    }

    private func createNewTab(loadURL url: URL?, sourceID: UUID? = nil) {
        let tab = TabItem()
        tab.sourceTabID = sourceID
        tab.delegate = self
        tabs.append(tab)
        switchTab(to: tabs.count - 1)

        if let url = url {
            load(url: url)
        } else {
            persistCurrentSession()
        }
    }

    private func switchTab(to index: Int) {
        guard tabs.indices.contains(index) else {
            return
        }

        if tabs.indices.contains(activeTabIndex) {
            activeTab.webView.removeFromSuperview()
        }

        resetProgress()
        activeTabIndex = index

        let tab = activeTab
        tab.webView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(tab.webView)

        NSLayoutConstraint.activate([
            tab.webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            tab.webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            tab.webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            tab.webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        ])

        bindProgressObservation(to: tab.webView)

        if tab.isDisplayingFailurePage {
            showFailureUI(for: tab)
        } else if let url = tab.url {
            showBrowserUI()
            let rawString = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            let hostString = url.host?.removingPercentEncoding ?? url.host ?? rawString
            addressField.text = hostString
        } else {
            showHomeUI()
        }

        if let restoreURL = tab.consumePendingRestoreURL() {
            tab.webView.load(URLRequest(url: restoreURL))
        }

        persistCurrentSession()
        updateUIState()
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        resetProgress()

        let isClosingActiveTab = (index == activeTabIndex)
        let tab = tabs[index]
        tab.destroy()
        tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabIndex = 0
            createNewTab(loadURL: nil)
            return
        }

        if isClosingActiveTab {
            activeTabIndex = min(index, tabs.count - 1)
            switchTab(to: activeTabIndex)
        } else {
            if index < activeTabIndex {
                activeTabIndex -= 1
            }
            updateUIState()
            persistCurrentSession()
        }
    }

    private func closeAllTabs() {
        resetProgress()
        for tab in tabs {
            tab.destroy()
        }
        tabs.removeAll()
        activeTabIndex = 0
        createNewTab(loadURL: nil)
    }

    private func bindProgressObservation(to webView: WKWebView) {
        progressObservation?.invalidate()

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] observedWebView, _ in
            DispatchQueue.main.async {
                guard let self = self,
                      observedWebView == self.activeTab.webView,
                      observedWebView.isLoading,
                      self.homeView.alpha < 0.5,
                      !self.activeTab.isDisplayingFailurePage else {
                    self?.resetProgress()
                    return
                }

                self.progressView.alpha = 1
                self.progressView.setProgress(Float(observedWebView.estimatedProgress), animated: true)
            }
        }
    }

    private func load(url: URL) {
        showBrowserUI()

        activeTab.url = url
        activeTab.title = url.host ?? url.absoluteString

        addressField.text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        activeTab.webView.load(URLRequest(url: url))

        persistCurrentSession()
    }

    private func showHomeUI() {
        homeView.alpha = 1
        webContainer.alpha = 0
        failureOverlayView.isHidden = true
        addressField.text = ""
        addressField.resignFirstResponder()
        resetProgress()
        updateUIState()
    }

    private func showBrowserUI() {
        homeView.alpha = 0
        webContainer.alpha = 1
        failureOverlayView.isHidden = true
        updateUIState()
    }

    private func showFailureUI(for tab: TabItem) {
        homeView.alpha = 0
        webContainer.alpha = 1
        failureOverlayView.isHidden = false
        let targetURL = tab.failedURL ?? tab.url
        failureURLLabel.text = targetURL?.absoluteString.removingPercentEncoding ?? targetURL?.absoluteString ?? ""
        if let err = tab.failureError as NSError? {
            failureTitleLabel.text = "无法连接至网页"
            failureReasonLabel.text = err.localizedDescription
        }
        let hostStr = targetURL?.host?.removingPercentEncoding ?? targetURL?.host ?? (targetURL?.absoluteString.removingPercentEncoding ?? targetURL?.absoluteString ?? "")
        addressField.text = hostStr
        resetProgress()
        updateUIState()
    }

    private func updateUIState() {
        guard !tabs.isEmpty else {
            return
        }

        let isHome = homeView.alpha > 0.5

        let canGoBack = activeTab.webView.canGoBack || activeTab.isDisplayingFailurePage || activeTab.sourceTabID != nil || activeTab.previousURL != nil
        backButton.isEnabled = !isHome && canGoBack
        forwardButton.isEnabled = !isHome && activeTab.webView.canGoForward
        moreButton.isEnabled = true
        refreshButton.isEnabled = !isHome

        tabsCountBadge.text = "\(tabs.count)"

        let refreshImage = activeTab.isLoading ? "xmark" : "arrow.clockwise"

        refreshButton.setImage(
            UIImage(
                systemName: refreshImage,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            ),
            for: .normal
        )
    }

    private func destinationURL(from input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        SearchHistoryStore.shared.addHistory(value)

        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            if let url = URL(string: value) {
                return url
            }
            if let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: encoded) {
                return url
            }
            return nil
        }

        if value.contains(".") && !value.contains(" ") {
            let prefixed = "https://" + value
            if let url = URL(string: prefixed) {
                return url
            }
            if let encoded = prefixed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: encoded) {
                return url
            }
        }

        return SearchEngineStore.shared.currentEngine.searchURL(query: value)
    }

    private func setFullscreen(_ enabled: Bool) {
        guard isFullscreen != enabled else {
            return
        }

        dismissKeyboard()

        isFullscreen = enabled
        bottomPanel.isHidden = enabled

        webTopSafeConstraint?.isActive = !enabled
        webTopFullscreenConstraint?.isActive = enabled
        webBottomPanelConstraint?.isActive = !enabled
        webBottomFullscreenConstraint?.isActive = enabled

        UIView.animate(withDuration: 0.2) {
            self.view.layoutIfNeeded()
        }

        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        updateUIState()
    }

    private func updateAddressEditingAppearance() {
        let editing = addressField.isFirstResponder

        refreshButton.isHidden = editing
        clearButton.isHidden = !editing

        UIView.animate(withDuration: 0.12) {
            self.refreshButton.alpha = editing ? 0 : 1
            self.clearButton.alpha = editing ? 1 : 0
        }
    }

    func tabRequestNewTab(url: URL) {
        createNewTab(loadURL: url, sourceID: activeTab.id)
    }

    func tabRequestGoBack(_ tab: TabItem) {
        goBack()
    }

    func tabProcessTerminated(_ tab: TabItem) {
        guard !tabs.isEmpty, tab.id == activeTab.id else { return }
        resetProgress()
        activeTab.webView.reload()
    }

    func tabDidUpdate(_ tab: TabItem) {
        guard !tabs.isEmpty, tab.id == activeTab.id else {
            persistCurrentSession()
            return
        }

        if !tab.isDisplayingFailurePage {
            failureOverlayView.isHidden = true
            if let url = tab.url, !addressField.isFirstResponder {
                let rawString = url.absoluteString.removingPercentEncoding ?? url.absoluteString
                let hostString = url.host?.removingPercentEncoding ?? url.host ?? rawString
                addressField.text = hostString
            }
        }

        if !tab.isLoading {
            resetProgress()

            if !tab.isDisplayingFailurePage,
               let url = tab.url {
                BrowserHistoryStore.shared.record(
                    url: url,
                    title: tab.title
                )
            }
        }

        updateUIState()
        persistCurrentSession()
    }

    func tabDidFail(_ tab: TabItem, error: Error) {
        guard !tabs.isEmpty, tab.id == activeTab.id else {
            return
        }

        showFailureUI(for: tab)
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        if let url = activeTab.url {
            textField.text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        }

        navigationStack.isHidden = true
        updateAddressEditingAppearance()

        editingDimmingView.isHidden = false
        UIView.animate(withDuration: 0.2) {
            self.editingDimmingView.alpha = 1
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if let url = activeTab.url {
            let rawString = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            textField.text = url.host?.removingPercentEncoding ?? url.host ?? rawString
        } else if textField.text?.isEmpty == true {
            textField.text = ""
        }

        navigationStack.isHidden = false
        updateAddressEditingAppearance()

        UIView.animate(withDuration: 0.2, animations: {
            self.editingDimmingView.alpha = 0
        }) { _ in
            self.editingDimmingView.isHidden = true
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let text = textField.text, let url = destinationURL(from: text) else {
            return true
        }

        textField.resignFirstResponder()
        load(url: url)

        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.view?.isDescendant(of: addressContainer) == true {
            return false
        }

        return true
    }

    @objc private func addressFieldDidChange() {
        updateAddressEditingAppearance()
    }

    @objc private func clearAddressInput() {
        addressField.text = ""
        addressField.becomeFirstResponder()
        updateAddressEditingAppearance()
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard addressField.isFirstResponder else {
            if bottomPanelBottomConstraint?.constant != 0 {
                bottomPanelBottomConstraint?.constant = 0
                view.layoutIfNeeded()
            }
            return
        }

        guard !isFullscreen,
              let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval else {
            return
        }

        let frameInView = view.convert(keyboardFrame, from: nil)
        let overlap = max(0, view.bounds.maxY - frameInView.minY)
        let curve = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        let options = UIView.AnimationOptions(rawValue: curve << 16)

        bottomPanelBottomConstraint?.constant = -overlap

        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.view.layoutIfNeeded()
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval else {
            bottomPanelBottomConstraint?.constant = 0
            view.layoutIfNeeded()
            return
        }

        let curve = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        let options = UIView.AnimationOptions(rawValue: curve << 16)

        bottomPanelBottomConstraint?.constant = 0

        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.view.layoutIfNeeded()
        }
    }

    @objc private func handleFullscreenExitGesture(_ gesture: UILongPressGestureRecognizer) {
        guard isFullscreen, gesture.state == .began else {
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        setFullscreen(false)
    }

    @objc private func handleRefreshTap() {
        guard homeView.alpha < 0.5 else {
            return
        }

        if activeTab.isDisplayingFailurePage {
            guard let targetURL = activeTab.failedURL else { return }
            activeTab.isDisplayingFailurePage = false
            failureOverlayView.isHidden = true
            activeTab.webView.load(URLRequest(url: targetURL))
            updateUIState()
            return
        }

        if activeTab.isLoading {
            activeTab.webView.stopLoading()
        } else {
            activeTab.webView.reload()
        }

        updateUIState()
    }

    @objc private func goBack() {
        if activeTab.isDisplayingFailurePage {
            let originURL = activeTab.failureOriginURL
            let sourceID = activeTab.sourceTabID

            activeTab.clearFailureState()
            failureOverlayView.isHidden = true

            if activeTab.webView.canGoBack {
                activeTab.webView.goBack()
                updateUIState()
                return
            }

            if let originURL = originURL {
                load(url: originURL)
                return
            }

            if let sourceID = sourceID,
               tabs.contains(where: { $0.id == sourceID }) {
                let closingIndex = activeTabIndex
                closeTab(at: closingIndex)
                return
            }

            showHomeUI()
            return
        }

        if activeTab.webView.canGoBack {
            activeTab.webView.goBack()
        } else if let sourceID = activeTab.sourceTabID, tabs.contains(where: { $0.id == sourceID }) {
            let closingIndex = activeTabIndex
            closeTab(at: closingIndex)
        } else if let prevURL = activeTab.previousURL, prevURL != activeTab.url {
            load(url: prevURL)
        } else if tabs.count > 1 {
            closeTab(at: activeTabIndex)
        } else {
            showHomeUI()
        }
    }

    @objc private func goForward() {
        activeTab.webView.goForward()
    }

    @objc private func showSiteDomainSettings() {
        dismissKeyboard()
        guard let host = activeTab.url?.host else { return }

        let settingsVC = DomainSettingsViewController(domain: host) { [weak self] in
            guard let self = self else { return }
            self.activeTab.reloadUserScripts()
            AdBlockManager.shared.applyRules(to: self.activeTab.webView)
        }
        settingsVC.onExtractText = { [weak self] in
            self?.extractPageText()
        }

        let nav = UINavigationController(rootViewController: settingsVC)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    private func extractPageText() {
        activeTab.webView.evaluateJavaScript("document.body.innerText") { [weak self] result, error in
            guard let self = self else { return }
            guard let text = result as? String, !text.isEmpty else { return }
            let vc = UIViewController()
            vc.title = "网页正文内容"
            vc.view.backgroundColor = .systemBackground

            let textView = UITextView()
            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.font = .systemFont(ofSize: 15)
            textView.isEditable = false
            textView.text = text

            vc.view.addSubview(textView)
            NSLayoutConstraint.activate([
                textView.topAnchor.constraint(equalTo: vc.view.topAnchor),
                textView.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
                textView.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor)
            ])

            vc.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(self.dismissModalVC))
            let nav = UINavigationController(rootViewController: vc)
            self.present(nav, animated: true)
        }
    }

    @objc private func dismissModalVC() {
        dismiss(animated: true)
    }

    @objc private func showPluginPanel() {
        dismissKeyboard()
        let currentUrlStr = activeTab.url?.absoluteString ?? ""
        let currentHost = activeTab.url?.host ?? ""
        let matchingScripts = UserScriptStore.shared.loadScripts().filter {
            UserScriptStore.shared.isScriptMatching(script: $0, urlString: currentUrlStr)
        }

        var items: [CustomBottomSheetItem] = []

        if matchingScripts.isEmpty {
            items.append(CustomBottomSheetItem(
                title: "未匹配到脚本",
                iconName: "info.circle",
                handler: nil
            ))
        } else {
            for script in matchingScripts {
                items.append(CustomBottomSheetItem(
                    title: script.name,
                    iconName: "chevron.left.forwardslash.chevron.right",
                    handler: { [weak self] in
                        self?.showScriptSubMenu(for: script)
                    }
                ))
            }
        }

        items.append(CustomBottomSheetItem(
            title: "搜索适合当前网站的脚本",
            iconName: "magnifyingglass",
            handler: { [weak self] in
                let searchUrlStr = "https://greasyfork.org/zh-CN/scripts?q=\(currentHost)"
                if let searchUrl = URL(string: searchUrlStr) {
                    self?.load(url: searchUrl)
                }
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "用户脚本管理",
            iconName: "slider.horizontal.3",
            handler: { [weak self] in
                self?.showPluginManager()
            }
        ))

        let panel = CustomBottomSheetViewController(title: "正在运行的脚本", items: items, layout: .list)
        if #available(iOS 15.0, *) {
            if let presentation = panel.sheetPresentationController {
                presentation.detents = [.medium(), .large()]
                presentation.prefersGrabberVisible = true
                presentation.preferredCornerRadius = 24
            }
        }
        present(panel, animated: true)
    }

    private func showScriptSubMenu(for script: UserScript) {
        var items: [CustomBottomSheetItem] = []

        let scriptCmds = activeTab.registeredCommands.filter { $0.scriptId == script.id }
        for cmd in scriptCmds {
            items.append(CustomBottomSheetItem(
                title: cmd.caption,
                iconName: "command",
                handler: { [weak self] in
                    self?.activeTab.webView.evaluateJavaScript("window.__gm_invokeMenuCommand(\(cmd.cmdId))", completionHandler: nil)
                }
            ))
        }

        items.append(CustomBottomSheetItem(
            title: script.isEnabled ? "禁用该脚本" : "启用该脚本",
            iconName: script.isEnabled ? "power.circle" : "checkmark.circle",
            handler: { [weak self] in
                var scripts = UserScriptStore.shared.loadScripts()
                if let idx = scripts.firstIndex(where: { $0.id == script.id }) {
                    scripts[idx].isEnabled = !script.isEnabled
                    UserScriptStore.shared.saveScripts(scripts)
                    self?.activeTab.reloadUserScripts()
                }
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "清除脚本缓存数据",
            iconName: "trash",
            isDestructive: false,
            handler: {
                ScriptDataStore.shared.clearDataForScript(scriptId: script.id)
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "编辑脚本代码",
            iconName: "pencil.and.outline",
            handler: { [weak self] in
                let editor = UserScriptEditorViewController(script: script)
                editor.onSave = { updatedScript in
                    var scripts = UserScriptStore.shared.loadScripts()
                    if let idx = scripts.firstIndex(where: { $0.id == updatedScript.id }) {
                        scripts[idx] = updatedScript
                        UserScriptStore.shared.saveScripts(scripts)
                        self?.activeTab.reloadUserScripts()
                    }
                }
                let nav = UINavigationController(rootViewController: editor)
                self?.present(nav, animated: true)
            }
        ))

        let panel = CustomBottomSheetViewController(title: script.name, items: items, layout: .list)
        if #available(iOS 15.0, *) {
            if let presentation = panel.sheetPresentationController {
                presentation.detents = [.medium(), .large()]
                presentation.prefersGrabberVisible = true
                presentation.preferredCornerRadius = 24
            }
        }
        present(panel, animated: true)
    }

    @objc private func showPluginManager() {
        dismissKeyboard()
        let manager = UserScriptManagerViewController()
        manager.onScriptsUpdated = { [weak self] in
            self?.activeTab.reloadUserScripts()
        }
        let nav = UINavigationController(rootViewController: manager)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    @objc private func showTabsManager() {
        dismissKeyboard()

        activeTab.updateSnapshot { [weak self] in
            guard let self = self else {
                return
            }

            let manager = TabGridViewController(
                tabs: self.tabs,
                activeIndex: self.activeTabIndex
            )

            manager.onSelectTab = { [weak self] index in
                self?.switchTab(to: index)
            }

            manager.onCloseTab = { [weak self] index in
                self?.closeTab(at: index)
            }

            manager.onClearAllTabs = { [weak self] in
                self?.closeAllTabs()
            }

            manager.onNewTab = { [weak self] in
                self?.createNewTab(loadURL: nil)
            }

            let navigationController = UINavigationController(rootViewController: manager)
            navigationController.modalPresentationStyle = .pageSheet
            self.present(navigationController, animated: true)
        }
    }

    private func showEyeProtectionLevelPicker() {
        let alert = UIAlertController(title: "护眼模式强度", message: nil, preferredStyle: .actionSheet)

        for level in EyeProtectionManager.Level.allCases {
            alert.addAction(UIAlertAction(title: level.title, style: .default) { [weak self] _ in
                EyeProtectionManager.shared.setLevel(level, in: self?.view.window)
            })
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showSearchEnginePicker() {
        let alert = UIAlertController(title: "选择默认搜索引擎", message: nil, preferredStyle: .actionSheet)
        for engine in SearchEngine.allCases {
            let isCurrent = engine == SearchEngineStore.shared.currentEngine
            let title = isCurrent ? "\(engine.name) ✓" : engine.name
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                SearchEngineStore.shared.currentEngine = engine
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showAdBlockerManager() {
        let manager = AdBlockManagerViewController()
        manager.onRulesChanged = { [weak self] in
            self?.showToastNotice("规则已应用，刷新页面后生效")
        }
        let nav = UINavigationController(rootViewController: manager)
        present(nav, animated: true)
    }

    @objc private func showMoreMenu() {
        dismissKeyboard()

        var items: [CustomBottomSheetItem] = []

        items.append(CustomBottomSheetItem(
            title: isFullscreen ? "退出全屏" : "全屏浏览",
            iconName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            handler: { [weak self] in
                guard let self = self else { return }
                self.setFullscreen(!self.isFullscreen)
            }
        ))

        let isEyeOn = EyeProtectionManager.shared.isEnabled
        items.append(CustomBottomSheetItem(
            title: isEyeOn ? "关闭护眼" : "护眼模式",
            iconName: "eye.fill",
            handler: { [weak self] in
                EyeProtectionManager.shared.toggle(in: self?.view.window)
            },
            longPressHandler: { [weak self] in
                self?.showEyeProtectionLevelPicker()
            }
        ))

        let isAdBlockOn = AdBlockManager.shared.isEnabled
        items.append(CustomBottomSheetItem(
            title: isAdBlockOn ? "拦截: 开启" : "拦截: 关闭",
            iconName: isAdBlockOn ? "shield.fill" : "shield.slash.fill",
            handler: { [weak self] in
                self?.showAdBlockerManager()
            }
        ))

        let currentEngine = SearchEngineStore.shared.currentEngine
        items.append(CustomBottomSheetItem(
            title: "\(currentEngine.name) 搜索",
            iconName: "magnifyingglass",
            handler: { [weak self] in
                self?.showSearchEnginePicker()
            }
        ))

        let currentUAItem = UserAgentStore.shared.getSelectedItem()
        items.append(CustomBottomSheetItem(
            title: "标识: \(currentUAItem.name)",
            iconName: "person.crop.square",
            handler: { [weak self] in
                self?.showUserAgentManager()
            }
        ))

        let isDesktop = UserAgentStore.shared.currentMode == .desktop
        items.append(CustomBottomSheetItem(
            title: isDesktop ? "移动版排版" : "电脑版排版",
            iconName: isDesktop ? "iphone" : "desktopcomputer",
            handler: { [weak self] in
                guard let self = self else { return }
                let newMode: UserAgentCategory = isDesktop ? .mobile : .desktop
                UserAgentStore.shared.currentMode = newMode
                let newUA = UserAgentStore.shared.getSelectedUA()
                self.activeTab.webView.customUserAgent = newUA
                self.activeTab.webView.configuration.defaultWebpagePreferences.preferredContentMode = (newMode == .desktop) ? .desktop : .mobile
                self.activeTab.reloadUserScripts()
                self.activeTab.webView.reloadFromOrigin()
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "历史记录",
            iconName: "clock.arrow.circlepath",
            handler: { [weak self] in
                self?.showBrowserHistory()
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "清理网站数据",
            iconName: "trash.circle",
            isDestructive: false,
            handler: { [weak self] in
                self?.showCleanDataMenu()
            }
        ))

        let panel = CustomBottomSheetViewController(title: "浏览器选项", items: items, layout: .grid)
        if #available(iOS 15.0, *) {
            if let presentation = panel.sheetPresentationController {
                presentation.detents = [.medium(), .large()]
                presentation.prefersGrabberVisible = true
                presentation.preferredCornerRadius = 24
            }
        }
        present(panel, animated: true)
    }

    private func showBrowserHistory() {
        dismissKeyboard()

        let historyVC = BrowserHistoryViewController()

        historyVC.onSelectURL = { [weak self] url in
            self?.load(url: url)
        }

        let navigationController = UINavigationController(
            rootViewController: historyVC
        )

        navigationController.modalPresentationStyle = .pageSheet
        present(navigationController, animated: true)
    }

    private func showUserAgentManager() {
        let manager = UserAgentManagerViewController()
        manager.onUASelected = { [weak self] item in
            guard let self = self else { return }
            let isDesktop = UserAgentStore.shared.currentMode == .desktop
            self.activeTab.webView.customUserAgent = UserAgentStore.shared.getSelectedUA()
            self.activeTab.webView.configuration.defaultWebpagePreferences.preferredContentMode = isDesktop ? .desktop : .mobile
            self.activeTab.reloadUserScripts()
            self.activeTab.webView.reloadFromOrigin()
        }
        let nav = UINavigationController(rootViewController: manager)
        present(nav, animated: true)
    }

    private func showCleanDataMenu() {
        let cleanVC = CleanDataSelectionViewController()
        cleanVC.onConfirmClean = { [weak self] options, completion in
            guard let self = self else {
                completion()
                return
            }
            self.performCleanData(options: options, completion: completion)
        }
        cleanVC.onOpenWebsiteDataManager = { [weak self] in
            let manager = WebsiteDataManagerViewController()
            let nav = UINavigationController(rootViewController: manager)
            self?.present(nav, animated: true)
        }
        let nav = UINavigationController(rootViewController: cleanVC)
        present(nav, animated: true)
    }

    private func performCleanData(options: Set<CleanOption>, completion: @escaping () -> Void) {
        let group = DispatchGroup()

        if options.contains(.cache) {
            group.enter()
            WebsiteCleaner.shared.cleanCacheOnly {
                group.leave()
            }
        }

        if options.contains(.loginAndData) {
            group.enter()
            WebsiteCleaner.shared.cleanUnprotectedLoginAndData {
                group.leave()
            }
        }

        if options.contains(.searchHistory) {
            SearchHistoryStore.shared.clearHistory()
            BrowserHistoryStore.shared.clearHistory()
        }

        if options.contains(.scriptData) {
            ScriptDataStore.shared.clearAllScriptData()
        }

        group.notify(queue: .main) { [weak self] in
            self?.activeTab.webView.reload()
            completion()
        }
    }
}
