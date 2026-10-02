// OnlineFeatureTests.swift
// M5 unified verification: identity persistence, credentials, search, refresh/fallback and JSC integration.
// Compact JSON fixture lines mirror remote payloads verbatim.
// swiftlint:disable line_length
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import NeriPlayer

final class OnlineMemoryCredentials: OnlineCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func write(_ data: Data, account: String) throws { lock.lock(); defer { lock.unlock() }; values[account] = data }
    func remove(account: String) throws { lock.lock(); defer { lock.unlock() }; values[account] = nil }
}

struct OnlineFixtureClient: OnlineURLRefreshingClient {
    var source: MusicSource
    var songs: [SongData] = []
    var fails = false
    var expired = false
    var refreshFails = false
    func search(query: String, page: Int) async throws -> [SongData] {
        if fails { throw OnlineError.http(503) }; return songs
    }
    func resolve(song: SongData) async throws -> ResolvedAudio {
        if fails { throw OnlineError.unavailable("not available") }
        return ResolvedAudio(song: song, url: URL(string: "https://cdn.example/audio") ?? URL(fileURLWithPath: "/invalid"),
                             expiresAt: expired ? .distantPast : .distantFuture)
    }
    func refresh(song: SongData, previous: ResolvedAudio?) async throws -> ResolvedAudio {
        if refreshFails { throw OnlineError.http(403) }
        return ResolvedAudio(song: song, url: URL(string: "https://cdn.example/refreshed") ?? URL(fileURLWithPath: "/invalid"))
    }
    func songs(in collection: OnlineCollection) async throws -> [SongData] { songs }
    func recommendations() async throws -> [SongData] { songs }
    func collections() async throws -> [OnlineCollection] { [] }
}

