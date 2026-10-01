// PlaybackControllerFeatureTests.swift
// NeriPlayer macOS —— 本轮播放控制器新增能力的测试。
//
// 覆盖三件新能力，全部用可控假引擎编排，不驱动 libmpv、不依赖真实音频：
//   1) 队列弹层的底层命令：jump(toQueueIndex:) 跳播、removeFromQueue(at:) 移除（含移除当前曲 /
//      移除其他曲 / 清空队列三种后果）；
//   2) 「播完当前曲暂停」：本曲 EOF 停在当前曲不推进，且为一次性（下一次 EOF 恢复队列推进）；
//   3) 应用音量：setVolume 夹取并随快照发布；瞬时（淡入淡出）音量不改应用音量、不发布快照。
//
// 为什么不用真实 MPVEngine：这三项都是「命令 → 内存态/引擎调用」的逻辑，可控引擎能把
// 「加载次数 / 最近一次音量 / 是否 EOF」变成确定性输入，避免真实音频的时序抖动（与
// PlaybackStateStoreTests 的取舍一致）。

import XCTest
@testable import NeriPlayer

final class PlaybackControllerFeatureTests: XCTestCase {

    private func track(_ name: String) -> Track {
        Track(url: URL(fileURLWithPath: "/music/\(name).mp3"), title: name)
    }

    private func makeStore(_ engine: FeatureFakeEngine) -> PlaybackStateStore {
        PlaybackStateStore(engine: engine)
    }

    /// 轮询 store 快照直到条件成立。
    private func waitForSnapshot(
        _ store: PlaybackStateStore, seconds: Double = 8,
        until predicate: @escaping @Sendable (PlaybackSnapshot) -> Bool
    ) async throws -> PlaybackSnapshot {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let snapshot = store.snapshot
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw FeatureTestError.timeout
    }

    // MARK: - 队列：跳播

    /// 跳到队列指定下标应加载该曲并开始播放。
    func testJumpToQueueIndexLoadsAndPlays() async throws {
        let engine = FeatureFakeEngine()
        let store = makeStore(engine)
        let items = [track("A"), track("B"), track("C")]
        store.setQueue(items, startIndex: 0)
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == items[0].id && !$0.isCoreIdle }

