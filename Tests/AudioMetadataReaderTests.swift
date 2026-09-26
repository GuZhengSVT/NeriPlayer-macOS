// AudioMetadataReaderTests.swift
// NeriPlayer macOS —— M2-T1：音频元数据读取测试。
//
// 素材不走本机音乐库，全部是 Tests/Fixtures/Audio/ 下提交入库的小样本
// （由 Tools/generate-audio-fixtures.sh 从系统提示音 Tink.aiff 转码生成，
// 详见该脚本头注释）。经 Package.swift 的 .copy 进入测试 bundle，
// 这里用 Bundle.module 取真实文件路径 —— TagLib 需要路径读取。
//
// 断言口径：
//   - 标签样本：五个格式都断言 title/artist/album 三个字段读对；
//   - duration：素材约 0.56s，有损编码有 padding，故用区间而非等值断言；
//   - 封面：mp3/flac/m4a 内嵌了封面，断言解码出的字节非空且是 PNG；
//   - 兜底：无标签样本走文件名，文件不存在返回 nil 且不崩溃。

import XCTest
@testable import NeriPlayer

final class AudioMetadataReaderTests: XCTestCase {

    // 与 Tools/generate-audio-fixtures.sh 中的标签常量保持一致。
    private static let expectedTitle = "Fixture Title"
    private static let expectedArtist = "Fixture Artist"
    private static let expectedAlbum = "Fixture Album"

    /// 系统提示音 Tink.aiff 时长 0.564s；各编码器会加少量 padding，
    /// 用 [0.3, 1.5] 的宽松区间吸收差异，只验证「时长确实读出来了」。
    private static let durationRange: ClosedRange<TimeInterval> = 0.3...1.5

