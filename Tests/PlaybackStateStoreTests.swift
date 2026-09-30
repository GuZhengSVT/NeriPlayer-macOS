// PlaybackStateStoreTests.swift
// NeriPlayer macOS —— M1-T5：PlaybackStateStore 内存态与引擎/队列桥接测试。
//
// 分两类覆盖：
//   1) 真实链路（真实 MPVEngine + 系统提示音 /System/Library/Sounds/*.aiff）：
//      入队即播、toggle、自然播完后的单曲循环重播 / 列表循环接下一首 / 顺序模式停在末尾，
//      以及「用户主动 stop 不触发推进」；不校验声音输出，只校验状态机。
//   2) 桥接逻辑（可控的 FakeEngine，不驱动 libmpv）：next/previous/force 的队列走位、
//      入队不改当前曲、模式切换保持当前曲，以及各模式的 EOF 推进判定。
//
// 为什么两类都要：真实链路证明代码确实与 libmpv 协同；假引擎把「引擎状态」变成可编排的输入，
// 让顺序末尾、stop 区分这类边界可以确定性断言，而不必等待真实音频播完。

import XCTest
@testable import NeriPlayer

final class PlaybackStateStoreTests: XCTestCase {

    /// 系统提示音素材。Tink 短（约 0.56s）便于快速走到 EOF；Bottle 稍长（约 0.77s）用于区分两首。
    private static let tinkURL = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
    private static let bottleURL = URL(fileURLWithPath: "/System/Library/Sounds/Bottle.aiff")

    private func track(_ url: URL, _ title: String) -> Track {
        Track(url: url, title: title)
    }

    private func makeStore(_ engine: any PlayerEngine) -> PlaybackStateStore {
        PlaybackStateStore(engine: engine)
    }

    // MARK: - 初始态与订阅（真实引擎）

    /// 空 store：无当前曲、非暂停、位置/时长为 0、队列为空。
    func testInitialSnapshotIsEmpty() throws {
        let store = makeStore(try MPVEngine(clientName: "store-initial", options: MPVLaunchOption.silentAudio))
        let snapshot = store.snapshot
        XCTAssertNil(snapshot.currentTrack)
        XCTAssertEqual(snapshot.position, 0)
        XCTAssertEqual(snapshot.duration, 0)
        XCTAssertFalse(snapshot.isPaused)
        XCTAssertTrue(snapshot.queue.isEmpty)
    }

    /// observeState 先推当前快照，再在状态变化时继续推送；属性读取与快照一致。
    func testObserveStateEmitsInitialSnapshotThenChanges() async throws {
        let store = makeStore(try MPVEngine(clientName: "store-observe", options: MPVLaunchOption.silentAudio))
        let reader = SnapshotReader(store.observeState())

        let firstSnapshot = await reader.next()
        let initial = try XCTUnwrap(firstSnapshot, "订阅后应立刻收到一次当前快照")
        XCTAssertNil(initial.currentTrack)
        XCTAssertTrue(initial.queue.isEmpty)

        let first = track(Self.tinkURL, "Tink")
        store.enqueue(first)
        let enqueued = try await nextState(reader) { $0.currentTrack?.id == first.id }
        XCTAssertEqual(enqueued.currentTrack?.title, "Tink")
        XCTAssertEqual(store.currentTrack?.id, first.id, "属性读取应反映最新快照")
    }

    // MARK: - 入队即播 / playTrack（真实引擎）

    /// 空队列入队第一首：它立即成为当前曲并开始播放（脱离内核空闲态）。
    func testEnqueueIntoEmptyQueueStartsPlayback() async throws {
        let store = makeStore(try MPVEngine(clientName: "store-enqueue", options: MPVLaunchOption.silentAudio))
        let first = track(Self.tinkURL, "Tink")
        store.enqueue(first)
        XCTAssertEqual(store.currentTrack?.id, first.id, "入队后应立即成为当前曲")

        let playing = try await waitForSnapshot(store) { $0.currentTrack?.id == first.id && !$0.isCoreIdle }
        XCTAssertGreaterThan(playing.duration, 0, "开始播放后应读到时长")
    }

