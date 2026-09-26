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
public final class MPVEngine: PlayerEngine, @unchecked Sendable {

    /// 保护 stateValue 与 continuations：属性事件线程与调用者线程会交汇。
    private let lock = NSLock()
    private var stateValue: PlayerEngineState = .idle
    private var continuations: [UUID: AsyncStream<PlayerEngineState>.Continuation] = [:]

    /// M1-T2 的 libmpv 封装；本类只通过其公开 API 访问内核。
    private let controller: MPVController
    /// 四条属性流的消费任务，deinit 时取消。
    private var observerTasks: [Task<Void, Never>] = []

    /// 创建引擎并开始桥接内核属性。
    /// - Parameter clientName: 仅用于日志区分同进程内的多个实例。
    public init(clientName: String = "NeriPlayer.Engine") throws {
        controller = try MPVController(clientName: clientName)
        startObserving()
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

    // MARK: - 只读状态

    public var currentURL: URL? { snapshot.currentURL }
    public var isPaused: Bool { snapshot.isPaused }
    public var position: Double { snapshot.position }
    public var duration: Double { snapshot.duration }
    public var isCoreIdle: Bool { snapshot.isCoreIdle }

    // MARK: - 命令

    public func load(url: URL) throws {
        guard url.isFileURL else {
            throw PlayerEngineError.unsupportedURL(url)
        }
        // 先复位为新文件状态，再下发命令。顺序很关键：duration 只在文件打开后推一次，
        // 若先下命令再复位，事件线程可能在复位前把新 duration 送进来、随后被复位成 0，
        // 于是 duration 会一直停在 0。先前解新内容在时序上不会覆盖后到的新值。
        mutate { state in
            state.currentURL = url
            state.position = 0
            state.duration = 0
            state.isPaused = false
        }
        do {
            try perform {
                try controller.loadFile(url.path)
                // 显式清 pause：内核的 pause 不随 loadfile 复位（实测）。
                try controller.play()
            }
        } catch {
            // 命令未受理时不留下「已加载」的假状态。
            mutate { $0 = .idle }
            throw error
        }
        Log.player.info("MPVEngine 加载：\(url.lastPathComponent)")
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

    // MARK: - 属性桥接

    /// 订阅四条内核属性，把变更折叠进状态快照。
    private func startObserving() {
        let properties: [MPVProperty] = [.timePosition, .duration, .paused, .coreIdle]
        for property in properties {
            let stream = controller.observe(property, bufferingNewest: 64)
            let task = Task { [weak self] in
                for await change in stream {
                    guard let self else { return }
                    self.apply(change)
                }
            }
            observerTasks.append(task)
        }
    }

    /// 把一次属性变更折叠进状态。只在事件线程调用。
    private func apply(_ change: MPVPropertyChange) {
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
