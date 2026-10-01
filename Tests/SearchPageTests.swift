import XCTest
@testable import NeriPlayer

@MainActor
final class SearchPageTests: XCTestCase {
    func testLinkRecognitionKeepsPlatformIdentityAndCollectionKind() {
        XCTAssertEqual(RecognizedMusicLink.parse("https://music.163.com/#/playlist?id=123"),
                       RecognizedMusicLink(source: .netease, id: "123", kind: .playlist))
        XCTAssertEqual(RecognizedMusicLink.parse("https://music.163.com/song?id=55"),
                       RecognizedMusicLink(source: .netease, id: "55", kind: nil))
        XCTAssertEqual(RecognizedMusicLink.parse("https://www.bilibili.com/video/BV1xx411c7mD?p=2"),
                       RecognizedMusicLink(source: .bilibili, id: "BV1xx411c7mD:2", kind: nil))
        XCTAssertEqual(RecognizedMusicLink.parse("https://music.youtube.com/playlist?list=PL123"),
                       RecognizedMusicLink(source: .youtubeMusic, id: "VLPL123", kind: .playlist))
        XCTAssertEqual(RecognizedMusicLink.parse("https://youtu.be/abcdefghijk"),
                       RecognizedMusicLink(source: .youtubeMusic, id: "abcdefghijk", kind: nil))
        XCTAssertNil(RecognizedMusicLink.parse("https://music.163.com.evil.example/song?id=123"))
        XCTAssertNil(RecognizedMusicLink.parse("https://music.163.com/song?id=-1"))
    }

    func testHistoryDeduplicatesPersistsAndExcludesLinks() throws {
        let suite = "SearchPageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SearchPageModel(defaults: defaults)
        model.remember(" Song "); model.remember("Other"); model.remember("song")
        model.remember("https://music.163.com/song?id=123")
        XCTAssertEqual(model.history, ["song", "Other"])
        XCTAssertEqual(SearchPageModel(defaults: defaults).history, model.history)
        model.clearHistory()
        XCTAssertTrue(SearchPageModel(defaults: defaults).history.isEmpty)
    }

    func testSearchOnlyModelDoesNotLoadCollectionsOrRecommendations() async throws {
        let client = SearchCountingClient()
        let sessions = OnlineSessionStore(credentials: OnlineMemoryCredentials())
        let content = OnlineContentRepository(clients: [client], sessions: sessions)
        let model = OnlineViewModel(clients: [client], sessions: sessions, store: nil, content: content, loadsBrowseContent: false)
        model.loadBrowseContent()
        model.setQuery("test"); model.search()
        for _ in 0..<200 where model.isSearching { try await Task.sleep(nanoseconds: 5_000_000) }
        let counts = await client.counts
        XCTAssertGreaterThan(counts.search, 0)
        XCTAssertEqual(counts.collections, 0)
        XCTAssertEqual(counts.recommendations, 0)
        model.stop()
    }

    func testCollectionFavoritesAreStableAndPersistAcrossReopen() throws {
        let suite = "CollectionFavoritesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorites = CollectionFavoritesStore(defaults: defaults)
        let collection = OnlineCollection(source: .bilibili, sourceID: "55", title: "Folder", kind: .favorites)
        favorites.toggle(collection)
        XCTAssertEqual(CollectionFavoritesStore(defaults: defaults).collections, [collection])
        favorites.toggle(collection)
        XCTAssertTrue(CollectionFavoritesStore(defaults: defaults).collections.isEmpty)
    }

    /// 账号设置页只拉账号，不拉推荐 / 歌单：
    /// 设置页的账号分类由 AccountSettingsSection 调用 loadAccountContent()，它不应触发浏览数据请求。
    /// 搜索模型（loadsBrowseContent: false）的 loadBrowseContent() 也只应转调账号请求。
    func testAccountContentLoadsAccountWithoutBrowsingData() async throws {
        let client = AccountCountingClient()
        let sessions = OnlineSessionStore(credentials: OnlineMemoryCredentials())
        let content = OnlineContentRepository(clients: [client], sessions: sessions)
        let model = OnlineViewModel(clients: [client], sessions: sessions, store: nil,
                                    content: content, loadsBrowseContent: false)
        model.loadAccountContent()
        for _ in 0..<200 where model.isLoadingAccount { try await Task.sleep(nanoseconds: 5_000_000) }
        let counts = await client.counts
        XCTAssertGreaterThan(counts.account, 0, "账号页应拉取账号")
        XCTAssertEqual(counts.collections, 0, "账号页不应拉取歌单")
        XCTAssertEqual(counts.recommendations, 0, "账号页不应拉取推荐")
        XCTAssertEqual(model.account?.name, "Fixture")
        model.stop()
    }

    func testLocalPageExcludesOnlineFavoritesButFavoritesPageRetainsThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DatabaseProvider(url: root.appendingPathComponent("library.sqlite"))
        try database.setupIfNeeded()
        let song = SongData(source: .netease, sourceID: "123", title: "Online favorite")
        try SyncRepository(database).addOnlineSong(song, favorite: true)
        let model = LibraryViewModel(database: database)
        model.load(); model.localFilesOnly = true
        XCTAssertTrue(model.sourceTracks.isEmpty)
        model.localFilesOnly = false; model.onlyFavorites = true
        XCTAssertEqual(model.sourceTracks.map(\.title), [song.title])
    }
}

private actor SearchCountingClient: OnlineMusicClient {
    nonisolated let source = MusicSource.netease
    private(set) var counts = (search: 0, collections: 0, recommendations: 0)
    func search(query: String, page: Int) async throws -> [SongData] {
        counts.search += 1; return [SongData(source: .netease, sourceID: "1", title: query)]
    }
    func collections() async throws -> [OnlineCollection] { counts.collections += 1; return [] }
    func recommendations() async throws -> [SongData] { counts.recommendations += 1; return [] }
    func resolve(song: SongData) async throws -> ResolvedAudio { throw OnlineError.invalidResponse }
    func songs(in collection: OnlineCollection) async throws -> [SongData] { [] }
}

private actor AccountCountingClient: OnlineMusicClient {
    nonisolated let source = MusicSource.netease
    private(set) var counts = (account: 0, collections: 0, recommendations: 0)
    func search(query: String, page: Int) async throws -> [SongData] { [] }
    func collections() async throws -> [OnlineCollection] { counts.collections += 1; return [] }
    func recommendations() async throws -> [SongData] { counts.recommendations += 1; return [] }
    func account() async throws -> OnlineAccount { counts.account += 1; return OnlineAccount(id: "1", name: "Fixture") }
    func resolve(song: SongData) async throws -> ResolvedAudio { throw OnlineError.invalidResponse }
    func songs(in collection: OnlineCollection) async throws -> [SongData] { [] }
}
