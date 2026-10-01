// MPVEngine.swift
// NeriPlayer macOS —— PlayerEngine 的 libmpv 实现（移植规划 M1-T3）。
//
// 结构：内部持有一个 MPVController（M1-T2），把 controller.observe 的
// time-pos / duration / pause / core-idle 四条属性流桥接成引擎状态，再以 AsyncStream 广播快照。
// 本文件不改动 MPVController：所需能力（loadFile / play / pause / stop / seek / setVolume / observe）
// M1-T2 已全部提供。
//
// 桥接规则（均为实机探针实测结论，见 M1-T3 报告）：
//   - time-pos / duration 变为 unavailable 表示「当前没有有效文件」，映射为 0；
//   - 自然播完后 libmpv 会自行卸载文件：time-pos/duration 转 unavailable、core-idle 回 true。
//     协议约定 currentURL 只在 stop() 时清空，故 EOF 后 currentURL 保留；
//     此时 seek 会被 libmpv 以 -12（error running command）拒绝，切歌交由 M1-T4 队列处理；
//   - libmpv 的 pause 是核心属性，不随 loadfile 复位；且在 paused 状态下 stop 后仍为 true。
//     因此 load() 在 loadfile 之后、stop() 在 stop 之后都显式清 pause ：
//     否则状态会与内核不一致，且后续 pause() 会命中「已是 true」而变成空操作。
//   - loadfile 是「下发即返回」：文件不存在时命令同样返回成功，失败只体现为
//     core-idle 始终不回落到「播放中」，因此 load(url:) 不承诺文件可播。
//
// 线程模型：libmpv 的回调在事件线程，订阅者在各自任务上下文；状态读写全部由 lock 串行化，
// yield 一律在锁外执行。
//
// 边界（不做）：播放队列（M1-T4）、持久化（M1-T4/M3）、媒体键（M1-T6）、输出设备（M1-T7）、
// 音效链路（M1-T8）。

import Foundation

/// 单文件播放引擎的 libmpv 实现。
public final class MPVEngine: PlayerEngine, ResolvedAudioPlayerEngine, @unchecked Sendable {

    /// 保护 stateValue 与 continuations：属性事件线程与调用者线程会交汇。
    private let lock = NSLock()
    private let lifecycleLock = NSRecursiveLock()
    private var currentEntryID: Int64?
    private var fileObservation: (any MPVPropertyObservation)?
    private var stateValue: PlayerEngineState = .idle
    private var continuations: [UUID: AsyncStream<PlayerEngineState>.Continuation] = [:]

    /// M1-T2 的 libmpv 封装；本类只通过其公开 API 访问内核。
    private let controller: MPVController
    private var audioTransport: OnlineAudioTransport?
    private var playbackCache: PlaybackAudioCache?

    func setPlaybackCache(_ cache: PlaybackAudioCache?) {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        playbackCache = cache
    }
    /// 四条属性的同步订阅令牌，deinit 时取消。
    private var propertyObservations: [any MPVPropertyObservation] = []
    /// 同步状态观察者（M3 收尾修复）：状态一变就在事件线程上直接通知订阅者，
    /// 不经过协作线程池调度。见 PlayerEngineObservation.swift 的说明。
    private let stateBroadcaster = PlayerEngineStateBroadcaster()

    /// 创建引擎并开始桥接内核属性。
    /// - Parameters:
    ///   - clientName: 仅用于日志区分同进程内的多个实例。
    ///   - options: mpv 启动选项（见 MPVLaunchOption）。测试夹具传 `.silentAudio` 以免真机出声。
    public init(clientName: String = "NeriPlayer.Engine", options: [MPVLaunchOption] = []) throws {
        controller = try MPVController(clientName: clientName, options: options)
        startObserving()
    }

    deinit {
        audioTransport?.stop()
        fileObservation?.cancel()
        // 先停同步订阅，再结束对外流，避免状态在销毁过程中继续广播。
        for observation in propertyObservations {
            observation.cancel()
        }
        propertyObservations.removeAll()
        lock.lock()
        let listeners = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for listener in listeners {
            listener.finish()
        }
    }

    // MARK: - 只读状态

    public var currentURL: URL? { snapshot.currentURL }
    public var isPaused: Bool { snapshot.isPaused }
    public var position: Double { snapshot.position }
    public var duration: Double { snapshot.duration }
    public var isCoreIdle: Bool { snapshot.isCoreIdle }
    public var hasEnded: Bool { snapshot.hasEnded }
    public var hasLoadedFile: Bool { snapshot.hasLoadedFile }
    public var state: PlayerEngineState { snapshot }

