// LibrarySyncServiceTests.swift
// NeriPlayer macOS —— M2-T4：扫描落库（LibrarySyncService）测试。
//
// 素材策略：库根目录与数据库都建在临时目录（setUp 创建、tearDown 删除），音频样本从
// Tests/Fixtures/Audio/ 复制改名而来，因此测试不依赖本机音乐库，也不留下任何文件。
//
// 覆盖点（对应任务书第 3 条）：
//   - 造 3 个音频文件 -> sync 后库中 3 条，其中带内嵌封面者写出 covers/<id>.png；
//   - 再次 sync 未改动 -> 全部跳过、库数量不变；
//   - 删除 1 个文件后 sync -> 库中 2 条，且该曲目的 PlaylistEntry 引用被级联清理、位置压实；
//   - 扫描 A 目录时不会误删库中 B 目录的曲目（删除范围限定在扫描子树内）。

import XCTest
@testable import NeriPlayer

final class LibrarySyncServiceTests: XCTestCase {

    private var tempDir: URL!
    /// 库根目录：tempDir/library。
    private var libraryDir: URL!
    private var fixtureDir: URL!
    private var provider: DatabaseProvider!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let fileManager = FileManager.default
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("NeriPlayerSyncServiceTests-\(UUID().uuidString)", isDirectory: true)
        libraryDir = tempDir.appendingPathComponent("library", isDirectory: true)
        fixtureDir = try Self.locateFixtureDirectory()
        try fileManager.createDirectory(at: libraryDir, withIntermediateDirectories: true)

        // 三个曲目，文本元数据互不相同，避免与去重语义纠缠：
        //   first.mp3  —— 有标签、有内嵌封面（Fixture Title / Fixture Artist）；
        //   Second Song.wav —— 无标签，标题走文件名兜底；
        //   Fallback Artist - Fallback Title.wav —— 无标签，文件名拆出 artist/title。
        try copyFixture("tagged.mp3", to: "first.mp3")
        try copyFixture("untagged.wav", to: "Second Song.wav")
        try copyFixture("Fallback Artist - Fallback Title.wav", to: "Fallback Artist - Fallback Title.wav")