final class OnlineFeatureTests: XCTestCase {
    private var song: SongData { SongData(source: .netease, sourceID: "123", title: "A Song", artist: "An Artist", duration: 180) }
    func testCookieIsolationAndClearing() throws {
        let store = OnlineSessionStore(credentials: OnlineMemoryCredentials())
        try store.saveCookieHeader("MUSIC_U=token; __csrf=csrf", for: .netease)
        XCTAssertEqual(try store.cookieHeader(for: .netease), "MUSIC_U=token; __csrf=csrf")
        XCTAssertNil(try store.cookieHeader(for: .bilibili))
        try store.clear(.netease)
        XCTAssertNil(try store.cookieHeader(for: .netease))
    }
    func testCookieHeaderRejectsInjectionAndInvalidNames() throws {
        for value in ["foo=bar\r\nX-Injected: yes", "bad name=x", "foo", ""] {
            XCTAssertThrowsError(try OnlineSessionStore.normalizedCookieHeader(value, source: .youtubeMusic))
        }
    }
    func testCookieExportFiltersDomainAndExpiry() throws {
        let export = "# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t0\tSID\tgood\n.evil.example\tTRUE\t/\tFALSE\t0\tSID\tbad\n.youtube.com\tTRUE\t/\tTRUE\t1\tOLD\texpired"
        XCTAssertEqual(try OnlineSessionStore.normalizedCookieHeader(export, source: .youtubeMusic), "SID=good")
    }
    func testStableOnlineQueueCodecNeverStoresSignedURL() throws {
        var track = song.track()
        track.url = try XCTUnwrap(URL(string: "https://cdn.example/signed?token=secret"))
        let json = PlayerStateCodec.encodeQueue([track])
        XCTAssertFalse(json.contains("token=secret"))
        let decoded = try XCTUnwrap(PlayerStateCodec.decodeQueue(json).first)
        XCTAssertEqual(decoded.onlineSong, song)
        XCTAssertEqual(decoded.url, song.identityURL)
        XCTAssertTrue(PlaybackSessionPolicy.isDurable(decoded))
    }
    func testSearchPreservesSourceOrderDeduplicatesAndReportsPartialFailure() async {
        let manager = OnlineSearchManager(clients: [OnlineFixtureClient(source: .netease, songs: [song, song]),
                                                    OnlineFixtureClient(source: .bilibili, fails: true), OnlineFixtureClient(source: .youtubeMusic)])
        let result = await manager.search(query: " A Song ")
        XCTAssertEqual(result.results.map(\.song), [song])
        XCTAssertEqual(result.query, "A Song")
        XCTAssertNotNil(result.failedSources[.bilibili])
        XCTAssertTrue(result.hasPartialFailure)
    }
    func testDurationBoundaryScores() {
        XCTAssertEqual(PlaybackResolver.durationScore(180, 183), 40)
        XCTAssertEqual(PlaybackResolver.durationScore(180, 183.001), 30)
        XCTAssertEqual(PlaybackResolver.durationScore(180, 195), 10)
        XCTAssertEqual(PlaybackResolver.durationScore(180, 196), 0)
        XCTAssertEqual(PlaybackResolver.durationScore(.nan, 180), 0)
    }
    func testResolverRefreshesExpiredURL() async throws {
        let resolver = PlaybackResolver(clients: [OnlineFixtureClient(source: .netease, expired: true)])
        let outcome = try await resolver.resolve(song)
        guard case .resolved(let audio, let attempts) = outcome else { return XCTFail("expected refreshed audio") }
        XCTAssertEqual(audio.url.lastPathComponent, "refreshed")
        XCTAssertTrue(attempts.contains { $0.stage == .refresh })
    }
    func testResolverFallsBackAndRejectsWrongDuration() async throws {
        var fallback = song; fallback.source = .bilibili; fallback.sourceID = "BV1xx411c7mD:1"
        var mismatch = fallback; mismatch.duration = 800
        let resolver = PlaybackResolver(clients: [OnlineFixtureClient(source: .netease, fails: true), OnlineFixtureClient(source: .bilibili)])
        XCTAssertEqual(resolver.candidates(for: song, from: [mismatch]).count, 1)
        let outcome = try await resolver.resolve(song, candidates: [fallback])
        guard case .resolved(let audio, _) = outcome else { return XCTFail("expected fallback") }
        XCTAssertEqual(audio.song.source, .bilibili)
    }
    func testResolverSkipsAfterExhaustion() async throws {
        let outcome = try await PlaybackResolver(clients: []).resolve(song)
        guard case .skipped = outcome else { return XCTFail("expected skip") }
    }
    func testNeteaseFallbackPlatformPriorityPrecedesMatchScore() {
        var bilibili = song; bilibili.source = .bilibili; bilibili.sourceID = "BV1xx411c7mD:1"; bilibili.duration = 184
        var youtube = song; youtube.source = .youtubeMusic; youtube.sourceID = "abcdefghijk"
        let candidates = PlaybackResolver(clients: []).candidates(for: song, from: [youtube, bilibili])
        XCTAssertEqual(candidates.map(\.song.source), [.netease, .bilibili, .youtubeMusic])
        XCTAssertGreaterThan(candidates[2].score.total, candidates[1].score.total)
    }
    func testPlaybackHeadersRejectInjection() throws {
        XCTAssertThrowsError(try OnlinePlaybackHeaders.validated(["Cookie": "x=1\r\nX: y"]))
        XCTAssertThrowsError(try OnlinePlaybackHeaders.validated(["Bad Key": "x"]))
        XCTAssertEqual(try OnlinePlaybackHeaders.validated(["Referer": "https://bilibili.com/"]).count, 1)
    }
    func testNeteaseSongNormalization() throws {
        let json = Data(#"{"id":123,"name":"Test","ar":[{"name":"Artist"}],"al":{"name":"Album"},"dt":183000}"#.utf8)
        let parsed = try JSONDecoder().decode(NeteaseSongResponse.self, from: json)
        XCTAssertEqual(parsed.normalized?.source, .netease)
        XCTAssertEqual(parsed.normalized?.duration, 183)
        XCTAssertEqual(parsed.normalized?.artist, "Artist")
    }
    func testNeteaseWEAPIHasDeterministicDoubleAESAndRSA() throws {
        let value = try NeteaseCrypto.weAPI(payload: ["s": "test"], secretKey: Data("abcdefghijklmnop".utf8))
        let repeated = try NeteaseCrypto.weAPI(payload: ["s": "test"], secretKey: Data("abcdefghijklmnop".utf8))
        XCTAssertEqual(value, repeated)
        XCTAssertEqual(value["params"], "CuDFnRu6I3tkacNjPgyex3G+xd8IWN5B5wihjnGXoHg=")
        XCTAssertEqual(value["encSecKey"]?.count, 256)
        XCTAssertNotNil(value["params"].flatMap { Data(base64Encoded: $0) })
    }
    func testEAPIIndependentAESVector() throws {
        let value = try NeteaseCrypto.eAPI(path: "/api/cloudsearch/pc", payload: ["s": "test"])
        let expected = "2b5d64177aa6460fbaa3dcb1285e28954bbb4f7556e09b0fb25750f12398bb505ed15d1b867f700368ed5229193b44b83c11d4560aff15815ef154f0a8abb9cf1e546481b2e47dfb465682fdf8903ad090b8a06b426668a758c2cadce62c8355"
        XCTAssertEqual(value["params"], expected.uppercased())
    }
    func testYTMRendererNormalization() throws {
        let json = Data(#"{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"abcdefghijk"},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song"}]}}},{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Artist"},{"text":" • "},{"text":"3:00"}]}}}]}}"#.utf8)
        let songs = try YouTubeMusicParser.songs(from: json)
        XCTAssertEqual(songs.first?.title, "Song")
        XCTAssertEqual(songs.first?.artist, "Artist")
        XCTAssertEqual(songs.first?.duration, 180)
    }
    func testYTMBootstrapCacheInvalidatesOtherAccount() throws {
        let html = #"ytcfg.set({"INNERTUBE_API_KEY":"api","INNERTUBE_CLIENT_VERSION":"v1","VISITOR_DATA":"visitor","LOGGED_IN":true,"PLAYER_JS_URL":"/s/player/id/base.js"});"#
        let parsed = try YouTubeMusicBootstrap.parse(html: html, fingerprint: "accountA", now: Date())
        XCTAssertTrue(parsed.usable(fingerprint: "accountA", now: Date()))
        XCTAssertFalse(parsed.usable(fingerprint: "accountB", now: Date()))
    }
    func testJSCSolverRoundTripAndOptionalChallenges() throws {
        let core = "function jsc(x) { return {preprocessed_player: '_result.sig = x => x.split(\"\").reverse().join(\"\"); _result.n = x => x + \"ok\";'}; }"
        let solver = YouTubeMusicSolver(assets: YouTubeMusicSolverAssets(library: "", core: core))
        let result = try solver.solve(signature: "abc", throttling: nil, playerJavaScript: "unused")
        XCTAssertEqual(result.signature, "cba")
        XCTAssertNil(result.throttling)
        let second = try solver.solve(signature: nil, throttling: "n", playerJavaScript: "unused")
        XCTAssertEqual(second.throttling, "nok")
        XCTAssertNotNil(YouTubeMusicSolverAssets.bundled())
    }
}

@MainActor
final class OnlineRenderingTests: XCTestCase {
    func testNativeExploreWindowRender() async throws {
        let song = SongData(source: .netease, sourceID: "123", title: "M5 Online Music", artist: "NeriPlayer", duration: 180)
        let model = OnlineViewModel(clients: [OnlineFixtureClient(source: .netease, songs: [song])],
                                    sessions: OnlineSessionStore(credentials: OnlineMemoryCredentials()))
        let loaded = expectation(description: "browse")
        let observation = model.$isLoadingRecommendations.dropFirst().filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        model.loadBrowseContent()
        await fulfillment(of: [loaded], timeout: 3)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: OnlineExploreView(viewModel: model).tint(.green).preferredColorScheme(.light))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); model.stop() }
        let drawn = expectation(description: "window drawing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { drawn.fulfill() }
        await fulfillment(of: [drawn], timeout: 2)
        host.layoutSubtreeIfNeeded()
        let pdf = host.dataWithPDF(inside: host.bounds)
        let image = try XCTUnwrap(NSImage(data: pdf))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 620,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 620).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: 900, height: 620))
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5000)
        if let path = ProcessInfo.processInfo.environment["NERIPLAYER_M5_CAPTURE_DIR"] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let destination = url.appendingPathComponent("m5-explore-window.png")
            let rendered = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 620,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rendered))
            host.wantsLayer = true
            graphics.cgContext.translateBy(x: 0, y: 620)
            graphics.cgContext.scaleBy(x: 1, y: -1)
            graphics.cgContext.setFillColor(NSColor.white.cgColor)
            graphics.cgContext.fill(host.bounds)
            host.layer?.render(in: graphics.cgContext)
            try XCTUnwrap(rendered.representation(using: .png, properties: [:])).write(to: destination)
        }
        withExtendedLifetime(observation) {}
    }
}
// swiftlint:enable line_length
