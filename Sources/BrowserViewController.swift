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
    var onLongPressAction: (() -> Void)?

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(customCopyAction) ||
           action == #selector(customPasteAction) ||
           action == #selector(customEditAction) ||
           action == #selector(customPasteAndGoAction) {
            return true
        }
        if action == #selector(copy(_:)) ||
           action == #selector(paste(_:)) ||
           action == #selector(selectAll(_:)) ||
           action == #selector(select(_:)) ||
           action == #selector(cut(_:)) {
            return true
        }
        return false
    }

    @objc func customCopyAction() {
        if let text = text, !text.isEmpty {
            UIPasteboard.general.string = text
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    @objc func customPasteAction() {
        if let paste = UIPasteboard.general.string {
            text = paste
            sendActions(for: .editingChanged)
        }
    }

    @objc func customEditAction() {
        becomeFirstResponder()
        selectAll(nil)
    }

    @objc func customPasteAndGoAction() {
        if let paste = UIPasteboard.general.string {
            text = paste
            _ = delegate?.textFieldShouldReturn?(self)
        }
    }
}

final class CalloutMenuButton: UIButton {
    override var isHighlighted: Bool {
        didSet {
            let isDark = traitCollection.userInterfaceStyle == .dark
            backgroundColor = isHighlighted ?
                (isDark ? UIColor(white: 1.0, alpha: 0.12) : UIColor(white: 0.0, alpha: 0.08)) :
                .clear
        }
    }
}

final class CalloutBubbleBackgroundView: UIView {
    enum ArrowDirection {
        case up
        case down
    }

    var arrowDirection: ArrowDirection = .down {
        didSet { setNeedsLayout() }
    }

    var arrowOffset: CGFloat = 136 {
        didSet { setNeedsLayout() }
    }

    private let shapeLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        backgroundColor = .clear
        layer.addSublayer(shapeLayer)
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        shapeLayer.fillColor = isDark ?
            UIColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 0.98).cgColor :
            UIColor(white: 1.0, alpha: 0.98).cgColor
        shapeLayer.strokeColor = isDark ?
            UIColor(white: 1.0, alpha: 0.12).cgColor :
            UIColor(white: 0.0, alpha: 0.06).cgColor
        shapeLayer.lineWidth = 0.5

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = isDark ? 0.35 : 0.12
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds

        let path = UIBezierPath()
        let cornerRadius: CGFloat = 12
        let arrowWidth: CGFloat = 14
        let arrowHeight: CGFloat = 7
        let halfArrow = arrowWidth / 2

        let minOffset = cornerRadius + halfArrow + 2
        let maxOffset = bounds.width - cornerRadius - halfArrow - 2
        let clampedOffset = min(max(minOffset, arrowOffset), maxOffset)

        if arrowDirection == .down {
            let bodyHeight = bounds.height - arrowHeight

            path.move(to: CGPoint(x: cornerRadius, y: 0))
            path.addLine(to: CGPoint(x: bounds.width - cornerRadius, y: 0))
            path.addArc(
                withCenter: CGPoint(x: bounds.width - cornerRadius, y: cornerRadius),
                radius: cornerRadius,
                startAngle: -CGFloat.pi / 2,
                endAngle: 0,
                clockwise: true
            )
            path.addLine(to: CGPoint(x: bounds.width, y: bodyHeight - cornerRadius))
            path.addArc(
                withCenter: CGPoint(x: bounds.width - cornerRadius, y: bodyHeight - cornerRadius),
                radius: cornerRadius,
                startAngle: 0,
                endAngle: CGFloat.pi / 2,
                clockwise: true
            )

            path.addLine(to: CGPoint(x: clampedOffset + halfArrow, y: bodyHeight))
            path.addLine(to: CGPoint(x: clampedOffset, y: bounds.height))
            path.addLine(to: CGPoint(x: clampedOffset - halfArrow, y: bodyHeight))

            path.addLine(to: CGPoint(x: cornerRadius, y: bodyHeight))
            path.addArc(
                withCenter: CGPoint(x: cornerRadius, y: bodyHeight - cornerRadius),
                radius: cornerRadius,
                startAngle: CGFloat.pi / 2,
                endAngle: CGFloat.pi,
                clockwise: true
            )
            path.addLine(to: CGPoint(x: 0, y: cornerRadius))
            path.addArc(
                withCenter: CGPoint(x: cornerRadius, y: cornerRadius),
                radius: cornerRadius,
                startAngle: CGFloat.pi,
                endAngle: -CGFloat.pi / 2,
                clockwise: true
            )
            path.close()
        } else {
            let bodyTop = arrowHeight

            path.move(to: CGPoint(x: clampedOffset - halfArrow, y: bodyTop))
            path.addLine(to: CGPoint(x: clampedOffset, y: 0))
            path.addLine(to: CGPoint(x: clampedOffset + halfArrow, y: bodyTop))

            path.addLine(to: CGPoint(x: bounds.width - cornerRadius, y: bodyTop))
            path.addArc(
                withCenter: CGPoint(x: bounds.width - cornerRadius, y: bodyTop + cornerRadius),
                radius: cornerRadius,
                startAngle: -CGFloat.pi / 2,
                endAngle: 0,
                clockwise: true
            )
            path.addLine(to: CGPoint(x: bounds.width, y: bounds.height - cornerRadius))
            path.addArc(
                withCenter: CGPoint(x: bounds.width - cornerRadius, y: bounds.height - cornerRadius),
                radius: cornerRadius,
                startAngle: 0,
                endAngle: CGFloat.pi / 2,
                clockwise: true
            )

            path.addLine(to: CGPoint(x: cornerRadius, y: bounds.height))
            path.addArc(
                withCenter: CGPoint(x: cornerRadius, y: bounds.height - cornerRadius),
                radius: cornerRadius,
                startAngle: CGFloat.pi / 2,
                endAngle: CGFloat.pi,
                clockwise: true
            )
            path.addLine(to: CGPoint(x: 0, y: bodyTop + cornerRadius))
            path.addArc(
                withCenter: CGPoint(x: cornerRadius, y: bodyTop + cornerRadius),
                radius: cornerRadius,
                startAngle: CGFloat.pi,
                endAngle: -CGFloat.pi / 2,
                clockwise: true
            )
            path.close()
        }

        shapeLayer.path = path.cgPath
        layer.shadowPath = path.cgPath
    }
}

