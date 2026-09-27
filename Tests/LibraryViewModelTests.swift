// LibraryViewModelTests.swift
// NeriPlayer macOS —— M2-T5：媒体库聚合纯函数与视图模型加载流程测试。
//
// 分两层覆盖：
//   1) LibraryGrouping 纯函数：不碰数据库，直接构造 LibraryTrack 断言分组键、分组数量、
//      大小写/全半角/空白折叠、空库等边界；
//   2) LibraryViewModel：在临时目录建库（不污染真实 Application Support），
//      验证 load() 读库与聚合、歌单写入口、以及 importDirectory 的后台同步回流。
//
// 素材：导入用例复用 Tests/Fixtures/Audio 的音频样本（与 M2-T4 同步测试同源），
// 找不到素材时 XCTSkip，不依赖本机音乐库。

import XCTest
import GRDB
@testable import NeriPlayer

@MainActor
final class LibraryViewModelTests: XCTestCase {

    private var tempDir: URL!
    private var provider: DatabaseProvider!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeriPlayerLibraryViewModelTests-" + UUID().uuidString, isDirectory: true)
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

    /// 造一条只关心分组字段的曲目（url 带随机后缀，避免同标题互相覆盖）。
    private func makeTrack(
        _ title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: Double? = 200
    ) -> LibraryTrack {
        LibraryTrack(
            id: UUID(),
            url: URL(fileURLWithPath: "/music/" + UUID().uuidString + "/" + title + ".mp3"),
            title: title,
            artist: artist,
            album: album,
            duration: duration
        )
    }

    /// 往临时库直接落一条带 album 的行。
    private func insertRecord(
        title: String,
        artist: String?,
        album: String? = nil,
        duration: Double? = 180
    ) throws {
        let record = TrackRecord(
            track: Track(
                url: URL(fileURLWithPath: "/music/" + UUID().uuidString + "/" + title + ".mp3"),
                title: title,
                artist: artist,
                duration: duration
            ),
            album: album
        )
        try provider.dbQueue.write { db in try record.insert(db) }
    }

    // MARK: - 聚合纯函数：歌手

    /// 归一化后相同的歌手写法（大小写/全半角/首尾空白）应并成一组。
    func testArtistGroupsMergeNormalizedVariants() {
        let tracks = [
            makeTrack("A", artist: "Kiseki"),
            makeTrack("B", artist: "KISEKI"),
            makeTrack("C", artist: "  kiseki  "),
            makeTrack("D", artist: "ＫＩＳＥＫＩ")
        ]
        let groups = LibraryGrouping.artistGroups(from: tracks)

        XCTAssertEqual(groups.count, 1, "归一化后同一位歌手只应有一组")
        XCTAssertEqual(groups.first?.count, 4)
        XCTAssertEqual(groups.first?.id, LibraryGrouping.artistKey("kiseki"))
    }

    /// 歌手缺失或纯空白都落入「未知歌手」，且不影响其他歌手分组。
    func testArtistGroupsBucketMissingArtist() {
        let tracks = [
            makeTrack("A", artist: nil),
            makeTrack("B", artist: "   "),
            makeTrack("C", artist: "Real Artist")
        ]
        let groups = LibraryGrouping.artistGroups(from: tracks)

        XCTAssertEqual(groups.count, 2)
        let unknown = groups.first { $0.id == LibraryGrouping.unknownArtist }
        XCTAssertEqual(unknown?.count, 2)
        XCTAssertEqual(unknown?.name, "未知歌手")
    }

    /// 歌手大小写不敏感的分组键必须一致（显式断言键本身，而不只是分组数量）。
    func testArtistKeyIsCaseInsensitive() {
        XCTAssertEqual(
            LibraryGrouping.artistKey("Some Artist"),
            LibraryGrouping.artistKey("  some   ARTIST ")
        )
        XCTAssertNotEqual(LibraryGrouping.artistKey(nil), LibraryGrouping.artistKey("X"))
    }

    // MARK: - 聚合纯函数：专辑

    /// 同名专辑属于不同歌手时是两张不同专辑；同 (歌手, 专辑) 才并组。
    func testAlbumGroupsSplitByArtist() {
        let tracks = [
            makeTrack("A", artist: "Alice", album: "Greatest Hits"),
            makeTrack("B", artist: "Alice", album: "greatest hits"),
            makeTrack("C", artist: "Bob", album: "Greatest Hits")
        ]
        let groups = LibraryGrouping.albumGroups(from: tracks)

        XCTAssertEqual(groups.count, 2, "专辑分组键含歌手，同名专辑跨歌手不应合并")
        let alice = groups.first { $0.artist.caseInsensitiveCompare("Alice") == .orderedSame }
        XCTAssertEqual(alice?.count, 2)
        XCTAssertEqual(alice?.album, "Greatest Hits")
    }

