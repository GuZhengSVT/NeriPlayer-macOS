// PlaybackSessionTests.swift
// NeriPlayer macOS —— M3-T3：播放现场（保存 / 恢复）的确定性单测。
//
// 覆盖面（与任务书验收一一对应）：
//   1) 可持久化投影：空队列、当前曲不可持久化 → 无可恢复内容；混合队列按规则剔除临时音源，
//      当前索引与随机序列同步重映射；
//   2) QueueManager.restore：原样采纳现场（含已走过的随机序列），并把非法输入钳回合法状态；
//   3) PlaybackStateStore.restore：恢复后队列/索引/模式到位，进度在「引擎真正加载起来」之后
//      才下发 seek（libmpv 的 loadfile 是下发即返回，早发的 seek 会被丢弃），且只下发一次；
//      默认停在暂停态，resumePlayback 为 true 时才继续播；
//   4) PlaybackSessionRecorder：结构变化立刻写、只有进度推进时按步长写、flushNow 无条件写、
//      没有可恢复内容时清除旧行、从未观察到快照时不做任何写入、写失败后允许重试；
//   5) 端到端：真实 store + 录制器 + 仓库，播一段 → 退出 flush → 用另一份 store 恢复 → 进度一致；
//   6) 存储层：PlayerState 往返（含 shouldResumePlayback），v2 → v3 升级不丢既有现场。
//
// 为什么录制器的写盘时机测试直接喂快照（recorder.handle）而不是经真实订阅：订阅路径受调度影响，
// 「第几次快照触发写盘」会变成时序断言。写盘判定是纯逻辑，直接喂输入就能确定性覆盖；
// 订阅路径本身由本文件第 5 节的端到端用例覆盖。

import XCTest
import GRDB
@testable import NeriPlayer

