// TrafficStatsTests.swift
// NeriPlayer macOS —— M3-T4：流量统计（表 / 记录 / 汇总）的确定性单测。
//
// 覆盖面（与任务书验收「单测：计数正确性」一一对应）：
//   1) 记录：按接入方式（Wi-Fi / 有线 / 蜂窝 / 其他）分列累加，按用途（播放 / 下载）分列累加，
//      请求次数递增，非正字节数被忽略；
//   2) 缓存命中：单独成列，不污染任何网络字节列，命中次数单独计；
//   3) 分日：同一天多次记录合并成一行，跨天分成不同行（dayStart 为本地零点）；
//   4) 读取：按日点查、最近 N 天倒序、区间过滤、区间汇总与缓存命中率、清空；
//   5) 迁移：v3 → v4 新增流量表且既有播放现场不受影响。
//
// 为什么用「注入时刻」而不是等到明天：分日与区间是纯逻辑，把时刻变成输入就能在毫秒内
// 覆盖跨天、区间边界这些用例，不必依赖真实时钟。

import XCTest
import GRDB
@testable import NeriPlayer

final class TrafficStatsTests: XCTestCase {

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
            .appendingPathComponent("NeriPlayerTrafficTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("library.sqlite")
    }

    private func makeProvider() throws -> DatabaseProvider {
        let provider = try DatabaseProvider(url: try makeDatabaseURL())
        try provider.setupIfNeeded()
        return provider
    }

    /// 固定的一天（本地时区下的某个瞬间），后续跨天用例都相对它偏移。
    private let dayOne = Date(timeIntervalSince1970: 1_700_000_000)

    /// 相对基准日偏移若干天。
    ///
    /// 用 UTC 日历做整日加法并给出回退，避免在测试里裸露强制解包；断言一律通过
    /// `TrafficStatsBucket.dayStart(for:)` 求期望值，因此与实现（用 Calendar.current）的口径
    /// 始终一致 —— 这里只负责产出「不同的自然日」，不负责定义自然日的边界。
    private func day(_ offset: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(byAdding: .day, value: offset, to: dayOne) ?? dayOne
    }

    // MARK: - 1. 记录：网络字节

    /// 四种接入方式各自累加到自己的列，互不串味。
    func testRecordAccumulatesPerNetworkType() throws {
        let repository = TrafficStatsRepository(try makeProvider())

        try repository.record(bytes: 100, networkType: .wifi, source: .playback, at: dayOne)
        try repository.record(bytes: 25, networkType: .wired, source: .playback, at: dayOne)
        try repository.record(bytes: 7, networkType: .cellular, source: .playback, at: dayOne)
        try repository.record(bytes: 3, networkType: .other, source: .playback, at: dayOne)
        try repository.record(bytes: 50, networkType: .wifi, source: .playback, at: dayOne)

        let bucket = try XCTUnwrap(try repository.bucket(forDayContaining: dayOne))
        XCTAssertEqual(bucket.wifiBytes, 150)
        XCTAssertEqual(bucket.wiredBytes, 25)
        XCTAssertEqual(bucket.cellularBytes, 7)
        XCTAssertEqual(bucket.otherBytes, 3)
        XCTAssertEqual(bucket.networkBytes, 185)
        XCTAssertEqual(bucket.bytes(on: .wifi), 150)
        XCTAssertEqual(bucket.bytes(on: .wired), 25)
    }

    /// 播放与下载各自累加，互不影响。
    func testRecordAccumulatesPerUsageSource() throws {
        let repository = TrafficStatsRepository(try makeProvider())

        try repository.record(bytes: 1000, networkType: .wifi, source: .playback, at: dayOne)
        try repository.record(bytes: 200, networkType: .wifi, source: .playback, at: dayOne)
        try repository.record(bytes: 5000, networkType: .wifi, source: .download, at: dayOne)

        let bucket = try XCTUnwrap(try repository.bucket(forDayContaining: dayOne))
        XCTAssertEqual(bucket.playbackNetworkBytes, 1200)
        XCTAssertEqual(bucket.downloadNetworkBytes, 5000)
        // 两列之和必须等于接入方式列的合计：用途维度不能漏记或重复记。
        XCTAssertEqual(bucket.playbackNetworkBytes + bucket.downloadNetworkBytes, bucket.networkBytes)
    }

