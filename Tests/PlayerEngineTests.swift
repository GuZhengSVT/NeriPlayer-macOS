// PlayerEngineTests.swift
// NeriPlayer macOS —— M1-T3：PlayerEngine 协议与 MPVEngine 实现测试。
//
// 与 MPVControllerTests 一样跑真实 libmpv（需要 Vendor/mpv/lib 与 rpath，见 Package.swift）。
// 音频素材取系统自带提示音 /System/Library/Sounds/*.aiff：无需联网、无版权顾虑、
// 且 mpv 可 loadfile 播放；测试不校验声音输出，只校验状态机。
//
// 边界：M1-T3 只验证单文件播放控制（加载/暂停/位置更新/停止清空/错误路径），
// 不涉及队列（M1-T4）、持久化（M4/M3）、媒体键（M1-T6）。

import XCTest
@testable import NeriPlayer

final class PlayerEngineTests: XCTestCase {

    /// 系统提示音素材。Tink 短（约 0.56s），Funk 较长（约 2.16s）便于观察进度推进。
    private static let shortSound = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
    private static let longSound = URL(fileURLWithPath: "/System/Library/Sounds/Funk.aiff")

    private func makeEngine() throws -> MPVEngine {
        try MPVEngine(clientName: "engine-test")
    }

    // MARK: - 初始状态

    /// 未加载任何文件时：无 URL、未暂停、位置/时长为 0、内核空闲。
    func testInitialStateIsIdle() throws {
        let engine = try makeEngine()
        XCTAssertNil(engine.currentURL)
        XCTAssertFalse(engine.isPaused)
        XCTAssertEqual(engine.position, 0)
        XCTAssertEqual(engine.duration, 0)
        XCTAssertTrue(engine.isCoreIdle, "新实例应处于空闲态")
        XCTAssertEqual(engine.state, .idle)
    }

    // MARK: - 加载

    /// load 后 currentURL 立即就位，且内核读到时长为正、退出空闲态（文件确实被加载）。
    func testLoadSetsCurrentURLAndLoadsFile() async throws {
        let engine = try makeEngine()
        try engine.load(url: Self.shortSound)
        XCTAssertEqual(engine.currentURL, Self.shortSound, "load 成功后应立即记录 currentURL")

        // 以「退出空闲态」为加载完成信号：实测 libmpv 先推 duration，随后才清 core-idle，
        // 因此非空闲快照里 duration 必然已就位，只等 duration 反而可能拿到仍然 idle 的中间态。
        let loaded = try await waitForState(engine) { !$0.isCoreIdle }
        XCTAssertEqual(loaded.currentURL, Self.shortSound)
        XCTAssertEqual(loaded.duration, 0.564, accuracy: 0.05, "Tink.aiff 时长约 0.56s")
        XCTAssertFalse(loaded.isCoreIdle, "加载并播放后内核不应再空闲")
    }

    /// 重载另一个文件：currentURL 被替换，不会与上一个文件混淆。
    func testLoadReplacesCurrentURL() async throws {
        let engine = try makeEngine()
        try engine.load(url: Self.shortSound)
        _ = try await waitForState(engine) { $0.duration > 0 }

        try engine.load(url: Self.longSound)
        XCTAssertEqual(engine.currentURL, Self.longSound)
        let loaded = try await waitForState(engine) { !$0.isCoreIdle }
        XCTAssertEqual(loaded.duration, 2.163, accuracy: 0.1, "Funk.aiff 时长约 2.16s")
    }

    // MARK: - 暂停 / 播放

    /// pause / play 反映到 isPaused，且是双向可逆的。
    func testPauseAndResume() async throws {
        let engine = try makeEngine()
        try engine.load(url: Self.shortSound)
        _ = try await waitForState(engine) { !$0.isCoreIdle }

        try engine.pause()
        let paused = try await waitForState(engine) { $0.isPaused }
        XCTAssertTrue(paused.isPaused)

        try engine.play()
        let resumed = try await waitForState(engine) { !$0.isPaused }
        XCTAssertFalse(resumed.isPaused)
    }

    /// load 是「从头播放」语义：即使此前处于暂停，加载新文件后也应为播放态。
    func testLoadClearsPreviousPauseState() async throws {
        let engine = try makeEngine()
        try engine.load(url: Self.longSound)
        _ = try await waitForState(engine) { !$0.isCoreIdle }
        try engine.pause()
        _ = try await waitForState(engine) { $0.isPaused }

        try engine.load(url: Self.shortSound)
        XCTAssertFalse(engine.isPaused, "load 应复位暂停状态，回到播放态")
    }

    // MARK: - 位置更新