    /// playTrack 把曲目并入队列并立即播放（未在队列中则追加）。
    func testPlayTrackAddsAndPlays() async throws {
        let store = makeStore(try MPVEngine(clientName: "store-playtrack", options: MPVLaunchOption.silentAudio))
        let first = track(Self.tinkURL, "Tink")
        store.playTrack(first)
        XCTAssertEqual(store.queueState.tracks.map(\.id), [first.id])
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == first.id && !$0.isCoreIdle }
    }

    // MARK: - toggle（真实引擎）

    /// 播放中 toggle 变为暂停，再次 toggle 恢复播放。
    func testTogglePlayPauseReflectsEngine() async throws {
        let store = makeStore(try MPVEngine(clientName: "store-toggle", options: MPVLaunchOption.silentAudio))
        let first = track(Self.bottleURL, "Bottle")
        store.setQueue([first], startIndex: 0)
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == first.id && !$0.isCoreIdle && !$0.isPaused }

        store.togglePlayPause()
        _ = try await waitForSnapshot(store) { $0.isPaused }

        store.togglePlayPause()
        _ = try await waitForSnapshot(store) { !$0.isPaused && !$0.isCoreIdle }
    }

    // MARK: - EOF 推进（真实引擎）

    /// 单曲循环：自然播完后重新加载同一首并继续播放。
    func testRepeatOneReplaysCurrentTrackAfterEOF() async throws {
        let store = makeStore(try MPVEngine(clientName: "store-repeat-one", options: MPVLaunchOption.silentAudio))
        let only = track(Self.tinkURL, "Tink")
        store.setMode(.repeatOne)
        store.setQueue([only], startIndex: 0)
        let reader = SnapshotReader(store.observeState())

        _ = try await nextState(reader, seconds: 8) { $0.currentTrack?.id == only.id && !$0.isCoreIdle && $0.position > 0.2 }
        _ = try await nextState(reader, seconds: 8) { $0.isCoreIdle }
        let replayed = try await nextState(reader, seconds: 8) { $0.currentTrack?.id == only.id && !$0.isCoreIdle }
        XCTAssertEqual(replayed.currentTrack?.title, "Tink", "单曲循环应重播同一首")
    }

    /// 列表循环：第一首自然播完后自动接下一首，走到末尾再回卷到首曲。
    func testRepeatAllAdvancesAndWrapsAfterEOF() async throws {
        let store = makeStore(try MPVEngine(clientName: "store-repeat-all", options: MPVLaunchOption.silentAudio))
        let first = track(Self.tinkURL, "Tink")
        let second = track(Self.bottleURL, "Bottle")
        store.setMode(.repeatAll)
        store.setQueue([first, second], startIndex: 0)
        let reader = SnapshotReader(store.observeState())

        _ = try await nextState(reader, seconds: 8) { $0.currentTrack?.id == first.id && !$0.isCoreIdle }
        _ = try await nextState(reader, seconds: 8) { $0.currentTrack?.id == second.id && !$0.isCoreIdle }
        let wrapped = try await nextState(reader, seconds: 10) { $0.currentTrack?.id == first.id && !$0.isCoreIdle }
        XCTAssertEqual(wrapped.queue.currentIndex, 0, "列表循环应在末尾回卷到首曲")
    }

    /// 顺序模式：播到最后一首后不再前进，停在末尾（当前曲保留、内核空闲）。
    func testSequentialStopsAtLastTrackAfterEOF() async throws {
        let store = makeStore(try MPVEngine(clientName: "store-sequential", options: MPVLaunchOption.silentAudio))
        let first = track(Self.tinkURL, "Tink")
        let second = track(Self.bottleURL, "Bottle")
        store.setMode(.sequential)
        store.setQueue([first, second], startIndex: 0)
        let reader = SnapshotReader(store.observeState())

        _ = try await nextState(reader, seconds: 8) { $0.currentTrack?.id == first.id && !$0.isCoreIdle }
        _ = try await nextState(reader, seconds: 8) { $0.currentTrack?.id == second.id && !$0.isCoreIdle }
        let stopped = try await nextState(reader, seconds: 8) { $0.currentTrack?.id == second.id && $0.isCoreIdle }
        XCTAssertEqual(stopped.queue.currentIndex, 1, "顺序模式应停在最后一首")

        // 再等一小段，确认不会「停一下又自己重播」。
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(store.currentTrack?.id, second.id)
        XCTAssertTrue(store.snapshot.isCoreIdle, "顺序模式播完后应保持停止，不再自动推进")
    }

    /// 用户主动 stop 后不应自动推进：即使引擎回到空闲态，当前曲与索引保持不变。
    func testStopDoesNotTriggerAdvance() async throws {
        let store = makeStore(try MPVEngine(clientName: "store-stop", options: MPVLaunchOption.silentAudio))
        let first = track(Self.bottleURL, "Bottle")
        let second = track(Self.tinkURL, "Tink")
        store.setQueue([first, second], startIndex: 0)
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == first.id && !$0.isCoreIdle }

        store.stop()
        // stop 后引擎状态更新是异步的，立即断言会闪失败；轮询等待其变为空闲。
        _ = try await waitForSnapshot(store, seconds: 8) { $0.isCoreIdle }
        XCTAssertTrue(store.snapshot.isCoreIdle, "stop 后内核应空闲")
        XCTAssertEqual(store.currentTrack?.id, first.id, "stop 不应清空当前曲")

        // 给足超过一首时长的时间，确认没有发生 EOF 式推进。
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(store.currentTrack?.id, first.id, "stop 后不得自动推进")
        XCTAssertEqual(store.queueState.currentIndex, 0)
        XCTAssertTrue(store.snapshot.isCoreIdle)
    }

    // MARK: - 切歌与队列桥接（假引擎，确定性）

    /// next() 推进索引并让引擎加载新曲；previous() 回退；顺序模式两端不再越界。
    func testNextAndPreviousDriveEngine() async throws {
        let engine = FakeEngine()
        let store = makeStore(engine)
        let items = [track(Self.tinkURL, "A"), track(Self.bottleURL, "B"), track(Self.tinkURL, "C")]
        store.setMode(.sequential)
        store.setQueue(items, startIndex: 0)
        try await awaitPlaying(store, items[0])

        store.next()
        try await awaitLoadedAndPlaying(store, engine, 2, items[1])
        XCTAssertEqual(engine.loadCount, 2)

        store.next()
        try await awaitLoadedAndPlaying(store, engine, 3, items[2])

        store.next()
        XCTAssertEqual(store.currentTrack?.id, items[2].id, "顺序模式在末位 next 不动作")
        XCTAssertEqual(engine.loadCount, 3, "无推进时不应再加载")

        store.previous()
        try await awaitLoadedAndPlaying(store, engine, 4, items[1])
        store.previous()
        try await awaitLoadedAndPlaying(store, engine, 5, items[0])
        store.previous()
        XCTAssertEqual(store.currentTrack?.id, items[0].id, "顺序模式在首位 previous 不动作")
    }

    /// next(force: true) 在末位回卷到首曲。
    func testNextForceWrapsAtEnd() async throws {
        let engine = FakeEngine()
        let store = makeStore(engine)
        let items = [track(Self.tinkURL, "A"), track(Self.bottleURL, "B")]
        store.setMode(.sequential)
        store.setQueue(items, startIndex: 1)
        try await awaitPlaying(store, items[1])

        store.next()
        XCTAssertEqual(store.currentTrack?.id, items[1].id, "非 force 的 next 在末位不动作")

        store.next(force: true)
        try await awaitLoadedAndPlaying(store, engine, 2, items[0])
        XCTAssertEqual(engine.lastLoadedURL, items[0].url)
    }

    /// 入队不改当前曲（仅入队到空队列才立即开播）。
    func testEnqueueKeepsCurrentTrack() async throws {
        let engine = FakeEngine()
        let store = makeStore(engine)
        let first = track(Self.tinkURL, "A")
        store.setQueue([first], startIndex: 0)
        try await awaitPlaying(store, first)

        store.enqueue(track(Self.bottleURL, "B"))
        store.enqueueNext(track(Self.tinkURL, "C"))
        XCTAssertEqual(store.currentTrack?.id, first.id, "入队不应改变当前曲")
        XCTAssertEqual(store.queueState.tracks.count, 3)
        XCTAssertEqual(engine.loadCount, 1, "入队不应触发加载")
    }

    /// 切换播放模式保持当前曲不变。
    func testSetModeKeepsCurrentTrack() async throws {
        let engine = FakeEngine()
        let store = makeStore(engine)
        let first = track(Self.tinkURL, "A")
        store.setQueue([first], startIndex: 0)
        try await awaitPlaying(store, first)

        store.setMode(.shuffle)
        XCTAssertEqual(store.currentTrack?.id, first.id)
        XCTAssertEqual(store.queueState.mode, .shuffle)
        XCTAssertEqual(engine.loadCount, 1)
    }

    /// 单曲循环 EOF：重新加载同一首。
    func testFakeRepeatOneEOFReloadsSameTrack() async throws {
        let engine = FakeEngine()
        let store = makeStore(engine)
        let only = track(Self.tinkURL, "A")
        store.setMode(.repeatOne)
        store.setQueue([only], startIndex: 0)
        try await awaitPlaying(store, only)

        engine.simulateEndOfFile()
        // 单曲循环重播的是同一首，不能用「是否在播」判断推进是否发生（EOF 前它就已在播），
        // 因此先等加载次数真正增长（计数器不会被流缓冲合并，是确定性信号）。
        try await waitForLoadCount(engine, 2)
        _ = try await waitForSnapshot(store) { !$0.isCoreIdle }
        XCTAssertEqual(engine.lastLoadedURL, only.url, "单曲循环 EOF 应重新加载当前曲")
        XCTAssertFalse(store.snapshot.isCoreIdle, "重播后应处于播放态")
    }

    /// 列表循环 EOF：推进到下一首并加载。
    func testFakeRepeatAllEOFAdvances() async throws {
        let engine = FakeEngine()
        let store = makeStore(engine)
        let items = [track(Self.tinkURL, "A"), track(Self.bottleURL, "B")]
        store.setMode(.repeatAll)
        store.setQueue(items, startIndex: 0)
        try await awaitPlaying(store, items[0])

        engine.simulateEndOfFile()
        // 先用加载计数确认 EOF 推进确实发生（轮询快照在负载抖动下会偶发等待超时），
        // 再断言快照反映新曲。
        try await waitForLoadCount(engine, 2)
        _ = try await waitForSnapshot(store) { $0.currentTrack?.id == items[1].id && !$0.isCoreIdle }
        XCTAssertEqual(engine.lastLoadedURL, items[1].url)
    }

    /// 顺序模式 EOF 在末位：不推进、不再加载，保持停止。
    func testFakeSequentialEOFAtEndStops() async throws {
        let engine = FakeEngine()
        let store = makeStore(engine)
        let items = [track(Self.tinkURL, "A"), track(Self.bottleURL, "B")]
        store.setMode(.sequential)
        store.setQueue(items, startIndex: 1)
        try await awaitPlaying(store, items[1])

        engine.simulateEndOfFile()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.currentTrack?.id, items[1].id, "顺序模式末位 EOF 应停在当前曲")
        XCTAssertEqual(engine.loadCount, 1, "不应发生推进加载")
    }

    /// stop 之后引擎回到空闲态不触发推进（stop 与 EOF 必须区分）。
    func testFakeStopDoesNotAdvanceOnIdle() async throws {
        let engine = FakeEngine()
        let store = makeStore(engine)
        let items = [track(Self.tinkURL, "A"), track(Self.bottleURL, "B")]
        store.setMode(.repeatAll)
        store.setQueue(items, startIndex: 0)
        try await awaitPlaying(store, items[0])

        store.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.currentTrack?.id, items[0].id, "stop 后不得推进下一首")
        XCTAssertEqual(engine.loadCount, 1)
        XCTAssertTrue(store.snapshot.isCoreIdle)

        // stop 后 toggle 应从当前曲恢复播放。
        store.togglePlayPause()
        try await awaitPlaying(store, items[0])
    }

    // MARK: - 工具：真实引擎轮询

    /// 轮询 store 快照直到条件成立（真实引擎下比流式等待更稳）。
    private func waitForSnapshot(
        _ store: PlaybackStateStore,
        // 20 秒上限：正常 10ms 内即返回，仅在极端负载下兜底（实测本机多实例并发跑测试时 8s 会偶发不够）。
        seconds: Double = 20,
        until predicate: @escaping @Sendable (PlaybackSnapshot) -> Bool
    ) async throws -> PlaybackSnapshot {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let snapshot = store.snapshot
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // 带上最后快照，便于失败时诊断卡在哪个状态。
        throw StoreTestError.snapshotTimeout(
            last: store.snapshot,
            predicate: String(describing: predicate)
        )
    }

    // MARK: - 工具：流式阶段等待

    /// 从读取器推进到首个满足条件的快照。
    private func nextState(
        _ reader: SnapshotReader,
        seconds: Double = 5,
        until predicate: @escaping @Sendable (PlaybackSnapshot) -> Bool
    ) async throws -> PlaybackSnapshot {
        try await withThrowingTaskGroup(of: PlaybackSnapshot.self) { group in
            group.addTask {
                while let snapshot = await reader.next() {
                    if predicate(snapshot) { return snapshot }
                }
                throw StoreTestError.streamEnded
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw StoreTestError.timeout
            }
            guard let result = try await group.next() else { throw StoreTestError.timeout }
            group.cancelAll()
            return result
        }
    }

    /// 假引擎下等待加载次数达到期望值（用于「重播同一首」这类无法靠曲目 id 区分的推进）。
    private func waitForLoadCount(_ engine: FakeEngine, _ expected: Int, seconds: Double = 20) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if engine.loadCount >= expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw StoreTestError.timeout
    }

    /// 假引擎下等待「加载次数达到 expectedLoads 且快照反映 track 在播」。
    /// 以 loadCount 为推进信号、快照为最终断言，规避 AsyncStream newest-1 缓冲
    /// 在高负载下偶发丢中间事件导致的快照等待超时（实测复现过 3 种用例）。
    private func awaitLoadedAndPlaying(
        _ store: PlaybackStateStore,
        _ engine: FakeEngine,
        _ expectedLoads: Int,
        _ track: Track
    ) async throws {
        try await waitForLoadCount(engine, expectedLoads)
        _ = try await waitForSnapshot(store) {
            $0.currentTrack?.id == track.id && !$0.isCoreIdle
        }
    }

    /// 假引擎下等待某曲开始播放（脱离空闲态）。
    private func awaitPlaying(_ store: PlaybackStateStore, _ track: Track) async throws {
        // 与真实引擎用例的 8 秒一致：CI/后台负载抖动时 3 秒会闪失败（实测复现过）。
        _ = try await waitForSnapshot(store, seconds: 8) {
            $0.currentTrack?.id == track.id && !$0.isCoreIdle
        }
    }
}

