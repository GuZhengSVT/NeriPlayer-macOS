// YouTubeMusicHome.swift
// YouTube Music 首页 shelf 模型与首页数据扩展。
// 行为参考：NeriPlayer Android `core/api/youtube/YouTubeMusicClient.kt` 的 getHomeFeed /
// parseHomePlaylistRecommendations（GPL-3.0-or-later）。
import Foundation

/// 首页推荐栏中的单个条目。它要么是可播放歌曲，要么是可打开的合集卡片。
public struct YouTubeMusicHomeItem: Identifiable, Codable, Hashable, Sendable {
    public let song: SongData?
    public let browseId: String
    private let collection: OnlineCollection?

    init(song: SongData, browseId: String) {
        self.song = song
        self.browseId = browseId
        collection = nil
    }

    init(collection: OnlineCollection) {
        song = nil
        browseId = collection.sourceID
        self.collection = collection
    }

    public var id: String { song?.id ?? "ytmusic:collection:\(browseId)" }
    public var title: String { song?.title ?? collection?.title ?? "" }
    public var subtitle: String { song?.artist ?? collection?.subtitle ?? "" }
    public var artworkURL: URL? { song?.artworkURL ?? collection?.artworkURL }
    public var asCollection: OnlineCollection? { collection }
}

public struct YouTubeMusicHomeShelf: Identifiable, Codable, Hashable, Sendable {
    public let title: String
    public let items: [YouTubeMusicHomeItem]

    public init(title: String, items: [YouTubeMusicHomeItem]) {
        self.title = title
        self.items = items
    }

    public var id: String { title }

    public var songs: [SongData] { items.compactMap(\.song) }
    public var collections: [OnlineCollection] { items.compactMap(\.asCollection) }
}

/// 首页 shelf 数据来源。YouTubeMusicClient 实现该协议；替身客户端也可按同一契约实现。
public protocol YouTubeMusicHomeProviding: Sendable {
    func homeShelves() async throws -> [YouTubeMusicHomeShelf]
}

extension YouTubeMusicClient: YouTubeMusicHomeProviding {
    /// 首页推荐栏。未登录时 YouTube 返回的是公开首页，已登录时返回账号个性化结果。
    public func homeShelves() async throws -> [YouTubeMusicHomeShelf] {
        let boot = try await bootstrap()
        let root = try await post("/youtubei/v1/browse", payload: ["browseId": "FEmusic_home"], boot: boot)
        return YouTubeMusicParser.homeShelves(root)
    }
}
