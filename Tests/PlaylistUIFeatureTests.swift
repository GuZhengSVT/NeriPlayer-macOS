// PlaylistUIFeatureTests.swift
// NeriPlayer macOS —— M2-T7：歌单管理页与「只看收藏」过滤的视图模型测试。
//
// 全部用例在临时目录建库（`DatabaseProvider(url:)` 注入），跑完即删。覆盖点：
//   - PlaylistOrdering.moved 纯函数：拖拽落点与 SwiftUI move(fromOffsets:toOffset:) 语义一致；
//   - 歌单管理：新建 / 重命名 / 删除 / 计数刷新，删当前打开的歌单会退回列表页；
//   - 详情页移除曲目与拖拽排序：落库后 position 恒为 0..n-1 连续，且 entries 顺序与内存一致；
//   - 「只看收藏」过滤：列表、聚合、搜索命中三处一起收敛为收藏曲目，关掉后恢复全量。
//
// 为什么不另测「setQueue(startIndex:)」：整单播放只是把 playAll 的起点从 0 换成被点行下标，
// 队列语义本身由 M1-T4/M1-T5 的 QueueManagerTests / PlaybackStateStoreTests 覆盖，这里不重复。

import XCTest
import GRDB
@testable import NeriPlayer

@MainActor
final class PlaylistUIFeatureTests: XCTestCase {

