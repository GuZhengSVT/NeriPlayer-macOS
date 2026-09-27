// PlaybackRecords.swift
// NeriPlayer macOS —— M3-T1 的 GRDB 记录类型（播放历史 / 播放统计 / 播放器现场）。
//
// 分层约定（与 Records.swift 一致）：Core 层的值类型不 import GRDB，本文件是它们在
// 数据库里的镜像 —— 每个 Record 提供一个「由值类型构造」与一个「转回值类型」的入口，
// Repository 与 UI 只面对 Core 值类型。
//
// 时间列沿用 GRDB 的 Date 默认编码（"YYYY-MM-DD HH:MM:SS.SSS" 字符串，按 UTC 存取）。
//
// PlayerState 的队列列存 JSON：队列可以包含尚未入库的临时项（拖入即播的文件），
// 用外键指向 Track 反而会在重启后丢现场，因此把 Track 的五个字段原样序列化。
// JSON 的编解码放在 Record 内部：Core 不需要知道这份序列化格式，未来换编码也只改这里。

import Foundation
import GRDB

// MARK: - 播放历史

/// PlayHistory 表的 GRDB 记录。trackId 即主键：一首歌最多一行历史。
public final class PlayHistoryRecord: Record {

    /// 曲目标识，主键，同时对 Track.id 有外键（级联删除）。
    public var trackId: UUID
    /// 最后一次播放时刻。
    public var playedAt: Date
    /// 记忆播放位置（秒）。
    public var resumePositionSeconds: Double

    public override static var databaseTableName: String { DatabaseSchema.playHistory }

    public init(trackId: UUID, playedAt: Date = Date(), resumePositionSeconds: Double = 0) {
        self.trackId = trackId
        self.playedAt = playedAt
        self.resumePositionSeconds = resumePositionSeconds
        super.init()
    }

    /// 由 Core 值类型构造。
    public convenience init(entry: PlayHistoryEntry) {
        self.init(
            trackId: entry.trackId,
            playedAt: entry.playedAt,
            resumePositionSeconds: entry.resumePositionSeconds
        )
    }

    public required init(row: Row) throws {
        self.trackId = row["trackId"]
        self.playedAt = row["playedAt"]
        self.resumePositionSeconds = row["resumePositionSeconds"]
        try super.init(row: row)
    }

    public override func encode(to container: inout PersistenceContainer) throws {
        container["trackId"] = trackId
        container["playedAt"] = playedAt
        container["resumePositionSeconds"] = resumePositionSeconds
    }

    /// 转回 Core 值类型。
    public var entry: PlayHistoryEntry {
        PlayHistoryEntry(
            trackId: trackId,
            playedAt: playedAt,
            resumePositionSeconds: resumePositionSeconds
        )
    }
}

// MARK: - 播放统计

/// PlaybackStats 表的 GRDB 记录。trackId 即主键：一首歌一行累计值。
public final class PlaybackStatsRecord: Record {

    public var trackId: UUID
    public var totalListenSeconds: Double
    public var playCount: Int
    public var firstPlayedAt: Date?
    public var lastPlayedAt: Date?

    public override static var databaseTableName: String { DatabaseSchema.playbackStats }

    public init(
        trackId: UUID,
        totalListenSeconds: Double = 0,
        playCount: Int = 0,
        firstPlayedAt: Date? = nil,
        lastPlayedAt: Date? = nil
    ) {
        self.trackId = trackId
        self.totalListenSeconds = totalListenSeconds
        self.playCount = playCount
        self.firstPlayedAt = firstPlayedAt
        self.lastPlayedAt = lastPlayedAt
        super.init()
    }

    public convenience init(stats: PlaybackStats) {
        self.init(
            trackId: stats.trackId,
            totalListenSeconds: stats.totalListenSeconds,
            playCount: stats.playCount,
            firstPlayedAt: stats.firstPlayedAt,
            lastPlayedAt: stats.lastPlayedAt
        )
    }

