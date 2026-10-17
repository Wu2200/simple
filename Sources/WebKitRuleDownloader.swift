import UIKit
import WebKit

final class WebKitRuleDownloader: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    static let shared = WebKitRuleDownloader()

    private var activeWebView: WKWebView?
    private var completionHandler: ((Result<String, Error>) -> Void)?
    private var downloadTempURL: URL?
    private var timeoutTimer: Timer?

    private override init() {
        super.init()
    }

    func downloadRuleText(from url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.cancelCurrent()
            self.completionHandler = completion

            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = self
            self.activeWebView = webView

            self.timeoutTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false) { [weak self] _ in
                self?.finish(with: .failure(NSError(domain: "WebKitRuleDownloader", code: -1001, userInfo: [NSLocalizedDescriptionKey: "规则下载超时"])))
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 60.0
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("zh-CN,zh-Hans;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")

            webView.load(request)
        }
    }

    private func finish(with result: Result<String, Error>) {
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        let handler = completionHandler
        completionHandler = nil

        cancelCurrent()

        handler?(result)
    }

    private func cancelCurrent() {
        activeWebView?.stopLoading()
        activeWebView?.navigationDelegate = nil
        activeWebView = nil

        if let temp = downloadTempURL {
            try? FileManager.default.removeItem(at: temp)
            downloadTempURL = nil
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            let disposition = (httpResponse.allHeaderFields["Content-Disposition"] as? String ?? httpResponse.allHeaderFields["content-disposition"] as? String ?? "").lowercased()
            if disposition.contains("attachment") || !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.body.innerText || document.documentElement.innerText") { [weak self] result, error in
            guard let self = self else { return }
            if let text = result as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.finish(with: .success(text))
            } else if let error = error {
                self.finish(with: .failure(error))
            } else {
                self.finish(with: .failure(NSError(domain: "WebKitRuleDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "规则内容为空"])))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 {
            return
        }
        finish(with: .failure(error))
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("adblock_rule_\(UUID().uuidString).txt")
        self.downloadTempURL = tempFile
        completionHandler(tempFile)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let tempURL = downloadTempURL else {
            finish(with: .failure(NSError(domain: "WebKitRuleDownloader", code: -2, userInfo: [NSLocalizedDescriptionKey: "未找到下载的规则文件"])))
            return
        }

        do {
            let data = try Data(contentsOf: tempURL)
            try? FileManager.default.removeItem(at: tempURL)
            self.downloadTempURL = nil

            let text = String(decoding: data, as: UTF8.self)
            finish(with: .success(text))
        } catch {
            finish(with: .failure(error))
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(with: .failure(error))
    }
}
