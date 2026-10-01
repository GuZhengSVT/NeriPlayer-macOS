// HomeSectionsTests.swift
// 首页分区：登录门槛、独立加载、失败保留、缓存隔离、过期结果丢弃，以及响应解析。
import XCTest
@testable import NeriPlayer

/// 可编排的首页替身客户端：按分区分别控制延迟与失败。
private actor HomeFixtureClient: OnlineMusicClient, NeteaseHomeProviding, YouTubeMusicHomeProviding {
    nonisolated let source: MusicSource = .netease
    var calls: [String: Int] = [:]
    var songFails = Set<String>()
    var playlistFails = Set<String>()
    var radarFails = false
    var shelfFails = false
    var delay: UInt64 = 0

    func count(_ name: String) -> Int { calls[name, default: 0] }
    func configure(delay: UInt64) { self.delay = delay }
    func failSongs(_ sources: Set<NeteaseHomeSongSource>) { songFails = Set(sources.map(\.rawValue)) }
    func failPlaylists(_ sources: Set<NeteaseHomePlaylistSource>) { playlistFails = Set(sources.map(\.rawValue)) }
    func failRadar(_ value: Bool) { radarFails = value }
    func failShelves(_ value: Bool) { shelfFails = value }

    func song(_ id: String) -> SongData { SongData(source: .netease, sourceID: id, title: "song-" + id) }

    func search(query: String, page: Int) async throws -> [SongData] { [] }
    func resolve(song: SongData) async throws -> ResolvedAudio { throw OnlineError.unsupported("fixture") }
    func songs(in collection: OnlineCollection) async throws -> [SongData] { [song("1")] }

    func homePlaylists(_ source: NeteaseHomePlaylistSource, limit: Int) async throws -> [OnlineCollection] {
        calls["playlist:" + source.rawValue, default: 0] += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if playlistFails.contains(source.rawValue) { throw OnlineError.http(503) }
        return [OnlineCollection(source: .netease, sourceID: source.rawValue, title: source.title, trackCount: 12)]
    }

    func homeSongs(_ source: NeteaseHomeSongSource, limit: Int) async throws -> [SongData] {
        calls["song:" + source.rawValue, default: 0] += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if songFails.contains(source.rawValue) { throw OnlineError.http(503) }
        return [song(source.rawValue)]
    }

    func homeRadarPlaylists() async throws -> [OnlineCollection] {
        calls["radar", default: 0] += 1
        if radarFails { throw OnlineError.http(503) }
        return neteaseRadarPlaylistDefinitions.map(\.fallbackCollection)
    }

    func homeShelves() async throws -> [YouTubeMusicHomeShelf] {
        calls["shelves", default: 0] += 1
        if shelfFails { throw OnlineError.http(503) }
        return [YouTubeMusicHomeShelf(title: "猜你喜欢", items: [])]
    }
}

