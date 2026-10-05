import UIKit
import WebKit

struct PersistedDownloadTask: Codable {
    let id: String
    let filename: String
    let urlString: String
    let targetFilename: String
    var writtenBytes: Int64
    var totalBytes: Int64
    var isFailed: Bool
    var errorMessage: String?
    var statusText: String?
}

struct ActiveDownloadItem {
    let id: String
    let filename: String
    var progress: Float
    var writtenBytes: Int64
    var totalBytes: Int64
    var isFailed: Bool
    var errorMessage: String?
    var statusText: String?
    var isRetrying: Bool
}

final class StreamDownloadTask: NSObject, URLSessionDataDelegate {
    let id: String
    let filename: String
    let originalURL: URL
    let targetURL: URL
    let tempURL: URL
    private(set) var writtenBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var retryCount: Int = 0
    private let maxInitialRetries: Int = 5
    private var hasReceivedAnyData: Bool = false
    private var fileHandle: FileHandle?
    private var dataTask: URLSessionDataTask?
    private var session: URLSession?
    private var isCancelled: Bool = false

    var onProgress: ((StreamDownloadTask) -> Void)?
    var onFinished: ((StreamDownloadTask, String) -> Void)?
    var onFailed: ((StreamDownloadTask, Error) -> Void)?

    init(id: String, filename: String, url: URL, targetURL: URL) {
        self.id = id
        self.filename = filename
        self.originalURL = url
        self.targetURL = targetURL
        let tempDir = DownloadCoordinator.getDownloadsDirectory()
        self.tempURL = tempDir.appendingPathComponent(".tmp_\(id).part")
        super.init()
    }

    func start() {
        guard !isCancelled else { return }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 86400.0
        config.waitsForConnectivity = false
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.httpMaximumConnectionsPerHost = 6

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: queue)

        resumeDownload()
    }

    private func resumeDownload() {
        guard !isCancelled, let session = session else { return }

        let fm = FileManager.default
        var existingSize: Int64 = 0
        if fm.fileExists(atPath: tempURL.path) {
            existingSize = Int64((try? fm.attributesOfItem(atPath: tempURL.path)[.size] as? UInt64) ?? 0)
        } else {
            fm.createFile(atPath: tempURL.path, contents: nil)
        }
        self.writtenBytes = existingSize

        var request = URLRequest(url: originalURL)
        request.timeoutInterval = 60.0
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh-Hans;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")

        if existingSize > 0 {
            request.setValue("bytes=\(existingSize)-", forHTTPHeaderField: "Range")
        }

        let task = session.dataTask(with: request)
        self.dataTask = task
        task.resume()
    }

    func cancel() {
        isCancelled = true
        dataTask?.cancel()
        dataTask = nil
        closeFile()
        session?.invalidateAndCancel()
        session = nil
        try? FileManager.default.removeItem(at: tempURL)
    }

    private func closeFile() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
    }

    func retryManually() {
        guard !isCancelled else { return }
        retryCount = 0
        dataTask?.cancel()
        closeFile()
        resumeDownload()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !isCancelled else {
            completionHandler(.cancel)
            return
        }

        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }

        let fm = FileManager.default

        if http.statusCode == 206 {
            if let handle = try? FileHandle(forWritingTo: tempURL) {
                _ = try? handle.seekToEnd()
                self.fileHandle = handle
            }
            if response.expectedContentLength > 0 {
                self.totalBytes = self.writtenBytes + response.expectedContentLength
            }
            completionHandler(.allow)
            return
        }

        if http.statusCode == 200 {
            closeFile()
            try? fm.removeItem(at: tempURL)
            fm.createFile(atPath: tempURL.path, contents: nil)
            self.writtenBytes = 0
            if response.expectedContentLength > 0 {
                self.totalBytes = response.expectedContentLength
            }
            self.fileHandle = try? FileHandle(forWritingTo: tempURL)
            completionHandler(.allow)
            return
        }

        if http.statusCode == 416 {
            if self.totalBytes > 0 && self.writtenBytes >= self.totalBytes {
                completionHandler(.cancel)
                finishSuccess()
                return
            }
            closeFile()
            try? fm.removeItem(at: tempURL)
            fm.createFile(atPath: tempURL.path, contents: nil)
            self.writtenBytes = 0
            self.fileHandle = try? FileHandle(forWritingTo: tempURL)
            completionHandler(.allow)
            return
        }

        completionHandler(.cancel)
        let err = NSError(domain: "HTTPError", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP状态码 \(http.statusCode)"])
        handleFailure(error: err)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isCancelled, let handle = fileHandle else { return }
        do {
            try handle.write(contentsOf: data)
            writtenBytes += Int64(data.count)
            hasReceivedAnyData = true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onProgress?(self)
            }
        } catch {
            handleFailure(error: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isCancelled else { return }
        closeFile()

        if let error = error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                return
            }
            handleFailure(error: error)
            return
        }

        let fm = FileManager.default
        let currentSize = Int64((try? fm.attributesOfItem(atPath: tempURL.path)[.size] as? UInt64) ?? 0)

        if totalBytes > 0 && currentSize < totalBytes {
            let truncatedError = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNetworkConnectionLost,
                userInfo: [NSLocalizedDescriptionKey: "连接中断，文件不完整"]
            )
            handleFailure(error: truncatedError)
            return
        }

        finishSuccess()
    }

    private func finishSuccess() {
        closeFile()
        let fm = FileManager.default
        do {
            let destDir = targetURL.deletingLastPathComponent()
            let finalURL = DownloadCoordinator.uniqueDestinationURL(for: targetURL.lastPathComponent, in: destDir)
            try fm.moveItem(at: tempURL, to: finalURL)
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: finalURL.path)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onFinished?(self, finalURL.lastPathComponent)
            }
        } catch {
            handleFailure(error: error)
        }
    }

    private func handleFailure(error: Error) {
        guard !isCancelled else { return }
        closeFile()

        let canRetry = hasReceivedAnyData ? true : (retryCount < maxInitialRetries)

        if canRetry {
            retryCount += 1
            let retryMsg = hasReceivedAnyData ? "网络波动，正在重试 (\(retryCount))" : "连接失败，正在重试 \(retryCount)/\(maxInitialRetries)"
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                NotificationCenter.default.post(
                    name: NSNotification.Name("DownloadProgressNotification"),
                    object: self.filename,
                    userInfo: [
                        "taskId": self.id,
                        "progress": self.totalBytes > 0 ? Float(self.writtenBytes) / Float(self.totalBytes) : 0,
                        "written": self.writtenBytes,
                        "total": self.totalBytes,
                        "statusText": retryMsg,
                        "isRetrying": true
                    ]
                )
            }
            let delay: Double = min(Double(retryCount) * 1.5, 4.0)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.resumeDownload()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onFailed?(self, error)
            }
        }
    }
}