        store.jump(toQueueIndex: 2)
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == items[2].id && !$0.isCoreIdle }
        XCTAssertEqual(store.queueState.currentIndex, 2)
        XCTAssertEqual(engine.lastLoadedURL, items[2].url)
    }

    /// 越界下标是空操作：当前曲与加载次数都不变。
    func testJumpOutOfRangeDoesNothing() async throws {
        let engine = FeatureFakeEngine()
        let store = makeStore(engine)
        let items = [track("A"), track("B")]
        store.setQueue(items, startIndex: 0)
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == items[0].id && !$0.isCoreIdle }
        let loadsBefore = engine.loadCount

        store.jump(toQueueIndex: 99)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.currentTrack?.id, items[0].id, "越界跳转不应改变当前曲")
        XCTAssertEqual(engine.loadCount, loadsBefore, "越界跳转不应触发加载")
    }

    // MARK: - 队列：移除

    /// 移除不是当前曲的条目：当前曲不变、不触发加载。
    func testRemoveNonCurrentKeepsPlayback() async throws {
        let engine = FeatureFakeEngine()
        let store = makeStore(engine)
        let items = [track("A"), track("B"), track("C")]
        store.setQueue(items, startIndex: 0)
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == items[0].id && !$0.isCoreIdle }
        let loadsBefore = engine.loadCount

        store.removeFromQueue(at: 2)
        _ = try await waitForSnapshot(store) { $0.queue.tracks.count == 2 }
        XCTAssertEqual(store.currentTrack?.id, items[0].id, "移除后面的曲目不应改变当前曲")
        XCTAssertEqual(engine.loadCount, loadsBefore, "移除其他曲目不应触发加载")
    }

    /// 移除当前曲：队列按「落到同序号的下一首」前进，并自动加载播放新的当前曲。
    func testRemoveCurrentAdvancesToNextAndLoads() async throws {
        let engine = FeatureFakeEngine()
        let store = makeStore(engine)
        let items = [track("A"), track("B"), track("C")]
        store.setQueue(items, startIndex: 1)
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == items[1].id && !$0.isCoreIdle }

        store.removeFromQueue(at: 1)
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == items[2].id && !$0.isCoreIdle }
        XCTAssertEqual(store.queueState.tracks.map(\.title), ["A", "C"])
        XCTAssertEqual(engine.lastLoadedURL, items[2].url, "移除当前曲应把新当前曲加载进引擎")
    }

    /// 移除最后一首导致队列清空：无当前曲、引擎停止。
    func testRemoveLastTrackClearsPlayback() async throws {
        let engine = FeatureFakeEngine()
        let store = makeStore(engine)
        store.setQueue([track("Only")], startIndex: 0)
        _ = try await waitForSnapshot(store) { $0.currentTrack != nil && !$0.isCoreIdle }

        store.removeFromQueue(at: 0)
        _ = try await waitForSnapshot(store) { $0.currentTrack == nil }
        XCTAssertTrue(store.queueState.tracks.isEmpty)
        XCTAssertTrue(store.snapshot.isCoreIdle, "队列清空后引擎应停止")
    }

    // MARK: - 播完当前曲暂停

    /// 开启后本曲自然播完停在当前曲：不推进、不重播，开关随快照发布后自动关闭。
    func testPauseAfterCurrentStopsAtCurrentTrack() async throws {
        let engine = FeatureFakeEngine()
        let store = makeStore(engine)
        let items = [track("A"), track("B")]
        store.setQueue(items, startIndex: 0)
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == items[0].id && !$0.isCoreIdle }

        store.setPauseAfterCurrent(true)
        _ = try await waitForSnapshot(store) { $0.pauseAfterCurrent }
        let loadsBefore = engine.loadCount

        engine.simulateEndOfFile()
        _ = try await waitForSnapshot(store) { $0.isCoreIdle }
        XCTAssertEqual(store.currentTrack?.id, items[0].id, "应停在当前曲，不推进到下一首")
        XCTAssertEqual(engine.loadCount, loadsBefore, "播完当前曲暂停不应触发加载")
        XCTAssertFalse(store.snapshot.pauseAfterCurrent, "一次性标记应被消费掉")
    }

    /// 一次性语义：开启 → 第一首 EOF 暂停并消费标记；第二首 EOF 恢复队列正常推进。
    func testPauseAfterCurrentIsOneShot() async throws {
        let engine = FeatureFakeEngine()
        let store = makeStore(engine)
        let items = [track("A"), track("B")]
        store.setQueue(items, startIndex: 0)
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == items[0].id && !$0.isCoreIdle }

        store.setPauseAfterCurrent(true)
        engine.simulateEndOfFile()
        _ = try await waitForSnapshot(store) { $0.isCoreIdle && $0.currentTrack?.id == items[0].id }

        // 用户回到播放：重新加载当前曲后再自然播完，这一次应正常切到下一首。
        store.togglePlayPause()
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == items[0].id && !$0.isCoreIdle }
        engine.simulateEndOfFile()
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == items[1].id }
        XCTAssertEqual(store.currentTrack?.id, items[1].id, "一次性暂停消费后应恢复自动推进")
    }

    /// 未开启时 EOF 仍按队列模式自动推进（不因新增功能改变既有行为）。
    func testWithoutPauseAfterCurrentAdvancesNormally() async throws {
        let engine = FeatureFakeEngine()
        let store = makeStore(engine)
        let items = [track("A"), track("B")]
        store.setMode(.repeatAll)
        store.setQueue(items, startIndex: 0)
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == items[0].id && !$0.isCoreIdle }

        engine.simulateEndOfFile()
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == items[1].id }
        XCTAssertEqual(store.currentTrack?.id, items[1].id)
    }

    // MARK: - 音量

    /// setVolume 夹取到 0–100，下发给引擎并随快照发布。
    func testSetVolumeClampsAndPublishes() async throws {
        let engine = FeatureFakeEngine()
        let store = makeStore(engine)

        store.setVolume(150)
        XCTAssertEqual(engine.lastVolume, 100, "超过上限应夹到 100")
        _ = try await waitForSnapshot(store) { $0.volume == 100 }

        store.setVolume(-20)
        XCTAssertEqual(engine.lastVolume, 0, "低于下限应夹到 0")
        _ = try await waitForSnapshot(store) { $0.volume == 0 }

        store.setVolume(.nan)
        XCTAssertEqual(engine.lastVolume, PlaybackVolumeDefaults.volume, "非有限值应回落到默认音量")
    }

    /// 瞬时音量（淡入淡出走这条）只下发引擎，不改应用音量、不发布快照。
    func testTransientVolumeDoesNotChangeAppVolume() async throws {
        let engine = FeatureFakeEngine()
        let store = makeStore(engine)
        store.setVolume(70)
        _ = try await waitForSnapshot(store) { $0.volume == 70 }

        store.setTransientVolume(5)
        XCTAssertEqual(engine.lastVolume, 5, "瞬时音量应下发给引擎")
        XCTAssertEqual(store.snapshot.volume, 70, "瞬时音量不应改写应用音量")
        XCTAssertEqual(store.snapshot.volume, 70, "快照里的应用音量保持不变（不发布包络值）")
    }
}

