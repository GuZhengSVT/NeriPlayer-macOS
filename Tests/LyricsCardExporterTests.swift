// LyricsCardExporterTests.swift
// M4-T6: deterministic AppKit lyric-card export tests.

import AppKit
import ImageIO
import XCTest
@testable import NeriPlayer

@MainActor
final class LyricsCardExporterTests: XCTestCase {
    func testPNGHasExact1080PixelWidthAndDynamicHeight() throws {
        let data = try LyricsCardExporter.pngData(
            title: "Song",
            artist: "Artist",
            lines: [line("第一行", translation: "translation")]
        )
        let size = try imagePixelSize(data)
        XCTAssertEqual(size.width, 1_080)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testPNGIsNonEmptyAndDecodable() throws {
        let data = try LyricsCardExporter.pngData(
            title: "Song",
            artist: nil,
            lines: [line("hello world")],
            showTranslation: false
        )
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(data.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertNotNil(CGImageSourceCreateWithData(data as CFData, nil))
    }

    func testLongTextWrapsWithoutChangingWidth() throws {
        let longText = String(repeating: "这是一段用于验证歌词卡片长句自动换行的文本。 ", count: 24)
        let shortData = try LyricsCardExporter.pngData(title: "Song", artist: nil, lines: [line("short")])
        let longData = try LyricsCardExporter.pngData(title: "Song", artist: nil, lines: [line(longText)])
        let shortSize = try imagePixelSize(shortData)
        let longSize = try imagePixelSize(longData)
        XCTAssertEqual(longSize.width, 1_080)
        XCTAssertGreaterThan(longSize.height, shortSize.height)
    }

    func testOneThroughSixLinesAreAccepted() throws {
        for count in 1...6 {
            let lines = (0..<count).map { line("歌词第 \($0 + 1) 行") }
            let data = try LyricsCardExporter.pngData(title: "Song", artist: nil, lines: lines)
            XCTAssertEqual(try imagePixelSize(data).width, 1_080)
        }
    }

    func testZeroAndSevenLinesAreRejected() {
        XCTAssertThrowsError(try LyricsCardExporter.pngData(title: "Song", artist: nil, lines: [])) { error in
            XCTAssertEqual(error as? LyricsCardExporterError, .invalidLineCount)
        }
        let sevenLines = (0..<7).map { line("歌词第 \($0 + 1) 行") }
        XCTAssertThrowsError(try LyricsCardExporter.pngData(title: "Song", artist: nil, lines: sevenLines)) { error in
            XCTAssertEqual(error as? LyricsCardExporterError, .invalidLineCount)
        }
    }

    func testEmptySelectedLineIsRejected() {
        XCTAssertThrowsError(
            try LyricsCardExporter.pngData(title: "Song", artist: nil, lines: [line(" \n")])
        ) { error in
            XCTAssertEqual(error as? LyricsCardExporterError, .emptyLyricLine)
        }
    }

    func testSaveWritesPNGToURL() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-card-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try LyricsCardExporter.save(
            title: "Song",
            artist: "Artist",
            lines: [line("歌词")],
            to: url
        )

        let data = try Data(contentsOf: url)
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(try imagePixelSize(data).width, 1_080)
    }

    private func line(_ content: String, translation: String? = nil) -> LyricsLine {
        .synced(SyncedLine(content: content, translation: translation, start: 0, end: 1_000))
    }

    private func imagePixelSize(_ data: Data) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("PNG should decode as an image")
            throw TestError.invalidImage
        }
        return (image.width, image.height)
    }

    private enum TestError: Error {
        case invalidImage
    }
}
