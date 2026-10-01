// T02-T05: real repository lifetime, coalescing, pagination and independent navigation.
import Combine
import XCTest
@testable import NeriPlayer

private actor ContentFixtureClient: OnlineMusicClient, NeteaseHomeProviding {
    nonisolated let source: MusicSource
    var calls: [String: Int] = [:]
    var fails = false
    var delay: UInt64 = 0
    var pageFails = false
    init(_ source: MusicSource) { self.source = source }
    func count(_ name: String) -> Int { calls[name, default: 0] }
    func configure(fails: Bool = false, delay: UInt64 = 0, pageFails: Bool = false) {
        self.fails = fails; self.delay = delay; self.pageFails = pageFails
    }
    func song(_ id: String) -> SongData { SongData(source: source, sourceID: id, title: source.title + id) }
    func search(query: String, page: Int) async throws -> [SongData] { [] }
    func resolve(song: SongData) async throws -> ResolvedAudio { throw OnlineError.unsupported("fixture") }
    func songs(in collection: OnlineCollection) async throws -> [SongData] { [song("1"), song("2")] }
    func recommendations() async throws -> [SongData] {
        calls["recommendations", default: 0] += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if fails { throw OnlineError.http(503) }
        return [song("1")]
    }
    func collections() async throws -> [OnlineCollection] {
        calls["collections", default: 0] += 1
        if fails { throw OnlineError.http(503) }
        return [OnlineCollection(source: source, sourceID: "42", title: source.title)]
    }
    func account() async throws -> OnlineAccount {
        calls["account", default: 0] += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return OnlineAccount(id: "account", name: "fixture")
    }
    func collectionPage(in collection: OnlineCollection, cursor: String?) async throws -> OnlineCollectionPage {
        calls["detail", default: 0] += 1
        if cursor != nil && pageFails { throw OnlineError.http(503) }
        return cursor == nil ? OnlineCollectionPage(songs: [song("1")], nextCursor: "2")
            : OnlineCollectionPage(songs: [song("1"), song("2")])
    }

    // Home sections use the same fixture so section-level isolation can be asserted without a network.
    func homePlaylists(_ source: NeteaseHomePlaylistSource, limit: Int) async throws -> [OnlineCollection] {
        calls["homePlaylists", default: 0] += 1
        if fails { throw OnlineError.http(503) }
        return [OnlineCollection(source: .netease, sourceID: "\(source.rawValue)", title: source.title)]
    }

    func homeSongs(_ source: NeteaseHomeSongSource, limit: Int) async throws -> [SongData] {
        calls["homeSongs", default: 0] += 1
        if fails { throw OnlineError.http(503) }
        return [song(source.rawValue)]
    }

    func homeRadarPlaylists() async throws -> [OnlineCollection] {
        calls["homeRadar", default: 0] += 1
        if fails { throw OnlineError.http(503) }
        return neteaseRadarPlaylistDefinitions.map(\.fallbackCollection)
    }
}