final class DownloadCoordinator: NSObject, WKDownloadDelegate {
    static let shared = DownloadCoordinator()

    private var activeStreamTasks: [String: StreamDownloadTask] = [:]
    private var wkDownloads: [ObjectIdentifier: String] = [:]
    private var wkDownloadInstances: [String: WKDownload] = [:]
    private var progressObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var cancelledTaskIDs: Set<String> = []
    private var persistedTasks: [String: PersistedDownloadTask] = [:]
    private var lastPersistTime: [String: TimeInterval] = [:]

    private(set) var activeTasks: [String: ActiveDownloadItem] = [:]

    private override init() {
        super.init()
        loadPersistedTasks()
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

    static func uniqueDestinationURL(for filename: String, in directory: URL) -> URL {
        let fm = FileManager.default
        let raw = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseFilename = raw.isEmpty ? "download_\(Int(Date().timeIntervalSince1970))" : raw
        var targetURL = directory.appendingPathComponent(baseFilename)
        var counter = 1
        let nameWithoutExt = (baseFilename as NSString).deletingPathExtension
        let ext = (baseFilename as NSString).pathExtension

        while fm.fileExists(atPath: targetURL.path) {
            let newName = ext.isEmpty ? "\(nameWithoutExt)_\(counter)" : "\(nameWithoutExt)_\(counter).\(ext)"
            targetURL = directory.appendingPathComponent(newName)
            counter += 1
        }
        return targetURL
    }

    private func savePersistedTasks() {
        let list = Array(persistedTasks.values)
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: "saved_download_tasks_v2")
    }

    private func updatePersistedProgress(id: String, written: Int64, total: Int64) {
        guard var task = persistedTasks[id] else { return }
        task.writtenBytes = written
        task.totalBytes = total
        task.isFailed = false
        task.errorMessage = nil
        task.statusText = nil
        persistedTasks[id] = task

        let now = Date().timeIntervalSince1970
        if now - (lastPersistTime[id] ?? 0) > 1.5 {
            lastPersistTime[id] = now
            savePersistedTasks()
        }
    }