final class PlaybackSessionTests: XCTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    // MARK: - 夹具

    private func makeDatabaseURL() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NeriPlayerSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("library.sqlite")
    }

    private func makeProvider() throws -> DatabaseProvider {
        let provider = try DatabaseProvider(url: try makeDatabaseURL())
        try provider.setupIfNeeded()
        return provider
    }

    private func makeLocalTracks(_ names: [String]) -> [Track] {
        names.map { Track(url: URL(fileURLWithPath: "/music/\($0).flac"), title: $0) }
    }

    /// 造一个远程（临时音源）曲目：M5 的在线地址不是本地文件，不该落库。
    private func makeRemoteTrack(_ name: String) throws -> Track {
        // 用 XCTUnwrap 而不是 `URL(string:)!`：地址真拼错时希望用例在这一行明确报错，
        // 而不是靠一个强制解包在别处崩掉。
        let url = try XCTUnwrap(URL(string: "https://example.invalid/song/\(name).m4a"))
        return Track(url: url, title: name)
    }

    private func snapshot(
        tracks: [Track],
        currentIndex: Int?,
        position: Double = 0,
        mode: PlaybackMode = .sequential,
        shuffleOrder: [UUID] = [],
        isPaused: Bool = false,
        isCoreIdle: Bool = false
    ) -> PlaybackSnapshot {
        PlaybackSnapshot(
            currentTrack: currentIndex.flatMap { tracks.indices.contains($0) ? tracks[$0] : nil },
            isPaused: isPaused,
            position: position,
            duration: 180,
            isCoreIdle: isCoreIdle,
            queue: QueueState(
                tracks: tracks,
                currentIndex: currentIndex,
                mode: mode,
                shuffleOrder: shuffleOrder
            )
        )
    }

    /// 轮询内存态直到条件成立；超时即失败并带上当前快照便于诊断。
    private func waitForSnapshot(
        _ store: PlaybackStateStore,
        seconds: Double = 20,
        until predicate: @escaping @Sendable (PlaybackSnapshot) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate(store.snapshot) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("等待内存态条件超时：\(store.snapshot)", file: file, line: line)
        throw PlaybackSessionTestError.waitTimeout
    }

    // MARK: - 1. 可持久化投影

    /// 空队列没有任何可恢复内容。
    func testRestorableStateIsNilForEmptyQueue() {
        let snapshot = snapshot(tracks: [], currentIndex: nil)
        XCTAssertNil(snapshot.restorablePlayerState())
    }

    /// 当前索引越界（外部改坏的现场）同样视为不可恢复，而不是产出非法状态。
    func testRestorableStateIsNilForOutOfRangeIndex() {
        let snapshot = snapshot(tracks: makeLocalTracks(["a"]), currentIndex: 5)
        XCTAssertNil(snapshot.restorablePlayerState())
    }

    /// 当前曲是临时音源时不恢复：恢复不了「正在播的那首」，恢复其余队列只会让人困惑。
    func testRestorableStateIsNilWhenCurrentTrackIsTransient() throws {
        let tracks = makeLocalTracks(["local"]) + [try makeRemoteTrack("online")]
        let snapshot = snapshot(tracks: tracks, currentIndex: 1, position: 30)
        XCTAssertNil(snapshot.restorablePlayerState())
    }

    /// 非当前曲的临时音源被剔除，当前索引与随机序列同步重映射。
    func testRestorableStateDropsTransientTracksAndRemapsIndex() throws {
        let a = makeLocalTracks(["a"])[0]
        let remote = try makeRemoteTrack("online")
        let b = makeLocalTracks(["b"])[0]
        let tracks = [a, remote, b]
        let snapshot = snapshot(
            tracks: tracks,
            currentIndex: 2,
            position: 42,
            mode: .shuffle,
            shuffleOrder: [a.id, remote.id, b.id]
        )

        let restored = try XCTUnwrap(snapshot.restorablePlayerState())

        XCTAssertEqual(restored.tracks.map(\.title), ["a", "b"], "临时音源应被剔除")
        XCTAssertEqual(restored.currentIndex, 1, "当前曲 b 在过滤后应落到索引 1")
        XCTAssertEqual(restored.currentTrack?.id, b.id)
        XCTAssertEqual(restored.shuffleOrder, [a.id, b.id], "随机序列里被剔除的 id 也要清掉")
        XCTAssertEqual(restored.position, 42)
        XCTAssertEqual(restored.mode, .shuffle)
    }

    /// 播放意图取「既没暂停、也不是空闲」：暂停或已停止都不该自动续播。
    func testRestorableStateCapturesPlaybackIntent() throws {
        let tracks = makeLocalTracks(["a"])

        let playing = try XCTUnwrap(
            snapshot(tracks: tracks, currentIndex: 0, isPaused: false, isCoreIdle: false).restorablePlayerState()
        )
        XCTAssertTrue(playing.shouldResumePlayback)

        let paused = try XCTUnwrap(
            snapshot(tracks: tracks, currentIndex: 0, isPaused: true, isCoreIdle: false).restorablePlayerState()
        )
        XCTAssertFalse(paused.shouldResumePlayback)

        let stopped = try XCTUnwrap(
            snapshot(tracks: tracks, currentIndex: 0, isPaused: false, isCoreIdle: true).restorablePlayerState()
        )
        XCTAssertFalse(stopped.shouldResumePlayback)
    }

    /// 注入的可持久化规则生效（生产用 isFileURL，测试可换规则）。
    func testRestorableStateHonoursInjectedDurabilityRule() throws {
        let tracks = makeLocalTracks(["a", "b"])
        // 当前曲是 b，而注入的规则认为只有 b 可持久化，因此现场可恢复。
        let snapshot = snapshot(tracks: tracks, currentIndex: 1)

        let restored = try XCTUnwrap(snapshot.restorablePlayerState(keeping: { $0.title == "b" }))

        XCTAssertEqual(restored.tracks.map(\.title), ["b"])
        XCTAssertEqual(restored.currentIndex, 0)

        // 换一条规则让当前曲变得不可持久化：现场随即不可恢复。
        XCTAssertNil(snapshot.restorablePlayerState(keeping: { $0.title == "a" }))
    }

    // MARK: - 2. 队列恢复

    /// 恢复原样采纳现场，包括已经走过的随机序列（不能被重新洗牌）。
    func testQueueRestoreKeepsShuffleOrderVerbatim() {
        let tracks = makeLocalTracks(["a", "b", "c", "d"])
        let order = [tracks[2].id, tracks[0].id, tracks[3].id, tracks[1].id]
        let queue = QueueManager()

        queue.restore(QueueState(tracks: tracks, currentIndex: 2, mode: .shuffle, shuffleOrder: order))

        XCTAssertEqual(queue.tracks.map(\.id), tracks.map(\.id))
        XCTAssertEqual(queue.currentIndex, 2)
        XCTAssertEqual(queue.mode, .shuffle)
        XCTAssertEqual(queue.shuffleOrder, order, "恢复不该重新洗牌")
    }

    /// 非随机模式下随机序列一律清空，避免留下上一轮的残留。
    func testQueueRestoreClearsShuffleOrderForNonShuffleModes() {
        let tracks = makeLocalTracks(["a", "b"])
        let queue = QueueManager()

        queue.restore(
            QueueState(tracks: tracks, currentIndex: 0, mode: .repeatAll, shuffleOrder: [tracks[0].id, tracks[1].id])
        )

        XCTAssertTrue(queue.shuffleOrder.isEmpty)
        XCTAssertEqual(queue.mode, .repeatAll)
    }

    /// 非法输入钳回合法状态：空队列、索引越界、索引为 nil、随机序列与队列不匹配。
    func testQueueRestoreClampsInvalidState() {
        let queue = QueueManager()
        let tracks = makeLocalTracks(["a", "b", "c"])

        queue.restore(QueueState(tracks: [], currentIndex: 3, mode: .sequential, shuffleOrder: []))
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.currentIndex, "空队列的索引必须是 nil")

        queue.restore(QueueState(tracks: tracks, currentIndex: 99, mode: .sequential, shuffleOrder: []))
        XCTAssertEqual(queue.currentIndex, 2, "越界索引钳到末位")

        queue.restore(QueueState(tracks: tracks, currentIndex: nil, mode: .sequential, shuffleOrder: []))
        XCTAssertEqual(queue.currentIndex, 0, "非空队列缺少索引时回到首曲")

        queue.restore(QueueState(tracks: tracks, currentIndex: 1, mode: .shuffle, shuffleOrder: [tracks[0].id]))
        XCTAssertEqual(queue.shuffleOrder.count, tracks.count, "序列长度不符时应重建")
        XCTAssertEqual(Set(queue.shuffleOrder), Set(tracks.map(\.id)))
    }

    // MARK: - 3. 内存态恢复

    /// 恢复到保存的进度并停在暂停态：seek 在引擎加载起来之后才下发，且只下发一次。
    func testStoreRestoreLoadsTrackSeeksAndStaysPaused() async throws {
        let engine = SessionControllableEngine()
        let store = PlaybackStateStore(engine: engine)
        let tracks = makeLocalTracks(["a", "b", "c"])
        let state = PlayerState(
            tracks: tracks,
            currentIndex: 1,
            position: 42,
            mode: .repeatAll,
            shuffleOrder: [],
            shouldResumePlayback: true
        )

        store.restore(state)

        try await waitForSnapshot(store) { $0.position == 42 && $0.isPaused }
        XCTAssertEqual(store.queueState.tracks.map(\.id), tracks.map(\.id))
        XCTAssertEqual(store.currentTrack?.id, tracks[1].id)
        XCTAssertEqual(store.queueState.mode, .repeatAll)
        XCTAssertEqual(engine.seeks, [42], "seek 只应下发一次")
        XCTAssertFalse(engine.isCoreIdle)
        XCTAssertTrue(engine.isPaused, "默认恢复到暂停态")
    }

    /// resumePlayback 为 true 时恢复完继续播，并重新武装自动推进。
    func testStoreRestoreCanResumePlayback() async throws {
        let engine = SessionControllableEngine()
        let store = PlaybackStateStore(engine: engine)
        let tracks = makeLocalTracks(["a", "b"])

        store.restore(
            PlayerState(tracks: tracks, currentIndex: 0, position: 10, mode: .sequential),
            resumePlayback: true
        )

        try await waitForSnapshot(store) { $0.position == 10 && !$0.isPaused }
        XCTAssertEqual(engine.seeks, [10])
    }

    /// 进度为 0 时不发多余的 seek（从头发起本来就不需要跳转）。
    func testStoreRestoreSkipsSeekAtZeroPosition() async throws {
        let engine = SessionControllableEngine()
        let store = PlaybackStateStore(engine: engine)
        let tracks = makeLocalTracks(["a"])

        store.restore(PlayerState(tracks: tracks, currentIndex: 0, position: 0, mode: .sequential))

        try await waitForSnapshot(store) { $0.currentTrack?.id == tracks[0].id && !$0.isCoreIdle }
        XCTAssertTrue(engine.seeks.isEmpty)
    }

    /// 空现场不改动队列，也不碰引擎。
    func testStoreRestoreWithEmptyStateDoesNothing() async throws {
        let engine = SessionControllableEngine()
        let store = PlaybackStateStore(engine: engine)

        store.restore(.empty)

        XCTAssertTrue(store.queueState.isEmpty)
        XCTAssertTrue(engine.seeks.isEmpty)
        XCTAssertNil(engine.currentURL)
    }

    /// sessionState 的播放意图与位置反映当前内存态。
    func testStoreSessionStateReflectsSnapshot() async throws {
        let engine = SessionControllableEngine()
        let store = PlaybackStateStore(engine: engine)
        let track = makeLocalTracks(["a"])[0]

        XCTAssertFalse(store.sessionState().shouldResumePlayback, "空态不算在播")

        store.playTrack(track)
        try await waitForSnapshot(store) { !$0.isCoreIdle }

        let state = store.sessionState()
        XCTAssertEqual(state.tracks.map(\.id), [track.id])
        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertTrue(state.shouldResumePlayback, "正在播放应记下续播意图")
    }

    // MARK: - 4. 录制器写盘时机

    /// 结构变化（切歌 / 换索引）立即写一次。
    func testRecorderWritesImmediatelyOnStructuralChange() {
        let sink = SaveSink()
        let recorder = PlaybackSessionRecorder(
            save: { try sink.save($0) },
            clear: { sink.clear() },
            positionStep: 2,
            now: { Date(timeIntervalSince1970: 0) }
        )
        let tracks = makeLocalTracks(["a", "b"])

        recorder.handle(snapshot(tracks: tracks, currentIndex: 0))
        XCTAssertEqual(sink.saved.count, 1)

        // 同一结构、进度变化不足步长：不写。
        recorder.handle(snapshot(tracks: tracks, currentIndex: 0, position: 1.9))
        XCTAssertEqual(sink.saved.count, 1, "进度不足步长不该写盘")

        // 切到下一首：结构变了，立刻写。
        recorder.handle(snapshot(tracks: tracks, currentIndex: 1, position: 0))
        XCTAssertEqual(sink.saved.count, 2)
        XCTAssertEqual(sink.saved.last?.currentIndex, 1)
    }

    /// 仅进度推进时按步长写盘：跨越阈值写一次，随后继续推进再写。
    func testRecorderThrottlesPositionOnlyChanges() {
        let sink = SaveSink()
        let recorder = PlaybackSessionRecorder(
            save: { try sink.save($0) },
            clear: { sink.clear() },
            positionStep: 2,
            now: { Date(timeIntervalSince1970: 0) }
        )
        let tracks = makeLocalTracks(["a"])

        recorder.handle(snapshot(tracks: tracks, currentIndex: 0, position: 0))
        XCTAssertEqual(sink.saved.count, 1)

        recorder.handle(snapshot(tracks: tracks, currentIndex: 0, position: 1.0))
        XCTAssertEqual(sink.saved.count, 1)

        recorder.handle(snapshot(tracks: tracks, currentIndex: 0, position: 2.0))
        XCTAssertEqual(sink.saved.count, 2, "达到步长应写盘")

        recorder.handle(snapshot(tracks: tracks, currentIndex: 0, position: 3.0))
        XCTAssertEqual(sink.saved.count, 2, "应以「上次已落库位置」为基准继续攒")

        recorder.handle(snapshot(tracks: tracks, currentIndex: 0, position: 4.5))
        XCTAssertEqual(sink.saved.count, 3)
    }

    /// 暂停 / 继续属于结构变化：队列进度都没动也要写一次播放意图。
    func testRecorderWritesOnPlaybackIntentChange() {
        let sink = SaveSink()
        let recorder = PlaybackSessionRecorder(
            save: { try sink.save($0) },
            clear: { sink.clear() },
            positionStep: 2,
            now: { Date(timeIntervalSince1970: 0) }
        )
        let tracks = makeLocalTracks(["a"])

        recorder.handle(snapshot(tracks: tracks, currentIndex: 0, isPaused: false))
        XCTAssertEqual(sink.saved.count, 1)
        XCTAssertEqual(sink.saved.last?.shouldResumePlayback, true)

        recorder.handle(snapshot(tracks: tracks, currentIndex: 0, isPaused: true))
        XCTAssertEqual(sink.saved.count, 2, "暂停是播放意图变化，必须落库")
        XCTAssertEqual(sink.saved.last?.shouldResumePlayback, false)
    }

    /// 现场变为「无可恢复内容」时清除旧行，而不是留下一份过期现场。
    func testRecorderClearsWhenNothingIsRestorable() {
        let sink = SaveSink()
        let recorder = PlaybackSessionRecorder(
            save: { try sink.save($0) },
            clear: { sink.clear() },
            positionStep: 2,
            now: { Date(timeIntervalSince1970: 0) }
        )
        let tracks = makeLocalTracks(["a"])

        recorder.handle(snapshot(tracks: tracks, currentIndex: 0))
        XCTAssertEqual(sink.saved.count, 1)

        recorder.handle(snapshot(tracks: [], currentIndex: nil))
        XCTAssertEqual(sink.clearCount, 1)
        XCTAssertEqual(sink.saved.count, 1, "清空不该再写现场")
    }

    /// 从未观察到快照时 flushNow 什么都不做 —— 否则「启动后立刻退出」会把刚恢复的现场抹掉。
    func testRecorderFlushWithoutObservationDoesNothing() {
        let sink = SaveSink()
        let recorder = PlaybackSessionRecorder(
            save: { try sink.save($0) },
            clear: { sink.clear() },
            now: { Date(timeIntervalSince1970: 0) }
        )

        recorder.flushNow(reason: "退出")

        XCTAssertTrue(sink.saved.isEmpty)
        XCTAssertEqual(sink.clearCount, 0)
    }

    /// flushNow 忽略步长：把当前位置原样写下（退出正是最需要它准确的时刻）。
    func testRecorderFlushWritesCurrentPositionRegardlessOfStep() {
        let sink = SaveSink()
        let recorder = PlaybackSessionRecorder(
            save: { try sink.save($0) },
            clear: { sink.clear() },
            positionStep: 10,
            now: { Date(timeIntervalSince1970: 0) }
        )
        let tracks = makeLocalTracks(["a"])

        recorder.handle(snapshot(tracks: tracks, currentIndex: 0, position: 0))
        recorder.handle(snapshot(tracks: tracks, currentIndex: 0, position: 0.4))
        XCTAssertEqual(sink.saved.count, 1, "步长 10 秒时不该因 0.4 秒写盘")

        recorder.flushNow(reason: "退出")

        XCTAssertEqual(sink.saved.count, 2)
        XCTAssertEqual(sink.saved.last?.position, 0.4)
    }

    /// 写失败后允许下一次变化重试，不把失败状态当成「已写入」。
    func testRecorderRetriesAfterSaveFailure() {
        let sink = SaveSink()
        sink.failNextSave = true
        let recorder = PlaybackSessionRecorder(
            save: { try sink.save($0) },
            clear: { sink.clear() },
            positionStep: 2,
            now: { Date(timeIntervalSince1970: 0) }
        )
        let tracks = makeLocalTracks(["a", "b"])

        recorder.handle(snapshot(tracks: tracks, currentIndex: 0))
        XCTAssertTrue(sink.saved.isEmpty, "第一次写盘应失败")

        recorder.handle(snapshot(tracks: tracks, currentIndex: 1))
        XCTAssertEqual(sink.saved.count, 1, "失败后下一次变化应重试成功")
        XCTAssertEqual(sink.saved.last?.currentIndex, 1)
    }

    /// attach 幂等：重复调用不会叠加订阅（叠加会让每次变化写两遍）。
    ///
    /// 直接断言 attach 的返回值，而不是去数写盘次数：后者要依赖「一次状态变化恰好产生几份
    /// 快照」，受调度影响。返回值就是「本次是否新建了订阅」这一事实本身。
    func testRecorderAttachIsIdempotent() {
        let sink = SaveSink()
        let recorder = PlaybackSessionRecorder(
            save: { try sink.save($0) },
            clear: { sink.clear() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let store = PlaybackStateStore(engine: SessionControllableEngine())

        XCTAssertTrue(recorder.attach(to: store), "首次 attach 应建立订阅")
        XCTAssertFalse(recorder.attach(to: store), "重复 attach 应被幂等拦下")

        recorder.stop()
        XCTAssertTrue(recorder.attach(to: store), "stop 之后应可以重新建立订阅")
        XCTAssertFalse(recorder.attach(to: store), "重新 attach 后仍应幂等")

        recorder.stop()
    }

    func testRecorderClearsFirstEmptyObservationOnlyOnce() {
        let sink = SaveSink()
        let recorder = PlaybackSessionRecorder(save: { try sink.save($0) }, clear: { sink.clear() })
        let empty = snapshot(tracks: [], currentIndex: nil)
        recorder.handle(empty)
        recorder.handle(empty)
        XCTAssertEqual(sink.clearCount, 1)
    }

    func testRecorderRetriesFailedClearOnIdenticalSnapshot() {
        let sink = SaveSink()
        let recorder = PlaybackSessionRecorder(save: { try sink.save($0) }, clear: {
            sink.clear()
            if sink.clearCount == 1 { throw PlaybackSessionTestError.injectedSaveFailure }
        })
        let empty = snapshot(tracks: [], currentIndex: nil)
        recorder.handle(empty)
        recorder.handle(empty)
        recorder.handle(empty)
        XCTAssertEqual(sink.clearCount, 2)
    }

    func testRecorderPersistsChangedTrackMetadataWithoutPositionChange() {
        let sink = SaveSink()
        let recorder = PlaybackSessionRecorder(save: { try sink.save($0) }, clear: { sink.clear() })
        var track = makeLocalTracks(["a"])[0]
        recorder.handle(snapshot(tracks: [track], currentIndex: 0))
        track.url = URL(fileURLWithPath: "/music/moved.flac")
        recorder.handle(snapshot(tracks: [track], currentIndex: 0))
        XCTAssertEqual(sink.saved.count, 2)
        XCTAssertEqual(sink.saved.last?.tracks.first?.url, track.url)
    }

    func testRecorderSerializesSaveAndClear() {
        let sink = SaveSink()
        let saving = DispatchSemaphore(value: 0)
        let releaseSave = DispatchSemaphore(value: 0)
        let saved = expectation(description: "save finished")
        let cleared = expectation(description: "clear finished")
        let clearing = DispatchSemaphore(value: 0)
        let recorder = PlaybackSessionRecorder(save: { state in
            saving.signal()
            _ = releaseSave.wait(timeout: .now() + 5)
            try sink.save(state)
        }, clear: {
            // The earlier save must commit before its replacement clear.
            XCTAssertEqual(sink.saved.count, 1)
            sink.clear()
        })
        let first = snapshot(tracks: makeLocalTracks(["a"]), currentIndex: 0)
        let empty = snapshot(tracks: [], currentIndex: nil)
        DispatchQueue.global().async { recorder.handle(first); saved.fulfill() }
        XCTAssertEqual(saving.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            clearing.signal()
            recorder.handle(empty)
            cleared.fulfill()
        }
        XCTAssertEqual(clearing.wait(timeout: .now() + 5), .success)
        releaseSave.signal()
        wait(for: [saved, cleared], timeout: 5)
        XCTAssertEqual(sink.clearCount, 1)
    }

    // MARK: - 5. 端到端：播放 → 退出保存 → 恢复

    /// 播一段后 flush，用另一份 store + 引擎恢复：队列、索引、模式与进度都要对得上。
    func testEndToEndSaveThenRestore() async throws {
        let provider = try makeProvider()
        let repository = PlayerStateRepository(provider)
        let tracks = makeLocalTracks(["a", "b", "c"])

        // 第一段会话：播到第 2 首的第 37 秒。
        let engine1 = SessionControllableEngine()
        let store1 = PlaybackStateStore(engine: engine1)
        let sink = SaveSink()
        let recorder = PlaybackSessionRecorder(
            save: { try repository.save($0); try sink.save($0) },
            clear: { try repository.clear() }
        )
        store1.setQueue(tracks, startIndex: 1)
        store1.setMode(.repeatAll)
        try await waitForSnapshot(store1) { !$0.isCoreIdle }
        engine1.advance(to: 37)
        try await waitForSnapshot(store1) { $0.position == 37 }
        recorder.attach(to: store1)
        try await Task.sleep(nanoseconds: 200_000_000)
        recorder.flushNow(reason: "退出")

        // 第二段会话：换一台「机器」——新的引擎与新的 store，从库里恢复。
        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(saved.currentIndex, 1)
        XCTAssertEqual(saved.mode, .repeatAll)

        let engine2 = SessionControllableEngine()
        let store2 = PlaybackStateStore(engine: engine2)
        store2.restore(saved, resumePlayback: false)

        try await waitForSnapshot(store2) { $0.position == 37 && $0.isPaused }
        XCTAssertEqual(store2.queueState.tracks.map(\.id), tracks.map(\.id))
        XCTAssertEqual(store2.currentTrack?.id, tracks[1].id)
        XCTAssertEqual(store2.queueState.mode, .repeatAll)
        XCTAssertEqual(engine2.seeks, [37])
    }

    // MARK: - 6. 存储层

    /// 现场往返（含播放意图）：v3 新增的列必须真的存下去、读回来。
    func testPlayerStateRepositoryRoundTripsResumeIntent() throws {
        let provider = try makeProvider()
        let repository = PlayerStateRepository(provider)
        let tracks = makeLocalTracks(["a", "b"])
        let state = PlayerState(
            tracks: tracks,
            currentIndex: 1,
            position: 91.5,
            mode: .shuffle,
            shuffleOrder: [tracks[1].id, tracks[0].id],
            shouldResumePlayback: true,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try repository.save(state)
        let loaded = try XCTUnwrap(try repository.load())

        XCTAssertEqual(loaded.tracks, tracks)
        XCTAssertEqual(loaded.currentIndex, 1)
        XCTAssertEqual(loaded.position, 91.5)
        XCTAssertEqual(loaded.mode, .shuffle)
        XCTAssertEqual(loaded.shuffleOrder, [tracks[1].id, tracks[0].id])
        XCTAssertTrue(loaded.shouldResumePlayback)
        XCTAssertEqual(loaded.updatedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// 未设置续播意图时读回 false（默认值），不会变成 nil 或崩掉。
    func testPlayerStateResumeIntentDefaultsToFalse() throws {
        let provider = try makeProvider()
        let repository = PlayerStateRepository(provider)

        try repository.save(PlayerState(tracks: makeLocalTracks(["a"]), currentIndex: 0, position: 0, mode: .sequential))

        XCTAssertEqual(try repository.load()?.shouldResumePlayback, false)
    }

    /// v2 → v3 升级：既有现场（队列/进度/模式）原样保留，新列按默认值 false 补齐。
    func testV2ToV3MigrationPreservesExistingSession() throws {
        // 1) 建一个只到 v2 的库，写入一条没有 v3 列的现场。
        // 这里刻意用原始 SQL 而不是 PlayerStateRecord：Record 已经带上 v3 的列，
        // 拿它去写一个 v2 的库只会得到「no such column」，测不到真实的老库形态。
        let url = try makeDatabaseURL()
        let provider = try DatabaseProvider(url: url)
        try provider.migrator.migrate(provider.dbQueue, upTo: "v2")
        let tracks = makeLocalTracks(["legacy-a", "legacy-b"])
        try provider.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO PlayerState
                        (id, currentIndex, position, mode, queue, shuffleOrder, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    PlayerStateRecord.singletonID,
                    1,
                    55.0,
                    PlaybackMode.repeatOne.rawValue,
                    PlayerStateCodec.encodeQueue(tracks),
                    "[]",
                    Date(timeIntervalSince1970: 1_600_000_000)
                ]
            )
        }

        // 2) 同一文件换新实例升级到最新：v3 只做 ALTER TABLE ADD COLUMN。
        let upgraded = try DatabaseProvider(url: url)
        try upgraded.setupIfNeeded()

        let applied = try upgraded.dbQueue.read { db in
            try upgraded.migrator.appliedIdentifiers(db)
        }
        XCTAssertEqual(Set(applied), ["v1", "v2", "v3", "v4", "v5", "v6"])

        let loaded = try XCTUnwrap(try PlayerStateRepository(upgraded).load())
        XCTAssertEqual(loaded.tracks.map(\.title), ["legacy-a", "legacy-b"])
        XCTAssertEqual(loaded.currentIndex, 1)
        XCTAssertEqual(loaded.position, 55)
        XCTAssertEqual(loaded.mode, .repeatOne)
        XCTAssertFalse(loaded.shouldResumePlayback, "老现场没有续播意图，按最保守的 false 处理")
    }
}

// MARK: - 测试替身

/// 写盘记录器：把 save/clear 调用收集起来供断言，可注入一次失败。
private final class SaveSink: @unchecked Sendable {

    private let lock = NSLock()
    private var savedStates: [PlayerState] = []
    private var clearCalls = 0
    private var failNext = false

    /// 收到的现场（按调用顺序）。
    var saved: [PlayerState] {
        lock.lock()
        defer { lock.unlock() }
        return savedStates
    }

    /// 收到的清除调用次数。
    var clearCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clearCalls
    }

    /// 让下一次 save 抛错，用于验证重试路径。
    var failNextSave: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failNext }
        set { lock.lock(); failNext = newValue; lock.unlock() }
    }

    /// 清空已记录的内容，便于「先让既有写盘落定、再观察下一次变化」。
    func reset() {
        lock.lock()
        savedStates.removeAll()
        clearCalls = 0
        lock.unlock()
    }

    func save(_ state: PlayerState) throws {
        lock.lock()
        let shouldFail = failNext
        failNext = false
        if !shouldFail {
            savedStates.append(state)
        }
        lock.unlock()
        if shouldFail {
            throw PlaybackSessionTestError.injectedSaveFailure
        }
    }

    func clear() {
        lock.lock()
        clearCalls += 1
        lock.unlock()
    }
}

private enum PlaybackSessionTestError: Error {
    case waitTimeout
    case injectedSaveFailure
}
