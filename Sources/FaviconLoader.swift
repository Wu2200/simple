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
        cache.countLimit = 300
    }

    private func diskPath(for cleanDomain: String) -> URL {
        let safeName = cleanDomain.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return diskCacheURL.appendingPathComponent("\(safeName).png")
    }

    func cachedFavicon(for domain: String) -> UIImage? {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return nil }

        if let img = memoryOrDiskImage(for: clean) {
            return img
        }

        if clean.hasPrefix("www.") {
            let noWww = String(clean.dropFirst(4))
            if let img = memoryOrDiskImage(for: noWww) {
                cache.setObject(img, forKey: clean as NSString)
                return img
            }
        } else {
            let withWww = "www." + clean
            if let img = memoryOrDiskImage(for: withWww) {
                cache.setObject(img, forKey: clean as NSString)
                return img
            }
        }

        let root = DomainRelationEngine.rootDomain(of: clean)
        if root != clean && !root.isEmpty, let img = memoryOrDiskImage(for: root) {
            cache.setObject(img, forKey: clean as NSString)
            return img
        }

        return nil
    }

    private func memoryOrDiskImage(for domainKey: String) -> UIImage? {
        if let cached = cache.object(forKey: domainKey as NSString) {
            return cached
        }
        let fileURL = diskPath(for: domainKey)
        if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
            cache.setObject(image, forKey: domainKey as NSString)
            return image
        }
        return nil
    }

    func saveHighResIcon(data: Data, for domain: String) {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty, let image = UIImage(data: data) else { return }

        var domainsToSave: Set<String> = [clean]
        let root = DomainRelationEngine.rootDomain(of: clean)
        if !root.isEmpty { domainsToSave.insert(root) }
        if clean.hasPrefix("www.") {
            domainsToSave.insert(String(clean.dropFirst(4)))
        } else {
            domainsToSave.insert("www." + clean)
        }

        for d in domainsToSave {
            cache.setObject(image, forKey: d as NSString)
            let fileURL = diskPath(for: d)
            try? data.write(to: fileURL)
        }
    }

    func preloadFavicon(for domain: String) {
        loadFavicon(for: domain) { _ in }
    }

    func loadFavicon(for domain: String, completion: @escaping (UIImage?) -> Void) {
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanDomain.isEmpty else {
            completion(nil)
            return
        }

        if let cached = cachedFavicon(for: cleanDomain) {
            completion(cached)
            return
        }

        mapLock.lock()
        if inFlightMap[cleanDomain] != nil {
            inFlightMap[cleanDomain]?.append(completion)
            mapLock.unlock()
            return
        }
        inFlightMap[cleanDomain] = [completion]
        mapLock.unlock()

        let root = DomainRelationEngine.rootDomain(of: cleanDomain)

        var candidateURLs: [String] = []
        candidateURLs.append("https://\(cleanDomain)/apple-touch-icon.png")
        candidateURLs.append("https://\(cleanDomain)/favicon.ico")
        if root != cleanDomain && !root.isEmpty {
            candidateURLs.append("https://\(root)/apple-touch-icon.png")
            candidateURLs.append("https://\(root)/favicon.ico")
        }
        candidateURLs.append("https://api.iowen.cn/favicon/\(cleanDomain).png")
        candidateURLs.append("https://favicon.im/\(cleanDomain)?larger=true")
        if root != cleanDomain && !root.isEmpty {
            candidateURLs.append("https://api.iowen.cn/favicon/\(root).png")
        }
        candidateURLs.append("https://www.google.com/s2/favicons?sz=128&domain=\(cleanDomain)")

        performConcurrentFetch(cleanDomain: cleanDomain, urls: candidateURLs)
    }

    private func performConcurrentFetch(cleanDomain: String, urls: [String]) {
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
                self.saveHighResIcon(data: data, for: cleanDomain)
            }

            self.mapLock.lock()
            let callbacks = self.inFlightMap.removeValue(forKey: cleanDomain) ?? []
            self.mapLock.unlock()

            DispatchQueue.main.async {
                for cb in callbacks {
                    cb(image)
                }
            }
        }

        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            group.enter()

            var req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 3.2)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

            session.dataTask(with: req) { data, response, _ in
                defer { group.leave() }

                lock.lock()
                if isFinished {
                    lock.unlock()
                    return
                }
                lock.unlock()

                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let data = data, data.count > 100,
                      let img = UIImage(data: data), img.size.width >= 16 else {
                    return
                }

                if img.size.width >= 48 {
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
