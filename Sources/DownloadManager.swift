import UIKit
import WebKit

final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, WKDownloadDelegate {
    static let shared = DownloadCoordinator()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 3600.0
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private var downloadTasks: [URLSessionDownloadTask: (filename: String, targetURL: URL)] = [:]
    private var cancelledDownloadIDs: Set<ObjectIdentifier> = []

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

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let info = downloadTasks[downloadTask] else { return }
        let progress = totalBytesExpectedToWrite > 0 ? Float(totalBytesWritten) / Float(totalBytesExpectedToWrite) : 0
        NotificationCenter.default.post(
            name: NSNotification.Name("DownloadProgressNotification"),
            object: info.filename,
            userInfo: [
                "progress": progress,
                "written": totalBytesWritten,
                "total": totalBytesExpectedToWrite
            ]
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

        var isHandled = false
        let safeCompletion: (URL?) -> Void = { dest in
            guard !isHandled else { return }
            isHandled = true
            completionHandler(dest)
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("PromptDownloadNotification"),
                object: response.url,
                userInfo: [
                    "filename": filename,
                    "host": host,
                    "onConfirm": { [weak self] (shouldDownload: Bool) in
                        guard let self = self else {
                            safeCompletion(nil)
                            return
                        }
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
                            safeCompletion(targetURL)
                        } else {
                            self.cancelledDownloadIDs.insert(ObjectIdentifier(download))
                            safeCompletion(nil)
                        }
                    } as (Bool) -> Void
                ]
            )
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        cancelledDownloadIDs.remove(ObjectIdentifier(download))
        NotificationCenter.default.post(
            name: NSNotification.Name("DownloadFinishedNotification"),
            object: nil
        )
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if cancelledDownloadIDs.remove(ObjectIdentifier(download)) != nil {
            return
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        if nsError.domain == "WebKitErrorDomain" && (nsError.code == 1 || nsError.code == 102) {
            return
        }
        if nsError.domain == WKError.errorDomain {
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
        DownloadCoordinator.getDownloadsDirectory()
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

        let ext = item.url.pathExtension.lowercased()
        let isArchive = (ext == "zip" || ext == "gz")

        var content = cell.defaultContentConfiguration()
        content.text = item.name
        content.secondaryText = "\(item.sizeString) • \(item.dateString)"
        content.image = UIImage(systemName: isArchive ? "doc.zipper" : "doc.fill")
        content.imageProperties.tintColor = isArchive ? .systemOrange : .systemBlue
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
        shareFile(file, sourceView: cell)
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.row < files.count else { return nil }
        let file = files[indexPath.row]
        let cell = tableView.cellForRow(at: indexPath) ?? tableView
        let ext = file.url.pathExtension.lowercased()
        let isArchive = (ext == "zip" || ext == "gz")

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIAction] = []

            if isArchive {
                let unzipAction = UIAction(
                    title: "解压",
                    image: UIImage(systemName: "doc.zipper")
                ) { _ in
                    self?.unzipArchiveFile(file)
                }
                actions.append(unzipAction)
            }

            let shareAction = UIAction(
                title: "分享",
                image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in
                self?.shareFile(file, sourceView: cell)
            }
            actions.append(shareAction)

            let previewAction = UIAction(
                title: "文件预览",
                image: UIImage(systemName: "eye")
            ) { _ in
                self?.previewFile(file)
            }
            actions.append(previewAction)

            let deleteAction = UIAction(
                title: "删除",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in
                self?.deleteFile(file)
            }
            actions.append(deleteAction)

            return UIMenu(title: file.name, children: actions)
        }
    }

    private func unzipArchiveFile(_ file: DownloadedFile) {
        let destDir = getDownloadsDirectory().appendingPathComponent((file.name as NSString).deletingPathExtension, isDirectory: true)
        do {
            try ZipExtractor.unzip(archiveURL: file.url, destinationURL: destDir)
            loadDownloadedFiles()
            let alert = UIAlertController(title: "解压完成", message: "已解压至: \(destDir.lastPathComponent)", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default))
            present(alert, animated: true)
        } catch {
            let alert = UIAlertController(title: "解压失败", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default))
            present(alert, animated: true)
        }
    }

    private func shareFile(_ file: DownloadedFile, sourceView: UIView) {
        docController = UIDocumentInteractionController(url: file.url)
        docController?.delegate = self
        docController?.name = file.name

        let presented = docController?.presentOptionsMenu(from: sourceView.bounds, in: sourceView, animated: true) ?? false
        if !presented {
            let openInPresented = docController?.presentOpenInMenu(from: sourceView.bounds, in: sourceView, animated: true) ?? false
            if !openInPresented {
                let activity = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
                if let popover = activity.popoverPresentationController {
                    popover.sourceView = sourceView
                    popover.sourceRect = sourceView.bounds
                }
                present(activity, animated: true)
            }
        }
    }

    private func previewFile(_ file: DownloadedFile) {
        docController = UIDocumentInteractionController(url: file.url)
        docController?.delegate = self
        if !docController!.presentPreview(animated: true) {
            shareFile(file, sourceView: view)
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
        let ext = file.url.pathExtension.lowercased()
        let isArchive = (ext == "zip" || ext == "gz")

        var contextualActions: [UIContextualAction] = []

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            self?.deleteFile(file)
            completion(true)
        }
        contextualActions.append(deleteAction)

        let shareAction = UIContextualAction(style: .normal, title: "分享") { [weak self] _, _, completion in
            let cell = self?.tableView.cellForRow(at: indexPath) ?? self?.view ?? UIView()
            self?.shareFile(file, sourceView: cell)
            completion(true)
        }
        shareAction.backgroundColor = .systemBlue
        contextualActions.append(shareAction)

        if isArchive {
            let unzipAction = UIContextualAction(style: .normal, title: "解压") { [weak self] _, _, completion in
                self?.unzipArchiveFile(file)
                completion(true)
            }
            unzipAction.backgroundColor = .systemOrange
            contextualActions.append(unzipAction)
        }

        return UISwipeActionsConfiguration(actions: contextualActions)
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDownloadProgressNotification(_:)),
            name: NSNotification.Name("DownloadProgressNotification"),
            object: nil
        )
    }

    @objc func handleDownloadProgressNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let progress = userInfo["progress"] as? Float,
              let filename = notification.object as? String else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let percent = Int(progress * 100)
            let written = userInfo["written"] as? Int64 ?? 0
            let total = userInfo["total"] as? Int64 ?? 0
            let writtenStr = ByteCountFormatter.string(fromByteCount: written, countStyle: .file)
            let totalStr = total > 0 ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : ""
            let detail = totalStr.isEmpty ? "\(writtenStr) • \(percent)%" : "\(writtenStr)/\(totalStr) • \(percent)%"
            self.showDownloadProgressToast(filename: filename, progress: progress, detail: detail)
        }
    }

    func showDownloadProgressToast(filename: String, progress: Float, detail: String) {
        currentToastView?.layer.removeAllAnimations()
        currentToastView?.removeFromSuperview()

        let toast = UIView()
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.backgroundColor = .secondarySystemGroupedBackground
        toast.layer.cornerRadius = 16
        toast.layer.cornerCurve = .continuous
        toast.layer.borderWidth = 0.5
        toast.layer.borderColor = UIColor.separator.cgColor
        toast.layer.shadowColor = UIColor.black.cgColor
        toast.layer.shadowOpacity = 0.08
        toast.layer.shadowOffset = CGSize(width: 0, height: 3)
        toast.layer.shadowRadius = 8

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = filename
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingMiddle

        let detailLabel = UILabel()
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.text = detail
        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .right

        let pView = UIProgressView(progressViewStyle: .default)
        pView.translatesAutoresizingMaskIntoConstraints = false
        pView.progress = progress
        pView.progressTintColor = .systemBlue
        pView.trackTintColor = UIColor.systemGray5
        pView.layer.cornerRadius = 2
        pView.clipsToBounds = true

        let headerStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.axis = .horizontal
        headerStack.distribution = .fillProportionally
        headerStack.spacing = 8

        let mainStack = UIStackView(arrangedSubviews: [headerStack, pView])
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.axis = .vertical
        mainStack.spacing = 6

        toast.addSubview(mainStack)
        view.addSubview(toast)
        currentToastView = toast

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: toast.topAnchor, constant: 10),
            mainStack.bottomAnchor.constraint(equalTo: toast.bottomAnchor, constant: -10),
            mainStack.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 14),
            mainStack.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -14),
            pView.heightAnchor.constraint(equalToConstant: 4),

            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            toast.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            toast.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: -14)
        ])

        toast.alpha = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak toast] in
            guard let toast = toast else { return }
            UIView.animate(withDuration: 0.2, animations: { toast.alpha = 0 }) { _ in
                toast.removeFromSuperview()
            }
        }
    }

    @objc func handlePromptDownloadNotification(_ notification: Notification) {
        guard view.window != nil else { return }
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

        let presenter = presentedViewController ?? self
        presenter.present(alert, animated: true)
    }

    @objc func handlePromptBlobExportNotification(_ notification: Notification) {
        guard view.window != nil, let fileURL = notification.object as? URL else { return }
        let filename = (notification.userInfo?["filename"] as? String) ?? fileURL.lastPathComponent
        let fileSize = (notification.userInfo?["fileSize"] as? Int) ?? 0
        let sizeString = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)

        let alert = UIAlertController(
            title: "网页文件已准备就绪",
            message: "\(filename) (\(sizeString))\n\n该文件已在网页中生成完毕，您可以直接导出或保存至下载管理。",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "分享", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let doc = UIDocumentInteractionController(url: fileURL)
            doc.name = filename
            let presenter = self.presentedViewController ?? self
            if !doc.presentOptionsMenu(from: presenter.view.bounds, in: presenter.view, animated: true) {
                let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                if let popover = activity.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
                presenter.present(activity, animated: true)
            }
        })

        alert.addAction(UIAlertAction(title: "存入下载管理", style: .default) { [weak self] _ in
            self?.showToastNotice("已存入下载管理: \(filename)")
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
            try? FileManager.default.removeItem(at: fileURL)
        })

        let presenter = presentedViewController ?? self
        presenter.present(alert, animated: true)
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
