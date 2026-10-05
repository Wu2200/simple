import UIKit
import WebKit

struct MainDomainGroup {
    let mainDomain: String
    var records: [WKWebsiteDataRecord]

    var allDataTypes: Set<String> {
        var types = Set<String>()
        for r in records {
            types.formUnion(r.dataTypes)
        }
        return types
    }

    var hasLocked: Bool {
        return CookieLockStore.shared.isLocked(domain: mainDomain) || records.contains { CookieLockStore.shared.isLocked(domain: $0.displayName) }
    }

    var allLocked: Bool {
        return !records.isEmpty && records.allSatisfy { CookieLockStore.shared.isLocked(domain: $0.displayName) }
    }

    var hasCookies: Bool {
        return records.contains { $0.dataTypes.contains(WKWebsiteDataTypeCookies) }
    }
}

final class DomainRelationStore {
    static let shared = DomainRelationStore()
    private let relationsKey = "browser_domain_relations_v2"
    private let primaryKey = "browser_primary_domains_v2"
    private var relations: [String: String] = [:]
    private var primaryDomains: Set<String> = []
    private let lock = NSLock()

    private init() {
        relations = UserDefaults.standard.dictionary(forKey: relationsKey) as? [String: String] ?? [:]
        let primaries = UserDefaults.standard.stringArray(forKey: primaryKey) ?? []
        primaryDomains = Set(primaries)
    }

    func recordPrimaryDomain(_ domain: String) {
        let root = DomainRelationEngine.rootDomain(of: domain)
        guard !root.isEmpty else { return }
        lock.lock()
        primaryDomains.insert(root)
        relations.removeValue(forKey: root)
        let primaries = Array(primaryDomains)
        let copy = relations
        lock.unlock()

        UserDefaults.standard.set(primaries, forKey: primaryKey)
        UserDefaults.standard.set(copy, forKey: relationsKey)
    }

    func recordRelations(subDomains: [String], parentDomain: String) {
        let parentRoot = DomainRelationEngine.rootDomain(of: parentDomain)
        guard !parentRoot.isEmpty else { return }

        lock.lock()
        primaryDomains.insert(parentRoot)
        var changed = false
        for sub in subDomains {
            let subRoot = DomainRelationEngine.rootDomain(of: sub)
            guard !subRoot.isEmpty, subRoot != parentRoot else { continue }
            if !primaryDomains.contains(subRoot) {
                if relations[subRoot] != parentRoot {
                    relations[subRoot] = parentRoot
                    changed = true
                }
            }
        }
        let copy = relations
        let primaries = Array(primaryDomains)
        lock.unlock()

        if changed {
            UserDefaults.standard.set(copy, forKey: relationsKey)
            UserDefaults.standard.set(primaries, forKey: primaryKey)
        }
    }

    func getParentDomain(for subDomain: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let subRoot = DomainRelationEngine.rootDomain(of: subDomain)
        return relations[subRoot]
    }

    func getAllRelations() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return relations
    }
}

enum DomainRelationEngine {
    static func rootDomain(of domain: String) -> String {
        let clean = domain.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let parts = clean.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return clean }

        if parts.allSatisfy({ Int($0) != nil }) && parts.count == 4 {
            return clean
        }
        if clean.contains(":") {
            return clean
        }

        let multiSuffixes: Set<String> = [
            "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
            "co.uk", "org.uk", "me.uk", "co.jp", "ne.jp",
            "com.hk", "org.hk", "com.tw", "com.au", "co.nz"
        ]

        if parts.count >= 3 {
            let lastTwo = "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
            if multiSuffixes.contains(lastTwo) {
                return "\(parts[parts.count - 3]).\(lastTwo)"
            }
        }

