// PlayerCommands.swift
// M8-T8: standard app-wide playback key equivalents.
import SwiftUI

struct PlayerCommands: Commands {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("播放") {
            Button("播放 / 暂停") { appState.playbackStore?.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
            Button("上一首") { appState.playbackStore?.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            Button("下一首") { appState.playbackStore?.next(force: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
        }
        CommandGroup(replacing: .appInfo) {
            Button("关于 NeriPlayer") { openWindow(id: "about") }
        }
        CommandMenu("帮助") {
            Button("打开诊断信息") { openWindow(id: "diagnostics") }
        }
    }
}
