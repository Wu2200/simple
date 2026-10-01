import UIKit
import WebKit

struct ActiveDownloadItem {
    let id: String
    let filename: String
    var progress: Float
    var writtenBytes: Int64
    var totalBytes: Int64
    var isFailed: Bool
    var errorMessage: String?
}

final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, WKDownloadDelegate {
    static let shared = DownloadCoordinator()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 3600.0
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private var downloadTasks: [URLSessionDownloadTask: (filename: String, targetURL: URL)] = [:]
    private var cancelledDownloadIDs: Set<ObjectIdentifier> = []
    private var progressObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var downloadTargets: [ObjectIdentifier: (filename: String, targetURL: URL)] = [:]

    private(set) var activeTasks: [String: ActiveDownloadItem] = [:]

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

        let taskID = "\(task.taskIdentifier)"
        activeTasks[taskID] = ActiveDownloadItem(
            id: taskID,
            filename: baseFilename,
            progress: 0.01,
            writtenBytes: 0,
            totalBytes: 0,
            isFailed: false,
            errorMessage: nil
        )

        task.resume()

        NotificationCenter.default.post(
            name: NSNotification.Name("DownloadStartedNotification"),
            object: baseFilename,
            userInfo: ["taskId": taskID]
        )
    }

    func removeActiveTask(id: String) {
        activeTasks.removeValue(forKey: id)
        NotificationCenter.default.post(name: NSNotification.Name("ActiveDownloadTasksChangedNotification"), object: nil)
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
        let taskID = "\(downloadTask.taskIdentifier)"
        activeTasks[taskID] = ActiveDownloadItem(
            id: taskID,
            filename: info.filename,
            progress: progress,
            writtenBytes: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite,
            isFailed: false,
            errorMessage: nil
        )

        NotificationCenter.default.post(
            name: NSNotification.Name("DownloadProgressNotification"),
            object: info.filename,
            userInfo: [
                "taskId": taskID,
                "progress": progress,
                "written": totalBytesWritten,
                "total": totalBytesExpectedToWrite
            ]
        )
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = downloadTasks[downloadTask] else { return }
        downloadTasks.removeValue(forKey: downloadTask)
        let taskID = "\(downloadTask.taskIdentifier)"
        activeTasks.removeValue(forKey: taskID)

        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: info.targetURL.path) {
                try fm.removeItem(at: info.targetURL)
            }
            try fm.moveItem(at: location, to: info.targetURL)
            NotificationCenter.default.post(
                name: NSNotification.Name("DownloadFinishedNotification"),
                object: info.targetURL.lastPathComponent,
                userInfo: ["taskId": taskID]
            )
        } catch {
            activeTasks[taskID] = ActiveDownloadItem(
                id: taskID,
                filename: info.filename,
                progress: 0,
                writtenBytes: 0,
                totalBytes: 0,
                isFailed: true,
                errorMessage: error.localizedDescription
            )
            NotificationCenter.default.post(
                name: NSNotification.Name("DownloadFailedNotification"),
                object: info.filename,
                userInfo: ["taskId": taskID, "error": error.localizedDescription]
            )
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask, let error = error else { return }
        if let info = downloadTasks[downloadTask] {
            downloadTasks.removeValue(forKey: downloadTask)
            let taskID = "\(downloadTask.taskIdentifier)"
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                activeTasks.removeValue(forKey: taskID)
                return
            }
            activeTasks[taskID] = ActiveDownloadItem(
                id: taskID,
                filename: info.filename,
                progress: 0,
                writtenBytes: 0,
                totalBytes: 0,
                isFailed: true,
                errorMessage: error.localizedDescription
            )
            NotificationCenter.default.post(
                name: NSNotification.Name("DownloadFailedNotification"),
                object: info.filename,
                userInfo: ["taskId": taskID, "error": error.localizedDescription]
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
        let downloadID = ObjectIdentifier(download)
        let taskKey = "\(downloadID.hashValue)"

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

                            self.downloadTargets[downloadID] = (filename, targetURL)
                            self.activeTasks[taskKey] = ActiveDownloadItem(
                                id: taskKey,
                                filename: filename,
                                progress: 0.01,
                                writtenBytes: 0,
                                totalBytes: response.expectedContentLength > 0 ? response.expectedContentLength : 0,
                                isFailed: false,
                                errorMessage: nil
                            )

                            let obs = download.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                                guard let self = self else { return }
                                let currentProgress = Float(p.fractionCompleted)
                                let written = p.completedUnitCount
                                let total = p.totalUnitCount
                                DispatchQueue.main.async {
                                    self.activeTasks[taskKey] = ActiveDownloadItem(
                                        id: taskKey,
                                        filename: filename,
                                        progress: currentProgress,
                                        writtenBytes: written,
                                        totalBytes: total,
                                        isFailed: false,
                                        errorMessage: nil
                                    )
                                    NotificationCenter.default.post(
                                        name: NSNotification.Name("DownloadProgressNotification"),
                                        object: filename,
                                        userInfo: [
                                            "taskId": taskKey,
                                            "progress": currentProgress,
                                            "written": written,
                                            "total": total
                                        ]
                                    )
                                }
                            }
                            self.progressObservations[downloadID] = obs

                            NotificationCenter.default.post(
                                name: NSNotification.Name("DownloadStartedNotification"),
                                object: filename,
                                userInfo: ["taskId": taskKey]
                            )
                            safeCompletion(targetURL)
                        } else {
                            self.cancelledDownloadIDs.insert(downloadID)
                            safeCompletion(nil)
                        }
                    } as (Bool) -> Void
                ]
            )
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let downloadID = ObjectIdentifier(download)
        let taskKey = "\(downloadID.hashValue)"
        let targetInfo = downloadTargets.removeValue(forKey: downloadID)
        progressObservations[downloadID]?.invalidate()
        progressObservations.removeValue(forKey: downloadID)
        cancelledDownloadIDs.remove(downloadID)
        activeTasks.removeValue(forKey: taskKey)

        NotificationCenter.default.post(
            name: NSNotification.Name("DownloadFinishedNotification"),
            object: targetInfo?.filename ?? nil,
            userInfo: ["taskId": taskKey]
        )
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let downloadID = ObjectIdentifier(download)
        let taskKey = "\(downloadID.hashValue)"
        let targetInfo = downloadTargets.removeValue(forKey: downloadID)
        progressObservations[downloadID]?.invalidate()
        progressObservations.removeValue(forKey: downloadID)

        if cancelledDownloadIDs.remove(downloadID) != nil {
            activeTasks.removeValue(forKey: taskKey)
            return
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            activeTasks.removeValue(forKey: taskKey)
            return
        }
        if nsError.domain == "WebKitErrorDomain" && (nsError.code == 1 || nsError.code == 102) {
            activeTasks.removeValue(forKey: taskKey)
            return
        }

        let fname = targetInfo?.filename ?? "文件"
        activeTasks[taskKey] = ActiveDownloadItem(
            id: taskKey,
            filename: fname,
            progress: 0,
            writtenBytes: 0,
            totalBytes: 0,
            isFailed: true,
            errorMessage: error.localizedDescription
        )

        NotificationCenter.default.post(
            name: NSNotification.Name("DownloadFailedNotification"),
            object: fname,
            userInfo: ["taskId": taskKey, "error": error.localizedDescription]
        )
    }
}