    public required init(row: Row) throws {
        self.trackId = row["trackId"]
        self.totalListenSeconds = row["totalListenSeconds"]
        self.playCount = row["playCount"]
        self.firstPlayedAt = row["firstPlayedAt"]
        self.lastPlayedAt = row["lastPlayedAt"]
        try super.init(row: row)
    }

    public override func encode(to container: inout PersistenceContainer) throws {
        container["trackId"] = trackId
        container["totalListenSeconds"] = totalListenSeconds
        container["playCount"] = playCount
        container["firstPlayedAt"] = firstPlayedAt
        container["lastPlayedAt"] = lastPlayedAt
    }

    public var stats: PlaybackStats {
        PlaybackStats(
            trackId: trackId,
            totalListenSeconds: totalListenSeconds,
            playCount: playCount,
            firstPlayedAt: firstPlayedAt,
            lastPlayedAt: lastPlayedAt
        )
    }
}

/// PlaybackStatsDailyBucket 表的 GRDB 记录。(dayStart, trackId) 复合主键。
public final class PlaybackStatsDailyBucketRecord: Record {

    public var dayStart: Date
    public var trackId: UUID
    public var totalListenSeconds: Double
    public var playCount: Int
    public var firstPlayedAt: Date?
    public var lastPlayedAt: Date?

    public override static var databaseTableName: String { DatabaseSchema.playbackStatsDailyBucket }

    public init(
        dayStart: Date,
        trackId: UUID,
        totalListenSeconds: Double = 0,
        playCount: Int = 0,
        firstPlayedAt: Date? = nil,
        lastPlayedAt: Date? = nil
    ) {
        self.dayStart = dayStart
        self.trackId = trackId
        self.totalListenSeconds = totalListenSeconds
        self.playCount = playCount
        self.firstPlayedAt = firstPlayedAt
        self.lastPlayedAt = lastPlayedAt
        super.init()
    }

    public convenience init(bucket: PlaybackStatsDailyBucket) {
        self.init(
            dayStart: bucket.dayStart,
            trackId: bucket.trackId,
            totalListenSeconds: bucket.totalListenSeconds,
            playCount: bucket.playCount,
            firstPlayedAt: bucket.firstPlayedAt,
            lastPlayedAt: bucket.lastPlayedAt
        )
    }

    public required init(row: Row) throws {
        self.dayStart = row["dayStart"]
        self.trackId = row["trackId"]
        self.totalListenSeconds = row["totalListenSeconds"]
        self.playCount = row["playCount"]
        self.firstPlayedAt = row["firstPlayedAt"]
        self.lastPlayedAt = row["lastPlayedAt"]
        try super.init(row: row)
    }

    public override func encode(to container: inout PersistenceContainer) throws {
        container["dayStart"] = dayStart
        container["trackId"] = trackId
        container["totalListenSeconds"] = totalListenSeconds
        container["playCount"] = playCount
        container["firstPlayedAt"] = firstPlayedAt
        container["lastPlayedAt"] = lastPlayedAt
    }

    public var bucket: PlaybackStatsDailyBucket {
        PlaybackStatsDailyBucket(
            dayStart: dayStart,
            trackId: trackId,
            totalListenSeconds: totalListenSeconds,
            playCount: playCount,
            firstPlayedAt: firstPlayedAt,
            lastPlayedAt: lastPlayedAt
        )
    }
}

// MARK: - 播放器现场

/// PlayerState 表的 GRDB 记录。单行表：id 恒为 PlayerStateRecord.singletonID。
public final class PlayerStateRecord: Record {

    /// 单行表固定主键。Repository 只读写这一行。
    public static let singletonID = 1

    public var id: Int
    /// 当前索引；空队列为 nil。
    public var currentIndex: Int?
    /// 播放位置（秒）。
    public var position: Double
    /// 播放模式（PlaybackMode.rawValue）。
    public var mode: String
    /// 队列 JSON（PlayerStateCodec 负责编解码）。
    public var queue: String
    /// 随机序列 JSON（UUID 字符串数组）。
    public var shuffleOrder: String
    public var updatedAt: Date

