// PlaybackStateStore.swift
// NeriPlayer macOS —— 播放内存态聚合与「引擎 × 队列」桥接（移植规划 M1-T5）。
//
// 定位：M1-T3 的 PlayerEngine 只会播「一个文件」，M1-T4 的 QueueManager 只会回答「下一首是谁」，
// 两者互不相识。本类把它们缝在一起，向上提供一个可读可订阅的统一内存态：队列决定播什么、
// 引擎负责播，EOF 后按队列模式自动接续。
//
// 发布者为什么选 AsyncStream，而不是 ObservableObject + 属性包装器自动发布：
//   1) 与本层既有约定一致 —— MPVController、MPVEngine、QueueManager 全部以 AsyncStream 发布全量快照，
//      订阅侧只维护一套消费写法；这条取舍 PlayerEngine.swift 的头注释已记录；
//   2) Core 层不引入 UI 框架耦合：自动发布属 Combine 且通常绑定 SwiftUI 的 ObservableObject，
//      会把「面向界面」的依赖下沉到 Core，而 M1-T6（媒体键）与后续后台逻辑都要复用本类；
//   3) 不把 Core 钉在 MainActor：AsyncStream 可在任意执行上下文消费，测试无需主线程调度。
//   因此本文件只 import Foundation：公开 observeState() -> AsyncStream<PlaybackSnapshot>，
//   并用只读属性（currentTrack/isPaused/position/duration/queueState）满足「可读」。
//   若后续 SwiftUI 视图需要可观察对象，应在 UI 层加一层薄适配订阅本流，而不是让 Core 依赖 Combine。
//
// 桥接模型（关键）：队列是「该播什么」的唯一真源，引擎只是执行者。
//   - 任何会改变当前曲的命令（playTrack / setQueue / next / previous / 入队到空队列）都把
//     queue.currentTrack 交给 engine.load(url:)；
//   - 自然播完（EOF）后按队列模式自动推进：重复调 queue.next() 即可覆盖三种情形 ——
//     repeatOne 返回当前曲（→ 重播）、repeatAll/shuffle 返回下一首、sequential 在末尾返回 nil（→ 停在末尾）；
//   - EOF 与「用户主动 stop」必须区分：核心是 playbackArmed 闩锁。只有观察到引擎真正离开空闲态之后，
//     才把随后回到空闲态解释为 EOF；load / stop 都会先清闩锁，于是「加载过程中的空闲」与
//     「用户 stop 产生的空闲」都不会被误判成 EOF。另有一道 currentURL 与队列当前曲的一致性校验，
//     防止「用户切歌」与「上一首 EOF」并发时推进两次。
//
// 线程模型：沿用本层做法 —— NSLock 串行化内部状态，yield 一律在锁外；引擎与队列各自线程安全，
// 本类只读取它们最后一次已知的快照。命令方法由调用线程同步发起并立即更新队列，不等事件回流。
//
// 边界（不做）：持久化与现场恢复（M3-T3）、媒体键（M1-T6）、输出设备（M1-T7）、音效链路（M1-T8）、UI。

import Foundation

// MARK: - 内存态快照

/// 播放内存态的一次完整快照：把引擎侧（进度/时长/暂停/空闲）与队列侧（内容/当前曲/模式）聚合成一体。
/// 与 MPVEngine/QueueManager 一致，发布粒度是整体快照而非字段增量 —— 订阅者无需自己按字段累积，
/// 也就不会因事件顺序产生状态错位。
public struct PlaybackSnapshot: Equatable, Sendable {

    /// 当前曲目，取自队列的 currentTrack；空队列为 nil。注意：停止或自然播完后该值仍保留，
    /// 用于界面显示「上一首是什么」，不代表引擎里还有已加载的文件。
    public var currentTrack: Track?
    /// 是否处于暂停。
    public var isPaused: Bool
    /// 当前播放位置（秒）。
    public var position: Double
    /// 当前文件总时长（秒）。
    public var duration: Double
    /// 解码核心是否空闲：未加载、加载中、自然播完、已停止都为此值 true。
    public var isCoreIdle: Bool
    /// 队列完整快照（内容 + 当前索引 + 模式 + 随机序列）。
    public var queue: QueueState

