import Combine
import Foundation
import XCTest
@testable import NeriPlayer

private final class AudioRecoveryEngine: ResolvedAudioPlayerEngine, @unchecked Sendable {
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

    func load(url: URL) throws { try loadResolvedAudio(ResolvedAudio(song: fixtureSong, url: url), paused: false) }
    func loadResolvedAudio(_ audio: ResolvedAudio, paused: Bool) throws {
        value = PlayerEngineState(currentURL: audio.url, isPaused: paused, position: 0, duration: 180,
                                  isCoreIdle: paused, hasLoadedFile: true)
        broadcaster.broadcast(value)
    }
    func play() throws { value.isPaused = false; broadcaster.broadcast(value) }
    func pause() throws { value.isPaused = true; broadcaster.broadcast(value) }
    func stop() throws { value = .idle; broadcaster.broadcast(value) }
    func seek(to seconds: Double) throws { value.position = seconds; broadcaster.broadcast(value) }
    func setVolume(_ volume: Double) throws { }
    func observeState() -> AsyncStream<PlayerEngineState> { AsyncStream { $0.yield(value) } }
    func addStateObserver(_ handler: @escaping @Sendable (PlayerEngineState) -> Void) -> any PlayerEngineStateObservation {
        broadcaster.add(handler)
    }
    func fail() { value.hasLoadedFile = false; value.isCoreIdle = true; value.playbackError = "failed"; broadcaster.broadcast(value) }
}

private let fixtureSong = SongData(source: .netease, sourceID: "recovery", title: "Recovery", artist: "Artist", duration: 180)

private struct RefreshFailureClient: OnlineURLRefreshingClient {
    let source: MusicSource
    let result: SongData
    let shouldFailRefresh: Bool
    func search(query: String, page: Int) async throws -> [SongData] { [result] }
    func resolve(song: SongData) async throws -> ResolvedAudio {
        ResolvedAudio(song: song, url: URL(string: "https://cdn.example/\(source.rawValue)")!)
    }
    func refresh(song: SongData, previous: ResolvedAudio?) async throws -> ResolvedAudio {
        if shouldFailRefresh { throw OnlineError.http(403) }
        return ResolvedAudio(song: song, url: URL(string: "https://cdn.example/refreshed")!)
    }
    func songs(in collection: OnlineCollection) async throws -> [SongData] { [] }
}

@MainActor
final class AudioRecoveryRegressionTests: XCTestCase {
    func testCacheSeparatesQualityAndPersistsActualQuality() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try PlaybackAudioCache(root: root)
        let low = ResolvedAudio(song: fixtureSong, url: URL(string: "https://cdn.example/low")!,
                                requestedQuality: "standard", actualQuality: "standard")
        try await cache.record(low, start: 0, total: 4, data: Data("low!".utf8), mime: "audio/mpeg")

        let mismatched = try await cache.lookupAudio(fixtureSong, quality: "lossless")
        let matching = try await cache.lookupAudio(fixtureSong, quality: "standard")
        XCTAssertNil(mismatched)
        let reused = try XCTUnwrap(matching)
        XCTAssertEqual(reused.requestedQuality, "standard")
        XCTAssertEqual(reused.actualQuality, "standard")
        XCTAssertEqual(try Data(contentsOf: reused.url), Data("low!".utf8))
    }

    func testCacheEvictsUnpinnedSongAndRetainsPinnedPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Payload plus metadata fits once, while both complete entries exceed this budget.
        let cache = try PlaybackAudioCache(root: root, capacityBytes: 400)
        let first = fixtureSong
        let second = SongData(source: .netease, sourceID: "second", title: "Second")
        let firstAudio = ResolvedAudio(song: first, url: URL(string: "https://cdn.example/first")!, requestedQuality: "standard")
        let secondAudio = ResolvedAudio(song: second, url: URL(string: "https://cdn.example/second")!, requestedQuality: "standard")
        try await cache.record(firstAudio, start: 0, total: 6, data: Data("first!".utf8), mime: "audio/mpeg")
        let lease = await cache.acquirePin(first)
        try await cache.record(secondAudio, start: 0, total: 6, data: Data("second".utf8), mime: "audio/mpeg")
        let pinnedAudio = try await cache.lookupAudio(first, quality: "standard")
        let evictedAudio = try await cache.lookupAudio(second, quality: "standard")
        XCTAssertNotNil(pinnedAudio)
        XCTAssertNil(evictedAudio)
        await cache.releasePin(lease)
    }

    func testCancelledCacheRecordDoesNotCreateFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try PlaybackAudioCache(root: root)
        let audio = ResolvedAudio(song: fixtureSong, url: URL(string: "https://cdn.example/cancelled")!, requestedQuality: "standard")
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let writer = Task {
            for await _ in gate { break }
            try await cache.record(audio, start: 0, total: 4, data: Data("late".utf8), mime: "audio/mpeg")
        }
        writer.cancel()
        continuation.yield(())
        continuation.finish()
        do { try await writer.value; XCTFail("cancelled cache write should fail") }
        catch is CancellationError { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Working"])
    }

    func testFailedRefreshSwitchesSourceAtSavedPositionAndRemainsPaused() async throws {
        let engine = AudioRecoveryEngine()
        let store = PlaybackStateStore(engine: engine)
        let alternative = SongData(source: .bilibili, sourceID: "alt", title: "Recovery", artist: "Artist", duration: 180)
        let clients: [any OnlineMusicClient] = [
            RefreshFailureClient(source: .netease, result: fixtureSong, shouldFailRefresh: true),
            RefreshFailureClient(source: .bilibili, result: alternative, shouldFailRefresh: false),
            RefreshFailureClient(source: .youtubeMusic,
                                 result: SongData(source: .youtubeMusic, sourceID: "unused", title: "Other"), shouldFailRefresh: false)
        ]
        let coordinator = OnlinePlaybackCoordinator(store: store, resolver: PlaybackResolver(clients: clients),
                                                    searchManager: OnlineSearchManager(clients: clients))
        defer { coordinator.stop(); store.stop() }
        let playing = expectation(description: "initial source loaded")
        let initial = coordinator.$phase.filter { $0 == .playing }.prefix(1).sink { _ in playing.fulfill() }
        coordinator.play(fixtureSong)
        await fulfillment(of: [playing], timeout: 3)
        try engine.seek(to: 42)
        store.togglePlayPause()

        let switched = expectation(description: "fallback source loaded")
        let fallback = coordinator.$currentResolvedAudio.compactMap { $0 }.filter { $0.song.source == .bilibili }
            .prefix(1).sink { _ in switched.fulfill() }
        engine.fail()
        await fulfillment(of: [switched], timeout: 3)

        let deadline = Date().addingTimeInterval(1)
        while engine.position != 42 && Date() < deadline { await Task.yield() }
        XCTAssertEqual(engine.position, 42, accuracy: 0.01)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(coordinator.currentResolvedAudio?.song.source, .bilibili)
        withExtendedLifetime([initial, fallback]) {}
    }
}
