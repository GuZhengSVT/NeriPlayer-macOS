// PlaybackSession.swift
// NeriPlayer macOS —— 播放现场（队列 + 索引 + 进度 + 模式）的保存管道（移植规划 M3-T3）。
//
// 定位：M3-T1 提供了 PlayerState 值与单行表存取，M1-T5 的 PlaybackStateStore 提供内存态。
// 本文件是两者之间的「什么时候写」策略 —— 订阅内存态快照，判断哪些变化值得落库，再把结果
// 交给注入的保存闭包。它不碰 SQLite（Repository 负责），也不碰 UI。
//
// 保存时机（对齐 Android 原库 PlayerManagerPersistenceExtensions 的 persist 语义，但按 macOS
// 侧的存储成本重新取舍）：
//   1) 结构变化 → 立即写。队列内容 / 当前索引 / 播放模式 / 随机序列 / 播放意图（在播还是暂停）
//      任一改变都写一次。这些变化全部由用户操作触发（切歌、换模式、暂停），频次是人手级别，
//      单行 upsert 的成本可忽略；
//   2) 仅进度推进 → 累计到阈值再写。libmpv 的 time-pos 每秒推来多次，每次都写盘没有意义；
//      按「已落库位置与当前位置相差 ≥ 2 秒」触发。
//
// 为什么用「进度差阈值」而不是定时器：位置推进本身就是事件驱动的，没有事件就说明位置没变
// （暂停/停止），此时也没有写盘的必要。阈值法省掉了一个周期定时器与它的唤醒开销，且让
// 「kill 后位置误差 ≤ 3 秒」这条验收可以直接从常量读出来：误差上界就是阈值（2 秒）加上
// 最后一次 time-pos 事件的延迟，不需要靠时序推理。
//
// 为什么不做 250ms 防抖（Android 侧 STATE_PERSIST_DEBOUNCE_MS）：那边落的是整份 JSON 文件，
// 写一次要序列化整个队列；这边是 SQLite 单行 upsert，防抖省下的 I/O 抵不上它引入的
// 「防抖窗口内退出可能丢最后一次变更」这一类时序问题。
//
// 边界（不做）：音源解析与重播（M5）—— 本任务只按「可持久化」规则存本地文件队列，
// 临时音源地址（M5 的带签名 URL）在持久化时被剔除，理由见 PlaybackSessionPolicy。

import Foundation

// MARK: - 持久化策略

/// 现场持久化的取舍规则。
public enum PlaybackSessionPolicy {

    /// 该轨道是否值得写进持久化现场。
    ///
    /// 只有本地文件算「可持久化」。在线音源（M5）拿到的播放地址通常是带签名与有效期的临时
    /// URL —— 存下来下次启动必然失效，恢复出来的只会是一串点了没反应的队列项。因此这类轨道
    /// 在落库前被剔除；真正「重开也能播」的在线队列要等 M5 拿音源标识重新解析地址，
    /// 那是 M5 的范围，不在本任务里假装支持。
    public static func isDurable(_ track: Track) -> Bool {
        track.url.isFileURL
    }
}

// MARK: - 保存阈值

/// 现场保存的阈值常量。
public enum PlaybackSessionThreshold {

    /// 仅进度变化时的写盘步长（秒）。
    ///
    /// 验收要求「kill 后位置恢复到 ±3 秒内」，本值即误差上界的主要来源（另加最后一次
    /// time-pos 事件的延迟）。取 2 秒是为了在 3 秒预算里留出余量，同时把每秒多次的
    /// 进度事件压成每 2 秒一次写盘。
    public static let positionStepSeconds: Double = 2
}

// MARK: - 内存态 → 可落库现场

extension PlaybackSnapshot {

    /// 把内存态投影成「可以落库的现场」。
    ///
    /// 返回 nil 表示没有可恢复的内容，调用方应清除已存的现场：
    ///   - 空队列，或当前索引越界；
    ///   - 当前曲不可持久化 —— 「正在播的那首」都恢复不了，恢复其余队列只会让人困惑，
    ///     不如干净地不恢复（与「剔除临时音源」同一条边界）。
    ///
    /// - Parameters:
    ///   - isDurable: 单曲是否可持久化；测试用它注入假规则，生产用 PlaybackSessionPolicy。
    ///   - now: 现场时间戳；注入以便测试确定性断言。
    func restorablePlayerState(
        keeping isDurable: (Track) -> Bool = PlaybackSessionPolicy.isDurable,
        now: Date = Date()
    ) -> PlayerState? {
        let queueState = queue
        guard let currentIndex = queueState.currentIndex,
              queueState.tracks.indices.contains(currentIndex) else {
            return nil
        }
        guard isDurable(queueState.tracks[currentIndex]) else { return nil }

        // 保留可持久化的轨道，并把当前索引重映射到过滤后的位置。
        // 随机序列同步裁剪：序列里残留已被剔除的 id 会让「下一首」跳到不存在的曲目。
        let kept = queueState.tracks.enumerated().filter { isDurable($0.element) }
        guard let restoredIndex = kept.firstIndex(where: { $0.offset == currentIndex }) else {
            return nil
        }
        let keptIDs = Set(kept.map(\.element.id))

        return PlayerState(
            tracks: kept.map(\.element),
            currentIndex: restoredIndex,
            position: position,
            mode: queueState.mode,
            shuffleOrder: queueState.shuffleOrder.filter { keptIDs.contains($0) },
            shouldResumePlayback: !isPaused && !isCoreIdle,
            updatedAt: now
        )
    }
}

