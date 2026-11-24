import UIKit
import WebKit

protocol TabItemDelegate: AnyObject {
    func tabDidUpdate(_ tab: TabItem)
    func tabDidFail(_ tab: TabItem, error: Error)
    func tabDidRedirect(_ tab: TabItem, to url: URL)
    func tabRequestNewTab(url: URL, inBackground: Bool)
    func tabRequestCreatePopupTab(_ tab: TabItem, configuration: WKWebViewConfiguration, navigationAction: WKNavigationAction) -> WKWebView?
    func tabRequestCloseTab(_ tab: TabItem)
    func tabProcessTerminated(_ tab: TabItem)
    func tabRequestGoBack(_ tab: TabItem)
    func tabRequestShowToast(_ message: String)
    func tabRequestCustomContextMenu(title: String, url: URL?, imageURLString: String?)
    func tabRequestAlert(_ tab: TabItem, message: String, completionHandler: @escaping () -> Void)
    func tabRequestConfirm(_ tab: TabItem, message: String, completionHandler: @escaping (Bool) -> Void)
    func tabRequestPrompt(_ tab: TabItem, prompt: String, defaultText: String?, completionHandler: @escaping (String?) -> Void)
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

private final class SafeGMURLSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let scheme = request.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

final class TabItem: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private static let safeGMURLSessionDelegate = SafeGMURLSessionDelegate()
    private static let gmURLSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30.0
        return URLSession(configuration: config, delegate: safeGMURLSessionDelegate, delegateQueue: nil)
    }()

    let id = UUID()
    let webView: WKWebView
    private let reloadCoverView = UIView()
    private let gmBridgeToken = UUID().uuidString
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
    var hasTriggeredAutoFullscreen = false
    private var pendingRestoreURL: URL?
    var needsReloadAfterTermination = false
    private var lastTerminationReloadTime: TimeInterval = 0
    private var rapidTerminationCount: Int = 0

    func shouldAttemptTerminationReload() -> Bool {
        let now = Date().timeIntervalSince1970
        if now - lastTerminationReloadTime < 2.0 {
            rapidTerminationCount += 1
        } else {
            rapidTerminationCount = 0
        }
        lastTerminationReloadTime = now
        return rapidTerminationCount < 3
    }

    private var hasInjectedScriptsForCurrentPage = false
    private var injectedRuntimeScriptIDs = Set<String>()
    private var isSuspendingToBlank = false
    private var isLoadingFailureDocument = false
    private var navigationActionURL: URL?
    private var userScrolledDuringLoading = false
    private var lastNewTabRequestedURL: URL?
    private var lastNewTabRequestedTime: TimeInterval = 0
    private var lastAppliedAdBlockActive: Bool?
    private var homeReturnURL: URL?
    private var homeReturnTitle: String?
    private var wasFailurePageWhenReturnedHome = false
    private var hasCommittedCurrentPage = false
    private var abandonedBackHistoryCount = 0

    enum HomeForwardNavigationResult: Equatable {
        case none
        case restoredImmediately(URL)
        case needsLoad(URL)
    }

    var isOnHome: Bool {
        url == nil && !isDisplayingFailurePage
    }

    var canWebViewGoBack: Bool {
        webView.canGoBack && webView.backForwardList.backList.count > abandonedBackHistoryCount
    }

    var canNavigateForwardFromHome: Bool {
        isOnHome ? (homeReturnURL != nil) : webView.canGoForward
    }

    private var urlObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var canGoBackObservation: NSKeyValueObservation?
    private var canGoForwardObservation: NSKeyValueObservation?

    weak var delegate: TabItemDelegate?
    private static let coreHistoryScriptSource = """
    (function() {
        if (window !== window.top) return;
        if (window.__simple_history_hooked__) return;
        window.__simple_history_hooked__ = true;

        function notifyUrlChange() {
            try {
                if (window !== window.top) return;
                window.webkit.messageHandlers.HistoryBridge.postMessage({
                    url: window.location.href,
                    title: document.title || ''
                });
            } catch(e) {}
        }

        function scheduleNotify() {
            notifyUrlChange();
            setTimeout(notifyUrlChange, 50);
            setTimeout(notifyUrlChange, 200);
        }

        if (window.History && window.History.prototype) {
            var protoPush = window.History.prototype.pushState;
            if (protoPush) {
                window.History.prototype.pushState = function() {
                    var ret = protoPush.apply(this, arguments);
                    scheduleNotify();
                    return ret;
                };
            }
            var protoReplace = window.History.prototype.replaceState;
            if (protoReplace) {
                window.History.prototype.replaceState = function() {
                    var ret = protoReplace.apply(this, arguments);
                    scheduleNotify();
                    return ret;
                };
            }
        }

        if (window.history) {
            var origPush = window.history.pushState;
            if (origPush && (!window.History || window.history.pushState !== window.History.prototype.pushState)) {
                window.history.pushState = function() {
                    var ret = origPush.apply(this, arguments);
                    scheduleNotify();
                    return ret;
                };
            }
            var origReplace = window.history.replaceState;
            if (origReplace && (!window.History || window.history.replaceState !== window.History.prototype.replaceState)) {
                window.history.replaceState = function() {
                    var ret = origReplace.apply(this, arguments);
                    scheduleNotify();
                    return ret;
                };
            }
        }

        window.addEventListener('popstate', scheduleNotify, true);
        window.addEventListener('hashchange', scheduleNotify, true);
        document.addEventListener('turbo:load', scheduleNotify, true);
        document.addEventListener('turbo:render', scheduleNotify, true);
        document.addEventListener('turbolinks:load', scheduleNotify, true);
        document.addEventListener('pjax:end', scheduleNotify, true);
    })();
    """

    private static let coreResourceScriptSource = """
    (function() {
        if (window.__simple_resource_tracker__) return;
        window.__simple_resource_tracker__ = true;

        function reportHosts(hosts) {
            if (!hosts || hosts.length === 0) return;
            try {
                window.webkit.messageHandlers.ResourceBridge.postMessage({
                    main: window.location.hostname,
                    resources: hosts
                });
            } catch(e) {}
        }

        var reported = {};
        function scanResources() {
            try {
                var found = [];
                var entries = performance.getEntriesByType('resource');
                for (var i = 0; i < entries.length; i++) {
                    try {
                        var h = new URL(entries[i].name).hostname;
                        if (h && !reported[h]) {
                            reported[h] = true;
                            found.push(h);
                        }
                    } catch(e) {}
                }
                var nodes = document.querySelectorAll('script[src], link[href], img[src], video[src], audio[src], iframe[src], source[src]');
                for (var j = 0; j < nodes.length; j++) {
                    try {
                        var src = nodes[j].src || nodes[j].href;
                        if (src) {
                            var h2 = new URL(src).hostname;
                            if (h2 && !reported[h2]) {
                                reported[h2] = true;
                                found.push(h2);
                            }
                        }
                    } catch(e) {}
                }
                if (found.length > 0) {
                    reportHosts(found);
                }
            } catch(e) {}
        }

        if (window.PerformanceObserver) {
            try {
                var observer = new PerformanceObserver(function() {
                    scanResources();
                });
                observer.observe({ entryTypes: ['resource'] });
            } catch(e) {}
        }

        document.addEventListener('DOMContentLoaded', scanResources);
        window.addEventListener('load', scanResources);
        setTimeout(scanResources, 600);
        setTimeout(scanResources, 2000);
        setTimeout(scanResources, 4500);
    })();
    """

    private static func makeCoreGMPolyfillScriptSource(bridgeToken: String) -> String {
        let tokenData = (try? JSONSerialization.data(withJSONObject: [bridgeToken], options: [])) ?? Data("[\"\"]".utf8)
        let tokenArrayJSON = String(data: tokenData, encoding: .utf8) ?? "[\"\"]"
        let tokenLiteral = String(tokenArrayJSON.dropFirst().dropLast())

        return """
        (function() {
            if (window.__gm_polyfilled__) return;
            window.__gm_polyfilled__ = true;
            window.unsafeWindow = window;

            var __expectedBridgeToken = \(tokenLiteral);
            var __gmHandler = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.GM) ? window.webkit.messageHandlers.GM : null;
            var __menuCommands = {};
            var __xhrCallbacks = {};
            var __cookieCallbacks = {};

            function postGMMessage(payload) {
                try {
                    if (__gmHandler) {
                        __gmHandler.postMessage(payload);
                        return true;
                    }
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.GM) {
                        window.webkit.messageHandlers.GM.postMessage(payload);
                        return true;
                    }
                } catch(e) {}
                return false;
            }

            window.__gm_invokeMenuCommand = function(id) {
                var fn = __menuCommands[id];
                if (typeof fn === 'function') { fn(); }
            };

            window.__handleCookieListResponse = function(id, cookies, error) {
                var cb = __cookieCallbacks[id];
                if (!cb) return;
                delete __cookieCallbacks[id];
                cb(cookies, error);
            };
            window.__gm_handleCookieListResponse = window.__handleCookieListResponse;

            window.__handleCookieOpResponse = function(id, error) {
                var cb = __cookieCallbacks[id];
                if (!cb) return;
                delete __cookieCallbacks[id];
                cb(error);
            };
            window.__gm_handleCookieOpResponse = window.__handleCookieOpResponse;

            window.__handleXhrResponse = function(id, status, text, headers, finalUrl, base64Data) {
                var opts = __xhrCallbacks[id];
                if (!opts) return;
                delete __xhrCallbacks[id];
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
            window.__gm_handleXhrResponse = window.__handleXhrResponse;

            window.__handleXhrError = function(id, errorText) {
                var opts = __xhrCallbacks[id];
                if (!opts) return;
                delete __xhrCallbacks[id];
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
            window.__gm_handleXhrError = window.__handleXhrError;

            var bridge = {
                postValue: function(token, payload) {
                    if (token !== __expectedBridgeToken || !payload) return;
                    postGMMessage(payload);
                },
                registerMenu: function(token, scriptId, caption, commandFunc) {
                    if (token !== __expectedBridgeToken) return -1;
                    var id = Math.floor(Math.random() * 1000000);
                    __menuCommands[id] = commandFunc;
                    postGMMessage({
                        action: 'registerMenuCommand',
                        id: id,
                        scriptId: scriptId,
                        caption: caption
                    });
                    return id;
                },
                unregisterMenu: function(token, id) {
                    if (token !== __expectedBridgeToken) return;
                    delete __menuCommands[id];
                    postGMMessage({
                        action: 'unregisterMenuCommand',
                        id: id
                    });
                },
                cookieOp: function(token, scriptId, actionName, details, callback) {
                    if (token !== __expectedBridgeToken) {
                        if (typeof callback === 'function') {
                            if (actionName === 'cookie_list') callback(null, 'Unauthorized');
                            else callback('Unauthorized');
                        }
                        return;
                    }
                    var id = 'ck_' + Math.random().toString(36).substr(2, 9);
                    if (typeof callback === 'function') {
                        __cookieCallbacks[id] = callback;
                    }
                    var payloadDetails = Object.assign({}, details || {}, {
                        __simpleScriptId: scriptId,
                        __bridgeToken: token
                    });
                    if (!postGMMessage({
                        action: actionName,
                        id: id,
                        details: payloadDetails
                    })) {
                        delete __cookieCallbacks[id];
                        if (typeof callback === 'function') {
                            if (actionName === 'cookie_list') callback(null, 'Bridge unavailable');
                            else callback('Bridge unavailable');
                        }
                    }
                },
                xhr: function(token, scriptId, opts) {
                    if (token !== __expectedBridgeToken || !opts) {
                        if (opts && opts.onerror) opts.onerror({ status: 0, statusText: 'Unauthorized', responseText: 'Unauthorized', response: null, responseHeaders: '', readyState: 4 });
                        return;
                    }
                    var id = 'xhr_' + Math.random().toString(36).substr(2, 9);
                    __xhrCallbacks[id] = opts;
                    if (!postGMMessage({
                        action: 'xhr',
                        id: id,
                        scriptId: scriptId,
                        bridgeToken: token,
                        method: opts.method || 'GET',
                        url: opts.url,
                        headers: opts.headers || {},
                        data: opts.data || null,
                        responseType: opts.responseType || '',
                        timeout: opts.timeout || 0
                    })) {
                        delete __xhrCallbacks[id];
                        if (opts.onerror) opts.onerror({ status: 0, statusText: 'Bridge unavailable', responseText: 'Bridge unavailable', response: null, responseHeaders: '', readyState: 4 });
                    }
                }
            };

            try {
                Object.defineProperty(window, '__simple_gm_bridge__', {
                    value: bridge,
                    enumerable: false,
                    configurable: false,
                    writable: false
                });
            } catch(e) {
                window.__simple_gm_bridge__ = bridge;
            }
        })();
        """
    }

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

    convenience override init() {
        self.init(configuration: nil)
    }

    init(configuration passedConfig: WKWebViewConfiguration? = nil) {
        let configuration: WKWebViewConfiguration
        if let passed = passedConfig {
            configuration = passed
        } else {
            configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
        }

        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = false

        let selectedItem = UserAgentStore.shared.getSelectedItem()
        let isDesktop = selectedItem.category == .desktop || selectedItem.id == "default_mac"
        configuration.defaultWebpagePreferences.preferredContentMode = isDesktop ? .desktop : .mobile

        let userContentController: WKUserContentController
        if passedConfig != nil {
            userContentController = configuration.userContentController
            for name in ["GM", "DownloadBridge", "ContextMenuBridge", "HistoryBridge", "ResourceBridge"] {
                userContentController.removeScriptMessageHandler(forName: name)
            }
        } else {
            userContentController = WKUserContentController()
            configuration.userContentController = userContentController
        }

        let safeWebView = SafeDropWebView(frame: .zero, configuration: configuration)
        webView = safeWebView
        super.init()

        safeWebView.onDropNotice = { [weak self] message in
            self?.delegate?.tabRequestShowToast(message)
        }

        webView.customUserAgent = UserAgentStore.shared.getSelectedUA()

        userContentController.add(WeakScriptMessageHandler(target: self), name: "GM")
        userContentController.add(WeakScriptMessageHandler(target: self), name: "DownloadBridge")
        userContentController.add(WeakScriptMessageHandler(target: self), name: "ContextMenuBridge")
        userContentController.add(WeakScriptMessageHandler(target: self), name: "HistoryBridge")
        userContentController.add(WeakScriptMessageHandler(target: self), name: "ResourceBridge")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAdBlockRulesAppliedNotification(_:)),
            name: NSNotification.Name("SimpleAdBlockRulesApplied"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUserScriptsUpdatedNotification(_:)),
            name: UserScriptStore.didUpdateScriptsNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarningNotification),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        AdBlockManager.shared.attach(to: webView)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
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

        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.handleURLChange(wv.url)
            }
        }

        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.handleTitleChange(wv.title)
            }
        }

        canGoBackObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.syncBackForwardGestureState()
                self.delegate?.tabDidUpdate(self)
            }
        }

        canGoForwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.delegate?.tabDidUpdate(self)
            }
        }
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

    @objc private func handleMemoryWarningNotification() {
        guard webView.window == nil else { return }
        suspendForMemoryWarning()
    }

    func reloadFromTop() {
        isSuspendingToBlank = false
        needsReloadAfterTermination = false
        userScrolledDuringLoading = false
        lastAutoFullscreenCheckedURL = nil
        hasCommittedCurrentPage = false
        injectedRuntimeScriptIDs.removeAll()
        webView.scrollView.setContentOffset(.zero, animated: false)
        showReloadCover()
        if let currentURL = url ?? webView.url {
            webView.load(URLRequest(url: currentURL))
        } else {
            webView.reload()
        }
    }

    private func syncBackForwardGestureState() {
        webView.allowsBackForwardNavigationGestures = !isOnHome && canWebViewGoBack
    }

    func navigateToHome() {
        if isOnHome {
            hideReloadCover()
            isLoading = false
            snapshot = nil
            syncBackForwardGestureState()
            return
        }

        let currentPageURL = (isDisplayingFailurePage ? (failedURL ?? url) : (url ?? webView.url)).flatMap { candidate -> URL? in
            let str = candidate.absoluteString
            return (str.isEmpty || str == "about:blank") ? nil : candidate
        }
        let currentPageTitle = title
        let wasFailureOrIncomplete = isDisplayingFailurePage || !hasCommittedCurrentPage

        webView.stopLoading()
        webView.evaluateJavaScript("""
        (function(){
            try {
                var media = document.querySelectorAll('audio, video');
                for (var i = 0; i < media.length; i++) {
                    media[i].pause();
                }
            } catch(e) {}
        })();
        """, completionHandler: nil)

        hideReloadCover()
        clearFailureState()
        isLoading = false
        isSuspendingToBlank = false
        url = nil
        title = "主页"
        previousURL = nil
        navigationActionURL = nil
        lastAutoFullscreenCheckedURL = nil
        hasTriggeredAutoFullscreen = false
        snapshot = nil
        injectedRuntimeScriptIDs.removeAll()
        registeredCommands.removeAll()

        if let currentPageURL = currentPageURL {
            homeReturnURL = currentPageURL
            homeReturnTitle = currentPageTitle
            wasFailurePageWhenReturnedHome = wasFailureOrIncomplete
        } else {
            homeReturnURL = nil
            homeReturnTitle = nil
            wasFailurePageWhenReturnedHome = false
        }

        syncBackForwardGestureState()
    }

    func prepareForExplicitLoad(url targetURL: URL) {
        if isOnHome {
            if let existingWebURL = webView.url, existingWebURL.absoluteString != "about:blank" {
                abandonedBackHistoryCount = webView.backForwardList.backList.count + 1
            }
            showReloadCover()
        }

        homeReturnURL = nil
        homeReturnTitle = nil
        wasFailurePageWhenReturnedHome = false
        hasCommittedCurrentPage = false
        needsReloadAfterTermination = false
        isSuspendingToBlank = false
        clearFailureState()
        url = targetURL
        lastAutoFullscreenCheckedURL = targetURL
        title = targetURL.host ?? targetURL.absoluteString
        snapshot = nil
        syncBackForwardGestureState()
    }

    func prepareForwardNavigationFromHome() -> HomeForwardNavigationResult {
        guard isOnHome,
              let savedURL = homeReturnURL,
              savedURL.absoluteString != "about:blank" else {
            return .none
        }

        let savedTitle = homeReturnTitle
        let currentWebURLString = webView.url?.absoluteString ?? ""
        let canRestoreLiveWebView = !wasFailurePageWhenReturnedHome &&
            !isSuspendingToBlank &&
            hasCommittedCurrentPage &&
            !currentWebURLString.isEmpty &&
            currentWebURLString != "about:blank" &&
            webView.url == savedURL

        homeReturnURL = nil
        homeReturnTitle = nil
        wasFailurePageWhenReturnedHome = false
        clearFailureState()
        needsReloadAfterTermination = false
        isSuspendingToBlank = false
        url = savedURL
        lastAutoFullscreenCheckedURL = savedURL
        if let savedTitle = savedTitle, !savedTitle.isEmpty, savedTitle != "主页" {
            title = savedTitle
        } else {
            title = savedURL.host ?? savedURL.absoluteString
        }
        snapshot = nil
        syncBackForwardGestureState()

        if canRestoreLiveWebView {
            hideReloadCover()
            return .restoredImmediately(savedURL)
        } else {
            hasCommittedCurrentPage = false
            showReloadCover()
            return .needsLoad(savedURL)
        }
    }

    @objc private func handleAdBlockRulesAppliedNotification(_ notification: Notification) {
        guard let targetWebView = notification.object as? WKWebView, targetWebView == self.webView else { return }
        let host = (notification.userInfo?["host"] as? String) ?? navigationActionURL?.host ?? url?.host ?? webView.url?.host
        lastAppliedAdBlockActive = AdBlockManager.shared.shouldBlock(for: host)
        rebuildUserContentScripts(forHost: host)
    }

    @objc private func handleUserScriptsUpdatedNotification(_ notification: Notification) {
        if Thread.isMainThread {
            rebuildUserContentScripts()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.rebuildUserContentScripts()
            }
        }
    }

    private func syncAdBlockStateIfNeeded(forHost host: String?) {
        let shouldBlock = AdBlockManager.shared.shouldBlock(for: host)
        if lastAppliedAdBlockActive != shouldBlock {
            lastAppliedAdBlockActive = shouldBlock
            AdBlockManager.shared.applyRules(to: webView, targetHost: host)
        }
    }

    private func ensureCoreScripts() {
        ensureBaseCoreScripts()
        syncDocumentStartUserScripts()
    }

    private func ensureBaseCoreScripts() {
        let controller = webView.configuration.userContentController

        let hasHistory = controller.userScripts.contains { $0.source.contains("__simple_history_hooked__") }
        if !hasHistory {
            let script = WKUserScript(
                source: Self.coreHistoryScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            controller.addUserScript(script)
        }

        let hasResource = controller.userScripts.contains { $0.source.contains("__simple_resource_tracker__") }
        if !hasResource {
            let script = WKUserScript(
                source: Self.coreResourceScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            controller.addUserScript(script)
        }

        let hasGMPolyfill = controller.userScripts.contains { $0.source.contains("__gm_polyfilled__") }
        if !hasGMPolyfill {
            let script = WKUserScript(
                source: Self.makeCoreGMPolyfillScriptSource(bridgeToken: gmBridgeToken),
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

    private func rebuildUserContentScripts(forHost explicitHost: String? = nil) {
        let controller = webView.configuration.userContentController
        let effectiveHost = explicitHost ?? navigationActionURL?.host ?? url?.host ?? webView.url?.host
        controller.removeAllUserScripts()
        ensureBaseCoreScripts()

        let cosmeticScripts = AdBlockManager.shared.activeCosmeticScripts(for: effectiveHost)
        for script in cosmeticScripts {
            controller.addUserScript(script)
        }

        let activeDocStartScripts = UserScriptStore.shared.loadScripts().filter { script in
            guard script.isEnabled else { return false }
            let runAt = script.runAt?.lowercased() ?? ""
            return runAt == "document-start"
        }
        for script in activeDocStartScripts {
            let tag = "__userscript_ds_\(script.id)__"
            let wrapped = wrapUserScriptForInjection(script: script, identifierTag: tag)
            let userScript = WKUserScript(
                source: wrapped,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            controller.addUserScript(userScript)
        }
    }

    private func syncDocumentStartUserScripts() {
        let controller = webView.configuration.userContentController
        let allScripts = UserScriptStore.shared.loadScripts()
        let activeDocStartScripts = allScripts.filter { script in
            guard script.isEnabled else { return false }
            let runAt = script.runAt?.lowercased() ?? ""
            return runAt == "document-start"
        }

        let expectedTags = Set(activeDocStartScripts.map { "__userscript_ds_\($0.id)__" })
        var currentTags = Set<String>()
        for us in controller.userScripts {
            for script in allScripts {
                let tag = "__userscript_ds_\(script.id)__"
                if us.source.contains(tag) {
                    currentTags.insert(tag)
                }
            }
        }

        if currentTags != expectedTags {
            rebuildUserContentScripts()
        }
    }

    private func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2 else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    private func wrapUserScriptForInjection(script: UserScript, identifierTag: String) -> String {
        let valuesJSON = ScriptDataStore.shared.getAllValuesJSON(scriptId: script.id)
        let scriptIdLiteral = javascriptStringLiteral(script.id)
        let bridgeTokenLiteral = javascriptStringLiteral(gmBridgeToken)
        let scriptNameLiteral = javascriptStringLiteral(script.name)
        let scriptVersionLiteral = javascriptStringLiteral(script.version ?? "1.0")
        let runAtMode = (script.runAt ?? "document-idle").lowercased()
        let runAtLiteral = javascriptStringLiteral(runAtMode)
        let escapedCode = script.code
        let isAllUrls = script.matchPattern == "*" || script.matchPattern == "<all_urls>"
        let matchCheckJS: String
        if isAllUrls {
            matchCheckJS = "true"
        } else {
            let rawParts = script.matchPattern.components(separatedBy: CharacterSet(charactersIn: ",\n;"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let partsData = (try? JSONSerialization.data(withJSONObject: rawParts, options: [])) ?? Data()
            let partsJSON = String(data: partsData, encoding: .utf8) ?? "[]"
            matchCheckJS = """
            (function() {
                var currentUrl = window.location.href;
                var currentHost = window.location.hostname.toLowerCase();
                var currentPath = window.location.pathname.toLowerCase();
                var patterns = \(partsJSON);
                function matchHost(h, pat) {
                    if (pat === '*' || pat === '<all_urls>' || !pat) return true;
                    if (pat.indexOf('://') !== -1) pat = pat.split('://')[1];
                    if (pat.indexOf('/') !== -1) pat = pat.split('/')[0];
                    pat = pat.trim().toLowerCase();
                    if (pat.indexOf('*.') === 0) {
                        var s = pat.substring(2);
                        return h === s || h.endsWith('.' + s);
                    }
                    if (pat.indexOf('*') === 0) {
                        var s = pat.substring(1);
                        return h.endsWith(s);
                    }
                    return h === pat || h.endsWith('.' + pat);
                }
                function matchUrl(u, rawPat) {
                    var pat = rawPat.trim().toLowerCase();
                    if (pat === '*' || pat === '<all_urls>') return true;
                    if (pat.indexOf('://') !== -1) pat = pat.split('://')[1];
                    var patHost = pat;
                    var patPath = null;
                    var slashIdx = pat.indexOf('/');
                    if (slashIdx !== -1) {
                        patHost = pat.substring(0, slashIdx);
                        patPath = pat.substring(slashIdx);
                    }
                    if (!matchHost(currentHost, patHost)) return false;
                    if (!patPath || patPath === '/*' || patPath === '/') return true;
                    var regStr = '^' + patPath.replace(/[.+?^${}()|[\\]\\\\]/g, '\\\\$&').replace(/\\*/g, '.*') + '$';
                    try {
                        return new RegExp(regStr).test(currentPath);
                    } catch(e) {
                        return true;
                    }
                }
                var excludes = patterns.filter(function(p){ return p.indexOf('!') === 0; }).map(function(p){ return p.substring(1); });
                for (var i = 0; i < excludes.length; i++) {
                    if (matchUrl(currentUrl, excludes[i])) return false;
                }
                var includes = patterns.filter(function(p){ return p.indexOf('!') !== 0; });
                if (includes.length === 0) return true;
                for (var j = 0; j < includes.length; j++) {
                    if (matchUrl(currentUrl, includes[j])) return true;
                }
                return false;
            })()
            """
        }

        return """
        // \(identifierTag)
        (function() {
            var __simpleMatched = false;
            try {
                __simpleMatched = (\(matchCheckJS));
            } catch(e) {
                return;
            }
            if (!__simpleMatched) return;
            var __execScript = function(scriptId, bridgeToken, scriptName, scriptVersion, initialValues) {
                var values = initialValues || {};
                var bridge = window.__simple_gm_bridge__;
                var GM_info = {
                    scriptHandler: 'Tampermonkey',
                    version: '5.0.0',
                    script: { name: scriptName, version: scriptVersion }
                };
                var GM_addStyle = function(css) {
                    var style = document.createElement('style');
                    style.type = 'text/css';
                    style.appendChild(document.createTextNode(css));
                    (document.head || document.documentElement).appendChild(style);
                    return style;
                };
                var GM_log = function() {};
                var GM_openInTab = function(url) {
                    window.open(url, '_blank');
                };
                var GM_setClipboard = function(text) {
                    if (navigator.clipboard && navigator.clipboard.writeText) {
                        navigator.clipboard.writeText(String(text || ''));
                    }
                };
                var GM_notification = function() {};
                var GM_setValue = function(name, val) {
                    values[name] = val;
                    if (bridge) {
                        bridge.postValue(bridgeToken, {
                            action: 'setValue',
                            scriptId: scriptId,
                            name: name,
                            value: val
                        });
                    }
                };
                var GM_getValue = function(name, defaultValue) {
                    return (name in values) ? values[name] : defaultValue;
                };
                var GM_deleteValue = function(name) {
                    delete values[name];
                    if (bridge) {
                        bridge.postValue(bridgeToken, {
                            action: 'deleteValue',
                            scriptId: scriptId,
                            name: name
                        });
                    }
                };
                var GM_listValues = function() {
                    return Object.keys(values);
                };
                var GM_registerMenuCommand = function(caption, commandFunc) {
                    if (bridge) {
                        return bridge.registerMenu(bridgeToken, scriptId, caption, commandFunc);
                    }
                    return -1;
                };
                var GM_unregisterMenuCommand = function(id) {
                    if (bridge) {
                        bridge.unregisterMenu(bridgeToken, id);
                    }
                };
                var GM_cookie = bridge ? {
                    list: function(details, callback) {
                        return bridge.cookieOp(bridgeToken, scriptId, 'cookie_list', details, callback);
                    },
                    delete: function(details, callback) {
                        return bridge.cookieOp(bridgeToken, scriptId, 'cookie_delete', details, callback);
                    },
                    set: function(details, callback) {
                        return bridge.cookieOp(bridgeToken, scriptId, 'cookie_set', details, callback);
                    }
                } : undefined;
                var GM_xmlhttpRequest = function(opts) {
                    if (bridge) {
                        bridge.xhr(bridgeToken, scriptId, opts);
                    } else if (opts && opts.onerror) {
                        opts.onerror({ status: 0, statusText: 'Bridge unavailable', responseText: 'Bridge unavailable', response: null, responseHeaders: '', readyState: 4 });
                    }
                };
                var GM = {
                    info: GM_info,
                    cookie: GM_cookie,
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
                            opts.onerror = function(error) {
                                if (origOnerror) origOnerror(error);
                                reject(error);
                            };
                            GM_xmlhttpRequest(opts);
                        });
                    },
                    addStyle: GM_addStyle,
                    openInTab: GM_openInTab,
                    setClipboard: GM_setClipboard,
                    notification: GM_notification,
                    registerMenuCommand: function(c, f) { return Promise.resolve(GM_registerMenuCommand(c, f)); }
                };

                try {
                    \(escapedCode)
                } catch(e) {}
            };

            var __runAt = \(runAtLiteral);
            var __ran = false;
            function __invokeOnce() {
                if (__ran) return;
                __ran = true;
                __execScript(\(scriptIdLiteral), \(bridgeTokenLiteral), \(scriptNameLiteral), \(scriptVersionLiteral), \(valuesJSON));
            }
            if (__runAt === 'document-start') {
                __invokeOnce();
            } else if (__runAt === 'document-body') {
                if (document.body) {
                    __invokeOnce();
                } else {
                    var __bodyObs = new MutationObserver(function() {
                        if (document.body) {
                            __bodyObs.disconnect();
                            __invokeOnce();
                        }
                    });
                    __bodyObs.observe(document.documentElement || document, { childList: true, subtree: true });
                    document.addEventListener('DOMContentLoaded', function() {
                        __bodyObs.disconnect();
                        __invokeOnce();
                    }, { once: true });
                }
            } else if (__runAt === 'document-end') {
                if (document.readyState !== 'loading') {
                    __invokeOnce();
                } else {
                    document.addEventListener('DOMContentLoaded', __invokeOnce, { once: true });
                }
            } else {
                if (document.readyState === 'complete') {
                    __invokeOnce();
                } else if (document.readyState === 'interactive') {
                    setTimeout(__invokeOnce, 0);
                } else {
                    document.addEventListener('DOMContentLoaded', function() {
                        setTimeout(__invokeOnce, 0);
                    }, { once: true });
                }
            }
        })();
        """
    }

    func destroy() {
        hideReloadCover()
        reloadCoverView.removeFromSuperview()
        NotificationCenter.default.removeObserver(self)
        AdBlockManager.shared.detach(from: webView)
        delegate = nil
        urlObservation?.invalidate()
        urlObservation = nil
        titleObservation?.invalidate()
        titleObservation = nil
        canGoBackObservation?.invalidate()
        canGoBackObservation = nil
        canGoForwardObservation?.invalidate()
        canGoForwardObservation = nil
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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "HistoryBridge")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "ResourceBridge")
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        webView.removeFromSuperview()
        snapshot = nil
    }

    func clearFailureState() {
        hideReloadCover()
        isDisplayingFailurePage = false
        needsReloadAfterTermination = false
        failedURL = nil
        failureError = nil
        failureOriginURL = nil
    }

    func restoreSession(url: URL?, title: String) {
        self.url = url
        self.title = title.isEmpty ? (url?.host ?? "新标签页") : title
        self.pendingRestoreURL = url
        self.needsReloadAfterTermination = false
        self.isDisplayingFailurePage = false
        self.failedURL = nil
        self.failureError = nil
        self.failureOriginURL = nil
        self.homeReturnURL = nil
        self.homeReturnTitle = nil
        self.wasFailurePageWhenReturnedHome = false
        self.hasCommittedCurrentPage = false
        self.abandonedBackHistoryCount = 0
        self.syncBackForwardGestureState()
    }

    func consumePendingRestoreURL() -> URL? {
        isSuspendingToBlank = false
        let url = pendingRestoreURL
        pendingRestoreURL = nil
        return url
    }

    func suspendForMemoryWarning() {
        guard !isDisplayingFailurePage else { return }
        guard let target = sessionURL() else { return }
        snapshot = nil
        url = target
        pendingRestoreURL = target
        isLoading = false
        needsReloadAfterTermination = false
        isSuspendingToBlank = true
        injectedRuntimeScriptIDs.removeAll()
        hideReloadCover()
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }
    func sessionURL() -> URL? {
        if isDisplayingFailurePage {
            return failedURL ?? url
        }
        let candidate = pendingRestoreURL ?? url
        guard let target = candidate else { return nil }
        let str = target.absoluteString
        if str.isEmpty || str == "about:blank" || str.contains("settings/hatsv2") {
            return nil
        }
        return target
    }

    func handleURLChange(_ newURL: URL?, explicitTitle: String? = nil) {
        guard !isOnHome, !isSuspendingToBlank else { return }
        guard let newURL = newURL, !newURL.absoluteString.contains("about:blank") else { return }

        let scheme = newURL.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return }

        if let currentHost = webView.url?.host?.lowercased(),
           let newHost = newURL.host?.lowercased(),
           currentHost != newHost {
            return
        }

        if !isDisplayingFailurePage {
            var hasChanged = false
            if url != newURL {
                previousURL = url
                url = newURL
                hasChanged = true
                if let host = newURL.host {
                    DomainRelationStore.shared.recordPrimaryDomain(host)
                }
            }
            if let t = explicitTitle, !t.isEmpty, title != t {
                title = t
                hasChanged = true
            } else if let t = webView.title, !t.isEmpty, title != t {
                title = t
                hasChanged = true
            } else if title.isEmpty {
                title = newURL.host ?? "新标签页"
                hasChanged = true
            }
            if hasChanged {
                delegate?.tabDidUpdate(self)
            }
        }
    }

    func handleTitleChange(_ newTitle: String?) {
        guard !isOnHome, !isSuspendingToBlank else { return }
        guard let newTitle = newTitle, !newTitle.isEmpty else { return }
        if !isDisplayingFailurePage {
            if title != newTitle {
                title = newTitle
                delegate?.tabDidUpdate(self)
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "ResourceBridge" {
            guard let body = message.body as? [String: Any],
                  let mainHost = body["main"] as? String,
                  let resources = body["resources"] as? [String] else { return }
            SiteResourceHistoryStore.shared.recordResources(subDomains: resources, forMainDomain: mainHost)
            return
        }

        if message.name == "HistoryBridge" {
            guard message.frameInfo.isMainFrame else { return }
            guard let body = message.body as? [String: Any],
                  let urlStr = body["url"] as? String,
                  let newURL = URL(string: urlStr) else { return }

            if let currentHost = webView.url?.host?.lowercased(),
               let newHost = newURL.host?.lowercased(),
               currentHost != newHost {
                return
            }

            let newTitle = body["title"] as? String
            handleURLChange(newURL, explicitTitle: newTitle)
            return
        }

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
        } else if action == "cookie_list", let reqId = body["id"] as? String, let details = body["details"] as? [String: Any] {
            handleCookieList(requestID: reqId, details: details, message: message)
        } else if action == "cookie_delete", let reqId = body["id"] as? String, let details = body["details"] as? [String: Any] {
            handleCookieDelete(requestID: reqId, details: details, message: message)
        } else if action == "cookie_set", let reqId = body["id"] as? String, let details = body["details"] as? [String: Any] {
            handleCookieSet(requestID: reqId, details: details, message: message)
        } else if action == "xhr", let reqId = body["id"] as? String {
            if let permErr = xhrPermissionError(body: body, message: message) {
                respondToXhrError(requestID: reqId, errorText: permErr)
                return
            }
            guard let urlString = body["url"] as? String,
                  let targetURL = URL(string: urlString),
                  let targetScheme = targetURL.scheme?.lowercased(),
                  targetScheme == "http" || targetScheme == "https" else {
                respondToXhrError(requestID: reqId, errorText: "Invalid or unsupported URL scheme")
                return
            }

            let method = (body["method"] as? String) ?? "GET"
            let responseType = ((body["responseType"] as? String) ?? "").lowercased()
            var request = URLRequest(url: targetURL)
            request.httpMethod = method

            let rawTimeout = (body["timeout"] as? NSNumber)?.doubleValue ?? 0
            if rawTimeout > 0 {
                request.timeoutInterval = min(max(rawTimeout / 1000.0, 1.0), 120.0)
            } else {
                request.timeoutInterval = 30.0
            }

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

            let task = Self.gmURLSession.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    if let error = error {
                        self?.respondToXhrError(requestID: reqId, errorText: error.localizedDescription)
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

    private func respondToXhrError(requestID: String, errorText: String) {
        let errArgs: [Any] = [requestID, errorText]
        let errData = (try? JSONSerialization.data(withJSONObject: errArgs, options: [])) ?? Data()
        let errJSON = String(data: errData, encoding: .utf8) ?? "[]"
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript("if (typeof window.__gm_handleXhrError === 'function') { window.__gm_handleXhrError.apply(null, \(errJSON)); }", completionHandler: nil)
        }
    }

    private func xhrPermissionError(body: [String: Any], message: WKScriptMessage) -> String? {
        guard (body["bridgeToken"] as? String) == gmBridgeToken else {
            return "Unauthorized GM_xmlhttpRequest token"
        }
        guard let scriptId = body["scriptId"] as? String,
              let script = UserScriptStore.shared.loadScripts().first(where: { $0.id == scriptId && $0.isEnabled }) else {
            return "GM_xmlhttpRequest requires an enabled userscript"
        }
        let frameURLString: String
        if let frameURL = message.frameInfo.request.url?.absoluteString, !frameURL.isEmpty, frameURL != "about:blank" {
            frameURLString = frameURL
        } else if message.frameInfo.isMainFrame, let pageURLString = webView.url?.absoluteString {
            frameURLString = pageURLString
        } else {
            return "GM_xmlhttpRequest origin could not be verified"
        }

        guard UserScriptStore.shared.isScriptMatching(script: script, urlString: frameURLString) else {
            return "GM_xmlhttpRequest is not authorized for this page"
        }
        return nil
    }

    private func cookiePermissionError(details: [String: Any], message: WKScriptMessage) -> String? {
        guard (details["__bridgeToken"] as? String) == gmBridgeToken else {
            return "Unauthorized GM_cookie token"
        }
        guard message.frameInfo.isMainFrame else {
            return "GM_cookie is only available to the main frame"
        }
        let permission = UserScriptStore.shared.cookiePermission
        guard permission != .disabled else {
            return "GM_cookie permission is disabled in UserScript settings"
        }
        guard let scriptId = details["__simpleScriptId"] as? String,
              let script = UserScriptStore.shared.loadScripts().first(where: { $0.id == scriptId && $0.isEnabled }),
              let pageURL = webView.url,
              UserScriptStore.shared.isScriptMatching(script: script, urlString: pageURL.absoluteString) else {
            return "GM_cookie request is not associated with an enabled userscript on this page"
        }

        let pageHost = pageURL.host?.lowercased() ?? ""
        if let rawURL = details["url"] as? String {
            guard let targetURL = URL(string: rawURL),
                  let targetScheme = targetURL.scheme?.lowercased(),
                  ["http", "https"].contains(targetScheme),
                  let targetHost = targetURL.host?.lowercased() else {
                return "Invalid cookie URL"
            }
            if permission == .sameDomain && targetHost != pageHost {
                return "GM_cookie is restricted to the current domain"
            }
        } else if permission == .sameDomain,
                  let requestedDomain = details["domain"] as? String,
                  !cookieDomain(requestedDomain, matches: pageHost) {
            return "GM_cookie is restricted to the current domain"
        }
        return nil
    }

    private func cookieDomain(_ cookieDomain: String, matches host: String) -> Bool {
        let domain = cookieDomain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
    }

    private func cookieMatchesURL(_ cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host?.lowercased(), cookieDomain(cookie.domain, matches: host) else { return false }
        if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
        if let expires = cookie.expiresDate, expires <= Date() { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if !cookiePath.hasSuffix("/") && requestPath.count > cookiePath.count {
            let boundary = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
            if requestPath[boundary] != "/" { return false }
        }
        return true
    }

    private func cookieDictionary(_ cookie: HTTPCookie) -> [String: Any] {
        return [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "expirationDate": cookie.expiresDate?.timeIntervalSince1970 ?? -1,
            "httpOnly": cookie.isHTTPOnly,
            "secure": cookie.isSecure,
            "sameSite": "unspecified"
        ]
    }

    private func respondToCookieList(requestID: String, cookies: [[String: Any]]?, error: String?) {
        let args: [Any] = [requestID, (cookies as Any?) ?? NSNull(), (error as Any?) ?? NSNull()]
        let data = (try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed])) ?? Data("[]".utf8)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript("if (typeof window.__handleCookieListResponse === 'function') { window.__handleCookieListResponse.apply(null, \(json)); }", completionHandler: nil)
        }
    }

    private func respondToCookieOperation(requestID: String, error: String?) {
        let args: [Any] = [requestID, (error as Any?) ?? NSNull()]
        let data = (try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed])) ?? Data("[]".utf8)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript("if (typeof window.__handleCookieOpResponse === 'function') { window.__handleCookieOpResponse.apply(null, \(json)); }", completionHandler: nil)
        }
    }

    private func matchesCookieDetails(_ cookie: HTTPCookie, details: [String: Any], pageHost: String, permission: GMCookiePermission) -> Bool {
        if let name = details["name"] as? String, cookie.name != name { return false }
        if let domain = details["domain"] as? String {
            let requested = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            if cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() != requested { return false }
        }
        if let path = details["path"] as? String, cookie.path != path { return false }
        if let rawURL = details["url"] as? String {
            guard let targetURL = URL(string: rawURL),
                  ["http", "https"].contains(targetURL.scheme?.lowercased() ?? ""),
                  permission == .allDomains || targetURL.host?.lowercased() == pageHost else { return false }
            return cookieMatchesURL(cookie, url: targetURL)
        }
        if permission == .sameDomain {
            return cookieDomain(cookie.domain, matches: pageHost)
        }
        return true
    }

    private func handleCookieList(requestID: String, details: [String: Any], message: WKScriptMessage) {
        if let error = cookiePermissionError(details: details, message: message) {
            respondToCookieList(requestID: requestID, cookies: nil, error: error)
            return
        }
        let permission = UserScriptStore.shared.cookiePermission
        let pageHost = webView.url?.host?.lowercased() ?? ""
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            let result = cookies.filter {
                self.matchesCookieDetails($0, details: details, pageHost: pageHost, permission: permission)
            }.map(self.cookieDictionary)
            self.respondToCookieList(requestID: requestID, cookies: result, error: nil)
        }
    }

    private func handleCookieDelete(requestID: String, details: [String: Any], message: WKScriptMessage) {
        if let error = cookiePermissionError(details: details, message: message) {
            respondToCookieOperation(requestID: requestID, error: error)
            return
        }
        guard details["name"] is String else {
            respondToCookieOperation(requestID: requestID, error: "A cookie name is required for deletion")
            return
        }
        let permission = UserScriptStore.shared.cookiePermission
        let pageHost = webView.url?.host?.lowercased() ?? ""
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            let matches = cookies.filter {
                self.matchesCookieDetails($0, details: details, pageHost: pageHost, permission: permission)
            }
            let group = DispatchGroup()
            for cookie in matches {
                group.enter()
                store.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) {
                self.respondToCookieOperation(requestID: requestID, error: nil)
            }
        }
    }

    private func handleCookieSet(requestID: String, details: [String: Any], message: WKScriptMessage) {
        if let error = cookiePermissionError(details: details, message: message) {
            respondToCookieOperation(requestID: requestID, error: error)
            return
        }
        guard let name = details["name"] as? String, !name.isEmpty,
              let value = details["value"] as? String,
              let pageURL = webView.url,
              let pageHost = pageURL.host?.lowercased() else {
            respondToCookieOperation(requestID: requestID, error: "Cookie name, value and current page are required")
            return
        }
        let targetURL = (details["url"] as? String).flatMap(URL.init(string:)) ?? pageURL
        guard let targetHost = targetURL.host?.lowercased(),
              ["http", "https"].contains(targetURL.scheme?.lowercased() ?? "") else {
            respondToCookieOperation(requestID: requestID, error: "A valid HTTP(S) cookie URL is required")
            return
        }
        let permission = UserScriptStore.shared.cookiePermission
        if permission == .sameDomain && targetHost != pageHost {
            respondToCookieOperation(requestID: requestID, error: "GM_cookie is restricted to the current domain")
            return
        }
        let domain = (details["domain"] as? String ?? targetHost).lowercased()
        guard cookieDomain(domain, matches: targetHost) else {
            respondToCookieOperation(requestID: requestID, error: "Cookie domain does not match the target URL")
            return
        }
        let path = (details["path"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/"
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .path: path,
            .name: name,
            .value: value
        ]
        if details["secure"] as? Bool == true { properties[.secure] = "TRUE" }
        if let expiry = details["expirationDate"] as? NSNumber, expiry.doubleValue > 0 {
            properties[.expires] = Date(timeIntervalSince1970: expiry.doubleValue)
        }
        guard let cookie = HTTPCookie(properties: properties) else {
            respondToCookieOperation(requestID: requestID, error: "Invalid cookie properties")
            return
        }
        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak self] in
            self?.respondToCookieOperation(requestID: requestID, error: nil)
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
                    object: filename,
                    userInfo: ["error": error.localizedDescription]
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

        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            let httpsScheme = "https:" + String(repeating: "/", count: 2)
            let iconURLString = (result as? String) ?? "\(httpsScheme)\(currentHost)/favicon.ico"
            guard let iconURL = URL(string: iconURLString) else { return }

            var req = URLRequest(url: iconURL, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 4.0)
            req.setValue(self.webView.customUserAgent ?? UserAgentStore.shared.getSelectedUA(), forHTTPHeaderField: "User-Agent")

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

        let currentUrlStr = url?.absoluteString ?? webView.url?.absoluteString ?? ""
        guard !currentUrlStr.isEmpty, currentUrlStr != "about:blank" else { return }

        let candidates = UserScriptStore.shared.loadScripts().filter {
            ($0.runAt?.lowercased() ?? "document-idle") != "document-start"
        }
        var matchingScripts: [UserScript] = []
        for script in candidates {
            guard script.isEnabled, !injectedRuntimeScriptIDs.contains(script.id) else {
                continue
            }
            if UserScriptStore.shared.isScriptMatching(script: script, urlString: currentUrlStr) {
                matchingScripts.append(script)
            }
        }

        guard !matchingScripts.isEmpty else { return }

        let polyfillJS = Self.makeCoreGMPolyfillScriptSource(bridgeToken: gmBridgeToken)
        webView.evaluateJavaScript(polyfillJS, completionHandler: nil)

        for script in matchingScripts {
            injectedRuntimeScriptIDs.insert(script.id)
            let wrappedJS = wrapUserScriptForInjection(script: script, identifierTag: "__userscript_rt_\(script.id)__")
            webView.evaluateJavaScript(wrappedJS, completionHandler: nil)
        }
    }

    func reloadUserScripts() {
        hasInjectedScriptsForCurrentPage = false
        injectedRuntimeScriptIDs.removeAll()
        registeredCommands.removeAll()
        rebuildUserContentScripts()
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

    private func requestNewTabIfNeeded(url: URL) {
        let now = Date().timeIntervalSince1970
        if lastNewTabRequestedURL == url && (now - lastNewTabRequestedTime) < 1.0 {
            return
        }
        lastNewTabRequestedURL = url
        lastNewTabRequestedTime = now
        delegate?.tabRequestNewTab(url: url, inBackground: false)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let popupWebView = delegate?.tabRequestCreatePopupTab(self, configuration: configuration, navigationAction: navigationAction) {
            return popupWebView
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        delegate?.tabRequestCloseTab(self)
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
        var handled = false
        let callOnce: (WKPermissionDecision) -> Void = { decision in
            guard !handled else { return }
            handled = true
            decisionHandler(decision)
        }

        let mediaDescription: String
        switch type {
        case .camera:
            mediaDescription = "相机"
        case .microphone:
            mediaDescription = "麦克风"
        case .cameraAndMicrophone:
            mediaDescription = "相机和麦克风"
        @unknown default:
            mediaDescription = "媒体设备"
        }

        let host = origin.host.isEmpty ? (webView.url?.host ?? "当前网页") : origin.host
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let rootVC = self.webView.window?.rootViewController else {
                callOnce(.deny)
                return
            }
            var topController: UIViewController = rootVC
            while let presented = topController.presentedViewController, !presented.isBeingDismissed {
                topController = presented
            }
            if topController.isBeingPresented || topController is UIAlertController {
                callOnce(.deny)
                return
            }
            let alert = UIAlertController(
                title: "媒体设备访问权限",
                message: "“\(host)”请求使用您的\(mediaDescription)",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "拒绝", style: .cancel) { _ in
                callOnce(.deny)
            })
            alert.addAction(UIAlertAction(title: "允许", style: .default) { _ in
                callOnce(.grant)
            })
            topController.present(alert, animated: true)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        if let delegate = delegate {
            delegate.tabRequestAlert(self, message: message, completionHandler: completionHandler)
        } else {
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        if let delegate = delegate {
            delegate.tabRequestConfirm(self, message: message, completionHandler: completionHandler)
        } else {
            completionHandler(false)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        if let delegate = delegate {
            delegate.tabRequestPrompt(self, prompt: prompt, defaultText: defaultText, completionHandler: completionHandler)
        } else {
            completionHandler(nil)
        }
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
        if isOnHome || isSuspendingToBlank {
            isLoading = false
            return
        }
        isLoading = true
        needsReloadAfterTermination = false
        if !isLoadingFailureDocument {
            isDisplayingFailurePage = false
        }
        hasInjectedScriptsForCurrentPage = false
        injectedRuntimeScriptIDs.removeAll()
        registeredCommands.removeAll()
        if let target = navigationActionURL ?? webView.url,
           ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
            syncAdBlockStateIfNeeded(forHost: target.host)
        }
        ensureCoreScripts()
        userScrolledDuringLoading = false
        syncBackForwardGestureState()
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard !isOnHome, !isSuspendingToBlank else { return }
        if let redirectURL = webView.url, !redirectURL.absoluteString.contains("about:blank") {
            if previousURL != redirectURL {
                previousURL = url
            }
            url = redirectURL
            title = redirectURL.host ?? "正在跳转…"
            if let host = redirectURL.host {
                DomainRelationStore.shared.recordPrimaryDomain(host)
            }
            delegate?.tabDidRedirect(self, to: redirectURL)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if isOnHome || isSuspendingToBlank {
            return
        }
        hideReloadCover()
        hasCommittedCurrentPage = true
        if !isDisplayingFailurePage, let currentURL = webView.url, !currentURL.absoluteString.contains("about:blank") {
            if previousURL != currentURL {
                previousURL = url
            }
            url = currentURL
            title = webView.title ?? url?.host ?? "新标签页"
            if let host = currentURL.host {
                DomainRelationStore.shared.recordPrimaryDomain(host)
            }
        }
        ensureCoreScripts()
        applyDesktopViewAdaptationIfNeeded()
        injectInlineVideoHelper()
        if !hasInjectedScriptsForCurrentPage {
            hasInjectedScriptsForCurrentPage = true
            injectAndRunUserScripts()
        }
        syncBackForwardGestureState()
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isSuspendingToBlank {
            if webView.url?.absoluteString == "about:blank" {
                isSuspendingToBlank = false
                isLoading = false
                return
            }
            isSuspendingToBlank = false
        }
        if isOnHome {
            isLoading = false
            return
        }
        hideReloadCover()
        isLoading = false
        hasCommittedCurrentPage = true
        if !isDisplayingFailurePage, let currentURL = webView.url, !currentURL.absoluteString.contains("about:blank") {
            url = currentURL
            title = webView.title ?? url?.host ?? "新标签页"
            if let host = currentURL.host {
                DomainRelationStore.shared.recordPrimaryDomain(host)
            }
        }
        injectAndRunUserScripts()
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

        syncBackForwardGestureState()
        delegate?.tabDidUpdate(self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hideReloadCover()
        isLoading = false
        hasCommittedCurrentPage = false
        needsReloadAfterTermination = true
        delegate?.tabProcessTerminated(self)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        hideReloadCover()
        isLoading = false
        if isOnHome || isSuspendingToBlank {
            return
        }
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
        if isOnHome || isSuspendingToBlank {
            return
        }
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

        if navigationAction.targetFrame?.isMainFrame == true,
           isOnHome,
           !isSuspendingToBlank,
           targetURL.absoluteString != "about:blank" {
            decisionHandler(.cancel, preferences)
            return
        }

        if navigationAction.targetFrame?.isMainFrame == true {
            navigationActionURL = targetURL
            let targetScheme = targetURL.scheme?.lowercased() ?? ""
            if ["http", "https"].contains(targetScheme) {
                syncAdBlockStateIfNeeded(forHost: targetURL.host)
            }
            if let host = targetURL.host {
                DomainRelationStore.shared.recordPrimaryDomain(host)
            }
        } else if let subHost = targetURL.host, let parentHost = url?.host {
            SiteResourceHistoryStore.shared.recordResources(subDomains: [subHost], forMainDomain: parentHost)
        }

        let selectedItem = UserAgentStore.shared.getSelectedItem()
        let isDesktopMode = selectedItem.category == .desktop || selectedItem.id == "default_mac"
        preferences.preferredContentMode = isDesktopMode ? .desktop : .mobile

        let scheme = targetURL.scheme?.lowercased() ?? ""

        if ["http", "https"].contains(scheme),
           navigationAction.targetFrame?.isMainFrame == true,
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
            "ipa", "apk", "xapk", "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz",
            "dmg", "pkg", "deb", "torrent", "iso", "bin", "exe", "msi"
        ]
        if navigationAction.shouldPerformDownload || knownDownloadExtensions.contains(ext) {
            decisionHandler(.download, preferences)
            return
        }

        if ["http", "https", "about", "data", "blob", "javascript"].contains(scheme) {
            if navigationAction.targetFrame == nil {
                decisionHandler(.cancel, preferences)
                if ["http", "https"].contains(scheme) {
                    requestNewTabIfNeeded(url: targetURL)
                }
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
                needsReloadAfterTermination = true
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
