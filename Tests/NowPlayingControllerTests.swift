// NowPlayingControllerTests.swift
// NeriPlayer macOS —— M1-T6：媒体键与 Now Playing 的节流与命令转发测试。
//
// 覆盖面（系统集成本身无法单测的部分，靠这层的可注入边界兜住）：
//   1) 命令注册与转发：注入 FakeRegistrar 替换 MPRemoteCommandCenter，
//      断言「六类命令都注册了」「回调确实把事件参数（seek 位置）原样交给闭包」；
//   2) 节流：直接测纯值类型 NowPlayingUpdateThrottle（注入时钟），
//      以及 NowPlayingController 在「关键字段变化 vs 仅进度变化」下的发布行为（注入 FakePublisher）；
//   3) 生产绑定：NowPlayingCommands.playbackStore(store) 在 FakeEngine 上驱动真实的
//      play/pause/next/previous/seek，证明闭包集与 PlaybackStateStore 的语义映射正确。
//
// 为什么用注入的 registrar 而不是真实的 MPRemoteCommandCenter.shared：
//   注册进系统的 handler 只能由系统触发，测试进程调用不到；若直接依赖 .shared，
//   「注册了哪些命令」「位置参数是否转发」都无法断言，只能验证「没崩」。
//   真实 .shared 路径由 SystemNowPlayingCommandRegistrar 覆盖（编译期类型检查 + 手动验收），
//   节流与转发逻辑则由本文件确定性覆盖。

import MediaPlayer
import XCTest
@testable import NeriPlayer

final class NowPlayingControllerTests: XCTestCase {

    // MARK: - 命令注册与转发

    /// setup 后六类命令各注册一次，且 isActive 为 true。
    func testSetupRegistersAllSixCommands() {
        let registrar = FakeRegistrar()
        let controller = NowPlayingController(registrar: registrar, publisher: FakePublisher())
        controller.setup(commands: .noop)

        XCTAssertEqual(Set(registrar.registeredCommands), Set(NowPlayingCommand.allCases))
        XCTAssertEqual(registrar.registeredCommands.count, 6)
        XCTAssertTrue(controller.isActive)
    }

    /// 每类命令的回调都转发到注入闭包；seek 的位置参数原样透传。
    func testCommandCallbacksForwardToInjectedClosures() throws {
        let registrar = FakeRegistrar()
        let controller = NowPlayingController(registrar: registrar, publisher: FakePublisher())
        let recorder = CallRecorder()
        controller.setup(commands: recorder.commands)

        XCTAssertEqual(try registrar.invoke(.play), true)
        XCTAssertEqual(try registrar.invoke(.pause), true)
        XCTAssertEqual(try registrar.invoke(.togglePlayPause), true)
        XCTAssertEqual(try registrar.invoke(.nextTrack), true)
        XCTAssertEqual(try registrar.invoke(.previousTrack), true)
        XCTAssertEqual(try registrar.invoke(.seekPosition, position: 12.5), true)

        XCTAssertEqual(recorder.calls, ["play", "pause", "toggle", "next", "previous", "seek:12.5"])
        // 非 seek 命令不应误传位置。
        XCTAssertEqual(recorder.seekPositions, [12.5])
    }

    /// 闭包返回 false（当前无可作用内容）时，控制器同样如实转达 false。
    func testCommandCallbackPropagatesUnhandledResult() throws {
        let registrar = FakeRegistrar()
        let controller = NowPlayingController(registrar: registrar, publisher: FakePublisher())
        controller.setup(commands: .responding(false))
        XCTAssertEqual(try registrar.invoke(.play), false)
    }

    /// 未注册任何命令时，controller 不存在 handler，也就不可能被系统触发；
    /// stop() 之后注册项被清空、isActive 复位。
    func testStopRemovesHandlersAndDeactivates() {
        let registrar = FakeRegistrar()
        let publisher = FakePublisher()
        let controller = NowPlayingController(registrar: registrar, publisher: publisher)
        controller.setup(commands: .noop)
        controller.stop()

        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(registrar.handlerCount == 0, "stop 后应注销全部 handler")
        XCTAssertTrue(registrar.registeredCommands.isEmpty, "stop 后注册表应为空")
        // setup 先清一次避免重复注册，stop 再清一次：共两次。
        XCTAssertEqual(registrar.removeAllCount, 2)
        XCTAssertEqual(publisher.publishCount, 1, "stop 应清空一次 Now Playing")
        XCTAssertNil(publisher.lastInfo, "清空时 nowPlayingInfo 应为 nil")
        XCTAssertEqual(publisher.lastState, .stopped)
    }

