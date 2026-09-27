// PlaybackEntryUITests.swift
// NeriPlayer macOS —— M2-T8：播放入口打通（歌手/专辑/歌单的整组播放与随机起点）与播放状态文案测试。
//
// 覆盖三件事：
//   1) 随机播放的首曲选择：固定种子下可复现、下标恒在组内、空组返回 nil；对着真实执行路径
//      （PlaybackEntry.shuffle）断言「选中的那首一定属于该组」，而不是在测试里照抄一遍调用顺序；
//   2) 整组入队语义：随机播放之后队列里是整组（不是只播到的那一首），且不会混入上一组的曲目；
//   3) 状态条文案：PlaybackStatusText 的映射规则，以及「可控引擎快照变化 → 文案跟着变」，
//      并用「只有位置变化时文案不变」证明状态条不会被播放进度带着重算。
//
// 为什么不用真实 MPVEngine：状态条文案只依赖快照字段，可控引擎能把「播放中/暂停/停止」编排成
// 确定性输入，避免真实音频的时序抖动（与 PlaybackStateStoreTests 的取舍一致）。

import XCTest
@testable import NeriPlayer

final class PlaybackEntryUITests: XCTestCase {

    // MARK: - 夹具

    private func makeTracks(count: Int, prefix: String = "曲") -> [Track] {
        (0..<count).map { index in
            Track(
                url: URL(fileURLWithPath: "/music/\(prefix)\(index).mp3"),
                title: "\(prefix)\(index)",
                artist: prefix
            )
        }
    }

    private func makeStore(_ engine: any PlayerEngine) -> PlaybackStateStore {
        PlaybackStateStore(engine: engine)
    }

    // MARK: - 随机下标

    /// 固定种子下同一组曲目的取数结果可复现，且下标落在组内。
    func testSeededRandomIndexIsReproducibleAndInRange() throws {
        let tracks = makeTracks(count: 7)
        let first = try XCTUnwrap(PlaybackShuffleEntry.randomIndex(in: tracks, isSeedFixed: true))
        let second = try XCTUnwrap(PlaybackShuffleEntry.randomIndex(in: tracks, isSeedFixed: true))
        XCTAssertEqual(first, second, "同一种子的取数应可复现")
        XCTAssertTrue(tracks.indices.contains(first), "下标必须在组内")
    }

    /// 组大小从 1 到 40 扫一遍：固定种子下也不会越界或返回 nil。
    func testSeededRandomIndexStaysInRangeForEveryGroupSize() throws {
        for count in 1...40 {
            let tracks = makeTracks(count: count)
            let index = try XCTUnwrap(PlaybackShuffleEntry.randomIndex(in: tracks, isSeedFixed: true))
            XCTAssertTrue(tracks.indices.contains(index), "组大小 \(count) 时下标越界：\(index)")
        }
    }

    /// 空组没有可选项：返回 nil，调用方据此不产生任何播放动作。
    func testRandomIndexIsNilForEmptyGroup() {
        XCTAssertNil(PlaybackShuffleEntry.randomIndex(in: []))
        XCTAssertNil(PlaybackShuffleEntry.randomIndex(in: [], isSeedFixed: true))
    }

    // MARK: - 随机播放（真实执行路径 + 可控引擎）

    /// 固定种子：选中的曲目属于该组、整组全量入队、当前曲就是选中的那首。
    func testShufflePicksTrackFromGroupAndQueuesWholeGroup() throws {
        let store = makeStore(FakeEngine())
        let group = makeTracks(count: 6, prefix: "歌手A")

        let picked = try XCTUnwrap(PlaybackEntry.shuffle(group, store: store, isSeedFixed: true))

        XCTAssertTrue(group.contains(picked), "随机选中的曲目必须属于该组")
        XCTAssertEqual(store.queueState.tracks.count, group.count, "整组应全量入队，而不是只播一首")
        XCTAssertEqual(store.queueState.tracks.map(\.id), group.map(\.id), "入队顺序应与该组一致")
        XCTAssertEqual(store.currentTrack?.id, picked.id, "当前曲应是随机到的起点")
    }

    /// 真随机（未固定种子）：反复随机取起点，选中的曲目始终落在该组内。
    func testUnseededShuffleAlwaysPicksWithinGroup() {
        let store = makeStore(FakeEngine())
        let group = makeTracks(count: 8, prefix: "歌手B")
        let groupIds = Set(group.map(\.id))

        for _ in 0..<50 {
            guard let picked = PlaybackEntry.shuffle(group, store: store) else {
                return XCTFail("非空组不应返回 nil")
            }
            XCTAssertTrue(groupIds.contains(picked.id), "随机起点越出了该组：\(picked.title)")
        }
    }

