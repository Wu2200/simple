import UIKit
import WebKit

protocol TabItemDelegate: AnyObject {
    func tabDidUpdate(_ tab: TabItem)
    func tabDidFail(_ tab: TabItem, error: Error)
    func tabRequestNewTab(url: URL, inBackground: Bool)
    func tabProcessTerminated(_ tab: TabItem)
    func tabRequestGoBack(_ tab: TabItem)
    func tabRequestShowToast(_ message: String)
}

final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, WKDownloadDelegate {
    static let shared = DownloadCoordinator()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private var downloadTasks: [URLSessionDownloadTask: (filename: String, targetURL: URL)] = [:]

    private override init() {
        super.init()
    }

    static func getDownloadsDirectory() -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloads = docs.appendingPathComponent("Downloads", isDirectory: true)
        if !fm.fileExists(atPath: downloads.path) {
            try? fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        }
        return downloads
    }

    func startDownload(url: URL, filename: String) {
        let destDir = Self.getDownloadsDirectory()
        let rawName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = "download_\(Int(Date().timeIntervalSince1970))"
        let baseFilename = rawName.isEmpty ? fallbackName : rawName

        let fm = FileManager.default
        var targetURL = destDir.appendingPathComponent(baseFilename)
        var counter = 1
        let nameWithoutExt = (baseFilename as NSString).deletingPathExtension
        let ext = (baseFilename as NSString).pathExtension

        while fm.fileExists(atPath: targetURL.path) {
            let newName = ext.isEmpty ? "\(nameWithoutExt)_\(counter)" : "\(nameWithoutExt)_\(counter).\(ext)"
            targetURL = destDir.appendingPathComponent(newName)
            counter += 1
        }

        let task = session.downloadTask(with: url)
        downloadTasks[task] = (baseFilename, targetURL)
        task.resume()

        NotificationCenter.default.post(
            name: NSNotification.Name("DownloadStartedNotification"),
            object: baseFilename
        )
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = downloadTasks[downloadTask] else { return }
        downloadTasks.removeValue(forKey: downloadTask)

        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: info.targetURL.path) {
                try fm.removeItem(at: info.targetURL)
            }
            try fm.moveItem(at: location, to: info.targetURL)
            NotificationCenter.default.post(
                name: NSNotification.Name("DownloadFinishedNotification"),
                object: info.targetURL.lastPathComponent
            )
        } catch {
            NotificationCenter.default.post(
                name: NSNotification.Name("DownloadFailedNotification"),
                object: error.localizedDescription
            )
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask, let error = error else { return }
        if downloadTasks[downloadTask] != nil {
            downloadTasks.removeValue(forKey: downloadTask)
            NotificationCenter.default.post(
                name: NSNotification.Name("DownloadFailedNotification"),
                object: error.localizedDescription
            )
        }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let filename = suggestedFilename.isEmpty ? "download_\(Int(Date().timeIntervalSince1970))" : suggestedFilename
        let host = response.url?.host ?? response.url?.absoluteString ?? "未知来源"

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("PromptDownloadNotification"),
                object: response.url,
                userInfo: [
                    "filename": filename,
                    "host": host,
                    "onConfirm": { (shouldDownload: Bool) in
                        if shouldDownload {
                            let destDir = Self.getDownloadsDirectory()
                            var targetURL = destDir.appendingPathComponent(filename)
                            let nameWithoutExt = (filename as NSString).deletingPathExtension
                            let ext = (filename as NSString).pathExtension
                            var counter = 1
                            let fm = FileManager.default
                            while fm.fileExists(atPath: targetURL.path) {
                                let newName = ext.isEmpty ? "\(nameWithoutExt)_\(counter)" : "\(nameWithoutExt)_\(counter).\(ext)"
                                targetURL = destDir.appendingPathComponent(newName)
                                counter += 1
                            }

                            NotificationCenter.default.post(
                                name: NSNotification.Name("DownloadStartedNotification"),
                                object: filename
                            )
                            completionHandler(targetURL)
                        } else {
                            completionHandler(nil)
                        }
                    } as (Bool) -> Void
                ]
            )
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        NotificationCenter.default.post(
            name: NSNotification.Name("DownloadFinishedNotification"),
            object: nil
        )
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        NotificationCenter.default.post(
            name: NSNotification.Name("DownloadFailedNotification"),
            object: error.localizedDescription
        )
    }
}

