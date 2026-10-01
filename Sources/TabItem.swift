import UIKit
import WebKit

protocol TabItemDelegate: AnyObject {
    func tabDidUpdate(_ tab: TabItem)
    func tabDidFail(_ tab: TabItem, error: Error)
    func tabRequestNewTab(url: URL, inBackground: Bool)
    func tabProcessTerminated(_ tab: TabItem)
    func tabRequestGoBack(_ tab: TabItem)
    func tabRequestShowToast(_ message: String)
    func tabRequestCustomContextMenu(title: String, url: URL?, imageURLString: String?)
}

final class TabItem: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id = UUID()
    let webView: WKWebView
    private let reloadCoverView = UIView()
    var title = "主页"
    var url: URL?
    var isLoading = false
    var snapshot: UIImage?
    var registeredCommands: [RegisteredMenuCommand] = []

    var sourceTabID: UUID?
    var failedURL: URL?
    var failureError: Error?
    var isDisplayingFailurePage = false
    var previousURL: URL?
    var failureOriginURL: URL?
    var lastAutoFullscreenCheckedURL: URL?
    var triggeredAutoFullscreenHosts: Set<String> = []
    private var pendingRestoreURL: URL?

    private var hasInjectedScriptsForCurrentPage = false
    private var isLoadingFailureDocument = false
    private var navigationActionURL: URL?
    private var userScrolledDuringLoading = false

    weak var delegate: TabItemDelegate?

    private static let coreGMPolyfillScriptSource = """
    (function() {
        if (window.__gm_polyfilled__) return;
        window.__gm_polyfilled__ = true;
        window.unsafeWindow = window;
        window.__gm_menu_commands__ = window.__gm_menu_commands__ || {};
        window.__gm_xhr_callbacks__ = window.__gm_xhr_callbacks__ || {};

        window.__gm_invokeMenuCommand = function(id) {
            var fn = window.__gm_menu_commands__[id];
            if (typeof fn === 'function') { fn(); }
        };
        window.GM_addStyle = function(css) {
            var style = document.createElement('style');
            style.type = 'text/css';
            style.appendChild(document.createTextNode(css));
            (document.head || document.documentElement).appendChild(style);
            return style;
        };
        window.GM_log = function(msg) {};
        window.GM_openInTab = function(url) {
            window.open(url, '_blank');
        };
        window.GM_setClipboard = function(text) {
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(String(text || ''));
            }
        };
        window.GM_notification = function() {};
        window.GM_xmlhttpRequest = function(opts) {
            var id = 'xhr_' + Math.random().toString(36).substr(2, 9);
            window.__gm_xhr_callbacks__ = window.__gm_xhr_callbacks__ || {};
            window.__gm_xhr_callbacks__[id] = opts;
            try {
                window.webkit.messageHandlers.GM.postMessage({
                    action: 'xhr',
                    id: id,
                    method: opts.method || 'GET',
                    url: opts.url,
                    headers: opts.headers || {},
                    data: opts.data || null,
                    responseType: opts.responseType || '',
                    timeout: opts.timeout || 0
                });
            } catch(e) {
                if (opts.onerror) opts.onerror({ status: 0, responseText: e.toString() });
            }
        };
        window.__gm_handleXhrResponse = function(id, status, text, headers, finalUrl, base64Data) {
            var opts = window.__gm_xhr_callbacks__ && window.__gm_xhr_callbacks__[id];
            if (!opts) return;
            delete window.__gm_xhr_callbacks__[id];
            var responseVal = text;
            if (opts.responseType === 'json') {
                try {
                    responseVal = JSON.parse(text);
                } catch(e) {
                    responseVal = null;
                }
            } else if ((opts.responseType === 'arraybuffer' || opts.responseType === 'blob') && base64Data) {
                try {
                    var binStr = atob(base64Data);
                    var len = binStr.length;
                    var bytes = new Uint8Array(len);
                    for (var i = 0; i < len; i++) {
                        bytes[i] = binStr.charCodeAt(i);
                    }
                    responseVal = opts.responseType === 'blob' ? new Blob([bytes]) : bytes.buffer;
                } catch(e) {}
            }
            var res = {
                status: status,
                statusText: (status >= 200 && status < 300) ? 'OK' : 'Error',
                responseText: text,
                response: responseVal,
                responseHeaders: headers || '',
                readyState: 4,
                finalUrl: finalUrl || opts.url
            };
            if (opts.onreadystatechange) opts.onreadystatechange(res);
            if (opts.onload) opts.onload(res);
        };
        window.__handleXhrResponse = window.__gm_handleXhrResponse;
        window.__gm_handleXhrError = function(id, errorText) {
            var opts = window.__gm_xhr_callbacks__ && window.__gm_xhr_callbacks__[id];
            if (!opts) return;
            delete window.__gm_xhr_callbacks__[id];
            var res = {
                status: 0,
                statusText: errorText,
                responseText: errorText,
                response: null,
                responseHeaders: '',
                readyState: 4
            };
            if (opts.onerror) opts.onerror(res);
        };
        window.__handleXhrError = window.__gm_handleXhrError;
    })();
    """

    private static let coreDownloadScriptSource = """
    (function() {
        if (window.__simple_download_hooked__) return;
        window.__simple_download_hooked__ = true;

        function sendBlobData(url, filename) {
            if (!url) return;
            if (url.startsWith('data:')) {
                try {
                    window.webkit.messageHandlers.DownloadBridge.postMessage({
                        filename: filename || 'file',
                        dataUrl: url
                    });
                } catch(e) {}
                return;
            }
            if (url.startsWith('blob:')) {
                fetch(url).then(function(res) {
                    return res.blob();
                }).then(function(blob) {
                    var reader = new FileReader();
                    reader.onloadend = function() {
                        try {
                            window.webkit.messageHandlers.DownloadBridge.postMessage({
                                filename: filename || 'file',
                                dataUrl: reader.result
                            });
                        } catch(e) {}
                    };
                    reader.readAsDataURL(blob);
                }).catch(function(err) {});
                return;
            }
        }

        var origClick = HTMLAnchorElement.prototype.click;
        HTMLAnchorElement.prototype.click = function() {
            var href = this.href || '';
            var dl = this.getAttribute('download');
            if (dl !== null || href.startsWith('blob:') || href.startsWith('data:')) {
                var name = dl || this.download || 'downloaded_file';
                sendBlobData(href, name);
                return;
            }
            return origClick.apply(this, arguments);
        };

        document.addEventListener('click', function(e) {
            var el = e.target;
            while (el && el.tagName !== 'A') {
                el = el.parentElement;
            }
            if (!el) return;
            var href = el.href || el.getAttribute('href') || '';
            var dl = el.getAttribute('download');
            if (dl !== null || href.startsWith('blob:') || href.startsWith('data:')) {
                e.preventDefault();
                e.stopPropagation();
                var name = dl || el.download || 'downloaded_file';
                sendBlobData(href, name);
            }
        }, true);

        var origOpen = window.open;
        window.open = function(url) {
            if (typeof url === 'string' && (url.startsWith('blob:') || url.startsWith('data:'))) {
                sendBlobData(url, 'downloaded_file');
                return null;
            }
            return origOpen.apply(this, arguments);
        };
    })();
    """

    private static let coreContextMenuScriptSource = """
    (function() {
        if (window.__simple_custom_callout_injected__) return;
        window.__simple_custom_callout_injected__ = true;

        var style = document.createElement('style');
        style.type = 'text/css';
        style.innerHTML = '* { -webkit-touch-callout: none !important; } a, a *, img, video { -webkit-touch-callout: none !important; -webkit-user-select: none !important; user-select: none !important; }';
        (document.head || document.documentElement).appendChild(style);

        window.addEventListener('contextmenu', function(e) {
            e.preventDefault();
        }, true);

        var timer = null;
        var resetTimer = null;
        var startX = 0;
        var startY = 0;
        var longPressed = false;

        function clearTimer() {
            if (timer) {
                clearTimeout(timer);
                timer = null;
            }
        }

        function clearResetTimer() {
            if (resetTimer) {
                clearTimeout(resetTimer);
                resetTimer = null;
            }
        }

        function clearSelection() {
            if (window.getSelection) {
                var sel = window.getSelection();
                if (sel && sel.removeAllRanges) {
                    sel.removeAllRanges();
                }
            }
        }

        function extractContext(el) {
            var link = null;
            var img = null;
            var cur = el;
            var depth = 0;
            while (cur && depth < 8 && cur !== document.body && cur !== document.documentElement) {
                if (!link && cur.tagName === 'A' && cur.href) {
                    link = cur;
                }
                if (!img) {
                    if (cur.tagName === 'IMG' && (cur.currentSrc || cur.src)) {
                        img = cur.currentSrc || cur.src;
                    } else if (cur.tagName === 'VIDEO' && cur.poster) {
                        img = cur.poster;
                    }
                }
                cur = cur.parentElement;
                depth++;
            }
            if (!img && link) {
                var innerImg = link.querySelector('img');
                if (innerImg && (innerImg.currentSrc || innerImg.src)) {
                    img = innerImg.currentSrc || innerImg.src;
                }
            }
            return {
                linkHref: link ? link.href : '',
                linkText: link ? (link.innerText || link.textContent || '').trim() : '',
                imgSrc: img || ''
            };
        }

        window.addEventListener('touchstart', function(e) {
            clearResetTimer();
            longPressed = false;

            if (!e.touches || e.touches.length !== 1) {
                clearTimer();
                return;
            }
            var target = e.target;
            if (!target) return;
            if (target.isContentEditable || target.tagName === 'INPUT' || target.tagName === 'TEXTAREA') {
                clearTimer();
                return;
            }

            var info = extractContext(target);
            if (!info.linkHref && !info.imgSrc) {
                clearTimer();
                return;
            }

            clearSelection();

            var touch = e.touches[0];
            startX = touch.clientX;
            startY = touch.clientY;
            clearTimer();

            timer = setTimeout(function() {
                longPressed = true;
                clearSelection();
                try {
                    window.webkit.messageHandlers.ContextMenuBridge.postMessage({
                        link: info.linkHref,
                        title: info.linkText,
                        image: info.imgSrc
                    });
                } catch(err) {}
            }, 520);
        }, { capture: true, passive: true });

        window.addEventListener('touchmove', function(e) {
            if (!timer) return;
            if (e.touches && e.touches.length > 0) {
                var touch = e.touches[0];
                var dx = Math.abs(touch.clientX - startX);
                var dy = Math.abs(touch.clientY - startY);
                if (dx > 10 || dy > 10) {
                    clearTimer();
                }
            }
        }, { capture: true, passive: true });

        window.addEventListener('touchend', function(e) {
            clearTimer();
            if (longPressed) {
                e.preventDefault();
                e.stopPropagation();
                clearResetTimer();
                resetTimer = setTimeout(function() {
                    longPressed = false;
                }, 300);
            }
        }, { capture: true, passive: false });

        window.addEventListener('touchcancel', function(e) {
            clearTimer();
            clearResetTimer();
            longPressed = false;
        }, { capture: true, passive: true });

        window.addEventListener('blur', function() {
            clearTimer();
            clearResetTimer();
            longPressed = false;
        }, true);

        window.addEventListener('scroll', function() {
            clearTimer();
        }, true);

        document.addEventListener('visibilitychange', function() {
            if (document.hidden) {
                clearTimer();
                clearResetTimer();
                longPressed = false;
            }
        }, true);

        window.addEventListener('click', function(e) {
            if (longPressed) {
                e.preventDefault();
                e.stopPropagation();
                clearResetTimer();
                longPressed = false;
            }
        }, true);
    })();
    """

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = false

        let selectedItem = UserAgentStore.shared.getSelectedItem()
        let isDesktop = selectedItem.category == .desktop || selectedItem.id == "default_mac"
        configuration.defaultWebpagePreferences.preferredContentMode = isDesktop ? .desktop : .mobile

        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.customUserAgent = UserAgentStore.shared.getSelectedUA()

        ensureCoreScripts()

        AdBlockManager.shared.attach(to: webView)
        userContentController.add(self, name: "GM")
        userContentController.add(self, name: "DownloadBridge")
        userContentController.add(self, name: "ContextMenuBridge")

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .onDrag
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.isOpaque = true

        reloadCoverView.translatesAutoresizingMaskIntoConstraints = false
        reloadCoverView.backgroundColor = .systemBackground
        reloadCoverView.isHidden = true
        webView.addSubview(reloadCoverView)
        NSLayoutConstraint.activate([
            reloadCoverView.topAnchor.constraint(equalTo: webView.topAnchor),
            reloadCoverView.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            reloadCoverView.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            reloadCoverView.bottomAnchor.constraint(equalTo: webView.bottomAnchor)
        ])

        webView.scrollView.panGestureRecognizer.addTarget(self, action: #selector(handleScrollViewPan(_:)))

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAdBlockRulesAppliedNotification(_:)),
            name: NSNotification.Name("SimpleAdBlockRulesApplied"),
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        destroy()
    }

    @objc private func handleScrollViewPan(_ gesture: UIPanGestureRecognizer) {
        if isLoading && (gesture.state == .began || gesture.state == .changed) {
            userScrolledDuringLoading = true
        }
    }

    func showReloadCover() {
        reloadCoverView.alpha = 1
        reloadCoverView.isHidden = false
        webView.bringSubviewToFront(reloadCoverView)
    }

    func hideReloadCover() {
        guard !reloadCoverView.isHidden else { return }
        UIView.animate(withDuration: 0.15, animations: {
            self.reloadCoverView.alpha = 0
        }) { _ in
            self.reloadCoverView.isHidden = true
        }
    }

    func stopLoading() {
        hideReloadCover()
        webView.stopLoading()
    }

    func reloadFromTop() {
        userScrolledDuringLoading = false
        lastAutoFullscreenCheckedURL = nil
        webView.scrollView.setContentOffset(.zero, animated: false)
        showReloadCover()
        if let currentURL = url ?? webView.url {
            webView.load(URLRequest(url: currentURL))
        } else {
            webView.reload()
        }
    }

    @objc private func handleAdBlockRulesAppliedNotification(_ notification: Notification) {
        guard let targetWebView = notification.object as? WKWebView, targetWebView == self.webView else { return }
        ensureCoreScripts()
    }

    private func ensureCoreScripts() {
        let controller = webView.configuration.userContentController

        let hasGMPolyfill = controller.userScripts.contains { $0.source.contains("__gm_polyfilled__") }
        if !hasGMPolyfill {
            let script = WKUserScript(
                source: Self.coreGMPolyfillScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            controller.addUserScript(script)
        }

        let hasDownload = controller.userScripts.contains { $0.source.contains("__simple_download_hooked__") }
        if !hasDownload {
            let script = WKUserScript(
                source: Self.coreDownloadScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            controller.addUserScript(script)
        }

        let hasCustomCallout = controller.userScripts.contains { $0.source.contains("__simple_custom_callout_injected__") }
        if !hasCustomCallout {
            let script = WKUserScript(
                source: Self.coreContextMenuScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            controller.addUserScript(script)
        }
    }

    func destroy() {
        hideReloadCover()
        reloadCoverView.removeFromSuperview()
        NotificationCenter.default.removeObserver(self)
        AdBlockManager.shared.detach(from: webView)
        delegate = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.evaluateJavaScript("""
        (function(){
            try {
                var media = document.querySelectorAll('audio, video');
                for(var i=0; i<media.length; i++){
                    media[i].pause();
                    media[i].src = '';
                    media[i].load();
                }
            } catch(e){}
        })();
        """, completionHandler: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "GM")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "DownloadBridge")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "ContextMenuBridge")
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        webView.removeFromSuperview()
        snapshot = nil
    }

    func clearFailureState() {
        hideReloadCover()
        isDisplayingFailurePage = false
        failedURL = nil
        failureError = nil
        failureOriginURL = nil
    }

    func restoreSession(url: URL?, title: String) {
        self.url = url
        self.title = title.isEmpty ? (url?.host ?? "新标签页") : title
        self.pendingRestoreURL = url
        self.isDisplayingFailurePage = false
        self.failedURL = nil
        self.failureError = nil
        self.failureOriginURL = nil
    }

    func consumePendingRestoreURL() -> URL? {
        let url = pendingRestoreURL
        pendingRestoreURL = nil
        return url
    }

    func sessionURL() -> URL? {
        if isDisplayingFailurePage {
            return failedURL ?? url
        }
        return pendingRestoreURL ?? url
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "ContextMenuBridge",
           let body = message.body as? [String: Any] {
            let linkStr = body["link"] as? String
            let title = body["title"] as? String ?? ""
            let imgStr = body["image"] as? String
            let linkURL = linkStr.flatMap { URL(string: $0) }
            delegate?.tabRequestCustomContextMenu(title: title, url: linkURL, imageURLString: imgStr)
            return
        }

        if message.name == "DownloadBridge",
           let body = message.body as? [String: Any],
           let dataUrl = body["dataUrl"] as? String {
            let filename = (body["filename"] as? String) ?? "downloaded_file"
            handleBlobDataURL(dataUrl, filename: filename)
            return
        }

        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }

        if action == "goBackAction" {
            delegate?.tabRequestGoBack(self)
        } else if action == "registerMenuCommand", let cmdId = body["id"] as? Int, let caption = body["caption"] as? String {
            let scriptId = (body["scriptId"] as? String) ?? ""
            registeredCommands.removeAll { $0.cmdId == cmdId || ($0.scriptId == scriptId && $0.caption == caption) }
            registeredCommands.append(RegisteredMenuCommand(scriptId: scriptId, cmdId: cmdId, caption: caption))
        } else if action == "unregisterMenuCommand", let cmdId = body["id"] as? Int {
            registeredCommands.removeAll { $0.cmdId == cmdId }
        } else if action == "setValue", let scriptId = body["scriptId"] as? String, let name = body["name"] as? String, let value = body["value"] {
            ScriptDataStore.shared.setValue(scriptId: scriptId, name: name, value: value)
        } else if action == "deleteValue", let scriptId = body["scriptId"] as? String, let name = body["name"] as? String {
            ScriptDataStore.shared.deleteValue(scriptId: scriptId, name: name)
        } else if action == "xhr", let reqId = body["id"] as? String, let urlString = body["url"] as? String, let targetURL = URL(string: urlString) {
            let method = (body["method"] as? String) ?? "GET"
            let responseType = ((body["responseType"] as? String) ?? "").lowercased()
            var request = URLRequest(url: targetURL)
            request.httpMethod = method

            if let headers = body["headers"] as? [String: Any] {
                for (k, v) in headers {
                    request.setValue("\(v)", forHTTPHeaderField: k)
                }
            }

            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue(webView.customUserAgent ?? UserAgentStore.shared.getSelectedUA(), forHTTPHeaderField: "User-Agent")
            }

            if let dataString = body["data"] as? String {
                request.httpBody = dataString.data(using: .utf8)
            }

            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    if let error = error {
                        let errArgs: [Any] = [reqId, error.localizedDescription]
                        let errData = (try? JSONSerialization.data(withJSONObject: errArgs, options: [])) ?? Data()
                        let errJSON = String(data: errData, encoding: .utf8) ?? "[]"
                        self?.webView.evaluateJavaScript("if (typeof window.__gm_handleXhrError === 'function') { window.__gm_handleXhrError.apply(null, \(errJSON)); }", completionHandler: nil)
                        return
                    }

                    let httpResp = response as? HTTPURLResponse
                    let statusCode = httpResp?.statusCode ?? 200
                    let responseText: String
                    if let data = data {
                        responseText = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                    } else {
                        responseText = ""
                    }

                    var headerLines: [String] = []
                    if let allHeaders = httpResp?.allHeaderFields {
                        for (k, v) in allHeaders {
                            headerLines.append("\(k): \(v)")
                        }
                    }
                    let headersString = headerLines.joined(separator: "\r\n")
                    let finalUrlString = response?.url?.absoluteString ?? urlString
                    let needsBinary = (responseType == "arraybuffer" || responseType == "blob")
                    let base64String = (needsBinary ? data?.base64EncodedString() : nil) ?? ""

                    let callArgs: [Any] = [reqId, statusCode, responseText, headersString, finalUrlString, base64String]
                    let argsData = (try? JSONSerialization.data(withJSONObject: callArgs, options: [])) ?? Data()
                    let argsJSON = String(data: argsData, encoding: .utf8) ?? "[]"

                    self?.webView.evaluateJavaScript("if (typeof window.__gm_handleXhrResponse === 'function') { window.__gm_handleXhrResponse.apply(null, \(argsJSON)); }", completionHandler: nil)
                }
            }
            task.resume()
        }
    }

    private func handleBlobDataURL(_ dataUrlString: String, filename: String) {
        guard let commaIndex = dataUrlString.firstIndex(of: ",") else { return }
        let base64Part = String(dataUrlString[dataUrlString.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64Part, options: .ignoreUnknownCharacters) else { return }

        let destDir = DownloadCoordinator.getDownloadsDirectory()
        var cleanName = (filename as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanName.isEmpty { cleanName = "download_\(Int(Date().timeIntervalSince1970))" }

        let fm = FileManager.default
        var targetURL = destDir.appendingPathComponent(cleanName)
        var counter = 1
        let nameWithoutExt = (cleanName as NSString).deletingPathExtension
        let ext = (cleanName as NSString).pathExtension

        while fm.fileExists(atPath: targetURL.path) {
            let newName = ext.isEmpty ? "\(nameWithoutExt)_\(counter)" : "\(nameWithoutExt)_\(counter).\(ext)"
            targetURL = destDir.appendingPathComponent(newName)
            counter += 1
        }

        do {
            try data.write(to: targetURL)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("PromptBlobExportNotification"),
                    object: targetURL,
                    userInfo: [
                        "filename": targetURL.lastPathComponent,
                        "fileSize": data.count
                    ]
                )
            }
        } catch {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("DownloadFailedNotification"),
                    object: error.localizedDescription
                )
            }
        }
    }

    private func applyDesktopViewAdaptationIfNeeded() {
        let selectedItem = UserAgentStore.shared.getSelectedItem()
        let isDesktop = selectedItem.category == .desktop || selectedItem.id == "default_mac"
        guard isDesktop else { return }

        let js = """
        (function() {
            try {
                var meta = document.querySelector('meta[name="viewport"]');
                if (!meta) {
                    meta = document.createElement('meta');
                    meta.name = 'viewport';
                    (document.head || document.documentElement).appendChild(meta);
                }
                var screenW = window.screen.width || 390;
                var targetW = 1024;
                var scale = (screenW / targetW).toFixed(2);
                meta.content = 'width=' + targetW + ', initial-scale=' + scale + ', minimum-scale=0.1, maximum-scale=5.0, user-scalable=yes';

                var styleId = '__desktop_overflow_fix__';
                if (!document.getElementById(styleId)) {
                    var style = document.createElement('style');
                    style.id = styleId;
                    style.type = 'text/css';
                    style.innerHTML = `
                        html { overflow-x: auto !important; }
                        body { max-width: 100% !important; overflow-x: auto !important; }
                        video, iframe, object, embed { max-width: 100% !important; }
                        .player-container, #player, .video-player, .html5-video-player { max-width: 100% !important; }
                    `;
                    (document.head || document.documentElement).appendChild(style);
                }
            } catch(e) {}
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func injectInlineVideoHelper() {
        let js = """
        (function() {
            try {
                if (window.__inline_video_helper_injected__) return;
                window.__inline_video_helper_injected__ = true;

                function fixInlineVideo(v) {
                    if (!v) return;
                    v.setAttribute('playsinline', 'true');
                    v.setAttribute('webkit-playsinline', 'true');
                    v.playsInline = true;
                    if (v.webkitSupportsPresentationMode && typeof v.webkitSetPresentationMode === 'function') {
                        if (v.webkitPresentationMode === 'fullscreen') {
                            v.webkitSetPresentationMode('inline');
                        }
                    }
                }

                var videos = document.querySelectorAll('video');
                for (var i = 0; i < videos.length; i++) {
                    fixInlineVideo(videos[i]);
                }

                var observer = new MutationObserver(function(mutations) {
                    for (var i = 0; i < mutations.length; i++) {
                        var added = mutations[i].addedNodes;
                        for (var j = 0; j < added.length; j++) {
                            var node = added[j];
                            if (node.tagName === 'VIDEO') {
                                fixInlineVideo(node);
                            } else if (node.querySelectorAll) {
                                var innerVideos = node.querySelectorAll('video');
                                for (var k = 0; k < innerVideos.length; k++) {
                                    fixInlineVideo(innerVideos[k]);
                                }
                            }
                        }
                    }
                });

                observer.observe(document.documentElement || document.body, {
                    childList: true,
                    subtree: true
                });
            } catch(e) {}
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func extractHighResFaviconIfNeeded() {
        guard let currentHost = url?.host, !currentHost.isEmpty else { return }

        let js = """
        (function() {
            try {
                var links = document.querySelectorAll("link[rel*='icon'], link[rel*='apple-touch-icon']");
                var bestHref = null;
                var bestScore = -1;

                for (var i = 0; i < links.length; i++) {
                    var el = links[i];
                    var rel = (el.getAttribute('rel') || '').toLowerCase();
                    var href = el.href;
                    if (!href) continue;

                    var score = 0;
                    if (rel.indexOf('apple-touch-icon') !== -1) {
                        score += 1000;
                    }
                    var sizes = el.getAttribute('sizes') || '';
                    var match = sizes.match(/(\\d+)x(\\d+)/i);
                    if (match) {
                        score += parseInt(match[1], 10);
                    } else if (rel.indexOf('icon') !== -1) {
                        score += 50;
                    }

                    if (score > bestScore) {
                        bestScore = score;
                        bestHref = href;
                    }
                }
                if (!bestHref) {
                    bestHref = window.location.origin + '/favicon.ico';
                }
                return bestHref;
            } catch(e) {
                return window.location.origin + '/favicon.ico';
            }
        })();
        """

        webView.evaluateJavaScript(js) { result, _ in
            let httpsScheme = "https:" + String(repeating: "/", count: 2)
            let iconURLString = (result as? String) ?? "\(httpsScheme)\(currentHost)/favicon.ico"
            guard let iconURL = URL(string: iconURLString) else { return }

            var req = URLRequest(url: iconURL, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 4.0)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

            URLSession.shared.dataTask(with: req) { data, response, _ in
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let data = data, data.count > 100,
                   let img = UIImage(data: data), img.size.width >= 16 {
                    FaviconLoader.shared.saveHighResIcon(data: data, for: currentHost)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: NSNotification.Name("FaviconUpdatedNotification"), object: currentHost)
                    }
                }
            }.resume()
        }
    }

    func injectAndRunUserScripts() {
        applyDesktopViewAdaptationIfNeeded()
        injectInlineVideoHelper()

        let currentUrlStr = url?.absoluteString ?? ""
        let matchingScripts = UserScriptStore.shared.loadScripts().filter {
            UserScriptStore.shared.isScriptMatching(script: $0, urlString: currentUrlStr)
        }

        var fullJS = Self.coreGMPolyfillScriptSource + "\n"
        for script in matchingScripts {
            let valuesJSON = ScriptDataStore.shared.getAllValuesJSON(scriptId: script.id)
            fullJS += """
            (function(scriptId, initialValues) {
                var values = initialValues || {};
                var GM_info = {
                    scriptHandler: 'Tampermonkey',
                    version: '5.0.0',
                    script: { name: scriptId, version: '1.0' }
                };
                var GM_setValue = function(name, val) {
                    values[name] = val;
                    try {
                        window.webkit.messageHandlers.GM.postMessage({
                            action: 'setValue',
                            scriptId: scriptId,
                            name: name,
                            value: val
                        });
                    } catch(e) {}
                };
                var GM_getValue = function(name, defaultValue) {
                    return (name in values) ? values[name] : defaultValue;
                };
                var GM_deleteValue = function(name) {
                    delete values[name];
                    try {
                        window.webkit.messageHandlers.GM.postMessage({
                            action: 'deleteValue',
                            scriptId: scriptId,
                            name: name
                        });
                    } catch(e) {}
                };
                var GM_listValues = function() {
                    return Object.keys(values);
                };
                var GM_registerMenuCommand = function(caption, commandFunc) {
                    var id = Math.floor(Math.random() * 1000000);
                    window.__gm_menu_commands__[id] = commandFunc;
                    try {
                        window.webkit.messageHandlers.GM.postMessage({
                            action: 'registerMenuCommand',
                            id: id,
                            scriptId: scriptId,
                            caption: caption
                        });
                    } catch(e) {}
                    return id;
                };
                var GM_unregisterMenuCommand = function(id) {
                    delete window.__gm_menu_commands__[id];
                    try {
                        window.webkit.messageHandlers.GM.postMessage({
                            action: 'unregisterMenuCommand',
                            id: id
                        });
                    } catch(e) {}
                };
                var GM_xmlhttpRequest = window.GM_xmlhttpRequest;
                var GM_addStyle = window.GM_addStyle;
                var GM_openInTab = window.GM_openInTab;
                var GM_setClipboard = window.GM_setClipboard;
                var GM_notification = window.GM_notification;
                var GM_log = window.GM_log;
                var GM = {
                    info: GM_info,
                    getValue: function(k, d) { return Promise.resolve(GM_getValue(k, d)); },
                    setValue: function(k, v) { GM_setValue(k, v); return Promise.resolve(); },
                    deleteValue: function(k) { GM_deleteValue(k); return Promise.resolve(); },
                    listValues: function() { return Promise.resolve(GM_listValues()); },
                    xmlHttpRequest: function(opts) {
                        return new Promise(function(resolve, reject) {
                            var origOnload = opts.onload;
                            var origOnerror = opts.onerror;
                            opts.onload = function(res) {
                                if (origOnload) origOnload(res);
                                resolve(res);
                            };
                            opts.onerror = function(res) {
                                if (origOnerror) origOnerror(res);
                                reject(res);
                            };
                            GM_xmlhttpRequest(opts);
                        });
                    },
                    addStyle: window.GM_addStyle,
                    openInTab: window.GM_openInTab,
                    setClipboard: window.GM_setClipboard,
                    notification: window.GM_notification,
                    registerMenuCommand: function(c, f) { return Promise.resolve(GM_registerMenuCommand(c, f)); }
                };

                try {
                    \(script.code)
                } catch(e) {}
            })('\(script.id)', \(valuesJSON));
            \n
            """
        }

        webView.evaluateJavaScript(fullJS, completionHandler: nil)
    }

    func reloadUserScripts() {
        hasInjectedScriptsForCurrentPage = false
        registeredCommands.removeAll()
        webView.reload()
    }

    func updateSnapshot(completion: (() -> Void)? = nil) {
        guard webView.bounds.width > 0, webView.bounds.height > 0, !webView.isLoading else {
            completion?()
            return
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds

        webView.takeSnapshot(with: configuration) { [weak self] image, error in
            if error == nil, let image = image {
                self?.snapshot = image
            }
            completion?()
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            let host = challenge.protectionSpace.host.lowercased()
            if CertificateTrustStore.shared.isHostTrusted(host) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        completionHandler(nil)
    }

    func webView(
        _ webView: WKWebView,
        contextMenuForElement elementInfo: WKContextMenuElementInfo,
        willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating
    ) {
    }

    @available(iOS 15.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }

    func saveImageToPhotos(from imageString: String) {
        let raw = imageString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            delegate?.tabRequestShowToast("获取图片失败")
            return
        }

        if raw.contains("image/svg+xml") {
            convertSvgToImage(urlString: raw) { [weak self] img in
                if let img = img {
                    self?.writeImageToAlbum(img)
                } else {
                    self?.delegate?.tabRequestShowToast("保存图片失败")
                }
            }
            return
        }

        if raw.hasPrefix("data:") {
            guard let commaIndex = raw.firstIndex(of: ",") else {
                delegate?.tabRequestShowToast("图片格式无效")
                return
            }
            let meta = String(raw[..<commaIndex])
            let payload = String(raw[raw.index(after: commaIndex)...])

            if meta.contains("base64") {
                guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
                      let image = UIImage(data: data) else {
                    delegate?.tabRequestShowToast("图片解析失败")
                    return
                }
                writeImageToAlbum(image)
            } else {
                guard let decodedString = payload.removingPercentEncoding,
                      let _ = decodedString.data(using: .utf8) else {
                    delegate?.tabRequestShowToast("图片解析失败")
                    return
                }
                if meta.contains("image/svg+xml") {
                    convertSvgToImage(urlString: raw) { [weak self] img in
                        if let img = img {
                            self?.writeImageToAlbum(img)
                        } else {
                            self?.delegate?.tabRequestShowToast("保存图片失败")
                        }
                    }
                    return
                }
                guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
                      let image = UIImage(data: data) else {
                    delegate?.tabRequestShowToast("图片解析失败")
                    return
                }
                writeImageToAlbum(image)
            }
            return
        }

        if raw.hasPrefix("blob:") {
            let escapedBlob = raw.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let js = """
            (function() {
                return new Promise(function(resolve) {
                    fetch("\(escapedBlob)")
                        .then(function(r) { return r.blob(); })
                        .then(function(b) {
                            var reader = new FileReader();
                            reader.onloadend = function() { resolve({ success: true, data: reader.result }); };
                            reader.onerror = function() { resolve({ success: false, error: '读取Blob失败' }); };
                            reader.readAsDataURL(b);
                        })
                        .catch(function(e) { resolve({ success: false, error: e.toString() }); });
                });
            })();
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self = self else { return }
                if let dict = result as? [String: Any],
                   let success = dict["success"] as? Bool, success,
                   let dataUrl = dict["data"] as? String {
                    self.saveImageToPhotos(from: dataUrl)
                    return
                }
                self.delegate?.tabRequestShowToast("读取Blob图片失败")
            }
            return
        }

        guard let url = URL(string: raw) else {
            delegate?.tabRequestShowToast("无效图片链接")
            return
        }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12.0)
        request.setValue(webView.customUserAgent ?? UserAgentStore.shared.getSelectedUA(), forHTTPHeaderField: "User-Agent")
        if let currentURL = webView.url?.absoluteString {
            request.setValue(currentURL, forHTTPHeaderField: "Referer")
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 403 {
                var retryReq = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12.0)
                let allHeaders = (self?.webView.customUserAgent).map { ["User-Agent": $0] } ?? [:]
                for (k, v) in allHeaders {
                    retryReq.setValue(v, forHTTPHeaderField: k)
                }
                URLSession.shared.dataTask(with: retryReq) { [weak self] retryData, retryResp, retryErr in
                    self?.handleDownloadedImageData(data: retryData, response: retryResp, error: retryErr, originalURLString: raw)
                }.resume()
                return
            }
            self?.handleDownloadedImageData(data: data, response: response, error: error, originalURLString: raw)
        }.resume()
    }

    private func convertSvgToImage(urlString: String, completion: @escaping (UIImage?) -> Void) {
        let escaped = urlString.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let js = """
        (function() {
            return new Promise(function(resolve) {
                var img = new Image();
                img.crossOrigin = 'anonymous';
                img.onload = function() {
                    var c = document.createElement('canvas');
                    c.width = img.naturalWidth || 300;
                    c.height = img.naturalHeight || 300;
                    var ctx = c.getContext('2d');
                    ctx.drawImage(img, 0, 0);
                    resolve(c.toDataURL('image/png'));
                };
                img.onerror = function() { resolve(null); };
                img.src = "\(escaped)";
            });
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            if let dataUrl = result as? String, let comma = dataUrl.firstIndex(of: ",") {
                let base64 = String(dataUrl[dataUrl.index(after: comma)...])
                if let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
                   let image = UIImage(data: data) {
                    completion(image)
                    return
                }
            }
            completion(nil)
        }
    }

    private func handleDownloadedImageData(data: Data?, response: URLResponse?, error: Error?, originalURLString: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let data = data, let image = UIImage(data: data), (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true {
                self.writeImageToAlbum(image)
                return
            }

            let escaped = originalURLString.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let fallbackJS = """
            (function() {
                var targetSrc = "\(escaped)";
                var imgs = document.querySelectorAll('img');
                for (var i = 0; i < imgs.length; i++) {
                    if (imgs[i].currentSrc === targetSrc || imgs[i].src === targetSrc) {
                        try {
                            var c = document.createElement('canvas');
                            c.width = imgs[i].naturalWidth || imgs[i].width;
                            c.height = imgs[i].naturalHeight || imgs[i].height;
                            var ctx = c.getContext('2d');
                            ctx.drawImage(imgs[i], 0, 0);
                            return c.toDataURL('image/png');
                        } catch(e) {}
                    }
                }
                return null;
            })();
            """
            self.webView.evaluateJavaScript(fallbackJS) { [weak self] result, _ in
                if let dataUrl = result as? String, dataUrl.hasPrefix("data:image/") {
                    self?.saveImageToPhotos(from: dataUrl)
                    return
                }
                self?.delegate?.tabRequestShowToast("下载图片失败")
            }
        }
    }

    private func writeImageToAlbum(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(image(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc private func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        DispatchQueue.main.async { [weak self] in
            if error != nil {
                self?.delegate?.tabRequestShowToast("保存图片失败")
            } else {
                self?.delegate?.tabRequestShowToast("已保存图片到相册")
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        if !isLoadingFailureDocument {
            isDisplayingFailurePage = false
        }
        hasInjectedScriptsForCurrentPage = false
        registeredCommands.removeAll()
        ensureCoreScripts()
        userScrolledDuringLoading = false
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hideReloadCover()
        if !isDisplayingFailurePage, let currentURL = webView.url, !currentURL.absoluteString.contains("about:blank") {
            if previousURL != currentURL {
                previousURL = url
            }
            url = currentURL
            title = webView.title ?? url?.host ?? "新标签页"
        }
        ensureCoreScripts()
        applyDesktopViewAdaptationIfNeeded()
        injectInlineVideoHelper()
        if !hasInjectedScriptsForCurrentPage {
            hasInjectedScriptsForCurrentPage = true
            injectAndRunUserScripts()
        }
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideReloadCover()
        isLoading = false
        if !isDisplayingFailurePage {
            url = webView.url
            title = webView.title ?? url?.host ?? "新标签页"
        }
        extractHighResFaviconIfNeeded()

        if userScrolledDuringLoading {
            let currentOffset = webView.scrollView.contentOffset
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.userScrolledDuringLoading else { return }
                if self.webView.scrollView.contentOffset != currentOffset && !self.webView.scrollView.isDragging {
                    self.webView.scrollView.setContentOffset(currentOffset, animated: false)
                }
            }
        }

        delegate?.tabDidUpdate(self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hideReloadCover()
        isLoading = false
        delegate?.tabProcessTerminated(self)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        hideReloadCover()
        isLoading = false
        if shouldIgnoreNavigationError(error) {
            delegate?.tabDidUpdate(self)
            return
        }
        isDisplayingFailurePage = true
        failedURL = navigationActionURL ?? webView.url
        failureError = error
        delegate?.tabDidFail(self, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        hideReloadCover()
        isLoading = false
        if shouldIgnoreNavigationError(error) {
            delegate?.tabDidUpdate(self)
            return
        }
        isDisplayingFailurePage = true
        failedURL = navigationActionURL ?? webView.url
        failureError = error
        delegate?.tabDidFail(self, error: error)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = DownloadCoordinator.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = DownloadCoordinator.shared
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        guard let targetURL = navigationAction.request.url else {
            decisionHandler(.cancel, preferences)
            return
        }

        navigationActionURL = targetURL

        let selectedItem = UserAgentStore.shared.getSelectedItem()
        let isDesktopMode = selectedItem.category == .desktop || selectedItem.id == "default_mac"
        preferences.preferredContentMode = isDesktopMode ? .desktop : .mobile

        let scheme = targetURL.scheme?.lowercased() ?? ""

        if ["http", "https"].contains(scheme),
           navigationAction.targetFrame != nil,
           targetURL != url {
            failureOriginURL = url
        }

        if targetURL.path.hasSuffix(".user.js") || targetURL.absoluteString.hasSuffix(".user.js") {
            decisionHandler(.cancel, preferences)
            NotificationCenter.default.post(
                name: NSNotification.Name("InstallUserScriptNotification"),
                object: targetURL
            )
            return
        }

        let ext = targetURL.pathExtension.lowercased()
        let knownDownloadExtensions: Set<String> = [
            "ipa", "apk", "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz",
            "dmg", "pkg", "deb", "torrent", "iso", "bin", "exe", "msi"
        ]
        if navigationAction.shouldPerformDownload || knownDownloadExtensions.contains(ext) {
            decisionHandler(.download, preferences)
            return
        }

        if ["http", "https", "about", "data", "blob"].contains(scheme) {
            if navigationAction.targetFrame == nil {
                decisionHandler(.cancel, preferences)
                webView.load(navigationAction.request)
                return
            }

            decisionHandler(.allow, preferences)
            return
        }

        decisionHandler(.cancel, preferences)

        if scheme == "intent", let fallbackURL = fallbackURL(from: targetURL) {
            webView.load(URLRequest(url: fallbackURL))
            return
        }

        UIApplication.shared.open(targetURL, options: [:], completionHandler: nil)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            let disposition = (httpResponse.allHeaderFields["Content-Disposition"] as? String ?? httpResponse.allHeaderFields["content-disposition"] as? String ?? "").lowercased()
            if disposition.contains("attachment") || !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
                return
            }
        }

        decisionHandler(.allow)
    }

    private func shouldIgnoreNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
            return true
        }

        if nsError.domain == WKError.errorDomain {
            if nsError.code == WKError.Code.webContentProcessTerminated.rawValue {
                return true
            }
        }

        return false
    }

    private func fallbackURL(from intentURL: URL) -> URL? {
        let value = intentURL.absoluteString

        guard let range = value.range(of: "S.browser_fallback_url=") else {
            return nil
        }

        let content = String(value[range.upperBound...])
        let encoded = content.components(separatedBy: ";").first ?? content
        let decoded = encoded.removingPercentEncoding ?? encoded

        return URL(string: decoded)
    }
}
