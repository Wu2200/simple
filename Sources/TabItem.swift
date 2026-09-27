import UIKit
import WebKit

// MARK: - 标签页协议定义
protocol TabItemDelegate: AnyObject {
    func tabDidUpdate(_ tab: TabItem)
    func tabDidFail(_ tab: TabItem, error: Error)
    func tabRequestNewTab(_ tab: TabItem, url: URL?)
    func tabProcessTerminated(_ tab: TabItem)
    func tabRequestGoBack(_ tab: TabItem)
    func tabItemDidStartLoading(_ item: TabItem)
    func tabItem(_ item: TabItem, didUpdateProgress progress: Double)
    func tabItemDidFinishLoading(_ item: TabItem)
    func tabItem(_ item: TabItem, didFailLoadingWithError error: Error)
}

extension TabItemDelegate {
    func tabDidUpdate(_ tab: TabItem) {}
    func tabDidFail(_ tab: TabItem, error: Error) {}
    func tabRequestNewTab(_ tab: TabItem, url: URL?) {}
    func tabProcessTerminated(_ tab: TabItem) {}
    func tabRequestGoBack(_ tab: TabItem) {}
    func tabItemDidStartLoading(_ item: TabItem) {}
    func tabItem(_ item: TabItem, didUpdateProgress progress: Double) {}
    func tabItemDidFinishLoading(_ item: TabItem) {}
    func tabItem(_ item: TabItem, didFailLoadingWithError error: Error) {}
}

// MARK: - 单标签页封装
final class TabItem: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {

    let id = UUID().uuidString
    let webView: WKWebView
    weak var delegate: TabItemDelegate?

    var title: String {
        return webView.title ?? ""
    }

    var currentURL: URL? {
        return webView.url
    }

    var isLoading: Bool {
        return webView.isLoading
    }

    var estimatedProgress: Double {
        return webView.estimatedProgress
    }

    var canGoBack: Bool {
        return webView.canGoBack
    }

    var canGoForward: Bool {
        return webView.canGoForward
    }

    private var progressObserver: NSKeyValueObservation?
    private var titleObserver: NSKeyValueObservation?
    private var urlObserver: NSKeyValueObservation?

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let userContent = WKUserContentController()
        config.userContentController = userContent

        let wv = WKWebView(frame: .zero, configuration: config)
        self.webView = wv
        super.init()

        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.customUserAgent = UserAgentStore.shared.currentUA

        userContent.add(self, name: "DownloadBridge")

        setupObservers()
    }

    private func setupObservers() {
        progressObserver = webView.observe(\.estimatedProgress, options: .new) { [weak self] wv, _ in
            guard let self = self else { return }
            self.delegate?.tabItem(self, didUpdateProgress: wv.estimatedProgress)
        }

        titleObserver = webView.observe(\.title, options: .new) { [weak self] _, _ in
            guard let self = self else { return }
            self.delegate?.tabDidUpdate(self)
        }

        urlObserver = webView.observe(\.url, options: .new) { [weak self] _, _ in
            guard let self = self else { return }
            self.delegate?.tabDidUpdate(self)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(handleUserAgentChanged), name: NSNotification.Name("UserAgentDidChangeNotification"), object: nil)
    }

    @objc private func handleUserAgentChanged() {
        webView.customUserAgent = UserAgentStore.shared.currentUA
    }

    func load(url: URL) {
        webView.load(URLRequest(url: url))
    }

    func reload() {
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

    func setAdBlockEnabled(_ enabled: Bool) {
        // 动态注入/清除规则
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        delegate?.tabItemDidStartLoading(self)
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        delegate?.tabItemDidFinishLoading(self)
        delegate?.tabDidUpdate(self)
        if let host = webView.url?.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        delegate?.tabItem(self, didFailLoadingWithError: error)
        delegate?.tabDidFail(self, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        delegate?.tabItem(self, didFailLoadingWithError: error)
        delegate?.tabDidFail(self, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        delegate?.tabProcessTerminated(self)
    }

    // 网页跳转与拦截
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
            return
        }

        if let url = navigationAction.request.url {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme != "http" && scheme != "https" && scheme != "about" {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
                return
            }

            let path = url.pathExtension.lowercased()
            let downloadExtensions: Set<String> = [
                "ipa", "apk", "zip", "rar", "7z", "tar", "gz", "dmg", "pkg", "deb", "torrent", "pdf"
            ]
            if downloadExtensions.contains(path) {
                promptDownload(url: url, filename: url.lastPathComponent)
                decisionHandler(.cancel)
                return
            }
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            if #available(iOS 15.0, *) {
                decisionHandler(.download)
            } else {
                if let url = navigationResponse.response.url {
                    promptDownload(url: url, filename: navigationResponse.response.suggestedFilename ?? url.lastPathComponent)
                }
                decisionHandler(.cancel)
            }
        }
    }

    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: - WKDownloadDelegate
    @available(iOS 15.0, *)
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let downloadsDir = docs.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: downloadsDir.path) {
            try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        }

        var destination = downloadsDir.appendingPathComponent(suggestedFilename)
        var counter = 1
        let name = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension

        while FileManager.default.fileExists(atPath: destination.path) {
            let newName = ext.isEmpty ? "\(name)_\(counter)" : "\(name)_\(counter).\(ext)"
            destination = downloadsDir.appendingPathComponent(newName)
            counter += 1
        }

        NotificationCenter.default.post(name: NSNotification.Name("DownloadStartedNotification"), object: nil)
        completionHandler(destination)
    }

    @available(iOS 15.0, *)
    func downloadDidFinish(_ download: WKDownload) {
        NotificationCenter.default.post(name: NSNotification.Name("DownloadFinishedNotification"), object: nil)
    }

    @available(iOS 15.0, *)
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        // 下载失败
    }

    // MARK: - 手动下载触发
    private func promptDownload(url: URL, filename: String) {
        NotificationCenter.default.post(
            name: NSNotification.Name("PromptDownloadConfirmationNotification"),
            object: nil,
            userInfo: ["url": url, "filename": filename]
        )
    }

    func startRealDownload(url: URL, filename: String) {
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, _ in
            guard let tempURL = tempURL else { return }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let downloadsDir = docs.appendingPathComponent("Downloads", isDirectory: true)
            if !FileManager.default.fileExists(atPath: downloadsDir.path) {
                try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
            }

            let destination = downloadsDir.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.moveItem(at: tempURL, to: destination)

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("DownloadFinishedNotification"), object: nil)
            }
        }
        NotificationCenter.default.post(name: NSNotification.Name("DownloadStartedNotification"), object: nil)
        task.resume()
    }

    // MARK: - WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "DownloadBridge", let body = message.body as? [String: Any] {
            if let urlStr = body["url"] as? String, let url = URL(string: urlStr) {
                let filename = body["filename"] as? String ?? url.lastPathComponent
                promptDownload(url: url, filename: filename)
            }
        }
    }
}