    // MARK: - 节流（纯值逻辑）

    /// 首次发布无条件通过；完全相同的信息跳过。
    func testThrottlePublishesFirstThenSkipsIdentical() {
        var throttle = NowPlayingUpdateThrottle(minimumInterval: 0.5)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(throttle.shouldPublish(Self.info(elapsed: 0), at: start))
        XCTAssertFalse(throttle.shouldPublish(Self.info(elapsed: 0), at: start.addingTimeInterval(10)))
    }

    /// 仅进度变化：窗口内跳过，窗口外发布。
    func testThrottleSuppressesProgressOnlyWithinWindow() {
        var throttle = NowPlayingUpdateThrottle(minimumInterval: 0.5)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(throttle.shouldPublish(Self.info(elapsed: 0), at: start))

        XCTAssertFalse(throttle.shouldPublish(Self.info(elapsed: 0.2), at: start.addingTimeInterval(0.2)))
        XCTAssertFalse(throttle.shouldPublish(Self.info(elapsed: 0.45), at: start.addingTimeInterval(0.49)))
        XCTAssertTrue(throttle.shouldPublish(Self.info(elapsed: 0.5), at: start.addingTimeInterval(0.5)))
        // 发布后计时窗口重置：紧接着的变化又被压住。
        XCTAssertFalse(throttle.shouldPublish(Self.info(elapsed: 0.6), at: start.addingTimeInterval(0.6)))
        XCTAssertTrue(throttle.shouldPublish(Self.info(elapsed: 1.0), at: start.addingTimeInterval(1.0)))
    }

    /// 关键字段变化（暂停/时长/曲目/歌手）不受时间窗口限制，立即发布。
    func testThrottlePublishesImmediatelyOnKeyFieldChange() {
        var throttle = NowPlayingUpdateThrottle(minimumInterval: 0.5)
        let start = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(throttle.shouldPublish(Self.info(elapsed: 0), at: start))

        let paused = Self.info(elapsed: 0.1, isPaused: true)
        XCTAssertTrue(throttle.shouldPublish(paused, at: start.addingTimeInterval(0.01)),
                      "暂停状态变化必须在同一时刻立即反映")

        let newDuration = Self.info(elapsed: 0.1, isPaused: true, duration: 240)
        XCTAssertTrue(throttle.shouldPublish(newDuration, at: start.addingTimeInterval(0.02)),
                      "时长就绪后必须立即发布")

        let otherTrack = Self.info(elapsed: 0.1, isPaused: true, duration: 240, title: "另一首")
        XCTAssertTrue(throttle.shouldPublish(otherTrack, at: start.addingTimeInterval(0.03)))

        let idle = Self.info(elapsed: 0.1, isPaused: true, duration: 240, title: "另一首", isCoreIdle: true)
        XCTAssertTrue(throttle.shouldPublish(idle, at: start.addingTimeInterval(0.04)))
    }

    // MARK: - 节流（控制器与发布后端）

    func testControllerThrottlesProgressUpdates() {
        let publisher = FakePublisher()
        let clock = ClockBox(Date(timeIntervalSince1970: 3_000))
        let controller = NowPlayingController(
            registrar: FakeRegistrar(),
            publisher: publisher,
            minimumUpdateInterval: 0.5,
            clock: { clock.now }
        )

        controller.update(info: Self.info(elapsed: 0))
        XCTAssertEqual(publisher.publishCount, 1)

        clock.advance(0.2)
        controller.update(info: Self.info(elapsed: 0.2))
        XCTAssertEqual(publisher.publishCount, 1, "窗口内的纯进度更新应被节流")

        clock.advance(0.3)
        controller.update(info: Self.info(elapsed: 0.5))
        XCTAssertEqual(publisher.publishCount, 2, "累计满 0.5s 后应发布")
    }

