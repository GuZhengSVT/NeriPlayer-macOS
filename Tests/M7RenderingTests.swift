// M7RenderingTests.swift
// M7: render real native settings windows with isolated database/defaults and optional PNG evidence.

import AppKit
import SwiftUI
import XCTest
@testable import NeriPlayer

@MainActor
final class M7RenderingTests: XCTestCase {
    func testSyncSettingsRenderBothProvidersAtNativeWindowSizes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M7Rendering-\(UUID().uuidString)")
        let database = try DatabaseProvider(url: root.appendingPathComponent("library.sqlite"))
        try database.setupIfNeeded()
        let suite = "M7Rendering-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            if root.lastPathComponent.hasPrefix("M7Rendering-") { try? FileManager.default.removeItem(at: root) }
        }
        let settings = SettingsStore(userDefaults: defaults)
        let model = SyncViewModel(database: database, settings: settings,
            configurationStore: SyncConfigurationStore(settings: settings, credentials: OnlineMemoryCredentials()))
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 940),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SettingsView(viewModel: SettingsViewModel(settings: settings), syncViewModel: model))
        window.contentView = host
        window.title = "NeriPlayer M7 Settings Verification"
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for provider in SyncConfiguration.Provider.allCases {
            model.configuration.provider = provider
            let drawn = expectation(description: "native drawing")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { drawn.fulfill() }
            await fulfillment(of: [drawn], timeout: 3)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 10_000)
            if let path = ProcessInfo.processInfo.environment["NERIPLAYER_M7_CAPTURE_DIR"] {
                let destination = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try data.write(to: destination.appendingPathComponent("m7-\(provider.rawValue)-settings.png"))
            }
        }
    }
}
