import UIKit

final class FaviconLoader {
    static let shared = FaviconLoader()
    private let cache = NSCache<NSString, UIImage>()
    private let diskCacheURL: URL = {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("FaviconDiskCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    private var inFlightMap: [String: [(UIImage?) -> Void]] = [:]
    private let mapLock = NSLock()

    private init() {
        cache.countLimit = 500
    }

    private func diskPath(for key: String) -> URL {
        let safeName = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "&", with: "_")
        return diskCacheURL.appendingPathComponent("\(safeName).png")
    }

    private func generateLookupKeys(from rawTarget: String) -> (primaryKey: String, candidateKeys: [String], targetInfo: TargetInfo) {
        let trimmed = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var scheme = "http"
        var host = trimmed
        var port: Int?
        var hostWithPort = trimmed

        if let url = URL(string: trimmed), let h = url.host {
            scheme = url.scheme?.lowercased() ?? "http"
            host = h.lowercased()
            port = url.port
            if let p = port {
                hostWithPort = "\(host):\(p)"
            } else {
                hostWithPort = host
            }
        } else if trimmed.contains(":") {
            let parts = trimmed.components(separatedBy: ":")
            if parts.count == 2, let p = Int(parts[1]) {
                host = parts[0]
                port = p
                hostWithPort = "\(host):\(p)"
            }
        }

        let origin: String
        if let p = port {
            origin = "\(scheme)://\(host):\(p)"
        } else {
            origin = "\(scheme)://\(host)"
        }

        let isPrivate = isPrivateHost(host)
        let root = isPrivate ? host : DomainRelationEngine.rootDomain(of: host)

        var keys: [String] = []

        func addKey(_ k: String) {
            let clean = k.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !clean.isEmpty && !keys.contains(clean) {
                keys.append(clean)
            }
        }

        addKey(hostWithPort)
        addKey(host)

        if host.hasPrefix("www.") {
            let noWww = String(host.dropFirst(4))
            if let p = port {
                addKey("\(noWww):\(p)")
            }
            addKey(noWww)
        } else if !isPrivate {
            let withWww = "www." + host
            if let p = port {
                addKey("\(withWww):\(p)")
            }
            addKey(withWww)
        }

        if !root.isEmpty && root != host {
            addKey(root)
        }

        let primary = hostWithPort.isEmpty ? host : hostWithPort
        let info = TargetInfo(
            scheme: scheme,
            host: host,
            port: port,
            hostWithPort: hostWithPort,
            origin: origin,
            isPrivate: isPrivate,
            rootDomain: root
        )

        return (primary, keys, info)
    }

    private func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") {
            return true
        }