    public init(
        currentTrack: Track?,
        isPaused: Bool,
        position: Double,
        duration: Double,
        isCoreIdle: Bool,
        queue: QueueState
    ) {
        self.currentTrack = currentTrack
        self.isPaused = isPaused
        self.position = position
        self.duration = duration
        self.isCoreIdle = isCoreIdle
        self.queue = queue
    }
}

// MARK: - 状态聚合与桥接

/// 播放内存态聚合器：持有播放引擎与播放队列，桥接「队列决定播什么」与「引擎执行播放」。
///
/// 采用 @unchecked Sendable：内部可变状态（快照、订阅者、闩锁）全部由 lock 串行化，
/// 引擎与队列本身线程安全。
public final class PlaybackStateStore: @unchecked Sendable {

    /// 保护 stateValue / continuations / 桥接闩锁。
    private let lock = NSLock()
    private var stateValue: PlaybackSnapshot
    private var continuations: [UUID: AsyncStream<PlaybackSnapshot>.Continuation] = [:]

    /// 播放引擎（M1-T3）。协议类型：便于换后端与测试注入。
    private let engine: any PlayerEngine
    /// 播放队列（M1-T4）。
    private let queue: QueueManager

    /// 引擎是否已在本轮加载后真正开始播放（离开空闲态）。EOF 判定依赖它：
    /// 只有「先离开空闲」再「回到空闲」才算自然播完，避免把加载中的空闲当作 EOF。
    private var playbackArmed = false
    /// 是否应保持「引擎与队列当前曲一致」。stop() 置 false，任何播放命令置 true。
    private var shouldPlayCurrent = false
    /// 引擎最后一次发布的状态快照。快照里的引擎侧字段一律取自这里，而不是实时回读引擎 ——
    /// 这样「内存态」严格是事件流的折叠结果，与 EOF 闩锁同源，不会出现「快照已显示在播、
    /// 但闩锁还没武装」的错位窗口（实时回读会因队列回调先于引擎回调而制造该窗口）。
    private var engineState: PlayerEngineState
    /// 引擎/队列状态流的消费任务，deinit 时取消。
    private var observerTasks: [Task<Void, Never>] = []

    // MARK: - 构造

    /// 注入引擎与队列（测试与依赖注入入口）。
    /// - Parameters:
    ///   - engine: 播放引擎；任意 PlayerEngine 实现均可。
    ///   - queue: 播放队列；默认新建一个。
    public init(engine: any PlayerEngine, queue: QueueManager = QueueManager()) {
        self.engine = engine
        self.queue = queue
        let initialEngineState = engine.state
        engineState = initialEngineState
        stateValue = PlaybackSnapshot(
            currentTrack: queue.currentTrack,
            isPaused: initialEngineState.isPaused,
            position: initialEngineState.position,
            duration: initialEngineState.duration,
            isCoreIdle: initialEngineState.isCoreIdle,
            queue: queue.state
        )
        startObserving()
    }

    /// 便捷构造：内部创建真实 libmpv 引擎（M1-T3 的 MPVEngine）。
    public convenience init(clientName: String = "NeriPlayer.Playback") throws {
        self.init(engine: try MPVEngine(clientName: clientName), queue: QueueManager())
    }

    deinit {
        // 先停订阅任务，再结束对外流，避免状态在销毁过程中继续广播。
        for task in observerTasks {
            task.cancel()
        }
        lock.lock()
        let listeners = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for listener in listeners {
            listener.finish()
        }
    }

    // MARK: - 可读状态

