// FloatingLyricsPanel.swift
// M8-T2/T5: always-on-top, draggable, click-through single-line lyric panel.
import AppKit
import SwiftUI

final class FloatingLyricsPanelController {
    private var panel: NSPanel?
    private weak var model: LyricsViewModel?

    @MainActor
    func toggle(model: LyricsViewModel) {
        if let panel {
            if panel.isVisible { hide() } else { show() }
            return
        }
        self.model = model
        let content = FloatingLyricsContent(model: model)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 72),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: content)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        self.panel = panel
        show()
    }

    @MainActor
    func hide() { panel?.orderOut(nil) }

    @MainActor
    func show() {
        guard let panel else { return }
        if panel.frame.origin == .zero, let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - panel.frame.width / 2
            let y = screen.visibleFrame.minY + 72
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
    }

    @MainActor
    func setClickThrough(_ enabled: Bool) { panel?.ignoresMouseEvents = enabled }
}

private struct FloatingLyricsContent: View {
    @ObservedObject var model: LyricsViewModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            Text(model.currentLyricText)
                .font(.system(size: min(32, max(18, model.fontSize)), weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(0.8), radius: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
        }
        .background(.black.opacity(0.18), in: Capsule())
        .padding(8)
    }
}
