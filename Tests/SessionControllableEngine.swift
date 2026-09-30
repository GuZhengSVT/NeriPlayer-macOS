// SessionControllableEngine.swift — deterministic playback-session test fixture.
import Foundation
@testable import NeriPlayer

/// 可控播放引擎：命令同步翻转状态并推流。
///
/// 为什么同步：store 的恢复逻辑依赖「先收到加载完成、再下发 seek」这一事件顺序。
/// 若把状态翻转放进 Task，事件会与调用线程竞争，测试就变成时序断言（与 PlaybackStateStoreTests
/// 的同名替身同一取舍）。
final class SessionControllableEngine: PlayerEngine, @unchecked Sendable {

    private let lock = NSLock()
    private var stateValue: PlayerEngineState = .idle
    private var continuations: [UUID: AsyncStream<PlayerEngineState>.Continuation] = [:]
    /// 同步状态观察者的广播器。
    private let stateBroadcaster = PlayerEngineStateBroadcaster()
    private var seekHistory: [Double] = []
    private let loadDuration: Double

    init(duration: Double = 180) {
        loadDuration = duration
    }

    var currentURL: URL? { snapshot.currentURL }
    var isPaused: Bool { snapshot.isPaused }
    var position: Double { snapshot.position }
    var duration: Double { snapshot.duration }
    var isCoreIdle: Bool { snapshot.isCoreIdle }

    /// 收到过的 seek 位置（按顺序）。
    var seeks: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return seekHistory
    }

    func load(url: URL) throws {
        guard url.isFileURL else { throw PlayerEngineError.unsupportedURL(url) }
        mutate { state in
            state.currentURL = url
            state.position = 0
            state.duration = loadDuration
            state.isPaused = false
            state.isCoreIdle = false
            state.hasLoadedFile = true
            state.hasEnded = false
        }
    }

    func play() throws {
        guard snapshot.currentURL != nil else { throw PlayerEngineError.noCurrentItem }
        mutate { $0.isPaused = false }
    }

    func pause() throws {
        guard snapshot.currentURL != nil else { throw PlayerEngineError.noCurrentItem }
        mutate { $0.isPaused = true }
    }

    func stop() throws {
        mutate { $0 = .idle }
    }

    func seek(to seconds: Double) throws {
        guard snapshot.currentURL != nil else { throw PlayerEngineError.noCurrentItem }
        lock.lock()
        seekHistory.append(seconds)
        lock.unlock()
        mutate { $0.position = seconds }
    }

    func setVolume(_ volume: Double) throws {}

    /// 模拟 time-pos 推进（真实引擎里由 mpv 事件驱动）。
    func advance(to position: Double) {
        mutate { $0.position = position }
    }

    /// 同步状态观察者（与生产实现同一套语义，见 PlayerEngineObservation.swift）。
    func addStateObserver(
        _ handler: @escaping @Sendable (PlayerEngineState) -> Void
    ) -> any PlayerEngineStateObservation {
        stateBroadcaster.add(handler)
    }

    func observeState() -> AsyncStream<PlayerEngineState> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
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

    private var snapshot: PlayerEngineState {
        lock.lock()
        defer { lock.unlock() }
        return stateValue
    }

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
        // 与 MPVEngine 同序：先同步广播（必须及时的那条），再 yield 到流。
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
}

/// 本文件内部错误标记。
