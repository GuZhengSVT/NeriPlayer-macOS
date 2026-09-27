// PlayHistory.swift
// NeriPlayer macOS —— 播放历史的值类型（移植规划 M3-T1）。
//
// 定位：与 Track / LibraryTrack 一样属于 Core 词汇 —— 纯值类型，不 import GRDB。
// GRDB 侧的 PlayHistoryRecord（Data/Database/PlaybackRecords.swift）负责与列互转，
// Repository 与 UI 只面对本类型。
//
// 语义参考 Android 原库 play_history（schemas/18.json）：一首歌一行，按键去重而不是
// 追加式日志 —— 原库以 identity_key 为主键，重复播放沿用同一行，只刷新 played_at 与记忆
// 播放位置。这样「最近播放」列表天然不重复，恢复现场时也能按 trackId 直接取到记忆位置。
// 本任务据此把主键定为 trackId（macOS 侧没有 identity_key 那种多段身份概念）。
//
// 为什么不在这里冗余标题/歌手/专辑：原库把元数据快照存进 play_history，是为了在线音源
// 下架后仍能展示历史条目；macOS 侧 Track 表就是权威元数据，且外键级联保证「曲目被删 →
// 历史随之删除」，不存在孤立条目，因此这里只存 trackId 与时间信息，展示时 JOIN Track 取
// 标题/歌手，不制造第二份可能过期的元数据。

import Foundation

/// 播放历史中的一行：曲目最后一次播放的时间与该曲的记忆播放位置。
public struct PlayHistoryEntry: Equatable, Sendable {

    /// 曲目标识。对应 Track.id，同时是本表主键（一首歌最多一行）。
    public var trackId: UUID
    /// 最后一次播放的起始时刻。
    public var playedAt: Date
    /// 记忆播放位置（秒）。用于 M3-T3 恢复现场与「继续播放」；未记录过为 0。
    public var resumePositionSeconds: Double

    public init(trackId: UUID, playedAt: Date, resumePositionSeconds: Double = 0) {
        self.trackId = trackId
        self.playedAt = playedAt
        self.resumePositionSeconds = resumePositionSeconds
    }
}