// MARK: - 可控假引擎

/// 本文件专用的可控引擎：与 PlaybackStateStoreTests 的 FakeEngine 同构，但额外暴露
/// 加载次数/最近 URL/最近音量并支持模拟 EOF。重复一份而不是共享：既有 Fixture 是 private，
/// 且本文件只需要这几个观察点，独立一份可避免改到既有测试夹具。
private final class FeatureFakeEngine: PlayerEngine, @unchecked Sendable {

    private let lock = NSLock()
    private var stateValue: PlayerEngineState = .idle
    private var continuations: [UUID: AsyncStream<PlayerEngineState>.Continuation] = [:]
    private let stateBroadcaster = PlayerEngineStateBroadcaster()
    private var loadCountValue = 0
    private var lastLoadedURLValue: URL?
    private var lastVolumeValue: Double?

    var currentURL: URL? { snapshot.currentURL }
    var isPaused: Bool { snapshot.isPaused }
    var position: Double { snapshot.position }
    var duration: Double { snapshot.duration }
    var isCoreIdle: Bool { snapshot.isCoreIdle }
    var hasLoadedFile: Bool { snapshot.hasLoadedFile }
    var hasEnded: Bool { snapshot.hasEnded }

    var loadCount: Int { locked { loadCountValue } }
    var lastLoadedURL: URL? { locked { lastLoadedURLValue } }
    var lastVolume: Double? { locked { lastVolumeValue } }

    func load(url: URL) throws {
        guard url.isFileURL else { throw PlayerEngineError.unsupportedURL(url) }
        locked { loadCountValue += 1; lastLoadedURLValue = url }
        mutate { state in
            state.currentURL = url
            state.position = 0
            state.duration = 60
            state.isPaused = false
            state.isCoreIdle = false
            state.hasEnded = false
            state.hasLoadedFile = true
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
        mutate { $0.position = seconds }
    }

    func setVolume(_ volume: Double) throws { locked { lastVolumeValue = volume } }

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
            continuation.onTermination = { [weak self] _ in self?.removeContinuation(id) }
            continuation.yield(current)
        }
    }

    /// 模拟自然播完：内核回到空闲且位置归零（currentURL 保留）。
    func simulateEndOfFile() {
        mutate { state in
            state.position = 0
            state.isCoreIdle = true
            state.hasEnded = true
            state.hasLoadedFile = false
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
        guard next != stateValue else { lock.unlock(); return }
        stateValue = next
        let listeners = Array(continuations.values)
        lock.unlock()
        stateBroadcaster.broadcast(next)
        for listener in listeners { listener.yield(next) }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}

private enum FeatureTestError: Error { case timeout }
