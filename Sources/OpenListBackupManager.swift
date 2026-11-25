import Foundation
import UIKit
import Network
import Security
import BackgroundTasks

enum OpenListUploadProtocolMode: Equatable {
    case openListAPI
    case webDAV
}

struct OpenListBackupConfig: Codable, Equatable {
    var isEnabled: Bool
    var serverURL: String
    var username: String
    var remoteDirectory: String
    var intervalHours: Int
    var lastSuccessDate: Date?
    var lastAttemptDate: Date?
    var lastErrorMessage: String?
    var lastUploadedFileName: String?

    static let defaultIntervalHours = 24
    static let defaultRemoteDirectory = "/SimpleBrowserBackups"

    static func defaultConfig() -> OpenListBackupConfig {
        OpenListBackupConfig(
            isEnabled: false,
            serverURL: "",
            username: "",
            remoteDirectory: defaultRemoteDirectory,
            intervalHours: defaultIntervalHours,
            lastSuccessDate: nil,
            lastAttemptDate: nil,
            lastErrorMessage: nil,
            lastUploadedFileName: nil
        )
    }

    init(
        isEnabled: Bool,
        serverURL: String,
        username: String,
        remoteDirectory: String,
        intervalHours: Int,
        lastSuccessDate: Date? = nil,
        lastAttemptDate: Date? = nil,
        lastErrorMessage: String? = nil,
        lastUploadedFileName: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.serverURL = serverURL
        self.username = username
        self.remoteDirectory = remoteDirectory
        self.intervalHours = min(max(intervalHours, 1), 8760)
        self.lastSuccessDate = lastSuccessDate
        self.lastAttemptDate = lastAttemptDate
        self.lastErrorMessage = lastErrorMessage
        self.lastUploadedFileName = lastUploadedFileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
        self.username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.remoteDirectory = try container.decodeIfPresent(String.self, forKey: .remoteDirectory) ?? Self.defaultRemoteDirectory
        let decodedInterval = try container.decodeIfPresent(Int.self, forKey: .intervalHours) ?? Self.defaultIntervalHours
        self.intervalHours = min(max(decodedInterval, 1), 8760)
        self.lastSuccessDate = try container.decodeIfPresent(Date.self, forKey: .lastSuccessDate)
        self.lastAttemptDate = try container.decodeIfPresent(Date.self, forKey: .lastAttemptDate)
        self.lastErrorMessage = try container.decodeIfPresent(String.self, forKey: .lastErrorMessage)
        self.lastUploadedFileName = try container.decodeIfPresent(String.self, forKey: .lastUploadedFileName)
    }
}

struct AutoBackupStatusSnapshot: Equatable {
    let config: OpenListBackupConfig
    let isUploading: Bool
    let nextScheduledDate: Date?
    let pendingRetryDate: Date?
    let retryAttemptCount: Int
    let isWaitingForRetry: Bool
}

protocol BackupCredentialStoring: AnyObject {
    func saveSecret(_ value: String, forAccount account: String)
    func loadSecret(forAccount account: String) -> String
}

final class KeychainCredentialStore: BackupCredentialStoring {
    private let service: String
    private let lock = NSLock()
    private var memoryCache: [String: String] = [:]

    init(service: String = (Bundle.main.bundleIdentifier ?? "com.example.SimpleBrowser") + ".OpenListBackup") {
        self.service = service
    }

    func saveSecret(_ value: String, forAccount account: String) {
        lock.lock()
        defer { lock.unlock() }

        if value.isEmpty {
            memoryCache.removeValue(forKey: account)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
            return
        }

        memoryCache[account] = value
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let existingStatus = SecItemCopyMatching(query as CFDictionary, nil)
        if existingStatus == errSecSuccess {
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        } else {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    func loadSecret(forAccount account: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) {
            memoryCache[account] = value
            return value
        }

        return memoryCache[account] ?? ""
    }
}

final class InMemoryCredentialStore: BackupCredentialStoring {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func saveSecret(_ value: String, forAccount account: String) {
        lock.lock()
        defer { lock.unlock() }
        if value.isEmpty {
            storage.removeValue(forKey: account)
        } else {
            storage[account] = value
        }
    }

    func loadSecret(forAccount account: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage[account] ?? ""
    }
}

enum OpenListClientError: LocalizedError, Equatable {
    case invalidServerURL
    case missingCredentials
    case invalidResponse
    case twoFactorRequired
    case authenticationFailed(statusCode: Int, message: String)
    case httpError(statusCode: Int, message: String)
    case apiError(code: Int, message: String)
    case targetPathIsNotDirectory

    var isAuthenticationOrPermissionError: Bool {
        switch self {
        case .twoFactorRequired, .missingCredentials, .authenticationFailed:
            return true
        case .httpError(let code, _):
            return code == 401 || code == 403
        case .apiError(let code, _):
            return code == 401 || code == 402 || code == 403
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "OpenList 服务器地址无效"
        case .missingCredentials:
            return "请填写 OpenList 登录用户名和密码，或直接填写 API Token"
        case .invalidResponse:
            return "OpenList 服务器返回了无法解析的响应"
        case .twoFactorRequired:
            return "账号已开启两步验证，请将用户名留空并在密码栏填入 API Token"
        case .authenticationFailed(_, let message):
            return message.isEmpty ? "OpenList 认证失败" : message
        case .httpError(let statusCode, let message):
            return message.isEmpty ? "服务器返回 HTTP \(statusCode)" : "服务器返回 HTTP \(statusCode): \(message)"
        case .apiError(let code, let message):
            return message.isEmpty ? "OpenList 返回错误码 \(code)" : message
        case .targetPathIsNotDirectory:
            return "指定的远程路径不是文件夹"
        }
    }
}

private final class OpenListTrustSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            let host = challenge.protectionSpace.host.lowercased()
            if CertificateTrustStore.shared.isHostTrusted(host) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

final class OpenListClient {
    private static let trustDelegate = OpenListTrustSessionDelegate()
    private let session: URLSession
    private let tokenLock = NSLock()
    private var cachedTokens: [String: String] = [:]

