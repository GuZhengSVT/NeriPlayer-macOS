// PlaybackStatsRecorder.swift
// NeriPlayer macOS —— M3-T2：统计写入管道（播放事件 → 内存累积 → 批量 flush）。
//
// 职责：把 M1-T5 的内存态快照流（PlaybackStateStore.observeState）折叠成「每首曲目听了多久、
// 算了几次有效播放」，在内存里按「曲目 × 自然日」攒着，等到 flush 时机再整批写库。
//
// 为什么要有这一层（而不是每次播放事件直接写库）：
//   1) libmpv 的 time-pos 约每 0.2–0.5s 推一次，若每次事件都落库，一首歌会产生成百上千次
//      写事务，边播边写还会和 UI 读库争同一个连接；原库（PlaybackStatsRepository +
//      PlaybackStatsTracker）同样是「先内存累积、再延迟批量落盘」的结构；
//   2) 计数语义需要「跨快照的连续判断」（本次播放累计了多久、是否已计过一次），
//      这属于状态机，放进内存比塞进每条 SQL 更清楚。
//
// flush 时机（任务边界）：切歌（曲目变化）、播放会话结束（播放→暂停/停止）、定时 30 秒、
// 应用退出。前两者由快照事件驱动，第三由 DispatchSourceTimer 驱动，第四由 AppState 挂在
// NSApplication.willTerminateNotification 上调用。
//
// 播放次数计数口径（对齐 Android 侧，见 data/stats/PlaybackStatsRepository.kt 与
// core/player/playback/PlaybackStatsTracker.kt）：
//   - 阈值：单次播放累计收听达到 MIN_LISTEN_MS_FOR_PLAY_COUNT（30s，Kotlin 常量
//     30_000L）才 +1；「划过即计数」被这条挡住；
//   - 播完：原库 calculatePlayCountIncrement 在 listenedMs 未达阈值时，还会比较
//     「总收听时长 / 曲目时长」得到的整首播放数是否增加（newFullPlays > prevFullPlays）。
//     本层用等价判据：本次播放累计收听 >= 曲目时长即算播完一次（短于 30s 的曲目靠这条
//     才能计数）；
//   - 每「一次播放」最多计 1（hasCountedCurrentPlay）：暂停恢复不算新的一次，只有换曲
//     或播完才开启新的一次（与原库 onSongChanged / onTrackEnded 复位一致）。
//
// 幂等：flush 把内存桶「取出并清空」，写库成功才真正落地。因此同一段收听只会进入写入一次，
// 连续两次 flush 中第二次一定是空载荷（no-op），不会双计；写库失败则把增量并回内存桶，
// 留待下一次 flush 重试。
//
// 分层：本文件只 import Foundation / Dispatch —— Core 层不得依赖 GRDB 或 UI 框架。
// 真正落库由注入的 flush 闭包（PlaybackStatsFlushHandler）完成，生产路径接到
// Data 层的 PlaybackStatsRepository（见 AppState 的接线），测试路径接到假实现。
//
// 线程模型：与 M1 各层一致 —— NSLock 串行化内部状态；快照消费（订阅任务）、定时器线程、
// 退出钩子可能并发调用本类，全部经同一把锁。
//
// 边界（不做）：播放现场恢复（M3-T3）、流量统计（M3-T4）、统计面板 UI（M3-T5 之后）。

import Dispatch
import Foundation

// MARK: - flush 触发原因

/// 一次 flush 的触发原因。只用于日志与测试断言，不参与落库。
public enum PlaybackStatsFlushReason: String, Sendable {
    /// 切歌（或队列清空导致当前曲消失）。
    case trackChange
    /// 播放会话结束：播放→暂停/停止。
    case sessionEnd
    /// 定时器到期。
    case periodic
    /// 应用退出。
    case termination
    /// 显式调用 flush。
    case manual
}

// MARK: - 增量载荷

/// 一份「尚未落库」的收听增量：某曲在某个自然日里新增的收听秒数与播放次数。
///
/// 为什么按「曲目 × 自然日」而不是只按曲目：每日桶表的主键是 (dayStart, trackId)，
/// 落库时必须带上桶键；同时跨午夜的收听只有按日切分才能算到正确的那一天。
public struct PlaybackStatsDelta: Equatable, Sendable {

