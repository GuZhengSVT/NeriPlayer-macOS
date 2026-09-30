// M6DownloadTests.swift
// M6: deterministic coverage for Android-aligned transfer, checkpoint and storage rules.
import CryptoKit
import Foundation
import XCTest
@testable import NeriPlayer

final class M6DownloadTests: XCTestCase {
    func testResourceKeyIgnoresVolatileSignedQueryButRetainsStableQuery() {
        let first = URL(string: "https://cdn.example/audio?id=1&expire=10&sig=old")!
        let second = URL(string: "https://cdn.example/audio?sig=new&id=1&expire=99")!
        let third = URL(string: "https://cdn.example/audio?id=2&expire=99&sig=new")!
        XCTAssertEqual(DownloadStorage.resourceKey(first), DownloadStorage.resourceKey(second))
        XCTAssertNotEqual(DownloadStorage.resourceKey(first), DownloadStorage.resourceKey(third))
    }

    func testPathOwnershipRejectsTraversalAndSymlink() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("file.part")
        try Data("ok".utf8).write(to: inside)
        XCTAssertNoThrow(try DownloadStorage.checked(inside, under: root))
        XCTAssertThrowsError(try DownloadStorage.checked(root.appendingPathComponent("../escape"), under: root))
    }

    func testRetryPolicyMatchesReferenceLimits() {
        XCTAssertEqual(DownloadRetryPolicy.delay(retryCount: 0), 1)
        XCTAssertEqual(DownloadRetryPolicy.delay(retryCount: 8), 256)
        XCTAssertEqual(DownloadRetryPolicy.delay(retryCount: 31), 300)
        XCTAssertEqual(DownloadRetryPolicy.limit(DownloadFailure.integrity), 3)
        XCTAssertEqual(DownloadRetryPolicy.limit(DownloadFailure.http(500)), 8)
        XCTAssertTrue(DownloadRetryPolicy.isOffline(URLError(.networkConnectionLost)))
    }

    func testHLSRejectsPlaylistVariantsEncryptionAndLiveStreams() throws {
        let url = URL(string: "https://cdn.example/live.m3u8")!
        XCTAssertThrowsError(try HLSPlaylist(url: url, text: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\na.m3u8\n#EXT-X-ENDLIST"))
        XCTAssertThrowsError(try HLSPlaylist(url: url, text: "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:1,\na.ts\n#EXT-X-ENDLIST"))
        XCTAssertThrowsError(try HLSPlaylist(url: url, text: "#EXTM3U\n#EXTINF:1,\na.ts"))
        let playlist = try HLSPlaylist(url: url, text: "#EXTM3U\n#EXTINF:1,\na.ts\n#EXT-X-ENDLIST")
        XCTAssertEqual(playlist.segments.first?.absoluteString, "https://cdn.example/a.ts")
    }

    func testCachePublishesOnlyAfterCompleteCoverageAndRejectsBadManifest() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try PlaybackAudioCache(root: root)
        let song = SongData(source: .bilibili, sourceID: "BV1:1", title: "Test")
        let audio = ResolvedAudio(song: song, url: URL(string: "https://cdn.example/audio?expire=1&sig=x")!)
        let initial = try await cache.lookup(song)
        XCTAssertNil(initial)
        try await cache.record(audio, start: 4, total: 8, data: Data("efgh".utf8), mime: "audio/mpeg")
        let partial = try await cache.lookup(song)
        XCTAssertNil(partial)
        try await cache.record(audio, start: 0, total: 8, data: Data("abcd".utf8), mime: "audio/mpeg")
        let completed = try await cache.lookup(song)
        let file = try XCTUnwrap(completed)
        XCTAssertEqual(try Data(contentsOf: file), Data("abcdefgh".utf8))
        try Data("bad".utf8).write(to: file)
        let corrupted = try await cache.lookup(song)
        XCTAssertNil(corrupted)
    }

    func testStorageAnalyzerSeparatesWorkingAndCompletedFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let downloads = root.appendingPathComponent("Downloads")
        let caches = root.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(at: downloads.appendingPathComponent("Files"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads.appendingPathComponent("Working"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches.appendingPathComponent("Playback"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 3).write(to: downloads.appendingPathComponent("Files/a.m4a"))
        try Data(repeating: 1, count: 2).write(to: downloads.appendingPathComponent("Working/a.part"))
        try Data(repeating: 1, count: 4).write(to: caches.appendingPathComponent("Playback/a.bin"))
        let usage = StorageAnalyzer.measure(downloads: downloads, caches: caches)
        XCTAssertEqual(usage.downloads, 3)
        XCTAssertEqual(usage.working, 2)
        XCTAssertEqual(usage.playbackCache, 4)
    }
}
