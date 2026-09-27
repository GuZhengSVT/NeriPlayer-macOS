// PlayerState.swift
// NeriPlayer macOS —— 播放器现场的值类型（移植规划 M3-T1）。
//
// 定位：把「退出时正在播的现场」表示成一个纯值 —— 队列内容、当前索引、播放进度、播放模式
// 与随机序列。本任务只定义模型、建表与存取接口；真正的「退出保存 / 启动恢复」编排属 M3-T3。
//
// 语义参考 Android 原库 playback_queue_state + playback_queue_song（schemas/18.json）：
// 原库拆成「状态行（current_index / position_ms / repeat_mode / shuffle_enabled / updated_at）」
// 与「队列行（(queue_id, position) 复合主键，逐首存元数据）」两张表。macOS 侧队列是本地播放
// 列表量级（数十到数千），且队列本身是一次整体替换的对象，因此本任务落成单张 PlayerState
// 表、队列以 JSON 列整体存取：读写是行级原子操作，不需要跨表拼装，也不会出现只写了一半
// 队列的中间态。
//
// 队列项为什么存全量元数据而不是只存 trackId 外键：队列可以包含尚未入库的临时项
// （拖入应用即播的文件），只存 trackId 会让这类现场在重启后丢失。存下 Track 的五个字段
// 即可原样重建队列，且不引入对 Track 表行的强制依赖。
//
// 与 Core 模型的关系：queueState 计算属性直接产出 QueueManager 能消费的 QueueState，
// 恢复现场时（M3-T3）把 queueState 交给 setQueue、把 mode 交给 setMode 即可，不需要转换层。

import Foundation

/// 播放器现场快照：队列 + 当前索引 + 进度 + 播放模式 + 随机序列。
public struct PlayerState: Equatable, Sendable {

    /// 队列内容（列表顺序）。
    public var tracks: [Track]
    /// 当前索引；nil 当且仅当队列为空，与 QueueState 的不变式一致。
    public var currentIndex: Int?
    /// 当前播放位置（秒）。
    public var position: Double
    /// 播放模式。
    public var mode: PlaybackMode
    /// 随机模式下的播放序列（轨道 id 排列）；非随机模式为空。
    public var shuffleOrder: [UUID]
    /// 本次现场的最后保存时间。
    public var updatedAt: Date

    public init(
        tracks: [Track],
        currentIndex: Int?,
        position: Double,
        mode: PlaybackMode,
        shuffleOrder: [UUID] = [],
        updatedAt: Date = Date()
    ) {
        self.tracks = tracks
        self.currentIndex = currentIndex
        self.position = position
        self.mode = mode
        self.shuffleOrder = shuffleOrder
        self.updatedAt = updatedAt
    }

    /// 由队列快照 + 播放进度构造（保存现场的调用点用这个入口）。
    public init(queueState: QueueState, position: Double, updatedAt: Date = Date()) {
        self.init(
            tracks: queueState.tracks,
            currentIndex: queueState.currentIndex,
            position: position,
            mode: queueState.mode,
            shuffleOrder: queueState.shuffleOrder,
            updatedAt: updatedAt
        )
    }

    /// 队列部分投影为 QueueState（恢复现场时交给 QueueManager）。
    public var queueState: QueueState {
        QueueState(tracks: tracks, currentIndex: currentIndex, mode: mode, shuffleOrder: shuffleOrder)
    }

    /// 当前曲目；空队列或索引越界为 nil。
    public var currentTrack: Track? {
        guard let index = currentIndex, tracks.indices.contains(index) else { return nil }
        return tracks[index]
    }

    /// 空现场。
    public static let empty = PlayerState(
        tracks: [],
        currentIndex: nil,
        position: 0,
        mode: .sequential,
        shuffleOrder: [],
        updatedAt: .distantPast
    )
}