    private func markPersistedFailed(id: String, error: String) {
        if var task = persistedTasks[id] {
            task.isFailed = true
            task.errorMessage = error
            task.statusText = "下载失败"
            persistedTasks[id] = task
            savePersistedTasks()
        }
    }

    func removePersistedTask(id: String) {
        persistedTasks.removeValue(forKey: id)
        lastPersistTime.removeValue(forKey: id)
        savePersistedTasks()
    }

    private func loadPersistedTasks() {
        guard let data = UserDefaults.standard.data(forKey: "saved_download_tasks_v2"),
              let list = try? JSONDecoder().decode([PersistedDownloadTask].self, from: data) else {
            return
        }
        let destDir = Self.getDownloadsDirectory()
        let fm = FileManager.default

        for item in list {
            guard let url = URL(string: item.urlString) else { continue }
            let tempURL = destDir.appendingPathComponent(".tmp_\(item.id).part")
            var currentWritten = item.writtenBytes
            if fm.fileExists(atPath: tempURL.path) {
                let actualSize = Int64((try? fm.attributesOfItem(atPath: tempURL.path)[.size] as? UInt64) ?? 0)
                if actualSize > 0 {
                    currentWritten = actualSize
                }
            }
            let targetURL = destDir.appendingPathComponent(item.targetFilename)
            persistedTasks[item.id] = PersistedDownloadTask(
                id: item.id,
                filename: item.filename,
                urlString: item.urlString,
                targetFilename: item.targetFilename,
                writtenBytes: currentWritten,
                totalBytes: item.totalBytes,
                isFailed: item.isFailed,
                errorMessage: item.errorMessage,
                statusText: item.statusText
            )

            let progress = item.totalBytes > 0 ? Float(currentWritten) / Float(item.totalBytes) : 0
            activeTasks[item.id] = ActiveDownloadItem(
                id: item.id,
                filename: item.filename,
                progress: progress,
                writtenBytes: currentWritten,
                totalBytes: item.totalBytes,
                isFailed: item.isFailed,
                errorMessage: item.errorMessage,
                statusText: item.statusText ?? (item.isFailed ? "下载失败" : "正在恢复下载"),
                isRetrying: !item.isFailed
            )

            let streamTask = StreamDownloadTask(id: item.id, filename: item.filename, url: url, targetURL: targetURL)
            activeStreamTasks[item.id] = streamTask
            attachCallbacks(to: streamTask)
            if !item.isFailed {
                streamTask.start()
            }
        }
    }

    private func attachCallbacks(to streamTask: StreamDownloadTask) {
        streamTask.onProgress = { [weak self] t in
            guard let self = self else { return }
            let p = t.totalBytes > 0 ? Float(t.writtenBytes) / Float(t.totalBytes) : 0
            self.activeTasks[t.id] = ActiveDownloadItem(
                id: t.id,
                filename: t.filename,
                progress: p,
                writtenBytes: t.writtenBytes,
                totalBytes: t.totalBytes,
                isFailed: false,
                errorMessage: nil,
                statusText: nil,
                isRetrying: false
            )
            self.updatePersistedProgress(id: t.id, written: t.writtenBytes, total: t.totalBytes)
            NotificationCenter.default.post(
                name: NSNotification.Name("DownloadProgressNotification"),
                object: t.filename,
                userInfo: [
                    "taskId": t.id,
                    "progress": p,
                    "written": t.writtenBytes,
                    "total": t.totalBytes
                ]
            )
        }

        streamTask.onFinished = { [weak self] t, finalName in
            guard let self = self else { return }
            self.activeStreamTasks.removeValue(forKey: t.id)
            self.activeTasks.removeValue(forKey: t.id)
            self.removePersistedTask(id: t.id)
            NotificationCenter.default.post(
                name: NSNotification.Name("DownloadFinishedNotification"),
                object: finalName,
                userInfo: ["taskId": t.id]
            )
        }

        streamTask.onFailed = { [weak self] t, err in
            guard let self = self else { return }
            self.activeTasks[t.id] = ActiveDownloadItem(
                id: t.id,
                filename: t.filename,
                progress: t.totalBytes > 0 ? Float(t.writtenBytes) / Float(t.totalBytes) : 0,
                writtenBytes: t.writtenBytes,
                totalBytes: t.totalBytes,
                isFailed: true,
                errorMessage: err.localizedDescription,
                statusText: "下载失败",
                isRetrying: false
            )
            self.markPersistedFailed(id: t.id, error: err.localizedDescription)
            NotificationCenter.default.post(
                name: NSNotification.Name("DownloadFailedNotification"),
                object: t.filename,
                userInfo: ["taskId": t.id, "error": err.localizedDescription]
            )
        }
    }

