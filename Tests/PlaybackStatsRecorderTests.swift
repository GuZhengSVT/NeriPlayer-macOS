// PlaybackStatsRecorderTests.swift
// NeriPlayer macOS —— M3-T2：统计写入管道的确定性单测。
//
// 覆盖面（与任务书验收一一对应）：
//   1) 切歌触发 flush：两首歌各听一段后切歌，上一首的收听与计数随切歌落库；
//   2) 定时触发 flush：假定时器到期 → 内存增量落库；
//   3) 幂等：同一段收听连续 flush 两次，第二次是空载荷，落库只发生一次；
//   4) 播放次数阈值语义：不足 30s 不计、达到 30s 计一次、同一次播放跨暂停恢复只计一次、
//      短曲播完整首也计一次；
//   5) 每日桶写入正确：PlaybackStatsFlushHandler 把增量并进累计行与 (dayStart, trackId) 桶；
//   6) 退出触发 flush：stop() 把内存里没落库的部分写出去；
//   7) 端到端：recorder 订阅真实 PlaybackStateStore（可控假引擎），走完整条链路。
//
// 为什么全部用注入时钟 + 假定时器：30 秒的等待与墙钟时间在测试里既慢又不确定；把「时间」
// 变成可控输入后，阈值、跨日切桶、周期 flush 都能在毫秒级确定性断言。
//
// 等待策略：订阅任务消费快照流是异步的，用例用 pendingDeltaCount / trackedTrackID /
// 引擎 loadCount 这些确定性信号轮询，不依赖真实音频时序，避免负载抖动导致的偶发超时。

import XCTest
import GRDB
@testable import NeriPlayer

final class PlaybackStatsRecorderTests: XCTestCase {

    /// 阈值口径常量：与 Core 侧 defaultPlayCountThresholdSeconds 同源（30s）。
    private let threshold = PlaybackStatsRecorder.defaultPlayCountThresholdSeconds

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    // MARK: - 夹具

    /// 直接驱动用的夹具：时钟与定时器都受控，落库接到临时库的真实 flush handler。
    /// 刻意不 attach（不订阅 store）—— 这组用例由 handle 显式喂快照；订阅链路本身由
    /// testPeriodicTimerFlushesPendingDeltas 与 testAttachedRecorderRecordsThroughRealStore 覆盖。
    private struct Harness {
        let recorder: PlaybackStatsRecorder
        let database: DatabaseProvider
        let clock: FakeStatsClock
        let timer: FakeStatsTimer
    }

    private func makeHarness() throws -> Harness {
        let provider = try makeProvider()
        let handler = PlaybackStatsFlushHandler(provider)
        let clock = FakeStatsClock()
        let timer = FakeStatsTimer()
        let recorder = PlaybackStatsRecorder(
            clock: { clock.now },
            dayStarter: { PlaybackStatsDailyBucket.dayStart(for: $0, calendar: Self.utcCalendar) },
            timer: timer,
            flush: { deltas in try handler.callAsFunction(deltas) }
        )
        return Harness(recorder: recorder, database: provider, clock: clock, timer: timer)
    }

    /// 固定时区日历：跨日切桶的断言不受运行机器时区影响。
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private func makeProvider() throws -> DatabaseProvider {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NeriPlayerStatsRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let provider = try DatabaseProvider(url: directory.appendingPathComponent("library.sqlite"))
        try provider.setupIfNeeded()
        return provider
    }

    /// 落一条曲目（统计表有外键指向 Track，未入库的曲目会写入失败）。
    private func insertTrack(_ name: String, duration: Double, into provider: DatabaseProvider) throws -> Track {
        let track = Track(
            url: URL(fileURLWithPath: "/tmp/NeriPlayer/stats/\(name).mp3"),
            title: name,
            duration: duration
        )
        try LibraryRepository(provider).upsertTracks([track])
        return track
    }

    /// 造一份播放快照：指定当前曲与是否在播。
    private func snapshot(
        _ track: Track?,
        isPlaying: Bool,
        position: Double = 0,
        duration: Double = 0
    ) -> PlaybackSnapshot {
        let queueTracks = track.map { [$0] } ?? []
        return PlaybackSnapshot(
            currentTrack: track,
            isPaused: !isPlaying,
            position: position,
            duration: duration,
            isCoreIdle: !isPlaying,
            queue: QueueState(
                tracks: queueTracks,
                currentIndex: track == nil ? nil : 0,
                mode: .sequential,
                shuffleOrder: []
            )
        )
    }