    /// 播放过程中 position 持续推进（真实解码，不依赖是否听到声音）。
    func testPositionAdvancesDuringPlayback() async throws {
        let engine = try makeEngine()
        try engine.load(url: Self.longSound)
        _ = try await waitForState(engine) { $0.duration > 0 }

        let advanced = try await waitForState(engine, seconds: 8) { $0.position > 0.3 }
        XCTAssertGreaterThan(advanced.position, 0.3)
        XCTAssertLessThanOrEqual(advanced.position, advanced.duration, "位置不应超过总时长")
    }

    /// 暂停后位置应稳定（同一位置附近不再前进），据此区分「暂停」与「播放」。
    func testPositionFrozenWhilePaused() async throws {
        let engine = try makeEngine()
        try engine.load(url: Self.longSound)
        _ = try await waitForState(engine) { $0.duration > 0 }
        _ = try await waitForState(engine) { $0.position > 0.2 }

        try engine.pause()
        _ = try await waitForState(engine) { $0.isPaused }
        // 暂停事件与位置事件可能几乎同时到达，先给内核一小段时间稳定。
        try await Task.sleep(nanoseconds: 300_000_000)
        let first = engine.position
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(engine.position, first, accuracy: 0.05, "暂停后位置应基本不动")
    }

    /// seek 到绝对秒数后位置随之更新。
    func testSeekMovesPosition() async throws {
        let engine = try makeEngine()
        try engine.load(url: Self.longSound)
        _ = try await waitForState(engine) { $0.duration > 1.0 }
        try engine.pause()
        _ = try await waitForState(engine) { $0.isPaused }

        try engine.seek(to: 1.2)
        let seeked = try await waitForState(engine) { $0.position > 1.0 }
        XCTAssertEqual(seeked.position, 1.2, accuracy: 0.1)
    }

    // MARK: - 停止

    /// stop 后 currentURL 清空、位置/时长归零、内核回到空闲态。
    func testStopClearsCurrentItemAndState() async throws {
        let engine = try makeEngine()
        try engine.load(url: Self.longSound)
        _ = try await waitForState(engine) { $0.duration > 0 && $0.position > 0.1 }

        try engine.stop()
        XCTAssertNil(engine.currentURL, "stop 后应清空 currentURL")
        XCTAssertEqual(engine.position, 0)
        XCTAssertEqual(engine.duration, 0)
        XCTAssertFalse(engine.isPaused)
        XCTAssertTrue(engine.isCoreIdle, "stop 后内核应回到空闲态")

        // 内核事件回流后仍应保持空闲，不会被迟到的属性事件污染。
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(engine.currentURL)
        XCTAssertEqual(engine.position, 0)
        XCTAssertTrue(engine.isCoreIdle)
    }

    /// 停止后可以重新加载并正常播放（状态机可循环使用）。
    func testReloadAfterStopWorks() async throws {
        let engine = try makeEngine()
        try engine.load(url: Self.shortSound)
        _ = try await waitForState(engine) { $0.duration > 0 }
        try engine.stop()
        XCTAssertNil(engine.currentURL)

        try engine.load(url: Self.longSound)
        XCTAssertEqual(engine.currentURL, Self.longSound)
        let reloaded = try await waitForState(engine, seconds: 8) { !$0.isCoreIdle }
        XCTAssertFalse(reloaded.isCoreIdle)
    }

    // MARK: - 音量

    /// 音量命令在加载前后都应被受理（内核量程 0–100）。
    func testSetVolumeIsAccepted() throws {
        let engine = try makeEngine()
        XCTAssertNoThrow(try engine.setVolume(35))
        try engine.load(url: Self.shortSound)
        XCTAssertNoThrow(try engine.setVolume(0))
        XCTAssertNoThrow(try engine.setVolume(100))
    }

    // MARK: - 错误路径

    /// 只支持本地文件：远程 URL 直接拒绝，不落到内核。
    func testLoadRejectsNonFileURL() throws {
        let engine = try makeEngine()
        let remote = URL(string: "https://example.com/song.mp3")!
        XCTAssertThrowsError(try engine.load(url: remote)) { error in
            guard case PlayerEngineError.unsupportedURL(let url) = error else {
                return XCTFail("期望 unsupportedURL，实际为 \(error)")
            }
            XCTAssertEqual(url, remote)
        }
        XCTAssertNil(engine.currentURL, "被拒绝的加载不应写入 currentURL")
    }

    /// 没有已加载项时，play / pause / seek 抛 noCurrentItem；stop 与 setVolume 不要求有项。
    func testCommandsWithoutCurrentItemThrow() throws {
        let engine = try makeEngine()
        for operation in ["play", "pause", "seek"] {
            XCTAssertThrowsError(try run(operation, on: engine)) { error in
                guard let engineError = error as? PlayerEngineError, case .noCurrentItem = engineError else {
                    return XCTFail("\(operation) 应抛 noCurrentItem，实际为 \(error)")
                }
            }
        }
        XCTAssertNoThrow(try engine.stop())
        XCTAssertNoThrow(try engine.setVolume(50))
    }