        return "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
    }

    static func areDomainsAssociated(_ d1: String, _ d2: String) -> Bool {
        let r1 = rootDomain(of: d1)
        let r2 = rootDomain(of: d2)
        if !r1.isEmpty && r1 == r2 { return true }

        if let p1 = DomainRelationStore.shared.getParentDomain(for: r1), (p1 == r2 || p1 == r1) {
            return true
        }
        if let p2 = DomainRelationStore.shared.getParentDomain(for: r2), (p2 == r1 || p2 == r2) {
            return true
        }
        return false
    }

    static func groupRecordsIntoMainDomains(_ records: [WKWebsiteDataRecord]) -> [MainDomainGroup] {
        var dict: [String: [WKWebsiteDataRecord]] = [:]

        for record in records {
            let host = record.displayName.trimmingCharacters(in: .whitespaces).lowercased()
            let root = rootDomain(of: host)
            dict[root, default: []].append(record)
        }

        let learnedRelations = DomainRelationStore.shared.getAllRelations()
        for (subRoot, parentRoot) in learnedRelations {
            if subRoot != parentRoot, let compRecs = dict[subRoot], dict[parentRoot] != nil {
                dict[parentRoot]?.append(contentsOf: compRecs)
                dict.removeValue(forKey: subRoot)
            }
        }

        var groups: [MainDomainGroup] = []
        for (mainDomain, groupRecords) in dict {
            var seen = Set<String>()
            var uniqueRecords: [WKWebsiteDataRecord] = []
            for r in groupRecords {
                if !seen.contains(r.displayName) {
                    seen.insert(r.displayName)
                    uniqueRecords.append(r)
                }
            }

            let sortedRecords = uniqueRecords.sorted { r1, r2 in
                let h1 = r1.displayName.lowercased()
                let h2 = r2.displayName.lowercased()
                if h1 == mainDomain { return true }
                if h2 == mainDomain { return false }
                let lock1 = CookieLockStore.shared.isLocked(domain: r1.displayName)
                let lock2 = CookieLockStore.shared.isLocked(domain: r2.displayName)
                if lock1 != lock2 { return lock1 && !lock2 }
                let c1 = r1.dataTypes.contains(WKWebsiteDataTypeCookies)
                let c2 = r2.dataTypes.contains(WKWebsiteDataTypeCookies)
                if c1 != c2 { return c1 && !c2 }
                return h1 < h2
            }

            groups.append(MainDomainGroup(mainDomain: mainDomain, records: sortedRecords))
        }

        return groups.sorted { g1, g2 in
            let lock1 = g1.hasLocked
            let lock2 = g2.hasLocked
            if lock1 != lock2 { return lock1 && !lock2 }
            let cookie1 = g1.hasCookies
            let cookie2 = g2.hasCookies
            if cookie1 != cookie2 { return cookie1 && !cookie2 }
            return g1.mainDomain.localizedCaseInsensitiveCompare(g2.mainDomain) == .orderedAscending
        }
    }
}

final class DomainSettingsStore {
    static let shared = DomainSettingsStore()
    private init() {}

    private func makeKey(_ domain: String, _ setting: String) -> String {
        return "DOMAIN_SETTING_\(domain.lowercased())_\(setting)"
    }

    func getBool(domain: String, setting: String, defaultVal: Bool = true) -> Bool {
        let k = makeKey(domain, setting)
        if UserDefaults.standard.object(forKey: k) == nil {
            return defaultVal
        }
        return UserDefaults.standard.bool(forKey: k)
    }

    func setBool(domain: String, setting: String, value: Bool) {
        UserDefaults.standard.set(value, forKey: makeKey(domain, setting))
    }
}

final class CertificateTrustStore {
    static let shared = CertificateTrustStore()
    private let key = "browser_trusted_insecure_hosts_v1"
    private var trustedHosts: Set<String>

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? []
        trustedHosts = Set(saved.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    func isHostTrusted(_ host: String) -> Bool {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return false }
        if trustedHosts.contains(clean) { return true }
        if clean.hasPrefix("www.") {
            let withoutWww = String(clean.dropFirst(4))
            if trustedHosts.contains(withoutWww) { return true }
        } else {
            let withWww = "www." + clean
            if trustedHosts.contains(withWww) { return true }
        }
        let root = DomainRelationEngine.rootDomain(of: clean)
        if !root.isEmpty && trustedHosts.contains(root) { return true }
        return false
    }