    /// 曲目标识（对应 Track.id / PlaybackStats.trackId）。
    public let trackId: UUID
    /// 该增量所属自然日的本地零点（PlaybackStatsDailyBucket 的桶键）。
    public let dayStart: Date
    /// 新增收听时长（秒）。
    public let listenSeconds: Double
    /// 新增播放次数（已达阈值或播完才 > 0）。
    public let playCount: Int
    /// 本增量内最早的播放时刻（累计行/桶行的 firstPlayedAt 取最小）。
    public let firstPlayedAt: Date
    /// 本增量内最近的播放时刻（累计行/桶行的 lastPlayedAt 取最大）。
    public let lastPlayedAt: Date

    public init(
        trackId: UUID,
        dayStart: Date,
        listenSeconds: Double,
        playCount: Int,
        firstPlayedAt: Date,
        lastPlayedAt: Date
    ) {
        self.trackId = trackId
        self.dayStart = dayStart
        self.listenSeconds = listenSeconds
        self.playCount = playCount
        self.firstPlayedAt = firstPlayedAt
        self.lastPlayedAt = lastPlayedAt
    }

    /// 是否含有效内容（时长与次数都为 0 的增量没有落库价值）。
    public var isEmpty: Bool {
        listenSeconds <= 0 && playCount <= 0
    }
}

/// 落库回调：把一批增量写入统计表。抛出即视为「整批未落库」，recorder 会把增量并回内存重试。
public typealias PlaybackStatsFlush = @Sendable ([PlaybackStatsDelta]) throws -> Void

// MARK: - 定时器抽象

/// 周期 flush 的定时器后端。抽成协议是为了让「定时到期触发 flush」可以确定性单测：
/// 测试注入的假定时器把 handler 握在手里，由用例主动触发，不必真的等 30 秒。
public protocol PlaybackStatsTimerScheduling: AnyObject, Sendable {

    /// 启动（或重启）一个每 interval 秒触发一次的定时器；handler 在后台线程执行。
    func schedule(every interval: TimeInterval, handler: @escaping @Sendable () -> Void)

    /// 取消定时器。未启动时是 no-op。
    func cancel()
}

/// 生产实现：DispatchSourceTimer。
/// leeway 放宽到 0.5s：统计落库是后台事务，不需要与到期时刻精确对齐，放宽可以让系统合并
/// 唤醒、省电，对播放链路零影响。
public final class DispatchSourceTimerScheduler: PlaybackStatsTimerScheduling, @unchecked Sendable {

    private let queue = DispatchQueue(label: "moe.ouom.NeriPlayer.playbackStats.timer")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    public init() {}

    public func schedule(every interval: TimeInterval, handler: @escaping @Sendable () -> Void) {
        cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        source.setEventHandler(handler: handler)
        lock.lock()
        timer = source
        lock.unlock()
        source.resume()
    }

    public func cancel() {
        lock.lock()
        let existing = timer
        timer = nil
        lock.unlock()
        existing?.cancel()
    }

    deinit {
        timer?.cancel()
    }
}

// MARK: - 录制器

/// 统计写入管道。订阅播放内存态快照，识别「切歌 / 会话结束」边界，把收听时长与播放次数
/// 按「曲目 × 自然日」累积在内存，按时机批量 flush 给注入的落库闭包。
public final class PlaybackStatsRecorder: @unchecked Sendable {

    /// 一次播放达到该时长即计一次（对齐原库 MIN_LISTEN_MS_FOR_PLAY_COUNT = 30_000L）。
    public static let defaultPlayCountThresholdSeconds: Double = playbackStatsPlayCountThresholdSeconds

    /// 默认周期 flush 间隔（秒）。
    public static let defaultFlushInterval: TimeInterval = 30

    /// 「曲目 × 自然日」的桶键。Date 与 UUID 都是 Hashable，可直接做字典键。
    private struct DayKey: Hashable {
        let dayStart: Date
        let trackId: UUID
    }

    /// 一个桶里攒的内容。
    private struct Accumulator {
        var listenSeconds: Double = 0
        var playCount: Int = 0
        var firstPlayedAt: Date
        var lastPlayedAt: Date
    }

    /// 保护下列全部可变状态 + attachedValue。
    private let lock = NSLock()

