// PlaybackStats.swift
// NeriPlayer macOS —— 播放统计的值类型（移植规划 M3-T1）。
//
// 与 PlayHistory 同属 Core 词汇：纯值类型，不 import GRDB；GRDB 侧的
// PlaybackStatsRecord / PlaybackStatsDailyBucketRecord 负责列映射。
//
// 语义参考 Android 原库 playback_stat / playback_stat_bucket（schemas/18.json）：
//   - playback_stat：一首歌一行累计值 —— 累计收听时长、播放次数、首次/最近播放时间；
//   - playback_stat_bucket：按「天」切分的同一批计数，(day_start_at, identity_key) 复合主键，
//     供「最近七天/本月/今年」这类时间窗统计聚合使用（原库保留 400 天、最多 8000 桶）。
// 本任务把两表都落成 macOS 版本（任务要求 PlaybackStats 含「每日桶」）。
//
// 计数口径（原库语义；写入管道属 M3-T2，此处只定义模型）：
//   - 收听时长按真实播放时长累加；
//   - 播放次数只在单次播放达到阈值（30s）后才 +1，避免「划过即计数」；
//   - firstPlayedAt 取首次（保留最小值），lastPlayedAt 取最近（保留最大值）。
// 时间单位从原库的毫秒改为秒：macOS 侧播放链路本身以秒为单位（Track.duration、
// PlayerEngine 的 position 都是秒），统一单位可以免去每次读写的换算。
//
// 每日桶的 dayStart 用本地时间的当天零点而不是 UTC 零点：用户看到的「今天听了多久」
// 按本地日历分天才有意义，原库 playbackStatsDayStartAt 亦基于设备本地时区。

import Foundation

/// 播放统计中「单次播放达到该时长才计一次播放次数」的阈值（秒）。对齐原库 30s 口径。
public let playbackStatsPlayCountThresholdSeconds: Double = 30

/// 一首曲目的累计播放统计。
public struct PlaybackStats: Equatable, Sendable {

    /// 曲目标识。对应 Track.id，同时是本表主键（一首歌一行）。
    public var trackId: UUID
    /// 累计收听时长（秒）。
    public var totalListenSeconds: Double
    /// 达到计数阈值的累计播放次数。
    public var playCount: Int
    /// 首次播放时间；理论上非空，异常数据下允许为 nil。
    public var firstPlayedAt: Date?
    /// 最近一次播放时间。按此列倒序即「最近播放」。
    public var lastPlayedAt: Date?

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
    }
}

/// 某一天的播放统计桶：与 PlaybackStats 同字段，但被限定在一个自然日内。
///
/// 复合主键 (trackId, dayStart) 决定「同一天同一首歌只有一行」；写入时的累加语义由
/// M3-T2 的管道负责，本层只保证约束成立。
public struct PlaybackStatsDailyBucket: Equatable, Sendable {

    /// 该桶所属自然日的本地零点。
    public var dayStart: Date
    /// 曲目标识。
    public var trackId: UUID
    /// 当日累计收听时长（秒）。
    public var totalListenSeconds: Double
    /// 当日累计播放次数（达到阈值才计）。
    public var playCount: Int
    /// 当日内首次播放时间。
    public var firstPlayedAt: Date?
    /// 当日内最近播放时间。
    public var lastPlayedAt: Date?

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
    }

    /// 求给定时刻所属自然日的本地零点。写入管道与查询窗口都用它把绝对时间折算成桶键。
    ///
    /// - Parameters:
    ///   - date: 待折算的时刻。
    ///   - calendar: 本地日历（默认当前时区）；传入固定时区的日历可让测试跨时区稳定。
    public static func dayStart(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }
}