    private static let pathHeaderAllowedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
    )

    init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.waitsForConnectivity = false
            configuration.allowsCellularAccess = true
            configuration.allowsExpensiveNetworkAccess = true
            configuration.allowsConstrainedNetworkAccess = true
            self.session = URLSession(configuration: configuration, delegate: Self.trustDelegate, delegateQueue: nil)
        }
    }

    static func normalizeServerURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !trimmed.contains("://") {
            let lower = trimmed.lowercased()
            let hostPart = lower.components(separatedBy: "/").first?.components(separatedBy: ":").first ?? ""
            let isLocalOrIP = isIPv4Host(hostPart) ||
                hostPart == "localhost" ||
                hostPart.hasSuffix(".local") ||
                hostPart == "::1" ||
                hostPart == "[::1]" ||
                lower.contains(":")
            trimmed = (isLocalOrIP ? "http://" : "https://") + trimmed
        }

        while trimmed.hasSuffix("/") && trimmed.count > "https://".count {
            trimmed.removeLast()
        }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        return components.url
    }

    private static func isIPv4Host(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let value = Int(part), value >= 0, value <= 255 else { return false }
        }
        return true
    }

    static func detectProtocolMode(for serverURL: URL) -> OpenListUploadProtocolMode {
        let path = serverURL.path.lowercased()
        if path == "/dav" || path.hasSuffix("/dav") || path.contains("/dav/") {
            return .webDAV
        }
        return .openListAPI
    }

    static func normalizeRemoteDirectory(_ raw: String) -> String {
        let replaced = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        let components = replaced.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        if components.isEmpty {
            return "/"
        }
        return "/" + components.joined(separator: "/")
    }

    static func fullRemoteFilePath(directory: String, fileName: String) -> String {
        let normalizedDir = normalizeRemoteDirectory(directory)
        let cleanFileName = (fileName as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedDir == "/" {
            return "/\(cleanFileName)"
        }
        return "\(normalizedDir)/\(cleanFileName)"
    }

    static func encodeOpenListPathHeader(_ path: String) -> String {
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        return normalized.addingPercentEncoding(withAllowedCharacters: pathHeaderAllowedCharacters) ?? normalized
    }

    private func endpointURL(base: URL, components pathComponents: [String]) -> URL {
        var result = base
        for component in pathComponents {
            result.appendPathComponent(component)
        }
        return result
    }

    private func tokenCacheKey(baseURL: URL, username: String, passwordOrToken: String) -> String {
        "\(baseURL.absoluteString)|\(username)|\(passwordOrToken.hashValue)"
    }

    func clearCachedToken(baseURL: URL, username: String, passwordOrToken: String) {
        let key = tokenCacheKey(baseURL: baseURL, username: username, passwordOrToken: passwordOrToken)
        tokenLock.lock()
        cachedTokens.removeValue(forKey: key)
        tokenLock.unlock()
    }

    func testConnection(
        serverURLString: String,
        username: String,
        passwordOrToken: String,
        remoteDirectory: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let baseURL = Self.normalizeServerURL(serverURLString) else {
            completion(.failure(OpenListClientError.invalidServerURL))
            return
        }

        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSecret = passwordOrToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDir = Self.normalizeRemoteDirectory(remoteDirectory)

        if Self.detectProtocolMode(for: baseURL) == .webDAV {
            testWebDAVConnection(
                baseURL: baseURL,
                username: cleanUsername,
                secret: cleanSecret,
                remoteDirectory: normalizedDir,
                completion: completion
            )
            return
        }

        guard !cleanSecret.isEmpty else {
            completion(.failure(OpenListClientError.missingCredentials))
            return
        }

        authenticateOpenListAPI(
            baseURL: baseURL,
            username: cleanUsername,
            secret: cleanSecret,
            forceRefresh: true
        ) { [weak self] authResult in
            guard let self = self else { return }
            switch authResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let token):
                self.verifyCurrentUser(baseURL: baseURL, token: token) { userResult in
                    switch userResult {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let resolvedUsername):
                        self.checkOpenListDirectory(baseURL: baseURL, token: token, path: normalizedDir) { dirResult in
                            switch dirResult {
                            case .success(let exists):
                                if exists {
                                    completion(.success("连接成功，当前账号 \(resolvedUsername)，目标目录已就绪"))
                                } else {
                                    completion(.success("连接成功，当前账号 \(resolvedUsername)，目标目录将在上传时自动创建"))
                                }
                            case .failure(let error):
                                if case OpenListClientError.targetPathIsNotDirectory = error {
                                    completion(.failure(error))
                                } else {
                                    completion(.success("连接成功，当前账号 \(resolvedUsername)"))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func uploadFile(
        data: Data,
        fileName: String,
        serverURLString: String,
        username: String,
        passwordOrToken: String,
        remoteDirectory: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let baseURL = Self.normalizeServerURL(serverURLString) else {
            completion(.failure(OpenListClientError.invalidServerURL))
            return
        }

        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSecret = passwordOrToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDir = Self.normalizeRemoteDirectory(remoteDirectory)
        let fullPath = Self.fullRemoteFilePath(directory: normalizedDir, fileName: fileName)

        if Self.detectProtocolMode(for: baseURL) == .webDAV {
            uploadViaWebDAV(
                data: data,
                baseURL: baseURL,
                username: cleanUsername,
                secret: cleanSecret,
                normalizedDirectory: normalizedDir,
                fullPath: fullPath,
                completion: completion
            )
            return
        }

        guard !cleanSecret.isEmpty else {
            completion(.failure(OpenListClientError.missingCredentials))
            return
        }

        performOpenListAPIUpload(
            data: data,
            baseURL: baseURL,
            username: cleanUsername,
            secret: cleanSecret,
            normalizedDirectory: normalizedDir,
            fullPath: fullPath,
            allowTokenRetry: !cleanUsername.isEmpty,
            skipDirectoryCheck: false,
            completion: completion
        )
    }

    private func performOpenListAPIUpload(
        data: Data,
        baseURL: URL,
        username: String,
        secret: String,
        normalizedDirectory: String,
        fullPath: String,
        allowTokenRetry: Bool,
        skipDirectoryCheck: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        authenticateOpenListAPI(
            baseURL: baseURL,
            username: username,
            secret: secret,
            forceRefresh: false
        ) { [weak self] authResult in
            guard let self = self else { return }
            switch authResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let token):
                let uploadStep: () -> Void = {
                    self.putOpenListFile(
                        data: data,
                        baseURL: baseURL,
                        token: token,
                        fullPath: fullPath
                    ) { putResult in
                        switch putResult {
                        case .success:
                            completion(.success(fullPath))
                        case .failure(let error):
                            if allowTokenRetry, self.isUnauthorizedAPIError(error) {
                                self.clearCachedToken(baseURL: baseURL, username: username, passwordOrToken: secret)
                                self.performOpenListAPIUpload(
                                    data: data,
                                    baseURL: baseURL,
                                    username: username,
                                    secret: secret,
                                    normalizedDirectory: normalizedDirectory,
                                    fullPath: fullPath,
                                    allowTokenRetry: false,
                                    skipDirectoryCheck: true,
                                    completion: completion
                                )
                                return
                            }
                            completion(.failure(error))
                        }
                    }
                }

                if skipDirectoryCheck {
                    uploadStep()
                    return
                }

                self.ensureOpenListDirectory(
                    baseURL: baseURL,
                    token: token,
                    directory: normalizedDirectory
                ) { dirResult in
                    switch dirResult {
                    case .failure(let error):
                        if allowTokenRetry, self.isUnauthorizedAPIError(error) {
                            self.clearCachedToken(baseURL: baseURL, username: username, passwordOrToken: secret)
                            self.performOpenListAPIUpload(
                                data: data,
                                baseURL: baseURL,
                                username: username,
                                secret: secret,
                                normalizedDirectory: normalizedDirectory,
                                fullPath: fullPath,
                                allowTokenRetry: false,
                                skipDirectoryCheck: false,
                                completion: completion
                            )
                            return
                        }
                        completion(.failure(error))
                    case .success:
                        uploadStep()
                    }
                }
            }
        }
    }

    private func isUnauthorizedAPIError(_ error: Error) -> Bool {
        if case OpenListClientError.apiError(let code, _) = error {
            return code == 401
        }
        if case OpenListClientError.httpError(let statusCode, _) = error {
            return statusCode == 401
        }
        if case OpenListClientError.authenticationFailed(let statusCode, _) = error {
            return statusCode == 401
        }
        return false
    }

    private func authenticateOpenListAPI(
        baseURL: URL,
        username: String,
        secret: String,
        forceRefresh: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        if username.isEmpty {
            completion(.success(secret))
            return
        }

        let cacheKey = tokenCacheKey(baseURL: baseURL, username: username, passwordOrToken: secret)
        if !forceRefresh {
            tokenLock.lock()
            let existing = cachedTokens[cacheKey]
            tokenLock.unlock()
            if let existing = existing, !existing.isEmpty {
                completion(.success(existing))
                return
            }
        }

        let loginURL = endpointURL(base: baseURL, components: ["api", "auth", "login"])
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: String] = [
            "username": username,
            "password": secret
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                completion(.failure(error))
                return
            }

            let parsed = self.parseOpenListAPIResponse(data: data, response: response)
            switch parsed {
            case .success(let json):
                if let dataObj = json["data"] as? [String: Any],
                   let token = dataObj["token"] as? String,
                   !token.isEmpty {
                    self.tokenLock.lock()
                    self.cachedTokens[cacheKey] = token
                    self.tokenLock.unlock()
                    completion(.success(token))
                } else {
                    completion(.failure(OpenListClientError.invalidResponse))
                }
            case .failure(let apiError):
                if case OpenListClientError.apiError(let code, let message) = apiError {
                    if code == 402 {
                        completion(.failure(OpenListClientError.twoFactorRequired))
                    } else if code == 401 || code == 403 || code == 429 {
                        completion(.failure(OpenListClientError.authenticationFailed(statusCode: code, message: message)))
                    } else {
                        completion(.failure(apiError))
                    }
                } else {
                    completion(.failure(apiError))
                }
            }
        }.resume()
    }

    private func verifyCurrentUser(
        baseURL: URL,
        token: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let meURL = endpointURL(base: baseURL, components: ["api", "me"])
        var request = URLRequest(url: meURL)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "Authorization")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                completion(.failure(error))
                return
            }
            let parsed = self.parseOpenListAPIResponse(data: data, response: response)
            switch parsed {
            case .success(let json):
                let userObj = json["data"] as? [String: Any]
                let username = (userObj?["username"] as? String) ?? "已登录"
                if let role = userObj?["role"] as? Int, role == 1 {
                    completion(.failure(OpenListClientError.authenticationFailed(statusCode: 401, message: "Token 无效或当前为访客身份")))
                    return
                }
                completion(.success(username))
            case .failure(let error):
                completion(.failure(error))
            }
        }.resume()
    }

    private func checkOpenListDirectory(
        baseURL: URL,
        token: String,
        path: String,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        if path == "/" {
            completion(.success(true))
            return
        }

        let getURL = endpointURL(base: baseURL, components: ["api", "fs", "get"])
        var request = URLRequest(url: getURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["path": path], options: [])

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                completion(.failure(error))
                return
            }
            let parsed = self.parseOpenListAPIResponse(data: data, response: response)
            switch parsed {
            case .success(let json):
                if let item = json["data"] as? [String: Any],
                   let isDir = item["is_dir"] as? Bool,
                   !isDir {
                    completion(.failure(OpenListClientError.targetPathIsNotDirectory))
                    return
                }
                completion(.success(true))
            case .failure(let err):
                if let openListErr = err as? OpenListClientError, openListErr.isAuthenticationOrPermissionError {
                    completion(.failure(err))
                } else {
                    completion(.success(false))
                }
            }
        }.resume()
    }

    private func ensureOpenListDirectory(
        baseURL: URL,
        token: String,
        directory: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if directory == "/" {
            completion(.success(()))
            return
        }

        checkOpenListDirectory(baseURL: baseURL, token: token, path: directory) { [weak self] checkResult in
            guard let self = self else { return }
            switch checkResult {
            case .success(true):
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            case .success(false):
                let segments = directory.split(separator: "/").map(String.init).filter { !$0.isEmpty }
                var pathsToCreate: [String] = []
                var current = ""
                for segment in segments {
                    current += "/\(segment)"
                    pathsToCreate.append(current)
                }
                self.createOpenListDirectoriesSequentially(
                    baseURL: baseURL,
                    token: token,
                    paths: pathsToCreate,
                    index: 0,
                    completion: completion
                )
            }
        }
    }

    private func createOpenListDirectoriesSequentially(
        baseURL: URL,
        token: String,
        paths: [String],
        index: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard index < paths.count else {
            completion(.success(()))
            return
        }

        let targetPath = paths[index]
        let mkdirURL = endpointURL(base: baseURL, components: ["api", "fs", "mkdir"])
        var request = URLRequest(url: mkdirURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["path": targetPath], options: [])

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                completion(.failure(error))
                return
            }

            let parsed = self.parseOpenListAPIResponse(data: data, response: response)
            switch parsed {
            case .success:
                self.createOpenListDirectoriesSequentially(
                    baseURL: baseURL,
                    token: token,
                    paths: paths,
                    index: index + 1,
                    completion: completion
                )
            case .failure(let err):
                if let openListErr = err as? OpenListClientError, openListErr.isAuthenticationOrPermissionError {
                    completion(.failure(err))
                    return
                }
                self.createOpenListDirectoriesSequentially(
                    baseURL: baseURL,
                    token: token,
                    paths: paths,
                    index: index + 1,
                    completion: completion
                )
            }
        }.resume()
    }

    private func putOpenListFile(
        data: Data,
        baseURL: URL,
        token: String,
        fullPath: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let putURL = endpointURL(base: baseURL, components: ["api", "fs", "put"])
        var request = URLRequest(url: putURL)
        request.httpMethod = "PUT"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue(Self.encodeOpenListPathHeader(fullPath), forHTTPHeaderField: "File-Path")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        request.setValue("true", forHTTPHeaderField: "Overwrite")
        request.httpBody = data

        session.dataTask(with: request) { [weak self] respData, response, error in
            guard let self = self else { return }
            if let error = error {
                completion(.failure(error))
                return
            }
            let parsed = self.parseOpenListAPIResponse(data: respData, response: response)
            switch parsed {
            case .success:
                completion(.success(()))
            case .failure(let err):
                completion(.failure(err))
            }
        }.resume()
    }

    private func parseOpenListAPIResponse(
        data: Data?,
        response: URLResponse?
    ) -> Result<[String: Any], Error> {
        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(OpenListClientError.invalidResponse)
        }

        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: []) as? [String: Any] }

        guard (200...299).contains(httpResponse.statusCode) else {
            let msg = (json?["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .failure(OpenListClientError.authenticationFailed(statusCode: httpResponse.statusCode, message: msg))
            }
            return .failure(OpenListClientError.httpError(statusCode: httpResponse.statusCode, message: msg))
        }

        guard let json = json, let code = json["code"] as? Int else {
            return .failure(OpenListClientError.invalidResponse)
        }

        if code == 200 {
            return .success(json)
        }

        let message = (json["message"] as? String) ?? "OpenList 返回错误"
        return .failure(OpenListClientError.apiError(code: code, message: message))
    }

    private func webDAVAuthorizationHeader(username: String, secret: String) -> String? {
        if !username.isEmpty {
            let raw = "\(username):\(secret)"
            return "Basic " + Data(raw.utf8).base64EncodedString()
        }
        if !secret.isEmpty {
            return "Bearer \(secret)"
        }
        return nil
    }

    private func webDAVURL(baseURL: URL, path: String) -> URL {
        let segments = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var target = baseURL
        for segment in segments {
            target.appendPathComponent(segment)
        }
        return target
    }

    private func testWebDAVConnection(
        baseURL: URL,
        username: String,
        secret: String,
        remoteDirectory: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let targetURL = webDAVURL(baseURL: baseURL, path: remoteDirectory)
        var request = URLRequest(url: targetURL)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        if let authHeader = webDAVAuthorizationHeader(username: username, secret: secret) {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        session.dataTask(with: request) { [weak self] _, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(OpenListClientError.invalidResponse))
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                completion(.failure(OpenListClientError.authenticationFailed(statusCode: http.statusCode, message: "WebDAV 认证或权限校验失败")))
                return
            }
            if (200...299).contains(http.statusCode) || http.statusCode == 207 {
                completion(.success("WebDAV 连接成功，目标目录已就绪"))
                return
            }
            if http.statusCode == 404 {
                self?.probeWebDAVRoot(baseURL: baseURL, username: username, secret: secret, completion: completion)
                return
            }
            completion(.failure(OpenListClientError.httpError(statusCode: http.statusCode, message: "WebDAV 响应异常")))
        }.resume()
    }

    private func probeWebDAVRoot(
        baseURL: URL,
        username: String,
        secret: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        if let authHeader = webDAVAuthorizationHeader(username: username, secret: secret) {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        session.dataTask(with: request) { _, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(OpenListClientError.invalidResponse))
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                completion(.failure(OpenListClientError.authenticationFailed(statusCode: http.statusCode, message: "WebDAV 认证或权限校验失败")))
                return
            }
            if (200...299).contains(http.statusCode) || http.statusCode == 207 {
                completion(.success("WebDAV 连接成功，目标目录将在上传时自动创建"))
                return
            }
            completion(.failure(OpenListClientError.httpError(statusCode: http.statusCode, message: "WebDAV 响应异常")))
        }.resume()
    }

    private func uploadViaWebDAV(
        data: Data,
        baseURL: URL,
        username: String,
        secret: String,
        normalizedDirectory: String,
        fullPath: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let segments = normalizedDirectory.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var pathsToCreate: [String] = []
        var current = ""
        for segment in segments {
            current += "/\(segment)"
            pathsToCreate.append(current)
        }

        createWebDAVDirectoriesSequentially(
            baseURL: baseURL,
            username: username,
            secret: secret,
            paths: pathsToCreate,
            index: 0
        ) { [weak self] mkResult in
            guard let self = self else { return }
            switch mkResult {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                let fileURL = self.webDAVURL(baseURL: baseURL, path: fullPath)
                var request = URLRequest(url: fileURL)
                request.httpMethod = "PUT"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
                if let authHeader = self.webDAVAuthorizationHeader(username: username, secret: secret) {
                    request.setValue(authHeader, forHTTPHeaderField: "Authorization")
                }
                request.httpBody = data

                self.session.dataTask(with: request) { _, response, error in
                    if let error = error {
                        completion(.failure(error))
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        completion(.failure(OpenListClientError.invalidResponse))
                        return
                    }
                    if http.statusCode == 401 || http.statusCode == 403 {
                        completion(.failure(OpenListClientError.authenticationFailed(statusCode: http.statusCode, message: "WebDAV 认证或写入权限不足")))
                        return
                    }
                    if (200...299).contains(http.statusCode) {
                        completion(.success(fullPath))
                        return
                    }
                    completion(.failure(OpenListClientError.httpError(statusCode: http.statusCode, message: "WebDAV 上传失败")))
                }.resume()
            }
        }
    }

    private func createWebDAVDirectoriesSequentially(
        baseURL: URL,
        username: String,
        secret: String,
        paths: [String],
        index: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard index < paths.count else {
            completion(.success(()))
            return
        }

        let dirURL = webDAVURL(baseURL: baseURL, path: paths[index])
        var request = URLRequest(url: dirURL)
        request.httpMethod = "MKCOL"
        if let authHeader = webDAVAuthorizationHeader(username: username, secret: secret) {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(OpenListClientError.invalidResponse))
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                completion(.failure(OpenListClientError.authenticationFailed(statusCode: http.statusCode, message: "WebDAV 认证或创建目录权限不足")))
                return
            }
            if (200...299).contains(http.statusCode) || http.statusCode == 405 {
                self.createWebDAVDirectoriesSequentially(
                    baseURL: baseURL,
                    username: username,
                    secret: secret,
                    paths: paths,
                    index: index + 1,
                    completion: completion
                )
                return
            }
            completion(.failure(OpenListClientError.httpError(statusCode: http.statusCode, message: "WebDAV 创建目录失败")))
        }.resume()
    }
}