    func startDownload(url: URL, filename: String) {
        let destDir = Self.getDownloadsDirectory()
        let rawName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = "download_\(Int(Date().timeIntervalSince1970))"
        let baseFilename = rawName.isEmpty ? fallbackName : rawName

        let targetURL = Self.uniqueDestinationURL(for: baseFilename, in: destDir)
        let uniqueName = targetURL.lastPathComponent

        let taskID = UUID().uuidString
        let streamTask = StreamDownloadTask(id: taskID, filename: uniqueName, url: url, targetURL: targetURL)
        activeStreamTasks[taskID] = streamTask

        activeTasks[taskID] = ActiveDownloadItem(
            id: taskID,
            filename: uniqueName,
            progress: 0.01,
            writtenBytes: 0,
            totalBytes: 0,
            isFailed: false,
            errorMessage: nil,
            statusText: nil,
            isRetrying: false
        )

        persistedTasks[taskID] = PersistedDownloadTask(
            id: taskID,
            filename: uniqueName,
            urlString: url.absoluteString,
            targetFilename: uniqueName,
            writtenBytes: 0,
            totalBytes: 0,
            isFailed: false,
            errorMessage: nil,
            statusText: nil
        )
        savePersistedTasks()

        attachCallbacks(to: streamTask)
        streamTask.start()

        NotificationCenter.default.post(
            name: NSNotification.Name("DownloadStartedNotification"),
            object: uniqueName,
            userInfo: ["taskId": taskID]
        )
    }

