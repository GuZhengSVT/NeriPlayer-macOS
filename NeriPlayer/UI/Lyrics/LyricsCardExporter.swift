// LyricsCardExporter.swift
// M4-T6: deterministic 1080px PNG lyric-card renderer.

import AppKit
import Foundation

/// Errors raised while creating a lyric card.
public enum LyricsCardExporterError: Error, LocalizedError, Equatable {
    /// The caller must pass the selected one through six lyric lines.
    case invalidLineCount
    /// A selected line has no visible lyric text after trimming whitespace.
    case emptyLyricLine
    /// AppKit could not allocate the bitmap used for rendering.
    case bitmapCreationFailed
    /// AppKit could not encode the rendered bitmap as PNG.
    case pngEncodingFailed
    case cardTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidLineCount:
            return "歌词卡片必须包含 1 到 6 行歌词"
        case .emptyLyricLine:
            return "歌词行不能为空"
        case .bitmapCreationFailed:
            return "无法创建歌词卡片位图"
        case .pngEncodingFailed:
            return "无法编码歌词卡片 PNG"
        case .cardTooLarge:
            return "选中的歌词过长，请减少导出内容"
        }
    }
}

/// Renders the selected lyric lines to a fixed-width PNG card.
///
/// AppKit is used deliberately here instead of SwiftUI `ImageRenderer`: this API has
/// deterministic bitmap dimensions in XCTest and does not depend on a SwiftUI view
/// hierarchy, window, or display backing scale. Since rendering touches AppKit, the
/// whole API is isolated to the main actor.
@MainActor
public enum LyricsCardExporter {
    public static let pixelWidth = 1_080
    public static let minimumLineCount = 1
    public static let maximumLineCount = 6