    /// 轮询等待一个确定性条件成立（订阅任务消费快照流是异步的）。
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        condition: () -> Bool,
        diagnostics: @escaping () -> String = { "" }
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("等待超时：\(description)；诊断：\(diagnostics())")
    }

    private func stats(_ provider: DatabaseProvider, _ trackId: UUID) throws -> PlaybackStats? {
        try PlaybackStatsRepository(provider).stats(trackId: trackId)
    }

    // MARK: - 1. 切歌触发 flush

    /// 听 A 满 30s → 切到 B：A 的收听与这一次播放应随切歌落库，B 尚未 flush 不应有行。
    func testTrackChangeFlushesPreviousTrack() async throws {
        let harness = try makeHarness()
        let trackA = try insertTrack("A", duration: 200, into: harness.database)
        let trackB = try insertTrack("B", duration: 200, into: harness.database)

        harness.recorder.handle(snapshot(trackA, isPlaying: true, duration: 200))
        harness.clock.advance(by: threshold)
        harness.recorder.handle(snapshot(trackB, isPlaying: true, duration: 200))

        let statsA = try XCTUnwrap(stats(harness.database, trackA.id), "切歌应把上一首的统计落库")
        XCTAssertEqual(statsA.totalListenSeconds, threshold, accuracy: 0.001, "A 的收听应随切歌落库")
        XCTAssertEqual(statsA.playCount, 1, "A 听满 30s，切歌时应计一次播放")
        XCTAssertNil(try stats(harness.database, trackB.id), "B 尚未 flush，不应有统计行")
    }

    // MARK: - 2. 定时触发 flush

    /// 假定时器到期 → 内存增量落库；到期前库里没有行。
    /// 走真实订阅链路（attach 才会启动定时器），用可控引擎的 seek 产生第二次快照。
    func testPeriodicTimerFlushesPendingDeltas() async throws {
        let provider = try makeProvider()
        let track = try insertTrack("Timer", duration: 200, into: provider)
        let clock = FakeStatsClock()
        let timer = FakeStatsTimer()
        let engine = FakeStatsEngine()
        let store = PlaybackStateStore(engine: engine)
        let handler = PlaybackStatsFlushHandler(provider)
        let failure = ErrorBox()
        let flushCount = Counter()
        let recorder = PlaybackStatsRecorder(
            clock: { clock.now },
            dayStarter: { PlaybackStatsDailyBucket.dayStart(for: $0, calendar: Self.utcCalendar) },
            timer: timer,
            flush: { deltas in
                flushCount.increment()
                do {
                    try handler.callAsFunction(deltas)
                } catch {
                    failure.record(error)
                    throw error
                }
            }
        )
        recorder.attach(to: store)
        defer { recorder.stop() }

        store.setQueue([track], startIndex: 0)
        try await waitUntil("store 已把曲目纳入跟踪", condition: { recorder.trackedTrackID == track.id })
        // 等到「播放片段已建立」再拨时钟：订阅流是 bufferingNewest(1)，负载高时中间态快照会被
        // 合并，若此时片段起点还没建立，拨动的 10s 不会被任何快照结算进去。
        try await waitUntil("播放片段已建立", condition: { recorder.isTrackingPlayback })

        // 播放 10s：用引擎 seek 推一份新快照，让这 10s 进入内存桶。
        clock.advance(by: 10)
        try engine.seek(to: 10)
        try await waitUntil(
            "内存已有增量",
            condition: { recorder.pendingDeltaCount > 0 },
            diagnostics: {
                let tracked = recorder.trackedTrackID?.uuidString ?? "nil"
                return "pending=\(recorder.pendingDeltaCount) tracked=\(tracked) loads=\(engine.loadCount) enginePos=\(engine.position)"
            }
        )
        XCTAssertNil(try stats(provider, track.id), "未到 flush 时机不应落库")

        // 定时器到期：假定时器由用例主动触发，不必真的等 30 秒。
        timer.fire()
        try await waitUntil(
            "定时 flush 已落库",
            condition: { (try? self.stats(provider, track.id)) ?? nil != nil },
            diagnostics: {
                let described = failure.last.map { String(describing: $0) } ?? "none"
                return "flushCount=\(flushCount.value) timerFires=\(timer.fireCount) pending=\(recorder.pendingDeltaCount) err=\(described)"
            }
        )

        let written = try XCTUnwrap(stats(provider, track.id))
        XCTAssertEqual(written.totalListenSeconds, 10, accuracy: 0.001, "定时 flush 应写入累计收听")
        XCTAssertEqual(written.playCount, 0, "只听了 10s，未达阈值不计播放次数")
    }

    // MARK: - 3. 幂等

    /// 同一段收听连续 flush 两次：第二次是空载荷，库里的值不变。
    func testRepeatedFlushDoesNotDoubleCount() async throws {
        let harness = try makeHarness()
        let track = try insertTrack("Idempotent", duration: 200, into: harness.database)

        harness.recorder.handle(snapshot(track, isPlaying: true, duration: 200))
        harness.clock.advance(by: threshold)
        harness.recorder.handle(snapshot(track, isPlaying: true, position: 30, duration: 200))

        XCTAssertTrue(harness.recorder.flush(reason: .manual))
        let first = try XCTUnwrap(stats(harness.database, track.id))
        XCTAssertEqual(harness.recorder.pendingDeltaCount, 0, "flush 后内存桶应清空")

        // 第二次 flush：内存桶已空，是 no-op；库里的值不得变化。
        XCTAssertTrue(harness.recorder.flush(reason: .manual), "空载荷 flush 应视为成功")
        let second = try XCTUnwrap(stats(harness.database, track.id))
        XCTAssertEqual(second.totalListenSeconds, first.totalListenSeconds, accuracy: 0.0001, "重复 flush 不得双计收听")
        XCTAssertEqual(second.playCount, first.playCount, "重复 flush 不得双计播放次数")
    }

    /// 写库失败时增量并回内存，下一次 flush 成功落地且数值不丢。
    func testFlushFailureRetainsDeltasForRetry() async throws {
        let provider = try makeProvider()
        let track = try insertTrack("Retry", duration: 200, into: provider)
        let clock = FakeStatsClock()
        let failure = FailureSwitch()
        let handler = PlaybackStatsFlushHandler(provider)
        let recorder = PlaybackStatsRecorder(
            clock: { clock.now },
            dayStarter: { PlaybackStatsDailyBucket.dayStart(for: $0, calendar: Self.utcCalendar) },
            timer: FakeStatsTimer(),
            flush: { deltas in
                if failure.isFailing { throw TestFlushError.boom }
                try handler.callAsFunction(deltas)
            }
        )

        recorder.handle(snapshot(track, isPlaying: true, duration: 200))
        clock.advance(by: 12)
        recorder.handle(snapshot(track, isPlaying: true, position: 12, duration: 200))

        failure.isFailing = true
        XCTAssertFalse(recorder.flush(reason: .manual), "写库失败时 flush 应返回 false")
        XCTAssertGreaterThan(recorder.pendingDeltaCount, 0, "失败后增量应并回内存等待重试")
        XCTAssertNil(try stats(provider, track.id), "失败的一次不应留下半条记录")

        failure.isFailing = false
        XCTAssertTrue(recorder.flush(reason: .manual), "重试应成功")
        let written = try XCTUnwrap(stats(provider, track.id))
        XCTAssertEqual(written.totalListenSeconds, 12, accuracy: 0.001, "重试后增量应完整落地")
    }

    // MARK: - 4. 播放次数阈值语义

    /// 不足阈值：不计播放次数，只累计收听。
    func testBelowThresholdDoesNotCountPlay() async throws {
        let harness = try makeHarness()
        let track = try insertTrack("Short", duration: 200, into: harness.database)

        harness.recorder.handle(snapshot(track, isPlaying: true, duration: 200))
        harness.clock.advance(by: threshold - 1)
        harness.recorder.flush(reason: .manual)

        let written = try XCTUnwrap(stats(harness.database, track.id))
        XCTAssertEqual(written.playCount, 0, "不足 30s 不应计播放次数")
        XCTAssertEqual(written.totalListenSeconds, threshold - 1, accuracy: 0.001, "收听时长仍应累计")
    }

    /// 达到阈值：切歌时计一次播放。
    func testReachingThresholdCountsOnePlay() async throws {
        let harness = try makeHarness()
        let trackA = try insertTrack("ReachA", duration: 200, into: harness.database)
        let trackB = try insertTrack("ReachB", duration: 200, into: harness.database)

        harness.recorder.handle(snapshot(trackA, isPlaying: true, duration: 200))
        harness.clock.advance(by: threshold)
        harness.recorder.handle(snapshot(trackB, isPlaying: true, duration: 200))

        XCTAssertEqual(try stats(harness.database, trackA.id)?.playCount, 1, "达到阈值应计一次播放")
    }

    /// 同一次播放只计一次：听满 30s 后暂停再恢复继续听，仍只计 1（暂停恢复不算新的一次）。
    func testPlayCountOncePerPlaySessionAcrossPause() async throws {
        let harness = try makeHarness()
        let trackA = try insertTrack("PauseA", duration: 600, into: harness.database)
        let trackB = try insertTrack("PauseB", duration: 600, into: harness.database)

        harness.recorder.handle(snapshot(trackA, isPlaying: true, duration: 600))
        // 听满 30s → 暂停：会话结束，结算一次播放。
        harness.clock.advance(by: threshold)
        harness.recorder.handle(snapshot(trackA, isPlaying: false, position: 30, duration: 600))
        XCTAssertEqual(try stats(harness.database, trackA.id)?.playCount, 1, "暂停应在会话结束时结算一次播放")

        // 恢复播放 120s（暂停期间不计收听）→ 切歌。总收听 150s，播放次数仍为 1。
        harness.clock.advance(by: 120)
        harness.recorder.handle(snapshot(trackA, isPlaying: true, position: 30, duration: 600))
        harness.clock.advance(by: 120)
        harness.recorder.handle(snapshot(trackB, isPlaying: true, duration: 600))

        let written = try XCTUnwrap(stats(harness.database, trackA.id))
        XCTAssertEqual(written.playCount, 1, "同一次播放跨暂停恢复只应计一次")
        XCTAssertEqual(written.totalListenSeconds, threshold + 120, accuracy: 0.001, "暂停期间不计收听，恢复后继续累计")
    }

    /// 短曲播完：曲目短于 30s 时，听满整首也计一次播放（对齐原库「播完」判据）。
    func testShortTrackCompletionCountsPlay() async throws {
        let harness = try makeHarness()
        let shortA = try insertTrack("TinyA", duration: 20, into: harness.database)
        let shortB = try insertTrack("TinyB", duration: 20, into: harness.database)

        harness.recorder.handle(snapshot(shortA, isPlaying: true, duration: 20))
        // 完整听完 20s（未到 30s 阈值）后切歌。
        harness.clock.advance(by: 20)
        harness.recorder.handle(snapshot(shortB, isPlaying: true, duration: 20))

        XCTAssertEqual(try stats(harness.database, shortA.id)?.playCount, 1, "播完整首应计一次播放")
    }

    // MARK: - 5. 每日桶写入正确

    /// 两次增量合并进同一个 (dayStart, trackId) 桶：秒数与次数累加，first/last 取最小/最大。
    func testFlushHandlerMergesDeltasIntoStatsAndDailyBucket() throws {
        let provider = try makeProvider()
        let track = try insertTrack("Bucket", duration: 200, into: provider)
        let handler = PlaybackStatsFlushHandler(provider)

        let dayStart = PlaybackStatsDailyBucket.dayStart(
            for: Date(timeIntervalSince1970: 1_700_000_000),
            calendar: Self.utcCalendar
        )
        let earlier = dayStart.addingTimeInterval(3_600)
        let later = dayStart.addingTimeInterval(7_200)

        try handler([
            PlaybackStatsDelta(trackId: track.id, dayStart: dayStart, listenSeconds: 40, playCount: 1,
                               firstPlayedAt: later, lastPlayedAt: later)
        ])
        try handler([
            PlaybackStatsDelta(trackId: track.id, dayStart: dayStart, listenSeconds: 25.5, playCount: 1,
                               firstPlayedAt: earlier, lastPlayedAt: earlier)
        ])

        let repository = PlaybackStatsRepository(provider)
        let written = try XCTUnwrap(repository.stats(trackId: track.id))
        XCTAssertEqual(written.totalListenSeconds, 65.5, accuracy: 0.0001)
        XCTAssertEqual(written.playCount, 2)
        XCTAssertEqual(written.firstPlayedAt, earlier, "firstPlayedAt 应取最早")
        XCTAssertEqual(written.lastPlayedAt, later, "lastPlayedAt 应取最近")

        let bucket = try XCTUnwrap(repository.bucket(trackId: track.id, dayStart: dayStart))
        XCTAssertEqual(bucket.totalListenSeconds, 65.5, accuracy: 0.0001)
        XCTAssertEqual(bucket.playCount, 2)
        XCTAssertEqual(bucket.firstPlayedAt, earlier)
        XCTAssertEqual(bucket.lastPlayedAt, later)
        XCTAssertEqual(try repository.bucketCount(), 1, "同一天同一首只应有一行桶")
    }

    /// 跨自然日：不同天的增量分别落到各自的桶里，累计行跨天累加。
    func testFlushHandlerWritesSeparateBucketsPerDay() throws {
        let provider = try makeProvider()
        let track = try insertTrack("CrossDay", duration: 200, into: provider)
        let handler = PlaybackStatsFlushHandler(provider)

        let day1 = PlaybackStatsDailyBucket.dayStart(
            for: Date(timeIntervalSince1970: 1_700_000_000),
            calendar: Self.utcCalendar
        )
        let day2 = day1.addingTimeInterval(24 * 3_600)

        try handler([
            PlaybackStatsDelta(trackId: track.id, dayStart: day1, listenSeconds: 10, playCount: 0,
                               firstPlayedAt: day1, lastPlayedAt: day1),
            PlaybackStatsDelta(trackId: track.id, dayStart: day2, listenSeconds: 20, playCount: 1,
                               firstPlayedAt: day2, lastPlayedAt: day2)
        ])

        let repository = PlaybackStatsRepository(provider)
        XCTAssertEqual(try repository.bucketCount(), 2, "两天应各有一行桶")
        XCTAssertEqual(
            try XCTUnwrap(repository.bucket(trackId: track.id, dayStart: day1)).totalListenSeconds,
            10,
            accuracy: 0.0001
        )
        XCTAssertEqual(try XCTUnwrap(repository.bucket(trackId: track.id, dayStart: day2)).playCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(repository.stats(trackId: track.id)).totalListenSeconds,
            30,
            accuracy: 0.0001,
            "累计行应跨越两天累加"
        )
    }

    // MARK: - 6. 退出触发 flush

    /// stop() 把内存里还没到时机的增量写出去，并清空内存桶。
    func testStopFlushesPendingDeltas() async throws {
        let harness = try makeHarness()
        let track = try insertTrack("Quit", duration: 200, into: harness.database)

        harness.recorder.handle(snapshot(track, isPlaying: true, duration: 200))
        harness.clock.advance(by: 8)
        harness.recorder.handle(snapshot(track, isPlaying: true, position: 8, duration: 200))
        XCTAssertGreaterThan(harness.recorder.pendingDeltaCount, 0, "退出前内存里应有未落库增量")

        harness.recorder.stop()
        let written = try XCTUnwrap(stats(harness.database, track.id), "退出应把内存增量写出")
        XCTAssertEqual(written.totalListenSeconds, 8, accuracy: 0.001)
        XCTAssertEqual(harness.recorder.pendingDeltaCount, 0, "退出后内存桶应清空")
        XCTAssertGreaterThanOrEqual(harness.timer.cancelCount, 1, "退出应取消定时器")
    }

    // MARK: - 7. 端到端（真实 PlaybackStateStore + 可控引擎）

    /// 订阅真实 store 的完整链路：入队即播 → 播放满阈值 → 切歌 → 统计落到库里。
    /// 用引擎 loadCount 与 trackedTrackID 作为确定性信号，等待不依赖真实音频时序。
    func testAttachedRecorderRecordsThroughRealStore() async throws {
        let provider = try makeProvider()
        let trackA = try insertTrack("LiveA", duration: 200, into: provider)
        let trackB = try insertTrack("LiveB", duration: 200, into: provider)

        let engine = FakeStatsEngine()
        let store = PlaybackStateStore(engine: engine)
        let clock = FakeStatsClock()
        let handler = PlaybackStatsFlushHandler(provider)
        let recorder = PlaybackStatsRecorder(
            clock: { clock.now },
            dayStarter: { PlaybackStatsDailyBucket.dayStart(for: $0, calendar: Self.utcCalendar) },
            timer: FakeStatsTimer(),
            flush: { deltas in try handler.callAsFunction(deltas) }
        )
        recorder.attach(to: store)
        defer { recorder.stop() }

        // 入队即播：等 store 观察到引擎进入播放态并把 A 纳入跟踪。
        store.setQueue([trackA, trackB], startIndex: 0)
        try await waitUntil("store 已把 A 纳入跟踪", condition: { recorder.trackedTrackID == trackA.id })
        try await waitUntil("A 的播放片段已建立", condition: { recorder.isTrackingPlayback })
        XCTAssertGreaterThan(engine.loadCount, 0, "入队即播应已加载 A")

        // 播放满阈值后切歌：A 的统计应随切歌落库。
        clock.advance(by: threshold)
        store.next()
        try await waitUntil(
            "A 的统计已落库",
            condition: { (try? self.stats(provider, trackA.id)) ?? nil != nil },
            diagnostics: { "pending=\(recorder.pendingDeltaCount) loads=\(engine.loadCount)" }
        )

        let written = try XCTUnwrap(stats(provider, trackA.id))
        XCTAssertEqual(written.totalListenSeconds, threshold, accuracy: 1, "A 的收听应达到阈值附近")
        XCTAssertEqual(written.playCount, 1, "A 听满阈值应计一次播放")
    }
}