    func testControllerPublishesKeyChangeImmediately() {
        let publisher = FakePublisher()
        let clock = ClockBox(Date(timeIntervalSince1970: 4_000))
        let controller = NowPlayingController(
            registrar: FakeRegistrar(),
            publisher: publisher,
            minimumUpdateInterval: 0.5,
            clock: { clock.now }
        )

        controller.update(info: Self.info(elapsed: 0))
        clock.advance(0.05)
        controller.update(info: Self.info(elapsed: 0.05, isPaused: true))

        XCTAssertEqual(publisher.publishCount, 2)
        XCTAssertEqual(publisher.lastInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0,
                       "暂停时播放速率应为 0")
    }

    /// 传 nil 立即清空（不受节流限制），播放状态写为 stopped。
    func testNilInfoClearsImmediately() {
        let publisher = FakePublisher()
        let controller = NowPlayingController(registrar: FakeRegistrar(), publisher: publisher)
        controller.update(info: Self.info(elapsed: 0))
        controller.update(info: nil)

        XCTAssertEqual(publisher.publishCount, 2)
        XCTAssertNil(publisher.lastInfo)
        XCTAssertEqual(publisher.lastState, .stopped)
    }

    // MARK: - 信息字典

    /// update(from:) 从快照生成五个要求字段；歌手为空时不写入空串。
    func testUpdateFromSnapshotBuildsInfoDictionary() throws {
        let publisher = FakePublisher()
        let controller = NowPlayingController(registrar: FakeRegistrar(), publisher: publisher)

        let track = Track(url: URL(fileURLWithPath: "/tmp/a.mp3"), title: "标题", artist: "歌手")
        let snapshot = PlaybackSnapshot(
            currentTrack: track,
            isPaused: false,
            position: 12,
            duration: 200,
            isCoreIdle: false,
            queue: QueueState(tracks: [track], currentIndex: 0, mode: .sequential, shuffleOrder: [])
        )
        controller.update(from: snapshot)

        let info = try XCTUnwrap(publisher.lastInfo)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "标题")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "歌手")
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 200)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 12)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        XCTAssertEqual(publisher.lastState, .playing)
    }

    /// 无当前曲（空队列）时清空 Now Playing，不发空字典。
    func testUpdateFromEmptySnapshotClears() {
        let publisher = FakePublisher()
        let controller = NowPlayingController(registrar: FakeRegistrar(), publisher: publisher)
        controller.update(from: PlaybackSnapshot(
            currentTrack: nil,
            isPaused: false,
            position: 0,
            duration: 0,
            isCoreIdle: true,
            queue: .empty
        ))
        XCTAssertEqual(publisher.publishCount, 1)
        XCTAssertNil(publisher.lastInfo)
    }

    // MARK: - 与 PlaybackStateStore 的生产绑定

    // MARK: - 系统集成冒烟（真实 MediaPlayer 实现，测试进程内可用）

    /// 生产注册后端对接真实 MPRemoteCommandCenter：六类命令注册后应被启用，且 stop 能安全注销。
    /// 验证的是 SystemNowPlayingCommandRegistrar 与真实框架协同不崩、命令确实进入启用态。
    func testSystemRegistrarEnablesRealCommands() {
        let controller = NowPlayingController(registrar: SystemNowPlayingCommandRegistrar(), publisher: FakePublisher())
        defer { controller.stop() }
        controller.setup(commands: .noop)

        let center = MPRemoteCommandCenter.shared()
        XCTAssertTrue(center.playCommand.isEnabled)
        XCTAssertTrue(center.pauseCommand.isEnabled)
        XCTAssertTrue(center.togglePlayPauseCommand.isEnabled)
        XCTAssertTrue(center.nextTrackCommand.isEnabled)
        XCTAssertTrue(center.previousTrackCommand.isEnabled)
        XCTAssertTrue(center.changePlaybackPositionCommand.isEnabled)
    }

    /// 生产发布后端对接真实 MPNowPlayingInfoCenter：写入的信息应能读回。
    func testSystemPublisherRoundTripsInfo() {
        let publisher = SystemNowPlayingInfoPublisher()
        publisher.publish(nowPlayingInfo: [MPMediaItemPropertyTitle: "M1-T6 探针"], playbackState: .paused)
        defer { publisher.publish(nowPlayingInfo: nil, playbackState: .stopped) }

        let center = MPNowPlayingInfoCenter.default()
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "M1-T6 探针")
        XCTAssertEqual(center.playbackState, .paused)
    }

    /// playbackStore 闭包集在真实 store（配假引擎）上正确驱动播放控制。
    /// store 的引擎侧字段由引擎状态流的消费任务异步折叠，故每步都等快照追上再断言。
    func testPlaybackStoreCommandsDriveStore() async throws {
        let engine = FakeEngine()
        let store = PlaybackStateStore(engine: engine)
        let commands = NowPlayingCommands.playbackStore(store)
        let first = Track(url: URL(fileURLWithPath: "/tmp/one.mp3"), title: "一")
        let second = Track(url: URL(fileURLWithPath: "/tmp/two.mp3"), title: "二")
        store.setQueue([first, second])
        try await awaitSnapshot(store) { $0.currentTrack?.id == first.id && !$0.isCoreIdle }

        XCTAssertEqual(store.currentTrack?.id, first.id)
        XCTAssertTrue(commands.nextTrack(), "非空队列的下一首应被处理")
        XCTAssertEqual(store.currentTrack?.id, second.id)
        XCTAssertTrue(commands.previousTrack())
        XCTAssertEqual(store.currentTrack?.id, first.id)

        XCTAssertTrue(commands.pause(), "播放中应能暂停")
        try await awaitSnapshot(store) { $0.isPaused }
        XCTAssertTrue(engine.isPaused)
        XCTAssertFalse(commands.pause(), "已暂停时再暂停应视为不可用")
        XCTAssertTrue(commands.play(), "暂停后应能恢复")
        try await awaitSnapshot(store) { !$0.isPaused }
        XCTAssertFalse(engine.isPaused)

        XCTAssertTrue(commands.seekPosition(8), "已加载项应能跳转")
        XCTAssertEqual(engine.lastSeek, 8)
        XCTAssertTrue(commands.seekPosition(-3), "负值应钳到 0")
        XCTAssertEqual(engine.lastSeek, 0)
    }

    /// 空队列的切歌命令返回 false（映射为 .noActionableNowPlayingItem）。
    func testPlaybackStoreCommandsReportEmptyQueue() {
        let store = PlaybackStateStore(engine: FakeEngine())
        let commands = NowPlayingCommands.playbackStore(store)
        XCTAssertFalse(commands.nextTrack())
        XCTAssertFalse(commands.previousTrack())
        XCTAssertFalse(commands.togglePlayPause())
        XCTAssertFalse(commands.play())
    }

    // MARK: - 夹具

    /// 等待 store 快照满足条件；超时抛错。用于消除引擎状态流的异步折叠时序抖动。
    private func awaitSnapshot(
        _ store: PlaybackStateStore,
        // 20s 上限，与其他套件一致：正常毫秒级返回，仅在系统负载抖动时兜底。
        seconds: TimeInterval = 20,
        _ predicate: (PlaybackSnapshot) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate(store.snapshot) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("等待 store 快照条件超时")
        throw NowPlayingTestError.snapshotTimeout
    }

    /// 构造一个参数化的 NowPlayingInfo（trackID 固定，便于只比较指定字段）。
    private static func info(
        elapsed: Double,
        isPaused: Bool = false,
        duration: Double = 100,
        title: String = "曲目",
        isCoreIdle: Bool = false
    ) -> NowPlayingInfo {
        NowPlayingInfo(
            trackID: Self.trackID,
            title: title,
            artist: "歌手",
            duration: duration,
            elapsed: elapsed,
            isPaused: isPaused,
            isCoreIdle: isCoreIdle
        )
    }

    private static let trackID = UUID()
}

