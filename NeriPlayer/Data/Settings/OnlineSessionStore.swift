// OnlineSessionStore.swift
// M5: account cookies stay in Keychain, never UserDefaults or playback snapshots.

import Foundation
import CryptoKit
import Security

public protocol OnlineCredentialStore: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func remove(account: String) throws
}

public enum CredentialStoreError: LocalizedError {
    case keychain(OSStatus), invalidCookie
    public var errorDescription: String? {
        switch self {
        case .keychain(let status): return "Keychain 操作失败（\(status)）"
        case .invalidCookie: return "Cookie 内容或所属域名无效"
        }
    }
}

public final class KeychainCredentialStore: OnlineCredentialStore, @unchecked Sendable {
    private let service: String
    public init(service: String = "moe.ouom.NeriPlayer.online") { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    public func read(account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        return result as? Data
    }
    public func write(_ data: Data, account: String) throws {
        let request = query(account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = request
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let inserted = SecItemAdd(insertion as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw CredentialStoreError.keychain(inserted) }
        } else if status != errSecSuccess { throw CredentialStoreError.keychain(status) }
    }
    public func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }
    }
}

public final class OnlineSessionStore: @unchecked Sendable {
    public static let shared = OnlineSessionStore()
    private let credentials: any OnlineCredentialStore
    private let lock = NSLock()
    private var versions: [MusicSource: UUID] = [:]
    public init(credentials: any OnlineCredentialStore = KeychainCredentialStore()) { self.credentials = credentials }

    public func cookieHeader(for source: MusicSource) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try credentials.read(account: source.rawValue) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public func saveCookieHeader(_ value: String, for source: MusicSource) throws {
        let normalized = try Self.normalizedCookieHeader(value, source: source)
        let oldContext = try? cacheContext(for: source)
        let newContext = Self.cacheContext(normalized)
        lock.lock()
        do {
            try credentials.write(Data(normalized.utf8), account: source.rawValue)
        } catch {
            lock.unlock()
            throw error
        }
        versions[source] = UUID()
        lock.unlock()
        if oldContext != newContext {
            NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["source": source])
        }
        Log.net.info("在线会话已保存到 Keychain：\(source.rawValue, privacy: .public)")
    }
    public func clear(_ source: MusicSource) throws {
        lock.lock()
        do {
            try credentials.remove(account: source.rawValue)
        } catch {
            lock.unlock()
            throw error
        }
        versions[source] = UUID()
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["source": source])
        Log.net.info("在线会话已清除：\(source.rawValue, privacy: .public)")
    }
    public func version(for source: MusicSource) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return versions[source]
    }

    static let didChange = Notification.Name("NeriPlayer.onlineSessionChanged")

    // Only a digest leaves Keychain; it is stable across launches and never logged.
    func cacheContext(for source: MusicSource) throws -> String {
        guard let cookie = try cookieHeader(for: source), !cookie.isEmpty else { return "anonymous" }
        return Self.cacheContext(cookie)
    }

    private static func cacheContext(_ cookie: String) -> String {
        SHA256.hash(data: Data(cookie.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // Accept a raw Cookie header or a Netscape cookie export; filter exports by platform domain and expiry.
    // Raw headers and Netscape exports share the final strict cookie validation.
    // swiftlint:disable:next cyclomatic_complexity
    public static func normalizedCookieHeader(_ input: String, source: MusicSource, now: Date = Date()) throws -> String {
        guard input.utf8.count <= 262_144 else { throw CredentialStoreError.invalidCookie }
        var pairs: [(String, String)] = []
        let rows = input.components(separatedBy: .newlines)
        let isExport = rows.contains { $0.split(separator: "\t", omittingEmptySubsequences: false).count == 7 }
        if isExport {
            for raw in rows {
                let row = raw.hasPrefix("#HttpOnly_") ? String(raw.dropFirst(10)) : raw
                if row.hasPrefix("#") { continue }
                let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 7, allowedDomain(fields[0], source: source) else { continue }
                if let expiry = Double(fields[4]), expiry > 0, expiry <= now.timeIntervalSince1970 { continue }
                pairs.append((fields[5], fields[6]))
            }
        } else {
            var header = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if header.lowercased().hasPrefix("cookie:") { header = String(header.dropFirst(7)) }
            guard !header.contains("\r"), !header.contains("\n") else { throw CredentialStoreError.invalidCookie }
            for pair in header.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { throw CredentialStoreError.invalidCookie }
                pairs.append((parts[0].trimmingCharacters(in: .whitespaces), String(parts[1]).trimmingCharacters(in: .whitespaces)))
            }
        }
        var result: [String: String] = [:]
        let forbidden = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t\r\n")
        for (key, value) in pairs {
            guard !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f && !forbidden.contains($0) }),
                  value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7f && $0 != ";" }) else {
                throw CredentialStoreError.invalidCookie
            }
            result[key] = value
        }
        guard !result.isEmpty else { throw CredentialStoreError.invalidCookie }
        return result.keys.sorted().map { "\($0)=\(result[$0] ?? "")" }.joined(separator: "; ")
    }
    private static func allowedDomain(_ value: String, source: MusicSource) -> Bool {
        let domain = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let suffix: String
        switch source {
        case .netease: suffix = "music.163.com"
        case .bilibili: suffix = "bilibili.com"
        case .youtubeMusic: suffix = "youtube.com"
        }
        return domain == suffix || domain.hasSuffix("." + suffix)
    }
}
