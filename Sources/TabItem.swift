import UIKit
import WebKit

// MARK: - 下载核心协调器（提供手动确认弹窗与沙盒落盘）
public final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate {
    public static let shared = DownloadCoordinator()

    public static let promptNotification = Notification.Name("PromptDownloadConfirmationNotification")
    public static let startedNotification = Notification.Name("DownloadStartedNotification")
    public static let finishedNotification = Notification.Name("DownloadFinishedNotification")
    public static let failedNotification = Notification.Name("DownloadFailedNotification")

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private var downloadTasks: [URLSessionDownloadTask: (filename: String, targetURL: URL)] = [:]

    private override init() {
        super.init()
    }

    /// 请求弹出下载手动确认提示框（绝不自动下载）
    public func requestDownloadPrompt(url: URL, suggestedFilename: String? = nil) {
        let name: String
        if let s = suggestedFilename, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = s
        } else if !url.lastPathComponent.isEmpty {
            name = url.lastPathComponent
        } else {
            name = "download_\(Int(Date().timeIntervalSince1970))"
        }

        NotificationCenter.default.post(
            name: Self.promptNotification,
            object: nil,
            userInfo: [
                "url": url,
                "filename": name
            ]
        )
    }

    /// 用户手动确认后开始真实下载
    public func startDownload(url: URL, filename: String) {
        let fileManager = FileManager.default
        guard let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let downloadsDir = docsURL.appendingPathComponent("Downloads")
        try? fileManager.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        var targetURL = downloadsDir.appendingPathComponent(filename)
        var counter = 1
        let nameWithoutExt = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        while fileManager.fileExists(atPath: targetURL.path) {
            let newName = ext.isEmpty ? "\(nameWithoutExt)_\(counter)" : "\(nameWithoutExt)_\(counter).\(ext)"
            targetURL = downloadsDir.appendingPathComponent(newName)
            counter += 1
        }

        let task = session.downloadTask(with: url)
        downloadTasks[task] = (filename, targetURL)
        task.resume()

        NotificationCenter.default.post(
            name: Self.startedNotification,
            object: nil,
            userInfo: [
                "filename": filename,
                "url": url
            ]
        )
    }

    // MARK: - URLSessionDownloadDelegate
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = downloadTasks[downloadTask] else { return }
        downloadTasks.removeValue(forKey: downloadTask)

        do {
            if FileManager.default.fileExists(atPath: info.targetURL.path) {
                try FileManager.default.removeItem(at: info.targetURL)
            }
            try FileManager.default.moveItem(at: location, to: info.targetURL)
            NotificationCenter.default.post(
                name: Self.finishedNotification,
                object: nil,
                userInfo: [
                    "filename": info.filename,
                    "fileURL": info.targetURL
                ]
            )
        } catch {
            NotificationCenter.default.post(
                name: Self.failedNotification,
                object: nil,
                userInfo: [
                    "filename": info.filename,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask, let error = error else { return }
        if let info = downloadTasks[downloadTask] {
            downloadTasks.removeValue(forKey: downloadTask)
            NotificationCenter.default.post(
                name: Self.failedNotification,
                object: nil,
                userInfo: [
                    "filename": info.filename,
                    "error": error.localizedDescription
                ]
            )
        }
    }
}

// MARK: - 标签页模型
public final class TabItem: NSObject, WKNavigationDelegate, WKUIDelegate {
    public let id: UUID
    public var title: String
    public var url: URL?
    public var webView: WKWebView
    public var screenshot: UIImage?
    public var lastAccessTime: Date
    public var isDesktopMode: Bool = false

    public init(id: UUID = UUID(), title: String = "新标签页", url: URL? = nil, webView: WKWebView? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.lastAccessTime = Date()

        if let existing = webView {
            self.webView = existing
        } else {
            let config = WKWebViewConfiguration()
            config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []
            self.webView = WKWebView(frame: .zero, configuration: config)
        }

        super.init()
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        self.webView.allowsBackForwardNavigationGestures = true
    }

    public func snapshot(completion: @escaping (UIImage?) -> Void) {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            self?.screenshot = image
            completion(image)
        }
    }

    public func reload() {
        webView.reload()
    }

    // MARK: - WKNavigationDelegate 下载手动拦截（严禁自动下载，必须弹出提示框由用户选择）
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let reqURL = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let downloadableExtensions: Set<String> = [
            "ipa", "apk", "zip", "rar", "7z", "tar", "gz", "bz2", "xz",
            "dmg", "pkg", "deb", "torrent", "pdf", "mp4", "mov", "avi", "mkv",
            "mp3", "flac", "wav", "exe", "iso", "bin", "doc", "docx", "xls", "xlsx", "ppt", "pptx"
        ]

        let ext = reqURL.pathExtension.lowercased()
        if downloadableExtensions.contains(ext) {
            decisionHandler(.cancel)
            DownloadCoordinator.shared.requestDownloadPrompt(url: reqURL, suggestedFilename: reqURL.lastPathComponent)
            return
        }

        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            let isAttachment = httpResponse.allHeaderFields.contains { key, value in
                guard let k = key as? String, k.lowercased() == "content-disposition" else { return false }
                return (value as? String)?.lowercased().contains("attachment") ?? false
            }

            if isAttachment || !navigationResponse.canShowMIMEType {
                decisionHandler(.cancel)
                let name = navigationResponse.response.suggestedFilename ?? navigationResponse.response.url?.lastPathComponent ?? "file"
                if let url = navigationResponse.response.url {
                    DownloadCoordinator.shared.requestDownloadPrompt(url: url, suggestedFilename: name)
                }
                return
            }
        }

        decisionHandler(.allow)
    }
}
