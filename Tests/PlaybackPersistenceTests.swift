// PlaybackPersistenceTests.swift
// NeriPlayer macOS —— M3-T1：DB v2 迁移与三张新表的测试。
//
// 覆盖点（与任务书验收一一对应）：
//   - v1 → v2 升级不丢数据：只在 v1 上建库并写入 Track/Playlist/PlaylistEntry/Favorite，
//     再升级到 v2，断言 v1 数据原样保留且 v2 的新表可用；
//   - 新表 CRUD：PlayHistory / PlaybackStats / PlayerState 的增删改查；
//   - 外键级联：删曲目 / 整库替换会连带清掉历史、统计与每日桶；
//   - 按需查询：历史按时间倒序、统计按 trackId 点查、每日桶按曲目与日期区间取。
//
// 全部用例在临时目录建库（DatabaseProvider(url:) 注入），跑完即删，不碰真实 Application Support。

import XCTest
import GRDB
@testable import NeriPlayer

final class PlaybackPersistenceTests: XCTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    // MARK: - 夹具

    /// 建一个空库的目录并返回其 URL（不迁移）。同一用例里可以据此先建 v1、再升级 v2。
    private func makeDatabaseURL() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NeriPlayerPlaybackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("library.sqlite")
    }

    /// 建一个已迁移到最新的库。
    private func makeProvider() throws -> DatabaseProvider {
        let provider = try DatabaseProvider(url: try makeDatabaseURL())
        try provider.setupIfNeeded()
        return provider
    }

    /// 建一个只迁移到 v1 的库（用于验证升级路径）。
    private func makeV1Provider() throws -> DatabaseProvider {
        let provider = try DatabaseProvider(url: try makeDatabaseURL())
        // 只跑 v1：v2 之后的新表此时不应存在，模拟「老版本已安装的库文件」。
        try provider.migrator.migrate(provider.dbQueue, upTo: "v1")
        return provider
    }

    /// 落一条曲目，返回其 id。
    @discardableResult
    private func insertTrack(_ name: String, into provider: DatabaseProvider) throws -> UUID {
        let track = Track(url: URL(fileURLWithPath: "/tmp/NeriPlayer/\(name).mp3"))
        try LibraryRepository(provider).upsertTracks([track])
        return track.id
    }

    /// 直接查某表行数。
    private func rowCount(_ table: String, in provider: DatabaseProvider) throws -> Int {
        try provider.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
        }
    }

    /// 造一个带完整元数据的队列项，用于 PlayerState 的往返断言。
    private func makeQueueTrack(_ name: String, artist: String? = nil, duration: Double? = 200) -> Track {
        Track(
            url: URL(fileURLWithPath: "/tmp/NeriPlayer/queue/\(name).flac"),
            title: name,
            artist: artist,
            duration: duration
        )
    }

    // MARK: - 迁移

    func testSetupCreatesV2Tables() throws {
        let provider = try makeProvider()
        let tables = try provider.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        XCTAssertTrue(tables.contains(DatabaseSchema.playHistory))
        XCTAssertTrue(tables.contains(DatabaseSchema.playbackStats))
        XCTAssertTrue(tables.contains(DatabaseSchema.playbackStatsDailyBucket))
        XCTAssertTrue(tables.contains(DatabaseSchema.playerState))
        // v1 的四张表仍在。
        XCTAssertTrue(tables.contains(DatabaseSchema.track))
        XCTAssertTrue(tables.contains(DatabaseSchema.favorite))
    }

    func testV2IsNotAppliedBeforeUpgrade() throws {
        let provider = try makeV1Provider()
        let applied = try provider.dbQueue.read { db in
            try provider.migrator.appliedIdentifiers(db)
        }
        XCTAssertEqual(applied, ["v1"])
        let tables = try provider.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        XCTAssertFalse(tables.contains(DatabaseSchema.playHistory))
    }

    func testV1ToV2MigrationPreservesV1Data() throws {
        // 1) 在 v1 库上写入四张 v1 表的数据。
        let provider = try makeV1Provider()
        let library = LibraryRepository(provider)
        let playlists = PlaylistRepository(provider)
        let favorites = FavoriteRepository(provider)

        let kept = Track(
            url: URL(fileURLWithPath: "/tmp/NeriPlayer/legacy-kept.mp3"),
            title: "legacy-kept",
            artist: "Legacy Artist",
            duration: 321
        )
        let other = Track(
            url: URL(fileURLWithPath: "/tmp/NeriPlayer/legacy-other.mp3"),
            title: "legacy-other"
        )
        try library.upsertTracks([kept, other])
        let playlist = try playlists.create(name: "旧歌单")
        try playlists.addTrack(playlistId: playlist.id, trackId: kept.id)
        try playlists.addTrack(playlistId: playlist.id, trackId: other.id)
        try favorites.favorite(trackId: kept.id)

        // 记下升级前的 id 与内容，升级后要逐项对得上。
        XCTAssertEqual(try library.allTracks().count, 2)

        // 2) 升级到最新：同一文件、新 provider，setupIfNeeded 会补跑 v2 与 v3。
        let upgraded = try DatabaseProvider(url: provider.databaseURL)
        try upgraded.setupIfNeeded()

        let applied = try upgraded.dbQueue.read { db in
            try upgraded.migrator.appliedIdentifiers(db)
        }
        XCTAssertEqual(Set(applied), ["v1", "v2", "v3", "v4", "v5"])

        // 3) v1 数据仍在且未被重建（id 保留）。
        let tracks = try LibraryRepository(upgraded).allTracks()
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks.first(where: { $0.title == "legacy-kept" })?.id, kept.id)
        XCTAssertEqual(tracks.first(where: { $0.title == "legacy-kept" })?.artist, "Legacy Artist")
        XCTAssertEqual(tracks.first(where: { $0.title == "legacy-kept" })?.duration, 321)

        let list = try PlaylistRepository(upgraded).list()
        XCTAssertEqual(list.map(\.name), ["旧歌单"])
        XCTAssertEqual(
            try PlaylistRepository(upgraded).entries(playlistId: playlist.id).map(\.title),
            ["legacy-kept", "legacy-other"]
        )
        XCTAssertEqual(try FavoriteRepository(upgraded).favorites().map(\.title), ["legacy-kept"])

        // 4) v2 的新表可用：升级后的库能正常写入历史。
        let history = PlayHistoryRepository(upgraded)
        try history.record(trackId: kept.id, resumePositionSeconds: 12)
        XCTAssertEqual(try history.entry(trackId: kept.id)?.resumePositionSeconds, 12)
    }

    func testMigrationAppliedOnceAfterUpgrade() throws {
        // 升级后再新建 provider 应发现迁移均已应用、空转通过（幂等）。
        let provider = try makeV1Provider()
        let upgraded = try DatabaseProvider(url: provider.databaseURL)
        try upgraded.setupIfNeeded()
        let again = try DatabaseProvider(url: provider.databaseURL)
        XCTAssertNoThrow(try again.setupIfNeeded())
        let applied = try again.dbQueue.read { db in
            try again.migrator.appliedIdentifiers(db)
        }
        XCTAssertEqual(Set(applied), ["v1", "v2", "v3", "v4", "v5"])
    }

    // MARK: - 播放历史 CRUD

    func testPlayHistoryRecordInsertsAndSortsByRecency() throws {
        let provider = try makeProvider()
        let repository = PlayHistoryRepository(provider)
        let first = try insertTrack("history-a", into: provider)
        let second = try insertTrack("history-b", into: provider)

        // 先播 a、后播 b：最近播放应是 b 在前。
        try repository.record(trackId: first, playedAt: Date(timeIntervalSince1970: 1000))
        try repository.record(trackId: second, playedAt: Date(timeIntervalSince1970: 2000))

        XCTAssertEqual(try repository.count(), 2)
        XCTAssertEqual(try repository.recent().map(\.trackId), [second, first])
        XCTAssertEqual(try repository.recent(limit: 1).map(\.trackId), [second])
        XCTAssertEqual(try repository.entry(trackId: first)?.playedAt, Date(timeIntervalSince1970: 1000))
    }

    func testPlayHistoryRecordIsIdempotentPerTrack() throws {
        let provider = try makeProvider()
        let repository = PlayHistoryRepository(provider)
        let trackId = try insertTrack("repeat", into: provider)

        try repository.record(trackId: trackId, playedAt: Date(timeIntervalSince1970: 100), resumePositionSeconds: 5)
        // 再播一次：只刷新时间，不新增行；未传位置则保留原记忆位置。
        let updated = try repository.record(trackId: trackId, playedAt: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(try repository.count(), 1)
        XCTAssertEqual(updated.playedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(updated.resumePositionSeconds, 5)
    }

    func testPlayHistoryUpdateResumePositionKeepsPlayedAt() throws {
        let provider = try makeProvider()
        let repository = PlayHistoryRepository(provider)
        let trackId = try insertTrack("resume", into: provider)

        try repository.record(trackId: trackId, playedAt: Date(timeIntervalSince1970: 500))
        let updated = try repository.updateResumePosition(trackId: trackId, position: 42.5)

        XCTAssertEqual(updated.resumePositionSeconds, 42.5)
        XCTAssertEqual(try repository.rememberedPosition(trackId: trackId), 42.5)
        // 已存在的行保持原 playedAt。
        XCTAssertEqual(updated.playedAt, Date(timeIntervalSince1970: 500))

        // 没有历史时也会建行。
        let fresh = try insertTrack("resume-fresh", into: provider)
        XCTAssertEqual(try repository.rememberedPosition(trackId: fresh), 0)
        _ = try repository.updateResumePosition(trackId: fresh, position: 3)
        XCTAssertEqual(try repository.rememberedPosition(trackId: fresh), 3)
    }

    func testPlayHistoryDeleteAndClear() throws {
        let provider = try makeProvider()
        let repository = PlayHistoryRepository(provider)
        let first = try insertTrack("del-a", into: provider)
        let second = try insertTrack("del-b", into: provider)
        try repository.record(trackId: first)
        try repository.record(trackId: second)

        try repository.delete(trackId: first)
        XCTAssertEqual(try repository.count(), 1)
        XCTAssertNil(try repository.entry(trackId: first))

        try repository.clear()
        XCTAssertEqual(try repository.count(), 0)
    }

    func testPlayHistoryRejectsUnknownTrack() throws {
        let provider = try makeProvider()
        let repository = PlayHistoryRepository(provider)
        // 外键约束：不存在的 trackId 写入应失败（不是静默成功）。
        XCTAssertThrowsError(try repository.record(trackId: UUID())) { error in
            XCTAssertTrue(error is DatabaseError)
        }
    }

    func testPlayHistoryFallsBackToTrackIdForSameTimestamp() throws {
        let provider = try makeProvider()
        let repository = PlayHistoryRepository(provider)
        let ids = try (0..<3).map { try insertTrack("same-time-\($0)", into: provider) }
        let stamp = Date(timeIntervalSince1970: 7777)
        for id in ids {
            try repository.record(trackId: id, playedAt: stamp)
        }
        // 时间相同：以 trackId 升序兜底，顺序确定（测试与分页依赖）。
        let expected = ids.sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(try repository.recent().map(\.trackId), expected)
    }

    // MARK: - 播放统计 CRUD

    func testPlaybackStatsUpsertAndFetch() throws {
        let provider = try makeProvider()
        let repository = PlaybackStatsRepository(provider)
        let trackId = try insertTrack("stats-a", into: provider)

        let written = PlaybackStats(
            trackId: trackId,
            totalListenSeconds: 1234.5,
            playCount: 7,
            firstPlayedAt: Date(timeIntervalSince1970: 100),
            lastPlayedAt: Date(timeIntervalSince1970: 5000)
        )
        try repository.upsert(written)

        let read = try repository.stats(trackId: trackId)
        XCTAssertEqual(read, written)
        XCTAssertNil(try repository.stats(trackId: UUID()))

        // 覆盖语义：第二次 upsert 是整行覆盖，不是累加。
        let overwritten = PlaybackStats(
            trackId: trackId,
            totalListenSeconds: 10,
            playCount: 1,
            firstPlayedAt: Date(timeIntervalSince1970: 6000),
            lastPlayedAt: Date(timeIntervalSince1970: 6000)
        )
        try repository.upsert(overwritten)
        XCTAssertEqual(try repository.stats(trackId: trackId)?.playCount, 1)
        XCTAssertEqual(try repository.stats(trackId: trackId)?.totalListenSeconds, 10)
    }

    func testPlaybackStatsAllSortedByLastPlayedDescending() throws {
        let provider = try makeProvider()
        let repository = PlaybackStatsRepository(provider)
        let a = try insertTrack("stats-sort-a", into: provider)
        let b = try insertTrack("stats-sort-b", into: provider)
        let c = try insertTrack("stats-sort-c", into: provider)

        try repository.upsert(PlaybackStats(
            trackId: a, totalListenSeconds: 1, playCount: 1,
            firstPlayedAt: Date(timeIntervalSince1970: 100), lastPlayedAt: Date(timeIntervalSince1970: 100)
        ))
        try repository.upsert(PlaybackStats(
            trackId: b, totalListenSeconds: 1, playCount: 1,
            firstPlayedAt: Date(timeIntervalSince1970: 300), lastPlayedAt: Date(timeIntervalSince1970: 300)
        ))
        // c 无最近播放时间（NULL）：按 SQLite 的 DESC 语义排到末尾。
        try repository.upsert(PlaybackStats(trackId: c, totalListenSeconds: 0, playCount: 0))

        XCTAssertEqual(try repository.all().map(\.trackId), [b, a, c])
    }

    func testPlaybackStatsDeleteAndClear() throws {
        let provider = try makeProvider()
        let repository = PlaybackStatsRepository(provider)
        let a = try insertTrack("stats-del-a", into: provider)
        let b = try insertTrack("stats-del-b", into: provider)
        try repository.upsert(PlaybackStats(trackId: a, totalListenSeconds: 5, playCount: 1))
        try repository.upsert(PlaybackStats(trackId: b, totalListenSeconds: 6, playCount: 2))
        try repository.upsert(bucket: PlaybackStatsDailyBucket(
            dayStart: Date(timeIntervalSince1970: 0), trackId: a, totalListenSeconds: 5, playCount: 1
        ))

        try repository.delete(trackId: a)
        XCTAssertNil(try repository.stats(trackId: a))
        // 每日桶随统计一并删除（delete 在同一事务里显式清桶）。
        XCTAssertEqual(try repository.bucketCount(), 0)
        XCTAssertEqual(try repository.all().map(\.trackId), [b])

        try repository.clear()
        XCTAssertTrue(try repository.all().isEmpty)
    }

    // MARK: - 每日桶

    func testDailyBucketUpsertAndQueryByTrack() throws {
        let provider = try makeProvider()
        let repository = PlaybackStatsRepository(provider)
        let trackId = try insertTrack("bucket-a", into: provider)
        let otherId = try insertTrack("bucket-b", into: provider)

        let day1 = Date(timeIntervalSince1970: 86_400)
        let day2 = Date(timeIntervalSince1970: 172_800)
        try repository.upsert(bucket: PlaybackStatsDailyBucket(
            dayStart: day1, trackId: trackId, totalListenSeconds: 60, playCount: 2
        ))
        try repository.upsert(bucket: PlaybackStatsDailyBucket(
            dayStart: day2, trackId: trackId, totalListenSeconds: 30, playCount: 1
        ))
        try repository.upsert(bucket: PlaybackStatsDailyBucket(
            dayStart: day1, trackId: otherId, totalListenSeconds: 10, playCount: 1
        ))

        // 按曲目取时间序列（升序）。
        let buckets = try repository.buckets(trackId: trackId)
        XCTAssertEqual(buckets.map(\.dayStart), [day1, day2])
        XCTAssertEqual(buckets.map(\.totalListenSeconds), [60, 30])

        // 点查某天。
        XCTAssertEqual(try repository.bucket(trackId: trackId, dayStart: day2)?.playCount, 1)
        XCTAssertNil(try repository.bucket(trackId: trackId, dayStart: Date(timeIntervalSince1970: 999)))
        XCTAssertEqual(try repository.bucketCount(), 3)
    }

    func testDailyBucketUpsertIsPerDayPerTrack() throws {
        let provider = try makeProvider()
        let repository = PlaybackStatsRepository(provider)
        let trackId = try insertTrack("bucket-idem", into: provider)
        let day = Date(timeIntervalSince1970: 86_400)

        try repository.upsert(bucket: PlaybackStatsDailyBucket(
            dayStart: day, trackId: trackId, totalListenSeconds: 10, playCount: 1
        ))
        // 同一天同一首再写：覆盖而不是新增（复合主键生效）。
        try repository.upsert(bucket: PlaybackStatsDailyBucket(
            dayStart: day, trackId: trackId, totalListenSeconds: 99, playCount: 3
        ))
        XCTAssertEqual(try repository.bucketCount(), 1)
        XCTAssertEqual(try repository.bucket(trackId: trackId, dayStart: day)?.totalListenSeconds, 99)
    }

    func testDailyBucketRangeQuery() throws {
        let provider = try makeProvider()
        let repository = PlaybackStatsRepository(provider)
        let trackId = try insertTrack("bucket-range", into: provider)
        let days = (1...5).map { Date(timeIntervalSince1970: Double($0) * 86_400) }
        for (offset, day) in days.enumerated() {
            try repository.upsert(bucket: PlaybackStatsDailyBucket(
                dayStart: day, trackId: trackId, totalListenSeconds: Double(offset), playCount: 1
            ))
        }
        // 区间 [day2, day4)：含起点、不含终点。
        let range = try repository.buckets(from: days[1], to: days[3])
        XCTAssertEqual(range.map(\.dayStart), [days[1], days[2]])
    }

    func testDailyBucketDeleteOne() throws {
        let provider = try makeProvider()
        let repository = PlaybackStatsRepository(provider)
        let trackId = try insertTrack("bucket-del", into: provider)
        let day = Date(timeIntervalSince1970: 86_400)
        try repository.upsert(bucket: PlaybackStatsDailyBucket(dayStart: day, trackId: trackId))

        try repository.deleteBucket(trackId: trackId, dayStart: day)
        XCTAssertNil(try repository.bucket(trackId: trackId, dayStart: day))
        XCTAssertEqual(try repository.bucketCount(), 0)
    }

    func testDayStartUsesProvidedCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        // 2026-09-27 09:30(+08) 的当天零点是 2026-09-27 00:00(+08)。
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 27
        components.hour = 9; components.minute = 30
        components.timeZone = calendar.timeZone
        let morning = try XCTUnwrap(calendar.date(from: components))
        let start = PlaybackStatsDailyBucket.dayStart(for: morning, calendar: calendar)

        let startComponents = calendar.dateComponents([.year, .month, .day, .hour], from: start)
        XCTAssertEqual(startComponents.year, 2026)
        XCTAssertEqual(startComponents.month, 9)
        XCTAssertEqual(startComponents.day, 27)
        XCTAssertEqual(startComponents.hour, 0)
    }

    // MARK: - 播放器现场

    func testPlayerStateSaveAndLoadRoundTrip() throws {
        let provider = try makeProvider()
        let repository = PlayerStateRepository(provider)

        let tracks = [
            makeQueueTrack("queue-1", artist: "艺人一", duration: 180),
            makeQueueTrack("queue-2", artist: nil, duration: nil),
            makeQueueTrack("queue-3", artist: "艺人三", duration: 240.5)
        ]
        let state = PlayerState(
            tracks: tracks,
            currentIndex: 1,
            position: 88.25,
            mode: .shuffle,
            shuffleOrder: tracks.map(\.id),
            updatedAt: Date(timeIntervalSince1970: 12_345)
        )
        try repository.save(state)

        let loaded = try repository.load()
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded?.queueState.currentTrack?.id, tracks[1].id)
        XCTAssertEqual(loaded?.mode, .shuffle)
        XCTAssertEqual(loaded?.shuffleOrder, tracks.map(\.id))
    }

    func testPlayerStateSaveOverwritesSingleRow() throws {
        let provider = try makeProvider()
        let repository = PlayerStateRepository(provider)

        try repository.save(PlayerState(
            tracks: [makeQueueTrack("first")], currentIndex: 0, position: 1,
            mode: .sequential, updatedAt: Date(timeIntervalSince1970: 1)
        ))
        try repository.save(PlayerState(
            tracks: [makeQueueTrack("second"), makeQueueTrack("third")], currentIndex: 1, position: 2,
            mode: .repeatAll, updatedAt: Date(timeIntervalSince1970: 2)
        ))

        XCTAssertEqual(try rowCount(DatabaseSchema.playerState, in: provider), 1)
        let loaded = try repository.load()
        XCTAssertEqual(loaded?.tracks.map(\.title), ["second", "third"])
        XCTAssertEqual(loaded?.currentIndex, 1)
        XCTAssertEqual(loaded?.mode, .repeatAll)
    }

    func testPlayerStateLoadEmptyAndClear() throws {
        let provider = try makeProvider()
        let repository = PlayerStateRepository(provider)

        // 从未保存过：nil。
        XCTAssertNil(try repository.load())

        try repository.save(PlayerState(
            tracks: [makeQueueTrack("clear-me")], currentIndex: 0, position: 3,
            mode: .sequential, updatedAt: Date(timeIntervalSince1970: 9)
        ))
        try repository.clear()
        XCTAssertNil(try repository.load())
        XCTAssertEqual(try rowCount(DatabaseSchema.playerState, in: provider), 0)
    }

    func testPlayerStateEmptyQueueHasNilIndex() throws {
        let provider = try makeProvider()
        let repository = PlayerStateRepository(provider)
        try repository.save(PlayerState(
            tracks: [], currentIndex: nil, position: 0,
            mode: .repeatOne, updatedAt: Date(timeIntervalSince1970: 3)
        ))
        let loaded = try repository.load()
        XCTAssertEqual(loaded?.tracks, [])
        XCTAssertNil(loaded?.currentIndex)
        XCTAssertEqual(loaded?.currentTrack, nil)
        XCTAssertEqual(loaded?.mode, .repeatOne)
    }

    func testPlayerStateToleratesCorruptQueueJSON() throws {
        let provider = try makeProvider()
        let repository = PlayerStateRepository(provider)
        // 直接写一行坏 JSON：读取应退化为空队列而不是抛错。
        try provider.dbQueue.write { db in
            try PlayerStateRecord(
                currentIndex: 0,
                position: 5,
                mode: PlaybackMode.repeatAll.rawValue,
                queue: "not-json",
                shuffleOrder: "{{{",
                updatedAt: Date(timeIntervalSince1970: 4)
            ).insert(db)
        }
        let loaded = try repository.load()
        XCTAssertEqual(loaded?.tracks, [])
        XCTAssertEqual(loaded?.shuffleOrder, [])
        XCTAssertEqual(loaded?.mode, .repeatAll)
        XCTAssertEqual(loaded?.position, 5)
    }

    func testPlayerStateUnknownModeFallsBackToSequential() throws {
        let provider = try makeProvider()
        let repository = PlayerStateRepository(provider)
        try provider.dbQueue.write { db in
            try PlayerStateRecord(
                currentIndex: nil,
                position: 0,
                mode: "no-such-mode",
                queue: "[]",
                shuffleOrder: "[]",
                updatedAt: Date(timeIntervalSince1970: 6)
            ).insert(db)
        }
        XCTAssertEqual(try repository.load()?.mode, .sequential)
    }

    // MARK: - 外键级联

    func testDeletingTrackCascadesPlaybackRows() throws {
        let provider = try makeProvider()
        let doomed = try insertTrack("cascade-doomed", into: provider)
        let kept = try insertTrack("cascade-kept", into: provider)

        let history = PlayHistoryRepository(provider)
        let stats = PlaybackStatsRepository(provider)
        try history.record(trackId: doomed)
        try history.record(trackId: kept)
        try stats.upsert(PlaybackStats(trackId: doomed, totalListenSeconds: 60, playCount: 1))
        try stats.upsert(bucket: PlaybackStatsDailyBucket(
            dayStart: Date(timeIntervalSince1970: 0), trackId: doomed, totalListenSeconds: 60, playCount: 1
        ))

        try LibraryRepository(provider).deleteTrack(id: doomed)

        XCTAssertNil(try history.entry(trackId: doomed))
        XCTAssertNotNil(try history.entry(trackId: kept))
        XCTAssertNil(try stats.stats(trackId: doomed))
        XCTAssertEqual(try stats.bucketCount(), 0)
    }

    func testReplaceLibraryCascadesPlaybackRows() throws {
        let provider = try makeProvider()
        let kept = Track(url: URL(fileURLWithPath: "/tmp/NeriPlayer/replace-kept.mp3"), title: "kept")
        let dropped = Track(url: URL(fileURLWithPath: "/tmp/NeriPlayer/replace-dropped.mp3"), title: "dropped")
        try LibraryRepository(provider).upsertTracks([kept, dropped])

        try PlayHistoryRepository(provider).record(trackId: dropped.id)
        try PlaybackStatsRepository(provider).upsert(
            PlaybackStats(trackId: dropped.id, totalListenSeconds: 5, playCount: 1)
        )

        try LibraryRepository(provider).replaceLibrary([kept])

        XCTAssertEqual(try rowCount(DatabaseSchema.playHistory, in: provider), 0)
        XCTAssertEqual(try rowCount(DatabaseSchema.playbackStats, in: provider), 0)
    }

    func testPlayerStateSurvivesTrackDeletion() throws {
        // 现场表与 Track 无外键：删除曲目不该影响已保存的现场（队列里可能含未入库项）。
        let provider = try makeProvider()
        let trackId = try insertTrack("state-track", into: provider)
        let queueTrack = makeQueueTrack("state-queue")
        try PlayerStateRepository(provider).save(PlayerState(
            tracks: [queueTrack], currentIndex: 0, position: 7,
            mode: .sequential, updatedAt: Date(timeIntervalSince1970: 8)
        ))

        try LibraryRepository(provider).deleteTrack(id: trackId)
        XCTAssertEqual(try PlayerStateRepository(provider).load()?.position, 7)
    }

    // MARK: - 索引

    func testV2IndexesExist() throws {
        let provider = try makeProvider()
        let indexes = try provider.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        XCTAssertTrue(indexes.contains("index_PlayHistory_playedAt"))
        XCTAssertTrue(indexes.contains("index_PlaybackStats_lastPlayedAt"))
        XCTAssertTrue(indexes.contains("index_PlaybackStatsDailyBucket_trackId_dayStart"))
    }
}