@MainActor
final class HomeSectionsTests: XCTestCase {
    private func sessions() -> OnlineSessionStore { OnlineSessionStore(credentials: OnlineMemoryCredentials()) }
    private func repository(_ client: HomeFixtureClient, _ sessions: OnlineSessionStore) -> OnlineContentRepository {
        OnlineContentRepository(clients: [client], sessions: sessions)
    }
    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<600 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        XCTFail("Timed out waiting for home state")
    }

    func testAnonymousSkipsLoginOnlySections() async throws {
        let client = HomeFixtureClient(), sessions = sessions()
        let model = HomeViewModel(content: repository(client, sessions), sessions: sessions)
        model.loadsYouTubeMusic = false
        model.load()
        await waitUntil { !model.isNeteaseLoading }
        XCTAssertFalse(model.hasLogin)
        XCTAssertFalse(model.snapshot.playlistSections.contains { $0.source == .dailyResource })
        XCTAssertFalse(model.snapshot.radarSongSections.contains { $0.source == .dailyRecommend })
        XCTAssertFalse(model.snapshot.radarSongSections.contains { $0.source == .privateFM })
        XCTAssertFalse(model.snapshot.playlistSections.isEmpty)
        XCTAssertFalse(model.snapshot.radarSongSections.isEmpty)
        model.stop()
    }

    func testLoggedInIncludesLoginOnlySections() async throws {
        let client = HomeFixtureClient(), sessions = sessions()
        try sessions.saveCookieHeader("MUSIC_U=token", for: .netease)
        let model = HomeViewModel(content: repository(client, sessions), sessions: sessions)
        model.loadsYouTubeMusic = false
        model.load()
        await waitUntil { !model.isNeteaseLoading }
        XCTAssertTrue(model.hasLogin)
        XCTAssertTrue(model.snapshot.playlistSections.contains { $0.source == .dailyResource })
        XCTAssertTrue(model.snapshot.radarSongSections.contains { $0.source == .dailyRecommend })
        XCTAssertTrue(model.snapshot.radarSongSections.contains { $0.source == .privateFM })
        model.stop()
    }

    func testSectionFailureDoesNotClearOtherSections() async throws {
        let client = HomeFixtureClient(), sessions = sessions()
        await client.failSongs([.topHot])
        let model = HomeViewModel(content: repository(client, sessions), sessions: sessions)
        model.loadsYouTubeMusic = false
        model.load()
        await waitUntil { !model.isNeteaseLoading }
        let failing = model.snapshot.trendingSongSections.first { $0.source == .topHot }
        XCTAssertNotNil(failing?.section.error)
        XCTAssertTrue(failing?.section.items.isEmpty ?? false)
        let healthy = model.snapshot.trendingSongSections.first { $0.source == .topSoaring }
        XCTAssertNil(healthy?.section.error)
        XCTAssertFalse(healthy?.section.items.isEmpty ?? true)
        XCTAssertFalse(model.snapshot.playlistSections.isEmpty)
        XCTAssertTrue(model.snapshot.playlistSections.allSatisfy { !$0.section.items.isEmpty })
        model.stop()
    }

    func testRefreshFailureRetainsPreviousItems() async throws {
        let client = HomeFixtureClient(), sessions = sessions()
        let model = HomeViewModel(content: repository(client, sessions), sessions: sessions)
        model.loadsYouTubeMusic = false
        model.load()
        await waitUntil { !model.isNeteaseLoading }
        let original = model.snapshot.playlistSections.first { $0.source == .personalized }?.section.items ?? []
        XCTAssertFalse(original.isEmpty)
        await client.failPlaylists([.personalized])
        model.reloadNetease()
        await waitUntil { !model.isNeteaseLoading }
        let refreshed = model.snapshot.playlistSections.first { $0.source == .personalized }
        XCTAssertEqual(refreshed?.section.items, original)
        XCTAssertNotNil(refreshed?.section.error)
        model.stop()
    }

    func testLateResultsFromPreviousAccountAreDiscarded() async throws {
        let client = HomeFixtureClient(), sessions = sessions()
        await client.configure(delay: 120_000_000)
        let model = HomeViewModel(content: repository(client, sessions), sessions: sessions)
        model.loadsYouTubeMusic = false
        model.load()
        try sessions.saveCookieHeader("MUSIC_U=other-account", for: .netease)
        // 先等会话变更触发的重新加载生效，再等它结算。
        await waitUntil { model.hasLogin }
        XCTAssertTrue(model.hasLogin)
        await waitUntil { !model.isNeteaseLoading }
        // 新上下文才出现登录专属分区；旧账号的延迟结果不得写入。
        let loginOnly = model.snapshot.playlistSections.first { $0.source == .dailyResource }
        XCTAssertNotNil(loginOnly)
        model.stop()
    }

    func testSectionMetadataParsingKeepsCountsFromMixedFieldNames() throws {
        // 同一语义在不同端点上用 playcount/trackCount/songCount，且可能是字符串。
        let json = """
        {"code":200,"playlists":[
          {"id":3003,"name":"每日歌单","coverImgUrl":"http://p3.music.126.net/c.jpg",
           "playcount":"123456","songCount":"32"},
          {"id":5320167908,"name":"时光雷达","coverImgUrl":"http://p4.music.126.net/d.jpg",
           "playCount":654321,"trackCount":50}
        ]}
        """
        let response = try JSONDecoder().decode(NeteaseHomePlaylistsResponse.self, from: Data(json.utf8))
        let collections = response.normalized
        XCTAssertEqual(collections.count, 2)
        XCTAssertEqual(collections.first?.trackCount, 32)
        XCTAssertEqual(collections.first?.playCount, 123_456)
        XCTAssertEqual(collections.last?.trackCount, 50)
        XCTAssertEqual(collections.last?.playCount, 654_321)
        XCTAssertEqual(collections.last?.artworkURL?.absoluteString, "https://p4.music.126.net/d.jpg")
    }

    func testNewsongAndPersonalFmShapesNormalize() throws {
        let newsong = """
        {"code":200,"result":[{"song":{"id":2002,"name":"新歌推荐","duration":210000,
          "artists":[{"id":31,"name":"歌手 B"}],"album":{"id":41,"name":"专辑 B","picUrl":"https://p2.music.126.net/b.jpg"}}}]}
        """
        let fm = """
        {"code":200,"data":[{"id":9001,"name":"私人FM","dt":180000,
          "ar":[{"id":11,"name":"歌手 A"}],"al":{"id":21,"name":"专辑 A","picUrl":"http://p1.music.126.net/a.jpg"}}]}
        """
        let songs = try JSONDecoder().decode(NeteasePersonalizedNewSongsResponse.self, from: Data(newsong.utf8))
        XCTAssertEqual(songs.normalized.first?.title, "新歌推荐")
        XCTAssertEqual(songs.normalized.first?.artist, "歌手 B")
        XCTAssertEqual(songs.normalized.first?.duration, 210)
        let fmSongs = try JSONDecoder().decode(NeteasePersonalFmResponse.self, from: Data(fm.utf8))
        XCTAssertEqual(fmSongs.normalized.first?.sourceID, "9001")
        XCTAssertEqual(fmSongs.normalized.first?.artworkURL?.absoluteString, "https://p1.music.126.net/a.jpg")
    }

    func testYouTubeHomeShelfParsingSplitsSongsAndCollections() throws {
        let json = """
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
          {"musicCarouselShelfRenderer":{
            "header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"猜你喜欢"}]}}},
            "contents":[
              {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"歌单 A"}]},
                "subtitle":{"runs":[{"text":"30 首"}]},
                "thumbnailRenderer":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://lh3.googleusercontent.com/a","width":120}]}}},
                "navigationEndpoint":{"browseEndpoint":{"browseId":"VLPL123"}}}},
              {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"单曲 B"}]},
                "subtitle":{"runs":[{"text":"歌手 C"}]},
                "navigationEndpoint":{"watchEndpoint":{"videoId":"abcdefghijk"}}}}
            ]}}
        ]}}}}]}}}
        """
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let shelves = YouTubeMusicParser.homeShelves(root)
        XCTAssertEqual(shelves.count, 1)
        XCTAssertEqual(shelves.first?.title, "猜你喜欢")
        XCTAssertEqual(shelves.first?.collections.first?.sourceID, "VLPL123")
        XCTAssertEqual(shelves.first?.songs.first?.sourceID, "abcdefghijk")
    }
}
