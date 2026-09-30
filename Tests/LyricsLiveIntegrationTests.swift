// LyricsLiveIntegrationTests.swift
// M4: opt-in real NetEase endpoint verification; normal tests never need network.
import XCTest
@testable import NeriPlayer

final class LyricsLiveIntegrationTests: XCTestCase {
    func testExplicitNeteaseSongHasKaraokeLyrics() async throws {
        guard ProcessInfo.processInfo.environment["NERIPLAYER_LIVE_LYRICS"] == "1" else {
            throw XCTSkip("Enable NERIPLAYER_LIVE_LYRICS=1 for real endpoint verification")
        }
        let track = Track(url: URL(fileURLWithPath: "/lyrics/live-verification.mp3"))
        let document = try await NeteaseLyricsProvider().lyrics(for: LyricsRequest(track: track, neteaseSongID: "411214279"))
        let lyrics = try XCTUnwrap(document)
        XCTAssertEqual(lyrics.source, "netease")
        XCTAssertGreaterThan(lyrics.lyrics.lines.count, 30)
        XCTAssertTrue(lyrics.lyrics.lines.contains { ($0.karaokeLine?.syllables.count ?? 0) > 5 })
        let state = LyricsTimeline(lyrics: lyrics.lyrics).state(at: 18)
        XCTAssertFalse(state.focusedLineIndices.isEmpty)
        XCTAssertTrue(state.syllableProgress.contains { $0.contains { $0 > 0 && $0 < 1 } })
    }
}
