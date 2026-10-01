import AppKit
import SwiftUI
import XCTest
@testable import NeriPlayer

@MainActor
final class PlayerBarRenderingTests: XCTestCase {
    func testPlayerBarFitsMinimumAndWideWindowsWithoutChangingHeight() async throws {
        _ = NSApplication.shared
        let suite = "PlayerBarRenderingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(settings: SettingsStore(userDefaults: defaults))
        state.startPlaybackIntegration()
        defer { state.stopPlaybackIntegration() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 84),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: FloatingPlayerBar(onLyrics: {}).environmentObject(state))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var heights: [CGFloat] = []
        for width in [720.0, 800.0, 900.0, 1200.0] {
            window.setContentSize(NSSize(width: width, height: 84))
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            XCTAssertLessThanOrEqual(size.width, width + 1, "播放器最小宽度不能把窗口撑大")
            XCTAssertLessThanOrEqual(size.height, 90, "播放器应保持紧凑高度")
            heights.append(size.height)
            if let path = ProcessInfo.processInfo.environment["NERIPLAYER_PLAYER_CAPTURE_DIR"] {
                let root = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try host.dataWithPDF(inside: host.bounds).write(to: root.appendingPathComponent("player-\(Int(width)).pdf"))
            }
        }
        XCTAssertLessThanOrEqual((heights.max() ?? 0) - (heights.min() ?? 0), 1, "不同宽度不应使进度和内容上下跳动")
    }
}