        provider = try DatabaseProvider(url: tempDir.appendingPathComponent("library.sqlite"))
        try provider.setupIfNeeded()
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        libraryDir = nil
        fixtureDir = nil
        provider = nil
        try super.tearDownWithError()
    }

    // MARK: - 基本落库

    /// 首轮同步：3 个文件全部入库；带封面的那条写出封面文件并回填 coverPath。
    func testSyncInsertsAllScannedFiles() throws {
        let service = makeService()
        let result = try service.sync(directory: libraryDir)

        XCTAssertEqual(result.discovered, 3)
        XCTAssertEqual(result.inserted, 3)
        XCTAssertEqual(result.updated, 0)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.totalCount, 3)

        let tracks = try LibraryRepository(provider).allTracksSorted(by: .title)
        XCTAssertEqual(tracks.count, 3)

        // tagged.mp3 内嵌 PNG 封面：应落成 covers/<id>.png 并写回路径。
        let withCover = try XCTUnwrap(tracks.first { $0.format == "mp3" })
        let coverPath = try XCTUnwrap(withCover.coverPath, "带内嵌封面的样本应写出封面路径")
        XCTAssertTrue(FileManager.default.fileExists(atPath: coverPath), "封面文件应真实存在：\(coverPath)")
        XCTAssertTrue(coverPath.hasSuffix("\(withCover.id.uuidString).png"), "封面以库 id 命名")
        XCTAssertEqual(result.coversWritten, 1)

        // 无封面的样本不产生封面路径。
        XCTAssertNil(tracks.first { $0.url.lastPathComponent == "Second Song.wav" }?.coverPath)
    }

    /// 第二轮同步未改动：全部跳过，库数量不变，封面不重写。
    func testSecondSyncSkipsUnchangedFiles() throws {
        let service = makeService()
        _ = try service.sync(directory: libraryDir)
        let second = try service.sync(directory: libraryDir)

        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.updated, 0)
        XCTAssertEqual(second.skipped, 3, "指纹未变应全部跳过")
        XCTAssertEqual(second.removed, 0)
        XCTAssertEqual(second.coversWritten, 0, "内容未变不应重复写封面")
        XCTAssertEqual(second.totalCount, 3)
    }

    /// 库里已有的幂等键：同一文件重复同步不产生第二行，且保留原 id。
    func testSyncIsIdempotentByURL() throws {
        let service = makeService()
        _ = try service.sync(directory: libraryDir)
        let firstIds = Set(try LibraryRepository(provider).allTracks().map(\.id))

        _ = try service.sync(directory: libraryDir)
        let secondIds = Set(try LibraryRepository(provider).allTracks().map(\.id))

        XCTAssertEqual(firstIds, secondIds, "重扫应保留原 id，不因复用/重读产生新主键")
    }

    // MARK: - 删除与引用清理

    /// 删除一个文件后同步：库中只剩 2 条，被删曲目的歌单条目随之级联清理、位置压实。
    func testSyncRemovesDeletedFileAndCleansPlaylistEntries() throws {
        let service = makeService()
        _ = try service.sync(directory: libraryDir)

        let library = LibraryRepository(provider)
        let playlists = PlaylistRepository(provider)
        let all = try library.allTracksSorted(by: .title)
        XCTAssertEqual(all.count, 3)

        // 把「Second Song.wav」与另一首放进同一歌单，验证删除后引用被清理。
        let doomed = try XCTUnwrap(all.first { $0.url.lastPathComponent == "Second Song.wav" })
        let survivor = try XCTUnwrap(all.first { $0.url.lastPathComponent != "Second Song.wav" })
        let playlist = try playlists.create(name: "p")
        try playlists.addTrack(playlistId: playlist.id, trackId: doomed.id)
        try playlists.addTrack(playlistId: playlist.id, trackId: survivor.id)
        XCTAssertEqual(try playlists.entries(playlistId: playlist.id).count, 2)

        try FileManager.default.removeItem(at: libraryDir.appendingPathComponent("Second Song.wav"))
        let second = try service.sync(directory: libraryDir)

        XCTAssertEqual(second.removed, 1)
        XCTAssertEqual(second.totalCount, 2)
        XCTAssertEqual(try library.allTracks().count, 2)
        XCTAssertNil(try library.track(id: doomed.id), "被删曲目应已从库中移除")

        // 引用清理：歌单只剩 survivor，位置压实为 0。
        let entries = try playlists.entries(playlistId: playlist.id)
        XCTAssertEqual(entries.map(\.id), [survivor.id])
        let positions = try provider.dbQueue.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT position FROM PlaylistEntry WHERE playlistId = ? ORDER BY position",
                arguments: [playlist.id]
            )
        }
        XCTAssertEqual(positions, [0])
    }

    /// 扫描 A 目录不应移除库里 B 目录的曲目：删除范围限定在本次扫描子树内。
    func testSyncDoesNotRemoveTracksOutsideScannedDirectory() throws {
        let otherDir = tempDir.appendingPathComponent("other-library", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtureDir.appendingPathComponent("tagged.flac"),
            to: otherDir.appendingPathComponent("outside.flac")
        )

        let service = makeService()
        _ = try service.sync(directory: otherDir)
        XCTAssertEqual(try LibraryRepository(provider).allTracks().count, 1)

        // 再扫 library（另一个目录）：不应把 other-library 的那首删掉。
        let result = try service.sync(directory: libraryDir)
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.totalCount, 4, "两个目录的曲目应共存")
        XCTAssertTrue(
            try LibraryRepository(provider).allTracks().contains { $0.url.lastPathComponent == "outside.flac" },
            "扫描 A 目录不应移除 B 目录的曲目"
        )
    }

    func testMissingRootDoesNotDeleteTracksFavoritesPlaylistsOrCovers() throws {
        let service = makeService()
        _ = try service.sync(directory: libraryDir)
        let library = LibraryRepository(provider)
        let before = try library.allTracksSorted(by: .title)
        let covered = try XCTUnwrap(before.first { $0.coverPath != nil })
        let coverPath = try XCTUnwrap(covered.coverPath)
        let coverBytes = try Data(contentsOf: URL(fileURLWithPath: coverPath))
        let playlists = PlaylistRepository(provider)
        let playlist = try playlists.create(name: "Keep me")
        try playlists.addTrack(playlistId: playlist.id, trackId: covered.id)
        try FavoriteRepository(provider).favorite(trackId: covered.id)

        let offline = tempDir.appendingPathComponent("offline", isDirectory: true)
        try FileManager.default.moveItem(at: libraryDir, to: offline)
        XCTAssertThrowsError(try service.sync(directory: libraryDir)) { error in
            XCTAssertEqual(error as? LibrarySyncError, .incompleteScan(self.libraryDir.standardizedFileURL))
        }
        XCTAssertEqual(try library.allTracksSorted(by: .title), before)
        XCTAssertEqual(try playlists.entries(playlistId: playlist.id).map(\.id), [covered.id])
        XCTAssertTrue(try FavoriteRepository(provider).isFavorited(trackId: covered.id))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: coverPath)), coverBytes)
    }

    func testUnreadableSubdirectoryRejectsPartialSnapshotAndPreservesCache() throws {
        let hidden = libraryDir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureDir.appendingPathComponent("untagged.wav"),
                                         to: hidden.appendingPathComponent("hidden.wav"))
        let scanner = LibraryScanner()
        let service = LibrarySyncService(database: provider, scanner: scanner)
        _ = try service.sync(directory: libraryDir)
        let before = try LibraryRepository(provider).allTracksSorted(by: .title)
        let cached = scanner.scan(directory: libraryDir)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: hidden.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hidden.path) }
        if (try? FileManager.default.contentsOfDirectory(atPath: hidden.path)) != nil {
            throw XCTSkip("This user can enumerate permission-denied directories")
        }

        let partial = scanner.scan(directory: libraryDir)
        XCTAssertFalse(partial.isComplete)
        XCTAssertEqual(partial.removedCount, 0)
        XCTAssertThrowsError(try service.sync(directory: libraryDir))
        XCTAssertEqual(try LibraryRepository(provider).allTracksSorted(by: .title), before)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hidden.path)
        let restored = scanner.scan(directory: libraryDir)
        XCTAssertTrue(restored.isComplete)
        XCTAssertEqual(restored.tracks.map(\.id), cached.tracks.map(\.id))
        XCTAssertEqual(restored.scannedCount, 0)
    }

    func testSuccessfullyScannedEmptyRootStillRemovesMissingTracks() throws {
        let service = makeService()
        _ = try service.sync(directory: libraryDir)
        for file in try FileManager.default.contentsOfDirectory(at: libraryDir, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
        let result = try service.sync(directory: libraryDir)
        XCTAssertEqual(result.removed, 3)
        XCTAssertEqual(result.totalCount, 0)
    }

    // MARK: - 素材工具

    private func makeService() -> LibrarySyncService {
        LibrarySyncService(database: provider)
    }

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

    private func copyFixture(_ fixtureName: String, to destinationName: String) throws {
        let source = fixtureDir.appendingPathComponent(fixtureName)
        let destination = libraryDir.appendingPathComponent(destinationName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