final class AutoBackupManager {
    static let shared = AutoBackupManager()
    static let statusDidChangeNotification = NSNotification.Name("AutoBackupStatusDidChangeNotification")

    static let defaultRetryDelay: TimeInterval = 60.0
    static let defaultMaxRetries = 3
    static let refreshTaskIdentifier = "com.example.SimpleBrowser.autobackup.refresh"
    static let processingTaskIdentifier = "com.example.SimpleBrowser.autobackup.processing"

    private static let serverSecretAccount = "openlist_password_or_token"
    private static let backupEncryptionPasswordAccount = "openlist_backup_encryption_password"

    typealias BackupDataGenerator = (_ encryptionPassword: String?, _ completion: @escaping (Result<(fileName: String, data: Data), Error>) -> Void) -> Void

    private let lock = NSLock()
    private let configFileURL: URL
    private let credentialStore: BackupCredentialStoring
    private let client: OpenListClient
    private let retryDelay: TimeInterval
    private let maxAutomaticRetries: Int
    private let enableBackgroundTasks: Bool
    private let backupDataGenerator: BackupDataGenerator
    private let nowProvider: () -> Date

    private var config: OpenListBackupConfig
    private var isUploading = false
    private var pendingRetryDate: Date?
    private var retryAttemptCount = 0
    private var scheduleTimer: Timer?
    private var retryTimer: Timer?
    private var hasStarted = false
    private var pathMonitor: NWPathMonitor?
    private var wasNetworkSatisfied: Bool?
    private var activeBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var manualCompletionHandlers: [(Result<String, Error>) -> Void] = []

