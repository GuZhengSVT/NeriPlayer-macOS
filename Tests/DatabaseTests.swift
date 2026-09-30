// DatabaseTests.swift
// M2-T3 数据库层测试：迁移幂等、Track upsert 去重、歌单 CRUD 与重排、外键级联删除。
//
// 全部用例在临时目录建库（`DatabaseProvider(path:)` 注入），跑完即删，不碰真实
// Application Support 目录，也不留下任何 .sqlite 文件。
//
// 为什么幂等测试要新建第二个 provider 而不是复用同一个实例：复用同一个实例只能证明
// 「没有未应用迁移时 migrate 不报错」；同一路径新建实例才会重新走一遍「读 grdb_migrations
// 表 → 发现 v1 已应用 → 跳过」的完整判定路径，才真正覆盖应用重启后再次启动的场景。

import XCTest
import GRDB
@testable import NeriPlayer

final class DatabaseTests: XCTestCase {

    /// 本用例创建的临时目录，tearDown 统一清理。
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    // MARK: - 测试夹具

    /// 在临时目录建一个已迁移完成的库。
    private func makeProvider() throws -> DatabaseProvider {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NeriPlayerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let provider = try DatabaseProvider(url: directory.appendingPathComponent("library.sqlite"))
        try provider.setupIfNeeded()
        return provider
    }

    /// 造一个本地文件 URL 的曲目。
    private func makeTrack(_ name: String, artist: String? = nil, duration: Double? = 180) -> Track {
        Track(url: URL(fileURLWithPath: "/tmp/NeriPlayer/\(name).mp3"), artist: artist, duration: duration)
    }