final class DownloadProgressCell: UITableViewCell {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let errorLabel = UILabel()
    private let removeButton = UIButton(type: .system)

    var onRemove: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        selectionStyle = .none

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingMiddle

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .right

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.layer.cornerRadius = 2
        progressView.clipsToBounds = true

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = .systemFont(ofSize: 12, weight: .medium)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 2
        errorLabel.isHidden = true

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        removeButton.tintColor = .systemGray3
        removeButton.addTarget(self, action: #selector(handleRemove), for: .touchUpInside)

        let topRow = UIStackView(arrangedSubviews: [titleLabel, detailLabel, removeButton])
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.axis = .horizontal
        topRow.spacing = 8
        topRow.alignment = .center

        let mainStack = UIStackView(arrangedSubviews: [topRow, progressView, errorLabel])
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.axis = .vertical
        mainStack.spacing = 6

        contentView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            removeButton.widthAnchor.constraint(equalToConstant: 24),
            removeButton.heightAnchor.constraint(equalToConstant: 24),
            progressView.heightAnchor.constraint(equalToConstant: 4),

            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])
    }

    @objc private func handleRemove() {
        onRemove?()
    }

    func configure(with item: ActiveDownloadItem) {
        titleLabel.text = item.filename
        if item.isFailed {
            progressView.progressTintColor = .systemRed
            progressView.progress = 1.0
            detailLabel.text = "下载失败"
            detailLabel.textColor = .systemRed
            errorLabel.text = item.errorMessage ?? "未知错误"
            errorLabel.isHidden = false
        } else {
            progressView.progressTintColor = .systemBlue
            progressView.progress = item.progress
            detailLabel.textColor = .secondaryLabel
            errorLabel.isHidden = true

            let percent = Int(item.progress * 100)
            let writtenStr = ByteCountFormatter.string(fromByteCount: item.writtenBytes, countStyle: .file)
            let totalStr = item.totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file) : ""
            detailLabel.text = totalStr.isEmpty ? "\(writtenStr) • \(percent)%" : "\(writtenStr)/\(totalStr) • \(percent)%"
        }
    }
}

