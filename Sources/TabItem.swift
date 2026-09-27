import UIKit
import WebKit

final class TabItem: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {

    weak var delegate: TabItemDelegate?
    let webView: WKWebView

    private(set) var title: String = ""
    private(set) var currentURL: URL?
    private(set) var isLoading: Bool = false

    private var activeDownload: WKDownload?
    private var downloadSuggestedFilename: String = ""

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()

        let ucc = WKUserContentController()

        // 注入 Blob / Data URL 导出桥接
        let blobScript = """
        (function() {
            window.addEventListener('click', function(e) {
                var el = e.target.closest('a');
                if (el && el.href) {
                    var href = el.href;
                    if (href.startsWith('blob:') || href.startsWith('data:')) {
                        var downloadName = el.getAttribute('download') || 'download_file';
                        fetch(href).then(res => res.blob()).then(blob => {
                            var reader = new FileReader();
                            reader.onloadend = function() {
                                window.webkit.messageHandlers.DownloadBridge.postMessage({
                                    filename: downloadName,
                                    dataUrl: reader.result
                                });
                            };
                            reader.readAsDataURL(blob);
                        }).catch(err => {});
                    }
                }
            }, true);
        })();
        """
        ucc.addUserScript(WKUserScript(source: blobScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))

        config.userContentController = ucc

        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        ucc.add(self, name: "DownloadBridge")

        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        self.webView.allowsBackForwardNavigationGestures = true
        self.webView.customUserAgent = UserAgentStore.shared.currentUA

        self.webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)
        self.webView.addObserver(self, forKeyPath: "title", options: .new, context: nil)
        self.webView.addObserver(self, forKeyPath: "URL", options: .new, context: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(handleUAChange), name: NSNotification.Name("UserAgentDidChangeNotification"), object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        webView.removeObserver(self, forKeyPath: "estimatedProgress")
        webView.removeObserver(self, forKeyPath: "title")
        webView.removeObserver(self, forKeyPath: "URL")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "DownloadBridge")
    }

    @objc private func handleUAChange() {
        webView.customUserAgent = UserAgentStore.shared.currentUA
    }

    func load(url: URL) {
        currentURL = url
        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy
        webView.load(request)
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
        // 动态切换拦截状态
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "DownloadBridge", let dict = message.body as? [String: Any],
           let filename = dict["filename"] as? String,
           let dataUrl = dict["dataUrl"] as? String {
            handleBlobDataDownload(filename: filename, dataUrl: dataUrl)
        }
    }

    private func handleBlobDataDownload(filename: String, dataUrl: String) {
        guard let commaIndex = dataUrl.firstIndex(of: ",") else { return }
        let base64String = String(dataUrl[dataUrl.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else { return }

        let tempDir = FileManager.default.temporaryDirectory
        let safeName = filename.replacingOccurrences(of: "/", with: "_")
        let fileURL = tempDir.appendingPathComponent(safeName)

        do {
            try data.write(to: fileURL)
            NotificationCenter.default.post(name: NSNotification.Name("PromptBlobExportNotification"), object: nil, userInfo: [
                "fileURL": fileURL,
                "filename": safeName,
                "fileSize": data.count
            ])
        } catch {}
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "estimatedProgress" {
            delegate?.tabItem(self, didUpdateProgress: webView.estimatedProgress)
        } else if keyPath == "title" {
            self.title = webView.title ?? ""
            delegate?.tabItemDidUpdateInfo(self)
        } else if keyPath == "URL" {
            self.currentURL = webView.url
            delegate?.tabItemDidUpdateInfo(self)
        }
    }

    // MARK: - 解决页面跳转后又跳回来的问题
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            // 在当前 WebView 中完整继承并加载原始请求，保留 POST 表单、Referer、Cookies
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let ext = url.pathExtension.lowercased()
        let downloadExts: Set<String> = [
            "ipa", "apk", "zip", "rar", "7z", "tar", "gz", "dmg", "pkg", "deb", "torrent",
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx"
        ]

        if downloadExts.contains(ext) {
            decisionHandler(.cancel)
            NotificationCenter.default.post(name: NSNotification.Name("PromptDownloadConfirmationNotification"), object: nil, userInfo: [
                "url": url,
                "filename": url.lastPathComponent
            ])
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            let disposition = httpResponse.allHeaderFields["Content-Disposition"] as? String ?? ""
            if disposition.lowercased().contains("attachment") {
                if #available(iOS 15.0, *) {
                    decisionHandler(.download)
                    return
                }
            }
        }
        decisionHandler(.allow)
    }

    // MARK: - WKDownloadDelegate
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        self.activeDownload = download
        download.delegate = self
        NotificationCenter.default.post(name: NSNotification.Name("DownloadStartedNotification"), object: nil)
    }

    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        self.activeDownload = download
        download.delegate = self
        NotificationCenter.default.post(name: NSNotification.Name("DownloadStartedNotification"), object: nil)
    }

    @available(iOS 15.0, *)
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        self.downloadSuggestedFilename = suggestedFilename
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dlDir = docs.appendingPathComponent("Downloads", isDirectory: true)

        if !FileManager.default.fileExists(atPath: dlDir.path) {
            try? FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        }

        var targetURL = dlDir.appendingPathComponent(suggestedFilename)
        var counter = 1
        let baseName = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension

        while FileManager.default.fileExists(atPath: targetURL.path) {
            let newName = ext.isEmpty ? "\(baseName)_\(counter)" : "\(baseName)_\(counter).\(ext)"
            targetURL = dlDir.appendingPathComponent(newName)
            counter += 1
        }

        completionHandler(targetURL)
    }

    @available(iOS 15.0, *)
    func downloadDidFinish(_ download: WKDownload) {
        self.activeDownload = nil
        NotificationCenter.default.post(name: NSNotification.Name("DownloadFinishedNotification"), object: nil, userInfo: [
            "filename": self.downloadSuggestedFilename
        ])
    }

    @available(iOS 15.0, *)
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        self.activeDownload = nil
    }

    func startRealDownload(url: URL, filename: String) {
        if #available(iOS 15.0, *) {
            var req = URLRequest(url: url)
            req.cachePolicy = .useProtocolCachePolicy
            self.downloadSuggestedFilename = filename
            let dl = webView.startDownload(using: req)
            dl.delegate = self
            self.activeDownload = dl
            NotificationCenter.default.post(name: NSNotification.Name("DownloadStartedNotification"), object: nil)
        }
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        delegate?.tabItemDidStartLoading(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        currentURL = webView.url
        title = webView.title ?? ""
        delegate?.tabItemDidFinishLoading(self)

        if let host = webView.url?.host {
            FaviconLoader.shared.preloadFavicon(for: host)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        delegate?.tabItem(self, didFailLoadingWithError: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        delegate?.tabItem(self, didFailLoadingWithError: error)
    }
}

protocol TabItemDelegate: AnyObject {
    func tabItemDidStartLoading(_ item: TabItem)
    func tabItem(_ item: TabItem, didUpdateProgress progress: Double)
    func tabItemDidFinishLoading(_ item: TabItem)
    func tabItem(_ item: TabItem, didFailLoadingWithError error: Error)
    func tabItemDidUpdateInfo(_ item: TabItem)
}