    /// 每次有效记录都算一次请求。
    func testRecordCountsRequests() throws {
        let repository = TrafficStatsRepository(try makeProvider())

        try repository.record(bytes: 1, networkType: .wifi, source: .playback, at: dayOne)
        try repository.record(bytes: 2, networkType: .wired, source: .download, at: dayOne)

        XCTAssertEqual(try repository.bucket(forDayContaining: dayOne)?.requestCount, 2)
    }

    /// 非正字节数没有意义：不记列、不计请求次数（对齐原库 `if (bytes <= 0L) return`）。
    func testRecordIgnoresNonPositiveBytes() throws {
        let repository = TrafficStatsRepository(try makeProvider())

        try repository.record(bytes: 0, networkType: .wifi, source: .playback, at: dayOne)
        try repository.record(bytes: -100, networkType: .wifi, source: .playback, at: dayOne)

        XCTAssertNil(
            try repository.bucket(forDayContaining: dayOne),
            "全是无效字节时不该建出一行空桶"
        )
    }

    /// 缓存命中单独成列：不进网络字节，只累加命中量与命中次数。
    func testCacheHitIsSeparateFromNetworkBytes() throws {
        let repository = TrafficStatsRepository(try makeProvider())

        try repository.record(bytes: 400, networkType: .wifi, source: .playback, at: dayOne)
        try repository.recordCacheHit(bytes: 600, at: dayOne)
        try repository.recordCacheHit(bytes: 100, at: dayOne)

        let bucket = try XCTUnwrap(try repository.bucket(forDayContaining: dayOne))
        XCTAssertEqual(bucket.cacheHitBytes, 700)
        XCTAssertEqual(bucket.cacheHitCount, 2)
        XCTAssertEqual(bucket.networkBytes, 400, "缓存命中的字节没有走网络，不该计入网络列")
        XCTAssertEqual(bucket.requestCount, 1, "缓存命中不是网络请求，不该增加请求次数")
    }

    /// 非正字节数的缓存命中同样被忽略。
    func testCacheHitIgnoresNonPositiveBytes() throws {
        let repository = TrafficStatsRepository(try makeProvider())

        try repository.recordCacheHit(bytes: 0, at: dayOne)
        try repository.recordCacheHit(bytes: -5, at: dayOne)

        XCTAssertNil(try repository.bucket(forDayContaining: dayOne))
    }

    // MARK: - 2. 分日

    /// 同一天多次记录合并成一行。
    func testRecordsOnSameDayAccumulateIntoOneRow() throws {
        let provider = try makeProvider()
        let repository = TrafficStatsRepository(provider)

        // 同一天的三个不同时刻（本地零点、当天稍后）。
        let start = TrafficStatsBucket.dayStart(for: dayOne)
        try repository.record(bytes: 10, networkType: .wifi, source: .playback, at: start)
        try repository.record(bytes: 20, networkType: .wifi, source: .playback, at: start.addingTimeInterval(3600))
        try repository.record(bytes: 30, networkType: .wifi, source: .playback, at: start.addingTimeInterval(7200))

        XCTAssertEqual(try rowCount(in: provider), 1, "同一天只应有一行")
        XCTAssertEqual(try repository.bucket(forDayContaining: dayOne)?.wifiBytes, 60)
    }

    /// 跨天分成不同行，各自带上自己的本地零点。
    func testRecordsOnDifferentDaysCreateSeparateRows() throws {
        let provider = try makeProvider()
        let repository = TrafficStatsRepository(provider)

        try repository.record(bytes: 10, networkType: .wifi, source: .playback, at: day(0))
        try repository.record(bytes: 20, networkType: .wifi, source: .playback, at: day(1))
        try repository.record(bytes: 30, networkType: .wifi, source: .playback, at: day(3))

        XCTAssertEqual(try rowCount(in: provider), 3)
        XCTAssertEqual(try repository.bucket(forDayContaining: day(0))?.wifiBytes, 10)
        XCTAssertEqual(try repository.bucket(forDayContaining: day(1))?.wifiBytes, 20)
        XCTAssertEqual(try repository.bucket(forDayContaining: day(2)), nil, "没有记录的日期不该凭空出现")
        XCTAssertEqual(try repository.bucket(forDayContaining: day(3))?.wifiBytes, 30)
    }