final class DownloadManagerViewController: UITableViewController, UIDocumentInteractionControllerDelegate {
    struct DownloadedItem {
        let name: String
        let url: URL
        let sizeString: String
        let dateString: String
        let date: Date
        let isDirectory: Bool
    }

    private var currentDirectory: URL
    private var files: [DownloadedItem] = []
    private var docController: UIDocumentInteractionController?

    init(directoryURL: URL? = nil) {
        self.currentDirectory = directoryURL ?? DownloadCoordinator.getDownloadsDirectory()
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        self.currentDirectory = DownloadCoordinator.getDownloadsDirectory()
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let isRoot = (currentDirectory == DownloadCoordinator.getDownloadsDirectory())
        title = isRoot ? "下载管理" : currentDirectory.lastPathComponent

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DownloadFileCell")
        tableView.register(DownloadProgressCell.self, forCellReuseIdentifier: "DownloadProgressCell")

        if isRoot {
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleClose))
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "清空", style: .plain, target: self, action: #selector(handleClearAll))
        }

        NotificationCenter.default.addObserver(self, selector: #selector(handleProgressChanged), name: NSNotification.Name("DownloadProgressNotification"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleTasksChanged), name: NSNotification.Name("DownloadStartedNotification"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleTasksChanged), name: NSNotification.Name("DownloadFinishedNotification"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleTasksChanged), name: NSNotification.Name("DownloadFailedNotification"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleTasksChanged), name: NSNotification.Name("ActiveDownloadTasksChangedNotification"), object: nil)

        loadDownloadedFiles()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleClose() {
        dismiss(animated: true)
    }

    @objc private func handleProgressChanged() {
        if !DownloadCoordinator.shared.activeTasks.isEmpty {
            tableView.reloadSections(IndexSet(integer: 0), with: .none)
        }
    }

    @objc private func handleTasksChanged() {
        loadDownloadedFiles()
    }

    private func getActiveTasks() -> [ActiveDownloadItem] {
        Array(DownloadCoordinator.shared.activeTasks.values).sorted { $0.id > $1.id }
    }

    private func loadDownloadedFiles() {
        let fm = FileManager.default
        var list: [DownloadedItem] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"

        if let urls = try? fm.contentsOfDirectory(at: currentDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey], options: .skipsHiddenFiles) {
            for url in urls {
                let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDir = vals?.isDirectory == true
                let date = vals?.contentModificationDate ?? Date()
                let dateStr = df.string(from: date)

                var sizeStr = ""
                if isDir {
                    let subCount = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles).count) ?? 0
                    sizeStr = "\(subCount) 项"
                } else {
                    let size = vals?.fileSize ?? 0
                    sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                }

                list.append(DownloadedItem(
                    name: url.lastPathComponent,
                    url: url,
                    sizeString: sizeStr,
                    dateString: dateStr,
                    date: date,
                    isDirectory: isDir
                ))
            }
        }

        list.sort { $0.date > $1.date }
        self.files = list
        tableView.reloadData()
    }

    @objc private func handleClearAll() {
        guard !files.isEmpty else { return }
        let alert = UIAlertController(title: "清空下载文件", message: "确定要删除当前目录下的所有文件及解压文件夹吗？", preferredStyle: .alert)
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

    override func numberOfSections(in tableView: UITableView) -> Int {
        let isRoot = (currentDirectory == DownloadCoordinator.getDownloadsDirectory())
        let active = getActiveTasks()
        if isRoot && !active.isEmpty {
            return 2
        }
        return 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let isRoot = (currentDirectory == DownloadCoordinator.getDownloadsDirectory())
        let active = getActiveTasks()
        if isRoot && !active.isEmpty {
            return section == 0 ? "下载任务" : "已下载文件"
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let isRoot = (currentDirectory == DownloadCoordinator.getDownloadsDirectory())
        let active = getActiveTasks()
        if isRoot && !active.isEmpty {
            return section == 0 ? active.count : files.count
        }
        return files.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let isRoot = (currentDirectory == DownloadCoordinator.getDownloadsDirectory())
        let active = getActiveTasks()

        if isRoot && !active.isEmpty && indexPath.section == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "DownloadProgressCell", for: indexPath) as! DownloadProgressCell
            let task = active[indexPath.row]
            cell.configure(with: task)
            cell.onRemove = {
                DownloadCoordinator.shared.removeActiveTask(id: task.id)
            }
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "DownloadFileCell", for: indexPath)
        let item = files[indexPath.row]
        let ext = item.url.pathExtension.lowercased()
        let isArchive = (ext == "zip" || ext == "gz")

        var content = cell.defaultContentConfiguration()
        content.text = item.name
        content.secondaryText = "\(item.sizeString) • \(item.dateString)"

        if item.isDirectory {
            content.image = UIImage(systemName: "folder.fill")
            content.imageProperties.tintColor = .systemYellow
        } else if isArchive {
            content.image = UIImage(systemName: "doc.zipper")
            content.imageProperties.tintColor = .systemOrange
        } else {
            content.image = UIImage(systemName: "doc.fill")
            content.imageProperties.tintColor = .systemBlue
        }
        content.imageProperties.maximumSize = CGSize(width: 22, height: 22)

        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let isRoot = (currentDirectory == DownloadCoordinator.getDownloadsDirectory())
        let active = getActiveTasks()
        if isRoot && !active.isEmpty && indexPath.section == 0 {
            return
        }

        guard indexPath.row < files.count else { return }
        let item = files[indexPath.row]

        if item.isDirectory {
            let subVC = DownloadManagerViewController(directoryURL: item.url)
            navigationController?.pushViewController(subVC, animated: true)
            return
        }

        let cell = tableView.cellForRow(at: indexPath) ?? tableView
        shareFile(item, sourceView: cell)
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let isRoot = (currentDirectory == DownloadCoordinator.getDownloadsDirectory())
        let active = getActiveTasks()
        if isRoot && !active.isEmpty && indexPath.section == 0 {
            return nil
        }

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

            if !file.isDirectory {
                let previewAction = UIAction(
                    title: "文件预览",
                    image: UIImage(systemName: "eye")
                ) { _ in
                    self?.previewFile(file)
                }
                actions.append(previewAction)
            }

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

    private func unzipArchiveFile(_ file: DownloadedItem) {
        let destDir = currentDirectory.appendingPathComponent((file.name as NSString).deletingPathExtension, isDirectory: true)
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

    private func shareFile(_ file: DownloadedItem, sourceView: UIView) {
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

    private func previewFile(_ file: DownloadedItem) {
        docController = UIDocumentInteractionController(url: file.url)
        docController?.delegate = self
        if !docController!.presentPreview(animated: true) {
            shareFile(file, sourceView: view)
        }
    }

    private func deleteFile(_ file: DownloadedItem) {
        try? FileManager.default.removeItem(at: file.url)
        loadDownloadedFiles()
    }

    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        self
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let isRoot = (currentDirectory == DownloadCoordinator.getDownloadsDirectory())
        let active = getActiveTasks()
        if isRoot && !active.isEmpty && indexPath.section == 0 {
            let task = active[indexPath.row]
            let deleteAction = UIContextualAction(style: .destructive, title: "移除") { _, _, completion in
                DownloadCoordinator.shared.removeActiveTask(id: task.id)
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [deleteAction])
        }

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
            self.showDownloadProgressToast(filename: filename, progress: progress, detail: detail, errorMessage: nil)
        }
    }

    func showDownloadProgressToast(filename: String, progress: Float, detail: String, errorMessage: String?) {
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
        detailLabel.textColor = errorMessage != nil ? .systemRed : .secondaryLabel
        detailLabel.textAlignment = .right

        let pView = UIProgressView(progressViewStyle: .default)
        pView.translatesAutoresizingMaskIntoConstraints = false
        pView.progress = progress
        pView.progressTintColor = errorMessage != nil ? .systemRed : .systemBlue
        pView.trackTintColor = UIColor.systemGray5
        pView.layer.cornerRadius = 2
        pView.clipsToBounds = true

        let headerStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.axis = .horizontal
        headerStack.distribution = .fillProportionally
        headerStack.spacing = 8

        var arrangedSubviews: [UIView] = [headerStack, pView]

        if let err = errorMessage {
            let errLabel = UILabel()
            errLabel.translatesAutoresizingMaskIntoConstraints = false
            errLabel.text = "失败原因: \(err)"
            errLabel.font = .systemFont(ofSize: 11, weight: .medium)
            errLabel.textColor = .systemRed
            errLabel.numberOfLines = 2
            arrangedSubviews.append(errLabel)
        }

        let mainStack = UIStackView(arrangedSubviews: arrangedSubviews)
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
        let dismissDelay = errorMessage != nil ? 4.5 : 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay) { [weak toast] in
            guard let toast = toast else { return }
            UIView.animate(withDuration: 0.2, animations: { toast.alpha = 0 }) { _ in
                toast.removeFromSuperview()
            }
        }
    }

    func safePresentAlert(_ alert: UIViewController, animated: Bool = true, completion: (() -> Void)? = nil) {
        guard view.window != nil else { return }
        var topController: UIViewController = self
        while let presented = topController.presentedViewController, !presented.isBeingDismissed {
            topController = presented
        }
        if topController.isBeingPresented {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.safePresentAlert(alert, animated: animated, completion: completion)
            }
            return
        }
        if topController is UIAlertController {
            return
        }
        topController.present(alert, animated: animated, completion: completion)
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

        safePresentAlert(alert)
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

        safePresentAlert(alert)
    }

    @objc func handleDownloadNotification(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if notification.name == NSNotification.Name("DownloadStartedNotification") {
                let filename = (notification.object as? String) ?? "文件"
                self.showDownloadProgressToast(filename: filename, progress: 0.05, detail: "0%", errorMessage: nil)
            } else if notification.name == NSNotification.Name("DownloadFinishedNotification") {
                let filename = (notification.object as? String) ?? "文件"
                self.showDownloadProgressToast(filename: filename, progress: 1.0, detail: "下载完成", errorMessage: nil)
            } else if notification.name == NSNotification.Name("DownloadFailedNotification") {
                let filename = (notification.object as? String) ?? "文件"
                let err = (notification.userInfo?["error"] as? String) ?? "未知错误"
                self.showDownloadProgressToast(filename: filename, progress: 1.0, detail: "下载失败", errorMessage: err)
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