    /// 单曲组：随机只能是它自己，且不产生空动作。
    func testShuffleWithSingleTrackGroup() throws {
        let store = makeStore(FakeEngine())
        let only = makeTracks(count: 1, prefix: "独唱")

        let picked = try XCTUnwrap(PlaybackEntry.shuffle(only, store: store, isSeedFixed: true))

        XCTAssertEqual(picked.id, only[0].id)
        XCTAssertEqual(store.queueState.tracks.count, 1)
    }

    /// 换组随机：上一组的曲目不会残留在队列里（整组替换而不是追加）。
    func testShuffleReplacesPreviousGroup() throws {
        let store = makeStore(FakeEngine())
        let first = makeTracks(count: 4, prefix: "旧组")
        let second = makeTracks(count: 3, prefix: "新组")
        PlaybackEntry.shuffle(first, store: store, isSeedFixed: true)

        let picked = try XCTUnwrap(PlaybackEntry.shuffle(second, store: store, isSeedFixed: true))

        XCTAssertEqual(store.queueState.tracks.map(\.id), second.map(\.id), "队列应被整组替换")
        XCTAssertTrue(second.contains(picked))
    }

    /// 空组防呆：返回 nil，且不动已经在播的队列（界面上两个按钮此时也是禁用的）。
    func testShuffleWithEmptyGroupLeavesQueueUntouched() throws {
        let store = makeStore(FakeEngine())
        let playing = makeTracks(count: 3, prefix: "正在播")
        PlaybackEntry.shuffle(playing, store: store, isSeedFixed: true)
        let before = store.queueState

        XCTAssertNil(PlaybackEntry.shuffle([], store: store))

        XCTAssertEqual(store.queueState, before, "空组不该改动队列")
    }

    // MARK: - 状态条文案（纯映射）

    /// 播放中 / 已暂停 / 已停止三种标签，以及缺歌手与空队列的回落。
    func testStatusTextMapsPlaybackStates() {
        let track = Track(url: URL(fileURLWithPath: "/music/夜曲.mp3"), title: "夜曲", artist: "周杰伦")

        XCTAssertEqual(text(track: track, isPaused: false, isCoreIdle: false), "正在播放 · 夜曲 — 周杰伦")
        XCTAssertEqual(text(track: track, isPaused: true, isCoreIdle: false), "已暂停 · 夜曲 — 周杰伦")
        // 空闲优先于暂停：自然播完/已停止时引擎会把暂停复位为 false，先看 isPaused 会误显示「正在播放」。
        XCTAssertEqual(text(track: track, isPaused: false, isCoreIdle: true), "已停止 · 夜曲 — 周杰伦")
        XCTAssertEqual(text(track: track, isPaused: true, isCoreIdle: true), "已停止 · 夜曲 — 周杰伦")

        let anonymous = Track(url: URL(fileURLWithPath: "/music/x.mp3"), title: "无题")
        XCTAssertEqual(text(track: anonymous, isPaused: false, isCoreIdle: false), "正在播放 · 无题 — 未知歌手")
        XCTAssertEqual(PlaybackStatusText.displayArtist("   "), "未知歌手", "纯空白歌手按缺失处理")

        XCTAssertNil(PlaybackStatusText.text(for: snapshot(track: nil)), "空队列不显示状态条")
    }

    /// 只有播放位置变化的两个快照文案相同：状态条不会被进度更新带着重算。
    func testStatusTextIgnoresPositionOnlyChanges() {
        let track = Track(url: URL(fileURLWithPath: "/music/a.mp3"), title: "A", artist: "Alice")
        let start = PlaybackSnapshot(
            currentTrack: track, isPaused: false, position: 0, duration: 180,
            isCoreIdle: false, queue: .empty
        )
        let later = PlaybackSnapshot(
            currentTrack: track, isPaused: false, position: 42, duration: 180,
            isCoreIdle: false, queue: .empty
        )
        XCTAssertEqual(PlaybackStatusText.text(for: start), PlaybackStatusText.text(for: later))
    }

    // MARK: - 状态条文案（快照流驱动）

    /// 可控引擎推快照：播放 → 暂停 → 恢复，状态条文案随快照变化跟着变（订阅路径与视图一致）。
    func testStatusTextFollowsEngineSnapshotChanges() async throws {
        let store = makeStore(FakeEngine())
        let track = makeTracks(count: 1, prefix: "夜曲")[0]
        let reader = TextReader(store.observeState())

        try await reader.waitForCount(1)
        XCTAssertNil(reader.lastText, "订阅时队列为空，不该有状态文案")

        store.playTrack(track)
        try await reader.waitForText("正在播放 · 夜曲0 — 夜曲")

        store.togglePlayPause()
        try await reader.waitForText("已暂停 · 夜曲0 — 夜曲")

        store.togglePlayPause()
        try await reader.waitForText("正在播放 · 夜曲0 — 夜曲")

        // 只有位置变化时文案不变：等待这次 seek 的快照落地，文案仍是刚才那条。
        let countBeforeSeek = reader.count
        store.seek(to: 12)
        try await reader.waitForCount(countBeforeSeek + 1)
        XCTAssertEqual(reader.lastText, "正在播放 · 夜曲0 — 夜曲")
    }

