// LibraryRepositoryTests.swift
// NeriPlayer macOS —— M2-T4：媒体库排序与去重（LibraryRepository 扩展）测试。
//
// 全部用例在临时目录建库（`DatabaseProvider(url:)` 注入），跑完即删。
// 覆盖点：
//   - 排序：title / artist 两种键的正反序断言；
//   - 去重：同标题同歌手时长相近但 url 不同的两条 -> dedupe 后剩 1 条；
//   - 去重保留策略：newestCreated 与 largestFile 各断言一次；
//   - 时长差超过阈值不判重、标题归一化（大小写/全半角）判重；
//   - 去重会清理被删曲目的 PlaylistEntry 引用并压实位置。

import XCTest
import GRDB
@testable import NeriPlayer

final class LibraryRepositoryTests: XCTestCase {

    private var temporaryDirectories: [URL] = []
    private var provider: DatabaseProvider!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NeriPlayerLibraryRepoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        provider = try DatabaseProvider(url: directory.appendingPathComponent("library.sqlite"))
        try provider.setupIfNeeded()
    }

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        provider = nil
        try super.tearDownWithError()
    }

    // MARK: - 夹具

    /// 直接落一条带库字段的行，用于精确控制 createdAt / fileSize / duration。
    @discardableResult
    private func insert(
        url: String,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: Double? = nil,
        fileSize: Double = 0,
        createdAt: Date = Date()
    ) throws -> UUID {
        let record = TrackRecord(
            track: Track(url: URL(fileURLWithPath: url), title: title, artist: artist, duration: duration),
            album: album,
            fileSize: fileSize,
            createdAt: createdAt
        )
        try provider.dbQueue.write { db in try record.insert(db) }
        return record.id
    }

    // MARK: - 排序

    /// title 升/降序，中英混排按 localizedStandardCompare。
    func testAllTracksSortedByTitle() throws {
        try insert(url: "/m/b.mp3", title: "banana")
        try insert(url: "/m/a.mp3", title: "Apple")
        try insert(url: "/m/c.mp3", title: "cherry")

        let repository = LibraryRepository(provider)
        XCTAssertEqual(
            try repository.allTracksSorted(by: .title).map(\.title),
            ["Apple", "banana", "cherry"],
            "升序应大小写不敏感"
        )
        XCTAssertEqual(
            try repository.allTracksSorted(by: .title, ascending: false).map(\.title),
            ["cherry", "banana", "Apple"]
        )
    }

    /// artist 排序：空歌手排在末尾（不因 NULL 抢占列表首行）。
    func testAllTracksSortedByArtistPlacesMissingLast() throws {
        try insert(url: "/m/1.mp3", title: "one", artist: "Zoe")
        try insert(url: "/m/2.mp3", title: "two", artist: "Alice")
        try insert(url: "/m/3.mp3", title: "three", artist: nil)

        let repository = LibraryRepository(provider)
        XCTAssertEqual(
            try repository.allTracksSorted(by: .artist).map(\.artist),
            ["Alice", "Zoe", nil],
            "升序时 null artist 应排在末尾"
        )
    }

    /// 排序结果携带库字段（专辑/体积/格式/封面），而非只回播放子集。
    func testSortedTracksCarryLibraryFields() throws {
        try insert(url: "/m/1.mp3", title: "one", artist: "A", album: "Album X", duration: 200, fileSize: 4096)
        let track = try XCTUnwrap(try LibraryRepository(provider).allTracksSorted(by: .title).first)
        XCTAssertEqual(track.album, "Album X")
        XCTAssertEqual(track.fileSize, 4096)
        XCTAssertEqual(track.duration, 200)
    }

    // MARK: - 去重

    /// 同标题同歌手时长相近但 url 不同 -> dedupe 后剩 1 条。
    func testDedupeKeepsSingleCopyOfNearDuplicates() throws {
        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        let originalId = try insert(
            url: "/m/original.mp3", title: "Kiseki", artist: "Alice", duration: 240.0, fileSize: 1024, createdAt: older
        )
        let copyId = try insert(
            url: "/m/copy.mp3", title: "Kiseki", artist: "Alice", duration: 242.0, fileSize: 1024, createdAt: newer
        )

        let repository = LibraryRepository(provider)
        let result = try repository.dedupe()

        XCTAssertEqual(result.duplicateGroups, 1)
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(result.removedTrackIds, [originalId], "默认保留 createdAt 最新者")
        XCTAssertEqual(try repository.allTracks().count, 1)
        XCTAssertEqual(try repository.allTracks().first?.id, copyId)
    }

    /// 默认策略保留 createdAt 最新的那条。
    func testDedupeNewestCreatedKeepsLatest() throws {
        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        let oldId = try insert(url: "/m/old.mp3", title: "Song", artist: "A", duration: 100, createdAt: older)
        let newId = try insert(url: "/m/new.mp3", title: "Song", artist: "A", duration: 101, createdAt: newer)

        _ = try LibraryRepository(provider).dedupe(strategy: .newestCreated)

        let remaining = try LibraryRepository(provider).allTracks()
        XCTAssertEqual(remaining.map(\.id), [newId], "应保留 updatedAt/createdAt 最新者")
        XCTAssertFalse(remaining.contains { $0.id == oldId })
    }

    /// largestFile 策略保留体积最大的那条。
    func testDedupeLargestFileKeepsBiggest() throws {
        let smallId = try insert(url: "/m/small.mp3", title: "Song", artist: "A", duration: 100, fileSize: 1024)
        let bigId = try insert(url: "/m/big.flac", title: "Song", artist: "A", duration: 100, fileSize: 10_485_760)

        _ = try LibraryRepository(provider).dedupe(strategy: .largestFile)

        let remaining = try LibraryRepository(provider).allTracks()
        XCTAssertEqual(remaining.map(\.id), [bigId])
        XCTAssertFalse(remaining.contains { $0.id == smallId })
    }

    /// 时长差超过 3 秒不判重（同名不同版本应共存）。
    func testDedupeIgnoresDurationMismatch() throws {
        try insert(url: "/m/radio.mp3", title: "Song", artist: "A", duration: 180)
        try insert(url: "/m/extended.mp3", title: "Song", artist: "A", duration: 420)

        let result = try LibraryRepository(provider).dedupe()

        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(try LibraryRepository(provider).allTracks().count, 2)
    }

    /// 标题/歌手归一化：大小写与全半角差异仍判为同一首。
    func testDedupeNormalizesCaseAndWidth() throws {
        try insert(url: "/m/a.mp3", title: "KISEKI", artist: "Alice", duration: 200)
        try insert(url: "/m/b.mp3", title: "kiseki", artist: "ALICE", duration: 201)

        XCTAssertEqual(try LibraryRepository(provider).dedupe().removedCount, 1)
    }

    /// 不同歌手不判重。
    func testDedupeKeepsDifferentArtists() throws {
        try insert(url: "/m/a.mp3", title: "Song", artist: "Alice", duration: 200)
        try insert(url: "/m/b.mp3", title: "Song", artist: "Bob", duration: 200)

        XCTAssertEqual(try LibraryRepository(provider).dedupe().removedCount, 0)
        XCTAssertEqual(try LibraryRepository(provider).allTracks().count, 2)
    }

    /// 去重同时清理被删曲目的 PlaylistEntry 引用并压实位置。
    func testDedupeCleansPlaylistEntriesAndCompactsPositions() throws {
        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        let loserId = try insert(url: "/m/loser.mp3", title: "Song", artist: "A", duration: 200, createdAt: older)
        let winnerId = try insert(url: "/m/winner.mp3", title: "Song", artist: "A", duration: 201, createdAt: newer)
        let otherId = try insert(url: "/m/other.mp3", title: "Other", artist: "B", duration: 200)

        let playlists = PlaylistRepository(provider)
        let playlist = try playlists.create(name: "p")
        try playlists.addTrack(playlistId: playlist.id, trackId: loserId)
        try playlists.addTrack(playlistId: playlist.id, trackId: otherId)
        XCTAssertEqual(try playlists.entries(playlistId: playlist.id).map(\.id), [loserId, otherId])

        let result = try LibraryRepository(provider).dedupe()
        XCTAssertEqual(result.removedTrackIds, [loserId])

        // 被删曲目的条目级联清理，剩余条目位置压实为 0。
        XCTAssertEqual(try playlists.entries(playlistId: playlist.id).map(\.id), [otherId])
        let positions = try provider.dbQueue.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT position FROM PlaylistEntry WHERE playlistId = ? ORDER BY position",
                arguments: [playlist.id]
            )
        }
        XCTAssertEqual(positions, [0])
        XCTAssertNotNil(try LibraryRepository(provider).track(id: winnerId))
    }

    /// 没有重复时 dedupe 是空操作，不删任何行。
    func testDedupeOnCleanLibraryIsNoOp() throws {
        try insert(url: "/m/a.mp3", title: "A", artist: "X", duration: 100)
        try insert(url: "/m/b.mp3", title: "B", artist: "Y", duration: 200)

        let result = try LibraryRepository(provider).dedupe()
        XCTAssertEqual(result.duplicateGroups, 0)
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(try LibraryRepository(provider).allTracks().count, 2)
    }
}