    // MARK: - 命令

    public func load(url: URL) throws {
        try load(url: url, paused: false)
    }

    public func load(url: URL, paused: Bool) throws {
        guard url.isFileURL else { throw PlayerEngineError.unsupportedURL(url) }
        try loadMedia(url: url, headers: [:], paused: paused)
    }

    public func loadResolvedAudio(_ audio: ResolvedAudio, paused: Bool) throws {
        guard let scheme = audio.url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              audio.url.host != nil, audio.url.user == nil, audio.url.password == nil else {
            throw PlayerEngineError.unsupportedURL(audio.url)
        }
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if audio.song.source == .youtubeMusic {
            audioTransport?.stop()
            let transport = try OnlineAudioTransport(cache: playbackCache)
            audioTransport = transport
            let local = try transport.register(audio)
            try loadMedia(url: audio.url, headers: [:], paused: paused, transportURL: local)
        } else {
            try loadMedia(url: audio.url, headers: audio.headers, paused: paused)
        }
    }

    private func loadMedia(url: URL, headers: [String: String], paused: Bool, transportURL: URL? = nil) throws {
        var fields = try OnlinePlaybackHeaders.validated(headers)
        let userAgentKey = fields.keys.first { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }
        let userAgent = userAgentKey.flatMap { fields.removeValue(forKey: $0) } ?? "NeriPlayer/0.1"
        let refererKey = fields.keys.first { $0.caseInsensitiveCompare("Referer") == .orderedSame }
        let referer = refererKey.flatMap { fields.removeValue(forKey: $0) } ?? ""
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if transportURL == nil { audioTransport?.stop(); audioTransport = nil }
        currentEntryID = nil
        // 先复位为新文件状态，再下发命令。顺序很关键：duration 只在文件打开后推一次，
        // 若先下命令再复位，事件线程可能在复位前把新 duration 送进来、随后被复位成 0，
        // 于是 duration 会一直停在 0。先前解新内容在时序上不会覆盖后到的新值。
        mutate { state in
            state.currentURL = url
            state.position = 0
            state.duration = 0
            state.isPaused = paused
            state.isCoreIdle = true
            state.hasEnded = false
            state.hasLoadedFile = false
            state.playbackError = nil
        }
        do {
            try perform {
                // Pause before loading so a restored paused session never emits audio.
                try controller.setStringList("http-header-fields", fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })
                try controller.setString("user-agent", userAgent)
                try controller.setString("referrer", referer)
                try controller.setString("ytdl", "no")
                try controller.setString("http-proxy", url.isFileURL || transportURL != nil ? "" : (OnlineProxySettings.systemProxy(for: url) ?? ""))
                try controller.setFlag("pause", paused)
                try controller.loadFile(transportURL?.absoluteString ?? (url.isFileURL ? url.path : url.absoluteString))
                currentEntryID = try controller.getInt64("playlist/0/id")
            }
        } catch {
            // 命令未受理时不留下「已加载」的假状态。
            mutate { $0 = .idle }
            throw error
        }
        Log.player.info("MPVEngine 加载：在线=\(!url.isFileURL)，host=\(url.host ?? "local", privacy: .public)")
    }

    public func play() throws {
        try requireCurrentItem()
        try perform { try controller.play() }
    }

    public func pause() throws {
        try requireCurrentItem()
        try perform { try controller.pause() }
    }

    public func stop() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        currentEntryID = nil
        audioTransport?.stop(); audioTransport = nil
        try perform {
            try controller.stop()
            // 同 load：paused 状态下 stop 后内核 pause 仍为 true，需显式复位。
            try controller.play()
        }
        mutate { $0 = .idle }
    }

    public func seek(to seconds: Double) throws {
        try requireCurrentItem()
        try perform { try controller.seek(to: seconds) }
    }

    public func setVolume(_ volume: Double) throws {
        try perform { try controller.setVolume(volume) }
    }

    func applyAudioEffects(_ settings: AudioEffectSettings) {
        do {
            try perform {
                try controller.setDouble("volume-gain-max", 15)
                try controller.setDouble("volume-gain", settings.loudnessEnabled ? settings.loudnessGain : 0)
                try controller.setString("af", settings.enabled ? AudioEffectCommandPlan.filterString(for: settings) : "")
                if let device = settings.outputDevice {
                    try controller.setString("audio-device", device)
                }
                try controller.setString("ao", settings.exclusiveOutput ? "coreaudio_exclusive" : "coreaudio")
            }
        } catch {
            Log.player.error("应用音效设置失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 状态订阅

    public func observeState() -> AsyncStream<PlayerEngineState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.lock()
            let current = stateValue
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
            // 先推一次当前快照，订阅者不必额外读一遍属性。
            continuation.yield(current)
        }
    }

    /// 同步注册状态观察者（见 PlayerEngine.addStateObserver 的说明）。
    public func addStateObserver(
        _ handler: @escaping @Sendable (PlayerEngineState) -> Void
    ) -> any PlayerEngineStateObservation {
        stateBroadcaster.add(handler)
    }

    // MARK: - 属性桥接

    /// 订阅四条内核属性，把变更折叠进状态快照。
    ///
    /// 用同步订阅（addPropertyObserver）而不是消费属性流：属性流要等一个消费任务被调度才会
    /// 把变更交到这里，实测在调度不利时这一步会拖很久，导致引擎状态迟迟不更新，
    /// 连带把内存态、界面文案与现场落库一起拖住。同步订阅在 mpv 事件线程上直接回调，
    /// 折叠时序与原先完全一致（仍按事件到达顺序逐条 apply），变的是「谁来驱动」。
    private func startObserving() {
        fileObservation = controller.addFileObserver { [weak self] event in
            self?.applyFileEvent(event)
        }
        let properties: [MPVProperty] = [.timePosition, .duration, .paused, .coreIdle]
        for property in properties {
            let observation = controller.addPropertyObserver(property) { [weak self] change in
                self?.apply(change)
            }
            propertyObservations.append(observation)
        }
    }

    private func applyFileEvent(_ event: MPVFileEvent) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        switch event {
        case .loaded(let entryID):
            guard entryID == currentEntryID else { return }
            mutate { $0.hasLoadedFile = true; $0.playbackError = nil }
        case .ended(let entryID, let reachedEOF):
            guard entryID == currentEntryID else { return }
            mutate {
                $0.hasLoadedFile = false
                $0.hasEnded = reachedEOF
                $0.isCoreIdle = true
            }
        case .failed(let entryID, let errorCode):
            guard entryID == currentEntryID else { return }
            mutate {
                $0.hasLoadedFile = false
                $0.hasEnded = false
                $0.isCoreIdle = true
                $0.playbackError = "音频加载或播放失败（mpv \(errorCode)）"
            }
        }
    }

    /// 把一次属性变更折叠进状态。只在事件线程调用。
    private func apply(_ change: MPVPropertyChange) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        switch change.property {
        case MPVProperty.timePosition.rawValue:
            mutate { $0.position = change.doubleValue ?? 0 }
        case MPVProperty.duration.rawValue:
            mutate { $0.duration = change.doubleValue ?? 0 }
        case MPVProperty.paused.rawValue:
            guard let paused = change.flagValue else { return }
            mutate { $0.isPaused = paused }
        case MPVProperty.coreIdle.rawValue:
            guard let idle = change.flagValue else { return }
            mutate { $0.isCoreIdle = idle }
        default:
            break
        }
    }

    // MARK: - 内部

    /// 读取当前快照。
    private var snapshot: PlayerEngineState {
        lock.lock()
        defer { lock.unlock() }
        return stateValue
    }

    /// 原地修改状态；仅在快照真的变化时向订阅者广播（锁外 yield）。
    ///
    /// 两条通知路径都走这里，保证语义一致：同步观察者与异步流拿到的是**同一份**状态序列。
    private func mutate(_ body: (inout PlayerEngineState) -> Void) {
        lock.lock()
        var next = stateValue
        body(&next)
        guard next != stateValue else {
            lock.unlock()
            return
        }
        stateValue = next
        let listeners = Array(continuations.values)
        lock.unlock()
        // 先同步广播，再 yield 到流：同步路径是「必须及时」的那条，优先送达。
        stateBroadcaster.broadcast(next)
        for listener in listeners {
            listener.yield(next)
        }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }

    /// 播放/暂停/跳转要求已加载项；停止与音量设置不要求。
    private func requireCurrentItem() throws {
        guard snapshot.currentURL != nil else {
            throw PlayerEngineError.noCurrentItem
        }
    }

    /// 把 libmpv 的错误统一转成 PlayerEngineError，不向上泄漏 MPVError。
    private func perform(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as PlayerEngineError {
            throw error
        } catch {
            throw PlayerEngineError.backend(error)
        }
    }
}