    func removeActiveTask(id: String) {
        cancelledTaskIDs.insert(id)

        if let streamTask = activeStreamTasks.removeValue(forKey: id) {
            streamTask.cancel()
        }

        if let download = wkDownloadInstances.removeValue(forKey: id) {
            download.cancel { _ in }
            let downloadID = ObjectIdentifier(download)
            wkDownloads.removeValue(forKey: downloadID)
            progressObservations[downloadID]?.invalidate()
            progressObservations.removeValue(forKey: downloadID)
        }

        activeTasks.removeValue(forKey: id)
        removePersistedTask(id: id)

        let destDir = Self.getDownloadsDirectory()
        let tempURL = destDir.appendingPathComponent(".tmp_\(id).part")
        try? FileManager.default.removeItem(at: tempURL)

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("ActiveDownloadTasksChangedNotification"), object: nil)
        }
    }

    func manualRetry(taskId: String) {
        cancelledTaskIDs.remove(taskId)
        if let streamTask = activeStreamTasks[taskId] {
            activeTasks[taskId] = ActiveDownloadItem(
                id: taskId,
                filename: streamTask.filename,
                progress: streamTask.totalBytes > 0 ? Float(streamTask.writtenBytes) / Float(streamTask.totalBytes) : 0,
                writtenBytes: streamTask.writtenBytes,
                totalBytes: streamTask.totalBytes,
                isFailed: false,
                errorMessage: nil,
                statusText: "正在重新连接",
                isRetrying: true
            )
            if var task = persistedTasks[taskId] {
                task.isFailed = false
                task.errorMessage = nil
                task.statusText = "正在重新连接"
                persistedTasks[taskId] = task
                savePersistedTasks()
            }
            NotificationCenter.default.post(
                name: NSNotification.Name("DownloadProgressNotification"),
                object: streamTask.filename,
                userInfo: [
                    "taskId": taskId,
                    "progress": streamTask.totalBytes > 0 ? Float(streamTask.writtenBytes) / Float(streamTask.totalBytes) : 0,
                    "written": streamTask.writtenBytes,
                    "total": streamTask.totalBytes,
                    "statusText": "正在重新连接"
                ]
            )
            streamTask.retryManually()
        } else if let pTask = persistedTasks[taskId], let url = URL(string: pTask.urlString) {
            let destDir = Self.getDownloadsDirectory()
            let targetURL = destDir.appendingPathComponent(pTask.targetFilename)
            let streamTask = StreamDownloadTask(id: taskId, filename: pTask.filename, url: url, targetURL: targetURL)
            activeStreamTasks[taskId] = streamTask
            attachCallbacks(to: streamTask)
            activeTasks[taskId] = ActiveDownloadItem(
                id: taskId,
                filename: pTask.filename,
                progress: pTask.totalBytes > 0 ? Float(pTask.writtenBytes) / Float(pTask.totalBytes) : 0,
                writtenBytes: pTask.writtenBytes,
                totalBytes: pTask.totalBytes,
                isFailed: false,
                errorMessage: nil,
                statusText: "正在重新连接",
                isRetrying: true
            )
            if var task = persistedTasks[taskId] {
                task.isFailed = false
                task.errorMessage = nil
                task.statusText = "正在重新连接"
                persistedTasks[taskId] = task
                savePersistedTasks()
            }
            streamTask.start()
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
                            let targetURL = Self.uniqueDestinationURL(for: filename, in: destDir)

                            let taskID = UUID().uuidString
                            self.wkDownloads[downloadID] = taskID
                            self.wkDownloadInstances[taskID] = download

                            self.activeTasks[taskID] = ActiveDownloadItem(
                                id: taskID,
                                filename: targetURL.lastPathComponent,
                                progress: 0.01,
                                writtenBytes: 0,
                                totalBytes: response.expectedContentLength > 0 ? response.expectedContentLength : 0,
                                isFailed: false,
                                errorMessage: nil,
                                statusText: nil,
                                isRetrying: false
                            )

                            let obs = download.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                                guard let self = self else { return }
                                let currentProgress = Float(p.fractionCompleted)
                                let written = p.completedUnitCount
                                let total = p.totalUnitCount
                                DispatchQueue.main.async {
                                    self.activeTasks[taskID] = ActiveDownloadItem(
                                        id: taskID,
                                        filename: targetURL.lastPathComponent,
                                        progress: currentProgress,
                                        writtenBytes: written,
                                        totalBytes: total,
                                        isFailed: false,
                                        errorMessage: nil,
                                        statusText: nil,
                                        isRetrying: false
                                    )
                                    NotificationCenter.default.post(
                                        name: NSNotification.Name("DownloadProgressNotification"),
                                        object: targetURL.lastPathComponent,
                                        userInfo: [
                                            "taskId": taskID,
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
                                object: targetURL.lastPathComponent,
                                userInfo: ["taskId": taskID]
                            )
                            safeCompletion(targetURL)
                        } else {
                            safeCompletion(nil)
                        }
                    } as (Bool) -> Void
                ]
            )
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let downloadID = ObjectIdentifier(download)
        guard let taskID = wkDownloads.removeValue(forKey: downloadID) else { return }
        progressObservations[downloadID]?.invalidate()
        progressObservations.removeValue(forKey: downloadID)
        wkDownloadInstances.removeValue(forKey: taskID)
        let item = activeTasks.removeValue(forKey: taskID)

        NotificationCenter.default.post(
            name: NSNotification.Name("DownloadFinishedNotification"),
            object: item?.filename ?? nil,
            userInfo: ["taskId": taskID]
        )
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let downloadID = ObjectIdentifier(download)
        guard let taskID = wkDownloads.removeValue(forKey: downloadID) else { return }
        progressObservations[downloadID]?.invalidate()
        progressObservations.removeValue(forKey: downloadID)
        wkDownloadInstances.removeValue(forKey: taskID)

        if cancelledTaskIDs.contains(taskID) {
            activeTasks.removeValue(forKey: taskID)
            return
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            activeTasks.removeValue(forKey: taskID)
            return
        }
        if nsError.domain == "WebKitErrorDomain" && (nsError.code == 1 || nsError.code == 102) {
            activeTasks.removeValue(forKey: taskID)
            return
        }

        let fname = activeTasks[taskID]?.filename ?? "文件"
        activeTasks[taskID] = ActiveDownloadItem(
            id: taskID,
            filename: fname,
            progress: activeTasks[taskID]?.progress ?? 0,
            writtenBytes: activeTasks[taskID]?.writtenBytes ?? 0,
            totalBytes: activeTasks[taskID]?.totalBytes ?? 0,
            isFailed: true,
            errorMessage: error.localizedDescription,
            statusText: "下载失败",
            isRetrying: false
        )

        NotificationCenter.default.post(
            name: NSNotification.Name("DownloadFailedNotification"),
            object: fname,
            userInfo: ["taskId": taskID, "error": error.localizedDescription]
        )
    }
}

