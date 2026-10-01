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
//   - 自动推进只消费显式 hasEnded；core-idle 包含暂停/缓冲，不能代表 EOF。
//     文件加载成功才武装一次推进，并校验引擎 URL 与队列当前曲的一致性。
//
// 线程模型：沿用本层做法 —— NSLock 串行化内部状态，yield 一律在锁外；引擎与队列各自线程安全，
// 本类只读取它们最后一次已知的快照。命令方法由调用线程同步发起并立即更新队列，不等事件回流。
//
// 边界（不做）：媒体键（M1-T6）、输出设备（M1-T7）、音效链路（M1-T8）、UI。
// 现场恢复的入口在本类（restore(_:resumePlayback:)），但「何时保存 / 何时恢复」的编排不在 ——
// 落库策略见 M3-T3 的 PlaybackSessionRecorder，启动编排见 AppState.

import Foundation

// MARK: - 音量

/// 应用音量的缺省值与合法区间。
///
/// 区间复用设置层的 PlaybackBehaviorDefaults.volumeRange（0–100）：音量条、设置页滑杆与内存态
/// 三者必须夹取同一范围，否则会出现「滑杆给 0–100、库存 0–1」这类只能靠比对代码发现的错位。
/// 缺省取 100（libmpv 初始音量），而不是用户设置里的 70 —— 那是一个尚未下发的偏好；
/// 应用启动后由 AppState 的「启动音量」把它真正写进内核，届时内存态随之更新。
public enum PlaybackVolumeDefaults {
    public static let volume: Double = 100
}

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
    /// Runtime failure is separate from natural EOF; online orchestration may recover it.
    public var playbackError: String?
    /// 当前音频流的真实规格（编码/比特率/采样率/声道/容器）。内核未报告时为 nil，
    /// 界面据此决定显示哪些字段，缺值不编造。
    public var audioTrackInfo: AudioTrackInfo?
    /// 应用音量（0–100）。这是「应用自己设定的音量」这一应用状态，不是对设备输出的测量：
    /// libmpv 不回读，本值由本类的 setVolume 维护。界面音量条绑它，缺省为 100（libmpv 默认），
    /// 应用启动后会以用户设置（启动音量）覆盖。
    public var volume: Double
    /// 是否已启用「播完当前曲暂停」。界面据此显示该开关的当前状态。
    ///
    /// 注意：这是内存态、不随现场落库 —— 该开关属于「本次操作意图」，退出后回到默认关闭，
    /// 与队列/播放模式（用户长期偏好）的持久化范围不同。
    public var pauseAfterCurrent: Bool

    public init(
        currentTrack: Track?,
        isPaused: Bool,
        position: Double,
        duration: Double,
        isCoreIdle: Bool,
        queue: QueueState,
        playbackError: String? = nil,
        audioTrackInfo: AudioTrackInfo? = nil,
        volume: Double = PlaybackVolumeDefaults.volume,
        pauseAfterCurrent: Bool = false
    ) {
        self.currentTrack = currentTrack
        self.isPaused = isPaused
        self.position = position
        self.duration = duration
        self.isCoreIdle = isCoreIdle
        self.queue = queue
        self.playbackError = playbackError
        self.audioTrackInfo = audioTrackInfo
        self.volume = volume
        self.pauseAfterCurrent = pauseAfterCurrent
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
    private let loadLock = NSRecursiveLock()
    /// Initial replay and later yields must remain ordered across producer threads.
    private let publicationLock = NSRecursiveLock()
    private var onlineLoadHandler: (@Sendable (Track, UUID, Bool) -> Void)?
    private var onlineFailureHandler: (@Sendable (Track, UUID, String) -> Void)?
    private var onlineRequestID: UUID?
    private var activeMediaURL: URL?
    private var stateValue: PlaybackSnapshot
    private var continuations: [UUID: AsyncStream<PlaybackSnapshot>.Continuation] = [:]

    /// 播放引擎（M1-T3）。协议类型：便于换后端与测试注入。
    private let engine: any PlayerEngine

    func setPlaybackCache(_ cache: PlaybackAudioCache?) {
        (engine as? MPVEngine)?.setPlaybackCache(cache)
    }
    /// 播放队列（M1-T4）。
    private let queue: QueueManager

    /// 已加载文件，允许消费一次显式 EOF；load / stop 清除此标记。
    private var playbackArmed = false
    /// 是否应保持「引擎与队列当前曲一致」。stop() 置 false，任何播放命令置 true。
    private var shouldPlayCurrent = false
    /// 引擎最后一次折叠进来的状态快照。快照里的引擎侧字段一律取自这里，而不是实时回读引擎 ——
    /// 这样「内存态」严格是同一份事件序列的折叠结果，与 EOF 闩锁同源，不会出现「快照已显示在播、
    /// 但闩锁还没武装」的错位窗口（实时回读会因队列回调先于引擎回调而制造该窗口）。
    ///
    /// M3 收尾修复：这份状态由**引擎同步回调**折叠（见 startObserving），不再由一个消费
    /// AsyncStream 的非结构化 Task 驱动 —— 后者在调度不利时会长时间不被唤醒，导致内存态
    /// 停在旧值（界面文案、媒体键、现场落库一起卡住）。折叠时序的语义没有变，变的只是
    /// 「谁来驱动」：从「等任务被调度」变成「状态产生方直接调用」。
    private var engineState: PlayerEngineState
    /// 缓存的音量值（0–100）。引擎不提供回读，界面音量条需要一个可发布、可回读的应用音量；
    /// 见 PlaybackSnapshot.volume 与 setVolume(_:)。
    private var volumeValue: Double = PlaybackVolumeDefaults.volume
    /// 是否已在本次播放会话里启用「播完当前曲暂停」。见 setPauseAfterCurrent 与 PlaybackSnapshot。
    private var pauseAfterCurrentValue = false
    /// 队列状态流的消费任务，deinit 时取消。
    private var observerTasks: [Task<Void, Never>] = []
    /// 引擎状态的同步订阅令牌，deinit 时取消。
    private var engineObservation: (any PlayerEngineStateObservation)?
    /// 待应用的恢复进度（移植规划 M3-T3）。见 `restore(_:resumePlayback:)`。
    private var pendingRestore: PendingRestore?

    /// 一次待应用的现场恢复：引擎真正加载起来之后才 seek / 决定播放态。
    private struct PendingRestore {
        var trackID: UUID
        /// 目标进度（秒）。
        var position: Double
        /// 恢复完成后是否立刻开始播放。
        var shouldPlay: Bool
    }

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
        activeMediaURL = initialEngineState.currentURL
        stateValue = PlaybackSnapshot(
            currentTrack: queue.currentTrack,
            isPaused: initialEngineState.isPaused,
            position: initialEngineState.position,
            duration: initialEngineState.duration,
            isCoreIdle: initialEngineState.isCoreIdle,
            queue: queue.state,
            audioTrackInfo: initialEngineState.audioTrackInfo,
            volume: volumeValue,
            pauseAfterCurrent: pauseAfterCurrentValue
        )
        startObserving()
    }

    /// 便捷构造：内部创建真实 libmpv 引擎（M1-T3 的 MPVEngine）。
    public convenience init(clientName: String = "NeriPlayer.Playback") throws {
        self.init(engine: try MPVEngine(clientName: clientName), queue: QueueManager())
    }

    deinit {
        // 先停订阅（任务与同步观察者），再结束对外流，避免状态在销毁过程中继续广播。
        for task in observerTasks {
            task.cancel()
        }
        engineObservation?.cancel()
        engineObservation = nil
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
    /// Readiness is independent of core-idle (which also includes pause/buffering).
    public var hasLoadedFile: Bool { engine.hasLoadedFile }
    /// 当前音频流规格（编码/比特率/采样率/声道/容器）；内核未报告时为 nil。
    public var audioTrackInfo: AudioTrackInfo? { snapshot.audioTrackInfo }
    /// 队列快照。
    public var queueState: QueueState { snapshot.queue }

    // MARK: - 订阅

    /// 订阅内存态变更。每次订阅返回独立新流：先推一次当前快照，之后只在快照真正变化时产出。
    public func observeState() -> AsyncStream<PlaybackSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            publicationLock.lock()
            defer { publicationLock.unlock() }
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

    // MARK: - Online resolution binding

    public func setOnlineHandlers(load: (@Sendable (Track, UUID, Bool) -> Void)?,
                                  failure: (@Sendable (Track, UUID, String) -> Void)?) {
        lock.lock()
        onlineLoadHandler = load
        onlineFailureHandler = failure
        lock.unlock()
    }

    public func isCurrentOnlineRequest(_ id: UUID, trackID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return onlineRequestID == id && queue.currentTrack?.id == trackID
    }

    @discardableResult
    func loadCachedAudio(_ url: URL, for track: Track, requestID: UUID, paused: Bool) throws -> Bool {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard isCurrentOnlineRequest(requestID, trackID: track.id) else { return false }
        lock.lock()
        activeMediaURL = url
        playbackArmed = false
        lock.unlock()
        try engine.load(url: url, paused: paused)
        publish()
        return true
    }

    @discardableResult
    public func loadResolvedAudio(_ audio: ResolvedAudio, for track: Track, requestID: UUID, paused: Bool,
                                  resumePosition: Double? = nil) throws -> Bool {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard isCurrentOnlineRequest(requestID, trackID: track.id) else { return false }
        guard let engine = engine as? any ResolvedAudioPlayerEngine else {
            throw OnlineError.unsupported("当前播放引擎不支持在线音源")
        }
        lock.lock()
        activeMediaURL = audio.url
        playbackArmed = false
        if let position = resumePosition, position.isFinite, position > 0 {
            pendingRestore = PendingRestore(trackID: track.id, position: position, shouldPlay: !paused)
        }
        lock.unlock()
        try engine.loadResolvedAudio(audio, paused: paused)
        publish()
        return true
    }

    /// Advance at most through each queue entry after failure, even in repeat-one mode.
    public func skipFailedOnlineTrack(_ trackID: UUID) {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard queue.currentTrack?.id == trackID else { return }
        let state = queue.state
        guard let index = state.currentIndex, index + 1 < state.tracks.count else { stop(); return }
        queue.jump(to: index + 1)
        loadCurrent()
    }

    // MARK: - 命令：播放当前曲 / 暂停

    /// 立刻播放指定曲目。若它已在队列中（按 id 匹配）则跳转到该曲；否则追加到队尾再跳转。
    public func playTrack(_ track: Track) {
        loadLock.lock()
        defer { loadLock.unlock() }
        selectInQueue(track)
        lock.lock()
        shouldPlayCurrent = true
        lock.unlock()
        loadCurrent()
    }

    /// 在播放/暂停之间切换。若引擎当前空闲（未加载、已停止或自然播完），则从头播放队列当前曲。
    public func togglePlayPause() {
        if !engine.hasLoadedFile || engine.currentURL == nil {
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
                // 用户要求继续播放，同时重新武装自动推进：M3-T3 恢复到暂停态的现场
                // 一开始是「不该推进」的，从这里起才该在 EOF 后接下一首。
                lock.lock()
                shouldPlayCurrent = true
                lock.unlock()
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
        loadLock.lock()
        defer { loadLock.unlock() }
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
        loadLock.lock()
        defer { loadLock.unlock() }
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
        loadLock.lock()
        defer { loadLock.unlock() }
        queue.setQueue(tracks, startAt: startIndex)
        if tracks.isEmpty {
            lock.lock()
            onlineRequestID = nil
            activeMediaURL = nil
            shouldPlayCurrent = false
            playbackArmed = false
            pendingRestore = nil
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

    /// 跳到队列中指定下标的曲目并开始播放。
    ///
    /// 与 playTrack 的区别：这是「在已知队列里的定位」，不按 id 查找、不会把不在队列里的曲目追加进来；
    /// 下标越界时不改变任何状态（只是重新发布当前快照）。队列弹层的「点某一首播」走这条路径。
    public func jump(toQueueIndex index: Int) {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard queue.jump(to: index) != nil else {
            publish()
            return
        }
        lock.lock()
        shouldPlayCurrent = true
        lock.unlock()
        loadCurrent()
    }

    /// 从队列移除指定下标的曲目。
    ///
    /// 索引语义由 QueueManager 负责（移除当前曲后选中落到同序号的下一首；移除末尾钳位；清空则无当前曲）。
    /// 本方法只补上**引擎侧**的后果：
    ///   - 移除的不是当前曲 → 队列内容变了、播放不受影响，仅发布快照；
    ///   - 移除的是当前曲 → 当前曲换成了别人，必须把新的当前曲加载进引擎并继续播放；
    ///   - 队列被清空 → 停止引擎并清掉「正在播的那一首」的在线请求等运行时标记（与 stop 同一条清理）。
    public func removeFromQueue(at index: Int) {
        loadLock.lock()
        defer { loadLock.unlock() }
        let before = queue.state
        guard before.tracks.indices.contains(index) else {
            publish()
            return
        }
        let wasCurrent = before.currentIndex == index
        guard queue.remove(at: index) != nil else {
            publish()
            return
        }
        guard let current = queue.currentTrack else {
            lock.lock()
            onlineRequestID = nil
            activeMediaURL = nil
            shouldPlayCurrent = false
            playbackArmed = false
            pendingRestore = nil
            lock.unlock()
            stopEngine()
            publish()
            return
        }
        if wasCurrent {
            lock.lock()
            shouldPlayCurrent = true
            lock.unlock()
            load(current)
        } else {
            publish()
        }
    }

    // MARK: - 命令：恢复现场（M3-T3）

    /// 恢复退出时的现场：整体采纳队列、加载当前曲，并把引擎移到保存的进度。
    ///
    /// 进度为什么不在这里直接 seek：libmpv 的 loadfile 是「下发即返回」，此刻文件还没打开，
    /// 紧接着的 seek 会被内核拒绝（M1-T3 实测）。因此把目标进度挂起，等引擎确认文件已加载
    /// （handleEngineState 收到 hasLoadedFile == true）再应用一次 —— 事件驱动，不引入定时等待，
    /// 也不会因为机器慢而在「文件还没打开」时白白丢掉一次 seek。
    ///
    /// 恢复后的播放态：`resumePlayback` 为 false 时停在保存的进度上暂停（默认，避免一启动就出声），
    /// 为 true 时加载完直接继续播。
    ///
    /// - Parameters:
    ///   - state: 保存的现场。
    ///   - resumePlayback: 恢复完成后是否自动继续播放。
    public func restore(_ state: PlayerState, resumePlayback: Bool = false) {
        loadLock.lock()
        defer { loadLock.unlock() }
        queue.restore(state.queueState)
        guard let track = state.currentTrack else {
            stop()
            return
        }
        lock.lock()
        // 恢复不是「用户要求播放」：先把自动推进闩锁放开，是否武装由 pendingRestore 决定，
        // 否则恢复出来的暂停现场一旦收到 EOF 就会自己往下切歌。
        shouldPlayCurrent = false
        playbackArmed = false
        pendingRestore = PendingRestore(trackID: track.id, position: max(0, state.position), shouldPlay: resumePlayback)
        lock.unlock()
        load(queue.currentTrack, preservingRestore: true)
    }

    /// 当前现场（供 M3-T3 落库）。位置取最近一次折叠出的引擎进度，
    /// 播放意图按「既没暂停、也不是空闲」判定。
    public func sessionState(now: Date = Date()) -> PlayerState {
        let snapshot = self.snapshot
        return PlayerState(
            queueState: snapshot.queue,
            position: snapshot.position,
            shouldResumePlayback: !snapshot.isPaused && !snapshot.isCoreIdle,
            updatedAt: now
        )
    }

    // MARK: - 命令：停止 / 转发

    /// 停止播放并卸载当前文件。队列内容保留，且不会因此自动推进下一首。
    public func stop() {
        loadLock.lock()
        defer { loadLock.unlock() }
        lock.lock()
        shouldPlayCurrent = false
        playbackArmed = false
        pendingRestore = nil
        onlineRequestID = nil
        activeMediaURL = nil
        lock.unlock()
        stopEngine()
        publish()
    }

    /// Apply M8 filters and output settings to the backend when supported.
    func applyAudioEffectsToEngine(_ settings: AudioEffectSettings) {
        (engine as? MPVEngine)?.applyAudioEffects(settings)
    }

    /// 设置应用音量（mpv 量程 0–100，可超过 100）。
    ///
    /// 引擎不提供回读，本类缓存最后一次设定值并随快照发布，界面音量条据此显示与回读。
    /// 值先夹到 0–100 再下发：越界值交给 libmpv 会被拒绝或产生意外的响度，夹取是这里唯一的合法化点。
    public func setVolume(_ volume: Double) {
        let clamped = volume.isFinite ? min(100, max(0, volume)) : PlaybackVolumeDefaults.volume
        lock.lock()
        volumeValue = clamped
        lock.unlock()
        do {
            try engine.setVolume(clamped)
        } catch {
            Log.player.error("PlaybackStateStore 设置音量失败：\(error.localizedDescription)")
        }
        publish()
    }

    /// 只把音量下发给引擎，不改动缓存的「应用音量」，也不发布快照。
    ///
    /// 供淡入淡出这类**瞬时**音量包络使用：它们逐帧改引擎音量以产生渐变，若同时改写应用音量，
    /// 界面音量条会跟着包络乱跳，用户随后松手时也会以一个中间值覆盖自己设定的音量。
    /// 因此瞬时包络与用户音量分成两条路径，只有用户/启动音量走 setVolume(_:)。
    func setTransientVolume(_ volume: Double) {
        let clamped = volume.isFinite ? min(100, max(0, volume)) : 0
        do {
            try engine.setVolume(clamped)
        } catch {
            Log.player.error("PlaybackStateStore 设置瞬时音量失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 命令：播完当前曲暂停

    /// 切换「播完当前曲暂停」。
    ///
    /// 语义（对齐 Android 版「播放完当前歌曲后暂停」）：只在本曲自然播完（EOF）时生效一次 ——
    /// 不因用户手动切歌/上一首/下一首触发，也不打断正在播放的当前曲。触发时把队列当前曲停在
    /// 你听到的位置（保持在当前曲上、不卸载、不推进），随后开关自动关闭（一次性，不常驻）。
    public func setPauseAfterCurrent(_ enabled: Bool) {
        lock.lock()
        pauseAfterCurrentValue = enabled
        lock.unlock()
        publish()
    }

    /// 当前是否启用了「播完当前曲暂停」。
    public var isPauseAfterCurrentEnabled: Bool { snapshot.pauseAfterCurrent }

    /// 若已启用一次性暂停，则消费它并返回 true（并清除标记）。
    /// EOF 推进路径在决定是否切下一首之前先问一次；不启用时返回 false，不改变既有自动推进。
    /// 已持有 lock。
    private func consumePauseAfterCurrentLocked() -> Bool {
        guard pauseAfterCurrentValue else { return false }
        pauseAfterCurrentValue = false
        return true
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

    /// 订阅引擎与队列两条状态来源：引擎状态用**同步回调**折叠，队列状态用流刷新。
    ///
    /// 为什么两条来源用不同机制：
    ///   - 引擎状态是内存态的主要输入（在播/暂停/进度/空闲），必须确定性送达，
    ///     所以用 `addStateObserver` —— 由产生状态的那段代码在自己的线程上直接调用，
    ///     不经过协作线程池调度（原先用 Task 消费流，实测在调度不利时会长时间不推进）；
    ///   - 队列的每条命令路径（enqueue / next / setMode / restore …）在改完状态后都已经
    ///     同步调用过 `publish()`，这条流只是「万一有遗漏」的兜底刷新，晚一点不影响正确性。
    private func startObserving() {
        engineObservation = engine.addStateObserver { [weak self] state in
            self?.handleEngineState(state)
        }
        let queueStream = queue.observeState()
        observerTasks.append(Task(priority: .userInitiated) { [weak self] in
            for await _ in queueStream {
                guard let self else { return }
                publish()
            }
        })
    }

    /// 处理一次引擎状态：维护 EOF 闩锁，应用待恢复的现场，必要时按队列模式自动推进。
    private func handleEngineState(_ state: PlayerEngineState) {
        var advanceTo: Track?
        var restore: PendingRestore?
        var failure: (track: Track, detail: (token: UUID, message: String))?
        lock.lock()
        engineState = state
        let stillCurrent = state.currentURL == (activeMediaURL ?? queue.currentTrack?.url)
        if let message = state.playbackError, stillCurrent,
           let track = queue.currentTrack, track.onlineSong != nil, let token = onlineRequestID {
            failure = (track, (token, message))
        }
        let failureHandler = onlineFailureHandler
        if state.hasEnded {
            if playbackArmed, shouldPlayCurrent, stillCurrent {
                playbackArmed = false
                // 一次性暂停优先于自动推进：用户勾了「播完当前曲暂停」，本曲自然结束后应停在当前曲，
                // 不切下一首（也不重播）。消费掉这个一次性标记后，后续 EOF 恢复成正常的队列推进。
                if consumePauseAfterCurrentLocked() {
                    shouldPlayCurrent = false
                    Log.player.info("PlaybackStateStore：播完当前曲，按一次性暂停停在当前曲")
                } else {
                    advanceTo = advanceAfterEndLocked()
                }
            }
        } else if state.hasLoadedFile, stillCurrent {
            playbackArmed = true
            if let pending = pendingRestore, pending.trackID == queue.currentTrack?.id {
                pendingRestore = nil
                restore = pending
            }
        }
        lock.unlock()

        publish()
        if let failure { failureHandler?(failure.track, failure.detail.token, failure.detail.message) }
        if let restore {
            applyRestore(restore)
        }
        if let advanceTo {
            // Never wait for the command lock from mpv's lifecycle callback thread.
            Task { [weak self] in self?.loadAfterEnd(advanceTo) }
        }
    }

    /// 应用一次挂起的现场恢复：先跳转到保存的进度，再按意图决定播放还是暂停。
    ///
    /// 顺序不能颠倒：loadfile 会把 pause 清掉（M1-T3），先 play 再 seek 会让「恢复到暂停态」
    /// 在暂停生效前响一小段。
    private func applyRestore(_ pending: PendingRestore) {
        guard pending.trackID == queue.currentTrack?.id,
              engine.currentURL == (activeMediaURL ?? queue.currentTrack?.url) else { return }
        do {
            if pending.position > 0 {
                try engine.seek(to: pending.position)
            }
            if pending.shouldPlay {
                lock.lock()
                shouldPlayCurrent = true
                lock.unlock()
                try engine.play()
            } else {
                try engine.pause()
            }
        } catch {
            Log.player.error("PlaybackStateStore 应用恢复现场失败：\(error.localizedDescription)")
        }
        publish()
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

    private func loadAfterEnd(_ track: Track) {
        loadLock.lock()
        defer { loadLock.unlock() }
        lock.lock()
        let allowed = shouldPlayCurrent && queue.currentTrack?.id == track.id
        lock.unlock()
        if allowed { load(track) }
    }

    /// 把队列当前曲加载进引擎。
    private func loadCurrent() {
        load(queue.currentTrack)
    }

    /// 加载指定曲目（nil 则什么都不做）。加载前清 EOF 闩锁，避免加载过程中的空闲被误判成 EOF。
    private func load(_ track: Track?, preservingRestore: Bool = false) {
        guard let track else {
            publish()
            return
        }
        loadLock.lock()
        defer { loadLock.unlock() }
        lock.lock()
        playbackArmed = false
        activeMediaURL = nil
        onlineRequestID = nil
        if !preservingRestore { pendingRestore = nil }
        let initiallyPaused = pendingRestore.map { !$0.shouldPlay } ?? false
        let handler = onlineLoadHandler
        let token = UUID()
        if track.onlineSong != nil { onlineRequestID = token }
        lock.unlock()
        if track.onlineSong != nil {
            stopEngine()
            if let handler { handler(track, token, initiallyPaused) } else { Log.player.error("在线音源解析器未就绪") }
            publish()
            return
        }
        do {
            try engine.load(url: track.url, paused: initiallyPaused)
            Log.player.info("PlaybackStateStore 加载本地曲目")
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
            queue: queueSnapshot,
            playbackError: engineState.playbackError,
            audioTrackInfo: engineState.audioTrackInfo,
            volume: volumeValue,
            pauseAfterCurrent: pauseAfterCurrentValue
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
        publicationLock.lock()
        defer { publicationLock.unlock() }
        lock.lock()
        let next = currentSnapshot()
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