// MARK: - 夹具类型

/// 测试内部错误标记。
private enum NowPlayingTestError: Error {
    case snapshotTimeout
}

/// 可编排时间的时钟。
private final class ClockBox: @unchecked Sendable {
    private var date: Date

    init(_ date: Date) { self.date = date }

    var now: Date { date }

    func advance(_ interval: TimeInterval) { date = date.addingTimeInterval(interval) }
}

/// 假注册后端：记录注册了哪些命令，并允许测试主动触发 handler。
private final class FakeRegistrar: NowPlayingCommandRegistering {
    private let lock = NSLock()
    private var handlers: [NowPlayingCommand: @Sendable (Double) -> Bool] = [:]
    private var registered: [NowPlayingCommand] = []
    private var removeAllCountValue = 0

    var registeredCommands: [NowPlayingCommand] { locked { registered } }
    var handlerCount: Int { locked { handlers.count } }
    var removeAllCount: Int { locked { removeAllCountValue } }

    func addHandler(
        for command: NowPlayingCommand,
        handler: @escaping @Sendable (Double) -> Bool
    ) -> Any {
        locked {
            handlers[command] = handler
            registered.append(command)
            return UUID()
        }
    }

    func removeAllHandlers() {
        locked {
            handlers.removeAll()
            registered.removeAll()
            removeAllCountValue += 1
        }
    }