    func trustHost(_ host: String) {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return }
        trustedHosts.insert(clean)
        if clean.hasPrefix("www.") {
            trustedHosts.insert(String(clean.dropFirst(4)))
        } else {
            trustedHosts.insert("www." + clean)
        }
        let root = DomainRelationEngine.rootDomain(of: clean)
        if !root.isEmpty {
            trustedHosts.insert(root)
        }
        UserDefaults.standard.set(Array(trustedHosts), forKey: key)
    }

    func untrustHost(_ host: String) {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        trustedHosts.remove(clean)
        if clean.hasPrefix("www.") {
            trustedHosts.remove(String(clean.dropFirst(4)))
        } else {
            trustedHosts.remove("www." + clean)
        }
        let root = DomainRelationEngine.rootDomain(of: clean)
        if !root.isEmpty {
            trustedHosts.remove(root)
        }
        UserDefaults.standard.set(Array(trustedHosts), forKey: key)
    }

    func clearAll() {
        trustedHosts.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
    }

    func getAllTrustedHosts() -> [String] {
        return Array(trustedHosts)
    }

    func restoreTrustedHosts(_ hosts: [String]) {
        trustedHosts = Set(hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        UserDefaults.standard.set(Array(trustedHosts), forKey: key)
    }
}

final class CookieLockStore {
    static let shared = CookieLockStore()
    private let key = "locked_cookie_domains_v2"

    private init() {}

    func getLockedDomains() -> [String] {
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func isLocked(domain: String) -> Bool {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !clean.isEmpty else { return false }
        let locked = getLockedDomains().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return locked.contains(clean)
    }

    func isCookieProtected(cookieDomain: String) -> Bool {
        let locked = getLockedDomains().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        if locked.isEmpty { return false }
        let cleanCookie = cookieDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !cleanCookie.isEmpty else { return false }

        for l in locked {
            if cleanCookie == l { return true }
            if l.hasSuffix("." + cleanCookie) { return true }
            if cleanCookie.hasSuffix("." + l) { return true }
            let r1 = DomainRelationEngine.rootDomain(of: cleanCookie)
            let r2 = DomainRelationEngine.rootDomain(of: l)
            if !r1.isEmpty && r1 == r2 { return true }
            if DomainRelationEngine.areDomainsAssociated(cleanCookie, l) { return true }
        }
        return false
    }

    func isRecordLoginProtected(recordDisplayName: String) -> Bool {
        let cleanName = recordDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !cleanName.isEmpty else { return false }
        let locked = getLockedDomains().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }

        for l in locked {
            if cleanName == l { return true }
            if l.hasSuffix("." + cleanName) || cleanName.hasSuffix("." + l) { return true }
            let r1 = DomainRelationEngine.rootDomain(of: cleanName)
            let r2 = DomainRelationEngine.rootDomain(of: l)
            if !r1.isEmpty && r1 == r2 { return true }
            if DomainRelationEngine.areDomainsAssociated(cleanName, l) { return true }
        }
        return false
    }

    func lock(domain: String) {
        var locked = getLockedDomains()
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if !clean.isEmpty && !locked.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == clean }) {
            locked.append(clean)
            UserDefaults.standard.set(locked, forKey: key)
        }
    }

    func unlock(domain: String) {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var locked = getLockedDomains()
        locked.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == clean }
        UserDefaults.standard.set(locked, forKey: key)
    }

    func toggleLock(domain: String) {
        if isLocked(domain: domain) {
            unlock(domain: domain)
        } else {
            lock(domain: domain)
        }
    }

    func lockAll(domains: [String]) {
        for d in domains {
            lock(domain: d)
        }
    }

    func unlockAll(domains: [String]) {
        for d in domains {
            unlock(domain: d)
        }
    }
}

