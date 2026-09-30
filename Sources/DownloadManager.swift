import UIKit
import WebKit

final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, WKDownloadDelegate {
    static let shared = DownloadCoordinator()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private var downloadTasks: [URLSessionDownloadTask: (filename: String, targetURL: URL)] = [:]
    private var cancelledDownloads: Set<WKDownload> = []

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
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
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
                    "onConfirm": { [weak self] (shouldDownload: Bool) in
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
                            self?.cancelledDownloads.insert(download)
                            completionHandler(nil)
                        }
                    } as (Bool) -> Void
                ]
            )
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        cancelledDownloads.remove(download)
        NotificationCenter.default.post(
            name: NSNotification.Name("DownloadFinishedNotification"),
            object: nil
        )
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if cancelledDownloads.remove(download) != nil {
            return
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        if nsError.domain == WKError.errorDomain {
            return
        }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
            return
        }
        NotificationCenter.default.post(
            name: NSNotification.Name("DownloadFailedNotification"),
            object: error.localizedDescription
        )
    }
}

final class DownloadManagerViewController: UITableViewController, UIDocumentInteractionControllerDelegate {
    private struct DownloadedFile {
        let name: String
        let url: URL
        let sizeString: String
        let dateString: String
    }

    private var files: [DownloadedFile] = []
    private var docController: UIDocumentInteractionController?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "下载管理"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DownloadFileCell")
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleClose))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "清空", style: .plain, target: self, action: #selector(handleClearAll))
        loadDownloadedFiles()
    }

    @objc private func handleClose() {
        dismiss(animated: true)
    }

    private func getDownloadsDirectory() -> URL {
        return DownloadCoordinator.getDownloadsDirectory()
    }

    private func loadDownloadedFiles() {
        let fm = FileManager.default
        var list: [DownloadedFile] = []
        let dirs = [getDownloadsDirectory(), fm.urls(for: .documentDirectory, in: .userDomainMask)[0]]

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"

        for dir in dirs {
            if let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey], options: .skipsHiddenFiles) {
                for url in urls {
                    let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                    if vals?.isDirectory == true { continue }

                    let size = vals?.fileSize ?? 0
                    let date = vals?.contentModificationDate ?? Date()
                    let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                    let dateStr = df.string(from: date)

                    list.append(DownloadedFile(name: url.lastPathComponent, url: url, sizeString: sizeStr, dateString: dateStr))
                }
            }
        }

        self.files = list
        tableView.reloadData()
    }

    @objc private func handleClearAll() {
        guard !files.isEmpty else { return }
        let alert = UIAlertController(title: "清空下载文件", message: "确定要删除所有已下载的文件吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            let fm = FileManager.default
            for f in self.files {
                try? fm.removeItem(at: f.url)
            }
            self.loadDownloadedFiles()
        })
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        files.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DownloadFileCell", for: indexPath)
        let item = files[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = item.name
        content.secondaryText = "\(item.sizeString) • \(item.dateString)"
        content.image = UIImage(systemName: "doc.fill")
        content.imageProperties.tintColor = .systemBlue
        content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < files.count else { return }
        let file = files[indexPath.row]
        let cell = tableView.cellForRow(at: indexPath) ?? tableView

        let alert = UIAlertController(title: file.name, message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "隔空投送/分享/其他应用", style: .default) { [weak self] _ in
            self?.shareFile(file, sourceView: cell)
        })

        alert.addAction(UIAlertAction(title: "文件预览", style: .default) { [weak self] _ in
            self?.previewFile(file)
        })

        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.deleteFile(file)
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }

        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.row < files.count else { return nil }
        let file = files[indexPath.row]
        let cell = tableView.cellForRow(at: indexPath) ?? tableView

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let shareAction = UIAction(
                title: "隔空投送/分享/其他应用",
                image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in
                self?.shareFile(file, sourceView: cell)
            }

            let previewAction = UIAction(
                title: "文件预览",
                image: UIImage(systemName: "eye")
            ) { _ in
                self?.previewFile(file)
            }

            let deleteAction = UIAction(
                title: "删除",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in
                self?.deleteFile(file)
            }

            return UIMenu(title: file.name, children: [shareAction, previewAction, deleteAction])
        }
    }

    private func shareFile(_ file: DownloadedFile, sourceView: UIView) {
        let activity = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        present(activity, animated: true)
    }

    private func previewFile(_ file: DownloadedFile) {
        docController = UIDocumentInteractionController(url: file.url)
        docController?.delegate = self
        if !docController!.presentPreview(animated: true) {
            docController?.presentOptionsMenu(from: view.bounds, in: view, animated: true)
        }
    }

    private func deleteFile(_ file: DownloadedFile) {
        try? FileManager.default.removeItem(at: file.url)
        loadDownloadedFiles()
    }

    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        self
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.row < files.count else { return nil }
        let file = files[indexPath.row]

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            self?.deleteFile(file)
            completion(true)
        }

        let shareAction = UIContextualAction(style: .normal, title: "隔空投送/分享/其他应用") { [weak self] _, _, completion in
            let cell = self?.tableView.cellForRow(at: indexPath) ?? self?.view ?? UIView()
            self?.shareFile(file, sourceView: cell)
            completion(true)
        }
        shareAction.backgroundColor = .systemBlue

        return UISwipeActionsConfiguration(actions: [deleteAction, shareAction])
    }
}

