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

private struct HomeShortcut {
    let title: String
    let urlString: String
    let iconName: String
    let iconColor: UIColor
}

final class BrowserViewController: UIViewController, UITextFieldDelegate, TabItemDelegate, UIGestureRecognizerDelegate {
    private var tabs: [TabItem] = []
    private var activeTabIndex = 0
    private var isFullscreen = false
    private var progressObservation: NSKeyValueObservation?

    private var activeTab: TabItem {
        if tabs.indices.contains(activeTabIndex) {
            return tabs[activeTabIndex]
        }
        if let first = tabs.first {
            return first
        }
        let fallback = TabItem()
        fallback.delegate = self
        tabs.append(fallback)
        activeTabIndex = 0
        return fallback
    }

    private let webContainer = UIView()
    private let homeView = UIView()
    private let homeScrollView = UIScrollView()
    private let homeSearchContainer = UIView()
    private let homeSearchField = AddressTextField()

    private let failureOverlayView = UIView()
    private let failureTitleLabel = UILabel()
    private let failureReasonLabel = UILabel()
    private let failureURLLabel = UILabel()
    private let failureBackButton = TouchButton()
    private let failureReloadButton = TouchButton()

    private let editingDimmingView = UIView()

    private let bottomPanel = UIView()
    private let addressContainer = UIView()
    private let addressContentView = UIView()
    private let lockButton = TouchButton()
    private let addressField = AddressTextField()
    private let clearButton = TouchButton()
    private let reloadButton = TouchButton()
    private let progressView = UIProgressView(progressViewStyle: .default)

    private let navigationStack = UIStackView()
    private let backButton = TouchButton()
    private let forwardButton = TouchButton()
    private let pluginButton = TouchButton()
    private let tabsButton = TouchButton()
    private let moreButton = TouchButton()

    private var bottomPanelBottomConstraint: NSLayoutConstraint?
    private var webTopSafeConstraint: NSLayoutConstraint?
    private var webTopFullscreenConstraint: NSLayoutConstraint?
    private var webBottomPanelConstraint: NSLayoutConstraint?
    private var webBottomFullscreenConstraint: NSLayoutConstraint?

    private let homeShortcuts: [HomeShortcut] = [
        HomeShortcut(title: "百度", urlString: "https://www.baidu.com", iconName: "magnifyingglass", iconColor: .systemBlue),
        HomeShortcut(title: "必应", urlString: "https://www.bing.com", iconName: "globe.asia.australia.fill", iconColor: .systemTeal),
        HomeShortcut(title: "GitHub", urlString: "https://github.com", iconName: "chevron.left.forwardslash.chevron.right", iconColor: .label),
        HomeShortcut(title: "哔哩哔哩", urlString: "https://www.bilibili.com", iconName: "play.tv.fill", iconColor: .systemPink),
        HomeShortcut(title: "知乎", urlString: "https://www.zhihu.com", iconName: "text.book.closed.fill", iconColor: .systemCyan),
        HomeShortcut(title: "掘金", urlString: "https://juejin.cn", iconName: "flame.fill", iconColor: .systemOrange),
        HomeShortcut(title: "维基百科", urlString: "https://zh.wikipedia.org", iconName: "character.book.closed.fill", iconColor: .systemIndigo),
        HomeShortcut(title: "V2EX", urlString: "https://www.v2ex.com", iconName: "bubble.left.and.bubble.right.fill", iconColor: .systemGreen)
    ]