// MARK: - 测试替身

/// 可控时钟：用例直接拨动 now，不依赖墙钟。
private final class FakeStatsClock: @unchecked Sendable {

    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// 假定时器：把 handler 握住，由用例主动 fire，因此「定时触发 flush」不必真等 30 秒。
private final class FakeStatsTimer: PlaybackStatsTimerScheduling, @unchecked Sendable {

    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var cancelCountValue = 0
    private var fireCountValue = 0

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelCountValue
    }

    var fireCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return fireCountValue
    }

    func schedule(every interval: TimeInterval, handler: @escaping @Sendable () -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelCountValue += 1
        handler = nil
        lock.unlock()
    }

    /// 模拟定时器到期。
    func fire() {
        lock.lock()
        fireCountValue += 1
        let handler = self.handler
        lock.unlock()
        handler?()
    }
}

/// 线程安全计数器。
private final class Counter: @unchecked Sendable {

    private let lock = NSLock()
    private var valueStorage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return valueStorage
    }

    func increment() {
        lock.lock()
        valueStorage += 1
        lock.unlock()
    }
}

/// 记录闭包里捕获到的最后一个错误（只用于失败诊断）。
private final class ErrorBox: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: (any Error)?

    var last: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ error: any Error) {
        lock.lock()
        storage = error
        lock.unlock()
    }
}

