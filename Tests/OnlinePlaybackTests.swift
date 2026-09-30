// OnlinePlaybackTests.swift
// M5: deterministic late network completion, runtime refresh and queue failure bounds.
import Combine
import Foundation
import XCTest
@testable import NeriPlayer

private final class OnlineTestEngine: ResolvedAudioPlayerEngine, @unchecked Sendable {
    private var value = PlayerEngineState.idle
    private let broadcaster = PlayerEngineStateBroadcaster()
    var currentURL: URL? { value.currentURL }
    var isPaused: Bool { value.isPaused }
    var position: Double { value.position }
    var duration: Double { value.duration }
    var isCoreIdle: Bool { value.isCoreIdle }
    var hasEnded: Bool { value.hasEnded }
    var hasLoadedFile: Bool { value.hasLoadedFile }
    var state: PlayerEngineState { value }
    var loadCount = 0
    func load(url: URL) throws { loadCount += 1; update(url: url, paused: false) }
    func loadResolvedAudio(_ audio: ResolvedAudio, paused: Bool) throws { loadCount += 1; update(url: audio.url, paused: paused) }
    private func update(url: URL, paused: Bool) {
        value = PlayerEngineState(currentURL: url, isPaused: paused, position: 0, duration: 180, isCoreIdle: paused, hasLoadedFile: true)
        broadcaster.broadcast(value)
    }
    func play() throws { value.isPaused = false; broadcaster.broadcast(value) }
    func pause() throws { value.isPaused = true; broadcaster.broadcast(value) }
    func stop() throws { value = .idle; broadcaster.broadcast(value) }
    func seek(to seconds: Double) throws { value.position = seconds; broadcaster.broadcast(value) }
    func setVolume(_ volume: Double) throws { }
    func observeState() -> AsyncStream<PlayerEngineState> { AsyncStream { $0.yield(value) } }
    func addStateObserver(_ handler: @escaping @Sendable (PlayerEngineState) -> Void) -> any PlayerEngineStateObservation { broadcaster.add(handler) }
    func fail() { value.hasLoadedFile = false; value.isCoreIdle = true; value.playbackError = "failed"; broadcaster.broadcast(value) }
    func end() { value.hasLoadedFile = false; value.hasEnded = true; value.isCoreIdle = true; broadcaster.broadcast(value) }
}
private final class OnlineRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: UUID?
    func accept(_ token: UUID) { lock.lock(); defer { lock.unlock() }; latest = token }
    var token: UUID? { lock.lock(); defer { lock.unlock() }; return latest }
}

