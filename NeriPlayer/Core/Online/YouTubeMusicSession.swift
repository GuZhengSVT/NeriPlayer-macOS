// YouTubeMusicSession.swift
// M5-T7: cookie validation, authenticated request headers and account-bound bootstrap cache.
import CryptoKit
import Foundation

public enum YouTubeMusicCookies {
    /// Import a Cookie request header, not a browser profile or Set-Cookie response.
    public static func normalized(_ header: String) throws -> String {
        guard header.utf8.count <= 65_536, !header.contains("\r"), !header.contains("\n") else {
            throw OnlineError.invalidInput("Cookie header 格式无效")
        }
        var cookies: [String: String] = [:]
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw OnlineError.invalidInput("请输入 Cookie 请求头，不是 Set-Cookie 或 JSON") }
            let name = pair[0].trimmingCharacters(in: .whitespaces)
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }),
                  !value.isEmpty, !value.contains("\u{0}") else { throw OnlineError.invalidInput("Cookie header 格式无效") }
            cookies[name] = value
        }
        guard !cookies.isEmpty else { throw OnlineError.invalidInput("Cookie header 不能为空") }
        return cookies.keys.sorted().map { "\($0)=\(cookies[$0] ?? "")" }.joined(separator: "; ")
    }

    static func values(_ header: String?) -> [String: String] {
        var result: [String: String] = [:]
        for part in (header ?? "").split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        return result
    }

    static func fingerprint(_ header: String?) -> String {
        let normalized = (try? header.map(normalized)) ?? "anonymous"
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func authorization(cookie: String?, origin: String, userSessionID: String, now: Date) -> String? {
        let cookies = values(cookie)
        let primary = cookies["SAPISID"] ?? cookies["__Secure-3PAPISID"] ?? cookies["__Secure-1PAPISID"] ?? cookies["APISID"]
        let sources = [("SAPISIDHASH", primary), ("SAPISID1PHASH", cookies["__Secure-1PAPISID"]),
                       ("SAPISID3PHASH", cookies["__Secure-3PAPISID"])]
        let timestamp = String(Int64(max(0, now.timeIntervalSince1970)))
        let headers = sources.compactMap { scheme, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            let prefix = userSessionID.isEmpty ? "" : userSessionID + " "
            let digest = Insecure.SHA1.hash(data: Data("\(prefix)\(timestamp) \(value) \(origin)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            return "\(scheme) \(timestamp)_\(digest)\(userSessionID.isEmpty ? "" : "_u")"
        }
        return headers.isEmpty ? nil : headers.joined(separator: " ")
    }
}

struct YouTubeMusicBootstrap: Codable, Equatable, Sendable {
    static let snapshotVersion = 1
    var version = snapshotVersion
    var apiKey: String
    var clientVersion: String
    var visitorData: String
    var sessionIndex: String
    var userSessionID: String
    var loggedIn: Bool
    var playerScriptURL: URL?
    var signatureTimestamp: Int?
    var authFingerprint: String
    var fetchedAt: Date

    func usable(fingerprint: String, now: Date, maximumAge: TimeInterval = 600) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return version == Self.snapshotVersion && authFingerprint == fingerprint && !apiKey.isEmpty
            && !clientVersion.isEmpty && !visitorData.isEmpty && age >= 0 && age < maximumAge
    }

    static func parse(html: String, fingerprint: String, now: Date) throws -> Self {
        let objects = configurationObjects(html)
        func value(_ names: [String]) -> Any? {
            for name in names {
                for object in objects { if let value = object[name] { return value } }
            }
            return nil
        }
        guard let api = value(["INNERTUBE_API_KEY", "innertubeApiKey"]) as? String, !api.isEmpty,
              let client = value(["INNERTUBE_CLIENT_VERSION", "INNERTUBE_CONTEXT_CLIENT_VERSION", "innertubeContextClientVersion"]) as? String,
              !client.isEmpty, let visitor = value(["VISITOR_DATA", "visitorData"]) as? String, !visitor.isEmpty else {
            throw OnlineError.unavailable("YouTube Music bootstrap 结构已变化或需要完成浏览器登录/同意页")
        }
        let script = value(["PLAYER_JS_URL"]) as? String ?? scriptPath(html)
        let playerURL = script.flatMap { URL(string: $0.replacingOccurrences(of: "\\/", with: "/"), relativeTo: URL(string: "https://music.youtube.com"))?.absoluteURL }
        let dataSyncID = value(["DATASYNC_ID", "datasyncId"]) as? String ?? ""
        let derivedUser = dataSyncID.split(separator: "||", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return Self(apiKey: api, clientVersion: client, visitorData: visitor,
                    sessionIndex: (value(["SESSION_INDEX"]) as? NSNumber)?.stringValue ?? (value(["SESSION_INDEX"]) as? String ?? "0"),
                    userSessionID: value(["USER_SESSION_ID"]) as? String ?? derivedUser,
                    loggedIn: value(["LOGGED_IN"]) as? Bool ?? false,
                    playerScriptURL: playerURL, signatureTimestamp: value(["STS", "signatureTimestamp"]) as? Int,
                    authFingerprint: fingerprint, fetchedAt: now)
    }

    private static func scriptPath(_ html: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: #"(?:\"jsUrl\"\s*:\s*|src\s*=\s*)[\"']([^\"']*/s/player/[^\"']+\.js)[\"']"#),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }

    private static func configurationObjects(_ html: String) -> [[String: Any]] {
        var results: [[String: Any]] = []
        var remaining = html.startIndex..<html.endIndex
        while let call = html.range(of: "ytcfg.set(", range: remaining) {
            var cursor = call.upperBound
            while cursor < html.endIndex, html[cursor].isWhitespace { cursor = html.index(after: cursor) }
            guard cursor < html.endIndex else { break }
            if html[cursor] == "{", let end = closingBrace(in: html, from: cursor),
               let data = String(html[cursor...end]).data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { results.append(object) }
            remaining = call.upperBound..<html.endIndex
        }
        return results
    }

    private static func closingBrace(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var quoted = false
        var escaped = false
        var cursor = start
        while cursor < text.endIndex {
            let character = text[cursor]
            if quoted {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }
}

/// Only bootstrap configuration and a one-way cookie fingerprint are persisted, never cookies.
struct YouTubeMusicBootstrapCache: Sendable {
    let url: URL?

    func load(fingerprint: String, now: Date) -> YouTubeMusicBootstrap? {
        guard let url, let data = try? Data(contentsOf: url), data.count < 65_536,
              let value = try? JSONDecoder().decode(YouTubeMusicBootstrap.self, from: data),
              value.usable(fingerprint: fingerprint, now: now, maximumAge: 43_200) else { return nil }
        return value
    }

    func save(_ value: YouTubeMusicBootstrap) {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            Log.net.debug("YouTube bootstrap cache saved")
        } catch { Log.net.error("YouTube bootstrap cache could not be saved") }
    }
}