/// 可切换的失败开关（跨闭包共享）。
private final class FailureSwitch: @unchecked Sendable {

    private let lock = NSLock()
    private var value = false

    var isFailing: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

/// 模拟写库失败的测试错误。
private enum TestFlushError: Error {
    case boom
}

/// 可控假引擎：不驱动 libmpv，加载即进入「播放中」；用于端到端链路。
/// 与 PlaybackStateStoreTests 的 FakeEngine 同构，本文件私有不与外层共享。
private final class FakeStatsEngine: PlayerEngine, @unchecked Sendable {

    private let lock = NSLock()
    private var stateValue: PlayerEngineState = .idle
    private var continuations: [UUID: AsyncStream<PlayerEngineState>.Continuation] = [:]
    private var loadCountValue = 0

    var currentURL: URL? { snapshot.currentURL }
    var isPaused: Bool { snapshot.isPaused }
    var position: Double { snapshot.position }
    var duration: Double { snapshot.duration }
    var isCoreIdle: Bool { snapshot.isCoreIdle }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadCountValue
    }

    func load(url: URL) throws {
        lock.lock()
        loadCountValue += 1
        lock.unlock()
        mutate { state in
            state.currentURL = url
            state.position = 0
            state.duration = 200
            state.isPaused = false
            state.isCoreIdle = false
        }
    }

    func play() throws { mutate { $0.isPaused = false } }
    func pause() throws { mutate { $0.isPaused = true } }
    func stop() throws { mutate { $0 = .idle } }
    func seek(to seconds: Double) throws { mutate { $0.position = seconds } }
    func setVolume(_ volume: Double) throws {}

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
        let changed = next != stateValue
        stateValue = next
        let listeners = Array(continuations.values)
        lock.unlock()
        guard changed else { return }
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
