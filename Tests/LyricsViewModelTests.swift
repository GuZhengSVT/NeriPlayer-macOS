// LyricsViewModelTests.swift
// M4: playback binding, preferences and stale-request regressions.
import Combine
import XCTest
@testable import NeriPlayer

@MainActor
final class LyricsViewModelTests: XCTestCase {
    private func settings() throws -> SettingsStore {
        let suite = "LyricsViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SettingsStore(userDefaults: defaults)
    }

    private func snapshot(_ track: Track?, position: Double = 0, paused: Bool = false) -> PlaybackSnapshot {
        PlaybackSnapshot(currentTrack: track, isPaused: paused, position: position, duration: 180,
                         isCoreIdle: false, queue: track.map { QueueState(tracks: [$0], currentIndex: 0, mode: .sequential, shuffleOrder: []) } ?? .empty)
    }

    private var document: LyricsDocument {
        LyricsDocument(lyrics: SyncedLyrics(lines: [.synced(SyncedLine(content: "hello", start: 1000, end: 3000))]),
                       offsetMilliseconds: 200, source: "fixture")
    }

    private func waitForLoad(_ model: LyricsViewModel, action: () -> Void) async {
        let ready = expectation(description: "lyrics loaded")
        let token = model.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in ready.fulfill() }
        action()
        await fulfillment(of: [ready], timeout: 2)
        withExtendedLifetime(token) {}
    }

    func testLoadsOncePerTrackAndProgressBindsWithoutRefetch() async throws {
        let provider = FixedLyricsProvider(document: document)
        let model = LyricsViewModel(provider: provider, settings: try settings())
        let track = Track(url: URL(fileURLWithPath: "/lyrics/first.mp3"))
        await waitForLoad(model) { model.accept(snapshot(track)) }
        XCTAssertEqual(model.document, document)
        model.accept(snapshot(track, position: 1.5))
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.timeline.state(at: model.playbackSeconds(), offsetMilliseconds: model.totalOffset).timeMilliseconds, 1700)
        model.stop()
    }

    func testPreferencesAndAssociationPersistByURL() async throws {
        let store = try settings()
        let provider = FixedLyricsProvider(document: document)
        let first = LyricsViewModel(provider: provider, settings: store)
        let track = Track(url: URL(fileURLWithPath: "/lyrics/persistent.mp3"))
        await waitForLoad(first) { first.accept(snapshot(track)) }
        first.setFontSize(100)
        first.setBlur(true)
        first.setTranslation(false)
        first.setPhonetic(false)
        first.setOffset(-500)
        XCTAssertFalse(first.associate(songID: "not an id"))
        await waitForLoad(first) { XCTAssertTrue(first.associate(songID: "123")) }
        let second = LyricsViewModel(provider: provider, settings: store)
        await waitForLoad(second) { second.accept(snapshot(Track(url: track.url))) }
        XCTAssertEqual(second.fontSize, 44)
        XCTAssertTrue(second.blur)
        XCTAssertFalse(second.showTranslation)
        XCTAssertFalse(second.showPhonetic)
        XCTAssertEqual(second.offsetMilliseconds, -500)
        XCTAssertEqual(second.totalOffset, -300)
        XCTAssertEqual(second.neteaseSongID, "123")
        first.stop()
        second.stop()
    }

    func testPauseDoesNotExtrapolateAndSeekInvertsCombinedOffset() async throws {
        let model = LyricsViewModel(provider: FixedLyricsProvider(document: document), settings: try settings())
        let engine = SessionControllableEngine()
        let store = PlaybackStateStore(engine: engine)
        let track = Track(url: URL(fileURLWithPath: "/lyrics/seek.mp3"))
        store.playTrack(track)
        await waitForLoad(model) { model.attach(to: store) }
        model.setOffset(300)
        model.seek(to: try XCTUnwrap(model.document?.lyrics.lines.first))
        XCTAssertEqual(engine.seeks.last, 0.5)
        model.accept(snapshot(track, position: 4, paused: true))
        XCTAssertEqual(model.playbackSeconds(at: Date().addingTimeInterval(20)), 4)
        model.stop()
        store.stop()
    }

    func testSwitchTrackRejectsLateResponseAndStopClearsState() async throws {
        let firstStarted = expectation(description: "first request")
        let secondStarted = expectation(description: "second request")
        let provider = GatedLyricsProvider { title in
            if title == "first" { firstStarted.fulfill() } else { secondStarted.fulfill() }
        }
        let model = LyricsViewModel(provider: provider, settings: try settings())
        model.accept(snapshot(Track(url: URL(fileURLWithPath: "/lyrics/first.mp3"))))
        await fulfillment(of: [firstStarted], timeout: 2)
        model.accept(snapshot(Track(url: URL(fileURLWithPath: "/lyrics/second.mp3"))))
        XCTAssertNil(model.document)
        await fulfillment(of: [secondStarted], timeout: 2)
        let loaded = expectation(description: "second loaded")
        let token = model.$document.compactMap { $0 }.prefix(1).sink { _ in loaded.fulfill() }
        await provider.complete("second", with: LyricsDocument(lyrics: SyncedLyrics(title: "second")))
        await fulfillment(of: [loaded], timeout: 2)
        await provider.complete("first", with: LyricsDocument(lyrics: SyncedLyrics(title: "first")))
        // Yield the canceled task's completion back to the main actor.
        await Task.yield()
        XCTAssertEqual(model.document?.lyrics.title, "second")
        model.stop()
        XCTAssertNil(model.document)
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.isLoading)
        withExtendedLifetime(token) {}
    }

    func testMissingLyricsAndErrorsFinishLoading() async throws {
        let missing = LyricsViewModel(provider: FixedLyricsProvider(document: nil), settings: try settings())
        let track = Track(url: URL(fileURLWithPath: "/lyrics/missing.mp3"))
        await waitForLoad(missing) { missing.accept(snapshot(track)) }
        XCTAssertNil(missing.document)
        XCTAssertNil(missing.errorMessage)
        let broken = LyricsViewModel(provider: BrokenLyricsProvider(), settings: try settings())
        await waitForLoad(broken) { broken.accept(snapshot(track)) }
        XCTAssertNotNil(broken.errorMessage)
        missing.stop()
        broken.stop()
    }

    func testCorruptPreferencesAndNonfiniteFontFallBack() throws {
        let store = try settings()
        store.set(Double.nan, for: SettingsKeys.lyricsFontSize)
        store.set(Data("bad-json".utf8), for: SettingsKeys.lyricsOffsets)
        let model = LyricsViewModel(provider: FixedLyricsProvider(document: nil), settings: store)
        XCTAssertEqual(model.fontSize, 28)
        model.setFontSize(-100)
        XCTAssertEqual(model.fontSize, 16)
        model.setOffset(Int.max)
        XCTAssertEqual(model.offsetMilliseconds, 60_000)
        model.stop()
    }
}

private actor FixedLyricsProvider: LyricsProvider {
    let document: LyricsDocument?
    private(set) var calls = 0
    init(document: LyricsDocument?) { self.document = document }
    func lyrics(for request: LyricsRequest) async throws -> LyricsDocument? { calls += 1; return document }
}

private struct BrokenLyricsProvider: LyricsProvider {
    func lyrics(for request: LyricsRequest) async throws -> LyricsDocument? { throw URLError(.notConnectedToInternet) }
}

private actor GatedLyricsProvider: LyricsProvider {
    private var requests: [String: CheckedContinuation<LyricsDocument?, Never>] = [:]
    private let onRequest: @Sendable (String) -> Void
    init(onRequest: @escaping @Sendable (String) -> Void) { self.onRequest = onRequest }
    func lyrics(for request: LyricsRequest) async throws -> LyricsDocument? {
        await withCheckedContinuation { continuation in
            requests[request.track.title] = continuation
            onRequest(request.track.title)
        }
    }
    func complete(_ title: String, with document: LyricsDocument) { requests.removeValue(forKey: title)?.resume(returning: document) }
}