    private var gentleToolbarIconColor: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.86, alpha: 1.0) : UIColor(red: 0.28, green: 0.28, blue: 0.31, alpha: 1.0)
        }
    }

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
        let strokeColor = gentleToolbarIconColor.resolvedColor(with: traitCollection)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setLineWidth(1.8)
            cg.setLineCap(.round)
            cg.setStrokeColor(strokeColor.cgColor)

            let yOffsets: [CGFloat] = [2.0, 9.0, 16.0]
            for y in yOffsets {
                cg.move(to: CGPoint(x: 1.5, y: y))
                cg.addLine(to: CGPoint(x: 18.5, y: y))
            }
            cg.strokePath()
        }
        return img.withRenderingMode(.alwaysTemplate)
    }

    private func makeAddBookmarkIcon() -> UIImage {
        let size = CGSize(width: 24, height: 24)
        let renderer = UIGraphicsImageRenderer(size: size)
        let strokeColor = gentleToolbarIconColor.resolvedColor(with: traitCollection)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setStrokeColor(strokeColor.cgColor)
            cg.setFillColor(strokeColor.cgColor)

            if let star = UIImage(systemName: "star", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)) {
                star.draw(in: CGRect(x: 0.5, y: 0.5, width: 19, height: 19))
            }

            cg.setBlendMode(.clear)
            cg.fillEllipse(in: CGRect(x: 12, y: 12, width: 12, height: 12))

            cg.setBlendMode(.normal)
            cg.setLineWidth(1.4)
            cg.strokeEllipse(in: CGRect(x: 13, y: 13, width: 10, height: 10))

            cg.setLineWidth(1.3)
            cg.setLineCap(.round)
            cg.move(to: CGPoint(x: 15.5, y: 18))
            cg.addLine(to: CGPoint(x: 20.5, y: 18))
            cg.move(to: CGPoint(x: 18, y: 15.5))
            cg.addLine(to: CGPoint(x: 18, y: 20.5))
            cg.strokePath()
        }
        return img.withRenderingMode(.alwaysTemplate)
    }

    private func configureHomeView() {
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

        let row1 = UIStackView()
        row1.axis = .horizontal
        row1.distribution = .fillEqually
        row1.spacing = 10

        let row2 = UIStackView()
        row2.axis = .horizontal
        row2.distribution = .fillEqually
        row2.spacing = 10

        for idx in 0..<4 {
            row1.addArrangedSubview(createShortcutButton(shortcut: homeShortcuts[idx], index: idx))
        }
        for idx in 4..<8 {
            row2.addArrangedSubview(createShortcutButton(shortcut: homeShortcuts[idx], index: idx))
        }

        let shortcutsStack = UIStackView(arrangedSubviews: [row1, row2])
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
    }

    private func createShortcutButton(shortcut: HomeShortcut, index: Int) -> TouchButton {
        let button = TouchButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tag = index
        button.addTarget(self, action: #selector(handleShortcutTap(_:)), for: .touchUpInside)

        let iconContainer = UIView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 1.0) : UIColor.white
        }
        iconContainer.layer.cornerRadius = 16
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.layer.borderWidth = 0
        iconContainer.layer.shadowColor = UIColor.black.cgColor
        iconContainer.layer.shadowOpacity = 0.03
        iconContainer.layer.shadowRadius = 4
        iconContainer.layer.shadowOffset = CGSize(width: 0, height: 2)
        iconContainer.isUserInteractionEnabled = false

        let iconImageView = UIImageView()
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.image = UIImage(
            systemName: shortcut.iconName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        )
        iconImageView.tintColor = shortcut.iconColor
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.isUserInteractionEnabled = false
        iconContainer.addSubview(iconImageView)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = shortcut.title
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.88, alpha: 1.0) : UIColor(red: 0.28, green: 0.28, blue: 0.31, alpha: 1.0)
        }
        label.textAlignment = .center
        label.isUserInteractionEnabled = false

        button.addSubview(iconContainer)
        button.addSubview(label)

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 76),

            iconContainer.topAnchor.constraint(equalTo: button.topAnchor),
            iconContainer.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 52),
            iconContainer.heightAnchor.constraint(equalToConstant: 52),

            iconImageView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 24),
            iconImageView.heightAnchor.constraint(equalToConstant: 24),

            label.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            label.bottomAnchor.constraint(lessThanOrEqualTo: button.bottomAnchor)
        ])

        return button
    }

    @objc private func handleShortcutTap(_ sender: UIButton) {
        let index = sender.tag
        guard homeShortcuts.indices.contains(index),
              let url = URL(string: homeShortcuts[index].urlString) else { return }
        load(url: url)
    }

    private func configureFailureView() {
        failureOverlayView.translatesAutoresizingMaskIntoConstraints = false
        failureOverlayView.backgroundColor = .systemBackground
        failureOverlayView.isHidden = true

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 0
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.05
        card.layer.shadowRadius = 16
        card.layer.shadowOffset = CGSize(width: 0, height: 4)

        let iconContainer = UIView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
        iconContainer.layer.cornerRadius = 26
        iconContainer.layer.cornerCurve = .continuous

        let failureIconView = UIImageView()
        failureIconView.translatesAutoresizingMaskIntoConstraints = false
        failureIconView.image = UIImage(
            systemName: "wifi.exclamationmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        )
        failureIconView.tintColor = .systemRed
        failureIconView.contentMode = .scaleAspectFit
        iconContainer.addSubview(failureIconView)

        failureTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        failureTitleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        failureTitleLabel.textColor = .label
        failureTitleLabel.textAlignment = .center
        failureTitleLabel.text = "无法打开网页"

        failureReasonLabel.translatesAutoresizingMaskIntoConstraints = false
        failureReasonLabel.font = .systemFont(ofSize: 13, weight: .regular)
        failureReasonLabel.textColor = .secondaryLabel
        failureReasonLabel.textAlignment = .center
        failureReasonLabel.numberOfLines = 0
        failureReasonLabel.text = "请检查网络连接或网址输入后重试。"

        failureURLLabel.translatesAutoresizingMaskIntoConstraints = false
        failureURLLabel.font = .systemFont(ofSize: 11, weight: .regular)
        failureURLLabel.textColor = .tertiaryLabel
        failureURLLabel.textAlignment = .center
        failureURLLabel.numberOfLines = 2

        failureBackButton.translatesAutoresizingMaskIntoConstraints = false
        var backConfig = UIButton.Configuration.gray()
        backConfig.title = "返回"
        backConfig.cornerStyle = .capsule
        backConfig.baseForegroundColor = .label
        failureBackButton.configuration = backConfig
        failureBackButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)

        failureReloadButton.translatesAutoresizingMaskIntoConstraints = false
        var reloadConfig = UIButton.Configuration.filled()
        reloadConfig.title = "重新加载"
        reloadConfig.cornerStyle = .capsule
        reloadConfig.baseBackgroundColor = .systemBlue
        reloadConfig.baseForegroundColor = .white
        failureReloadButton.configuration = reloadConfig
        failureReloadButton.addTarget(self, action: #selector(handleFailureReload), for: .touchUpInside)

        let failureButtons = UIStackView(arrangedSubviews: [failureBackButton, failureReloadButton])
        failureButtons.translatesAutoresizingMaskIntoConstraints = false
        failureButtons.axis = .horizontal
        failureButtons.spacing = 10
        failureButtons.distribution = .fillEqually

        let failureStack = UIStackView(arrangedSubviews: [
            iconContainer,
            failureTitleLabel,
            failureReasonLabel,
            failureURLLabel,
            failureButtons
        ])
        failureStack.translatesAutoresizingMaskIntoConstraints = false
        failureStack.axis = .vertical
        failureStack.alignment = .fill
        failureStack.spacing = 10
        failureStack.setCustomSpacing(18, after: failureURLLabel)

        card.addSubview(failureStack)
        failureOverlayView.addSubview(card)

        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 52),
            iconContainer.heightAnchor.constraint(equalToConstant: 52),

            failureIconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            failureIconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            failureIconView.widthAnchor.constraint(equalToConstant: 26),
            failureIconView.heightAnchor.constraint(equalToConstant: 26),

            failureButtons.heightAnchor.constraint(equalToConstant: 40),

            failureStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            failureStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            failureStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            failureStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),

            card.leadingAnchor.constraint(equalTo: failureOverlayView.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: failureOverlayView.trailingAnchor, constant: -24),
            card.centerYAnchor.constraint(equalTo: failureOverlayView.centerYAnchor, constant: -30)
        ])
    }

    private func configureInterface() {
        let pageBackground = UIColor.systemBackground

        view.backgroundColor = pageBackground

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.backgroundColor = pageBackground

        homeView.translatesAutoresizingMaskIntoConstraints = false
        homeView.backgroundColor = pageBackground

        configureFailureView()

        editingDimmingView.translatesAutoresizingMaskIntoConstraints = false
        editingDimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        editingDimmingView.alpha = 0
        editingDimmingView.isHidden = true

        let dimmingTap = UITapGestureRecognizer(
            target: self,
            action: #selector(dismissKeyboard)
        )
        editingDimmingView.addGestureRecognizer(dimmingTap)

        bottomPanel.translatesAutoresizingMaskIntoConstraints = false
        bottomPanel.backgroundColor = .clear
        bottomPanel.clipsToBounds = false

        let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blurView.translatesAutoresizingMaskIntoConstraints = false
        bottomPanel.addSubview(blurView)

        addressContainer.translatesAutoresizingMaskIntoConstraints = false
        addressContainer.backgroundColor = .clear
        addressContainer.layer.shadowColor = UIColor.black.cgColor
        addressContainer.layer.shadowOpacity = 0.04
        addressContainer.layer.shadowRadius = 8
        addressContainer.layer.shadowOffset = CGSize(width: 0, height: 2)
        addressContainer.clipsToBounds = false

        addressContentView.translatesAutoresizingMaskIntoConstraints = false
        addressContentView.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 1.0) : UIColor.white
        }
        addressContentView.layer.cornerRadius = 22
        addressContentView.layer.cornerCurve = .continuous
        addressContentView.clipsToBounds = true

        lockButton.translatesAutoresizingMaskIntoConstraints = false
        lockButton.tintColor = UIColor(red: 0.48, green: 0.48, blue: 0.51, alpha: 1.0)
        lockButton.setImage(
            UIImage(
                systemName: "lock.fill",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 12,
                    weight: .medium
                )
            ),
            for: .normal
        )
        lockButton.hitTestInsets = UIEdgeInsets(top: -10, left: -10, bottom: -10, right: -10)
        lockButton.addTarget(
            self,
            action: #selector(showSiteDomainSettings),
            for: .touchUpInside
        )

        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.delegate = self
        addressField.placeholder = "搜索或输入网址"
        addressField.font = .systemFont(ofSize: 14.5, weight: .regular)
        addressField.textColor = .label
        addressField.textAlignment = .left
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.clearButtonMode = .never
        addressField.textContentType = .URL
        addressField.addTarget(
            self,
            action: #selector(addressFieldDidChange),
            for: .editingChanged
        )

        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        reloadButton.tintColor = UIColor(red: 0.48, green: 0.48, blue: 0.51, alpha: 1.0)
        reloadButton.setImage(
            UIImage(
                systemName: "arrow.clockwise",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 13.5,
                    weight: .medium
                )
            ),
            for: .normal
        )
        reloadButton.hitTestInsets = UIEdgeInsets(top: -8, left: -8, bottom: -8, right: -8)
        reloadButton.addTarget(
            self,
            action: #selector(handleAddressReload),
            for: .touchUpInside
        )

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.tintColor = UIColor(red: 0.48, green: 0.48, blue: 0.51, alpha: 1.0)
        clearButton.setImage(
            UIImage(
                systemName: "xmark.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 15,
                    weight: .medium
                )
            ),
            for: .normal
        )
        clearButton.hitTestInsets = UIEdgeInsets(top: -8, left: -8, bottom: -8, right: -8)
        clearButton.alpha = 0
        clearButton.isHidden = true
        clearButton.addTarget(
            self,
            action: #selector(clearAddressInput),
            for: .touchUpInside
        )

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = .systemBlue
        progressView.trackTintColor = .clear
        progressView.progress = 0
        progressView.alpha = 0
        progressView.clipsToBounds = true

        navigationStack.translatesAutoresizingMaskIntoConstraints = false
        navigationStack.axis = .horizontal
        navigationStack.alignment = .fill
        navigationStack.distribution = .fillEqually
        navigationStack.spacing = 2

        configureToolbarButton(
            backButton,
            imageName: "chevron.backward",
            action: #selector(goBack)
        )
        configureToolbarButton(
            forwardButton,
            imageName: "chevron.forward",
            action: #selector(goForward)
        )
        configureToolbarButton(
            moreButton,
            imageName: "line.3.horizontal",
            action: #selector(showMoreMenu)
        )
        configureToolbarButton(
            tabsButton,
            imageName: "square.on.square",
            action: #selector(showTabsManager)
        )
        configureToolbarButton(
            pluginButton,
            imageName: "puzzlepiece.extension",
            action: #selector(showPluginPanel)
        )

        let longPressMore = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleMoreButtonLongPress(_:))
        )
        longPressMore.minimumPressDuration = 0.45
        moreButton.addGestureRecognizer(longPressMore)

        navigationStack.addArrangedSubview(backButton)
        navigationStack.addArrangedSubview(forwardButton)
        navigationStack.addArrangedSubview(moreButton)
        navigationStack.addArrangedSubview(tabsButton)
        navigationStack.addArrangedSubview(pluginButton)

        addressContainer.addSubview(addressContentView)
        addressContentView.addSubview(lockButton)
        addressContentView.addSubview(addressField)
        addressContentView.addSubview(reloadButton)
        addressContentView.addSubview(clearButton)
        addressContentView.addSubview(progressView)

        bottomPanel.addSubview(addressContainer)
        bottomPanel.addSubview(navigationStack)

        view.addSubview(webContainer)
        view.addSubview(homeView)
        view.addSubview(failureOverlayView)
        view.addSubview(editingDimmingView)
        view.addSubview(bottomPanel)

        bottomPanelBottomConstraint = bottomPanel.bottomAnchor.constraint(
            equalTo: view.bottomAnchor
        )

        webTopSafeConstraint = webContainer.topAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.topAnchor
        )
        webTopFullscreenConstraint = webContainer.topAnchor.constraint(
            equalTo: view.topAnchor
        )
        webBottomPanelConstraint = webContainer.bottomAnchor.constraint(
            equalTo: bottomPanel.topAnchor
        )
        webBottomFullscreenConstraint = webContainer.bottomAnchor.constraint(
            equalTo: view.bottomAnchor
        )

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

            blurView.topAnchor.constraint(equalTo: bottomPanel.topAnchor),
            blurView.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomPanel.bottomAnchor),

            addressContainer.topAnchor.constraint(
                equalTo: bottomPanel.topAnchor,
                constant: 8
            ),
            addressContainer.leadingAnchor.constraint(
                equalTo: bottomPanel.leadingAnchor,
                constant: 14
            ),
            addressContainer.trailingAnchor.constraint(
                equalTo: bottomPanel.trailingAnchor,
                constant: -14
            ),
            addressContainer.heightAnchor.constraint(equalToConstant: 44),

            addressContentView.topAnchor.constraint(
                equalTo: addressContainer.topAnchor
            ),
            addressContentView.leadingAnchor.constraint(
                equalTo: addressContainer.leadingAnchor
            ),
            addressContentView.trailingAnchor.constraint(
                equalTo: addressContainer.trailingAnchor
            ),
            addressContentView.bottomAnchor.constraint(
                equalTo: addressContainer.bottomAnchor
            ),

            lockButton.leadingAnchor.constraint(
                equalTo: addressContentView.leadingAnchor,
                constant: 10
            ),
            lockButton.centerYAnchor.constraint(
                equalTo: addressContentView.centerYAnchor
            ),
            lockButton.widthAnchor.constraint(equalToConstant: 24),
            lockButton.heightAnchor.constraint(equalToConstant: 24),

            addressField.leadingAnchor.constraint(
                equalTo: lockButton.trailingAnchor,
                constant: 6
            ),
            addressField.trailingAnchor.constraint(
                equalTo: addressContentView.trailingAnchor,
                constant: -38
            ),
            addressField.topAnchor.constraint(
                equalTo: addressContentView.topAnchor
            ),
            addressField.bottomAnchor.constraint(
                equalTo: addressContentView.bottomAnchor
            ),

            progressView.leadingAnchor.constraint(
                equalTo: addressContentView.leadingAnchor
            ),
            progressView.trailingAnchor.constraint(
                equalTo: addressContentView.trailingAnchor
            ),
            progressView.bottomAnchor.constraint(
                equalTo: addressContentView.bottomAnchor
            ),
            progressView.heightAnchor.constraint(equalToConstant: 2.5),

            reloadButton.trailingAnchor.constraint(
                equalTo: addressContentView.trailingAnchor,
                constant: -10
            ),
            reloadButton.centerYAnchor.constraint(
                equalTo: addressContentView.centerYAnchor
            ),
            reloadButton.widthAnchor.constraint(equalToConstant: 24),
            reloadButton.heightAnchor.constraint(equalToConstant: 24),

            clearButton.trailingAnchor.constraint(
                equalTo: addressContentView.trailingAnchor,
                constant: -10
            ),
            clearButton.centerYAnchor.constraint(
                equalTo: addressContentView.centerYAnchor
            ),
            clearButton.widthAnchor.constraint(equalToConstant: 24),
            clearButton.heightAnchor.constraint(equalToConstant: 24),

            navigationStack.topAnchor.constraint(
                equalTo: addressContainer.bottomAnchor,
                constant: 4
            ),
            navigationStack.leadingAnchor.constraint(
                equalTo: bottomPanel.leadingAnchor,
                constant: 12
            ),
            navigationStack.trailingAnchor.constraint(
                equalTo: bottomPanel.trailingAnchor,
                constant: -12
            ),
            navigationStack.bottomAnchor.constraint(
                equalTo: bottomPanel.safeAreaLayoutGuide.bottomAnchor,
                constant: -2
            ),
            navigationStack.heightAnchor.constraint(equalToConstant: 40)
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
        configuration.baseForegroundColor = gentleToolbarIconColor
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
            tabs[activeTabIndex].webView.removeFromSuperview()
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
        updateAddressRightButtons()
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
            updateAddressRightButtons()
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
                      self.tabs.indices.contains(self.activeTabIndex),
                      observedWebView == self.activeTab.webView,
                      observedWebView.isLoading,
                      self.homeView.alpha < 0.5,
                      !self.activeTab.isDisplayingFailurePage else {
                    self?.resetProgress()
                    self?.updateAddressRightButtons()
                    return
                }

                self.progressView.alpha = 1
                self.progressView.setProgress(Float(observedWebView.estimatedProgress), animated: true)
                self.updateAddressRightButtons()
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
        updateAddressRightButtons()
    }

    private func showHomeUI() {
        homeView.alpha = 1
        webContainer.alpha = 0
        failureOverlayView.isHidden = true
        addressField.text = ""
        addressField.resignFirstResponder()
        homeSearchField.text = ""
        homeSearchField.resignFirstResponder()
        resetProgress()
        updateUIState()
        updateAddressRightButtons()
    }

    private func showBrowserUI() {
        homeView.alpha = 0
        webContainer.alpha = 1
        failureOverlayView.isHidden = true
        homeSearchField.resignFirstResponder()
        updateUIState()
        updateAddressRightButtons()
    }

    private func showFailureUI(for tab: TabItem) {
        homeView.alpha = 0
        webContainer.alpha = 1
        failureOverlayView.isHidden = false
        let targetURL = tab.failedURL ?? tab.url
        failureURLLabel.text = targetURL?.absoluteString.removingPercentEncoding ?? targetURL?.absoluteString ?? ""
        if let err = tab.failureError as NSError? {
            failureTitleLabel.text = "无法打开网页"
            failureReasonLabel.text = err.localizedDescription
        }
        let hostStr = targetURL?.host?.removingPercentEncoding ?? targetURL?.host ?? (targetURL?.absoluteString.removingPercentEncoding ?? targetURL?.absoluteString ?? "")
        addressField.text = hostStr
        resetProgress()
        updateUIState()
        updateAddressRightButtons()
    }

    private func updateUIState() {
        guard !tabs.isEmpty, tabs.indices.contains(activeTabIndex) else {
            return
        }

        let isHome = homeView.alpha > 0.5

        let canGoBack = activeTab.webView.canGoBack || activeTab.isDisplayingFailurePage || activeTab.sourceTabID != nil || activeTab.previousURL != nil
        backButton.isEnabled = !isHome && canGoBack
        forwardButton.isEnabled = !isHome && activeTab.webView.canGoForward
        moreButton.isEnabled = true
    }

    private func updateAddressRightButtons() {
        guard !tabs.isEmpty, tabs.indices.contains(activeTabIndex) else {
            reloadButton.isHidden = true
            reloadButton.alpha = 0
            clearButton.isHidden = true
            clearButton.alpha = 0
            return
        }

        let currentTab = tabs[activeTabIndex]
        let isEditing = addressField.isFirstResponder
        let isHome = homeView.alpha > 0.5
        let hasText = !(addressField.text?.isEmpty ?? true)

        if isEditing {
            reloadButton.isHidden = true
            reloadButton.alpha = 0
            let showClear = hasText
            clearButton.isHidden = !showClear
            clearButton.alpha = showClear ? 1 : 0
        } else {
            clearButton.isHidden = true
            clearButton.alpha = 0
            let showReload = !isHome && (currentTab.url != nil || currentTab.isDisplayingFailurePage)
            reloadButton.isHidden = !showReload
            reloadButton.alpha = showReload ? 1 : 0
            let iconName = currentTab.isLoading ? "xmark" : "arrow.clockwise"
            reloadButton.setImage(
                UIImage(
                    systemName: iconName,
                    withConfiguration: UIImage.SymbolConfiguration(
                        pointSize: 13.5,
                        weight: .medium
                    )
                ),
                for: .normal
            )
        }
    }

    @objc private func handleAddressReload() {
        if activeTab.isDisplayingFailurePage {
            handleFailureReload()
        } else if activeTab.isLoading {
            activeTab.webView.stopLoading()
            resetProgress()
            updateAddressRightButtons()
        } else {
            activeTab.webView.reload()
        }
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
        updateAddressRightButtons()
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
        updateAddressRightButtons()
        persistCurrentSession()
    }

    func tabDidFail(_ tab: TabItem, error: Error) {
        guard !tabs.isEmpty, tab.id == activeTab.id else {
            return
        }

        showFailureUI(for: tab)
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        if textField == addressField {
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
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if textField == addressField {
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
        if touch.view?.isDescendant(of: addressContainer) == true ||
           touch.view?.isDescendant(of: homeSearchContainer) == true {
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

    @objc private func handleFailureReload() {
        guard let targetURL = activeTab.failedURL else { return }
        activeTab.isDisplayingFailurePage = false
        failureOverlayView.isHidden = true
        activeTab.webView.load(URLRequest(url: targetURL))
        updateUIState()
        updateAddressRightButtons()
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
                iconName: "exclamationmark.triangle",
                handler: nil
            ))
        } else {
            for script in matchingScripts {
                items.append(CustomBottomSheetItem(
                    title: script.name,
                    iconName: "puzzlepiece.extension",
                    handler: { [weak self] in
                        self?.showScriptSubMenu(for: script)
                    }
                ))
            }
        }

        items.append(CustomBottomSheetItem(
            title: "搜索适合当前网站的脚本",
            iconName: "arrow.down.circle",
            handler: { [weak self] in
                let searchUrlStr = "https://greasyfork.org/zh-CN/scripts?q=\(currentHost)"
                if let searchUrl = URL(string: searchUrlStr) {
                    self?.load(url: searchUrl)
                }
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "用户脚本管理",
            iconName: "gearshape",
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
                iconName: "play.circle",
                handler: { [weak self] in
                    self?.activeTab.webView.evaluateJavaScript("window.__gm_invokeMenuCommand(\(cmd.cmdId))", completionHandler: nil)
                }
            ))
        }

        items.append(CustomBottomSheetItem(
            title: script.isEnabled ? "禁用该脚本" : "启用该脚本",
            iconName: "power",
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
            iconName: "curlybraces",
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
            self?.showToastNotice("规则已更新并重新应用")
        }
        let nav = UINavigationController(rootViewController: manager)
        present(nav, animated: true)
    }

    private func addCurrentPageToBookmarks() {
        guard let url = activeTab.url else {
            showToastNotice("主页无需添加书签")
            return
        }
        BookmarkStore.shared.addBookmark(title: activeTab.title, urlString: url.absoluteString)
        showToastNotice("已添加到书签")
    }

    @objc private func showMoreMenu() {
        dismissKeyboard()

        var items: [CustomBottomSheetItem] = []

        // Page 1: 8 Items (4 columns x 2 rows)
        // 1. 书签/历史
        items.append(CustomBottomSheetItem(
            title: "书签/历史",
            iconName: "star",
            dismissOnTap: true,
            handler: { [weak self] in
                self?.showBrowserBookmarksAndHistory()
            }
        ))

        // 2. 电脑版 (长按进入标识设置)
        let isDesktop = UserAgentStore.shared.currentMode == .desktop
        items.append(CustomBottomSheetItem(
            title: isDesktop ? "移动版" : "电脑版",
            iconName: "desktopcomputer",
            isSwitchOn: isDesktop,
            dismissOnTap: false,
            handler: { [weak self] in
                guard let self = self else { return }
                let newMode: UserAgentCategory = (UserAgentStore.shared.currentMode == .desktop) ? .mobile : .desktop
                UserAgentStore.shared.currentMode = newMode
                let newUA = UserAgentStore.shared.getSelectedUA()
                self.activeTab.webView.customUserAgent = newUA
                self.activeTab.webView.configuration.defaultWebpagePreferences.preferredContentMode = (newMode == .desktop) ? .desktop : .mobile
                self.activeTab.reloadUserScripts()
                self.activeTab.webView.reloadFromOrigin()
            },
            longPressHandler: { [weak self] in
                self?.showUserAgentManager()
            }
        ))

        // 3. 扩展脚本
        items.append(CustomBottomSheetItem(
            title: "扩展脚本",
            iconName: "puzzlepiece.extension",
            dismissOnTap: true,
            handler: { [weak self] in
                self?.showPluginPanel()
            }
        ))

        // 4. 夜间模式
        let isEyeOn = EyeProtectionManager.shared.isEnabled
        items.append(CustomBottomSheetItem(
            title: "夜间模式",
            iconName: "moon.stars",
            isSwitchOn: isEyeOn,
            dismissOnTap: false,
            handler: { [weak self] in
                EyeProtectionManager.shared.toggle(in: self?.view.window)
            },
            longPressHandler: { [weak self] in
                self?.showEyeProtectionLevelPicker()
            }
        ))

        // 5. 添加书签 (放置在原全屏浏览位置)
        items.append(CustomBottomSheetItem(
            title: "添加书签",
            customImage: makeAddBookmarkIcon(),
            dismissOnTap: true,
            handler: { [weak self] in
                self?.addCurrentPageToBookmarks()
            }
        ))

        // 6. 全屏浏览 (移动到原标识设置位置)
        items.append(CustomBottomSheetItem(
            title: isFullscreen ? "退出全屏" : "全屏浏览",
            iconName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            dismissOnTap: true,
            handler: { [weak self] in
                guard let self = self else { return }
                self.setFullscreen(!self.isFullscreen)
            }
        ))

        // 7. 广告过滤 (与清除数据交换位置)
        let isAdBlockOn = AdBlockManager.shared.isEnabled
        items.append(CustomBottomSheetItem(
            title: "广告过滤",
            iconName: "shield.lefthalf.filled",
            isSwitchOn: isAdBlockOn,
            dismissOnTap: false,
            handler: { [weak self] in
                guard let self = self else { return }
                let newState = !AdBlockManager.shared.isEnabled
                AdBlockManager.shared.isEnabled = newState
                AdBlockManager.shared.applyRules(to: self.activeTab.webView)
                self.showToastNotice(newState ? "已开启广告过滤" : "已停用广告过滤")
            },
            longPressHandler: { [weak self] in
                self?.showAdBlockerManager()
            }
        ))

        // 8. 清除数据 (与广告过滤交换位置)
        items.append(CustomBottomSheetItem(
            title: "清除数据",
            iconName: "trash",
            dismissOnTap: true,
            handler: { [weak self] in
                self?.showCleanDataMenu()
            }
        ))

        // Page 2: Secondary items
        // 9. 标识设置 (移动到第二页)
        items.append(CustomBottomSheetItem(
            title: "标识设置",
            iconName: "slider.horizontal.3",
            dismissOnTap: true,
            handler: { [weak self] in
                self?.showUserAgentManager()
            }
        ))

        // 10. 搜索引擎
        let currentEngine = SearchEngineStore.shared.currentEngine
        items.append(CustomBottomSheetItem(
            title: currentEngine.name,
            iconName: "magnifyingglass",
            dismissOnTap: true,
            handler: { [weak self] in
                self?.showSearchEnginePicker()
            }
        ))

        // 11. 提取正文
        items.append(CustomBottomSheetItem(
            title: "提取正文",
            iconName: "doc.text.magnifyingglass",
            dismissOnTap: true,
            handler: { [weak self] in
                self?.extractPageText()
            }
        ))

        let panel = CustomBottomSheetViewController(title: "选项", items: items, layout: .grid)
        if #available(iOS 16.0, *) {
            if let presentation = panel.sheetPresentationController {
                presentation.detents = [.custom { _ in 280 }]
                presentation.prefersGrabberVisible = false
                presentation.preferredCornerRadius = 24
            }
        } else if #available(iOS 15.0, *) {
            if let presentation = panel.sheetPresentationController {
                presentation.detents = [.medium()]
                presentation.prefersGrabberVisible = false
                presentation.preferredCornerRadius = 24
            }
        }
        present(panel, animated: true)
    }

    private func showBrowserBookmarksAndHistory() {
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