    /// 直接查某歌单各 entry 的 position（升序）。
    private func positions(in provider: DatabaseProvider, playlistId: UUID) throws -> [Int] {
        try provider.dbQueue.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT position FROM PlaylistEntry WHERE playlistId = ? ORDER BY position",
                arguments: [playlistId]
            )
        }
    }

    /// 建一个可被歌单引用的曲目，返回其 id。
    private func insertTrack(_ name: String, into provider: DatabaseProvider) throws -> UUID {
        let track = makeTrack(name)
        try LibraryRepository(provider).upsertTracks([track])
        return track.id
    }

    // MARK: - 迁移

    func testSetupCreatesFourTables() throws {
        let provider = try makeProvider()
        let tables = try provider.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        XCTAssertTrue(tables.contains(DatabaseSchema.track))
        XCTAssertTrue(tables.contains(DatabaseSchema.playlist))
        XCTAssertTrue(tables.contains(DatabaseSchema.playlistEntry))
        XCTAssertTrue(tables.contains(DatabaseSchema.favorite))
    }

    func testMigrationTwiceOnSameProviderIsIdempotent() throws {
        let provider = try makeProvider()
        // 第二次调用：登记表里的迁移均已应用，应空转且不抛错。
        XCTAssertNoThrow(try provider.setupIfNeeded())
        XCTAssertNoThrow(try provider.setupIfNeeded())

        let applied = try provider.dbQueue.read { db in
            try provider.migrator.appliedIdentifiers(db)
        }
        // 断言「全部登记项都已应用」。appliedIdentifiers 的返回顺序不承诺稳定，
        // 因此比集合而不是数组；新增迁移时这里会失败，正好提醒把新版本号补进来。
        XCTAssertEqual(Set(applied), ["v1", "v2", "v3", "v4"])
    }

    func testMigrationTwiceAcrossProvidersIsIdempotent() throws {
        let first = try makeProvider()
        // 同一路径、新实例：重新登记迁移后应发现 v1 已应用并跳过建表。
        let second = try DatabaseProvider(url: first.databaseURL)
        XCTAssertNoThrow(try second.setupIfNeeded())

        // 数据仍在（证明第二次没有重建表）。
        let track = makeTrack("keep-me")
        try LibraryRepository(first).upsertTracks([track])
        let third = try DatabaseProvider(url: first.databaseURL)
        try third.setupIfNeeded()
        XCTAssertEqual(try LibraryRepository(third).allTracks().count, 1)
    }

    func testForeignKeysAreEnabled() throws {
        let provider = try makeProvider()
        let enabled = try provider.dbQueue.read { db in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") ?? false
        }
        XCTAssertTrue(enabled)
    }

    // MARK: - Track upsert

    func testUpsertTracksInsertsOnceForSameURL() throws {
        let provider = try makeProvider()
        let repository = LibraryRepository(provider)

        let first = makeTrack("same-song", artist: "A")
        try repository.upsertTracks([first])
        XCTAssertEqual(try repository.allTracks().count, 1)

        // 同 url、不同 id/标题：应命中 UNIQUE(url) 覆盖而非新增一行。
        let second = Track(
            url: first.url,
            title: "renamed",
            artist: "B",
            duration: 240
        )
        try repository.upsertTracks([second])

        let tracks = try repository.allTracks()
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.title, "renamed")
        XCTAssertEqual(tracks.first?.artist, "B")
        // 主键列不参与覆盖：原行的 id 保留，队列里持有的 id 不会因重扫描失效。
        XCTAssertEqual(tracks.first?.id, first.id)
    }

    func testTrackByUrlFindsNormalizedURL() throws {
        let provider = try makeProvider()
        let repository = LibraryRepository(provider)
        let track = makeTrack("lookup", artist: "C")
        try repository.upsertTracks([track])

        let found = try repository.trackByUrl(track.url)
        XCTAssertEqual(found?.id, track.id)
        XCTAssertEqual(found?.title, "lookup")
        XCTAssertNil(try repository.trackByUrl(URL(fileURLWithPath: "/tmp/NeriPlayer/missing.mp3")))
    }

    func testReplaceLibraryRemovesTracksMissingFromList() throws {
        let provider = try makeProvider()
        let repository = LibraryRepository(provider)
        let kept = makeTrack("kept")
        let dropped = makeTrack("dropped")
        try repository.upsertTracks([kept, dropped])

        let deleted = try repository.replaceLibrary([kept])
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(try repository.allTracks().map(\.title), ["kept"])
    }

    // MARK: - 歌单 CRUD

    func testPlaylistCreateRenameListDelete() throws {
        let provider = try makeProvider()
        let repository = PlaylistRepository(provider)

        let created = try repository.create(name: "通勤")
        XCTAssertEqual(created.name, "通勤")
        XCTAssertEqual(created.createdAt, created.updatedAt)

        try repository.rename(id: created.id, to: "通勤歌单")
        let listed = try repository.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.name, "通勤歌单")
        XCTAssertEqual(listed.first?.id, created.id)

        try repository.delete(id: created.id)
        XCTAssertTrue(try repository.list().isEmpty)
        XCTAssertThrowsError(try repository.delete(id: created.id)) { error in
            XCTAssertEqual(error as? RepositoryError, .playlistNotFound(created.id))
        }
    }

    func testAddTrackIsDeduplicatedPerPlaylist() throws {
        let provider = try makeProvider()
        let repository = PlaylistRepository(provider)
        let playlist = try repository.create(name: "p")
        let trackId = try insertTrack("a", into: provider)

        XCTAssertEqual(try repository.addTrack(playlistId: playlist.id, trackId: trackId), 0)
        // 重复加入返回既有位置，不新增行。
        XCTAssertEqual(try repository.addTrack(playlistId: playlist.id, trackId: trackId), 0)
        XCTAssertEqual(try repository.entries(playlistId: playlist.id).count, 1)
    }

    func testAddTrackRejectsUnknownTrack() throws {
        let provider = try makeProvider()
        let repository = PlaylistRepository(provider)
        let playlist = try repository.create(name: "p")
        let ghost = UUID()

        XCTAssertThrowsError(try repository.addTrack(playlistId: playlist.id, trackId: ghost)) { error in
            XCTAssertEqual(error as? RepositoryError, .trackNotFound(ghost))
        }
    }

    func testRemoveTrackCompactsPositions() throws {
        let provider = try makeProvider()
        let repository = PlaylistRepository(provider)
        let playlist = try repository.create(name: "p")
        let ids = try ["a", "b", "c"].map { title -> UUID in
            let track = makeTrack(title)
            _ = try LibraryRepository(provider).upsertTracks([track])
            return track.id
        }
        for id in ids {
            try repository.addTrack(playlistId: playlist.id, trackId: id)
        }
        XCTAssertEqual(try positions(in: provider, playlistId: playlist.id), [0, 1, 2])

        try repository.removeTrack(playlistId: playlist.id, trackId: ids[0])
        XCTAssertEqual(try positions(in: provider, playlistId: playlist.id), [0, 1])
        XCTAssertEqual(
            try repository.entries(playlistId: playlist.id).map(\.title),
            ["b", "c"]
        )
    }

    // MARK: - 重排

    func testReorderProducesContiguousPositions() throws {
        let provider = try makeProvider()
        let repository = PlaylistRepository(provider)
        let playlist = try repository.create(name: "p")

        var ids: [UUID] = []
        for title in ["a", "b", "c", "d"] {
            let track = makeTrack(title)
            try LibraryRepository(provider).upsertTracks([track])
            ids.append(track.id)
            try repository.addTrack(playlistId: playlist.id, trackId: track.id)
        }

        // 把最后一首拖到最前，其余保持原相对顺序接在其后。
        try repository.reorder(playlistId: playlist.id, trackIds: [ids[3]])

        XCTAssertEqual(
            try repository.entries(playlistId: playlist.id).map(\.title),
            ["d", "a", "b", "c"]
        )
        // 落库位置恒为 0..n-1 连续无空洞。
        XCTAssertEqual(try positions(in: provider, playlistId: playlist.id), [0, 1, 2, 3])

        // 全量反转，仍保持连续。
        try repository.reorder(playlistId: playlist.id, trackIds: [ids[1], ids[3], ids[0], ids[2]])
        XCTAssertEqual(
            try repository.entries(playlistId: playlist.id).map(\.title),
            ["b", "d", "a", "c"]
        )
        XCTAssertEqual(try positions(in: provider, playlistId: playlist.id), [0, 1, 2, 3])
    }

    func testReorderIgnoresForeignTrackIds() throws {
        let provider = try makeProvider()
        let repository = PlaylistRepository(provider)
        let playlist = try repository.create(name: "p")
        let first = try insertTrack("a", into: provider)
        let second = try insertTrack("b", into: provider)
        try repository.addTrack(playlistId: playlist.id, trackId: first)
        try repository.addTrack(playlistId: playlist.id, trackId: second)

        // 不属于本歌单的 id 被忽略，已存在的两首保持传入的相对顺序。
        try repository.reorder(playlistId: playlist.id, trackIds: [second, UUID()])
        XCTAssertEqual(
            try repository.entries(playlistId: playlist.id).map(\.title),
            ["b", "a"]
        )
        XCTAssertEqual(try positions(in: provider, playlistId: playlist.id), [0, 1])
    }

    // MARK: - 级联删除

    func testDeletingPlaylistCascadesEntriesButKeepsTracks() throws {
        let provider = try makeProvider()
        let playlists = PlaylistRepository(provider)
        let library = LibraryRepository(provider)
        let playlist = try playlists.create(name: "p")
        let trackId = try insertTrack("a", into: provider)
        try playlists.addTrack(playlistId: playlist.id, trackId: trackId)
        XCTAssertEqual(try playlists.entries(playlistId: playlist.id).count, 1)

        try playlists.delete(id: playlist.id)

        let remainingEntries = try provider.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM PlaylistEntry") ?? -1
        }
        XCTAssertEqual(remainingEntries, 0)
        // 曲目本身不受影响。
        XCTAssertEqual(try library.allTracks().count, 1)
    }

    func testDeletingTrackCascadesFavoriteAndPlaylistEntry() throws {
        let provider = try makeProvider()
        let playlists = PlaylistRepository(provider)
        let playlist = try playlists.create(name: "p")
        let trackId = try insertTrack("a", into: provider)
        let otherId = try insertTrack("b", into: provider)
        try playlists.addTrack(playlistId: playlist.id, trackId: trackId)
        try playlists.addTrack(playlistId: playlist.id, trackId: otherId)
        try provider.dbQueue.write { db in
            try FavoriteRecord(trackId: trackId).insert(db)
            try FavoriteRecord(trackId: otherId).insert(db)
        }

        try LibraryRepository(provider).deleteTrack(id: trackId)

        let counts = try provider.dbQueue.read { db in
            (
                favorites: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM Favorite") ?? -1,
                entries: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM PlaylistEntry") ?? -1,
                tracks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM Track") ?? -1
            )
        }
        XCTAssertEqual(counts.favorites, 1)
        XCTAssertEqual(counts.entries, 1)
        XCTAssertEqual(counts.tracks, 1)
        // 级联后歌单位置重新压实为 0。
        XCTAssertEqual(try positions(in: provider, playlistId: playlist.id), [0])
    }

    func testReplaceLibraryCascadesRemovedTracks() throws {
        let provider = try makeProvider()
        let playlists = PlaylistRepository(provider)
        let library = LibraryRepository(provider)
        let playlist = try playlists.create(name: "p")
        let kept = makeTrack("kept")
        let dropped = makeTrack("dropped")
        try library.upsertTracks([kept, dropped])
        try playlists.addTrack(playlistId: playlist.id, trackId: dropped.id)

        try library.replaceLibrary([kept])

        XCTAssertEqual(try playlists.entries(playlistId: playlist.id).count, 0)
        XCTAssertEqual(try library.allTracks().map(\.title), ["kept"])
    }
}