final class AddressCalloutMenuView: UIView {
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var onEdit: (() -> Void)?
    var onPasteAndGo: (() -> Void)?

    private let backgroundView = CalloutBubbleBackgroundView()
    private let contentView = UIView()
    private let stackView = UIStackView()

    init(arrowDirection: CalloutBubbleBackgroundView.ArrowDirection, arrowOffset: CGFloat) {
        super.init(frame: .zero)
        backgroundView.arrowDirection = arrowDirection
        backgroundView.arrowOffset = arrowOffset
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        backgroundColor = .clear
        addSubview(backgroundView)
        addSubview(contentView)

        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true

        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.distribution = .fill
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let btnCopy = createItemButton(title: "拷贝", action: #selector(handleCopyTapped), width: 56)
        let btnPaste = createItemButton(title: "粘贴", action: #selector(handlePasteTapped), width: 56)
        let btnEdit = createItemButton(title: "编辑", action: #selector(handleEditTapped), width: 56)
        let btnPasteAndGo = createItemButton(title: "粘贴并前往", action: #selector(handlePasteAndGoTapped), width: 94)

        stackView.addArrangedSubview(btnCopy)
        stackView.addArrangedSubview(makeSeparator())
        stackView.addArrangedSubview(btnPaste)
        stackView.addArrangedSubview(makeSeparator())
        stackView.addArrangedSubview(btnEdit)
        stackView.addArrangedSubview(makeSeparator())
        stackView.addArrangedSubview(btnPasteAndGo)
    }

    private func createItemButton(title: String, action: Selector, width: CGFloat) -> CalloutMenuButton {
        let btn = CalloutMenuButton(type: .custom)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 14.5, weight: .regular)
        btn.setTitleColor(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.96, alpha: 1.0) : UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
        }, for: .normal)
        btn.addTarget(self, action: action, for: .touchUpInside)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: width).isActive = true
        return btn
    }

