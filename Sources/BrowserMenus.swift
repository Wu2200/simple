import UIKit
import WebKit

final class EyeProtectionManager {
    static let shared = EyeProtectionManager()

    private let enabledKey = "eye_protection_enabled_v1"
    private let levelKey = "eye_protection_level_v2"
    private var overlayView: UIView?

    enum Level: Int, CaseIterable {
        case low = 0
        case medium = 1
        case high = 2

        var alpha: CGFloat {
            switch self {
            case .low:
                return 0.245
            case .medium:
                return 0.35
            case .high:
                return 0.455
            }
        }

        var title: String {
            switch self {
            case .low:
                return "低强度"
            case .medium:
                return "中强度"
            case .high:
                return "高强度"
            }
        }
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    var level: Level {
        get {
            Level(rawValue: UserDefaults.standard.integer(forKey: levelKey)) ?? .medium
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: levelKey)
        }
    }

    private init() {}

    func restoreState(in window: UIWindow?) {
        guard isEnabled else { return }
        applyOverlay(in: window)
    }

    func toggle(in window: UIWindow?) {
        isEnabled.toggle()
        if isEnabled {
            applyOverlay(in: window)
        } else {
            removeOverlay()
        }
    }

    func setLevel(_ newLevel: Level, in window: UIWindow?) {
        level = newLevel
        isEnabled = true
        applyOverlay(in: window)
    }

    private func applyOverlay(in window: UIWindow?) {
        removeOverlay()
        guard let window = window else { return }
        let overlay = UIView(frame: window.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.black.withAlphaComponent(level.alpha)
        overlay.isUserInteractionEnabled = false
        window.addSubview(overlay)
        overlayView = overlay
    }

    private func removeOverlay() {
        overlayView?.removeFromSuperview()
        overlayView = nil
    }
}

extension BrowserViewController {
    func makeAddBookmarkIcon() -> UIImage {
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

    func getAddBookmarkIcon() -> UIImage {
        if let icon = cachedAddBookmarkIcon {
            return icon
        }
        let icon = makeAddBookmarkIcon()
        cachedAddBookmarkIcon = icon
        return icon
    }

    @objc func handleMoreButtonLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showCleanDataMenu()
    }

    func extractPageText() {
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

    @objc func dismissModalVC() {
        dismiss(animated: true)
    }

    @objc func showPluginPanel() {
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
                let httpsScheme = "https:" + String(repeating: "/", count: 2)
                let searchUrlStr = "\(httpsScheme)greasyfork.org/zh-CN/scripts?q=\(currentHost)"
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

    func showScriptSubMenu(for script: UserScript) {
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

    @objc func showPluginManager() {
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

    @objc func showTabsManager() {
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

    func showEyeProtectionLevelPicker() {
        let alert = UIAlertController(title: "护眼模式强度", message: nil, preferredStyle: .actionSheet)

        for level in EyeProtectionManager.Level.allCases {
            alert.addAction(UIAlertAction(title: level.title, style: .default) { [weak self] _ in
                EyeProtectionManager.shared.setLevel(level, in: self?.view.window)
            })
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    func showFullscreenModePicker() {
        let alert = UIAlertController(title: "全屏浏览", message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "完整全屏", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.fullscreenMode = .full
            self.setFullscreen(true)
        })

        alert.addAction(UIAlertAction(title: "不完整全屏", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.fullscreenMode = .statusBarOnly
            self.setFullscreen(true)
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        present(alert, animated: true)
    }

    func showSearchEnginePicker() {
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

    func showAdBlockerManager() {
        let manager = AdBlockManagerViewController()
        manager.onRulesChanged = { [weak self] in
            self?.showToastNotice("规则已更新并重新应用")
        }
        let nav = UINavigationController(rootViewController: manager)
        present(nav, animated: true)
    }

    func handleAddAction() {
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
                    folderAlert.addAction(UIAlertAction(title: folder.title, style: .default) { _ in
                        BookmarkStore.shared.addBookmark(title: resolvedTitle, urlString: url.absoluteString, parentId: folder.id)
                        self.showToastNotice("已保存到该文件夹")
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

    @objc func showMoreMenu() {
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
            },
            longPressHandler: { [weak self] in
                self?.showFullscreenModePicker()
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

    func showBrowserBookmarksAndHistory() {
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

    func showUserAgentManager() {
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

    func showCleanDataMenu() {
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

    func performCleanData(options: Set<CleanOption>, completion: @escaping () -> Void) {
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
