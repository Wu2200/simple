import UIKit
import WebKit

// MARK: - TabItemDelegate 协议
protocol TabItemDelegate: AnyObject {
    func tabDidUpdate(_ tab: TabItem)
    func tabDidFail(_ tab: TabItem, error: Error)
    func tabProcessTerminated(_ tab: TabItem)
    func tabRequestGoBack(_ tab: TabItem)
    func tabRequestNewTab(_ tab: TabItem, url: URL?)
}

// MARK: - 下载协调器
final class DownloadCoordinator: NSObject, WKDownloadDelegate {
    static let shared = DownloadCoordinator()
    private var downloadDestinations: [WKDownload: URL] = [:]

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dlFolder = docs.appendingPathComponent("Downloads", isDirectory: true)
        if !fm.fileExists(atPath: dlFolder.path) {
            try? fm.createDirectory(at: dlFolder, withIntermediateDirectories: true)
        }

        var destination = dlFolder.appendingPathComponent(suggestedFilename)
        var counter = 1
        let baseName = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension

        while fm.fileExists(atPath: destination.path) {
            let newName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            destination = dlFolder.appendingPathComponent(newName)
            counter += 1
        }

        downloadDestinations[download] = destination
        completionHandler(destination)
        NotificationCenter.default.post(name: NSNotification.Name("DownloadStartedNotification"), object: nil)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let dest = downloadDestinations[download] {
            downloadDestinations.removeValue(forKey: download)
            NotificationCenter.default.post(name: NSNotification.Name("DownloadFinishedNotification"), object: nil, userInfo: ["url": dest])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: download)
        NotificationCenter.default.post(name: NSNotification.Name("DownloadFailedNotification"), object: nil)
    }
}

// MARK: - 前端文件导出桥接
final class DownloadBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "downloadBlobBridge",
              let body = message.body as? [String: Any],
              let base64 = body["base64"] as? String,
              let filename = body["filename"] as? String else { return }

        guard let data = Data(base64Encoded: base64) else { return }

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dlFolder = docs.appendingPathComponent("Downloads", isDirectory: true)
        if !fm.fileExists(atPath: dlFolder.path) {
            try? fm.createDirectory(at: dlFolder, withIntermediateDirectories: true)
        }

        let fileURL = dlFolder.appendingPathComponent(filename)
        try? data.write(to: fileURL)

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("BlobDownloadFinishedNotification"), object: nil, userInfo: ["fileURL": fileURL, "filename": filename])
        }
    }
}

// MARK: - 网页标签项核心实现
final class TabItem: NSObject, WKNavigationDelegate, WKUIDelegate {

    weak var delegate: TabItemDelegate?
    var webView: WKWebView!

    var title: String {
        return webView?.title?.isEmpty == false ? webView.title! : "新标签页"
    }

    var currentURL: URL? {
        return webView?.url
    }

    var isLoading: Bool {
        return webView?.isLoading ?? false
    }

    var estimatedProgress: Double {
        return webView?.estimatedProgress ?? 0.0
    }

    var canGoBack: Bool {
        return webView?.canGoBack ?? false
    }

    var canGoForward: Bool {
        return webView?.canGoForward ?? false
    }

    private var progressObserver: NSKeyValueObservation?
    private var isAdBlockEnabled: Bool = true
    private let downloadBridge = DownloadBridge()

    override init() {
        super.init()
        setupWebView()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let pref = WKWebpagePreferences()
        pref.allowsContentJavaScript = true
        config.defaultWebpagePreferences = pref

        let userContent = WKUserContentController()
        userContent.add(downloadBridge, name: "downloadBlobBridge")

        // 注入 Blob / 前端文件拦截脚本
        let blobScript = """
        (function() {
            var originalClick = HTMLAnchorElement.prototype.click;
            HTMLAnchorElement.prototype.click = function() {
                if (this.hasAttribute('download') && this.href && (this.href.startsWith('blob:') || this.href.startsWith('data:'))) {
                    fetch(this.href).then(r => r.blob()).then(blob => {
                        var reader = new FileReader();
                        reader.onloadend = function() {
                            var base64data = reader.result.split(',')[1];
                            window.webkit.messageHandlers.downloadBlobBridge.postMessage({
                                filename: this.download || 'downloaded_file',
                                base64: base64data
                            });
                        };
                        reader.readAsDataURL(blob);
                    });
                    return;
                }
                originalClick.apply(this, arguments);
            };
        })();
        """
        let userScript = WKUserScript(source: blobScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        userContent.addUserScript(userScript)
        config.userContentController = userContent

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = UserAgentStore.shared.activeItem.userAgent

        progressObserver = webView.observe(\.estimatedProgress, options: .new) { [weak self] _, _ in
            guard let self = self else { return }
            self.delegate?.tabDidUpdate(self)
        }
    }

    func load(url: URL) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        webView.load(req)
    }

    func reload() {
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func setAdBlockEnabled(_ enabled: Bool) {
        self.isAdBlockEnabled = enabled
    }

    func startRealDownload(url: URL, filename: String) {
        let req = URLRequest(url: url)
        webView.startDownload(using: req) { download in
            download.delegate = DownloadCoordinator.shared
        }
    }

    // MARK: - WKNavigationDelegate (保留完整上下文与 Headers 跳转)
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if let targetURL = navigationAction.request.url {
            let ext = targetURL.pathExtension.lowercased()
            let knownDownloadExts: Set<String> = ["ipa", "apk", "zip", "rar", "7z", "tar", "gz", "dmg", "pkg", "deb", "torrent"]
            if knownDownloadExts.contains(ext) {
                decisionHandler(.cancel, preferences)
                NotificationCenter.default.post(
                    name: NSNotification.Name("PromptDownloadConfirmationNotification"),
                    object: nil,
                    userInfo: ["url": targetURL, "filename": targetURL.lastPathComponent]
                )
                return
            }
        }

        // 新窗口直接在当前窗口继承加载，保留 POST 数据与 Headers，杜绝跳回
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel, preferences)
            return
        }

        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse {
            let disposition = response.allHeaderFields["Content-Disposition"] as? String ?? ""
            if disposition.lowercased().contains("attachment") {
                decisionHandler(.cancel)
                if let url = response.url {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("PromptDownloadConfirmationNotification"),
                        object: nil,
                        userInfo: ["url": url, "filename": response.suggestedFilename ?? url.lastPathComponent]
                    )
                }
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        delegate?.tabDidUpdate(self)
        if let host = webView.url?.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        delegate?.tabDidFail(self, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        delegate?.tabProcessTerminated(self)
    }

    // MARK: - WKUIDelegate
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