    private var tempDir: URL!
    private var provider: DatabaseProvider!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeriPlayerPlaylistUITests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        provider = try DatabaseProvider(url: tempDir.appendingPathComponent("library.sqlite"))
        try provider.setupIfNeeded()
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        provider = nil
        try super.tearDownWithError()
    }

    // MARK: - 夹具

    /// 新建歌单返回**实际创建的那个**，且能把曲目原子地加进去。
    ///
    /// 防回归：当前播放栏为在线曲新建歌单时用返回的 id 入库入单；如果实现退化成「用名字回查」，
    /// 在已有同名歌单时会误加到旧歌单。这里通过「已存在同名歌单，再新建一个并加入曲目」断言
    /// 曲目落在**新**歌单上，而不是按名字命中的那一个。
    func testCreatePlaylistReturnsCreatedInstance() throws {
        let track = try insertTrack("Alpha", artist: "Alice")
        let viewModel = LibraryViewModel(database: provider)
        viewModel.load()

        // 先有一个同名歌单：名字回查会命中它。
        let repository = PlaylistRepository(provider)
        let existing = try repository.create(name: "同名")

        let created = try XCTUnwrap(viewModel.createPlaylist(named: "同名", adding: track))
        XCTAssertNotEqual(created.id, existing.id, "应新建一个不同的歌单，而不是复用同名旧歌单")
        XCTAssertEqual(try repository.entries(playlistId: created.id).count, 1, "曲目应落在新歌单里")
        XCTAssertEqual(try repository.entries(playlistId: existing.id).count, 0, "旧同名歌单不应被写入")
    }

    /// 落一条曲目到临时库，返回其对外值类型。
    @discardableResult
    private func insertTrack(_ title: String, artist: String? = nil, album: String? = nil) throws -> LibraryTrack {
        let record = TrackRecord(
            track: Track(
                url: URL(fileURLWithPath: "/music/" + UUID().uuidString + "/" + title + ".mp3"),
                title: title,
                artist: artist,
                duration: 180
            ),
            album: album
        )
        try provider.dbQueue.write { db in try record.insert(db) }
        return record.toLibraryTrack()
    }

    /// 直接查某歌单各 entry 的 position（升序），断言连续性用。
    private func positions(playlistId: UUID) throws -> [Int] {
        try provider.dbQueue.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT position FROM PlaylistEntry WHERE playlistId = ? ORDER BY position",
                arguments: [playlistId]
            )
        }
    }

    /// 建一个已加载完毕、含若干曲目的视图模型。
    private func makeViewModel() -> LibraryViewModel {
        let viewModel = LibraryViewModel(database: provider)
        viewModel.load()
        return viewModel
    }

    // MARK: - 排序纯函数

    /// moved 的落点语义：destination 是搬移前坐标系里的插入点，与 SwiftUI 的 onMove 一致。
    func testPlaylistOrderingMovedMatchesSwiftUISemantics() {
        let items = ["a", "b", "c", "d"]
        // 把最后一个拖到最前。
        XCTAssertEqual(PlaylistOrdering.moved(items, from: IndexSet(integer: 3), to: 0), ["d", "a", "b", "c"])
        // 把第一个拖到「c 之后」：搬移前 c 的下标是 2，插入点是 3。
        XCTAssertEqual(PlaylistOrdering.moved(items, from: IndexSet(integer: 0), to: 3), ["b", "c", "a", "d"])
        // 相邻互换。
        XCTAssertEqual(PlaylistOrdering.moved(items, from: IndexSet(integer: 1), to: 3), ["a", "c", "b", "d"])
        // 拖到末尾（destination == count）。
        XCTAssertEqual(PlaylistOrdering.moved(items, from: IndexSet(integer: 0), to: 4), ["b", "c", "d", "a"])
        // 多选搬移：被搬走的元素保持相对顺序。
        XCTAssertEqual(PlaylistOrdering.moved(items, from: IndexSet([0, 2]), to: 4), ["b", "d", "a", "c"])
    }

    // MARK: - 歌单管理

    /// 新建 / 重命名 / 删除：列表与计数同批刷新，删掉当前打开的歌单会退回列表页。
    func testPlaylistCreateRenameDeleteThroughViewModel() throws {
        let track = try insertTrack("a", artist: "Alice")
        let viewModel = makeViewModel()

        viewModel.createPlaylist(named: "  通勤  ", adding: track)
        let created = try XCTUnwrap(viewModel.playlists.first)
        XCTAssertEqual(created.name, "通勤", "名字应去首尾空白")
        XCTAssertEqual(viewModel.playlistCounts[created.id], 1)
        XCTAssertNil(viewModel.errorMessage)

        viewModel.openPlaylist(created)
        XCTAssertEqual(viewModel.openPlaylist?.id, created.id)
        XCTAssertEqual(viewModel.playlistEntries.map(\.title), ["a"])

        viewModel.renamePlaylist(created, to: "夜间")
        XCTAssertEqual(viewModel.playlists.map(\.name), ["夜间"])
        XCTAssertEqual(viewModel.openPlaylist?.name, "夜间", "打开中的歌单名跟随重命名")

        viewModel.deletePlaylist(try XCTUnwrap(viewModel.playlists.first))
        XCTAssertTrue(viewModel.playlists.isEmpty)
        XCTAssertNil(viewModel.openPlaylistId, "删掉当前打开的歌单应退回列表页")
        XCTAssertTrue(viewModel.playlistEntries.isEmpty)
    }

    /// 重命名成空名被拒绝，原名字与歌单集合不变。
    func testRenameRejectsBlankName() throws {
        let viewModel = makeViewModel()
        viewModel.createPlaylist(named: "原名", adding: nil)
        let playlist = try XCTUnwrap(viewModel.playlists.first)

        viewModel.renamePlaylist(playlist, to: "   ")

        XCTAssertEqual(viewModel.playlists.map(\.name), ["原名"])
        XCTAssertEqual(viewModel.errorMessage, "歌单名不能为空")
    }

    /// 详情页移除曲目后，内存列表与计数同步更新。
    func testRemoveTrackFromOpenPlaylist() throws {
        let first = try insertTrack("a")
        let second = try insertTrack("b")
        let viewModel = makeViewModel()
        viewModel.createPlaylist(named: "p", adding: first)
        viewModel.add(second, to: try XCTUnwrap(viewModel.playlists.first))
        viewModel.openPlaylist(try XCTUnwrap(viewModel.playlists.first))
        XCTAssertEqual(viewModel.playlistEntries.count, 2)

        viewModel.removeFromOpenPlaylist(first)

        XCTAssertEqual(viewModel.playlistEntries.map(\.title), ["b"])
        XCTAssertEqual(viewModel.playlistCounts[try XCTUnwrap(viewModel.openPlaylistId)], 1)
    }

    // MARK: - 拖拽排序

    /// 拖拽后：内存顺序按落点变化，落库 position 恒为 0..n-1 连续，且库中顺序与内存一致。
    func testDragReorderPersistsContiguousPositions() throws {
        let viewModel = makeViewModel()
        let titles = ["a", "b", "c", "d"]
        viewModel.createPlaylist(named: "p", adding: nil)
        let playlist = try XCTUnwrap(viewModel.playlists.first)
        let repository = PlaylistRepository(provider)
        for title in titles {
            let track = try insertTrack(title)
            try repository.addTrack(playlistId: playlist.id, trackId: track.id)
        }
        viewModel.openPlaylist(playlist)
        XCTAssertEqual(viewModel.playlistEntries.map(\.title), titles)

        // 把最后一首拖到最前。
        viewModel.moveInOpenPlaylist(fromOffsets: IndexSet(integer: 3), toOffset: 0)

        XCTAssertEqual(viewModel.playlistEntries.map(\.title), ["d", "a", "b", "c"])
        XCTAssertEqual(try positions(playlistId: playlist.id), [0, 1, 2, 3], "position 应连续无空洞")
        XCTAssertEqual(
            try repository.entriesDetailed(playlistId: playlist.id).map(\.title),
            ["d", "a", "b", "c"],
            "库中顺序应与内存一致"
        )

        // 再来一次跨位移动，连续性不变量仍成立。
        viewModel.moveInOpenPlaylist(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(viewModel.playlistEntries.map(\.title), ["a", "b", "d", "c"])
        XCTAssertEqual(try positions(playlistId: playlist.id), [0, 1, 2, 3])
    }

    // MARK: - 只看收藏

    /// 打开「只看收藏」：列表、歌手/专辑聚合、搜索命中三处一起收敛为收藏曲目；关掉恢复全量。
    func testOnlyFavoritesFiltersListAggregatesAndSearch() throws {
        let loved = try insertTrack("七里香", artist: "周杰伦", album: "七里香")
        _ = try insertTrack("晴天", artist: "周杰伦", album: "叶惠美")
        _ = try insertTrack("成都", artist: "赵雷", album: "无法长大")
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.tracks.count, 3)

        viewModel.toggleFavorite(loved)
        XCTAssertTrue(viewModel.isFavorited(loved))
        XCTAssertEqual(viewModel.favorites.map(\.id), [loved.id])

        viewModel.onlyFavorites = true

        XCTAssertEqual(viewModel.searchResults.map(\.title), ["七里香"], "列表收敛为收藏曲目")
        XCTAssertEqual(viewModel.artistGroups.map(\.name), ["周杰伦"])
        XCTAssertEqual(viewModel.artistGroups.first?.count, 1, "聚合只看收藏曲目")
        XCTAssertEqual(viewModel.albumGroups.map(\.album), ["七里香"])

        // 「只看收藏」开着时，未收藏的歌不会被搜索命中。
        viewModel.searchQuery = "zjl"
        XCTAssertEqual(viewModel.searchResults.map(\.title), ["七里香"])
        viewModel.searchQuery = ""

        viewModel.onlyFavorites = false
        XCTAssertEqual(viewModel.searchResults.count, 3, "关掉过滤恢复全量")
        XCTAssertEqual(viewModel.artistGroups.count, 2)
    }

    /// 开着「只看收藏」时取消收藏：该曲立刻从列表与聚合里消失。
    func testUnfavoriteWhileFilteringRemovesTrackFromList() throws {
        let first = try insertTrack("a", artist: "Alice")
        let second = try insertTrack("b", artist: "Bob")
        let viewModel = makeViewModel()
        viewModel.toggleFavorite(first)
        viewModel.toggleFavorite(second)
        viewModel.onlyFavorites = true
        XCTAssertEqual(viewModel.searchResults.count, 2)

        viewModel.toggleFavorite(first)

        XCTAssertEqual(viewModel.searchResults.map(\.title), ["b"])
        XCTAssertEqual(viewModel.artistGroups.map(\.name), ["Bob"])
        XCTAssertFalse(viewModel.isFavorited(first))
    }

    /// 一首都没收藏时开过滤：isFavoritesFilterEmpty 为真（视图据此显示专门空态）。
    func testFavoritesFilterEmptyFlag() throws {
        _ = try insertTrack("a")
        let viewModel = makeViewModel()

        viewModel.onlyFavorites = true

        XCTAssertTrue(viewModel.isFavoritesFilterEmpty)
        XCTAssertFalse(viewModel.isEmpty, "库非空，只是收藏为空")
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }
}