// MARK: - 现场录制器

/// 播放现场录制器：订阅内存态快照，按「结构变化立即写 / 进度变化按步长写」的策略落库。
///
/// 线程模型：订阅任务与调用线程（退出时的 flushNow）都会进入，内部状态由 lock 串行化，
/// 写盘一律在锁外执行 —— 与 PlaybackStatsRecorder 同一套约定，避免持锁做 I/O。
public final class PlaybackSessionRecorder: @unchecked Sendable {

    /// 落库回调。抛出即视为本次未保存，录制器允许后续重试。
    public typealias SaveHandler = @Sendable (PlayerState) throws -> Void
    /// 清除回调：现场已无可恢复内容时调用。
    public typealias ClearHandler = @Sendable () throws -> Void

    /// 判断「结构是否变化」用的投影：这些字段任一改变都必须立刻落库。
    ///
    /// 进度刻意不在其中 —— 它走阈值，不做逐步比较。播放意图（shouldResumePlayback）必须在内：
    /// 暂停与继续播放的队列、索引、进度可能完全相同，只有它能触发一次写盘。
    private struct SessionSignature: Equatable {
        var trackIDs: [UUID]
        var currentIndex: Int?
        var mode: PlaybackMode
        var shuffleOrder: [UUID]
        var shouldResumePlayback: Bool

        init(_ state: PlayerState) {
            trackIDs = state.tracks.map(\.id)
            currentIndex = state.currentIndex
            mode = state.mode
            shuffleOrder = state.shuffleOrder
            shouldResumePlayback = state.shouldResumePlayback
        }
    }

    private let lock = NSLock()
    /// 最近一次快照投影出的现场；nil 表示「当前没有可恢复的内容」。
    private var latest: PlayerState?
    /// 最近一次真正写下去的内容，用于跳过重复写盘。
    private var lastWritten: PlayerState?
    /// 是否收到过至少一次快照。没有它就无法区分「观察到空队列」与「还没来得及观察」——
    /// 后者若按前者处理，启动后立刻退出会把刚恢复的现场清掉。
    private var hasObserved = false
    private var subscription: Task<Void, Never>?

    private let save: SaveHandler
    private let clear: ClearHandler
    private let positionStep: Double
    private let isDurable: @Sendable (Track) -> Bool
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - save: 落库闭包（通常包一层 PlayerStateRepository.save）。
    ///   - clear: 清除闭包（通常包一层 PlayerStateRepository.clear）。
    ///   - positionStep: 进度写盘步长（秒）。
    ///   - isDurable: 单曲可持久化判定。
    ///   - now: 现场时间戳来源，注入以便测试。
    public init(
        save: @escaping SaveHandler,
        clear: @escaping ClearHandler,
        positionStep: Double = PlaybackSessionThreshold.positionStepSeconds,
        // 默认值写成显式的 @Sendable 闭包而不是直接引用方法与 Date.init：
        // 后者是普通的非 Sendable 函数值，转换到 @Sendable 参数类型时会触发
        // 「converting non-Sendable function value」告警。
        isDurable: @escaping @Sendable (Track) -> Bool = { PlaybackSessionPolicy.isDurable($0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.save = save
        self.clear = clear
        self.positionStep = positionStep
        self.isDurable = isDurable
        self.now = now
    }

    deinit {
        subscription?.cancel()
    }

    /// 订阅播放内存态并开始录制。
    ///
    /// 调用方必须先把要恢复的现场写进 store 再 attach：订阅时会立刻收到一次当前快照，
    /// 若此刻队列还是空的，这次快照会被当成「现场已清空」而抹掉刚存下的内容。
    ///
    /// - Returns: 本次调用是否真的建立了订阅；已有订阅时返回 false（幂等，不叠加）。
    ///   返回值存在的意义是让「幂等」可被直接断言，而不必靠「数写盘次数」这类间接、
    ///   受调度影响的观察方式。
    @discardableResult
    public func attach(to store: PlaybackStateStore) -> Bool {
        lock.lock()
        guard subscription == nil else {
            lock.unlock()
            return false
        }
        // 占位标记与真正的订阅任务分两步：订阅时会同步推一次当前快照，
        // 持有 lock 去构造流没有必要，也会把「检查—赋值」拉成一个跨调用的临界区。
        let stream = store.observeState()
        let task = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                self.handle(snapshot)
            }
        }
        subscription = task
        lock.unlock()
        return true
    }