/// 状态流读取器。设计为单消费者：每个测试只在一条等待链里使用同一读取器，故不做并发读保护。
private final class SnapshotReader: @unchecked Sendable {
    private var iterator: AsyncStream<PlaybackSnapshot>.AsyncIterator

    init(_ stream: AsyncStream<PlaybackSnapshot>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> PlaybackSnapshot? {
        await iterator.next()
    }
}

/// 测试内部错误标记。
private enum StoreTestError: Error {
    case timeout
    case streamEnded
    /// 超时并携带最后快照，用于诊断等待条件为何未满足。
    case snapshotTimeout(last: PlaybackSnapshot, predicate: String)
}

/// 可控的假引擎：不驱动 libmpv，用 simulateEndOfFile 编排「自然播完」。
/// 让 EOF 推进、stop 区分这类边界可以确定性断言，避免真实音频的时序抖动。
private final class FakeEngine: PlayerEngine, @unchecked Sendable {

    private let lock = NSLock()
    private var stateValue: PlayerEngineState = .idle
    private var continuations: [UUID: AsyncStream<PlayerEngineState>.Continuation] = [:]
    /// 同步状态观察者的广播器。
    private let stateBroadcaster = PlayerEngineStateBroadcaster()
    private var loadCountValue = 0
    private var lastLoadedURLValue: URL?
    private var lastVolumeValue: Double?
    private var lastSeekValue: Double?