    /// 当前完整内存态快照。
    public var snapshot: PlaybackSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return stateValue
    }

    /// 当前曲目（队列的 currentTrack）。
    public var currentTrack: Track? { snapshot.currentTrack }
    /// 是否暂停。
    public var isPaused: Bool { snapshot.isPaused }
    /// 当前播放位置（秒）。
    public var position: Double { snapshot.position }
    /// 当前文件总时长（秒）。
    public var duration: Double { snapshot.duration }
    /// 队列快照。
    public var queueState: QueueState { snapshot.queue }

    // MARK: - 订阅

    /// 订阅内存态变更。每次订阅返回独立新流：先推一次当前快照，之后只在快照真正变化时产出。
    public func observeState() -> AsyncStream<PlaybackSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.lock()
            let current = stateValue
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
            continuation.yield(current)
        }
    }

    // MARK: - 命令：播放当前曲 / 暂停

    /// 立刻播放指定曲目。若它已在队列中（按 id 匹配）则跳转到该曲；否则追加到队尾再跳转。
    public func playTrack(_ track: Track) {
        selectInQueue(track)
        lock.lock()
        shouldPlayCurrent = true
        lock.unlock()
        loadCurrent()
    }

    /// 在播放/暂停之间切换。若引擎当前空闲（未加载、已停止或自然播完），则从头播放队列当前曲。
    public func togglePlayPause() {
        if engine.isCoreIdle || engine.currentURL == nil {
            guard queue.currentTrack != nil else {
                publish()
                return
            }
            lock.lock()
            shouldPlayCurrent = true
            lock.unlock()
            loadCurrent()
            return
        }
        do {
            if engine.isPaused {
                try engine.play()
            } else {
                try engine.pause()
            }
        } catch {
            Log.player.error("PlaybackStateStore 切换播放/暂停失败：\(error.localizedDescription)")
        }
        publish()
    }

    // MARK: - 命令：切歌

    /// 下一首。顺序模式下已在末位且 force 为 false 时不动作；force 为 true 则回卷到首曲。
    /// - Parameter force: 是否强制推进（到末尾时回卷），对齐 Android 版 next(force) 语义。
    public func next(force: Bool = false) {
        var target = queue.next()
        if target == nil, force {
            target = queue.jump(to: 0)
        }
        guard target != nil else {
            publish()
            return
        }
        lock.lock()
        shouldPlayCurrent = true
        lock.unlock()
        loadCurrent()
    }

    /// 上一首。顺序模式下已在首曲时不动作；列表循环回卷到末曲。
    public func previous() {
        guard queue.previous() != nil else {
            publish()
            return
        }
        lock.lock()
        shouldPlayCurrent = true
        lock.unlock()
        loadCurrent()
    }

    // MARK: - 命令：队列

    /// 整批替换队列并从 startIndex 开始播放（索引越界自动钳位）。空列表则停止播放。
    public func setQueue(_ tracks: [Track], startIndex: Int = 0) {
        queue.setQueue(tracks, startAt: startIndex)
        if tracks.isEmpty {
            lock.lock()
            shouldPlayCurrent = false
            lock.unlock()
            stopEngine()
            publish()
            return
        }
        lock.lock()
        shouldPlayCurrent = true
        lock.unlock()
        loadCurrent()
    }

    /// 追加到队尾。空队列时该曲直接成为当前曲并立即开播（「入队即播」）。
    public func enqueue(_ track: Track) {
        let wasEmpty = queue.isEmpty
        queue.enqueue(track)
        if wasEmpty {
            lock.lock()
            shouldPlayCurrent = true
            lock.unlock()
            loadCurrent()
            return
        }
        publish()
    }

    /// 插到「当前曲的下一首」，不打断当前播放。空队列时该曲直接成为当前曲并立即开播。
    public func enqueueNext(_ track: Track) {
        let wasEmpty = queue.isEmpty
        queue.enqueueNext(track)
        if wasEmpty {
            lock.lock()
            shouldPlayCurrent = true
            lock.unlock()
            loadCurrent()
            return
        }
        publish()
    }

    /// 切换播放模式（顺序/列表循环/单曲循环/随机）。保持当前曲与播放位置不变。
    public func setMode(_ mode: PlaybackMode) {
        queue.setMode(mode)
        publish()
    }

    // MARK: - 命令：停止 / 转发

    /// 停止播放并卸载当前文件。队列内容保留，且不会因此自动推进下一首。
    public func stop() {
        lock.lock()
        shouldPlayCurrent = false
        playbackArmed = false
        lock.unlock()
        stopEngine()
        publish()
    }

    /// 设置音量（mpv 量程 0–100，可超过 100）。引擎不提供回读，本类不做缓存。
    public func setVolume(_ volume: Double) {
        do {
            try engine.setVolume(volume)
        } catch {
            Log.player.error("PlaybackStateStore 设置音量失败：\(error.localizedDescription)")
        }
    }

    /// 跳转到绝对位置（秒）。
    public func seek(to seconds: Double) {
        do {
            try engine.seek(to: seconds)
        } catch {
            Log.player.error("PlaybackStateStore 跳转失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 桥接：状态订阅

    /// 订阅引擎与队列两条状态流：引擎流驱动 EOF 判定，队列流驱动快照刷新。
    private func startObserving() {
        let engineStream = engine.observeState()
        observerTasks.append(Task { [weak self] in
            for await state in engineStream {
                guard let self else { return }
                handleEngineState(state)
            }
        })
        let queueStream = queue.observeState()
        observerTasks.append(Task { [weak self] in
            for await _ in queueStream {
                guard let self else { return }
                publish()
            }
        })
    }

    /// 处理一次引擎状态：维护 EOF 闩锁，必要时按队列模式自动推进。
    private func handleEngineState(_ state: PlayerEngineState) {
        var advanceTo: Track?
        lock.lock()
        engineState = state
        if state.isCoreIdle {
            if playbackArmed {
                playbackArmed = false
                // 一致性校验：只有「引擎里的文件」仍是队列当前曲时，才把这次空闲当作 EOF。
                // 用户刚切过歌（队列已指向新曲）而上一首的 EOF 迟到时，这条校验会挡掉误推进。
                let stillCurrent = state.currentURL == queue.currentTrack?.url
                if shouldPlayCurrent, stillCurrent {
                    advanceTo = advanceAfterEndLocked()
                }
            }
        } else {
            // 真正离开空闲态，说明本轮加载成功并开始播放，可以武装 EOF 判定。
            playbackArmed = true
        }
        lock.unlock()

        publish()
        if let advanceTo {
            load(advanceTo)
        }
    }

    /// EOF 后按队列模式推进。返回要加载的曲目；顺序模式播到末尾返回 nil 并解除「应播放」标记。
    /// 已持有 lock。
    private func advanceAfterEndLocked() -> Track? {
        let next = queue.next()
        if next == nil {
            // 顺序模式播到最后一首：不推进，停在末尾（currentURL 与队列都保留）。
            shouldPlayCurrent = false
            Log.player.info("PlaybackStateStore：顺序模式播到末尾，停止自动推进")
        }
        return next
    }

    // MARK: - 内部：加载与发布

    /// 把队列当前曲加载进引擎。
    private func loadCurrent() {
        load(queue.currentTrack)
    }

    /// 加载指定曲目（nil 则什么都不做）。加载前清 EOF 闩锁，避免加载过程中的空闲被误判成 EOF。
    private func load(_ track: Track?) {
        guard let track else {
            publish()
            return
        }
        lock.lock()
        playbackArmed = false
        lock.unlock()
        do {
            try engine.load(url: track.url)
            Log.player.info("PlaybackStateStore 加载：\(track.url.lastPathComponent)")
        } catch {
            Log.player.error("PlaybackStateStore 加载失败：\(error.localizedDescription)")
        }
        publish()
    }

    /// 把 track 设为队列当前曲：已在队列（按 id 匹配）则跳转，否则追加后跳转。
    private func selectInQueue(_ track: Track) {
        if let index = queue.tracks.firstIndex(where: { $0.id == track.id }) {
            queue.jump(to: index)
            return
        }
        queue.enqueue(track)
        if let index = queue.tracks.firstIndex(where: { $0.id == track.id }) {
            queue.jump(to: index)
        }
    }

    /// 从引擎与队列的当前真值重建快照。
    private func currentSnapshot() -> PlaybackSnapshot {
        let queueSnapshot = queue.state
        return PlaybackSnapshot(
            currentTrack: queueSnapshot.currentTrack,
            isPaused: engineState.isPaused,
            position: engineState.position,
            duration: engineState.duration,
            isCoreIdle: engineState.isCoreIdle,
            queue: queueSnapshot
        )
    }

    /// 停止引擎并吞掉错误（仅日志）。停止不需要已加载项。
    private func stopEngine() {
        do {
            try engine.stop()
        } catch {
            Log.player.error("PlaybackStateStore 停止失败：\(error.localizedDescription)")
        }
    }

    /// 重建快照并在真正变化时向订阅者广播（锁外 yield）。
    private func publish() {
        let next = currentSnapshot()
        lock.lock()
        guard next != stateValue else {
            lock.unlock()
            return
        }
        stateValue = next
        let listeners = Array(continuations.values)
        lock.unlock()
        for listener in listeners {
            listener.yield(next)
        }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