    /// dayStart 落在本地零点：同一天任意时刻查询都命中同一行。
    func testBucketIsKeyedByLocalDayStart() throws {
        let repository = TrafficStatsRepository(try makeProvider())
        let start = TrafficStatsBucket.dayStart(for: dayOne)

        try repository.record(bytes: 42, networkType: .wired, source: .download, at: start.addingTimeInterval(86_399))

        XCTAssertEqual(try repository.bucket(forDayContaining: start)?.wiredBytes, 42)
        XCTAssertEqual(
            try repository.bucket(forDayContaining: start.addingTimeInterval(86_399))?.wiredBytes,
            42,
            "同一天的最末一秒仍应命中当天的桶"
        )
    }

    // MARK: - 3. 读取与汇总

    /// 最近 N 天按日期倒序返回，且 limit 生效。
    func testRecentBucketsAreNewestFirstAndLimited() throws {
        let repository = TrafficStatsRepository(try makeProvider())
        for offset in 0...4 {
            try repository.record(bytes: Int64(10 * (offset + 1)), networkType: .wifi, source: .playback, at: day(offset))
        }

        let all = try repository.recentBuckets(limit: 10)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all.map(\.dayStart), all.map(\.dayStart).sorted(by: >), "应按日期倒序")

        let limited = try repository.recentBuckets(limit: 2)
        XCTAssertEqual(limited.count, 2)
        XCTAssertEqual(limited.first?.wifiBytes, 50, "最新的在前")
        XCTAssertEqual(limited.last?.wifiBytes, 40)