    var currentURL: URL? { snapshot.currentURL }
    var isPaused: Bool { snapshot.isPaused }
    var position: Double { snapshot.position }
    var duration: Double { snapshot.duration }
    var isCoreIdle: Bool { snapshot.isCoreIdle }

    /// 已受理的加载次数。
    var loadCount: Int { locked { loadCountValue } }
    /// 最近一次加载的 URL。
    var lastLoadedURL: URL? { locked { lastLoadedURLValue } }
    /// 最近一次音量命令。
    var lastVolume: Double? { locked { lastVolumeValue } }
    /// 最近一次跳转位置。
    var lastSeek: Double? { locked { lastSeekValue } }

    func load(url: URL) throws {
        guard url.isFileURL else { throw PlayerEngineError.unsupportedURL(url) }
        locked { loadCountValue += 1; lastLoadedURLValue = url }
        // 同步更新状态（真实 MPVEngine 里这一步由 mpv 事件异步驱动，但 store 的
        // EOF 闩锁逻辑只依赖「先收到播放中、再收到空闲」的事件顺序，与同步/异步无关）。
        // 之前这里用 Task 异步翻转，高负载下事件会被 AsyncStream 的 bufferingNewest(1)
        // 合并，闩锁来不及武装，测试偶发超时（实测复现两次），故改为同步保证确定性。
        mutate { state in
            state.currentURL = url
            state.position = 0
            state.duration = 60
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

    func stop() throws {
        mutate { $0 = .idle }
    }

    func seek(to seconds: Double) throws {
        guard snapshot.currentURL != nil else { throw PlayerEngineError.noCurrentItem }
        locked { lastSeekValue = seconds }
        mutate { $0.position = seconds }
    }

    func setVolume(_ volume: Double) throws {
        locked { lastVolumeValue = volume }
    }

    /// 同步状态观察者（与生产实现同一套语义，见 PlayerEngineObservation.swift）。
    func addStateObserver(
        _ handler: @escaping @Sendable (PlayerEngineState) -> Void
    ) -> any PlayerEngineStateObservation {
        stateBroadcaster.add(handler)
    }

    func observeState() -> AsyncStream<PlayerEngineState> {
        // unbounded：测试替身必须保留全部状态事件。store 的 EOF 闩锁依赖
        // 「先看到播放中、再看到空闲」的事件顺序；bufferingNewest(1) 在高负载下
        // 会用最新事件覆盖掉还没被消费的「播放中」事件，闩锁来不及武装，
        // EOF 推进被跳过（实测复现的 flake 根因）。真实 MPVEngine 的每条属性流
        // 缓冲为 64 且属性变更频率低，不受此问题影响。
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

    /// 模拟自然播完：内核回到空闲且位置归零（currentURL 保留，与真实 MPVEngine 一致）。
    func simulateEndOfFile() {
        mutate { state in
            state.position = 0
            state.isCoreIdle = true
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