    /// 立即落库（应用退出、停止播放集成等收尾时机调用）。
    ///
    /// 与常态路径的区别：忽略进度步长，把当前位置原样写下 —— 退出正是「最后一次进度」最有价值
    /// 的时刻。从未收到过快照时什么都不做：那说明现场尚未读取，此时的「空」不代表用户清空了队列。
    ///
    /// - Parameter reason: 记录到日志的触发原因，便于排查「现场为什么是这一份」。
    public func flushNow(reason: String) {
        write(reason: reason, force: true)
    }

    /// 停止订阅。幂等。
    public func stop() {
        lock.lock()
        let task = subscription
        subscription = nil
        lock.unlock()
        task?.cancel()
    }

    // MARK: - 内部

    /// 处理一次内存态快照：投影 → 判断是否需要写 → 写。
    ///
    /// internal 而非 private：写盘时机是纯逻辑，单测直接喂快照即可确定性覆盖，
    /// 不必依赖订阅与调度的时序（订阅路径本身由端到端用例覆盖）。
    func handle(_ snapshot: PlaybackSnapshot) {
        let projection = snapshot.restorablePlayerState(keeping: isDurable, now: now())

        var shouldWrite = false
        lock.lock()
        let previous = latest
        let observedBefore = hasObserved
        latest = projection
        hasObserved = true
        switch (previous, projection) {
        case let (previous?, projection?):
            // 有旧有新：结构变了立刻写；只有进度推进则攒够步长再写。
            let structChanged = SessionSignature(previous) != SessionSignature(projection)
            // 进度基准必须是「上次真正落库的位置」，不能是上一份快照：mpv 的 time-pos 事件
            // 间隔（约 1 秒）小于步长（2 秒），拿相邻快照做差会每一步都不到阈值，
            // 于是永远攒不够、等于完全不落库 —— 进度会被无限期地拖在起点上。
            let positionAdvanced = lastWritten.map {
                abs(projection.position - $0.position) >= positionStep
            } ?? true
            shouldWrite = structChanged || positionAdvanced
        default:
            // 新出现或变为空：都是「现场性质」的变化，值得写一次。
            // observedBefore 为 false 时同样写 —— 这是启动后的第一份现场。
            shouldWrite = true
        }
        lock.unlock()

        guard shouldWrite else { return }
        write(reason: observedBefore ? "快照变化" : "首次快照", force: false)
    }

    /// 落库当前现场（latest 为 nil 则清除）。
    /// - Parameter force: true 时忽略「与上次写入相同」的短路。
    private func write(reason: String, force: Bool) {
        lock.lock()
        guard hasObserved else {
            lock.unlock()
            return
        }
        let state = latest
        if !force, contentEquals(state, lastWritten) {
            lock.unlock()
            return
        }
        lastWritten = state
        lock.unlock()

        do {
            if let state {
                try save(state)
                let indexLabel = state.currentIndex.map(String.init) ?? "nil"
                Log.db.debug(
                    "保存播放现场（\(reason)）：队列 \(state.tracks.count) 首，索引 \(indexLabel)，位置 \(Int(state.position))s"
                )
            } else {
                try clear()
                Log.db.debug("清除播放现场（\(reason)）：当前没有可恢复的内容")
            }
        } catch {
            // 写失败不改变内存态，只把「已写入」标记退回去，让下一次快照再试一遍。
            lock.lock()
            lastWritten = nil
            lock.unlock()
            Log.db.error("播放现场保存失败（\(reason)）：\(error.localizedDescription)")
        }
    }

    /// 两份现场在「内容」上是否相同。
    ///
    /// 不能直接用 ==：updatedAt 每次投影都会取新时间，直接比较永远不相等，短路的语义就没了。
    /// 这里把时间戳归一后比较，让「无变化则不写盘」这条判断真正成立。
    private func contentEquals(_ lhs: PlayerState?, _ rhs: PlayerState?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            var left = lhs
            var right = rhs
            left.updatedAt = .distantPast
            right.updatedAt = .distantPast
            return left == right
        default:
            return false
        }
    }
}
