import UIKit
import WebKit

struct BrowserTabSessionItem: Codable {
    var urlString: String?
    var title: String
}

struct BrowserSession: Codable {
    var tabs: [BrowserTabSessionItem]
    var activeIndex: Int
}

final class BrowserSessionStore {
    static let shared = BrowserSessionStore()

    private let key = "browser_tab_session_v1"
    private let maximumTabCount = 30

    private init() {}

    func loadSession() -> BrowserSession? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let session = try? JSONDecoder().decode(BrowserSession.self, from: data),
              !session.tabs.isEmpty else {
            return nil
        }
        return session
    }

    func saveSession(tabs: [BrowserTabSessionItem], activeIndex: Int) {
        let limitedTabs = Array(tabs.prefix(maximumTabCount))
        guard !limitedTabs.isEmpty else {
            clearSession()
            return
        }

        let safeIndex = min(max(0, activeIndex), limitedTabs.count - 1)
        let session = BrowserSession(tabs: limitedTabs, activeIndex: safeIndex)

        guard let data = try? JSONEncoder().encode(session) else {
            return
        }

        UserDefaults.standard.set(data, forKey: key)
    }

    func clearSession() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

final class BrowserViewController: UIViewController, UITextFieldDelegate, TabItemDelegate, UIGestureRecognizerDelegate, UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    var tabs: [TabItem] = []
    var activeTabIndex = 0
    var isFullscreen = false
    var progressObservation: NSKeyValueObservation?
    var isCompletingProgress = false

    var editingShortcutIdForCustomIcon: String?
    var cachedAddBookmarkIcon: UIImage?

    var activeTab: TabItem {
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

    let webContainer = UIView()
    let homeView = UIView()
    let homeScrollView = UIScrollView()
    let homeSearchContainer = UIView()
    let homeSearchField = AddressTextField()
    let shortcutsStack = UIStackView()

    let failureOverlayView = UIView()
    let failureIconView = UIImageView()
    let failureTitleLabel = UILabel()
    let failureReasonLabel = UILabel()
    let failureURLLabel = UILabel()
    let failureBackButton = TouchButton()
    let failureReloadButton = TouchButton()
    let failureContinueButton = TouchButton()

    let editingDimmingView = UIView()

    let bottomPanel = UIView()
    let addressContainer = UIView()
    let addressContentView = UIView()
    let lockButton = TouchButton()
    let addressField = AddressTextField()
    let expandButton = TouchButton()
    let clearButton = TouchButton()
    let reloadButton = TouchButton()
    let progressView = UIProgressView(progressViewStyle: .default)

    let navigationStack = UIStackView()
    let backButton = TouchButton()
    let forwardButton = TouchButton()
    let pluginButton = TouchButton()
    let tabsButton = TouchButton()
    let moreButton = TouchButton()

    var bottomPanelBottomConstraint: NSLayoutConstraint?
    var webTopSafeConstraint: NSLayoutConstraint?
    var webTopFullscreenConstraint: NSLayoutConstraint?
    var webBottomPanelConstraint: NSLayoutConstraint?
    var webBottomFullscreenConstraint: NSLayoutConstraint?

    var fullscreenExitGesture: UILongPressGestureRecognizer?

    var isShowingLongPressMenu = false
    weak var activeCalloutOverlay: UIView?
    weak var currentToastView: UIView?

    var gentleToolbarIconColor: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.86, alpha: 1.0) : UIColor(red: 0.28, green: 0.28, blue: 0.31, alpha: 1.0)
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        traitCollection.userInterfaceStyle == .dark ? .lightContent : .darkContent
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
        configureAddressLongPressMenu()
        configureInstallerObserver()
        configureSessionObservers()
        configureDownloadObservers()
        configureFaviconObserver()
        restorePreviousSession()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        EyeProtectionManager.shared.restoreState(in: view.window)
        ensureBottomPanelPosition()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        ensureBottomPanelPosition()
    }

    func ensureBottomPanelPosition() {
        if !addressField.isFirstResponder && (bottomPanelBottomConstraint?.constant ?? 0) != 0 {
            bottomPanelBottomConstraint?.constant = 0
            view.layoutIfNeeded()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        dismissCalloutMenu()
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

    func resetProgress() {
        isCompletingProgress = false
        progressView.layer.removeAllAnimations()
        progressView.alpha = 0
        progressView.setProgress(0, animated: false)
    }

    func completeProgress() {
        guard !isCompletingProgress else { return }
        isCompletingProgress = true
        progressView.setProgress(1.0, animated: true)
        UIView.animate(withDuration: 0.25, delay: 0.05, options: [.curveEaseOut, .allowUserInteraction], animations: {
            self.progressView.alpha = 0
        }, completion: { [weak self] _ in
            self?.progressView.setProgress(0, animated: false)
            self?.isCompletingProgress = false
        })
    }

    func configureInstallerObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstallUserScriptNotification(_:)),
            name: NSNotification.Name("InstallUserScriptNotification"),
            object: nil
        )
    }

    func configureSessionObservers() {
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc func handleAppDidBecomeActive() {
        ensureBottomPanelPosition()
    }

    @objc func handleSessionPersistenceNotification() {
        persistCurrentSession()
    }

    func restorePreviousSession() {
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

    func persistCurrentSession() {
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

    @objc func handleInstallUserScriptNotification(_ notification: Notification) {
        guard let scriptURL = notification.object as? URL else { return }

        let task = URLSession.shared.dataTask(with: scriptURL) { [weak self] data, response, error in
            guard let data = data, let code = String(data: data, encoding: .utf8), !code.isEmpty else {
                DispatchQueue.main.async {
                    self?.showToastNotice("下载或解析油猴脚本失败")
                }
                return
            }
            let (parsedName, parsedMatch) = UserScriptStore.shared.parseMetadata(from: code)

            DispatchQueue.main.async {
                let alert = UIAlertController(
                    title: "安装油猴脚本",
                    message: "脚本名称: \(parsedName)\n匹配规则: \(parsedMatch)\n\n是否确定安装此油猴脚本？",
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

    func makeSpacedThreeLinesIcon() -> UIImage {
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

    func configureFailureView() {
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
        backConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 13.5, weight: .medium)
            return outgoing
        }
        failureBackButton.configuration = backConfig
        failureBackButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)

        failureReloadButton.translatesAutoresizingMaskIntoConstraints = false
        var reloadConfig = UIButton.Configuration.filled()
        reloadConfig.title = "重新加载"
        reloadConfig.cornerStyle = .capsule
        reloadConfig.baseBackgroundColor = .systemBlue
        reloadConfig.baseForegroundColor = .white
        reloadConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 13.5, weight: .medium)
            return outgoing
        }
        failureReloadButton.configuration = reloadConfig
        failureReloadButton.addTarget(self, action: #selector(handleFailureReload), for: .touchUpInside)

        failureContinueButton.translatesAutoresizingMaskIntoConstraints = false
        var continueConfig = UIButton.Configuration.tinted()
        continueConfig.title = "继续访问"
        continueConfig.cornerStyle = .capsule
        continueConfig.baseBackgroundColor = .systemRed
        continueConfig.baseForegroundColor = .systemRed
        continueConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 13.5, weight: .medium)
            return outgoing
        }
        failureContinueButton.configuration = continueConfig
        failureContinueButton.addTarget(self, action: #selector(handleFailureContinue), for: .touchUpInside)
        failureContinueButton.isHidden = true

        let failureButtons = UIStackView(arrangedSubviews: [failureBackButton, failureReloadButton, failureContinueButton])
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

    func configureInterface() {
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

        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.tintColor = UIColor(red: 0.48, green: 0.48, blue: 0.51, alpha: 1.0)
        expandButton.setImage(
            UIImage(
                systemName: "arrow.up.left.and.arrow.down.right",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 11.5,
                    weight: .medium
                )
            ),
            for: .normal
        )
        expandButton.hitTestInsets = UIEdgeInsets(top: -8, left: -4, bottom: -8, right: -4)
        expandButton.addTarget(
            self,
            action: #selector(handleExpandAddress),
            for: .touchUpInside
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
            pointSize: 16.2,
            action: #selector(showTabsManager)
        )
        configureToolbarButton(
            pluginButton,
            imageName: "puzzlepiece.extension",
            pointSize: 16.2,
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
        addressContentView.addSubview(expandButton)
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

            expandButton.trailingAnchor.constraint(
                equalTo: reloadButton.leadingAnchor,
                constant: -4
            ),
            expandButton.centerYAnchor.constraint(
                equalTo: addressContentView.centerYAnchor
            ),
            expandButton.widthAnchor.constraint(equalToConstant: 24),
            expandButton.heightAnchor.constraint(equalToConstant: 24),

            addressField.leadingAnchor.constraint(
                equalTo: lockButton.trailingAnchor,
                constant: 6
            ),
            addressField.trailingAnchor.constraint(
                equalTo: expandButton.leadingAnchor,
                constant: -6
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

    func configureAddressLongPressMenu() {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleAddressLongPress(_:)))
        longPress.minimumPressDuration = 0.42
        addressContentView.addGestureRecognizer(longPress)
    }

    @objc func handleAddressLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        dismissKeyboard()
        dismissCalloutMenu()
        isShowingLongPressMenu = true

        let targetRect = addressContentView.convert(addressContentView.bounds, to: view)
        let menuWidth: CGFloat = 272
        let menuHeight: CGFloat = 51

        let isAbove = targetRect.minY > 120
        let arrowDir: CalloutBubbleBackgroundView.ArrowDirection = isAbove ? .down : .up
        let menuY: CGFloat = isAbove ? (targetRect.minY - menuHeight - 6) : (targetRect.maxY + 6)
        let minX: CGFloat = 16
        let maxX: CGFloat = view.bounds.width - menuWidth - 16
        let menuX: CGFloat = min(max(minX, targetRect.midX - menuWidth / 2), maxX)
        let arrowOffset = targetRect.midX - menuX

        let overlay = UIView(frame: view.bounds)
        overlay.backgroundColor = .clear

        let tapDismiss = UITapGestureRecognizer(target: self, action: #selector(dismissCalloutMenu))
        overlay.addGestureRecognizer(tapDismiss)

        let menuView = AddressCalloutMenuView(arrowDirection: arrowDir, arrowOffset: arrowOffset)
        menuView.frame = CGRect(x: menuX, y: menuY, width: menuWidth, height: menuHeight)

        menuView.onCopy = { [weak self] in
            self?.dismissCalloutMenuAnimated(menuView, overlay: overlay) {
                self?.handleCalloutCopy()
            }
        }

        menuView.onPaste = { [weak self] in
            self?.dismissCalloutMenuAnimated(menuView, overlay: overlay) {
                self?.handleCalloutPaste()
            }
        }

        menuView.onEdit = { [weak self] in
            self?.dismissCalloutMenuAnimated(menuView, overlay: overlay) {
                self?.handleCalloutEdit()
            }
        }

        menuView.onPasteAndGo = { [weak self] in
            self?.dismissCalloutMenuAnimated(menuView, overlay: overlay) {
                self?.handleCalloutPasteAndGo()
            }
        }

        overlay.addSubview(menuView)
        view.addSubview(overlay)
        activeCalloutOverlay = overlay

        menuView.alpha = 0
        menuView.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)

        UIView.animate(withDuration: 0.18, delay: 0, options: .curveEaseOut) {
            menuView.alpha = 1
            menuView.transform = .identity
        }
    }

    @objc func dismissCalloutMenu() {
        guard let overlay = activeCalloutOverlay else {
            isShowingLongPressMenu = false
            return
        }
        if let menu = overlay.subviews.first(where: { $0 is AddressCalloutMenuView }) {
            dismissCalloutMenuAnimated(menu, overlay: overlay, completion: nil)
        } else {
            overlay.removeFromSuperview()
            activeCalloutOverlay = nil
            isShowingLongPressMenu = false
        }
    }

    func dismissCalloutMenuAnimated(_ menu: UIView, overlay: UIView, completion: (() -> Void)?) {
        UIView.animate(withDuration: 0.14, animations: {
            menu.alpha = 0
            menu.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
        }) { [weak self] _ in
            overlay.removeFromSuperview()
            self?.activeCalloutOverlay = nil
            self?.isShowingLongPressMenu = false
            completion?()
        }
    }

    func handleCalloutCopy() {
        let currentText: String
        if let url = activeTab.url {
            let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            currentText = (raw == "about:blank") ? "" : raw
        } else {
            currentText = addressField.text ?? ""
        }
        if !currentText.isEmpty {
            UIPasteboard.general.string = currentText
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    func handleCalloutPaste() {
        if let paste = UIPasteboard.general.string, !paste.isEmpty {
            addressField.text = paste
            addressField.becomeFirstResponder()
            updateAddressEditingAppearance()
        }
    }

    func handleCalloutEdit() {
        if let url = activeTab.url {
            let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            addressField.text = (raw == "about:blank") ? "" : raw
        }
        addressField.becomeFirstResponder()
        addressField.selectAll(nil)
        updateAddressEditingAppearance()
    }

    func handleCalloutPasteAndGo() {
        guard let paste = UIPasteboard.general.string,
              let url = destinationURL(from: paste) else {
            return
        }
        load(url: url)
    }

    func showToastNotice(_ text: String) {
        currentToastView?.layer.removeAllAnimations()
        currentToastView?.removeFromSuperview()

        let toast = UIView()
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.backgroundColor = .white
        toast.layer.cornerRadius = 16
        toast.layer.cornerCurve = .continuous
        toast.layer.borderWidth = 0.5
        toast.layer.borderColor = UIColor(white: 0.88, alpha: 1.0).cgColor
        toast.layer.shadowColor = UIColor.black.cgColor
        toast.layer.shadowOpacity = 0.08
        toast.layer.shadowOffset = CGSize(width: 0, height: 3)
        toast.layer.shadowRadius = 8

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = UIColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1.0)
        label.textAlignment = .center
        toast.addSubview(label)

        view.addSubview(toast)
        currentToastView = toast

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: toast.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: toast.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -16),

            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: -14)
        ])

        toast.alpha = 0
        UIView.animate(withDuration: 0.18) { toast.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak toast] in
            guard let toast = toast else { return }
            UIView.animate(withDuration: 0.2, animations: { toast.alpha = 0 }) { _ in
                toast.removeFromSuperview()
            }
        }
    }

    func configureToolbarButton(_ button: TouchButton, imageName: String, pointSize: CGFloat = 18, action: Selector?) {
        var configuration = UIButton.Configuration.plain()
        if imageName == "line.3.horizontal" {
            configuration.image = makeSpacedThreeLinesIcon()
        } else {
            configuration.image = UIImage(
                systemName: imageName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
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

    func configureKeyboardObservers() {
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

    func configureKeyboardDismissal() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        view.addGestureRecognizer(tapGesture)
    }

    func configureFullscreenExitGesture() {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleFullscreenExitGesture(_:)))
        gesture.minimumPressDuration = 1.3
        gesture.numberOfTouchesRequired = 2
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = self
        gesture.isEnabled = false
        view.addGestureRecognizer(gesture)
        fullscreenExitGesture = gesture
    }

    func createNewTab(loadURL url: URL?, sourceID: UUID? = nil) {
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

    func createNewTabInBackground(loadURL url: URL, sourceID: UUID? = nil) {
        let tab = TabItem()
        tab.sourceTabID = sourceID
        tab.delegate = self
        tab.url = url
        tab.title = url.host ?? url.absoluteString
        tab.webView.load(URLRequest(url: url))
        let insertIndex = min(activeTabIndex + 1, tabs.count)
        tabs.insert(tab, at: insertIndex)
        persistCurrentSession()
        showToastNotice("已在后台标签打开")
    }

    func switchTab(to index: Int) {
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
            let hostString = url.host?.removingPercentEncoding ?? url.host ?? (rawString == "about:blank" ? "" : rawString)
            addressField.text = hostString
            if let host = url.host {
                FaviconLoader.shared.preloadFavicon(for: host)
            }
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

    func closeTab(at index: Int) {
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

    func closeAllTabs() {
        resetProgress()
        for tab in tabs {
            tab.destroy()
        }
        tabs.removeAll()
        activeTabIndex = 0
        createNewTab(loadURL: nil)
    }

    func bindProgressObservation(to webView: WKWebView) {
        progressObservation?.invalidate()

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] observedWebView, _ in
            DispatchQueue.main.async {
                guard let self = self,
                      self.tabs.indices.contains(self.activeTabIndex),
                      observedWebView == self.activeTab.webView else {
                    return
                }

                if self.homeView.alpha > 0.5 || self.activeTab.isDisplayingFailurePage {
                    self.resetProgress()
                    self.updateAddressRightButtons()
                    return
                }

                let progress = Float(observedWebView.estimatedProgress)

                if observedWebView.isLoading {
                    if progress < 0.2 {
                        self.isCompletingProgress = false
                    }
                    if self.isCompletingProgress {
                        return
                    }
                    if self.progressView.alpha < 1 {
                        self.progressView.alpha = 1
                    }
                    let currentProgress = self.progressView.progress
                    let nextProgress = max(currentProgress, progress)
                    if nextProgress >= 1.0 {
                        self.completeProgress()
                    } else {
                        self.progressView.setProgress(nextProgress, animated: true)
                    }
                } else {
                    self.completeProgress()
                }

                self.updateAddressRightButtons()
            }
        }
    }

    func load(url: URL) {
        showBrowserUI()

        activeTab.url = url
        activeTab.title = url.host ?? url.absoluteString

        let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        addressField.text = (raw == "about:blank") ? "" : raw

        resetProgress()
        progressView.alpha = 1
        progressView.setProgress(0.08, animated: false)

        activeTab.webView.load(URLRequest(url: url))

        if let host = url.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }

        persistCurrentSession()
        updateAddressRightButtons()
    }

    func showHomeUI() {
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

    func showBrowserUI() {
        homeView.alpha = 0
        webContainer.alpha = 1
        failureOverlayView.isHidden = true
        homeSearchField.resignFirstResponder()
        updateUIState()
        updateAddressRightButtons()
    }

    func isCertificateError(_ error: Error?) -> Bool {
        guard let nsError = error as NSError? else { return false }
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired,
                 NSURLErrorSecureConnectionFailed,
                 -1200, -1201, -1202, -1203, -1204, -1205, -1206:
                return true
            default:
                break
            }
        }
        let desc = nsError.localizedDescription.lowercased()
        return desc.contains("certificate") || desc.contains("证书") || desc.contains("ssl") || desc.contains("tls")
    }

    func showFailureUI(for tab: TabItem) {
        homeView.alpha = 0
        webContainer.alpha = 1
        failureOverlayView.isHidden = false
        let targetURL = tab.failedURL ?? tab.url
        failureURLLabel.text = targetURL?.absoluteString.removingPercentEncoding ?? targetURL?.absoluteString ?? ""
        let isCertErr = isCertificateError(tab.failureError)
        if isCertErr {
            failureTitleLabel.text = "非私人连接"
            failureIconView.image = UIImage(
                systemName: "lock.trianglebadge.exclamationmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
            )
            failureContinueButton.isHidden = false
        } else {
            failureTitleLabel.text = "无法打开网页"
            failureIconView.image = UIImage(
                systemName: "wifi.exclamationmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
            )
            failureContinueButton.isHidden = true
        }
        if let err = tab.failureError as NSError? {
            failureReasonLabel.text = err.localizedDescription
        }
        let rawStr = targetURL?.absoluteString.removingPercentEncoding ?? targetURL?.absoluteString ?? ""
        let hostStr = targetURL?.host?.removingPercentEncoding ?? targetURL?.host ?? (rawStr == "about:blank" ? "" : rawStr)
        addressField.text = hostStr
        resetProgress()
        updateUIState()
        updateAddressRightButtons()
    }

    func updateUIState() {
        guard !tabs.isEmpty, tabs.indices.contains(activeTabIndex) else {
            return
        }

        let isHome = homeView.alpha > 0.5

        let canGoBack = activeTab.webView.canGoBack || activeTab.isDisplayingFailurePage || activeTab.sourceTabID != nil || activeTab.previousURL != nil
        backButton.isEnabled = !isHome && canGoBack
        forwardButton.isEnabled = !isHome && activeTab.webView.canGoForward
        moreButton.isEnabled = true
    }

    func updateAddressRightButtons() {
        guard !tabs.isEmpty, tabs.indices.contains(activeTabIndex) else {
            reloadButton.isHidden = true
            reloadButton.alpha = 0
            clearButton.isHidden = true
            clearButton.alpha = 0
            expandButton.isHidden = true
            expandButton.alpha = 0
            return
        }

        let currentTab = tabs[activeTabIndex]
        let isEditing = addressField.isFirstResponder
        let isHome = homeView.alpha > 0.5
        let hasText = !(addressField.text?.isEmpty ?? true)

        let showExpand = !isHome || isEditing || hasText
        expandButton.isHidden = !showExpand
        expandButton.alpha = showExpand ? 1 : 0

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

    @objc func handleExpandAddress() {
        dismissKeyboard()
        let currentText = activeTab.url?.absoluteString ?? addressField.text ?? ""
        let editor = ExpandedURLEditorViewController(initialURL: currentText) { [weak self] newURLString in
            guard let self = self, let url = self.destinationURL(from: newURLString) else { return }
            self.load(url: url)
        }
        let nav = UINavigationController(rootViewController: editor)
        if #available(iOS 16.0, *) {
            if let presentation = nav.sheetPresentationController {
                presentation.detents = [.custom { _ in 240 }]
                presentation.prefersGrabberVisible = true
                presentation.preferredCornerRadius = 24
            }
        } else if #available(iOS 15.0, *) {
            if let presentation = nav.sheetPresentationController {
                presentation.detents = [.medium()]
                presentation.prefersGrabberVisible = true
                presentation.preferredCornerRadius = 24
            }
        }
        present(nav, animated: true)
    }

    @objc func handleAddressReload() {
        if activeTab.isDisplayingFailurePage {
            handleFailureReload()
        } else if activeTab.isLoading {
            activeTab.stopLoading()
            resetProgress()
            updateAddressRightButtons()
        } else {
            activeTab.reloadFromTop()
        }
    }

    func destinationURL(from input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        SearchHistoryStore.shared.addHistory(value)

        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            if let url = URL(string: value) {
                return url
            }
            let decoded = value.removingPercentEncoding ?? value
            if let encoded = decoded.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: encoded) {
                return url
            }
            return nil
        }

        let lower = value.lowercased()
        let isLocal = lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1")
        let hasDot = value.contains(".") && !value.contains(" ")
        let hasPort = value.contains(":") && !value.contains(" ")

        if isLocal || hasDot || hasPort {
            let scheme = isLocal ? "http://" : "https://"
            let prefixed = scheme + value
            if let url = URL(string: prefixed) {
                return url
            }
            let decoded = prefixed.removingPercentEncoding ?? prefixed
            if let encoded = decoded.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: encoded) {
                return url
            }
        }

        return SearchEngineStore.shared.currentEngine.searchURL(query: value)
    }

    func setFullscreen(_ enabled: Bool) {
        guard isFullscreen != enabled else {
            return
        }

        dismissKeyboard()

        isFullscreen = enabled
        fullscreenExitGesture?.isEnabled = enabled
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

    func updateAddressEditingAppearance() {
        updateAddressRightButtons()
    }

    func tabRequestNewTab(url: URL, inBackground: Bool) {
        if inBackground {
            createNewTabInBackground(loadURL: url, sourceID: activeTab.id)
        } else {
            createNewTab(loadURL: url, sourceID: activeTab.id)
        }
    }

    func tabRequestCustomContextMenu(title: String, url: URL?, imageURLString: String?) {
        guard url != nil || (imageURLString != nil && !(imageURLString?.isEmpty ?? true)) else { return }

        dismissKeyboard()
        ensureBottomPanelPosition()

        let alertTitle: String
        if !title.isEmpty {
            alertTitle = title
        } else if let host = url?.host {
            alertTitle = host
        } else if let url = url {
            alertTitle = url.absoluteString
        } else {
            alertTitle = "图片选项"
        }

        let alert = UIAlertController(title: alertTitle, message: nil, preferredStyle: .actionSheet)

        if let url = url {
            alert.addAction(UIAlertAction(title: "新标签打开", style: .default) { [weak self] _ in
                self?.createNewTab(loadURL: url)
            })
            alert.addAction(UIAlertAction(title: "后台打开", style: .default) { [weak self] _ in
                self?.createNewTabInBackground(loadURL: url)
            })
            alert.addAction(UIAlertAction(title: "拷贝链接", style: .default) { [weak self] _ in
                UIPasteboard.general.string = url.absoluteString
                self?.showToastNotice("已拷贝链接")
            })
        }

        if let imgStr = imageURLString, !imgStr.isEmpty {
            alert.addAction(UIAlertAction(title: "保存图片到相册", style: .default) { [weak self] _ in
                self?.activeTab.saveImageToPhotos(from: imgStr)
            })
            alert.addAction(UIAlertAction(title: "拷贝图片链接", style: .default) { [weak self] _ in
                UIPasteboard.general.string = imgStr
                self?.showToastNotice("已拷贝图片链接")
            })
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        let presenter = presentedViewController ?? self
        presenter.present(alert, animated: true)
    }

    func tabRequestShowToast(_ message: String) {
        showToastNotice(message)
    }

    func tabRequestGoBack(_ tab: TabItem) {
        goBack()
    }

    func tabProcessTerminated(_ tab: TabItem) {
        guard !tabs.isEmpty, tab.id == activeTab.id else { return }
        resetProgress()
        let targetURL = tab.url ?? tab.webView.url
        if let url = targetURL, url.absoluteString != "about:blank" {
            tab.url = url
            showBrowserUI()
            tab.webView.load(URLRequest(url: url))
        } else {
            showBrowserUI()
            activeTab.webView.reload()
        }
    }

    func tabDidUpdate(_ tab: TabItem) {
        guard !tabs.isEmpty, tabs.indices.contains(activeTabIndex), tab.id == activeTab.id else {
            persistCurrentSession()
            return
        }

        if !tab.isDisplayingFailurePage {
            failureOverlayView.isHidden = true
            if let url = tab.url, !addressField.isFirstResponder {
                let rawString = url.absoluteString.removingPercentEncoding ?? url.absoluteString
                let hostString = url.host?.removingPercentEncoding ?? url.host ?? (rawString == "about:blank" ? "" : rawString)
                addressField.text = hostString
                if let host = url.host {
                    FaviconLoader.shared.preloadFavicon(for: host)
                }
            }
        }

        if !tab.isLoading {
            completeProgress()

            if !tab.isDisplayingFailurePage,
               let url = tab.url,
               url.absoluteString != "about:blank" {
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
                let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
                textField.text = (raw == "about:blank") ? "" : raw
            }

            navigationStack.isHidden = true
            updateAddressEditingAppearance()

            editingDimmingView.isHidden = false
            UIView.animate(withDuration: 0.2) {
                self.editingDimmingView.alpha = 1
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak textField] in
                textField?.selectAll(nil)
            }
        } else if textField == homeSearchField {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak textField] in
                textField?.selectAll(nil)
            }
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if textField == addressField {
            if let url = activeTab.url {
                let rawString = url.absoluteString.removingPercentEncoding ?? url.absoluteString
                textField.text = url.host?.removingPercentEncoding ?? url.host ?? (rawString == "about:blank" ? "" : rawString)
            } else if textField.text?.isEmpty == true {
                textField.text = ""
            }

            navigationStack.isHidden = false
            updateAddressEditingAppearance()

            bottomPanelBottomConstraint?.constant = 0
            UIView.animate(withDuration: 0.2, animations: {
                self.view.layoutIfNeeded()
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
        if gestureRecognizer == fullscreenExitGesture {
            return isFullscreen
        }
        if touch.view?.isDescendant(of: bottomPanel) == true ||
           touch.view?.isDescendant(of: homeSearchContainer) == true {
            return false
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == fullscreenExitGesture {
            return true
        }
        return false
    }

    @objc func addressFieldDidChange() {
        updateAddressEditingAppearance()
    }

    @objc func clearAddressInput() {
        addressField.text = ""
        addressField.becomeFirstResponder()
        updateAddressEditingAppearance()
    }

    @objc func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc func keyboardWillChangeFrame(_ notification: Notification) {
        if isShowingLongPressMenu {
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

        if addressField.isFirstResponder && overlap > 0 {
            bottomPanelBottomConstraint?.constant = -overlap
            UIView.animate(withDuration: duration, delay: 0, options: options) {
                self.view.layoutIfNeeded()
            }
        } else if homeSearchField.isFirstResponder {
            if bottomPanelBottomConstraint?.constant != 0 {
                bottomPanelBottomConstraint?.constant = 0
            }
            let insets = UIEdgeInsets(top: 0, left: 0, bottom: overlap, right: 0)
            homeScrollView.contentInset = insets
            homeScrollView.scrollIndicatorInsets = insets
            let searchFrame = homeSearchContainer.convert(homeSearchContainer.bounds, to: homeScrollView)
            homeScrollView.scrollRectToVisible(searchFrame.insetBy(dx: 0, dy: -20), animated: true)
        } else {
            if bottomPanelBottomConstraint?.constant != 0 {
                bottomPanelBottomConstraint?.constant = 0
                UIView.animate(withDuration: duration, delay: 0, options: options) {
                    self.view.layoutIfNeeded()
                }
            }
        }
    }

    @objc func keyboardWillHide(_ notification: Notification) {
        homeScrollView.contentInset = .zero
        homeScrollView.scrollIndicatorInsets = .zero

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

    @objc func handleFullscreenExitGesture(_ gesture: UILongPressGestureRecognizer) {
        guard isFullscreen, gesture.state == .began else {
            return
        }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        setFullscreen(false)
    }

    @objc func handleFailureReload() {
        guard activeTab.failedURL != nil else { return }
        activeTab.isDisplayingFailurePage = false
        failureOverlayView.isHidden = true
        activeTab.reloadFromTop()
        updateUIState()
        updateAddressRightButtons()
    }

    @objc func handleFailureContinue() {
        guard let targetURL = activeTab.failedURL ?? activeTab.url,
              let host = targetURL.host?.lowercased() else {
            return
        }
        let alert = UIAlertController(
            title: "访问非私人连接",
            message: "该网站的证书不受信任，继续访问可能存在安全风险。是否确定继续访问？",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "继续访问", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            CertificateTrustStore.shared.trustHost(host)
            self.activeTab.isDisplayingFailurePage = false
            self.failureOverlayView.isHidden = true
            self.activeTab.webView.load(URLRequest(url: targetURL))
            self.updateUIState()
            self.updateAddressRightButtons()
        })
        present(alert, animated: true)
    }

    @objc func goBack() {
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
        } else {
            showHomeUI()
        }
    }

    @objc func goForward() {
        activeTab.webView.goForward()
    }

    @objc func showSiteDomainSettings() {
        if addressField.isFirstResponder {
            addressField.resignFirstResponder()
        }
        guard let host = (activeTab.url?.host ?? activeTab.failedURL?.host) else { return }

        let settingsVC = DomainSettingsViewController(domain: host) { [weak self] in
            guard let self = self else { return }
            self.activeTab.reloadUserScripts()
            AdBlockManager.shared.applyRules(to: self.activeTab.webView)
            let targetURL = self.activeTab.failedURL ?? self.activeTab.url ?? self.activeTab.webView.url
            if let targetURL = targetURL, targetURL.absoluteString != "about:blank" {
                self.activeTab.isDisplayingFailurePage = false
                self.failureOverlayView.isHidden = true
                self.activeTab.reloadFromTop()
            }
        }
        settingsVC.onExtractText = { [weak self] in
            self?.extractPageText()
        }

        let nav = UINavigationController(rootViewController: settingsVC)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }
}