        let parts = host.split(separator: ".")
        if parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]) {
            if first == 10 { return true }
            if first == 127 { return true }
            if first == 192 && second == 168 { return true }
            if first == 172 && (16...31).contains(second) { return true }
        }

        return false
    }

    func cachedFavicon(for target: String) -> UIImage? {
        let (_, candidateKeys, _) = generateLookupKeys(from: target)

        for key in candidateKeys {
            if let img = memoryOrDiskImage(for: key) {
                for fillKey in candidateKeys {
                    cache.setObject(img, forKey: fillKey as NSString)
                }
                return img
            }
        }

        return nil
    }

    private func memoryOrDiskImage(for key: String) -> UIImage? {
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        let fileURL = diskPath(for: key)
        if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
            cache.setObject(image, forKey: key as NSString)
            return image
        }
        return nil
    }

    func saveHighResIcon(data: Data, for target: String) {
        let (_, candidateKeys, _) = generateLookupKeys(from: target)
        guard let image = UIImage(data: data), image.size.width >= 12 else { return }

        for key in candidateKeys {
            cache.setObject(image, forKey: key as NSString)
            let fileURL = diskPath(for: key)
            try? data.write(to: fileURL)
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("FaviconUpdatedNotification"),
                object: nil
            )
        }
    }

    func preloadFavicon(for target: String) {
        loadFavicon(for: target) { _ in }
    }

    func loadFavicon(for target: String, completion: @escaping (UIImage?) -> Void) {
        let (primaryKey, candidateKeys, info) = generateLookupKeys(from: target)
        guard !primaryKey.isEmpty else {
            completion(nil)
            return
        }

        if let cached = cachedFavicon(for: target) {
            completion(cached)
            return
        }

        mapLock.lock()
        if inFlightMap[primaryKey] != nil {
            inFlightMap[primaryKey]?.append(completion)
            mapLock.unlock()
            return
        }
        inFlightMap[primaryKey] = [completion]
        mapLock.unlock()

        var candidateURLs: [String] = []

        candidateURLs.append("\(info.origin)/apple-touch-icon.png")
        candidateURLs.append("\(info.origin)/apple-touch-icon-precomposed.png")
        candidateURLs.append("\(info.origin)/img/apple-touch-icon.png")
        candidateURLs.append("\(info.origin)/img/favicon.png")
        candidateURLs.append("\(info.origin)/img/logo.png")
        candidateURLs.append("\(info.origin)/favicon.ico")
        candidateURLs.append("\(info.origin)/favicon.png")

        if !info.isPrivate {
            if info.scheme == "https" {
                candidateURLs.append("http://\(info.hostWithPort)/favicon.ico")
            } else {
                candidateURLs.append("https://\(info.hostWithPort)/favicon.ico")
            }

            candidateURLs.append("https://api.iowen.cn/favicon/\(info.host).png")
            candidateURLs.append("https://favicon.im/\(info.host)?larger=true")
            candidateURLs.append("https://www.google.com/s2/favicons?sz=128&domain=\(info.host)")

            if !info.rootDomain.isEmpty && info.rootDomain != info.host {
                candidateURLs.append("https://api.iowen.cn/favicon/\(info.rootDomain).png")
                candidateURLs.append("https://www.google.com/s2/favicons?sz=128&domain=\(info.rootDomain)")
            }
        }

        performConcurrentFetch(primaryKey: primaryKey, candidateKeys: candidateKeys, urls: candidateURLs)
    }

    private func performConcurrentFetch(primaryKey: String, candidateKeys: [String], urls: [String]) {
        var isFinished = false
        var bestImage: UIImage?
        var bestData: Data?
        let session = URLSession.shared
        let lock = NSLock()
        let group = DispatchGroup()

        func finish(with image: UIImage?, data: Data?) {
            lock.lock()
            if isFinished {
                lock.unlock()
                return
            }
            isFinished = true
            lock.unlock()

            if let data = data, image != nil {
                for key in candidateKeys {
                    self.cache.setObject(image!, forKey: key as NSString)
                    let fileURL = self.diskPath(for: key)
                    try? data.write(to: fileURL)
                }
            }

            self.mapLock.lock()
            let callbacks = self.inFlightMap.removeValue(forKey: primaryKey) ?? []
            self.mapLock.unlock()

            DispatchQueue.main.async {
                for cb in callbacks {
                    cb(image)
                }
                if image != nil {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("FaviconUpdatedNotification"),
                        object: nil
                    )
                }
            }
        }

        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            group.enter()

            var req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 4.0)
            req.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )

            session.dataTask(with: req) { data, response, _ in
                defer { group.leave() }

                lock.lock()
                if isFinished {
                    lock.unlock()
                    return
                }
                lock.unlock()

                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let data = data, data.count > 40,
                      let img = UIImage(data: data), img.size.width >= 12 else {
                    return
                }

                if img.size.width >= 32 {
                    finish(with: img, data: data)
                    return
                }

                lock.lock()
                if bestImage == nil {
                    bestImage = img
                    bestData = data
                }
                lock.unlock()
            }.resume()
        }

        group.notify(queue: .global()) {
            lock.lock()
            let finalImage = bestImage
            let finalData = bestData
            let done = isFinished
            lock.unlock()

            if !done {
                finish(with: finalImage, data: finalData)
            }
        }
    }
}

private struct TargetInfo {
    var scheme: String
    var host: String
    var port: Int?
    var hostWithPort: String
    var origin: String
    var isPrivate: Bool
    var rootDomain: String
}
