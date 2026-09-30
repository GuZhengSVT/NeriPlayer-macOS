// LyricsRenderingTests.swift
// M4: render real SwiftUI lyric windows with local sidecars and optional evidence PNGs.
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import NeriPlayer

@MainActor
final class LyricsRenderingTests: XCTestCase {
    func testLocalYRCPlaybackWindowAndCardRender() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LyricsRendering-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let track = Track(url: directory.appendingPathComponent("夜行.mp3"), title: "夜行", artist: "NeriPlayer · M4")
        let yrc = """
        [0,3000](0,800,0)夜(800,700,0)色(1500,700,0)渐(2200,800,0)深
        [3000,4000](3000,1000,0)Still (4000,1000,0)walking (5000,1000,0)through (6000,1000,0)the night
        [7000,4000](7000,2000,0)沿着星光(9000,2000,0)继续前行
        [11000,4000](11000,2000,0)这是一句用于验证自动换行的较长中文歌词(13000,2000,0)仍然清晰可见
        """
        try yrc.write(to: track.url.deletingPathExtension().appendingPathExtension("yrc"), atomically: true, encoding: .utf8)
        let suite = "LyricsRendering-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LyricsViewModel(provider: LocalLyricsProvider(), settings: SettingsStore(userDefaults: defaults))
        let loaded = expectation(description: "local lyrics")
        let token = model.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        model.accept(PlaybackSnapshot(currentTrack: track, isPaused: true, position: 4.5, duration: 15,
                                      isCoreIdle: false, queue: QueueState(tracks: [track], currentIndex: 0, mode: .sequential, shuffleOrder: [])))
        await fulfillment(of: [loaded], timeout: 2)
        let document = try XCTUnwrap(model.document)
        XCTAssertEqual(document.source, "local")
        XCTAssertEqual(document.lyrics.lines.count, 4)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: LyricsView(model: model).tint(.green))
        window.contentView = host
        window.title = "NeriPlayer M4 Lyrics Verification"
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); model.stop() }
        let drawn = expectation(description: "native window drawing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { drawn.fulfill() }
        await fulfillment(of: [drawn], timeout: 2)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000)
        let state = model.timeline.state(at: 4.5)
        XCTAssertEqual(state.focusedLineIndices, [1])
        XCTAssertEqual(state.syllableProgress[1], [1, 0.5, 0, 0])
        if let path = ProcessInfo.processInfo.environment["NERIPLAYER_M4_CAPTURE_DIR"] {
            let destination = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try png.write(to: destination.appendingPathComponent("m4-lyrics-window.png"))
            try LyricsCardExporter.save(title: track.title, artist: track.artist, lines: Array(document.lyrics.lines.prefix(3)),
                                        to: destination.appendingPathComponent("m4-lyrics-card.png"))
            host.frame.size = NSSize(width: 560, height: 460)
            window.setContentSize(host.frame.size)
            host.layoutSubtreeIfNeeded()
            let narrow = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: narrow)
            try XCTUnwrap(narrow.representation(using: .png, properties: [:]))
                .write(to: destination.appendingPathComponent("m4-lyrics-compact.png"))
        }
        withExtendedLifetime(token) {}
    }
}