@MainActor
final class OnlineContentCacheTests: XCTestCase {
    private func sessions() -> OnlineSessionStore { OnlineSessionStore(credentials: OnlineMemoryCredentials()) }
    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for content state")
    }

    func testRecommendationsCoalesceAndReuseFreshCache() async throws {
        let client = ContentFixtureClient(.netease), sessions = sessions()
        await client.configure(delay: 20_000_000)
        let repository = OnlineContentRepository(clients: [client], sessions: sessions)
        let context = try repository.context(for: .netease)
        async let first = repository.recommendations(source: .netease, context: context, force: false)
        async let second = repository.recommendations(source: .netease, context: context, force: false)
        let values = try await (first, second)
        XCTAssertEqual(values.0.value, values.1.value)
        _ = try await repository.recommendations(source: .netease, context: context, force: false)
        let count = await client.count("recommendations")
        XCTAssertEqual(count, 1)
    }

    func testDetailPagesPreserveOrderDeduplicateAndCacheCompleteResult() async throws {
        let client = ContentFixtureClient(.netease), sessions = sessions()
        let repository = OnlineContentRepository(clients: [client], sessions: sessions)
        let collection = OnlineCollection(source: .netease, sourceID: "42", title: "Playlist")
        let context = try repository.context(for: .netease)
        var pageSizes: [Int] = []
        let value = try await repository.detail(collection, context: context, force: false) { pageSizes.append($0.count) }
        XCTAssertEqual(pageSizes, [1, 2])
        XCTAssertEqual(value.value.songs.map(\.sourceID), ["1", "2"])
        _ = try await repository.detail(collection, context: context, force: false)
        let count = await client.count("detail")
        XCTAssertEqual(count, 2)
    }

    func testPartialPageFailureDoesNotPublishCompleteCache() async throws {
        let client = ContentFixtureClient(.netease), sessions = sessions()
        await client.configure(pageFails: true)
        let repository = OnlineContentRepository(clients: [client], sessions: sessions)
        let collection = OnlineCollection(source: .netease, sourceID: "42", title: "Playlist")
        let context = try repository.context(for: .netease)
        do {
            _ = try await repository.detail(collection, context: context, force: false)
            XCTFail("Expected second page failure")
        } catch { XCTAssertEqual(error as? OnlineError, .http(503)) }
        XCTAssertNil(repository.cached(OnlineCollectionDetail.self, source: .netease, context: context, resource: "detail:\(collection.id)"))
    }

    func testFailedRefreshRetainsPreviousSuccessfulValue() async throws {
        let client = ContentFixtureClient(.netease), sessions = sessions()
        let repository = OnlineContentRepository(clients: [client], sessions: sessions)
        let model = OnlineViewModel(clients: [client], sessions: sessions, store: nil, content: repository)
        model.loadBrowseContent()
        await waitUntil { !model.isLoadingCollections && !model.isLoadingRecommendations }
        let original = model.collections
        await client.configure(fails: true)
        model.loadBrowseContent(force: true)
        XCTAssertEqual(model.collections, original)
        await waitUntil { !model.isLoadingCollections && !model.isLoadingRecommendations }
        XCTAssertEqual(model.collections, original)
        XCTAssertNotNil(model.browseErrors["歌单"])
        model.stop()
    }

    func testAccountChangeCannotReusePrivateCache() async throws {
        let client = ContentFixtureClient(.netease), sessions = sessions()
        try sessions.saveCookieHeader("MUSIC_U=first", for: .netease)
        let repository = OnlineContentRepository(clients: [client], sessions: sessions)
        let old = try repository.context(for: .netease)
        _ = try await repository.collections(source: .netease, context: old, force: false)
        try sessions.saveCookieHeader("MUSIC_U=second", for: .netease)
        let new = try repository.context(for: .netease)
        XCTAssertNotEqual(old, new)
        XCTAssertNil(repository.cached([OnlineCollection].self, source: .netease, context: new, resource: "collections"))
    }

    func testHomeRecommendationsStayIndependentOfExploreSource() async throws {
        let netease = ContentFixtureClient(.netease), bili = ContentFixtureClient(.bilibili), sessions = sessions()
        let repository = OnlineContentRepository(clients: [netease, bili], sessions: sessions)
        let home = HomeViewModel(content: repository, sessions: sessions)
        let explore = OnlineViewModel(clients: [netease, bili], sessions: sessions, store: nil, content: repository)
        home.loadsYouTubeMusic = false
        home.load()
        await waitUntil { !home.isNeteaseLoading }
        let original = home.snapshot.playlistSections
        XCTAssertFalse(original.isEmpty)
        explore.setSource(.bilibili)
        await waitUntil { !explore.isLoadingRecommendations }
        XCTAssertEqual(home.snapshot.playlistSections, original)
        XCTAssertEqual(home.source, .netease)
        XCTAssertEqual(explore.recommendations.first?.source, .bilibili)
        home.stop(); explore.stop()
    }

    func testFastPlatformSwitchDiscardsLateResults() async throws {
        let netease = ContentFixtureClient(.netease), bili = ContentFixtureClient(.bilibili), sessions = sessions()
        await netease.configure(delay: 80_000_000)
        let explore = OnlineViewModel(clients: [netease, bili], sessions: sessions)
        explore.loadBrowseContent()
        explore.setSource(.bilibili)
        await waitUntil { !explore.isLoadingRecommendations && !explore.isLoadingAccount }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(explore.source, .bilibili)
        XCTAssertTrue(explore.recommendations.allSatisfy { $0.source == .bilibili })
        XCTAssertTrue(explore.collections.allSatisfy { $0.source == .bilibili })
        explore.stop()
    }
}
