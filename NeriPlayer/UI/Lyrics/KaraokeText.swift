// KaraokeText.swift
// M4-T5: native shaped text layout with per-syllable clipped highlighting.
import AppKit
import SwiftUI

struct KaraokeText: NSViewRepresentable {
    let syllables: [KaraokeSyllable]
    let time: Int
    let focused: Bool
    let fontSize: Double
    var alignment: KaraokeAlignment = .start
    @Environment(\.colorScheme) private var colorScheme
    /// 统一字体设置（需求 5）。逐字高亮在 AppKit 侧排字，必须自己把歌词字体解析成 NSFont：
    /// 环境值一变，SwiftUI 会重新调用 updateNSView，字体随设置即时生效。
    @Environment(\.appTypography) private var typography

    /// 解析到真实 NSFont。逐字高亮一直是半粗体，所以不走 `lyricNSFont`（常规字重），
    /// 而是直接复用 `AppTypography.resolve` 的三级家族解析，保持既有字重不变。
    private func resolvedFont() -> NSFont {
        AppTypography.resolve(family: typography.lyricsFontFamily, points: fontSize, weight: .semibold)
            ?? NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    }

    func makeNSView(context: Context) -> KaraokeTextView { KaraokeTextView() }

    func updateNSView(_ view: KaraokeTextView, context: Context) {
        view.configure(syllables: syllables, fontSize: fontSize, alignment: alignment,
                       accent: NSColor(Color.accentColor), dark: colorScheme == .dark,
                       font: resolvedFont())
        view.update(time: time, focused: focused)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: KaraokeTextView, context: Context) -> CGSize? {
        nsView.measure(width: max(1, proposal.width ?? 600))
    }
}

final class KaraokeTextView: NSView {
    private let storage = NSTextStorage()
    private let accentStorage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let accentLayout = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private let accentContainer = NSTextContainer(size: .zero)
    private var syllables: [KaraokeSyllable] = []
    private var ranges: [NSRange] = []
    private var rectangles: [[CGRect]] = []
    private var fontSize: Double = 0
    private var alignment = KaraokeAlignment.start
    private var accent = NSColor.controlAccentColor
    private var dark = false
    private var font = NSFont.systemFont(ofSize: 0, weight: .semibold)
    private var measuredWidth: CGFloat = -1
    private var measuredSize = CGSize.zero
    private var currentTime = 0
    private var focused = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        accentStorage.addLayoutManager(accentLayout)
        accentLayout.addTextContainer(accentContainer)
        container.lineFragmentPadding = 0
        accentContainer.lineFragmentPadding = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(syllables: [KaraokeSyllable], fontSize: Double, alignment: KaraokeAlignment,
                   accent: NSColor, dark: Bool, font: NSFont) {
        guard self.syllables != syllables || self.fontSize != fontSize || self.alignment != alignment
                || self.accent != accent || self.dark != dark || self.font != font else { return }
        self.syllables = syllables
        self.fontSize = fontSize
        self.alignment = alignment
        self.accent = accent
        self.dark = dark
        self.font = font
        var text = ""
        ranges = []
        for syllable in syllables {
            let start = text.utf16.count
            text += syllable.content
            ranges.append(NSRange(location: start, length: syllable.content.utf16.count))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 4
        paragraph.alignment = alignment == .end ? .right : .left
        let foreground = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.45)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground, .paragraphStyle: paragraph
        ]
        storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        var highlighted = attributes
        highlighted[.foregroundColor] = accent
        accentStorage.setAttributedString(NSAttributedString(string: text, attributes: highlighted))
        setAccessibilityLabel(text)
        measuredWidth = -1
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func update(time: Int, focused: Bool) {
        guard currentTime != time || self.focused != focused else { return }
        currentTime = time
        self.focused = focused
        needsDisplay = true
    }

    func measure(width: CGFloat) -> CGSize {
        guard width != measuredWidth else { return measuredSize }
        measuredWidth = width
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        accentContainer.containerSize = container.containerSize
        layout.ensureLayout(for: container)
        accentLayout.ensureLayout(for: accentContainer)
        measuredSize = CGSize(width: width, height: max(1, ceil(layout.usedRect(for: container).maxY)))
        rectangles = ranges.map { range in
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var result: [CGRect] = []
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in result.append(rect) }
            return result
        }
        return measuredSize
    }

    override func draw(_ dirtyRect: NSRect) {
        _ = measure(width: max(1, bounds.width))
        let glyphs = layout.glyphRange(for: container)
        layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        guard focused, let context = NSGraphicsContext.current?.cgContext else { return }
        var clips: [CGRect] = []
        for (index, syllable) in syllables.enumerated() {
            guard rectangles.indices.contains(index) else { continue }
            let rects = rectangles[index]
            let width = rects.reduce(CGFloat.zero) { $0 + $1.width }
            var remaining = width * CGFloat(syllable.progress(current: currentTime))
            for rect in rects {
                let highlighted = min(rect.width, remaining)
                if highlighted > 0 {
                    clips.append(CGRect(x: rect.minX, y: rect.minY, width: highlighted, height: rect.height))
                }
                remaining -= highlighted
            }
        }
        guard !clips.isEmpty else { return }
        context.saveGState()
        context.clip(to: clips)
        accentLayout.drawGlyphs(forGlyphRange: accentLayout.glyphRange(for: accentContainer), at: .zero)
        context.restoreGState()
    }
}
