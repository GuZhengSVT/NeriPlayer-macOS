// NeteaseHomeSections.swift
// 首页分区来源、登录门槛与雷达歌单清单。
// 行为参考：NeriPlayer Android `ui/viewmodel/tab/NeteaseHomeRecommendations.kt`（GPL-3.0-or-later）。
import Foundation

/// 首页推荐歌单分区的来源。与 Android `NeteaseHomePlaylistSource` 一一对应。
public enum NeteaseHomePlaylistSource: String, CaseIterable, Hashable, Sendable {
    case personalized
    case dailyResource
    case highQuality
    case hotPlaylists
    case acgPlaylists

    public var title: String {
        switch self {
        case .personalized: return "推荐歌单"
        case .dailyResource: return "每日推荐歌单"
        case .highQuality: return "精品歌单"
        case .hotPlaylists: return "热门歌单"
        case .acgPlaylists: return "ACG 歌单"
        }
    }

    public var requiresLogin: Bool { self == .dailyResource }
}

/// 首页歌曲分区的来源。与 Android `NeteaseHomeSongSource` 一一对应。
public enum NeteaseHomeSongSource: String, CaseIterable, Hashable, Sendable {
    case topSoaring
    case personalRadar
    case dailyRecommend
    case privateFM
    case personalizedNewSongs
    case topHot
    case topNew

    public var title: String {
        switch self {
        case .topSoaring: return "飙升榜"
        case .personalRadar: return "私人雷达"
        case .dailyRecommend: return "每日推荐"
        case .privateFM: return "私人 FM"
        case .personalizedNewSongs: return "新歌推荐"
        case .topHot: return "热歌榜"
        case .topNew: return "新歌榜"
        }
    }

    public var requiresLogin: Bool { self == .dailyRecommend || self == .privateFM }
}

/// 官方榜单单曲 ID（与 Android 常量一致）。
public let neteasePrivateRadarPlaylistID = "3136952023"
public let neteaseToplistSoaringID = "19723756"
public let neteaseToplistNewID = "3779629"
public let neteaseToplistHotID = "3778678"

public let neteaseHomePlaylistSources: [NeteaseHomePlaylistSource] = [
    .personalized, .dailyResource, .highQuality, .hotPlaylists, .acgPlaylists
]

public let neteaseHomeTrendingSongSources: [NeteaseHomeSongSource] = [
    .topSoaring, .personalizedNewSongs, .topHot, .topNew
]

public let neteaseHomeRadarSongSources: [NeteaseHomeSongSource] = [
    .personalRadar, .dailyRecommend, .privateFM
]

/// 单分区曲目上限。Android 使用同一数值，避免首页一次拉取整张榜单。
public let neteaseHomeSectionSongLimit = 30
public let neteaseHomeSectionPlaylistLimit = 30

/// 私人 FM 多批次的合并上限，与 Android `HOME_PRIVATE_FM_MAX_BATCHES` 对齐。
public let neteaseHomePrivateFmMaxBatches = 10

public func availableNeteaseHomePlaylistSources(
    _ candidates: [NeteaseHomePlaylistSource],
    hasLogin: Bool
) -> [NeteaseHomePlaylistSource] {
    candidates.filter { !$0.requiresLogin || hasLogin }
}

public func availableNeteaseHomeSongSources(
    _ candidates: [NeteaseHomeSongSource],
    hasLogin: Bool
) -> [NeteaseHomeSongSource] {
    candidates.filter { !$0.requiresLogin || hasLogin }
}

/// 雷达歌单：API 可用时取当前账号的标题与封面，失败时回落到这里的名称。
public struct NeteaseRadarPlaylistDefinition: Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public var fallbackCollection: OnlineCollection {
        OnlineCollection(source: .netease, sourceID: id, title: name)
    }
}

public let neteaseRadarPlaylistDefinitions: [NeteaseRadarPlaylistDefinition] = [
    NeteaseRadarPlaylistDefinition(id: "5320167908", name: "时光雷达"),
    NeteaseRadarPlaylistDefinition(id: "5362359247", name: "宝藏雷达"),
    NeteaseRadarPlaylistDefinition(id: "5300458264", name: "新歌雷达"),
    NeteaseRadarPlaylistDefinition(id: "5327906368", name: "乐迷雷达"),
    NeteaseRadarPlaylistDefinition(id: "5341776086", name: "神秘雷达")
]

public func isNeteaseRadarPlaylist(id: String) -> Bool {
    neteaseRadarPlaylistDefinitions.contains { $0.id == id }
}

/// 私人 FM 是多批次拉取的，这里保证合并结果不重复且不超上限。
public func appendUniqueNeteaseHomeSongs(current: [SongData], next: [SongData], limit: Int) -> [SongData] {
    guard limit > 0 else { return [] }
    var merged = current
    var seen = Set(current.map(\.id))
    for song in next {
        guard merged.count < limit else { break }
        if seen.insert(song.id).inserted { merged.append(song) }
    }
    return merged
}

/// 首页分区数据来源。NeteaseClient 实现该协议；测试与替身客户端也按同一契约实现。
public protocol NeteaseHomeProviding: Sendable {
    func homePlaylists(_ source: NeteaseHomePlaylistSource, limit: Int) async throws -> [OnlineCollection]
    func homeSongs(_ source: NeteaseHomeSongSource, limit: Int) async throws -> [SongData]
    func homeRadarPlaylists() async throws -> [OnlineCollection]
}