extension BrowserViewController {
    func configureDownloadObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptDownloadNotification(_:)),
            name: NSNotification.Name("PromptDownloadNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptBlobExportNotification(_:)),
            name: NSNotification.Name("PromptBlobExportNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDownloadNotification(_:)),
            name: NSNotification.Name("DownloadStartedNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDownloadNotification(_:)),
            name: NSNotification.Name("DownloadFinishedNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDownloadNotification(_:)),
            name: NSNotification.Name("DownloadFailedNotification"),
            object: nil
        )
    }

    @objc func handlePromptDownloadNotification(_ notification: Notification) {
        let url = notification.object as? URL
        let filename = (notification.userInfo?["filename"] as? String) ?? url?.lastPathComponent ?? "文件"
        let displayName = filename.isEmpty ? "文件" : filename
        let onConfirm = notification.userInfo?["onConfirm"] as? ((Bool) -> Void)

        let alert = UIAlertController(
            title: "下载文件",
            message: "\(displayName)\n\n来源: \(url?.host ?? url?.absoluteString ?? "未知来源")",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "下载文件", style: .default) { _ in
            if let onConfirm = onConfirm {
                onConfirm(true)
            } else if let url = url {
                DownloadCoordinator.shared.startDownload(url: url, filename: displayName)
            }
        })

        alert.addAction(UIAlertAction(title: "复制下载链接", style: .default) { [weak self] _ in
            if let url = url {
                UIPasteboard.general.string = url.absoluteString
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.showToastNotice("复制成功")
            }
            onConfirm?(false)
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
            onConfirm?(false)
        })

        present(alert, animated: true)
    }

    @objc func handlePromptBlobExportNotification(_ notification: Notification) {
        guard let fileURL = notification.object as? URL else { return }
        let filename = (notification.userInfo?["filename"] as? String) ?? fileURL.lastPathComponent
        let fileSize = (notification.userInfo?["fileSize"] as? Int) ?? 0
        let sizeString = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)

        let alert = UIAlertController(
            title: "网页文件已准备就绪",
            message: "\(filename) (\(sizeString))\n\n该文件已在网页中生成完毕，您可以直接导出或保存至下载管理。",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "隔空投送/分享/其他应用", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = self.view
                popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            self.present(activity, animated: true)
        })

        alert.addAction(UIAlertAction(title: "存入下载管理", style: .default) { [weak self] _ in
            self?.showToastNotice("已存入下载管理: \(filename)")
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
            try? FileManager.default.removeItem(at: fileURL)
        })

        present(alert, animated: true)
    }

    @objc func handleDownloadNotification(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            if notification.name == NSNotification.Name("DownloadStartedNotification") {
                if let filename = notification.object as? String {
                    self?.showToastNotice("开始下载: \(filename)")
                } else {
                    self?.showToastNotice("已开始下载任务")
                }
            } else if notification.name == NSNotification.Name("DownloadFinishedNotification") {
                self?.showToastNotice("下载完成，已存入下载管理")
            } else if notification.name == NSNotification.Name("DownloadFailedNotification") {
                if let err = notification.object as? String {
                    self?.showToastNotice("下载失败: \(err)")
                } else {
                    self?.showToastNotice("下载失败")
                }
            }
        }
    }

    func showDownloadManager() {
        if addressField.isFirstResponder {
            addressField.resignFirstResponder()
        }
        let vc = DownloadManagerViewController()
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }
}
