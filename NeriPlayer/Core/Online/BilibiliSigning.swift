// BilibiliSigning.swift
// M5-T3: deterministic Bilibili WBI query signing and multipart video identities.
import CryptoKit
import Foundation

public struct BilibiliVideoIdentity: Equatable, Sendable {
    public let bvid: String
    public let page: Int

    public init(sourceID: String) throws {
        let parts = sourceID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { throw OnlineError.invalidInput("Invalid Bilibili video identity") }
        let identifier = String(parts[0])
        guard identifier.count == 12, identifier.hasPrefix("BV"), identifier.allSatisfy({ $0.isASCII && $0.isLetter || $0.isASCII && $0.isNumber }) else {
            throw OnlineError.invalidInput("Invalid Bilibili BV identifier")
        }
        let requestedPage = parts.count == 2 ? Int(parts[1]) : 1
        guard let page = requestedPage, (1...10_000).contains(page) else {
            throw OnlineError.invalidInput("Invalid Bilibili page")
        }
        bvid = identifier
        self.page = page
    }

    public var sourceID: String { "\(bvid):\(page)" }
    public var pageURL: URL? { URL(string: "https://www.bilibili.com/video/\(bvid)?p=\(page)") }
}

public enum BilibiliSigning {
    private static let indices = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 62, 6, 63, 57, 20, 34, 52, 59, 11, 36, 44
    ]
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func mixinKey(imageURL: String, subURL: String) throws -> String {
        guard let image = URL(string: imageURL), let sub = URL(string: subURL) else { throw OnlineError.invalidResponse }
        let raw = Array((image.deletingPathExtension().lastPathComponent + sub.deletingPathExtension().lastPathComponent).utf8)
        guard raw.count == 64, raw.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw OnlineError.invalidResponse
        }
        return String(bytes: indices.prefix(32).map { raw[$0] }, encoding: .utf8) ?? ""
    }

    /// URI escaping is identical for hashing and the final URL; values remove !'()* per WBI.
    public static func signedQuery(parameters: [String: String], mixinKey: String, timestamp: Int64) throws -> String {
        guard mixinKey.utf8.count == 32, timestamp >= 0 else { throw OnlineError.invalidInput("Invalid WBI signing input") }
        var values = parameters.mapValues { value in String(value.filter { !"!'()*".contains($0) }) }
        values.removeValue(forKey: "w_rid")
        values["wts"] = String(timestamp)
        let query = queryString(values)
        let digest = Insecure.MD5.hash(data: Data((query + mixinKey).utf8))
        let signature = digest.map { String(format: "%02x", $0) }.joined()
        return query + "&w_rid=" + signature
    }

    static func queryString(_ parameters: [String: String]) -> String {
        parameters.keys.sorted().map { "\(encode($0))=\(encode(parameters[$0] ?? ""))" }.joined(separator: "&")
    }

    private static func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
}