    /// 停止后状态条仍在（当前曲保留），但标签变为「已停止」。
    func testStatusTextShowsStoppedAfterStop() async throws {
        let store = makeStore(FakeEngine())
        let track = makeTracks(count: 1, prefix: "停")[0]
        let reader = TextReader(store.observeState())

        store.playTrack(track)
        try await reader.waitForText("正在播放 · 停0 — 停")

        store.stop()

        try await reader.waitForText("已停止 · 停0 — 停")
    }

    // MARK: - 工具

    private func snapshot(track: Track? = nil, isPaused: Bool = false, isCoreIdle: Bool = true) -> PlaybackSnapshot {
        PlaybackSnapshot(
            currentTrack: track,
            isPaused: isPaused,
            position: 0,
            duration: 0,
            isCoreIdle: isCoreIdle,
            queue: .empty
        )
    }

    private func text(track: Track?, isPaused: Bool, isCoreIdle: Bool) -> String? {
        PlaybackStatusText.text(for: snapshot(track: track, isPaused: isPaused, isCoreIdle: isCoreIdle))
    }
}

/// 状态文案读取器：后台消费快照流，把每条快照按「状态条看到的那段映射」折算成文案写进日志，
/// 测试侧只轮询日志。
///
/// 为什么用「后台消费 + 轮询日志」而不是「每步都 await 下一个快照」：等待超时时被取消的等待者
/// 会让已经取到的快照落进无人认领的任务里（AsyncStream 的迭代器不响应取消），后续步骤于是
/// 少看到一次变化，表现为随机超时。日志形态没有这个问题 —— 快照只会被追加，不会被丢弃。
private final class TextReader: @unchecked Sendable {

    private let lock = NSLock()
    private var log: [String?] = []
    private var consumer: Task<Void, Never>?

    init(_ stream: AsyncStream<PlaybackSnapshot>) {
        consumer = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                self.append(PlaybackStatusText.text(for: snapshot))
            }
        }
    }

    deinit { consumer?.cancel() }

    /// 已记录的文案条数。
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return log.count
    }

    /// 最后一条文案（尚无记录或最后一条为「不显示」时是 nil）。
    var lastText: String? {
        lock.lock()
        defer { lock.unlock() }
        return log.last ?? nil
    }

    /// 等到日志里出现 expected 这条文案。
    func waitForText(_ expected: String, seconds: Double = 8) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if recorded().contains(expected) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw PlaybackEntryTestError.waitTimeout(expected: expected, observed: recorded())
    }

    /// 等到日志条数达到 expected（用于「状态条确实又收到过一次快照」这类断言）。
    func waitForCount(_ expected: Int, seconds: Double = 8) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if count >= expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw PlaybackEntryTestError.waitTimeout(expected: "至少 \(expected) 条快照", observed: recorded())
    }

    private func append(_ text: String?) {
        lock.lock()
        log.append(text)
        lock.unlock()
    }

    private func recorded() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return log.compactMap { $0 }
    }
}

/// 本文件内部错误标记。
private enum PlaybackEntryTestError: Error {
    /// 等待条件在超时前没有满足；带上已观察到的文案便于诊断。
    case waitTimeout(expected: String, observed: [String])
}

/// 可控的假引擎（与 PlaybackStateStoreTests 的 FakeEngine 同构）：load/play/pause/stop/seek
/// 同步翻转状态并推流，使「快照变化 → 文案更新」可以确定性断言。
private final class FakeEngine: PlayerEngine, @unchecked Sendable {

    private let lock = NSLock()
    private var stateValue: PlayerEngineState = .idle
    private var continuations: [UUID: AsyncStream<PlayerEngineState>.Continuation] = [:]

    var currentURL: URL? { snapshot.currentURL }
    var isPaused: Bool { snapshot.isPaused }
    var position: Double { snapshot.position }
    var duration: Double { snapshot.duration }
    var isCoreIdle: Bool { snapshot.isCoreIdle }

    func load(url: URL) throws {
        guard url.isFileURL else { throw PlayerEngineError.unsupportedURL(url) }
        mutate { state in
            state.currentURL = url
            state.position = 0
            state.duration = 180
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
        mutate { $0.position = seconds }
    }

    func setVolume(_ volume: Double) throws {}

    func observeState() -> AsyncStream<PlayerEngineState> {
        // unbounded：状态条测试要看到每一次快照变化（含「播放中 → 暂停」），
        // bufferingNewest(1) 在高负载下会合并掉中间事件（与 PlaybackStateStoreTests 同因）。
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