final class DownloadProgressCell: UITableViewCell {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let errorLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let removeButton = UIButton(type: .system)

    var taskID: String = ""
    var onRemove: (() -> Void)?
    var onRetry: (() -> Void)?

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

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setImage(UIImage(systemName: "arrow.clockwise.circle.fill"), for: .normal)
        retryButton.tintColor = .systemBlue
        retryButton.addTarget(self, action: #selector(handleRetry), for: .touchUpInside)
        retryButton.isHidden = true

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        removeButton.tintColor = .systemGray3
        removeButton.addTarget(self, action: #selector(handleRemove), for: .touchUpInside)

        let actionStack = UIStackView(arrangedSubviews: [retryButton, removeButton])
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.axis = .horizontal
        actionStack.spacing = 8
        actionStack.alignment = .center

        let topRow = UIStackView(arrangedSubviews: [titleLabel, detailLabel, actionStack])
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
            retryButton.widthAnchor.constraint(equalToConstant: 24),
            retryButton.heightAnchor.constraint(equalToConstant: 24),
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

    @objc private func handleRetry() {
        onRetry?()
    }

    func configure(with item: ActiveDownloadItem) {
        self.taskID = item.id
        titleLabel.text = item.filename
        if item.isFailed {
            progressView.progressTintColor = .systemRed
            progressView.progress = 1.0
            detailLabel.text = "下载失败"
            detailLabel.textColor = .systemRed
            let reason = item.errorMessage ?? "网络连接断开"
            errorLabel.text = "失败原因: \(reason)"
            errorLabel.isHidden = false
            retryButton.isHidden = false
        } else if item.isRetrying {
            progressView.progressTintColor = .systemOrange
            progressView.progress = item.progress
            detailLabel.text = item.statusText ?? "正在重试"
            detailLabel.textColor = .systemOrange
            errorLabel.isHidden = true
            retryButton.isHidden = true
        } else {
            progressView.progressTintColor = .systemBlue
            progressView.progress = item.progress
            detailLabel.textColor = .secondaryLabel
            errorLabel.isHidden = true
            retryButton.isHidden = true

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

        NotificationCenter.default.addObserver(self, selector: #selector(handleProgressChanged(_:)), name: NSNotification.Name("DownloadProgressNotification"), object: nil)
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

    @objc private func handleProgressChanged(_ notification: Notification) {
        guard let taskID = notification.userInfo?["taskId"] as? String,
              let task = DownloadCoordinator.shared.activeTasks[taskID] else {
            return
        }
        for cell in tableView.visibleCells {
            if let progressCell = cell as? DownloadProgressCell, progressCell.taskID == taskID {
                progressCell.configure(with: task)
            }
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
            cell.onRetry = {
                DownloadCoordinator.shared.manualRetry(taskId: task.id)
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
        showFileActionMenu(for: item, sourceView: cell)
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

    private func showFileActionMenu(for file: DownloadedItem, sourceView: UIView) {
        let sheet = UIAlertController(title: file.name, message: nil, preferredStyle: .actionSheet)
        let ext = file.url.pathExtension.lowercased()
        let isArchive = (ext == "zip" || ext == "gz")

        if isArchive {
            sheet.addAction(UIAlertAction(title: "解压", style: .default) { [weak self] _ in
                self?.unzipArchiveFile(file)
            })
        }

        sheet.addAction(UIAlertAction(title: "分享", style: .default) { [weak self] _ in
            self?.shareFile(file, sourceView: sourceView)
        })

        if !file.isDirectory {
            sheet.addAction(UIAlertAction(title: "文件预览", style: .default) { [weak self] _ in
                self?.previewFile(file)
            })
        }

        sheet.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.deleteFile(file)
        })

        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = sheet.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
            popover.permittedArrowDirections = [.up, .down]
        }

        present(sheet, animated: true)
    }

    private func unzipArchiveFile(_ file: DownloadedItem) {
        let rawBase = (file.name as NSString).deletingPathExtension
        var destDir = currentDirectory.appendingPathComponent(rawBase, isDirectory: true)
        let fm = FileManager.default
        var counter = 1
        while fm.fileExists(atPath: destDir.path) {
            destDir = currentDirectory.appendingPathComponent("\(rawBase)_\(counter)", isDirectory: true)
            counter += 1
        }
        do {
            try ZipExtractor.unzip(archiveURL: file.url, destinationURL: destDir)
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: destDir.path)
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