final class TabItem: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id = UUID()
    let webView: WKWebView
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
    private var pendingRestoreURL: URL?

    private var hasInjectedScriptsForCurrentPage = false
    private var isLoadingFailureDocument = false
    private var navigationActionURL: URL?

    weak var delegate: TabItemDelegate?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true

        let selectedItem = UserAgentStore.shared.getSelectedItem()
        let isDesktop = selectedItem.category == .desktop || selectedItem.id == "default_mac"
        configuration.defaultWebpagePreferences.preferredContentMode = isDesktop ? .desktop : .mobile

        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController

        let downloadBridgeSource = """
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
        let downloadScript = WKUserScript(
            source: downloadBridgeSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        userContentController.addUserScript(downloadScript)

        let touchScriptSource = """
        (function() {
            if (window.__simple_touch_injected__) return;
            window.__simple_touch_injected__ = true;
            window.__simple_last_touch = null;
            window.__simple_context_target = null;

            function saveTouch(e) {
                var t = (e.touches && e.touches.length > 0) ? e.touches[0] : (e.changedTouches && e.changedTouches.length > 0 ? e.changedTouches[0] : e);
                if (t && typeof t.clientX === 'number') {
                    window.__simple_last_touch = {
                        x: t.clientX,
                        y: t.clientY,
                        target: e.target
                    };
                }
            }

            window.addEventListener('touchstart', saveTouch, { capture: true, passive: true });
            window.addEventListener('touchmove', saveTouch, { capture: true, passive: true });
            window.addEventListener('pointerdown', saveTouch, { capture: true, passive: true });
            window.addEventListener('contextmenu', function(e) {
                saveTouch(e);
                window.__simple_context_target = e.target;
            }, { capture: true, passive: true });
        })();
        """
        let touchScript = WKUserScript(
            source: touchScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        userContentController.addUserScript(touchScript)

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.customUserAgent = UserAgentStore.shared.getSelectedUA()

        AdBlockManager.shared.attach(to: webView)
        userContentController.add(self, name: "GM")
        userContentController.add(self, name: "DownloadBridge")

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = true
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .onDrag
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.isOpaque = true
    }

    deinit {
        destroy()
    }

    func destroy() {
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
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        webView.removeFromSuperview()
        snapshot = nil
    }

    func clearFailureState() {
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
            var request = URLRequest(url: targetURL)
            request.httpMethod = method

            if let headers = body["headers"] as? [String: String] {
                for (k, v) in headers {
                    request.setValue(v, forHTTPHeaderField: k)
                }
            }

            if let dataString = body["data"] as? String {
                request.httpBody = dataString.data(using: .utf8)
            }

            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    if let error = error {
                        let errData = (try? JSONSerialization.data(withJSONObject: [error.localizedDescription], options: [])) ?? Data()
                        let errJSON = String(data: errData, encoding: .utf8) ?? "[\"\"]"
                        let unwrappedErr = String(errJSON.dropFirst().dropLast())
                        self?.webView.evaluateJavaScript("window.__gm_handleXhrError('\(reqId)', \(unwrappedErr))", completionHandler: nil)
                        return
                    }

                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
                    let responseText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let jsonTextData = try? JSONSerialization.data(withJSONObject: [responseText], options: [])
                    let jsonText = jsonTextData.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
                    let unwrappedText = String(jsonText.dropFirst().dropLast())

                    self?.webView.evaluateJavaScript("window.__gm_handleXhrResponse('\(reqId)', \(statusCode), \(unwrappedText))", completionHandler: nil)
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
            let iconURLString = (result as? String) ?? "https://\(currentHost)/favicon.ico"
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

        let gmPolyfillBase = """
        if (!window.__gm_polyfilled__) {
            window.__gm_polyfilled__ = true;
            window.unsafeWindow = window;
            window.__gm_menu_commands__ = window.__gm_menu_commands__ || {};

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
                        timeout: opts.timeout || 0
                    });
                } catch(e) {
                    if (opts.onerror) opts.onerror({ status: 0, responseText: e.toString() });
                }
            };
            window.__handleXhrResponse = function(id, status, text) {
                var opts = window.__gm_xhr_callbacks__[id];
                if (!opts) return;
                delete window.__gm_xhr_callbacks__[id];
                var res = {
                    status: status,
                    statusText: status === 200 ? 'OK' : 'Error',
                    responseText: text,
                    response: text,
                    readyState: 4,
                    finalUrl: opts.url
                };
                if (opts.onload) opts.onload(res);
                if (opts.onreadystatechange) opts.onreadystatechange(res);
            };
            window.__handleXhrError = function(id, errorText) {
                var opts = window.__gm_xhr_callbacks__[id];
                if (!opts) return;
                delete window.__gm_xhr_callbacks__[id];
                var res = { status: 0, statusText: errorText, responseText: errorText, response: errorText, readyState: 4 };
                if (opts.onerror) opts.onerror(res);
            };
        }
        """

        var fullJS = gmPolyfillBase + "\n"
        for script in matchingScripts {
            let valuesJSON = ScriptDataStore.shared.getAllValuesJSON(scriptId: script.id)
            fullJS += """
            (function(scriptId, initialValues) {
                var values = initialValues || {};
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
                var GM = {
                    getValue: function(k, d) { return Promise.resolve(GM_getValue(k, d)); },
                    setValue: function(k, v) { GM_setValue(k, v); return Promise.resolve(); },
                    deleteValue: function(k) { GM_deleteValue(k); return Promise.resolve(); },
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
        let rawLink = elementInfo.linkURL?.absoluteString ?? ""
        let escapedLink = rawLink.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

        let inspectJS = """
        (function() {
            var touch = window.__simple_last_touch;
            var ctxTarget = window.__simple_context_target;
            var directTarget = ctxTarget || (touch ? touch.target : null);
            var tx = touch ? touch.x : -1;
            var ty = touch ? touch.y : -1;
            var fallbackLink = "\(escapedLink)";

            function cleanURL(u) {
                if (!u || typeof u !== 'string') return '';
                var trimmed = u.trim().replace(/^["']|["']$/g, '');
                if (trimmed.startsWith('data:') || trimmed.startsWith('blob:')) return trimmed;
                try {
                    return new URL(trimmed, window.location.href).href;
                } catch(e) {
                    return trimmed;
                }
            }

            function isRealImg(s) {
                if (!s || typeof s !== 'string') return false;
                var trimmed = s.trim().replace(/^["']|["']$/g, '');
                if (!trimmed) return false;
                if (trimmed.startsWith('data:image/svg+xml')) return true;
                if (trimmed.startsWith('data:image/')) {
                    if (trimmed.length < 150 && trimmed.indexOf('R0lGODlhAQAB') !== -1) return false;
                    return true;
                }
                if (trimmed.startsWith('blob:')) return true;
                var lower = trimmed.toLowerCase();
                if (lower.indexOf('blank.gif') !== -1 || lower.indexOf('pixel.gif') !== -1 || lower.indexOf('spacer.gif') !== -1) return false;
                return lower.startsWith('http://') || lower.startsWith('https://') || lower.startsWith('//');
            }

            function parseSrcset(val) {
                if (!val) return '';
                var parts = val.split(',');
                var bestUrl = '';
                var maxW = 0;
                for (var k = 0; k < parts.length; k++) {
                    var item = parts[k].trim().split(/\\s+/);
                    if (item.length > 0 && item[0]) {
                        var w = 0;
                        if (item.length > 1) {
                            var m = item[1].match(/(\\d+)/);
                            if (m) w = parseInt(m[1], 10);
                        }
                        if (w >= maxW) {
                            maxW = w;
                            bestUrl = item[0];
                        }
                    }
                }
                return bestUrl;
            }

            function extractImageFromNode(node) {
                if (!node) return '';
                var tag = (node.tagName || '').toUpperCase();
                if (tag === 'IMG' || tag === 'AMP-IMG') {
                    var candidates = [
                        node.currentSrc,
                        node.src,
                        node.getAttribute('src'),
                        node.getAttribute('data-original'),
                        node.getAttribute('data-src'),
                        node.getAttribute('data-actualsrc'),
                        node.getAttribute('data-lazy-src'),
                        node.getAttribute('data-url'),
                        node.getAttribute('data-orig'),
                        node.getAttribute('data-cover'),
                        node.getAttribute('data-echo'),
                        node.getAttribute('srcset'),
                        node.getAttribute('data-srcset')
                    ];
                    for (var cIdx = 0; cIdx < candidates.length; cIdx++) {
                        var c = candidates[cIdx];
                        if (c) {
                            var p = parseSrcset(c) || c;
                            if (isRealImg(p)) return cleanURL(p);
                        }
                    }
                }
                if (tag === 'PICTURE') {
                    var sources = node.querySelectorAll('source');
                    for (var sIdx = 0; sIdx < sources.length; sIdx++) {
                        var ss = sources[sIdx].getAttribute('srcset') || sources[sIdx].getAttribute('src');
                        if (ss) {
                            var parsed = parseSrcset(ss) || ss;
                            if (isRealImg(parsed)) return cleanURL(parsed);
                        }
                    }
                    var inner = node.querySelector('img, amp-img');
                    if (inner) {
                        var fromInner = extractImageFromNode(inner);
                        if (fromInner) return fromInner;
                    }
                }
                if (tag === 'CANVAS') {
                    try { return node.toDataURL('image/png'); } catch(e) { return ''; }
                }
                if (tag === 'VIDEO' && node.poster && isRealImg(node.poster)) {
                    return cleanURL(node.poster);
                }
                try {
                    var bg = window.getComputedStyle(node).backgroundImage;
                    if (bg && bg !== 'none' && bg.indexOf('url(') !== -1) {
                        var m = bg.match(/url\\(['"]?(.*?)['"]?\\)/i);
                        if (m && m[1] && isRealImg(m[1])) return cleanURL(m[1]);
                    }
                } catch(e) {}
                return '';
            }

            function findBestImageInContainer(container, targetX, targetY) {
                if (!container) return null;
                var direct = extractImageFromNode(container);
                if (direct) {
                    var dr = container.getBoundingClientRect ? container.getBoundingClientRect() : null;
                    return { src: direct, el: container, rect: dr };
                }
                if (!container.querySelectorAll) return null;

                var elements = container.querySelectorAll('img, amp-img, picture, canvas, [style*="background-image"], [data-src], [data-original]');
                if (elements.length === 0) return null;

                var best = null;
                var bestScore = -Infinity;

                for (var elIdx = 0; elIdx < elements.length; elIdx++) {
                    var el = elements[elIdx];
                    var src = extractImageFromNode(el);
                    if (!src) continue;

                    var r = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
                    var w = r ? r.width : (el.offsetWidth || el.naturalWidth || 0);
                    var h = r ? r.height : (el.offsetHeight || el.naturalHeight || 0);
                    var area = w * h;

                    var isTiny = (w > 0 && h > 0 && (w <= 24 || h <= 24));
                    var lowerSrc = src.toLowerCase();
                    var isFavicon = (lowerSrc.indexOf('favicon') !== -1 || lowerSrc.indexOf('site_icon') !== -1 || (el.className && el.className.toString().toLowerCase().indexOf('favicon') !== -1));

                    var score = area;

                    if (targetX >= 0 && targetY >= 0 && r && (r.width > 0 || r.height > 0)) {
                        var inside = (targetX >= r.left - 10 && targetX <= r.right + 10 && targetY >= r.top - 10 && targetY <= r.bottom + 10);
                        if (inside) {
                            score += 1000000;
                        } else {
                            var cx = (r.left + r.right) / 2;
                            var cy = (r.top + r.bottom) / 2;
                            var dist = Math.hypot(targetX - cx, targetY - cy);
                            score -= dist * 250;
                        }
                    }

                    if (isTiny || isFavicon) {
                        score -= 500000;
                    }

                    if (score > bestScore) {
                        bestScore = score;
                        best = { src: src, el: el, rect: r };
                    }
                }
                return best;
            }

            var resolvedImg = '';
            var resolvedLink = fallbackLink ? cleanURL(fallbackLink) : '';
            var targetRect = null;

            if (directTarget) {
                var fromDirect = findBestImageInContainer(directTarget, tx, ty);
                if (fromDirect && fromDirect.src) {
                    resolvedImg = fromDirect.src;
                    targetRect = fromDirect.rect;
                }
                if (!resolvedLink) {
                    var directA = directTarget.tagName === 'A' ? directTarget : (directTarget.closest ? directTarget.closest('a') : null);
                    if (directA) {
                        resolvedLink = cleanURL(directA.href || directA.getAttribute('href') || '');
                    }
                }
            }

            if (!resolvedImg && tx >= 0 && ty >= 0) {
                var probePoints = [
                    { x: tx, y: ty },
                    { x: tx - 8, y: ty },
                    { x: tx + 8, y: ty },
                    { x: tx, y: ty - 8 },
                    { x: tx, y: ty + 8 },
                    { x: tx - 16, y: ty },
                    { x: tx + 16, y: ty },
                    { x: tx, y: ty - 16 },
                    { x: tx, y: ty + 16 }
                ];

                for (var pIdx = 0; pIdx < probePoints.length; pIdx++) {
                    var pt = probePoints[pIdx];
                    var els = [];
                    if (document.elementsFromPoint) {
                        els = document.elementsFromPoint(pt.x, pt.y) || [];
                    }
                    for (var eIdx = 0; eIdx < els.length; eIdx++) {
                        var el = els[eIdx];
                        if (!el || el === document.body || el === document.documentElement) continue;

                        if (!resolvedLink) {
                            var a = el.tagName === 'A' ? el : (el.closest ? el.closest('a') : null);
                            if (a) {
                                resolvedLink = cleanURL(a.href || a.getAttribute('href') || '');
                            }
                        }

                        if (!resolvedImg) {
                            var found = findBestImageInContainer(el, tx, ty);
                            if (found && found.src) {
                                resolvedImg = found.src;
                                targetRect = found.rect;
                            }
                        }

                        if (resolvedImg && resolvedLink) break;
                    }
                    if (resolvedImg) break;
                }
            }

            if (!resolvedImg && directTarget) {
                var cur = directTarget;
                var depth = 0;
                while (cur && depth < 8 && cur !== document.body && cur !== document.documentElement) {
                    if (!resolvedLink && cur.tagName === 'A') {
                        resolvedLink = cleanURL(cur.href || cur.getAttribute('href') || '');
                    }
                    if (!resolvedImg) {
                        var foundParent = findBestImageInContainer(cur, tx, ty);
                        if (foundParent && foundParent.src) {
                            resolvedImg = foundParent.src;
                            targetRect = foundParent.rect;
                        }
                    }
                    cur = cur.parentElement;
                    depth++;
                }
            }

            if (!resolvedImg && resolvedLink) {
                var allA = document.querySelectorAll('a');
                for (var aIdx = 0; aIdx < allA.length; aIdx++) {
                    var anc = allA[aIdx];
                    var aHref = cleanURL(anc.href || anc.getAttribute('href') || '');
                    if (aHref && (aHref === resolvedLink || resolvedLink.startsWith(aHref) || aHref.startsWith(resolvedLink))) {
                        var foundInA = findBestImageInContainer(anc, tx, ty);
                        if (foundInA && foundInA.src) {
                            resolvedImg = foundInA.src;
                            targetRect = foundInA.rect;
                            break;
                        }
                        var card = anc.closest ? anc.closest('.g, .MjjYud, [data-ved], [data-hveid], article, li, .result, .c-container, .tF2Cxc, div') : null;
                        if (card) {
                            var foundInCard = findBestImageInContainer(card, tx, ty);
                            if (foundInCard && foundInCard.src) {
                                resolvedImg = foundInCard.src;
                                targetRect = foundInCard.rect;
                                break;
                            }
                        }
                    }
                }
            }

            var rectData = null;
            if (targetRect && targetRect.width > 0 && targetRect.height > 0) {
                rectData = {
                    x: targetRect.left,
                    y: targetRect.top,
                    width: targetRect.width,
                    height: targetRect.height
                };
            }

            return {
                imgSrc: resolvedImg,
                linkHref: resolvedLink,
                rect: rectData
            };
        })();
        """

        webView.evaluateJavaScript(inspectJS) { [weak self] result, _ in
            guard let self = self else {
                completionHandler(nil)
                return
            }

            var detectedLinkURL = elementInfo.linkURL
            var detectedImageString: String? = nil
            var detectedRect: CGRect? = nil

            if let dict = result as? [String: Any] {
                if detectedLinkURL == nil, let linkHref = dict["linkHref"] as? String, !linkHref.isEmpty {
                    detectedLinkURL = URL(string: linkHref)
                }
                if let imgSrc = dict["imgSrc"] as? String, !imgSrc.isEmpty {
                    detectedImageString = imgSrc
                }
                if let rDict = dict["rect"] as? [String: Any],
                   let rx = rDict["x"] as? CGFloat,
                   let ry = rDict["y"] as? CGFloat,
                   let rw = rDict["width"] as? CGFloat,
                   let rh = rDict["height"] as? CGFloat,
                   rw > 0, rh > 0 {
                    detectedRect = CGRect(x: rx, y: ry, width: rw, height: rh)
                }
            }

            guard detectedLinkURL != nil || (detectedImageString != nil && !detectedImageString!.isEmpty) else {
                completionHandler(nil)
                return
            }

            let finalLink = detectedLinkURL
            let finalImageString = detectedImageString
            let finalRect = detectedRect

            let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self = self else { return UIMenu(title: "", children: []) }
                var actions: [UIMenuElement] = []

                if let imageStr = finalImageString, !imageStr.isEmpty {
                    let saveImageAction = UIAction(title: "保存图片", image: UIImage(systemName: "arrow.down.to.line")) { [weak self] _ in
                        self?.saveImageToPhotos(from: imageStr, fallbackRect: finalRect)
                    }
                    let copyImageLinkAction = UIAction(title: "拷贝图片链接", image: UIImage(systemName: "link")) { [weak self] _ in
                        UIPasteboard.general.string = imageStr
                        self?.delegate?.tabRequestShowToast("已拷贝图片链接")
                    }
                    actions.append(contentsOf: [saveImageAction, copyImageLinkAction])

                    if let imgURL = URL(string: imageStr), imgURL.scheme?.hasPrefix("http") == true {
                        let openImageAction = UIAction(title: "在新标签打开图片", image: UIImage(systemName: "arrow.up.right.square")) { [weak self] _ in
                            self?.delegate?.tabRequestNewTab(url: imgURL, inBackground: false)
                        }
                        actions.append(openImageAction)
                    }
                }

                if let link = finalLink {
                    let isLinkSameAsImage = (finalImageString != nil && link.absoluteString == finalImageString)
                    if !isLinkSameAsImage {
                        let linkTitle = (finalImageString != nil) ? "打开网页链接" : "新标签打开"
                        let backgroundTitle = (finalImageString != nil) ? "后台打开网页" : "后台打开"
                        let copyTitle = (finalImageString != nil) ? "拷贝网页链接" : "拷贝链接"

                        let openAction = UIAction(title: linkTitle, image: UIImage(systemName: "safari")) { [weak self] _ in
                            self?.delegate?.tabRequestNewTab(url: link, inBackground: false)
                        }
                        let backgroundAction = UIAction(title: backgroundTitle, image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                            self?.delegate?.tabRequestNewTab(url: link, inBackground: true)
                        }
                        let copyLinkAction = UIAction(title: copyTitle, image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                            UIPasteboard.general.string = link.absoluteString
                            self?.delegate?.tabRequestShowToast("已拷贝链接")
                        }
                        actions.append(contentsOf: [openAction, backgroundAction, copyLinkAction])
                    }
                }

                return UIMenu(title: "", children: actions)
            }

            completionHandler(config)
        }
    }

    func webView(
        _ webView: WKWebView,
        contextMenuForElement elementInfo: WKContextMenuElementInfo,
        willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating
    ) {
    }

    private func saveImageToPhotos(from imageString: String, fallbackRect: CGRect? = nil) {
        let raw = imageString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            fallbackSaveViaSnapshot(rect: fallbackRect)
            return
        }

        if raw.hasPrefix("data:") {
            guard let commaIndex = raw.firstIndex(of: ",") else {
                fallbackSaveViaSnapshot(rect: fallbackRect)
                return
            }
            let meta = String(raw[..<commaIndex])
            var payload = String(raw[raw.index(after: commaIndex)...])

            if meta.contains(";base64") {
                if let unescaped = payload.removingPercentEncoding {
                    payload = unescaped
                }
                payload = payload.replacingOccurrences(of: "\n", with: "")
                                 .replacingOccurrences(of: "\r", with: "")
                                 .replacingOccurrences(of: " ", with: "+")
                                 .trimmingCharacters(in: .whitespacesAndNewlines)
                let rem = payload.count % 4
                if rem > 0 {
                    payload.append(String(repeating: "=", count: 4 - rem))
                }
                guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
                      let image = UIImage(data: data) else {
                    fallbackSaveViaSnapshot(rect: fallbackRect)
                    return
                }
                writeImageToAlbum(image)
            } else {
                if let decodedString = payload.removingPercentEncoding,
                   let data = decodedString.data(using: .utf8),
                   let image = UIImage(data: data) {
                    writeImageToAlbum(image)
                } else {
                    fallbackSaveViaSnapshot(rect: fallbackRect)
                }
            }
            return
        }

        if raw.hasPrefix("blob:") {
            let escapedBlob = raw.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let js = """
            (function() {
                return fetch("\(escapedBlob)").then(function(res) {
                    if (!res.ok) throw new Error('HTTP ' + res.status);
                    return res.blob();
                }).then(function(blob) {
                    return new Promise(function(resolve, reject) {
                        var reader = new FileReader();
                        reader.onloadend = function() {
                            if (reader.result) {
                                resolve({ success: true, data: reader.result });
                            } else {
                                reject(new Error('读取失败'));
                            }
                        };
                        reader.onerror = function() { reject(new Error('读取错误')); };
                        reader.readAsDataURL(blob);
                    });
                }).catch(function(err) {
                    return { success: false, error: err.message || '获取图片失败' };
                });
            })();
            """
            webView.evaluateJavaScript(js) { [weak self] result, error in
                guard let self = self else { return }
                if let dict = result as? [String: Any],
                   let success = dict["success"] as? Bool, success,
                   let dataUrl = dict["data"] as? String {
                    self.saveImageToPhotos(from: dataUrl, fallbackRect: fallbackRect)
                    return
                }
                self.fallbackSaveViaSnapshot(rect: fallbackRect)
            }
            return
        }

        guard let url = URL(string: raw) else {
            fallbackSaveViaSnapshot(rect: fallbackRect)
            return
        }

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15.0)
            request.setValue(self.webView.customUserAgent ?? UserAgentStore.shared.getSelectedUA(), forHTTPHeaderField: "User-Agent")
            if let currentReferer = self.webView.url?.absoluteString {
                request.setValue(currentReferer, forHTTPHeaderField: "Referer")
            }
            let matchingCookies = cookies.filter { cookie in
                guard let host = url.host?.lowercased() else { return false }
                let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                return host == domain || host.hasSuffix("." + domain)
            }
            let headerFields = HTTPCookie.requestHeaderFields(with: matchingCookies)
            for (k, v) in headerFields {
                request.setValue(v, forHTTPHeaderField: k)
            }

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }
                if let httpResponse = response as? HTTPURLResponse, (httpResponse.statusCode == 403 || httpResponse.statusCode == 401),
                   let currentReferer = self.webView.url?.absoluteString, !currentReferer.isEmpty {
                    var retryReq = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15.0)
                    retryReq.setValue(self.webView.customUserAgent ?? UserAgentStore.shared.getSelectedUA(), forHTTPHeaderField: "User-Agent")
                    for (k, v) in headerFields {
                        retryReq.setValue(v, forHTTPHeaderField: k)
                    }
                    URLSession.shared.dataTask(with: retryReq) { [weak self] retryData, retryResp, retryErr in
                        self?.handleDownloadedImageData(data: retryData, response: retryResp, error: retryErr, originalURLString: raw, fallbackRect: fallbackRect)
                    }.resume()
                    return
                }
                self.handleDownloadedImageData(data: data, response: response, error: error, originalURLString: raw, fallbackRect: fallbackRect)
            }.resume()
        }
    }

    private func handleDownloadedImageData(data: Data?, response: URLResponse?, error: Error?, originalURLString: String, fallbackRect: CGRect?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let data = data, let image = UIImage(data: data), (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true {
                self.writeImageToAlbum(image)
                return
            }

            let escapedImg = originalURLString.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let fallbackJS = """
            (function() {
                var targetSrc = "\(escapedImg)";
                var imgs = document.querySelectorAll('img, amp-img');
                for (var i = 0; i < imgs.length; i++) {
                    var item = imgs[i];
                    if (item.currentSrc === targetSrc || item.src === targetSrc || item.getAttribute('src') === targetSrc) {
                        try {
                            var canvas = document.createElement('canvas');
                            canvas.width = item.naturalWidth || item.width || 300;
                            canvas.height = item.naturalHeight || item.height || 300;
                            var ctx = canvas.getContext('2d');
                            ctx.drawImage(item, 0, 0);
                            return canvas.toDataURL('image/png');
                        } catch(e) {
                            return '';
                        }
                    }
                }
                return '';
            })();
            """
            self.webView.evaluateJavaScript(fallbackJS) { [weak self] result, _ in
                if let dataUrl = result as? String, dataUrl.hasPrefix("data:image/") {
                    self?.saveImageToPhotos(from: dataUrl, fallbackRect: fallbackRect)
                    return
                }
                self?.fallbackSaveViaSnapshot(rect: fallbackRect)
            }
        }
    }

    private func fallbackSaveViaSnapshot(rect: CGRect?) {
        guard let rect = rect, rect.width > 8, rect.height > 8, webView.bounds.width > 0, webView.bounds.height > 0 else {
            delegate?.tabRequestShowToast("保存图片失败")
            return
        }

        let intersectRect = rect.intersection(webView.bounds)
        guard intersectRect.width > 8, intersectRect.height > 8 else {
            delegate?.tabRequestShowToast("保存图片失败")
            return
        }

        let config = WKSnapshotConfiguration()
        config.rect = intersectRect
        config.afterScreenUpdates = true

        webView.takeSnapshot(with: config) { [weak self] image, error in
            if let image = image, error == nil {
                self?.writeImageToAlbum(image)
            } else {
                self?.delegate?.tabRequestShowToast("保存图片失败")
            }
        }
    }

    private func writeImageToAlbum(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(image(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc private func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if let error = error {
            delegate?.tabRequestShowToast("保存失败: \(error.localizedDescription)")
        } else {
            delegate?.tabRequestShowToast("已保存图片到相册")
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        if !isLoadingFailureDocument {
            isDisplayingFailurePage = false
        }
        hasInjectedScriptsForCurrentPage = false
        registeredCommands.removeAll()
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if !isDisplayingFailurePage, let currentURL = webView.url, !currentURL.absoluteString.contains("about:blank") {
            if previousURL != currentURL {
                previousURL = url
            }
            url = currentURL
            title = webView.title ?? url?.host ?? "新标签页"
        }
        applyDesktopViewAdaptationIfNeeded()
        injectInlineVideoHelper()
        if !hasInjectedScriptsForCurrentPage {
            hasInjectedScriptsForCurrentPage = true
            injectAndRunUserScripts()
        }
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        if !isDisplayingFailurePage {
            url = webView.url
            title = webView.title ?? url?.host ?? "新标签页"
        }
        applyDesktopViewAdaptationIfNeeded()
        injectInlineVideoHelper()
        if !hasInjectedScriptsForCurrentPage {
            hasInjectedScriptsForCurrentPage = true
            injectAndRunUserScripts()
        }
        extractHighResFaviconIfNeeded()
        updateSnapshot()
        delegate?.tabDidUpdate(self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        delegate?.tabProcessTerminated(self)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
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
