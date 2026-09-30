// PlaybackLifecycleRegressionTests.swift — delayed load, pause and EOF isolation.
import XCTest
@testable import NeriPlayer

final class PlaybackLifecycleRegressionTests: XCTestCase {
    private func track(_ name: String) -> Track {
        Track(url: URL(fileURLWithPath: "/music/\(name).wav"), title: name)
    }

    func testPauseAndBufferingNeverAdvanceOrReloadQueue() async {
        let engine = DelayedLifecycleEngine()
        let store = PlaybackStateStore(engine: engine)
        let first = track("first"), second = track("second")
        store.setQueue([first, second])
        engine.finishLoading()
        engine.simulateIdle(paused: true)
        XCTAssertEqual(store.currentTrack?.id, first.id)
        store.togglePlayPause()
        XCTAssertEqual(engine.loads, 1)
        XCTAssertFalse(engine.isPaused)
        engine.simulateIdle(paused: false)
        XCTAssertEqual(store.currentTrack?.id, first.id)
        XCTAssertEqual(engine.loads, 1)
        engine.end()
        let deadline = Date().addingTimeInterval(1)
        while engine.loads < 2, Date() < deadline { await Task.yield() }
        XCTAssertEqual(store.currentTrack?.id, second.id)
        XCTAssertEqual(engine.loads, 2)
    }

    func testSelectingAnotherTrackCancelsPendingRestore() {
        let engine = DelayedLifecycleEngine()
        let store = PlaybackStateStore(engine: engine)
        let first = track("first"), second = track("second")
        store.restore(PlayerState(tracks: [first], currentIndex: 0, position: 42, mode: .sequential))
        store.setQueue([second])
        engine.finishLoading()
        XCTAssertEqual(store.currentTrack?.id, second.id)
        XCTAssertTrue(engine.seeks.isEmpty)
        XCTAssertFalse(engine.isPaused)
    }

    func testEmptyRestoreStopsOldPlayback() {
        let engine = DelayedLifecycleEngine()
        let store = PlaybackStateStore(engine: engine)
        store.setQueue([track("first")])
        engine.finishLoading()
        store.restore(PlayerState(tracks: [], currentIndex: nil, position: 0, mode: .sequential))
        XCTAssertNil(engine.currentURL)
        XCTAssertNil(store.currentTrack)
        XCTAssertTrue(store.snapshot.isCoreIdle)
    }
}

/// Single-threaded synchronous fixture; delayed completion is driven by each test.
private final class DelayedLifecycleEngine: PlayerEngine, @unchecked Sendable {
    private var value = PlayerEngineState.idle
    private let broadcaster = PlayerEngineStateBroadcaster()
    private(set) var loads = 0
    private(set) var seeks: [Double] = []
    var currentURL: URL? { value.currentURL }
    var isPaused: Bool { value.isPaused }
    var position: Double { value.position }
    var duration: Double { value.duration }
    var isCoreIdle: Bool { value.isCoreIdle }
    var hasLoadedFile: Bool { value.hasLoadedFile }
    var hasEnded: Bool { value.hasEnded }
    func load(url: URL) throws { try load(url: url, paused: false) }
    func load(url: URL, paused: Bool) throws {
        loads += 1
        value = PlayerEngineState(currentURL: url, isPaused: paused, position: 0, duration: 100,
                                  isCoreIdle: true, hasLoadedFile: false)
        broadcaster.broadcast(value)
    }
    func finishLoading() {
        value.hasLoadedFile = true
        value.isCoreIdle = value.isPaused
        broadcaster.broadcast(value)
    }
    func simulateIdle(paused: Bool) {
        value.isPaused = paused
        value.isCoreIdle = true
        broadcaster.broadcast(value)
    }
    func end() {
        value.hasEnded = true
        value.hasLoadedFile = false
        value.isCoreIdle = true
        broadcaster.broadcast(value)
    }
    func play() throws {
        value.isPaused = false
        value.isCoreIdle = false
        broadcaster.broadcast(value)
    }
    func pause() throws { simulateIdle(paused: true) }
    func stop() throws { value = .idle; broadcaster.broadcast(value) }
    func seek(to seconds: Double) throws {
        seeks.append(seconds)
        value.position = seconds
        broadcaster.broadcast(value)
    }
    func setVolume(_ volume: Double) throws {}
    func observeState() -> AsyncStream<PlayerEngineState> {
        AsyncStream { $0.yield(value); $0.finish() }
    }
    func addStateObserver(_ handler: @escaping @Sendable (PlayerEngineState) -> Void) -> any PlayerEngineStateObservation {
        broadcaster.add(handler)
    }
}