    /// 专辑缺失落入「未知专辑」，同时保留其歌手维度。
    func testAlbumGroupsBucketMissingAlbum() {
        let tracks = [
            makeTrack("A", artist: "Alice", album: nil),
            makeTrack("B", artist: "Alice", album: "")
        ]
        let groups = LibraryGrouping.albumGroups(from: tracks)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.album, "未知专辑")
        XCTAssertEqual(groups.first?.artist, "Alice")
        XCTAssertEqual(groups.first?.count, 2)
    }

    /// 空库：两个聚合都返回空数组（首次启动引导依赖 isEmpty，不依赖聚合）。
    func testEmptyLibraryYieldsEmptyGroups() {
        XCTAssertTrue(LibraryGrouping.artistGroups(from: []).isEmpty)
        XCTAssertTrue(LibraryGrouping.albumGroups(from: []).isEmpty)
    }

    // MARK: - 视图模型：加载流程

    /// load() 从临时库读出曲目并完成聚合，歌单为空。
    func testLoadReadsTracksAndAggregatesFromTemporaryLibrary() throws {
        try insertRecord(title: "Alpha", artist: "Alice", album: "First")
        try insertRecord(title: "Beta", artist: "alice", album: "First")
        try insertRecord(title: "Gamma", artist: "Bob", album: "Second")

        let viewModel = LibraryViewModel(database: provider)
        XCTAssertFalse(viewModel.hasLoaded)

        viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertFalse(viewModel.isEmpty)
        XCTAssertEqual(viewModel.tracks.map(\.title), ["Alpha", "Beta", "Gamma"], "按标题升序")
        XCTAssertEqual(viewModel.artistGroups.count, 2, "alice/Alice 应并成一位")
        XCTAssertEqual(viewModel.albumGroups.count, 2)
        XCTAssertNil(viewModel.errorMessage)
    }

    /// 空库加载：hasLoaded 为 true 且 isEmpty 为 true（首启引导的显示条件）。
    func testLoadEmptyLibraryMarksLoadedButEmpty() {
        let viewModel = LibraryViewModel(database: provider)
        viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertTrue(viewModel.isEmpty)
        XCTAssertTrue(viewModel.tracks.isEmpty)
    }

    /// 歌单写入口：新建歌单并把曲目加入，重复加入保持幂等。
    func testCreatePlaylistAndAddTrackIsIdempotent() throws {
        try insertRecord(title: "Alpha", artist: "Alice", album: "First")
        let viewModel = LibraryViewModel(database: provider)
        viewModel.load()
        let track = try XCTUnwrap(viewModel.tracks.first)

        viewModel.createPlaylist(named: "我的歌单", adding: track)
        XCTAssertEqual(viewModel.playlists.map(\.name), ["我的歌单"])
        let playlist = try XCTUnwrap(viewModel.playlists.first)
        XCTAssertEqual(try PlaylistRepository(provider).entries(playlistId: playlist.id).count, 1)

        // 重复加入同一首不应产生第二条。
        viewModel.add(track, to: playlist)
        XCTAssertEqual(try PlaylistRepository(provider).entries(playlistId: playlist.id).count, 1)
        XCTAssertNil(viewModel.errorMessage)
    }

    /// 空白歌单名被拒绝，不产生歌单。
    func testCreatePlaylistRejectsBlankName() throws {
        try insertRecord(title: "Alpha", artist: "Alice")
        let viewModel = LibraryViewModel(database: provider)
        viewModel.load()

        viewModel.createPlaylist(named: "   ", adding: viewModel.tracks.first)

        XCTAssertTrue(viewModel.playlists.isEmpty)
        XCTAssertEqual(viewModel.errorMessage, "歌单名不能为空")
    }

    // MARK: - 视图模型：导入流程

    /// importDirectory 在后台同步，主线程回流后 tracks 与聚合被刷新。
    func testImportDirectorySyncsAndRefreshes() async throws {
        let fixtureDir = try Self.locateFixtureDirectory()
        let libraryDir = tempDir.appendingPathComponent("music", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        for name in ["tagged.mp3", "untagged.wav"] {
            try FileManager.default.copyItem(
                at: fixtureDir.appendingPathComponent(name),
                to: libraryDir.appendingPathComponent(name)
            )
        }

        let viewModel = LibraryViewModel(database: provider)
        viewModel.importDirectory(libraryDir)

        // 等待后台同步完成（轮询 isSyncing；主线程让出以让 Task 续体执行）。
        var waited = 0.0
        while viewModel.isSyncing && waited < 15 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 0.05
        }

        XCTAssertFalse(viewModel.isSyncing, "导入应在超时前结束")
        XCTAssertEqual(viewModel.tracks.count, 2)
        XCTAssertFalse(viewModel.artistGroups.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - 素材定位

    private static func locateFixtureDirectory() throws -> URL {
        if let url = Bundle.module.url(forResource: "Audio", withExtension: nil) {
            return url
        }
        if let resources = Bundle.module.resourceURL {
            let candidate = resources.appendingPathComponent("Audio", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw XCTSkip("缺少测试素材目录（Tests/Fixtures/Audio）")
    }
}
