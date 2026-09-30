// BilibiliParsing.swift
// M5-T3: Bili-only normalization, media selection and cookie parsing helpers.
import Foundation

internal enum BilibiliParsing {
    static func endpoint(host: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        return components.url ?? URL(fileURLWithPath: "/")
    }

    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return Int(number.stringValue) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func positiveID(_ value: Any?) -> String? {
        let string: String
        if let number = value as? NSNumber { string = number.stringValue } else if let value = value as? String { string = value } else { return nil }
        guard let number = Int64(string), number > 0 else { return nil }
        return String(number)
    }

    static func duration(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var result: Double = 0
        for part in parts {
            guard let number = Double(part), number.isFinite, number >= 0 else { return nil }
            result = result * 60 + number
        }
        return result.isFinite ? result : nil
    }

    static func httpURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, !raw.contains("\r"), !raw.contains("\n") else { return nil }
        let value = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func plainText(_ html: String) -> String {
        let text = html.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&quot;": "\"", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        guard let expression = try? NSRegularExpression(pattern: #"&(?:amp|quot|apos|lt|gt|nbsp|#[0-9]+|#x[0-9a-fA-F]+);"#) else { return text }
        var output = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let token = String(output[range])
            if let replacement = entities[token] { output.replaceSubrange(range, with: replacement); continue }
            let hex = token.hasPrefix("&#x")
            let digits = token.dropFirst(hex ? 3 : 2).dropLast()
            if let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = UnicodeScalar(value) {
                output.replaceSubrange(range, with: String(scalar))
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func partMetadata(_ part: String, fallbackArtist: String) -> (title: String, artist: String) {
        let clean = plainText(part).replacingOccurrences(of: #"^\d+\.\s*"#, with: "", options: .regularExpression)
        guard let expression = try? NSRegularExpression(pattern: #"\s[-\u2013\u2014]\s"#) else { return (clean, fallbackArtist) }
        let matches = expression.matches(in: clean, range: NSRange(clean.startIndex..., in: clean))
        guard matches.count == 1, let range = Range(matches[0].range, in: clean) else { return (clean, fallbackArtist) }
        let title = String(clean[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let artist = String(clean[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return title.isEmpty || artist.isEmpty ? (clean, fallbackArtist) : (title, artist)
    }

    static func audioURL(_ data: [String: Any]) -> URL? {
        let dash = data["dash"] as? [String: Any] ?? [:]
        let flac = (dash["flac"] as? [String: Any])?["audio"] as? [String: Any]
        let dolby = (dash["dolby"] as? [String: Any])?["audio"] as? [[String: Any]] ?? []
        let standard = dash["audio"] as? [[String: Any]] ?? []
        struct AudioCandidate { let url: URL; let priority: Int; let bandwidth: Int }
        var candidates: [AudioCandidate] = []
        for (priority, tracks) in [(3, flac.map { [$0] } ?? []), (2, dolby), (1, standard)] {
            for track in tracks {
                let base = track["baseUrl"] as? String ?? track["base_url"] as? String
                let backups = track["backupUrl"] as? [String] ?? track["backup_url"] as? [String] ?? []
                let urls = [base].compactMap { $0 } + backups
                guard let url = urls.compactMap({ httpURL($0) }).first else { continue }
                candidates.append(AudioCandidate(url: url, priority: priority, bandwidth: integer(track["bandwidth"]) ?? 0))
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.bandwidth > rhs.bandwidth
        }
        if let best = candidates.first { return best.url }
        // Multiple progressive fragments cannot be represented by ResolvedAudio's one URL.
        let progressive = data["durl"] as? [[String: Any]] ?? []
        guard progressive.count == 1 else { return nil }
        let item = progressive[0]
        let urls = [item["url"] as? String].compactMap { $0 }
            + (item["backup_url"] as? [String] ?? item["backupUrl"] as? [String] ?? [])
        return urls.compactMap { httpURL($0) }.first
    }

    static func expiry(_ url: URL) -> Date? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for name in ["deadline", "expires", "expire"] {
            guard let value = items.first(where: { $0.name == name })?.value,
                  let timestamp = Double(value), timestamp.isFinite, timestamp > 0 else { continue }
            return Date(timeIntervalSince1970: timestamp)
        }
        return nil
    }

    static func cookies(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = String(pair[0]).trimmingCharacters(in: .whitespaces)
            let value = String(pair[1]).trimmingCharacters(in: .whitespaces)
            if validCookie(name: name, value: value) { result[name] = value }
        }
        return result
    }

    static func cookieHeader(_ cookies: [String: String]) -> String {
        cookies.keys.sorted().compactMap { name in
            guard let value = cookies[name], validCookie(name: name, value: value) else { return nil }
            return name + "=" + value
        }.joined(separator: "; ")
    }

    private static func validCookie(name: String, value: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }
            && !value.contains("\r") && !value.contains("\n") && !value.contains(";")
    }

    static func responseCookies(_ response: HTTPURLResponse) -> [String: String] {
        guard let url = response.url else { return [:] }
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String { headers[name] = String(describing: value) }
        }
        var result: [String: String] = [:]
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
            where validCookie(name: cookie.name, value: cookie.value) {
            result[cookie.name] = cookie.value
        }
        return result
    }

    static func loginURLCookies(_ raw: String?) -> [String: String] {
        guard let raw, let components = URLComponents(string: raw),
              let host = components.host, host == "bilibili.com" || host.hasSuffix(".bilibili.com") else { return [:] }
        let allowed = Set(["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"])
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if allowed.contains(item.name), let value = item.value, validCookie(name: item.name, value: value) {
                result[item.name] = value
            }
        }
        return result
    }
}