    convenience init() {
        let fm = FileManager.default
        let baseDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = baseDir.appendingPathComponent("SimpleBrowser", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.init(
            configFileURL: dir.appendingPathComponent("auto_backup_config_v1.json"),
            credentialStore: KeychainCredentialStore(),
            client: OpenListClient(),
            retryDelay: Self.defaultRetryDelay,
            maxAutomaticRetries: Self.defaultMaxRetries,
            enableBackgroundTasks: true,
            backupDataGenerator: { password, completion in
                BackupManager.shared.generateBackupData(encryptionPassword: password, completion: completion)
            },
            nowProvider: { Date() }
        )
    }

    init(
        configFileURL: URL,
        credentialStore: BackupCredentialStoring,
        client: OpenListClient,
        retryDelay: TimeInterval = AutoBackupManager.defaultRetryDelay,
        maxAutomaticRetries: Int = AutoBackupManager.defaultMaxRetries,
        enableBackgroundTasks: Bool = false,
        backupDataGenerator: @escaping BackupDataGenerator,
        nowProvider: @escaping () -> Date = { Date() }
    ) {
        self.configFileURL = configFileURL
        self.credentialStore = credentialStore
        self.client = client
        self.retryDelay = retryDelay
        self.maxAutomaticRetries = max(1, maxAutomaticRetries)
        self.enableBackgroundTasks = enableBackgroundTasks
        self.backupDataGenerator = backupDataGenerator
        self.nowProvider = nowProvider
        self.config = Self.loadConfig(from: configFileURL)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        scheduleTimer?.invalidate()
        retryTimer?.invalidate()
        pathMonitor?.cancel()
    }

    private static func loadConfig(from url: URL) -> OpenListBackupConfig {
        guard let data = try? Data(contentsOf: url) else {
            return .defaultConfig()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(OpenListBackupConfig.self, from: data)) ?? .defaultConfig()
    }

    private func saveConfigLocked() {
        let dir = configFileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configFileURL, options: .atomic)
    }

