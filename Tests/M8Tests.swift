// M8Tests.swift
import XCTest
@testable import NeriPlayer

final class M8Tests: XCTestCase {
    func testURLRouterSupportsFourPlaybackActions() {
        XCTAssertEqual(AppURLRouter.action(for: URL(string: "neriplayer://play")!), .play)
        XCTAssertEqual(AppURLRouter.action(for: URL(string: "neriplayer://pause")!), .pause)
        XCTAssertEqual(AppURLRouter.action(for: URL(string: "neriplayer://next")!), .next)
        XCTAssertEqual(AppURLRouter.action(for: URL(string: "neriplayer://previous")!), .previous)
        XCTAssertNil(AppURLRouter.action(for: URL(string: "https://example.com/play")!))
    }

    func testAudioEffectFilterUsesNamedFilterAndHeadroom() {
        var settings = AudioEffectSettings(enabled: true)
        settings.bands[0].gain = 6
        let filter = AudioEffectCommandPlan.filterString(for: settings)
        XCTAssertTrue(filter.hasPrefix("@eq:lavfi=[volume="))
        XCTAssertTrue(filter.contains("equalizer=f=31.5:t=o:w=1:g=6.0"))
        XCTAssertFalse(filter.contains("loudnorm"))
        XCTAssertEqual(AudioEffectSettings.clampGain(99), 15)
    }

    func testFadePlanClampsAndPreservesBaseVolume() {
        let settings = AudioEffectSettings(fadeInMilliseconds: 1_000, fadeOutMilliseconds: 1_000)
        let plan = PlaybackFadePlan(settings: settings)
        XCTAssertEqual(plan.volume(at: 0, durationMilliseconds: 10_000, base: 70), 0)
        XCTAssertEqual(plan.volume(at: 500, durationMilliseconds: 10_000, base: 70), 35, accuracy: 0.001)
        XCTAssertEqual(plan.volume(at: 9_500, durationMilliseconds: 10_000, base: 70), 35, accuracy: 0.001)
        XCTAssertEqual(plan.volume(at: 10_000, durationMilliseconds: 10_000, base: 70), 0, accuracy: 0.001)
    }

    func testAudioOutputWatchdogFallsBackAfterRetries() {
        var watchdog = AudioOutputWatchdog(retryLimit: 2)
        XCTAssertEqual(watchdog.recordFailure(exclusive: true), .retryExclusive)
        XCTAssertEqual(watchdog.recordFailure(exclusive: true), .retryExclusive)
        XCTAssertEqual(watchdog.recordFailure(exclusive: true), .fallbackToShared)
        XCTAssertEqual(watchdog.recordSuccess(), .none)
    }

    func testListenTogetherTrackDecodesServerOmittedOptionalCandidates() throws {
        let data = Data(#"{"stableKey":"netease:1","channelId":"netease","audioId":"1","name":"Song","artist":"Artist"}"#.utf8)
        let track = try JSONDecoder().decode(ListenTogetherTrack.self, from: data)
        XCTAssertEqual(track.stableKey, "netease:1")
        XCTAssertEqual(track.streamUrls, [])
        XCTAssertEqual(track.durationMs, 0)
    }

    func testListenTogetherRoomStateAcceptsMinimalServerState() throws {
        let data = Data(#"{"roomId":"ABC234","version":3}"#.utf8)
        let state = try JSONDecoder().decode(ListenTogetherRoomState.self, from: data)
        XCTAssertEqual(state.version, 3)
        XCTAssertEqual(state.settings.allowMemberControl, true)
        XCTAssertEqual(state.playback.state, "paused")
    }
}