@MainActor
final class OnlinePlaybackTests: XCTestCase {
    private var song: SongData { SongData(source: .netease, sourceID: "123", title: "Song", artist: "Artist", duration: 180) }
    func testStopRejectsLateResolution() throws {
        let engine = OnlineTestEngine(); let store = PlaybackStateStore(engine: engine)
        let capture = OnlineRequestCapture()
        store.setOnlineHandlers(load: { _, token, _ in capture.accept(token) }, failure: nil)
        let track = song.track(); store.playTrack(track)
        let token = try XCTUnwrap(capture.token)
        store.stop()
        let audio = ResolvedAudio(song: song, url: try XCTUnwrap(URL(string: "https://cdn.example/audio")))
        XCTAssertFalse(try store.loadResolvedAudio(audio, for: track, requestID: token, paused: false))
        XCTAssertEqual(engine.loadCount, 0)
    }
    func testLocalSelectionRejectsOldOnlineCompletion() throws {
        let engine = OnlineTestEngine(); let store = PlaybackStateStore(engine: engine)
        let capture = OnlineRequestCapture()
        store.setOnlineHandlers(load: { _, token, _ in capture.accept(token) }, failure: nil)
        let track = song.track(); store.playTrack(track)
        let token = try XCTUnwrap(capture.token)
        let local = Track(url: URL(fileURLWithPath: "/fixture.wav")); store.playTrack(local)
        let audio = ResolvedAudio(song: song, url: try XCTUnwrap(URL(string: "https://cdn.example/audio")))
        XCTAssertFalse(try store.loadResolvedAudio(audio, for: track, requestID: token, paused: false))
        XCTAssertEqual(store.currentTrack?.id, local.id)
    }
    func testOnlineEOFAdvancesStableQueueAndRestoreWaitsUntilLoaded() async throws {
        let engine = OnlineTestEngine(); let store = PlaybackStateStore(engine: engine)
        let capture = OnlineRequestCapture()
        store.setOnlineHandlers(load: { _, token, _ in capture.accept(token) }, failure: nil)
        let track = song.track(); let local = Track(url: URL(fileURLWithPath: "/fixture.wav"))
        store.restore(PlayerState(tracks: [track, local], currentIndex: 0, position: 42, mode: .sequential), resumePlayback: true)
        let audio = ResolvedAudio(song: song, url: try XCTUnwrap(URL(string: "https://cdn.example/audio")))
        XCTAssertTrue(try store.loadResolvedAudio(audio, for: track, requestID: XCTUnwrap(capture.token), paused: false))
        XCTAssertEqual(engine.position, 42)
        XCTAssertEqual(store.currentTrack?.url, song.identityURL)
        engine.end()
        let deadline = Date().addingTimeInterval(1)
        while engine.currentURL != local.url, Date() < deadline { await Task.yield() }
        XCTAssertEqual(store.currentTrack?.id, local.id)
        XCTAssertEqual(engine.currentURL, local.url)
    }
    func testValidPlaybackCacheHitLoadsLocalFileWithStableOnlineQueueIdentity() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PlaybackAudioCache(root: directory)
        let cached = URL(string: "https://cdn.example/audio?expire=1&sig=old")!
        let audio = ResolvedAudio(song: song, url: cached)
        try await cache.record(audio, start: 0, total: 8, data: Data("abcdefgh".utf8), mime: "audio/mpeg")
        let engine = OnlineTestEngine(); let store = PlaybackStateStore(engine: engine)
        let client = OnlineFixtureClient(source: .netease, fails: true)
        let coordinator = OnlinePlaybackCoordinator(store: store, resolver: PlaybackResolver(clients: [client]),
                                                    searchManager: OnlineSearchManager(clients: [client]), cache: cache)
        defer { coordinator.stop(); store.stop() }
        let ready = expectation(description: "cache hit ready")
        let observation = coordinator.$phase.filter { $0 == .playing }.prefix(1).sink { _ in ready.fulfill() }
        coordinator.play(song)
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertEqual(engine.currentURL?.pathExtension, "mp3")
        XCTAssertEqual(store.currentTrack?.url, song.identityURL)
        XCTAssertEqual(coordinator.currentResolvedAudio?.url, engine.currentURL)
        withExtendedLifetime(observation) {}
    }

    func testFailureSkipDoesNotLoopRepeatOne() throws {
        let engine = OnlineTestEngine(); let store = PlaybackStateStore(engine: engine)
        let track = song.track()
        store.setQueue([track]); store.setMode(.repeatOne)
        store.skipFailedOnlineTrack(track.id)
        XCTAssertNil(engine.currentURL)
        XCTAssertEqual(store.currentTrack?.id, track.id)
    }
    func testRuntimeFailureRefreshesOnlyOnceThenSkips() async throws {
        let engine = OnlineTestEngine(); let store = PlaybackStateStore(engine: engine)
        let client = OnlineFixtureClient(source: .netease)
        let coordinator = OnlinePlaybackCoordinator(store: store, resolver: PlaybackResolver(clients: [client]),
                                                    searchManager: OnlineSearchManager(clients: [client]))
        defer { coordinator.stop(); store.stop() }
        let ready = expectation(description: "initial resolution")
        let observation = coordinator.$phase.filter { $0 == .playing }.prefix(1).sink { _ in ready.fulfill() }
        coordinator.play(song)
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertEqual(engine.loadCount, 1)
        let refreshed = expectation(description: "refresh")
        let second = coordinator.$currentResolvedAudio.compactMap { $0 }
            .filter { $0.url.lastPathComponent == "refreshed" }.prefix(1).sink { _ in refreshed.fulfill() }
        engine.fail()
        await fulfillment(of: [refreshed], timeout: 3)
        XCTAssertEqual(engine.loadCount, 2)
        let skipped = expectation(description: "skip")
        let third = coordinator.$phase.filter { $0 == .skipped }.prefix(1).sink { _ in skipped.fulfill() }
        engine.fail()
        await fulfillment(of: [skipped], timeout: 3)
        XCTAssertEqual(engine.loadCount, 2)
        withExtendedLifetime([observation, second, third]) {}
    }
}
