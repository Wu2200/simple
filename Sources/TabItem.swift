import UIKit
import WebKit

// MARK: - 标签页协议
protocol TabItemDelegate: AnyObject {
    func tabDidUpdate(_ tab: TabItem)
    func tabDidFail(_ tab: TabItem, error: Error)
    func tabRequestNewTab(_ tab: TabItem, url: URL?)
    func tabProcessTerminated(_ tab: TabItem)
    func tabRequestGoBack(_ tab: TabItem)
}

// MARK: - 下载代理管理
final class DownloadCoordinator: NSObject, WKDownloadDelegate {
    static let shared = DownloadCoordinator()
    private var downloadDestinations: [WKDownload: URL] = [:]

    private override init() {
        super.init()
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let downloadsDir = docs.appendingPathComponent("Downloads", isDirectory: true)

        if !fileManager.fileExists(atPath: downloadsDir.path) {
            try? fileManager.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        }

        var destination = downloadsDir.appendingPathComponent(suggestedFilename)
        var counter = 1
        let baseName = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension

        while fileManager.fileExists(atPath: destination.path) {
            let newName = ext.isEmpty ? "\(baseName)_\(counter)" : "\(baseName)_\(counter).\(ext)"
            destination = downloadsDir.appendingPathComponent(newName)
            counter += 1
        }

        downloadDestinations[download] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloadDestinations.removeValue(forKey: download)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("DownloadFinishedNotification"), object: nil)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: download)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("DownloadFailedNotification"), object: nil)
        }
    }
}

// MARK: - 标签页实体
final class TabItem: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    weak var delegate: TabItemDelegate?
    let webView: WKWebView

    var title: String {
        let t = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !t.isEmpty { return t }
        if let host = webView.url?.host, !host.isEmpty { return host }
        return "新标签页"
    }

    var currentURL: URL? {
        return webView.url
    }

    var isLoading: Bool {
        return webView.isLoading
    }

    var progress: Double {
        return webView.estimatedProgress
    }

    var isDesktopMode: Bool = false

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let userContent = WKUserContentController()
        config.userContentController = userContent

        let wv = WKWebView(frame: .zero, configuration: config)
        self.webView = wv
        super.init()

        userContent.add(self, name: "DownloadBridge")

        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true

        applyUserAgent()
    }

    func applyUserAgent() {
        let ua = UserAgentStore.shared.currentUA(isDesktop: isDesktopMode)
        webView.customUserAgent = ua
    }

    func setDesktopMode(_ desktop: Bool) {
        self.isDesktopMode = desktop
        applyUserAgent()
        webView.reload()
    }

    func setAdBlockEnabled(_ enabled: Bool) {
        // 预留 AdBlock 编译规则绑定
    }

    func load(url: URL) {
        applyUserAgent()
        let req = URLRequest(url: url)
        webView.load(req)
    }

    func reload() {
        applyUserAgent()
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func goBack() {
        if webView.canGoBack {
            webView.goBack()
        }
    }

    func goForward() {
        if webView.canGoForward {
            webView.goForward()
        }
    }

    func startRealDownload(url: URL, filename: String) {
        NotificationCenter.default.post(name: NSNotification.Name("DownloadStartedNotification"), object: nil)
        let req = URLRequest(url: url)
        webView.startDownload(using: req) { download in
            download.delegate = DownloadCoordinator.shared
        }
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow, preferences)
            return
        }

        // 识别常见文件直接下载类型
        let pathExt = url.pathExtension.lowercased()
        let fileExtensions: Set<String> = [
            "ipa", "apk", "zip", "rar", "7z", "tar", "gz", "bz2", "dmg", "pkg", "deb", "torrent", "pdf", "mp3", "mp4"
        ]

        if fileExtensions.contains(pathExt) && navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel, preferences)
            NotificationCenter.default.post(
                name: NSNotification.Name("PromptDownloadConfirmationNotification"),
                object: nil,
                userInfo: ["url": url, "filename": url.lastPathComponent]
            )
            return
        }

        // 解决前端动态跳转跳回问题：继承原 request 打开
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel, preferences)
            return
        }

        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.allHeaderFields["Content-Disposition"] as? String,
           disposition.lowercased().contains("attachment") {

            if let url = http.url {
                var suggested = navigationResponse.response.suggestedFilename ?? url.lastPathComponent
                if suggested.isEmpty { suggested = "downloaded_file" }
                decisionHandler(.cancel)
                NotificationCenter.default.post(
                    name: NSNotification.Name("PromptDownloadConfirmationNotification"),
                    object: nil,
                    userInfo: ["url": url, "filename": suggested]
                )
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let host = webView.url?.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        delegate?.tabDidFail(self, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
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

    // MARK: - WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // 前端脚本桥接预留
    }
}