final class WebsiteCleaner {
    static let shared = WebsiteCleaner()
    private init() {}

    static let cacheDataTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
        WKWebsiteDataTypeFetchCache
    ]

    static let nonCookieLoginDataTypes: Set<String> = [
        WKWebsiteDataTypeLocalStorage,
        WKWebsiteDataTypeIndexedDBDatabases,
        WKWebsiteDataTypeWebSQLDatabases,
        WKWebsiteDataTypeSessionStorage
    ]

    func clean(
        cache: Bool,
        loginAndData: Bool,
        completion: (() -> Void)? = nil
    ) {
        URLCache.shared.removeAllCachedResponses()

        let store = WKWebsiteDataStore.default()
        let group = DispatchGroup()

        if cache {
            group.enter()
            store.removeData(ofTypes: Self.cacheDataTypes, modifiedSince: .distantPast) {
                group.leave()
            }
        }

        if loginAndData {
            group.enter()

            if let sharedCookies = HTTPCookieStorage.shared.cookies {
                for c in sharedCookies {
                    if !CookieLockStore.shared.isCookieProtected(cookieDomain: c.domain) {
                        HTTPCookieStorage.shared.deleteCookie(c)
                    }
                }
            }

            store.fetchDataRecords(ofTypes: Self.nonCookieLoginDataTypes) { records in
                let unprotectedRecords = records.filter { record in
                    !CookieLockStore.shared.isRecordLoginProtected(recordDisplayName: record.displayName)
                }

                let subGroup = DispatchGroup()

                if !unprotectedRecords.isEmpty {
                    subGroup.enter()
                    store.removeData(ofTypes: Self.nonCookieLoginDataTypes, for: unprotectedRecords) {
                        subGroup.leave()
                    }
                }

                subGroup.enter()
                store.httpCookieStore.getAllCookies { cookies in
                    let cookieGroup = DispatchGroup()
                    for c in cookies {
                        if !CookieLockStore.shared.isCookieProtected(cookieDomain: c.domain) {
                            cookieGroup.enter()
                            store.httpCookieStore.delete(c) {
                                cookieGroup.leave()
                            }
                        }
                    }
                    cookieGroup.notify(queue: .main) {
                        subGroup.leave()
                    }
                }

                subGroup.notify(queue: .main) {
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            completion?()
        }
    }

    func cleanCacheOnly(completion: (() -> Void)? = nil) {
        clean(cache: true, loginAndData: false, completion: completion)
    }

    func cleanUnprotectedLoginAndData(completion: (() -> Void)? = nil) {
        clean(cache: true, loginAndData: true, completion: completion)
    }

    func cleanSingleDomain(record: WKWebsiteDataRecord, cacheOnly: Bool, completion: (() -> Void)? = nil) {
        let store = WKWebsiteDataStore.default()

        if cacheOnly {
            store.removeData(ofTypes: Self.cacheDataTypes, for: [record]) {
                DispatchQueue.main.async {
                    completion?()
                }
            }
        } else {
            let nonCookieTypes = Self.nonCookieLoginDataTypes.union(Self.cacheDataTypes)
            store.removeData(ofTypes: nonCookieTypes, for: [record]) {
                store.httpCookieStore.getAllCookies { cookies in
                    let group = DispatchGroup()
                    for c in cookies where !CookieLockStore.shared.isCookieProtected(cookieDomain: c.domain) &&
                                          (c.domain.contains(record.displayName) || record.displayName.contains(c.domain)) {
                        group.enter()
                        store.httpCookieStore.delete(c) {
                            group.leave()
                        }
                    }
                    group.notify(queue: .main) {
                        completion?()
                    }
                }
            }
        }
    }
}