    private func fixtureURL(_ name: String, extension ext: String) throws -> URL {
        let url = Bundle.module.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "Audio"
        )
        return try XCTUnwrap(url, "缺少测试素材 \(name).\(ext)，请先运行 Tools/generate-audio-fixtures.sh")
    }

    // MARK: - 五格式标签读取

    /// mp3/flac/m4a/ogg/wav 五个标签样本：三个文本字段 + 格式标识 + 时长都要对。
    func testReadsTagsForAllSupportedFormats() throws {
        struct Case {
            let fileExtension: String
            let format: AudioFormat
        }
        let cases = [
            Case(fileExtension: "mp3", format: .mp3),
            Case(fileExtension: "flac", format: .flac),
            Case(fileExtension: "m4a", format: .m4a),
            Case(fileExtension: "ogg", format: .ogg),
            Case(fileExtension: "wav", format: .wav)
        ]

        for testCase in cases {
            let ext = testCase.fileExtension
            let url = try fixtureURL("tagged", extension: ext)
            let metadata = try XCTUnwrap(
                AudioMetadataReader.readMetadata(at: url),
                "标签样本 \(ext) 应能读出模型"
            )

            XCTAssertEqual(metadata.title, Self.expectedTitle, "\(ext) title")
            XCTAssertEqual(metadata.artist, Self.expectedArtist, "\(ext) artist")
            XCTAssertEqual(metadata.album, Self.expectedAlbum, "\(ext) album")
            XCTAssertEqual(metadata.format, testCase.format, "\(ext) 格式标识")
            XCTAssertEqual(metadata.url, url)
            XCTAssertGreaterThan(metadata.fileSize, 0, "\(ext) 文件大小应大于 0")

            let duration = try XCTUnwrap(metadata.duration, "\(ext) 应读出时长")
            XCTAssertTrue(
                Self.durationRange.contains(duration),
                "\(ext) 时长 \(duration) 应落在 \(Self.durationRange)"
            )
        }
    }

    /// mp3/flac/m4a 内嵌了 PNG 封面：断言解出的字节非空且确实是 PNG。
    ///
    /// ogg 样本按脚本说明不嵌封面（ffmpeg 的 ogg 复用器不收 PNG 流），
    /// 故不在此列 —— 这是素材侧限制，不是读取器行为差异。
    func testReadsEmbeddedCoverForFormatsThatSupportIt() throws {
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])

        for ext in ["mp3", "flac", "m4a"] {
            let url = try fixtureURL("tagged", extension: ext)
            let metadata = try XCTUnwrap(AudioMetadataReader.readMetadata(at: url))
            let cover = try XCTUnwrap(metadata.coverImage, "\(ext) 应读出内嵌封面")
            XCTAssertFalse(cover.isEmpty, "\(ext) 封面字节不应为空")
            XCTAssertTrue(
                cover.starts(with: pngMagic),
                "\(ext) 封面应是 PNG（生成脚本用 ffmpeg 写的就是 PNG）"
            )
        }
    }

    // MARK: - 兜底

    /// 无标签 WAV：三个文本字段读不到，title 回落为去扩展名的文件名，
    /// duration 与 fileSize 仍要有值（满足「读不到元数据也要给兜底」）。
    func testUntaggedFileFallsBackToFileNameAndStillReportsDurationAndSize() throws {
        let url = try fixtureURL("untagged", extension: "wav")
        let metadata = try XCTUnwrap(AudioMetadataReader.readMetadata(at: url))

        XCTAssertEqual(metadata.title, "untagged")
        XCTAssertNil(metadata.artist, "单段文件名不应凭空造出 artist")
        XCTAssertNil(metadata.album)
        XCTAssertEqual(metadata.format, .wav)
        XCTAssertGreaterThan(metadata.fileSize, 0)
        let duration = try XCTUnwrap(metadata.duration)
        XCTAssertTrue(Self.durationRange.contains(duration))
    }

    /// 「Artist - Title」型文件名（无标签）：去扩展名后按 " - " 拆出两个字段。
    func testFileNameFallbackSplitsArtistAndTitle() throws {
        let url = try fixtureURL("Fallback Artist - Fallback Title", extension: "wav")
        let metadata = try XCTUnwrap(AudioMetadataReader.readMetadata(at: url))

        XCTAssertEqual(metadata.title, "Fallback Title")
        XCTAssertEqual(metadata.artist, "Fallback Artist")
        XCTAssertNil(metadata.album)
    }

    // MARK: - 异常路径

    /// 不存在的文件：返回 nil，不抛异常、不崩溃。
    func testMissingFileReturnsNilWithoutCrashing() {
        let missing = URL(fileURLWithPath: "/tmp/neriplayer-does-not-exist-\(UUID().uuidString).mp3")
        XCTAssertNil(AudioMetadataReader.readMetadata(at: missing))
    }

    /// 目录不是音频文件，同样按「不可读」处理返回 nil。
    func testDirectoryReturnsNil() {
        XCTAssertNil(AudioMetadataReader.readMetadata(at: URL(fileURLWithPath: "/tmp")))
    }

    /// 存在但内容不是音频：不抛异常，仍返回模型，title 走文件名兜底，
    /// 只有 fileSize 确定（duration 允许为 nil）。
    func testNonAudioFileStillReturnsFallbackModel() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("neriplayer-not-audio-\(UUID().uuidString).flac")
        try Data("this is definitely not a flac stream".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try XCTUnwrap(AudioMetadataReader.readMetadata(at: url))
        XCTAssertEqual(metadata.format, .flac)
        XCTAssertEqual(metadata.title, url.deletingPathExtension().lastPathComponent)
        XCTAssertGreaterThan(metadata.fileSize, 0)
    }

    // MARK: - 文件名解析边界

    /// 多段文件名：首段当 artist，其余用 " - " 拼回 title，标题内的连字符不被截断。
    func testFileNameParserKeepsMultiSegmentTitleIntact() {
        let parsed = FilenameMetadataParser.parse(fileName: "Artist - Title - With - Dashes.mp3")
        XCTAssertEqual(parsed.artist, "Artist")
        XCTAssertEqual(parsed.title, "Title - With - Dashes")
    }

    /// 空段被丢弃，不产出空字符串字段。规则：拆分后「非空段」不足两段时
    /// 只认 title、不认 artist（单段文件名不可能是 artist-title 结构）。
    func testFileNameParserDropsBlankSegments() {
        let leadingBlank = FilenameMetadataParser.parse(fileName: " - Title.wav")
        XCTAssertEqual(leadingBlank.title, "Title")
        XCTAssertNil(leadingBlank.artist, "只剩一段时不猜 artist")

        // "Artist -  - Title"：两个分隔符相邻，中间段为空，应被丢掉。
        let middleBlank = FilenameMetadataParser.parse(fileName: "Artist -  - Title.wav")
        XCTAssertEqual(middleBlank.artist, "Artist")
        XCTAssertEqual(middleBlank.title, "Title", "空段丢掉后剩余段成为 title")
    }

    /// 无扩展名 / 全空白文件名：不崩溃，返回空解析结果。
    func testFileNameParserHandlesDegenerateNames() {
        XCTAssertEqual(FilenameMetadataParser.parse(fileName: ""), .init(title: nil, artist: nil))
        XCTAssertNil(FilenameMetadataParser.parse(fileName: "   ").title)
        XCTAssertEqual(FilenameMetadataParser.parse(fileName: "solo").title, "solo")
    }
}