    var currentConfig: OpenListBackupConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    var currentServerSecret: String {
        credentialStore.loadSecret(forAccount: Self.serverSecretAccount)
    }

    var currentBackupEncryptionPassword: String {
        credentialStore.loadSecret(forAccount: Self.backupEncryptionPasswordAccount)
    }

    var statusSnapshot: AutoBackupStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshotLocked()
    }

    private func makeSnapshotLocked() -> AutoBackupStatusSnapshot {
        let nextScheduledDate = computeNextScheduledDateLocked()
        return AutoBackupStatusSnapshot(
            config: config,
            isUploading: isUploading,
            nextScheduledDate: nextScheduledDate,
            pendingRetryDate: pendingRetryDate,
            retryAttemptCount: retryAttemptCount,
            isWaitingForRetry: pendingRetryDate != nil
        )
    }

    private func computeNextScheduledDateLocked() -> Date? {
        guard config.isEnabled else { return nil }
        if let retryDate = pendingRetryDate {
            return retryDate
        }
        guard let lastSuccess = config.lastSuccessDate else {
            return nowProvider()
        }
        return lastSuccess.addingTimeInterval(TimeInterval(config.intervalHours) * 3600.0)
    }

    private func postStatusChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            NotificationCenter.default.post(name: Self.statusDidChangeNotification, object: self)
        }
    }

    func start() {
        lock.lock()
        if hasStarted {
            lock.unlock()
            return
        }
        hasStarted = true
        lock.unlock()

        if enableBackgroundTasks {
            registerBackgroundTasksIfPermitted()
            startNetworkMonitor()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.evaluateScheduleIfNeeded()
        }
    }

    private func registerBackgroundTasksIfPermitted() {
        guard #available(iOS 13.0, *) else { return }
        let permitted = (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]) ?? []

        if permitted.contains(Self.refreshTaskIdentifier) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskIdentifier, using: nil) { [weak self] task in
                guard let refreshTask = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self?.handleBackgroundTask(refreshTask)
            }
        }

        if permitted.contains(Self.processingTaskIdentifier) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingTaskIdentifier, using: nil) { [weak self] task in
                guard let processingTask = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self?.handleBackgroundTask(processingTask)
            }
        }
    }

    @available(iOS 13.0, *)
    private func handleBackgroundTask(_ task: BGTask) {
        scheduleBackgroundTasksIfNeeded()

        task.expirationHandler = { [weak self] in
            self?.postStatusChanged()
        }

        let cfg = currentConfig
        guard cfg.isEnabled, OpenListClient.normalizeServerURL(cfg.serverURL) != nil else {
            task.setTaskCompleted(success: true)
            return
        }

        let dueDate = statusSnapshot.nextScheduledDate ?? nowProvider()
        guard nowProvider() >= dueDate else {
            task.setTaskCompleted(success: true)
            return
        }

        triggerUploadInternal(isManual: false, overrideConfig: nil, overrideSecret: nil, overrideBackupPassword: nil) { result in
            switch result {
            case .success:
                task.setTaskCompleted(success: true)
            case .failure:
                task.setTaskCompleted(success: false)
            }
        }
    }

    private func scheduleBackgroundTasksIfNeeded() {
        guard enableBackgroundTasks else { return }
        guard #available(iOS 13.0, *) else { return }
        let permitted = (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]) ?? []

        guard let targetDate = statusSnapshot.nextScheduledDate else {
            if permitted.contains(Self.refreshTaskIdentifier) {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskIdentifier)
            }
            if permitted.contains(Self.processingTaskIdentifier) {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingTaskIdentifier)
            }
            return
        }

        let beginDate = max(targetDate, nowProvider().addingTimeInterval(15))

        if permitted.contains(Self.refreshTaskIdentifier) {
            let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
            request.earliestBeginDate = beginDate
            try? BGTaskScheduler.shared.submit(request)
        }

        if permitted.contains(Self.processingTaskIdentifier) {
            let request = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = false
            request.earliestBeginDate = beginDate
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let satisfied = path.status == .satisfied
            self.lock.lock()
            let previous = self.wasNetworkSatisfied
            self.wasNetworkSatisfied = satisfied
            let hasError = self.config.lastErrorMessage != nil
            let enabled = self.config.isEnabled
            if previous == false && satisfied && enabled && hasError {
                self.retryAttemptCount = 0
            }
            self.lock.unlock()

            if previous == false && satisfied && enabled && hasError {
                DispatchQueue.main.async {
                    self.evaluateScheduleIfNeeded()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "SimpleBrowser.AutoBackupNetworkMonitor"))
        pathMonitor = monitor
    }

    @objc private func handleAppDidBecomeActive() {
        evaluateScheduleIfNeeded()
    }

    @objc private func handleAppDidEnterBackground() {
        scheduleBackgroundTasksIfNeeded()
        lock.lock()
        let uploading = isUploading
        let hasRetry = pendingRetryDate != nil
        lock.unlock()
        if uploading || hasRetry {
            beginBackgroundProtectionIfNeeded()
        }
    }

    private func beginBackgroundProtectionIfNeeded() {
        guard enableBackgroundTasks else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.activeBackgroundTaskID == .invalid else { return }
            self.activeBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "OpenListAutoBackup") { [weak self] in
                self?.endBackgroundProtectionIfNeeded()
            }
        }
    }

    private func endBackgroundProtectionIfNeeded() {
        guard enableBackgroundTasks else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.activeBackgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(self.activeBackgroundTaskID)
                self.activeBackgroundTaskID = .invalid
            }
        }
    }

    func updateConfiguration(
        isEnabled: Bool,
        serverURL: String,
        username: String,
        passwordOrToken: String,
        remoteDirectory: String,
        intervalHours: Int,
        backupPassword: String,
        triggerIfDue: Bool = true
    ) {
        let clampedInterval = min(max(intervalHours, 1), 8760)
        let cleanServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSecret = passwordOrToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDir = OpenListClient.normalizeRemoteDirectory(remoteDirectory)
        let previousSecret = currentServerSecret

        credentialStore.saveSecret(cleanSecret, forAccount: Self.serverSecretAccount)
        credentialStore.saveSecret(backupPassword, forAccount: Self.backupEncryptionPasswordAccount)

        lock.lock()
        let endpointChanged = config.serverURL != cleanServer ||
            config.username != cleanUser ||
            previousSecret != cleanSecret ||
            config.remoteDirectory != normalizedDir
        config.isEnabled = isEnabled
        config.serverURL = cleanServer
        config.username = cleanUser
        config.remoteDirectory = normalizedDir
        config.intervalHours = clampedInterval
        if endpointChanged {
            config.lastErrorMessage = nil
            pendingRetryDate = nil
            retryAttemptCount = 0
        } else if !isEnabled {
            pendingRetryDate = nil
            retryAttemptCount = 0
        }
        saveConfigLocked()
        lock.unlock()

        if endpointChanged, let url = OpenListClient.normalizeServerURL(cleanServer) {
            client.clearCachedToken(
                baseURL: url,
                username: cleanUser,
                passwordOrToken: cleanSecret
            )
        }

        DispatchQueue.main.async { [weak self] in
            self?.cancelTimersOnMainThread()
            self?.postStatusChanged()
            self?.scheduleBackgroundTasksIfNeeded()
            if triggerIfDue && isEnabled {
                self?.evaluateScheduleIfNeeded()
            }
        }
    }

    func testConnection(
        serverURL: String,
        username: String,
        passwordOrToken: String,
        remoteDirectory: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        client.testConnection(
            serverURLString: serverURL,
            username: username,
            passwordOrToken: passwordOrToken,
            remoteDirectory: remoteDirectory
        ) { result in
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func triggerManualBackup(
        overrideConfig: OpenListBackupConfig? = nil,
        passwordOrToken: String? = nil,
        backupPassword: String? = nil,
        completion: ((Result<String, Error>) -> Void)? = nil
    ) {
        if let overrideConfig = overrideConfig {
            let cleanSecret = (passwordOrToken ?? currentServerSecret).trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveBackupPassword = backupPassword ?? currentBackupEncryptionPassword
            updateConfiguration(
                isEnabled: overrideConfig.isEnabled,
                serverURL: overrideConfig.serverURL,
                username: overrideConfig.username,
                passwordOrToken: cleanSecret,
                remoteDirectory: overrideConfig.remoteDirectory,
                intervalHours: overrideConfig.intervalHours,
                backupPassword: effectiveBackupPassword,
                triggerIfDue: false
            )
        }

        triggerUploadInternal(
            isManual: true,
            overrideConfig: nil,
            overrideSecret: nil,
            overrideBackupPassword: nil,
            completion: completion
        )
    }

    func evaluateScheduleIfNeeded() {
        let evaluateWork = { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let isCurrentlyUploading = self.isUploading
            let enabled = self.config.isEnabled
            let server = self.config.serverURL
            let retryDate = self.pendingRetryDate
            let nextDate = self.computeNextScheduledDateLocked()
            self.lock.unlock()

            guard !isCurrentlyUploading else { return }

            if let retryDate = retryDate {
                let remaining = retryDate.timeIntervalSince(self.nowProvider())
                if remaining <= 0 {
                    self.triggerUploadInternal(isManual: false, overrideConfig: nil, overrideSecret: nil, overrideBackupPassword: nil, completion: nil)
                } else {
                    self.scheduleRetryTimerOnMainThread(delay: remaining)
                }
                return
            }

            guard enabled, OpenListClient.normalizeServerURL(server) != nil, let targetDate = nextDate else {
                self.cancelTimersOnMainThread()
                self.scheduleBackgroundTasksIfNeeded()
                return
            }

            let delay = targetDate.timeIntervalSince(self.nowProvider())
            if delay <= 0 {
                self.triggerUploadInternal(isManual: false, overrideConfig: nil, overrideSecret: nil, overrideBackupPassword: nil, completion: nil)
            } else {
                self.scheduleRegularTimerOnMainThread(delay: delay)
                self.scheduleBackgroundTasksIfNeeded()
            }
        }

        if Thread.isMainThread {
            evaluateWork()
        } else {
            DispatchQueue.main.async(execute: evaluateWork)
        }
    }

    private func triggerUploadInternal(
        isManual: Bool,
        overrideConfig: OpenListBackupConfig?,
        overrideSecret: String?,
        overrideBackupPassword: String?,
        completion: ((Result<String, Error>) -> Void)?
    ) {
        lock.lock()
        if isUploading {
            if let completion = completion {
                manualCompletionHandlers.append(completion)
            }
            lock.unlock()
            return
        }

        let effectiveConfig = overrideConfig ?? config
        let effectiveSecret = overrideSecret ?? currentServerSecret
        let effectiveEncryptionPassword = overrideBackupPassword ?? currentBackupEncryptionPassword

        guard OpenListClient.normalizeServerURL(effectiveConfig.serverURL) != nil else {
            let err = OpenListClientError.invalidServerURL
            if isManual {
                config.lastAttemptDate = nowProvider()
                config.lastErrorMessage = err.localizedDescription
                saveConfigLocked()
            }
            lock.unlock()
            postStatusChanged()
            DispatchQueue.main.async {
                completion?(.failure(err))
            }
            return
        }

        isUploading = true
        pendingRetryDate = nil
        if isManual {
            retryAttemptCount = 0
        }
        if let completion = completion {
            manualCompletionHandlers.append(completion)
        }
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.cancelTimersOnMainThread()
        }
        beginBackgroundProtectionIfNeeded()
        postStatusChanged()

        backupDataGenerator(effectiveEncryptionPassword.isEmpty ? nil : effectiveEncryptionPassword) { [weak self] packResult in
            guard let self = self else { return }
            switch packResult {
            case .failure(let error):
                self.finishUploadAttempt(with: .failure(error), fileName: nil)
            case .success(let payload):
                self.client.uploadFile(
                    data: payload.data,
                    fileName: payload.fileName,
                    serverURLString: effectiveConfig.serverURL,
                    username: effectiveConfig.username,
                    passwordOrToken: effectiveSecret,
                    remoteDirectory: effectiveConfig.remoteDirectory
                ) { [weak self] uploadResult in
                    self?.finishUploadAttempt(with: uploadResult, fileName: payload.fileName)
                }
            }
        }
    }

    private func finishUploadAttempt(with result: Result<String, Error>, fileName: String?) {
        let now = nowProvider()

        lock.lock()
        isUploading = false
        let callbacks = manualCompletionHandlers
        manualCompletionHandlers.removeAll()

        switch result {
        case .success:
            config.lastSuccessDate = now
            config.lastAttemptDate = now
            config.lastErrorMessage = nil
            if let fileName = fileName {
                config.lastUploadedFileName = fileName
            }
            pendingRetryDate = nil
            retryAttemptCount = 0
            saveConfigLocked()
            let nextRegularDelay = config.isEnabled ? TimeInterval(config.intervalHours) * 3600.0 : nil
            lock.unlock()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cancelTimersOnMainThread()
                if let delay = nextRegularDelay {
                    self.scheduleRegularTimerOnMainThread(delay: delay)
                }
                self.scheduleBackgroundTasksIfNeeded()
                self.endBackgroundProtectionIfNeeded()
                self.postStatusChanged()
                for callback in callbacks {
                    callback(result)
                }
            }

        case .failure(let error):
            config.lastAttemptDate = now
            config.lastErrorMessage = error.localizedDescription

            let allowedRetries: Int
            if let openListError = error as? OpenListClientError, openListError.isAuthenticationOrPermissionError {
                allowedRetries = 1
            } else {
                allowedRetries = maxAutomaticRetries
            }

            let shouldScheduleRetry = retryAttemptCount < allowedRetries
            if shouldScheduleRetry {
                retryAttemptCount += 1
                pendingRetryDate = now.addingTimeInterval(retryDelay)
            } else {
                pendingRetryDate = nil
            }
            saveConfigLocked()
            let scheduledDelay = shouldScheduleRetry ? retryDelay : nil
            let regularDelay = (!shouldScheduleRetry && config.isEnabled) ? TimeInterval(config.intervalHours) * 3600.0 : nil
            lock.unlock()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cancelTimersOnMainThread()
                if let retryDelay = scheduledDelay {
                    self.scheduleRetryTimerOnMainThread(delay: retryDelay)
                } else {
                    if let regularDelay = regularDelay {
                        self.scheduleRegularTimerOnMainThread(delay: regularDelay)
                    }
                    self.endBackgroundProtectionIfNeeded()
                }
                self.scheduleBackgroundTasksIfNeeded()
                self.postStatusChanged()
                for callback in callbacks {
                    callback(result)
                }
            }
        }
    }

    private func cancelTimersOnMainThread() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func scheduleRegularTimerOnMainThread(delay: TimeInterval) {
        scheduleTimer?.invalidate()
        let safeDelay = max(1.0, delay)
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: safeDelay, repeats: false) { [weak self] _ in
            self?.evaluateScheduleIfNeeded()
        }
    }

    private func scheduleRetryTimerOnMainThread(delay: TimeInterval) {
        retryTimer?.invalidate()
        let safeDelay = max(0.05, delay)
        retryTimer = Timer.scheduledTimer(withTimeInterval: safeDelay, repeats: false) { [weak self] _ in
            self?.triggerUploadInternal(isManual: false, overrideConfig: nil, overrideSecret: nil, overrideBackupPassword: nil, completion: nil)
        }
    }
}
