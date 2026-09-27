// FavoriteRepositoryTests.swift
// NeriPlayer macOS —— M2-T7：收藏仓库测试。
//
// 全部用例在临时目录建库（`DatabaseProvider(url:)` 注入），跑完即删，不碰真实 Application Support。
// 覆盖点（与任务书一一对应）：
//   - 收藏 / 取消收藏 / 幂等（重复收藏保持原 favoritedAt，重复取消不报错）；
//   - favorites() 按 favoritedAt 倒序；
//   - 级联删除：删曲目 / 整库替换会连带清掉收藏行；
//   - 收藏不存在曲目抛可归因错误（而非让外键约束报 DatabaseError）。

import XCTest
import GRDB
@testable import NeriPlayer

final class FavoriteRepositoryTests: XCTestCase {

    private var temporaryDirectories: [URL] = []
    private var provider: DatabaseProvider!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NeriPlayerFavoriteTests-\(UUID().uuidString)", isDirectory: true)
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

    /// 落一条曲目，返回其 id。
    @discardableResult
    private func insertTrack(_ name: String) throws -> UUID {
        let track = Track(url: URL(fileURLWithPath: "/tmp/NeriPlayer/\(name).mp3"))
        try LibraryRepository(provider).upsertTracks([track])
        return track.id
    }

    /// 直接写一行带指定 favoritedAt 的收藏，用于精确断言排序。
    private func insertFavorite(trackId: UUID, at date: Date) throws {
        try provider.dbQueue.write { db in
            try FavoriteRecord(trackId: trackId, favoritedAt: date).insert(db)
        }
    }

    // MARK: - 收藏 / 取消 / 幂等

    func testFavoriteThenIsFavoritedThenUnfavorite() throws {
        let repository = FavoriteRepository(provider)
        let trackId = try insertTrack("a")

        XCTAssertFalse(try repository.isFavorited(trackId: trackId))
        XCTAssertTrue(try repository.favorite(trackId: trackId), "首次收藏应真的新增")
        XCTAssertTrue(try repository.isFavorited(trackId: trackId))
        XCTAssertEqual(try repository.favorites().map(\.id), [trackId])

        try repository.unfavorite(trackId: trackId)
        XCTAssertFalse(try repository.isFavorited(trackId: trackId))
        XCTAssertTrue(try repository.favorites().isEmpty)
    }

    /// 重复收藏是幂等空操作：返回 false，且不改写原 favoritedAt（收藏列表顺序不因重复点击漂移）。
    func testFavoriteIsIdempotentAndPreservesOriginalTimestamp() throws {
        let repository = FavoriteRepository(provider)
        let trackId = try insertTrack("a")
        let first = Date(timeIntervalSince1970: 1_000)
        try insertFavorite(trackId: trackId, at: first)

        XCTAssertFalse(try repository.favorite(trackId: trackId), "已收藏时不新增")
        XCTAssertEqual(try repository.favorites().count, 1)

        let stored = try provider.dbQueue.read { db in
            try FavoriteRecord.fetchOne(db, key: trackId)?.favoritedAt
        }
        // Date 落库按毫秒精度存取，比较时留一点容差。
        XCTAssertEqual(try XCTUnwrap(stored).timeIntervalSince1970, first.timeIntervalSince1970, accuracy: 0.01)
    }

    /// 取消未收藏的曲目静默成功（删 0 行不是错误），连续两次也不抛错。
    func testUnfavoriteIsIdempotentForUnknownTrack() throws {
        let repository = FavoriteRepository(provider)
        let trackId = try insertTrack("a")

        XCTAssertNoThrow(try repository.unfavorite(trackId: trackId))
        XCTAssertNoThrow(try repository.unfavorite(trackId: trackId))
        XCTAssertFalse(try repository.isFavorited(trackId: trackId))
    }

    /// 收藏不存在的曲目抛 trackNotFound，而不是把外键约束错误漏给调用方。
    func testFavoriteUnknownTrackThrows() throws {
        let repository = FavoriteRepository(provider)
        let ghost = UUID()

        XCTAssertThrowsError(try repository.favorite(trackId: ghost)) { error in
            XCTAssertEqual(error as? RepositoryError, .trackNotFound(ghost))
        }
    }

    /// toggle 是星标按钮的唯一入口：一次调用翻转状态并返回结果状态。
    func testToggleFlipsState() throws {
        let repository = FavoriteRepository(provider)
        let trackId = try insertTrack("a")

        XCTAssertTrue(try repository.toggle(trackId: trackId))
        XCTAssertTrue(try repository.isFavorited(trackId: trackId))
        XCTAssertFalse(try repository.toggle(trackId: trackId))
        XCTAssertFalse(try repository.isFavorited(trackId: trackId))
    }

    // MARK: - 排序

    /// favorites() 按 favoritedAt 倒序：最近收藏在前，与插入顺序无关。
    func testFavoritesOrderedByFavoritedAtDescending() throws {
        let repository = FavoriteRepository(provider)
        let oldest = try insertTrack("oldest")
        let middle = try insertTrack("middle")
        let newest = try insertTrack("newest")
        let base = Date(timeIntervalSince1970: 10_000)
        try insertFavorite(trackId: middle, at: base.addingTimeInterval(10))
        try insertFavorite(trackId: oldest, at: base)
        try insertFavorite(trackId: newest, at: base.addingTimeInterval(20))

        XCTAssertEqual(try repository.favorites().map(\.id), [newest, middle, oldest])
        XCTAssertEqual(try repository.favoritedTrackIds(), Set([oldest, middle, newest]))
    }

    // MARK: - 级联删除

    /// 删曲目：收藏行经外键级联清掉。
    func testDeletingTrackCascadesFavorite() throws {
        let repository = FavoriteRepository(provider)
        let doomed = try insertTrack("doomed")
        let survivor = try insertTrack("survivor")
        try repository.favorite(trackId: doomed)
        try repository.favorite(trackId: survivor)

        try LibraryRepository(provider).deleteTrack(id: doomed)

        XCTAssertEqual(try repository.favorites().map(\.id), [survivor])
        XCTAssertFalse(try repository.isFavorited(trackId: doomed))
    }

    /// 整库替换：清单外的曲目被删，其收藏一并级联清掉。
    func testReplaceLibraryCascadesFavorites() throws {
        let repository = FavoriteRepository(provider)
        let kept = Track(url: URL(fileURLWithPath: "/tmp/NeriPlayer/kept.mp3"))
        let dropped = Track(url: URL(fileURLWithPath: "/tmp/NeriPlayer/dropped.mp3"))
        try LibraryRepository(provider).upsertTracks([kept, dropped])
        try repository.favorite(trackId: kept.id)
        try repository.favorite(trackId: dropped.id)

        try LibraryRepository(provider).replaceLibrary([kept])

        XCTAssertEqual(try repository.favorites().map(\.id), [kept.id])
    }
}