    /// 底层错误统一包装为 .backend，不向上泄漏 MPVError。
    /// 用 NaN 音量触发内核的「不支持的格式」拒绝（实测 code=-9），稳定且与素材无关。
    func testBackendErrorIsWrapped() throws {
        let engine = try makeEngine()
        XCTAssertThrowsError(try engine.setVolume(.nan)) { error in
            guard let engineError = error as? PlayerEngineError, case .backend = engineError else {
                return XCTFail("期望 backend 包装，实际为 \(error)")
            }
        }
    }

    /// PlayerEngineError 提供可读描述（LocalizedError 一致性）。
    func testErrorDescriptionsAreReadable() {
        let url = URL(fileURLWithPath: "/tmp/x.mp3")
        XCTAssertNotNil(PlayerEngineError.unsupportedURL(url).errorDescription)
        XCTAssertNotNil(PlayerEngineError.noCurrentItem.errorDescription)
        XCTAssertNotNil(
            PlayerEngineError.backend(PlayerEngineError.noCurrentItem).errorDescription
        )
    }

    // MARK: - 状态订阅

    /// observeState 先推当前快照，再在状态变化时继续推送。
    func testObserveStateEmitsInitialSnapshotThenChanges() async throws {
        let engine = try makeEngine()
        let reader = StateReader(engine.observeState())

        let initialSnapshot = await reader.next()
        let initial = try XCTUnwrap(initialSnapshot, "订阅后应立刻收到一次当前快照")
        XCTAssertNil(initial.currentURL)
        XCTAssertTrue(initial.isCoreIdle)

        try engine.load(url: Self.shortSound)
        let loaded = try await nextState(reader, seconds: 8) { $0.currentURL == Self.shortSound }
        XCTAssertEqual(loaded.currentURL, Self.shortSound)
    }

    /// 每个订阅者拿到独立的流；取消一个订阅不影响另一个。
    func testObserveStateSupportsMultipleSubscribers() async throws {
        let engine = try makeEngine()
        let cancelled = engine.observeState()
        let cancelTask = Task { for await _ in cancelled {} }
        try await Task.sleep(nanoseconds: 50_000_000)
        cancelTask.cancel()
        _ = await cancelTask.value

        // 已取消的订阅者不影响新订阅者的正常工作。
        try engine.load(url: Self.shortSound)
        let loaded = try await waitForState(engine) { $0.duration > 0 }
        XCTAssertEqual(loaded.currentURL, Self.shortSound)
    }

    // MARK: - 工具

    /// 按名字触发一个无参命令，用于参数化断言错误类型。
    private func run(_ operation: String, on engine: MPVEngine) throws {
        switch operation {
        case "play": try engine.play()
        case "pause": try engine.pause()
        case "seek": try engine.seek(to: 0)
        default: XCTFail("未知操作：\(operation)")
        }
    }

    /// 订阅状态流并等待首个满足条件的快照。
    private func waitForState(
        _ engine: MPVEngine,
        seconds: Double = 5,
        until predicate: @escaping @Sendable (PlayerEngineState) -> Bool
    ) async throws -> PlayerEngineState {
        try await nextState(StateReader(engine.observeState()), seconds: seconds, until: predicate)
    }

    /// 从已有读取器里推进到首个满足条件的快照，带超时保护。
    private func nextState(
        _ reader: StateReader,
        seconds: Double,
        until predicate: @escaping @Sendable (PlayerEngineState) -> Bool
    ) async throws -> PlayerEngineState {
        try await withThrowingTaskGroup(of: PlayerEngineState.self) { group in
            group.addTask {
                while let state = await reader.next() {
                    if predicate(state) { return state }
                }
                throw EngineTestError.streamEnded
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw EngineTestError.timeout
            }
            guard let result = try await group.next() else { throw EngineTestError.timeout }
            group.cancelAll()
            return result
        }
    }
}

/// 状态流读取器。设计为单消费者：迭代器内部状态不做加锁，
/// 每个测试用例只在一条等待链里使用同一个读取器，故不存在并发读。
private final class StateReader: @unchecked Sendable {
    private var iterator: AsyncStream<PlayerEngineState>.AsyncIterator

    init(_ stream: AsyncStream<PlayerEngineState>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> PlayerEngineState? {
        await iterator.next()
    }
}

/// 测试内部错误标记。
private enum EngineTestError: Error {
    case timeout
    case streamEnded
}