    // 当前曲目状态机
    private var currentTrackId: UUID?
    /// 上一份快照中引擎是否在播（非暂停且非空闲）。
    private var isPlaying = false
    /// 当前「播放片段」的起点；未在播时为 nil。用来把两次快照之间的墙钟时间折算成收听时长。
    private var segmentStart: Date?
    /// 本次播放（同一曲、从开始到计过一次为止）累计的收听秒数，用于阈值与播完判定。
    private var currentPlayListenedSeconds: Double = 0
    /// 本次播放是否已计过一次播放；暂停恢复不重置它。
    private var hasCountedCurrentPlay = false
    /// 本次播放绑定的曲目时长（秒），来自引擎快照，用于「播完」判定。
    private var currentPlayDurationSeconds: Double = 0

    /// 待落库的桶（曲目 × 自然日）。
    private var pendingBuckets: [DayKey: Accumulator] = [:]

    private var subscription: Task<Void, Never>?
    private var attachedValue = false
    private var stopped = false
    private var subscriptionGeneration: UUID?
    private let lifecycleLock = NSLock()
    private let flushLock = NSLock()

    private let clock: @Sendable () -> Date
    private let dayStarter: @Sendable (Date) -> Date
    private let playCountThresholdSeconds: Double
    private let flushInterval: TimeInterval
    private let timer: any PlaybackStatsTimerScheduling
    private let flushHandler: PlaybackStatsFlush
    private let prepareTrack: @Sendable (Track) throws -> Track

    /// - Parameters:
    ///   - flushInterval: 周期 flush 间隔（秒），默认 30。
    ///   - playCountThresholdSeconds: 单次播放计入一次播放的时长阈值（秒），默认 30。
    ///   - clock: 取当前时刻；注入假时钟即可确定性验证收听时长与跨日切桶。
    ///   - dayStarter: 求某时刻所属自然日的本地零点；默认用 PlaybackStatsDailyBucket.dayStart。
    ///   - timer: 周期 flush 后端；默认 DispatchSourceTimer，测试可注入可手动触发的假实现。
    ///   - flush: 落库闭包（生产路径接 Data 层的 PlaybackStatsRepository）。
    public init(
        flushInterval: TimeInterval = PlaybackStatsRecorder.defaultFlushInterval,
        playCountThresholdSeconds: Double = PlaybackStatsRecorder.defaultPlayCountThresholdSeconds,
        clock: @escaping @Sendable () -> Date = { Date() },
        dayStarter: @escaping @Sendable (Date) -> Date = { PlaybackStatsDailyBucket.dayStart(for: $0) },
        timer: any PlaybackStatsTimerScheduling = DispatchSourceTimerScheduler(),
        prepareTrack: @escaping @Sendable (Track) throws -> Track = { $0 },
        flush: @escaping PlaybackStatsFlush
    ) {
        self.flushInterval = flushInterval
        self.playCountThresholdSeconds = playCountThresholdSeconds
        self.clock = clock
        self.dayStarter = dayStarter
        self.timer = timer
        self.flushHandler = flush
        self.prepareTrack = prepareTrack
    }

    deinit {
        subscription?.cancel()
        timer.cancel()
    }

