// OnlineModels.swift
// M5: stable platform identities, normalized songs and online client contracts.

import Foundation

public enum MusicSource: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case netease, bilibili, youtubeMusic
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .netease: return "网易云"
        case .bilibili: return "Bilibili"
        case .youtubeMusic: return "YouTube Music"
        }
    }
}

public struct SongData: Identifiable, Codable, Hashable, Sendable {
    public var source: MusicSource
    public var sourceID: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double?
    public var artworkURL: URL?
    public var pageURL: URL?
    public var sourceSubID: String?
    public var sourceAudioID: String?
    public var id: String { "\(source.rawValue):\(sourceID)" }

    public init(source: MusicSource, sourceID: String, title: String, artist: String = "",
                album: String = "", duration: Double? = nil, artworkURL: URL? = nil, pageURL: URL? = nil) {
        self.source = source
        self.sourceID = sourceID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.artworkURL = artworkURL
        self.pageURL = pageURL
        self.sourceSubID = nil
        self.sourceAudioID = nil
    }

    public var identityURL: URL {
        var components = URLComponents()
        components.scheme = "neriplayer-online"
        components.host = source.rawValue
        components.path = "/" + sourceID
        // sourceID is escaped by URLComponents, including Bilibili page separators.
        return components.url ?? URL(fileURLWithPath: "/invalid-online-identity")
    }

    public func track(id: UUID = UUID()) -> Track {
        Track(id: id, url: identityURL, title: title, artist: artist, duration: duration, onlineSong: self)
    }
}

public struct OnlineCollection: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case playlist, album, favorites }
    public var source: MusicSource
    public var sourceID: String
    public var title: String
    public var subtitle: String
    public var artworkURL: URL?
    public var kind: Kind
    public var id: String { "\(source.rawValue):\(kind.rawValue):\(sourceID)" }
    public init(source: MusicSource, sourceID: String, title: String, subtitle: String = "",
                artworkURL: URL? = nil, kind: Kind = .playlist) {
        self.source = source; self.sourceID = sourceID; self.title = title
        self.subtitle = subtitle; self.artworkURL = artworkURL; self.kind = kind
    }
}

public struct ResolvedAudio: Equatable, Sendable {
    public var song: SongData
    public var url: URL
    public var headers: [String: String]
    public var expiresAt: Date?
    public init(song: SongData, url: URL, headers: [String: String] = [:], expiresAt: Date? = nil) {
        self.song = song; self.url = url; self.headers = headers; self.expiresAt = expiresAt
    }
}

public struct QRLoginTicket: Equatable, Sendable {
    public var key: String
    public var url: URL
    public init(key: String, url: URL) { self.key = key; self.url = url }
}

public enum QRLoginState: Equatable, Sendable {
    case waiting, scanned, expired, authorized
}

public struct OnlineAccount: Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum OnlineError: LocalizedError, Equatable {
    case invalidResponse, unavailable(String), authenticationRequired, unsupported(String), http(Int), invalidInput(String)
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "平台返回了无法解析的数据"
        case .unavailable(let message), .unsupported(let message), .invalidInput(let message): return message
        case .authenticationRequired: return "请先登录该平台"
        case .http(let code): return "网络请求失败（HTTP \(code)）"
        }
    }
}

public protocol OnlineMusicClient: Sendable {
    var source: MusicSource { get }
    func search(query: String, page: Int) async throws -> [SongData]
    func resolve(song: SongData) async throws -> ResolvedAudio
    func songs(in collection: OnlineCollection) async throws -> [SongData]
    func collections() async throws -> [OnlineCollection]
    func recommendations() async throws -> [SongData]
    func account() async throws -> OnlineAccount
    func beginQRLogin() async throws -> QRLoginTicket
    func pollQRLogin(_ ticket: QRLoginTicket) async throws -> QRLoginState
    func setFavorite(_ song: SongData, favorite: Bool) async throws
}

public extension OnlineMusicClient {
    func search(query: String) async throws -> [SongData] { try await search(query: query, page: 1) }
    func collections() async throws -> [OnlineCollection] { [] }
    func recommendations() async throws -> [SongData] { [] }
    func account() async throws -> OnlineAccount { throw OnlineError.authenticationRequired }
    func beginQRLogin() async throws -> QRLoginTicket { throw OnlineError.unsupported("此平台使用 Cookie 导入登录") }
    func pollQRLogin(_ ticket: QRLoginTicket) async throws -> QRLoginState { throw OnlineError.unsupported("此平台使用 Cookie 导入登录") }
    func setFavorite(_ song: SongData, favorite: Bool) async throws { throw OnlineError.unsupported("此平台暂不支持收藏写入") }
}