    private func makeSeparator() -> UIView {
        let sep = UIView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 1.0, alpha: 0.15) : UIColor(white: 0.0, alpha: 0.12)
        }
        sep.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        return sep
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundView.frame = bounds
        let arrowHeight: CGFloat = 7
        if backgroundView.arrowDirection == .down {
            contentView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - arrowHeight)
        } else {
            contentView.frame = CGRect(x: 0, y: arrowHeight, width: bounds.width, height: bounds.height - arrowHeight)
        }
    }

    @objc private func handleCopyTapped() {
        onCopy?()
    }

    @objc private func handlePasteTapped() {
        onPaste?()
    }

    @objc private func handleEditTapped() {
        onEdit?()
    }

    @objc private func handlePasteAndGoTapped() {
        onPasteAndGo?()
    }
}

final class BrowserViewController: UIViewController, UITextFieldDelegate, TabItemDelegate, UIGestureRecognizerDelegate, UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private var tabs: [TabItem] = []
    private var activeTabIndex = 0
    private var isFullscreen = false
    private var progressObservation: NSKeyValueObservation?

    private var editingShortcutIdForCustomIcon: String?
    private var cachedAddBookmarkIcon: UIImage?

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
    private let shortcutsStack = UIStackView()

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
    private let expandButton = TouchButton()
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

    private var isShowingLongPressMenu = false
    private weak var activeCalloutOverlay: UIView?
    private weak var currentToastView: UIView?

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

    private func configureFaviconObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFaviconUpdatedNotification(_:)),
            name: NSNotification.Name("FaviconUpdatedNotification"),
            object: nil
        )
    }

    @objc private func handleFaviconUpdatedNotification(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.reloadHomeShortcuts()
        }
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

    private func configureDownloadObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptDownloadNotification(_:)),
            name: NSNotification.Name("PromptDownloadNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptBlobExportNotification(_:)),
            name: NSNotification.Name("PromptBlobExportNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDownloadNotification(_:)),
            name: NSNotification.Name("DownloadStartedNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDownloadNotification(_:)),
            name: NSNotification.Name("DownloadFinishedNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDownloadNotification(_:)),
            name: NSNotification.Name("DownloadFailedNotification"),
            object: nil
        )
    }

    @objc private func handlePromptDownloadNotification(_ notification: Notification) {
        let url = notification.object as? URL
        let filename = (notification.userInfo?["filename"] as? String) ?? url?.lastPathComponent ?? "文件"
        let displayName = filename.isEmpty ? "文件" : filename
        let onConfirm = notification.userInfo?["onConfirm"] as? ((Bool) -> Void)

        let alert = UIAlertController(
            title: "下载文件",
            message: "\(displayName)\n\n来源: \(url?.host ?? url?.absoluteString ?? "未知来源")",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "下载文件", style: .default) { _ in
            if let onConfirm = onConfirm {
                onConfirm(true)
            } else if let url = url {
                DownloadCoordinator.shared.startDownload(url: url, filename: displayName)
            }
        })

        alert.addAction(UIAlertAction(title: "复制下载链接", style: .default) { [weak self] _ in
            if let url = url {
                UIPasteboard.general.string = url.absoluteString
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.showToastNotice("已复制下载链接")
            }
            onConfirm?(false)
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        present(alert, animated: true)
    }

    @objc private func handlePromptBlobExportNotification(_ notification: Notification) {
        guard let fileURL = notification.object as? URL else { return }
        let filename = (notification.userInfo?["filename"] as? String) ?? fileURL.lastPathComponent
        let fileSize = (notification.userInfo?["fileSize"] as? Int) ?? 0
        let sizeString = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)

        let alert = UIAlertController(
            title: "网页文件已准备就绪",
            message: "\(filename) (\(sizeString))\n\n该文件已在网页中生成完毕，您可以直接导出或保存至下载管理。",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "导出 / 共享文件", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = self.view
                popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            self.present(activity, animated: true)
        })

        alert.addAction(UIAlertAction(title: "存入下载管理", style: .default) { [weak self] _ in
            self?.showToastNotice("已存入下载管理: \(filename)")
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
            try? FileManager.default.removeItem(at: fileURL)
        })

        present(alert, animated: true)
    }

    @objc private func handleDownloadNotification(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            if notification.name == NSNotification.Name("DownloadStartedNotification") {
                if let filename = notification.object as? String {
                    self?.showToastNotice("开始下载: \(filename)")
                } else {
                    self?.showToastNotice("已开始下载任务")
                }
            } else if notification.name == NSNotification.Name("DownloadFinishedNotification") {
                self?.showToastNotice("下载完成，已存入下载管理")
            } else if notification.name == NSNotification.Name("DownloadFailedNotification") {
                if let err = notification.object as? String {
                    self?.showToastNotice("下载失败: \(err)")
                } else {
                    self?.showToastNotice("下载失败")
                }
            }
        }
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

    private func getAddBookmarkIcon() -> UIImage {
        if let icon = cachedAddBookmarkIcon {
            return icon
        }
        let icon = makeAddBookmarkIcon()
        cachedAddBookmarkIcon = icon
        return icon
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

    private func reloadHomeShortcuts() {
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

    private func createShortcutButton(shortcut: HomeShortcutItem, index: Int) -> TouchButton {
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

    @objc private func handleShortcutTap(_ sender: UIButton) {
        let shortcuts = HomeShortcutStore.shared.loadShortcuts()
        guard shortcuts.indices.contains(sender.tag),
              let url = URL(string: shortcuts[sender.tag].urlString) else { return }
        load(url: url)
    }

    @objc private func handleShortcutLongPress(_ gesture: UILongPressGestureRecognizer) {
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

    private func promptChooseCustomIcon(for shortcutId: String) {
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

    private func showEditShortcutAlert(item: HomeShortcutItem) {
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

    private func configureAddressLongPressMenu() {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleAddressLongPress(_:)))
        longPress.minimumPressDuration = 0.42
        addressContentView.addGestureRecognizer(longPress)
    }

    @objc private func handleAddressLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        view.endEditing(true)
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

    @objc private func dismissCalloutMenu() {
        guard let overlay = activeCalloutOverlay else { return }
        if let menu = overlay.subviews.first(where: { $0 is AddressCalloutMenuView }) {
            dismissCalloutMenuAnimated(menu, overlay: overlay, completion: nil)
        } else {
            overlay.removeFromSuperview()
            isShowingLongPressMenu = false
        }
    }

    private func dismissCalloutMenuAnimated(_ menu: UIView, overlay: UIView, completion: (() -> Void)?) {
        UIView.animate(withDuration: 0.14, animations: {
            menu.alpha = 0
            menu.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
        }) { [weak self] _ in
            overlay.removeFromSuperview()
            self?.isShowingLongPressMenu = false
            completion?()
        }
    }

    private func handleCalloutCopy() {
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

    private func handleCalloutPaste() {
        if let paste = UIPasteboard.general.string, !paste.isEmpty {
            addressField.text = paste
            addressField.becomeFirstResponder()
            updateAddressEditingAppearance()
        }
    }

    private func handleCalloutEdit() {
        if let url = activeTab.url {
            let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            addressField.text = (raw == "about:blank") ? "" : raw
        }
        addressField.becomeFirstResponder()
        addressField.selectAll(nil)
        updateAddressEditingAppearance()
    }

    private func handleCalloutPasteAndGo() {
        guard let paste = UIPasteboard.general.string,
              let url = destinationURL(from: paste) else {
            return
        }
        load(url: url)
    }

    @objc private func handleMoreButtonLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showCleanDataMenu()
    }

    private func showToastNotice(_ text: String) {
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

    private func configureToolbarButton(_ button: TouchButton, imageName: String, pointSize: CGFloat = 18, action: Selector?) {
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

        let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        addressField.text = (raw == "about:blank") ? "" : raw
        activeTab.webView.load(URLRequest(url: url))

        if let host = url.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }

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
        let rawStr = targetURL?.absoluteString.removingPercentEncoding ?? targetURL?.absoluteString ?? ""
        let hostStr = targetURL?.host?.removingPercentEncoding ?? targetURL?.host ?? (rawStr == "about:blank" ? "" : rawStr)
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

    @objc private func handleExpandAddress() {
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
            resetProgress()

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
        if touch.view?.isDescendant(of: bottomPanel) == true ||
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
        if isShowingLongPressMenu {
            return
        }

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
        if addressField.isFirstResponder {
            addressField.resignFirstResponder()
        }
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
            guard let text = result as? String, !text.isEmpty else {
                return
            }
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

            vc.navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "完成",
                style: .done,
                target: self,
                action: #selector(self.dismissModalVC)
            )

            let copyAction = UIAction { _ in
                UIPasteboard.general.string = text
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            vc.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "复制", primaryAction: copyAction)

            let nav = UINavigationController(rootViewController: vc)
            self.present(nav, animated: true)
        }
    }

    @objc private func dismissModalVC() {
        dismiss(animated: true)
    }

    @objc private func showPluginPanel() {
        if addressField.isFirstResponder {
            addressField.resignFirstResponder()
        }
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

        let panel = CustomBottomSheetViewController(title: "", items: items, layout: .list)
        if #available(iOS 16.0, *) {
            if let presentation = panel.sheetPresentationController {
                let cardHeight: CGFloat = 56
                let spacing: CGFloat = 10
                let totalHeight: CGFloat = CGFloat(items.count) * cardHeight + CGFloat(max(0, items.count - 1)) * spacing + 48
                presentation.detents = [.custom { _ in min(totalHeight, 420) }]
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
        if #available(iOS 16.0, *) {
            if let presentation = panel.sheetPresentationController {
                let cardHeight: CGFloat = 56
                let spacing: CGFloat = 10
                let totalHeight: CGFloat = CGFloat(items.count) * cardHeight + CGFloat(max(0, items.count - 1)) * spacing + 88
                presentation.detents = [.custom { _ in min(totalHeight, 460) }]
                presentation.prefersGrabberVisible = false
                presentation.preferredCornerRadius = 24
            }
        } else if #available(iOS 15.0, *) {
            if let presentation = panel.sheetPresentationController {
                presentation.detents = [.medium(), .large()]
                presentation.prefersGrabberVisible = false
                presentation.preferredCornerRadius = 24
            }
        }
        present(panel, animated: true)
    }

    @objc private func showPluginManager() {
        if addressField.isFirstResponder {
            addressField.resignFirstResponder()
        }
        let manager = UserScriptManagerViewController()
        manager.onScriptsUpdated = { [weak self] in
            self?.activeTab.reloadUserScripts()
        }
        let nav = UINavigationController(rootViewController: manager)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    @objc private func showTabsManager() {
        if addressField.isFirstResponder {
            addressField.resignFirstResponder()
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

        let tabToSnapshot = activeTab
        if !tabToSnapshot.isLoading {
            tabToSnapshot.updateSnapshot { [weak manager] in
                DispatchQueue.main.async {
                    manager?.reloadGrid()
                }
            }
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

    private func showDownloadManager() {
        if addressField.isFirstResponder {
            addressField.resignFirstResponder()
        }
        let vc = DownloadManagerViewController()
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    private func handleAddAction() {
        guard let url = activeTab.url else {
            showToastNotice("主页无需添加")
            return
        }

        let rawTitle = activeTab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = rawTitle.isEmpty ? (url.host ?? url.absoluteString) : rawTitle

        let alert = UIAlertController(title: "添加当前网页", message: resolvedTitle, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "添加到书签", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let folders = BookmarkStore.shared.getAllFolders()
            if folders.isEmpty {
                BookmarkStore.shared.addBookmark(title: resolvedTitle, urlString: url.absoluteString, parentId: nil)
                self.showToastNotice("已添加到书签")
            } else {
                let folderAlert = UIAlertController(title: "选择目标文件夹", message: nil, preferredStyle: .actionSheet)
                folderAlert.addAction(UIAlertAction(title: "书签根目录", style: .default) { _ in
                    BookmarkStore.shared.addBookmark(title: resolvedTitle, urlString: url.absoluteString, parentId: nil)
                    self.showToastNotice("已保存到书签根目录")
                })
                for folder in folders {
                    folderAlert.addAction(UIAlertAction(title: "📁 \(folder.title)", style: .default) { _ in
                        BookmarkStore.shared.addBookmark(title: resolvedTitle, urlString: url.absoluteString, parentId: folder.id)
                        self.showToastNotice("已保存到「\(folder.title)」")
                    })
                }
                folderAlert.addAction(UIAlertAction(title: "取消", style: .cancel))
                self.present(folderAlert, animated: true)
            }
        })

        alert.addAction(UIAlertAction(title: "添加到主页", style: .default) { [weak self] _ in
            guard let self = self else { return }
            HomeShortcutStore.shared.addShortcut(title: resolvedTitle, urlString: url.absoluteString)
            if let host = url.host {
                FaviconLoader.shared.preloadFavicon(for: host)
            }
            self.reloadHomeShortcuts()
            self.showToastNotice("已添加到主页，长按可自定义Logo")
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func showMoreMenu() {
        if addressField.isFirstResponder {
            addressField.resignFirstResponder()
        } else if homeSearchField.isFirstResponder {
            homeSearchField.resignFirstResponder()
        }

        var items: [CustomBottomSheetItem] = []

        items.append(CustomBottomSheetItem(
            title: "书签/历史",
            iconName: "star",
            dismissOnTap: true,
            handler: { [weak self] in
                self?.showBrowserBookmarksAndHistory()
            }
        ))

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
                let targetURL = self.activeTab.url ?? self.activeTab.webView.url
                if let currentURL = targetURL, currentURL.absoluteString != "about:blank" {
                    self.showBrowserUI()
                    self.activeTab.url = currentURL
                    self.activeTab.webView.load(URLRequest(url: currentURL))
                }
            },
            longPressHandler: { [weak self] in
                self?.showUserAgentManager()
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "下载管理",
            iconName: "arrow.down.circle",
            dismissOnTap: true,
            handler: { [weak self] in
                self?.showDownloadManager()
            }
        ))

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

        items.append(CustomBottomSheetItem(
            title: "添加",
            customImage: getAddBookmarkIcon(),
            dismissOnTap: true,
            handler: { [weak self] in
                self?.handleAddAction()
            }
        ))

        items.append(CustomBottomSheetItem(
            title: isFullscreen ? "退出全屏" : "全屏浏览",
            iconName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            dismissOnTap: true,
            handler: { [weak self] in
                guard let self = self else { return }
                self.setFullscreen(!self.isFullscreen)
            }
        ))

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
            },
            longPressHandler: { [weak self] in
                self?.showAdBlockerManager()
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "清除数据",
            iconName: "trash",
            dismissOnTap: true,
            handler: { [weak self] in
                self?.showCleanDataMenu()
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "扩展脚本",
            iconName: "puzzlepiece.extension",
            dismissOnTap: true,
            handler: { [weak self] in
                self?.showPluginPanel()
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "标识设置",
            iconName: "slider.horizontal.3",
            dismissOnTap: true,
            handler: { [weak self] in
                self?.showUserAgentManager()
            }
        ))

        let currentEngine = SearchEngineStore.shared.currentEngine
        items.append(CustomBottomSheetItem(
            title: currentEngine.name,
            iconName: "magnifyingglass",
            dismissOnTap: true,
            handler: { [weak self] in
                self?.showSearchEnginePicker()
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "提取正文",
            iconName: "doc.text.magnifyingglass",
            dismissOnTap: true,
            handler: { [weak self] in
                self?.extractPageText()
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "数据备份",
            iconName: "externaldrive",
            dismissOnTap: true,
            handler: { [weak self] in
                self?.showBackupActionSheet()
            }
        ))

        let panel = CustomBottomSheetViewController(title: "选项", items: items, layout: .grid)
        if #available(iOS 16.0, *) {
            if let presentation = panel.sheetPresentationController {
                presentation.detents = [.custom { _ in 260 }]
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

    private func showBackupActionSheet() {
        let sheet = UIAlertController(
            title: "数据备份与恢复",
            message: "可将书签、主页站点、浏览记录、网站登录信息、脚本与拦截规则等打包导出，或使用备份文件进行恢复。",
            preferredStyle: .actionSheet
        )

        sheet.addAction(UIAlertAction(title: "备份并导出文件", style: .default) { [weak self] _ in
            self?.performExportBackup()
        })

        sheet.addAction(UIAlertAction(title: "从备份文件恢复", style: .default) { [weak self] _ in
            self?.presentDocumentPickerForRestore()
        })

        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }

    private func performExportBackup() {
        BackupManager.shared.exportBackupFile { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let fileURL):
                let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                if let popover = activityVC.popoverPresentationController {
                    popover.sourceView = self.view
                    popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
                self.present(activityVC, animated: true)
            case .failure(let error):
                self.showToastNotice("导出备份失败: \(error.localizedDescription)")
            }
        }
    }

    private func presentDocumentPickerForRestore() {
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .data, .item], asCopy: true)
        } else {
            picker = UIDocumentPickerViewController(documentTypes: ["public.json", "public.item"], in: .import)
        }
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let selectedURL = urls.first else { return }
        let shouldAccess = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if shouldAccess {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }

        let alert = UIAlertController(
            title: "恢复备份确认",
            message: "确定要从选择的备份文件恢复吗？\n当前的所有数据将被该备份文件恢复替换。",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "确认恢复", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            BackupManager.shared.restore(from: selectedURL) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    self.reloadHomeShortcuts()
                    self.activeTab.reloadUserScripts()
                    AdBlockManager.shared.applyRules(to: self.activeTab.webView)
                    self.showToastNotice("数据恢复成功")
                case .failure(let error):
                    let errAlert = UIAlertController(
                        title: "恢复失败",
                        message: "备份文件解析错误或格式无效：\(error.localizedDescription)",
                        preferredStyle: .alert
                    )
                    errAlert.addAction(UIAlertAction(title: "确定", style: .default))
                    self.present(errAlert, animated: true)
                }
            }
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showBrowserBookmarksAndHistory() {
        if addressField.isFirstResponder {
            addressField.resignFirstResponder()
        }

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
            let targetURL = self.activeTab.url ?? self.activeTab.webView.url
            if let currentURL = targetURL, currentURL.absoluteString != "about:blank" {
                self.showBrowserUI()
                self.activeTab.url = currentURL
                self.activeTab.webView.load(URLRequest(url: currentURL))
            }
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
        cleanVC.onOpenWebsiteDataManager = { [weak cleanVC] in
            let manager = WebsiteDataManagerViewController()
            cleanVC?.navigationController?.pushViewController(manager, animated: true)
        }
        let nav = UINavigationController(rootViewController: cleanVC)
        present(nav, animated: true)
    }

    private func performCleanData(options: Set<CleanOption>, completion: @escaping () -> Void) {
        let cleanCache = options.contains(.cache)
        let cleanLoginAndData = options.contains(.loginAndData)
        let targetURL = activeTab.url ?? activeTab.webView.url

        let group = DispatchGroup()

        if cleanCache || cleanLoginAndData {
            group.enter()
            WebsiteCleaner.shared.clean(cache: cleanCache, loginAndData: cleanLoginAndData) {
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
            guard let self = self else {
                completion()
                return
            }
            completion()
            if let url = targetURL, url.absoluteString != "about:blank" {
                self.showBrowserUI()
                self.activeTab.url = url
                self.activeTab.webView.load(URLRequest(url: url))
            }
        }
    }
}

final class DownloadManagerViewController: UITableViewController, UIDocumentInteractionControllerDelegate {
    private struct DownloadedFile {
        let name: String
        let url: URL
        let sizeString: String
        let dateString: String
    }

    private var files: [DownloadedFile] = []
    private var docController: UIDocumentInteractionController?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "下载管理"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DownloadFileCell")
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleClose))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "清空", style: .plain, target: self, action: #selector(handleClearAll))
        loadDownloadedFiles()
    }

    @objc private func handleClose() {
        dismiss(animated: true)
    }

    private func getDownloadsDirectory() -> URL {
        return DownloadCoordinator.getDownloadsDirectory()
    }

    private func loadDownloadedFiles() {
        let fm = FileManager.default
        var list: [DownloadedFile] = []
        let dirs = [getDownloadsDirectory(), fm.urls(for: .documentDirectory, in: .userDomainMask)[0]]

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"

        for dir in dirs {
            if let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey], options: .skipsHiddenFiles) {
                for url in urls {
                    let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                    if vals?.isDirectory == true { continue }

                    let size = vals?.fileSize ?? 0
                    let date = vals?.contentModificationDate ?? Date()
                    let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                    let dateStr = df.string(from: date)

                    list.append(DownloadedFile(name: url.lastPathComponent, url: url, sizeString: sizeStr, dateString: dateStr))
                }
            }
        }

        self.files = list
        tableView.reloadData()
    }

    @objc private func handleClearAll() {
        guard !files.isEmpty else { return }
        let alert = UIAlertController(title: "清空下载文件", message: "确定要删除所有已下载的文件吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            let fm = FileManager.default
            for f in self.files {
                try? fm.removeItem(at: f.url)
            }
            self.loadDownloadedFiles()
        })
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        files.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DownloadFileCell", for: indexPath)
        let item = files[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = item.name
        content.secondaryText = "\(item.sizeString) • \(item.dateString)"
        content.image = UIImage(systemName: "doc.fill")
        content.imageProperties.tintColor = .systemBlue
        content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < files.count else { return }
        let file = files[indexPath.row]

        docController = UIDocumentInteractionController(url: file.url)
        docController?.delegate = self
        if !docController!.presentPreview(animated: true) {
            docController?.presentOptionsMenu(from: view.bounds, in: view, animated: true)
        }
    }

    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        self
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.row < files.count else { return nil }
        let file = files[indexPath.row]

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            try? FileManager.default.removeItem(at: file.url)
            self?.loadDownloadedFiles()
            completion(true)
        }

        let shareAction = UIContextualAction(style: .normal, title: "共享") { [weak self] _, _, completion in
            let activity = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
            self?.present(activity, animated: true)
            completion(true)
        }
        shareAction.backgroundColor = .systemBlue

        return UISwipeActionsConfiguration(actions: [deleteAction, shareAction])
    }
}

final class ExpandedURLEditorViewController: UIViewController, UITextViewDelegate {
    private let initialURL: String
    private let onConfirm: (String) -> Void
    private let textView = UITextView()

    init(initialURL: String, onConfirm: @escaping (String) -> Void) {
        self.initialURL = initialURL
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "编辑网址"
        view.backgroundColor = .systemBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: self,
            action: #selector(handleCancel)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "前往",
            style: .done,
            target: self,
            action: #selector(handleGo)
        )

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 1.0) : UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)
        }
        container.layer.cornerRadius = 14
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 16, weight: .regular)
        textView.textColor = .label
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.text = initialURL
        textView.keyboardType = .webSearch
        textView.returnKeyType = .go
        textView.delegate = self
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)

        container.addSubview(textView)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            container.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),

            textView.topAnchor.constraint(equalTo: container.topAnchor),
            textView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.textView.becomeFirstResponder()
            if !self.textView.text.isEmpty {
                self.textView.selectAll(nil)
            }
        }
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" {
            handleGo()
            return false
        }
        return true
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }

    @objc private func handleGo() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss(animated: true) { [weak self] in
            if !text.isEmpty {
                self?.onConfirm(text)
            }
        }
    }
}
