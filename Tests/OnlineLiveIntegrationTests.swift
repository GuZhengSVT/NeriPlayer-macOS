// OnlineLiveIntegrationTests.swift
// M5 opt-in public endpoint probes; no user cookies or logged-in accounts required.
import Foundation
import XCTest
@testable import NeriPlayer

final class OnlineLiveIntegrationTests: XCTestCase {
    private func verifyPlayback(_ audio: ResolvedAudio) async throws {
        let engine = try MPVEngine(options: MPVLaunchOption.silentAudio)
        defer { try? engine.stop() }
        try engine.loadResolvedAudio(audio, paused: false)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let state = engine.state
            if let message = state.playbackError { throw OnlineError.unavailable(message) }
            if state.hasLoadedFile, state.position >= 0.3 {
                print("M5 LIVE mpv decoded source=\(audio.song.source.rawValue) duration=\(state.duration)")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw OnlineError.unavailable("libmpv 在线解码超时")
    }
    func testPublicQRLoginTicketsAndWaitingState() async throws {
        try enabled()
        let sessions = OnlineSessionStore(credentials: OnlineMemoryCredentials())
        let clients: [any OnlineMusicClient] = [NeteaseClient(sessions: sessions), BilibiliClient(sessions: sessions)]
        for client in clients {
            let ticket = try await client.beginQRLogin()
            XCTAssertFalse(ticket.key.isEmpty)
            let state = try await client.pollQRLogin(ticket)
            XCTAssertEqual(state, .waiting)
            print("M5 LIVE QR waiting source=\(client.source.rawValue)")
        }
    }
    private func enabled() throws {
        guard ProcessInfo.processInfo.environment["NERIPLAYER_LIVE_ONLINE"] == "1" else {
            throw XCTSkip("Set NERIPLAYER_LIVE_ONLINE=1 to probe real platform APIs")
        }
    }
    func testNeteasePublicSearchAndResolution() async throws {
        try enabled()
        let client = NeteaseClient(sessions: OnlineSessionStore(credentials: OnlineMemoryCredentials()))
        let songs = try await client.search(query: "NeriPlayer", page: 1)
        print("M5 LIVE NetEase search count=\(songs.count)")
        print("M5 LIVE NetEase search completed, resolving playback")
        let song = SongData(source: .netease, sourceID: "33894312", title: "Live endpoint probe")
        let audio = try await client.resolve(song: song)
        XCTAssertNotNil(audio.url.host)
        try await verifyPlayback(audio)
        print("M5 LIVE NetEase resolved host=\(audio.url.host ?? "")")
    }
    func testBilibiliPublicSearchAndResolution() async throws {
        try enabled()
        let client = BilibiliClient(sessions: OnlineSessionStore(credentials: OnlineMemoryCredentials()))
        let songs = try await client.search(query: "音乐", page: 1)
        let song = try XCTUnwrap(songs.first)
        print("M5 LIVE Bilibili search count=\(songs.count)")
        let audio = try await client.resolve(song: song)
        XCTAssertNotNil(audio.url.host)
        try await verifyPlayback(audio)
        print("M5 LIVE Bilibili resolved host=\(audio.url.host ?? "")")
    }
    func testYouTubeMusicPublicSearchAndResolution() async throws {
        try enabled()
        let client = YouTubeMusicClient(sessionStore: OnlineSessionStore(credentials: OnlineMemoryCredentials()))
        let songs = try await client.search(query: "night music", page: 1)
        let song = try XCTUnwrap(songs.first)
        print("M5 LIVE YouTube Music search count=\(songs.count)")
        let audio = try await client.resolve(song: song)
        XCTAssertNotNil(audio.url.host)
        var request = URLRequest(url: audio.url)
        request.timeoutInterval = 15
        audio.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.data(for: request)
        print("M5 LIVE YouTube Music CDN status=\((response as? HTTPURLResponse)?.statusCode ?? 0) bytes=\(bytes.count)")
        try await verifyPlayback(audio)
        print("M5 LIVE YouTube Music resolved host=\(audio.url.host ?? "")")
    }
}