        XCTAssertTrue(try repository.recentBuckets(limit: 0).isEmpty, "limit 非法时返回空而不是全量")
    }

    /// 区间查询是「起点含、终点不含」，用于按周期统计。
    func testBucketsRespectTimeRange() throws {
        let repository = TrafficStatsRepository(try makeProvider())
        for offset in 0...3 {
            try repository.record(bytes: Int64(10 * (offset + 1)), networkType: .wifi, source: .playback, at: day(offset))
        }

        let start = TrafficStatsBucket.dayStart(for: day(1))
        let end = TrafficStatsBucket.dayStart(for: day(3))
        let range = try repository.buckets(from: start, to: end)

        XCTAssertEqual(range.count, 2, "应包含 day(1) 与 day(2)，排除 day(3)")
        XCTAssertEqual(range.map(\.wifiBytes), [20, 30])
        XCTAssertEqual(range.map(\.dayStart), range.map(\.dayStart).sorted(), "区间内应按日期升序")
    }

    /// 汇总把区间内的桶加起来，并算出缓存命中率。
    func testSummaryAggregatesRangeAndComputesCacheHitRate() throws {
        let repository = TrafficStatsRepository(try makeProvider())

        try repository.record(bytes: 400, networkType: .wifi, source: .playback, at: day(1))
        try repository.record(bytes: 100, networkType: .wired, source: .download, at: day(2))
        try repository.recordCacheHit(bytes: 500, at: day(2))
        // 区间外的一天，不该被算进去。
        try repository.record(bytes: 9999, networkType: .wifi, source: .playback, at: day(10))

        let summary = try repository.summary(
            from: TrafficStatsBucket.dayStart(for: day(1)),
            to: TrafficStatsBucket.dayStart(for: day(3))
        )

        XCTAssertEqual(summary.wifiBytes, 400)
        XCTAssertEqual(summary.wiredBytes, 100)
        XCTAssertEqual(summary.networkBytes, 500)
        XCTAssertEqual(summary.playbackNetworkBytes, 400)
        XCTAssertEqual(summary.downloadNetworkBytes, 100)
        XCTAssertEqual(summary.cacheHitBytes, 500)
        XCTAssertEqual(summary.requestCount, 2)
        XCTAssertEqual(summary.cacheHitCount, 1)
        XCTAssertEqual(summary.measuredPlaybackBytes, 900, "播放实际消耗 = 网络播放 + 缓存命中")
        XCTAssertEqual(summary.cacheHitRate, 500.0 / 900.0, accuracy: 1e-9)
        XCTAssertTrue(summary.hasTrafficData)
    }

    /// 空库的汇总：全零、无数据、命中率为 0（不做除零）。
    func testSummaryIsEmptyAndSafeWhenNoData() throws {
        let repository = TrafficStatsRepository(try makeProvider())

        let summary = try repository.summary()

        XCTAssertEqual(summary.networkBytes, 0)
        XCTAssertEqual(summary.cacheHitRate, 0)
        XCTAssertFalse(summary.hasTrafficData)
    }

    /// 清空后一切归零。
    func testClearAllRemovesEverything() throws {
        let provider = try makeProvider()
        let repository = TrafficStatsRepository(provider)
        try repository.record(bytes: 100, networkType: .wifi, source: .playback, at: dayOne)
        try repository.recordCacheHit(bytes: 50, at: dayOne)

        try repository.clearAll()

        XCTAssertEqual(try rowCount(in: provider), 0)
        XCTAssertNil(try repository.bucket(forDayContaining: dayOne))
        XCTAssertFalse(try repository.summary().hasTrafficData)
    }

    // MARK: - 4. 迁移

    /// v3 → v4：新增流量表，且既有播放现场不受影响。
    func testV3ToV4MigrationAddsTrafficTableAndPreservesSession() throws {
        // 1) 建一个只到 v3 的库，写入一份播放现场。
        let url = try makeDatabaseURL()
        let provider = try DatabaseProvider(url: url)
        try provider.migrator.migrate(provider.dbQueue, upTo: "v3")
        let tracks = [Track(url: URL(fileURLWithPath: "/music/legacy.flac"), title: "legacy")]
        try PlayerStateRepository(provider).save(
            PlayerState(tracks: tracks, currentIndex: 0, position: 12, mode: .repeatAll, shouldResumePlayback: true)
        )

        // 2) 升级到最新：v4 只做 CREATE TABLE。
        let upgraded = try DatabaseProvider(url: url)
        try upgraded.setupIfNeeded()

        let applied = try upgraded.dbQueue.read { db in
            try upgraded.migrator.appliedIdentifiers(db)
        }
        XCTAssertEqual(Set(applied), ["v1", "v2", "v3", "v4", "v5"])

        // 3) 既有现场原样保留。
        let restored = try XCTUnwrap(try PlayerStateRepository(upgraded).load())
        XCTAssertEqual(restored.tracks.map(\.title), ["legacy"])
        XCTAssertEqual(restored.position, 12)
        XCTAssertTrue(restored.shouldResumePlayback)

        // 4) 新表可用：迁移后立刻能记录与读取。
        let repository = TrafficStatsRepository(upgraded)
        try repository.record(bytes: 77, networkType: .wired, source: .playback)
        XCTAssertEqual(try repository.summary().wiredBytes, 77)
    }

    // MARK: - 5. 值逻辑

    /// 网络类型都有各自的展示名，且互不重复（统计页按它分组）。
    func testNetworkTypeDisplayNamesAreDistinctAndNonEmpty() {
        let names = TrafficNetworkType.allCases.map(\.displayName)
        XCTAssertEqual(names.count, TrafficNetworkType.allCases.count)
        XCTAssertEqual(Set(names).count, names.count, "展示名不该重复")
        XCTAssertFalse(names.contains(where: \.isEmpty))
    }

    /// 工具：查流量表的行数。
    private func rowCount(in provider: DatabaseProvider) throws -> Int {
        try provider.dbQueue.read { db in
            try TrafficStatsRecord.fetchCount(db)
        }
    }
}
