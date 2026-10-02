// FloatingLyricsPanel.swift
// M8-T2/T5: always-on-top, draggable, click-through single-line lyric panel.
import AppKit
import Combine
import SwiftUI

final class FloatingLyricsPanelController {
    private var panel: NSPanel?
    private weak var model: LyricsViewModel?
    /// 面板高度跟随「底部歌词字号」（需求 5）：字号调大后单行歌词仍能完整显示。
    /// 面板创建后不会因为设置变化被重建，所以这里订阅歌词模型并同步调整 frame。
    private var cancellable: AnyCancellable?

    @MainActor
    func toggle(model: LyricsViewModel) {
        if let panel {
            if panel.isVisible { hide() } else { show() }
            return
        }
        self.model = model
        let content = FloatingLyricsContent(model: model)
        let height = Self.panelHeight(for: model.compactFontSize)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: content)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        self.panel = panel
        observeCompactFontSize()
        show()
    }

    /// 面板高度：单行歌词 + 上下留白。下限 72pt 保证小字号时胶囊仍有正常厚度。
    private static func panelHeight(for compactFontSize: Double) -> CGFloat {
        max(72, CGFloat(compactFontSize) + 44)
    }

    /// 跟随「底部歌词字号」调整面板高度。只在值真的变化时改 frame，
    /// 避免把「自己写出去的值」再回灌成一次多余的布局。
    @MainActor
    private func observeCompactFontSize() {
        guard let model else { return }
        cancellable = model.$compactFontSize
            .dropFirst()
            .sink { size in
                // Combine 的回调不在主线程隔离上下文里，改 AppKit frame 要显式跳回主 actor。
                Task { @MainActor [weak self] in self?.resizePanel(for: size) }
            }
    }

    @MainActor
    private func resizePanel(for compactFontSize: Double) {
        guard let panel else { return }
        var frame = panel.frame
        let height = Self.panelHeight(for: compactFontSize)
        guard abs(frame.height - height) > 0.5 else { return }
        // 面板贴底显示：向上生长，保持底边不动。
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
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

    /// 悬浮歌词是独立 NSPanel，拿不到主窗口注入的环境值，因此就地从歌词模型拼一份排版值：
    /// 用完整版歌词字号与字体家族，只把字号换成「底部歌词字号」。
    private var typography: AppTypography {
        AppTypography(
            uiScale: 1,
            compactLyricsSize: CGFloat(model.compactFontSize),
            uiFontFamily: TypographyFontFamily.systemID,
            lyricsFontFamily: model.fontFamily,
            lyricsBaseSize: CGFloat(model.fontSize)
        )
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            Text(model.currentLyricText)
                .font(typography.lyricFont(size: typography.compactLyricsSize, weight: .semibold))
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