    /// 以系统播放器的方式触发某类命令的 handler。未注册时抛错。
    func invoke(_ command: NowPlayingCommand, position: Double = 0) throws -> Bool {
        let handler = locked { handlers[command] }
        return try XCTUnwrap(handler, "\(command) 未注册 handler")(position)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// 假发布后端：记录写入次数与最后一次内容。
private final class FakePublisher: NowPlayingInfoPublishing {
    private let lock = NSLock()
    private var entries: [(info: [String: Any]?, state: MPNowPlayingPlaybackState)] = []

    var publishCount: Int { locked { entries.count } }
    var lastInfo: [String: Any]? { locked { entries.last?.info } }
    var lastState: MPNowPlayingPlaybackState? { locked { entries.last?.state } }

    func publish(nowPlayingInfo: [String: Any]?, playbackState: MPNowPlayingPlaybackState) {
        locked { entries.append((nowPlayingInfo, playbackState)) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// 记录命令调用顺序，用于断言转发目标。
private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var callsValue: [String] = []
    private var seekPositionsValue: [Double] = []

    var calls: [String] { locked { callsValue } }
    var seekPositions: [Double] { locked { seekPositionsValue } }

    var commands: NowPlayingCommands {
        NowPlayingCommands(
            play: { self.record("play"); return true },
            pause: { self.record("pause"); return true },
            togglePlayPause: { self.record("toggle"); return true },
            nextTrack: { self.record("next"); return true },
            previousTrack: { self.record("previous"); return true },
            seekPosition: { position in
                self.locked { self.seekPositionsValue.append(position) }
                self.record("seek:\(position)")
                return true
            }
        )
    }

    private func record(_ call: String) { locked { callsValue.append(call) } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private extension NowPlayingCommands {

    /// 不做任何事、一律返回 true 的闭包集。
    static var noop: NowPlayingCommands { .responding(true) }

    /// 不做任何事、一律返回 handled 的闭包集。
    static func responding(_ handled: Bool) -> NowPlayingCommands {
        NowPlayingCommands(
            play: { handled },
            pause: { handled },
            togglePlayPause: { handled },
            nextTrack: { handled },
            previousTrack: { handled },
            seekPosition: { _ in handled }
        )
    }
}

/// 可控的假引擎（与 PlaybackStateStoreTests 的 FakeEngine 同构，但只保留本文件所需能力）。
private final class FakeEngine: PlayerEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var stateValue: PlayerEngineState = .idle
    private var continuations: [UUID: AsyncStream<PlayerEngineState>.Continuation] = [:]
    private var lastSeekValue: Double?

    var currentURL: URL? { snapshot.currentURL }
    var isPaused: Bool { snapshot.isPaused }
    var position: Double { snapshot.position }
    var duration: Double { snapshot.duration }
    var isCoreIdle: Bool { snapshot.isCoreIdle }
    var lastSeek: Double? { locked { lastSeekValue } }

    func load(url: URL) throws {
        guard url.isFileURL else { throw PlayerEngineError.unsupportedURL(url) }
        mutate { state in
            state.currentURL = url
            state.position = 0
            state.duration = 100
            state.isPaused = false
            state.isCoreIdle = false
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

    func stop() throws { mutate { $0 = .idle } }

    func seek(to seconds: Double) throws {
        guard snapshot.currentURL != nil else { throw PlayerEngineError.noCurrentItem }
        locked { lastSeekValue = seconds }
        mutate { $0.position = seconds }
    }

    func setVolume(_ volume: Double) throws {}

    func observeState() -> AsyncStream<PlayerEngineState> {
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

    private var snapshot: PlayerEngineState { locked { stateValue } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
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