    /// 是否已开始订阅快照流。
    public var isAttached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return attachedValue
    }

    /// 当前待落库的增量条数（诊断与测试用）。
    public var pendingDeltaCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingBuckets.count
    }

    /// 当前正在跟踪的曲目（诊断与测试用）：订阅链路是否已把某首曲子纳入统计，看这里。
    var trackedTrackID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return currentTrackId
    }

    /// 是否处于「正在计时的播放片段」（诊断与测试用）：曲目已知、引擎在播、且片段起点已建立。
    /// 快照流用的是 bufferingNewest(1)，负载高时中间态快照会被合并；调用方（测试）等到本值
    /// 为 true，才能保证之后拨动时钟产生的时长一定被下一次快照结算进去。
    var isTrackingPlayback: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentTrackId != nil && isPlaying && segmentStart != nil
    }

    // MARK: - 接入与退出

    /// 订阅播放内存态快照并启动周期 flush。幂等：重复调用只保留一个订阅。
    public func attach(to store: PlaybackStateStore) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        lock.lock()
        guard !attachedValue else {
            lock.unlock()
            return
        }
        let generation = UUID()
        subscriptionGeneration = generation
        stopped = false
        attachedValue = true
        lock.unlock()

        let stream = store.observeState()
        subscription = Task { [weak self] in
            var preparedID: UUID?
            var preparedTrack: Track?
            for await value in stream {
                guard let self, !Task.isCancelled else { return }
                var snapshot = value
                if let track = snapshot.currentTrack {
                    if track.id != preparedID {
                        do {
                            preparedTrack = try self.prepareTrack(track); preparedID = track.id
                        } catch {
                            Log.db.error("播放元数据登记失败：\(error.localizedDescription)"); continue
                        }
                    }
                    snapshot.currentTrack = preparedTrack
                }
                self.handle(snapshot, generation: generation)
            }
        }
        timer.schedule(every: flushInterval) { [weak self] in
            self?.flush(reason: .periodic)
        }
    }

    /// Invalidate queued observations before settling the final listening segment.
    public func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        subscription?.cancel()
        subscription = nil
        timer.cancel()
        lock.lock()
        subscriptionGeneration = nil
        attachedValue = false
        stopped = true
        let now = clock()
        collectSegmentLocked(at: now)
        if let id = currentTrackId { finalizePlayLocked(trackId: id, at: now) }
        isPlaying = false
        segmentStart = nil
        currentTrackId = nil
        currentPlayListenedSeconds = 0
        hasCountedCurrentPlay = false
        currentPlayDurationSeconds = 0
        lock.unlock()
        flush(reason: .termination)
    }

    // MARK: - 快照消费（状态机）

    /// 处理一份播放内存态快照。内部接口，测试可直接喂构造好的快照做确定性断言。
    func handle(_ snapshot: PlaybackSnapshot) {
        handle(snapshot, generation: nil)
    }

    private func handle(_ snapshot: PlaybackSnapshot, generation: UUID?) {
        var flushReason: PlaybackStatsFlushReason?
        lock.lock()
        guard !stopped, generation == nil || generation == subscriptionGeneration else {
            lock.unlock()
            return
        }
        let now = clock()
        // 先把「上一次快照到现在」这段播放时间计入内存桶 —— 必须先结算再判断边界，
        // 否则切歌那一刻的这段收听会丢。
        collectSegmentLocked(at: now)

        let trackId = snapshot.currentTrack?.id
        let playing = snapshot.currentTrack != nil && !snapshot.isPaused && !snapshot.isCoreIdle
        let duration = snapshot.duration > 0 ? snapshot.duration : (snapshot.currentTrack?.duration ?? 0)

        if trackId != currentTrackId {
            // 切歌边界：先给上一首收尾（可能计一次播放），再切到新曲。
            if let previous = currentTrackId {
                finalizePlayLocked(trackId: previous, at: now)
            }
            currentTrackId = trackId
            currentPlayListenedSeconds = 0
            currentPlayDurationSeconds = duration
            hasCountedCurrentPlay = false
            isPlaying = playing
            segmentStart = playing ? now : nil
            flushReason = .trackChange
        } else {
            if isPlaying, !playing, let id = trackId {
                // 会话结束：播放→暂停/停止。收尾并结算播放次数（原库 onPlayingChanged(false)
                // 同样在停止时结算，否则「听满 30s 就暂停」的播放会永远不计）。
                finalizePlayLocked(trackId: id, at: now)
                flushReason = .sessionEnd
            }
            if duration > 0 {
                currentPlayDurationSeconds = duration
            }
            isPlaying = playing
            segmentStart = playing ? now : nil
        }
        lock.unlock()

        if let flushReason {
            flush(reason: flushReason)
        }
    }

    /// 把自 segmentStart 起到 now 的播放时长计入内存桶与本次播放累计。已持有 lock。
    private func collectSegmentLocked(at now: Date) {
        guard isPlaying, let start = segmentStart, let trackId = currentTrackId else { return }
        let delta = now.timeIntervalSince(start)
        if delta > 0 {
            addListenLocked(trackId: trackId, seconds: delta, at: now)
            currentPlayListenedSeconds += delta
        }
        // 片段起点前移到当前时刻：下一次 collect 只算新增的那一段。
        segmentStart = now
    }

    /// 给一次播放收尾：达到阈值或已播完则计一次播放。已持有 lock。
    ///
    /// 口径见文件头：本次播放累计收听 >= 30s（原库 MIN_LISTEN_MS_FOR_PLAY_COUNT）或
    /// >= 曲目时长（等价于原库 fullPlays 增加的判据）二者之一成立即算一次有效播放，
    /// 且同一次播放最多计 1。
    private func finalizePlayLocked(trackId: UUID, at now: Date) {
        guard !hasCountedCurrentPlay else { return }
        let reachedThreshold = currentPlayListenedSeconds >= playCountThresholdSeconds
        let reachedFullTrack = currentPlayDurationSeconds > 0
            && currentPlayListenedSeconds >= currentPlayDurationSeconds
        guard reachedThreshold || reachedFullTrack else { return }
        countPlayLocked(trackId: trackId, at: now)
        hasCountedCurrentPlay = true
    }

    /// 把一段收听时长计入「曲目 × 自然日」桶。已持有 lock。
    /// 归属日取结算时刻所在自然日（与原库按 record 调用时刻算 dayStart 一致，误差上界是一次
    /// flush 间隔）；跨午夜的连续收听因此可能被拆到两天，这正是每日桶想要的切分。
    private func addListenLocked(trackId: UUID, seconds: Double, at time: Date) {
        guard seconds > 0 else { return }
        let key = DayKey(dayStart: dayStarter(time), trackId: trackId)
        var bucket = pendingBuckets[key] ?? Accumulator(firstPlayedAt: time, lastPlayedAt: time)
        bucket.listenSeconds += seconds
        bucket.firstPlayedAt = min(bucket.firstPlayedAt, time)
        bucket.lastPlayedAt = max(bucket.lastPlayedAt, time)
        pendingBuckets[key] = bucket
    }

    /// 计一次播放。已持有 lock。
    private func countPlayLocked(trackId: UUID, at time: Date) {
        let key = DayKey(dayStart: dayStarter(time), trackId: trackId)
        var bucket = pendingBuckets[key] ?? Accumulator(firstPlayedAt: time, lastPlayedAt: time)
        bucket.playCount += 1
        bucket.firstPlayedAt = min(bucket.firstPlayedAt, time)
        bucket.lastPlayedAt = max(bucket.lastPlayedAt, time)
        pendingBuckets[key] = bucket
    }

    // MARK: - flush

    /// 把内存桶整批写出去。幂等：成功后桶即清空，重复调用第二次是空载荷 no-op。
    ///
    /// 写库失败时把增量并回内存桶（下次 flush 重试），因此一次统计不会因为一次写失败而丢失。
    /// - Returns: 本次 flush 是否成功（空载荷也视为成功）。
    @discardableResult
    public func flush(reason: PlaybackStatsFlushReason = .manual) -> Bool {
        flushLock.lock()
        defer { flushLock.unlock() }
        // 取桶 + 清空必须在同一把锁里完成：这样「同一段收听」只可能被取走一次，
        // 并发到来的第二次 flush 拿到的一定是空载荷。
        lock.lock()
        let now = clock()
        collectSegmentLocked(at: now)
        if let id = currentTrackId { finalizePlayLocked(trackId: id, at: now) }
        let payload = pendingBuckets.compactMap { key, bucket -> PlaybackStatsDelta? in
            let delta = PlaybackStatsDelta(
                trackId: key.trackId,
                dayStart: key.dayStart,
                listenSeconds: bucket.listenSeconds,
                playCount: bucket.playCount,
                firstPlayedAt: bucket.firstPlayedAt,
                lastPlayedAt: bucket.lastPlayedAt
            )
            return delta.isEmpty ? nil : delta
        }
        pendingBuckets.removeAll()
        lock.unlock()

        guard !payload.isEmpty else {
            return true
        }

        do {
            try flushHandler(payload)
            Log.player.debug("统计 flush（\(reason.rawValue)）：\(payload.count) 条增量")
            return true
        } catch {
            lock.lock()
            mergeBackLocked(payload)
            lock.unlock()
            Log.player.error("统计 flush 失败（\(reason.rawValue)），增量已并回内存待重试：\(error.localizedDescription)")
            return false
        }
    }

    /// 写库失败时把已取出的增量并回内存桶（按桶键合并）。已持有 lock。
    private func mergeBackLocked(_ deltas: [PlaybackStatsDelta]) {
        for delta in deltas {
            let key = DayKey(dayStart: delta.dayStart, trackId: delta.trackId)
            var bucket = pendingBuckets[key]
                ?? Accumulator(firstPlayedAt: delta.firstPlayedAt, lastPlayedAt: delta.lastPlayedAt)
            bucket.listenSeconds += delta.listenSeconds
            bucket.playCount += delta.playCount
            bucket.firstPlayedAt = min(bucket.firstPlayedAt, delta.firstPlayedAt)
            bucket.lastPlayedAt = max(bucket.lastPlayedAt, delta.lastPlayedAt)
            pendingBuckets[key] = bucket
        }
    }
}