    // Validation and drawing form one deterministic rendering transaction.
    // swiftlint:disable cyclomatic_complexity
    /// Renders a card with exactly 1080 output pixels across and a content-derived height.
    ///
    /// The first selected line is emphasized in green; all other lyric text is black.
    /// Translation is rendered beneath each line when `showTranslation` is true.
    public static func pngData(
        title: String,
        artist: String?,
        lines: [LyricsLine],
        showTranslation: Bool = true
    ) throws -> Data {
        guard (minimumLineCount...maximumLineCount).contains(lines.count) else {
            throw LyricsCardExporterError.invalidLineCount
        }

        guard title.utf8.count <= 16_384, (artist?.utf8.count ?? 0) <= 16_384,
              lines.allSatisfy({ $0.content.utf8.count <= 16_384 && ($0.translation?.utf8.count ?? 0) <= 16_384 }) else {
            throw LyricsCardExporterError.cardTooLarge
        }
        let displayLines = try lines.map { line -> DisplayLine in
            let content = line.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { throw LyricsCardExporterError.emptyLyricLine }
            let translation = showTranslation
                ? line.translation?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            return DisplayLine(content: content, translation: translation)
        }

        let width = CGFloat(pixelWidth)
        let inset: CGFloat = 80
        let textWidth = width - inset * 2
        let titleFont = NSFont.systemFont(ofSize: 42, weight: .bold)
        let artistFont = NSFont.systemFont(ofSize: 24, weight: .regular)
        let lyricFont = NSFont.systemFont(ofSize: 34, weight: .semibold)
        let translationFont = NSFont.systemFont(ofSize: 23, weight: .regular)
        let footerFont = NSFont.systemFont(ofSize: 18, weight: .regular)
        let paragraph = paragraphStyle

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = trimmedTitle.isEmpty ? "NeriPlayer" : trimmedTitle
        let cleanArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleHeight = measuredHeight(cleanTitle.isEmpty ? " " : cleanTitle, font: titleFont, width: textWidth, paragraph: paragraph)
        let artistHeight = cleanArtist.map { measuredHeight($0, font: artistFont, width: textWidth, paragraph: paragraph) } ?? 0
        let footerHeight = measuredHeight("NeriPlayer", font: footerFont, width: textWidth, paragraph: paragraph)

        // All values are points and the bitmap is intentionally allocated at the same
        // dimensions. No NSScreen scale is consulted, so 1 point is exactly 1 PNG pixel.
        var height: CGFloat = 56 + titleHeight
        if artistHeight > 0 { height += 12 + artistHeight }
        height += 46
        for line in displayLines {
            height += measuredHeight(line.content, font: lyricFont, width: textWidth, paragraph: paragraph)
            if let translation = line.translation, !translation.isEmpty {
                height += 10 + measuredHeight(translation, font: translationFont, width: textWidth, paragraph: paragraph)
            }
            height += 28
        }
        height += 44 + footerHeight + 28
        guard height.isFinite, height <= 12_000 else { throw LyricsCardExporterError.cardTooLarge }
        let pixelHeight = max(1, Int(ceil(height)))

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw LyricsCardExporterError.bitmapCreationFailed
        }
        representation.size = NSSize(width: width, height: CGFloat(pixelHeight))

        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: representation) else {
            throw LyricsCardExporterError.bitmapCreationFailed
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer {
            graphicsContext.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        }

        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: CGFloat(pixelHeight))).fill()

        let black = NSColor(calibratedWhite: 0.04, alpha: 1)
        let mutedBlack = NSColor(calibratedWhite: 0.38, alpha: 1)
        let green = NSColor(calibratedRed: 0.08, green: 0.60, blue: 0.30, alpha: 1)
        var y = CGFloat(pixelHeight) - 56
        draw(cleanTitle.isEmpty ? "NeriPlayer" : cleanTitle, atTop: &y, font: titleFont, color: black, width: textWidth, paragraph: paragraph)
        if let cleanArtist, !cleanArtist.isEmpty {
            y -= 12
            draw(cleanArtist, atTop: &y, font: artistFont, color: mutedBlack, width: textWidth, paragraph: paragraph)
        }
        y -= 46

        for (index, line) in displayLines.enumerated() {
            draw(line.content, atTop: &y, font: lyricFont, color: index == 0 ? green : black, width: textWidth, paragraph: paragraph)
            if let translation = line.translation, !translation.isEmpty {
                y -= 10
                draw(translation, atTop: &y, font: translationFont, color: mutedBlack, width: textWidth, paragraph: paragraph)
            }
            y -= 28
        }

        y = 28 + footerHeight
        draw("NeriPlayer", atTop: &y, font: footerFont, color: mutedBlack, width: textWidth, paragraph: paragraph)

        guard let data = representation.representation(using: .png, properties: [:]), !data.isEmpty else {
            throw LyricsCardExporterError.pngEncodingFailed
        }
        Log.ui.debug("歌词卡片已编码：\(pixelWidth)x\(pixelHeight)")
        return data
    }

    // swiftlint:enable cyclomatic_complexity

    /// Renders and atomically writes a PNG card to `url`.
    public static func save(
        title: String,
        artist: String?,
        lines: [LyricsLine],
        showTranslation: Bool = true,
        to url: URL
    ) throws {
        let data = try pngData(title: title, artist: artist, lines: lines, showTranslation: showTranslation)
        try data.write(to: url, options: .atomic)
    }

    private struct DisplayLine {
        let content: String
        let translation: String?
    }

    private static var paragraphStyle: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 0
        return paragraph
    }

    private static func measuredHeight(
        _ text: String,
        font: NSFont,
        width: CGFloat,
        paragraph: NSParagraphStyle
    ) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph]
        )
        return max(1, ceil(rect.height))
    }

    // Keep rendering coordinates, typeface and color explicit.
    // swiftlint:disable:next function_parameter_count
    private static func draw(
        _ text: String,
        atTop y: inout CGFloat,
        font: NSFont,
        color: NSColor,
        width: CGFloat,
        paragraph: NSParagraphStyle
    ) {
        let height = measuredHeight(text, font: font, width: width, paragraph: paragraph)
        let rect = NSRect(x: 80, y: y - height, width: width, height: height)
        text.draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
        y -= height
    }
}