    public override static var databaseTableName: String { DatabaseSchema.playerState }

    public init(
        id: Int = PlayerStateRecord.singletonID,
        currentIndex: Int?,
        position: Double,
        mode: String,
        queue: String,
        shuffleOrder: String,
        updatedAt: Date
    ) {
        self.id = id
        self.currentIndex = currentIndex
        self.position = position
        self.mode = mode
        self.queue = queue
        self.shuffleOrder = shuffleOrder
        self.updatedAt = updatedAt
        super.init()
    }

    /// 由 Core 值类型构造（队列/随机序列在此序列化成 JSON）。
    public convenience init(state: PlayerState) {
        self.init(
            currentIndex: state.currentIndex,
            position: state.position,
            mode: state.mode.rawValue,
            queue: PlayerStateCodec.encodeQueue(state.tracks),
            shuffleOrder: PlayerStateCodec.encodeShuffleOrder(state.shuffleOrder),
            updatedAt: state.updatedAt
        )
    }

    public required init(row: Row) throws {
        self.id = row["id"]
        self.currentIndex = row["currentIndex"]
        self.position = row["position"]
        self.mode = row["mode"]
        self.queue = row["queue"]
        self.shuffleOrder = row["shuffleOrder"]
        self.updatedAt = row["updatedAt"]
        try super.init(row: row)
    }

    public override func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["currentIndex"] = currentIndex
        container["position"] = position
        container["mode"] = mode
        container["queue"] = queue
        container["shuffleOrder"] = shuffleOrder
        container["updatedAt"] = updatedAt
    }

    /// 转回 Core 值类型。JSON 列解析失败时退化为空队列/空序列（不抛错）——
    /// 现场是「锦上添花」的恢复数据，坏一列不应让整个读取路径失败。
    public var state: PlayerState {
        PlayerState(
            tracks: PlayerStateCodec.decodeQueue(queue),
            currentIndex: currentIndex,
            position: position,
            mode: PlaybackMode(rawValue: mode) ?? .sequential,
            shuffleOrder: PlayerStateCodec.decodeShuffleOrder(shuffleOrder),
            updatedAt: updatedAt
        )
    }
}

// MARK: - JSON 编解码

/// PlayerState 的队列列与随机序列列的编解码。
///
/// 独立成 enum（无实例）而不是塞进 Record：编解码格式是存储细节，集中在一处便于将来演进
/// （例如加字段时保持向后兼容）。解码一律「尽力而为」：坏 JSON 返回空值而不抛错。
enum PlayerStateCodec {

    /// 队列中单个 Track 的序列化形态。
    private struct TrackPayload: Codable {
        var id: UUID
        var url: String
        var title: String
        var artist: String?
        var duration: Double?
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Track 数组 → JSON 字符串。
    static func encodeQueue(_ tracks: [Track]) -> String {
        let payloads = tracks.map {
            TrackPayload(
                id: $0.id,
                url: $0.url.absoluteString,
                title: $0.title,
                artist: $0.artist,
                duration: $0.duration
            )
        }
        guard let data = try? encoder.encode(payloads),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// JSON 字符串 → Track 数组；空串或坏数据返回空数组。
    static func decodeQueue(_ json: String) -> [Track] {
        guard let data = json.data(using: .utf8),
              let payloads = try? decoder.decode([TrackPayload].self, from: data) else {
            return []
        }
        return payloads.map {
            Track(
                id: $0.id,
                url: URL(string: $0.url) ?? URL(fileURLWithPath: $0.url),
                title: $0.title,
                artist: $0.artist,
                duration: $0.duration
            )
        }
    }

    /// UUID 数组 → JSON 字符串。
    static func encodeShuffleOrder(_ order: [UUID]) -> String {
        guard let data = try? encoder.encode(order),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// JSON 字符串 → UUID 数组；空串或坏数据返回空数组。
    static func decodeShuffleOrder(_ json: String) -> [UUID] {
        guard let data = json.data(using: .utf8),
              let order = try? decoder.decode([UUID].self, from: data) else {
            return []
        }
        return order
    }
}
