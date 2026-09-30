// LyricsEnhancedLrcTests.swift
// NeriPlayer macOS —— M4-T1：Enhanced LRC 解析器/导出器单测。
//
// 来源：accompanist-lyrics-core/src/commonTest/.../parser/
//   EnhancedLrcParserTest.kt   → EnhancedLrcParserTests（7 条 golden case）
//   LrcParserTest.kt           → LrcParserTests（2 条 golden case）
//   CompressedTimestampTest.kt → CompressedTimestampTests（4 条 golden case）
//
// 一个 Kotlin @Test 对应一个 func testXxx，期望值一字不改；文末带「（补充）」的用例是
// 移植后新增的边界（原库没有对应测试），只覆盖原实现确实会走到、但 golden case 没碰的分支：
// 方括号音节、v1/v2 对齐继承、canParse、LrcExporter。
//
// 强转的写法：原库 `result.lines[i] as SyncedLine` 在 Swift 里用
// `guard case .synced(let line) = … else { return XCTFail(…) }`；失败信息里带上下标，
// 断言失败时能直接看出是哪一行类型不符。

import XCTest
@testable import NeriPlayer

// MARK: - 公共工具

/// Kotlin `"""…""".trimIndent().split("\n")` 的等价物。
///
/// Swift 的 `split` 默认丢掉所有空串，而 Kotlin 的 `split("\n")`（limit = 0）只丢"尾部"空串；
/// 导出器产出的文本以 "\n" 结尾，这里必须和 Kotlin 一样把结尾那一个空串去掉，
/// 否则会多出一行"空行输入"（解析器虽然会过滤掉，但行号语义就不一致了）。
private func lrcLines(_ text: String) -> [String] {
    var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    while parts.last?.isEmpty == true {
        parts.removeLast()
    }
    return parts
}

// MARK: - EnhancedLrcParserTest.kt

final class EnhancedLrcParserTests: XCTestCase {

    func testBilingualLrcPairsOriginalWithTranslation() {
        let lrc = lrcLines("""
            [00:10.00]English line one
            [00:10.00]中文第一行
            [00:13.00]English line two
            [00:13.00]中文第二行
            """)

        let data = EnhancedLrcParser().parse(lrc)

        XCTAssertEqual(data.lines.count, 2)
        guard case .synced(let first) = data.lines[0],
              case .synced(let second) = data.lines[1] else {
            return XCTFail("同时间戳的原文/译文应解析成 SyncedLine")
        }
        XCTAssertEqual(first.content, "English line one")
        XCTAssertEqual(first.translation, "中文第一行")
        XCTAssertEqual(second.content, "English line two")
        XCTAssertEqual(second.translation, "中文第二行")
    }

    func testCreditLineDoesNotStealTranslationOnSharedTimestamp() {
        // 制作信息行与第一句正文共享时间戳; 修复前 credit 会窃取第一句英文做译文, 导致整体错位一行
        let lrc = lrcLines("""
            [00:15.00]作词 : Anson Seabra
            [00:15.00]I've been on the low
            [00:15.00]我一直很低落
            [00:18.00]Keep your head up
            [00:18.00]抬起头来
            """)

        let data = EnhancedLrcParser().parse(lrc)

        XCTAssertEqual(data.lines.count, 3)
        guard case .synced(let credit) = data.lines[0],
              case .synced(let firstLyric) = data.lines[1],
              case .synced(let secondLyric) = data.lines[2] else {
            return XCTFail("全普通行应解析成 SyncedLine")
        }
        XCTAssertEqual(credit.content, "作词 : Anson Seabra")
        XCTAssertNil(credit.translation)
        XCTAssertEqual(firstLyric.content, "I've been on the low")
        XCTAssertEqual(firstLyric.translation, "我一直很低落")
        XCTAssertEqual(secondLyric.content, "Keep your head up")
        XCTAssertEqual(secondLyric.translation, "抬起头来")
    }

    func testCreditOnlyLyricsProduceNoFalseTranslation() {
        let lrc = lrcLines("""
            [00:00.00]作词 : Someone
            [00:00.00]作曲 : Someone
            [00:15.00]Only English here
            [00:18.00]Another english line
            """)

        let data = EnhancedLrcParser().parse(lrc)

        XCTAssertEqual(data.lines.count, 4)
        for (index, line) in data.lines.enumerated() {
            guard case .synced(let synced) = line else {
                return XCTFail("第 \(index) 行应为 SyncedLine")
            }
            XCTAssertNil(synced.translation)
        }
    }

    func testParseBgWithTranslation() {
        let lrc = lrcLines("""
            [00:10.00]<00:10.00>Main <00:10.50>Lyrics<00:10.70>
            [00:10.00]主歌词翻译
            [bg: <00:10.00>Back<00:10.50>ground<00:11.00>]
            [bg: <00:10.00>背景音翻译<00:11.00>]
            """)

        let data = EnhancedLrcParser().parse(lrc)

        XCTAssertEqual(data.lines.count, 1)
        guard case .main(let line) = data.lines[0] else {
            return XCTFail("带 [bg:…] 的行应解析成 MainKaraokeLine")
        }
        XCTAssertEqual(line.translation, "主歌词翻译")

        guard let bg = line.accompanimentLines?.first else {
            return XCTFail("伴奏行应挂在主唱行上")
        }
        XCTAssertEqual(bg.syllables.joinedContent.trimmingCharacters(in: .whitespacesAndNewlines), "Background")
        XCTAssertEqual(bg.translation, "背景音翻译")
    }

    func testELRCRoundTrip() {
        let lrc = lrcLines("""
            [ti:Test Title]
            [00:01.00]<00:01.00>Hello <00:02.00>World<00:02.50>
            [00:01.00]你好世界
            [bg: <00:01.50>Chorus<00:02.00>]
            [bg: <00:01.50>合唱<00:02.00>]
            """)

        let parsed = EnhancedLrcParser().parse(lrc)
        let exported = EnhancedLrcExporter().export(parsed)

        let reParsed = EnhancedLrcParser().parse(lrcLines(exported))

        XCTAssertEqual(parsed.lines.count, reParsed.lines.count)
        guard case .main(let p1) = parsed.lines[0],
              case .main(let p2) = reParsed.lines[0] else {
            return XCTFail("带音节的行往返后应仍是 MainKaraokeLine")
        }

        XCTAssertEqual(p1.translation, p2.translation)
        XCTAssertEqual(p1.accompanimentLines?.count, p2.accompanimentLines?.count)
        XCTAssertEqual(p1.accompanimentLines?.first?.translation, p2.accompanimentLines?.first?.translation)
    }

    func testOutOfOrderTimestampsDoNotThrowAndKeepOtherLines() {
        // 乱序时间戳 (第二行早于第一行) 修复前会让 rearrangeUncheckedLineTime 产生 end < start
        // 触发 SyncedLine 的 require(end>=start) 抛异常, 导致 AutoParser/parse 失败, 整份歌词被丢弃
        // 修复后应容错解析并保留全部行, 异常行的时长被钳制为非负
        let lrc = lrcLines("""
            [01:00.00]Later line
            [00:30.00]Earlier line
            [01:30.00]Final line
            """)

        let data = EnhancedLrcParser().parse(lrc)

        XCTAssertEqual(data.lines.count, 3)
        guard case .synced(let first) = data.lines[0],
              case .synced(let second) = data.lines[1],
              case .synced(let third) = data.lines[2] else {
            return XCTFail("普通行应解析成 SyncedLine")
        }
        XCTAssertEqual(first.content, "Later line")
        XCTAssertEqual(second.content, "Earlier line")
        XCTAssertEqual(third.content, "Final line")
        // 乱序行的 end 被钳制为不小于 start, 时长非负, 不再触发构造异常
        XCTAssertGreaterThanOrEqual(first.duration, 0)
        XCTAssertGreaterThanOrEqual(first.end, first.start)
    }

    func testModelConstructionToleratesEndBeforeStart() {
        // 直接验证模型层去掉硬 require 后的容错: end < start 不再抛异常, 时长钳制为 0
        let synced = SyncedLine(content: "malformed", translation: nil, start: 200, end: 100)
        XCTAssertEqual(synced.duration, 0)

        let main = MainKaraokeLine(
            syllables: [KaraokeSyllable(content: "x", start: 100, end: 200)],
            translation: nil,
            alignment: .unspecified,
            start: 200,
            end: 100
        )
        XCTAssertEqual(main.duration, 0)

        let accompaniment = AccompanimentKaraokeLine(
            syllables: [KaraokeSyllable(content: "y", start: 100, end: 200)],
            translation: nil,
            alignment: .unspecified,
            start: 200,
            end: 100
        )
        XCTAssertEqual(accompaniment.duration, 0)
    }

    // MARK: （补充）

    func testCanParseRequiresLineTimestamp() {
        // canParse 只认「两位分:两位秒.2~3位毫秒」的行时间戳；1 位毫秒 / 1 位分都不算。
        XCTAssertTrue(EnhancedLrcParser().canParse("[00:12.34]lyric"))
        XCTAssertTrue(EnhancedLrcParser().canParse("[00:12.345]lyric"))
        XCTAssertFalse(EnhancedLrcParser().canParse("[00:12.3]lyric"))
        XCTAssertFalse(EnhancedLrcParser().canParse("[0:12.34]lyric"))
        XCTAssertFalse(EnhancedLrcParser().canParse("just a plain line"))
    }

    func testSquareBracketKaraokeSyllables() {
        // （补充）"坏"卡拉OK写法：音节时间戳用方括号，靠 detectBracketType 走 SQUARE 分支。
        // 注意这是原库的实际行为：`Hel` 在第一个方括号音节标签之前，不属于任何音节（被丢弃），
        // 而第二个 `[00:12.34]` 与第一个一样被当成"前导行时间戳"，所以会展开成 2 行。
        let lrc = lrcLines("[00:12.34][00:12.34]Hel[00:12.60]lo [00:12.90]World")

        let data = EnhancedLrcParser().parse(lrc)

        XCTAssertEqual(data.lines.count, 2)
        guard case .main(let first) = data.lines[0] else {
            return XCTFail("方括号音节应解析成 MainKaraokeLine")
        }
        XCTAssertEqual(first.syllables.joinedContent, "lo World")
        XCTAssertEqual(first.start, 12_600)
        XCTAssertEqual(first.syllables[0].start, 12_600)
        XCTAssertEqual(first.syllables[1].start, 12_900)
        XCTAssertEqual(first.end, 12_900)
    }

    func testVoiceAlignmentInheritedByAccompaniment() {
        // （补充）`v1:`/`v2:` 决定主唱行的对齐方式；伴奏行自身是 Unspecified，
        // 由 rearrangeAccompanimentAlignment 继承"上一个主唱行"的对齐方式。
        let lrc = lrcLines("""
            [00:10.00]v1: <00:10.00>First<00:11.00>
            [bg:<00:10.00>Bg<00:11.00>]
            [00:12.00]v2: <00:12.00>Second<00:13.00>
            [bg:<00:12.00>Bg2<00:13.00>]
            """)

        let data = EnhancedLrcParser().parse(lrc)

        XCTAssertEqual(data.lines.count, 2)
        guard case .main(let first) = data.lines[0],
              case .main(let second) = data.lines[1] else {
            return XCTFail("带音节的行应解析成 MainKaraokeLine")
        }
        XCTAssertEqual(first.alignment, .start)
        XCTAssertEqual(first.accompanimentLines?.first?.alignment, .start)
        XCTAssertEqual(second.alignment, .end)
        XCTAssertEqual(second.accompanimentLines?.first?.alignment, .end)
    }
}

// MARK: - LrcParserTest.kt

final class LrcParserTests: XCTestCase {

    func testStandardLrcWithTranslation() {
        let lrc = lrcLines("""
            [ti:Song Title]
            [ar:Artist Name]
            [00:01.00]Line 1
            [00:01.00]Translation 1
            [00:02.50]Line 2
            """)

        let result = EnhancedLrcParser().parse(lrc)
        XCTAssertEqual(result.title, "Song Title")
        XCTAssertEqual(result.lines.count, 2)

        guard case .synced(let line1) = result.lines[0] else {
            return XCTFail("标准 LRC 应解析成 SyncedLine")
        }
        XCTAssertEqual(line1.content, "Line 1")
        XCTAssertEqual(line1.translation, "Translation 1")
    }

    func testLRCRoundTrip() {
        let original = """
            [ti:Round Trip]
            [00:05.00]Hello
            [00:05.00]你好
            [00:10.00]World
            """

        let parsed = EnhancedLrcParser().parse(lrcLines(original))
        let exported = EnhancedLrcExporter().export(parsed)

        let reParsed = EnhancedLrcParser().parse(lrcLines(exported))

        XCTAssertEqual(parsed.title, reParsed.title)
        XCTAssertEqual(parsed.lines.count, reParsed.lines.count)
        guard case .synced(let p1) = parsed.lines[0],
              case .synced(let p2) = reParsed.lines[0] else {
            return XCTFail("标准 LRC 往返后应仍是 SyncedLine")
        }
        XCTAssertEqual(p1.translation, p2.translation)
    }

    // MARK: （补充）

    func testLrcExporterRoundTripKeepsHeaderAndArtists() {
        // （补充）LrcExporter 的往返：头部标签与艺术家列表。原库的 golden case 只覆盖
        // EnhancedLrcExporter，这里补上标准导出器。
        //
        // 注意这条用例钉的是原库的**有损**行为：`LrcExporter.kt` 只写
        // `artists.joinToString("/") { it.name }`，`type` 直接丢弃；所以
        // `[ar:A:甲/B:乙]` 导出后是 `[ar:甲/乙]`，再解析回来的角色退化成 "Main"
        // （`EnhancedLrcParser.kt` 里只有恰好切出两段才认角色）。不改产品代码去"修"它 ——
        // 改了就和参考实现的字节输出不一致了。
        let original = lrcLines("""
            [ti:Round Trip]
            [ar:A:甲/B:乙]
            [00:05.00]Hello
            [00:05.00]你好
            [00:10.00]World
            """)

        let parsed = EnhancedLrcParser().parse(original)
        XCTAssertEqual(parsed.title, "Round Trip")
        XCTAssertEqual(parsed.artists?.count, 2)
        XCTAssertEqual(parsed.artists?[0].type, "A")
        XCTAssertEqual(parsed.artists?[0].name, "甲")
        XCTAssertEqual(parsed.artists?[1].type, "B")
        XCTAssertEqual(parsed.artists?[1].name, "乙")

        let exported = LrcExporter().export(parsed)
        XCTAssertTrue(exported.contains("[ti:Round Trip]"))
        // 原库导出器只写姓名，角色信息会被丢弃：`[ar:A:甲/B:乙]` → `[ar:甲/乙]`
        XCTAssertTrue(exported.contains("[ar:甲/乙]"))

        let reParsed = EnhancedLrcParser().parse(lrcLines(exported))
        XCTAssertEqual(reParsed.title, parsed.title)
        // 姓名与顺序能回来，type 退化成 "Main"（原库行为，不是缺陷修复目标）
        XCTAssertEqual(reParsed.artists?.map(\.name), parsed.artists?.map(\.name))
        XCTAssertEqual(reParsed.artists?.map(\.type), ["Main", "Main"])
        XCTAssertEqual(reParsed.lines.count, parsed.lines.count)
    }

    func testLrcExporterFlattensKaraokeAndBackground() {
        // （补充）标准 LRC 没有音节/伴奏：导出时卡拉OK行折算成逐行对齐行，[bg:…] 整条丢掉。
        let lrc = lrcLines("""
            [00:10.00]<00:10.00>Main <00:10.50>Lyrics<00:10.70>
            [bg:<00:10.00>Back<00:10.50>]
            """)

        let parsed = EnhancedLrcParser().parse(lrc)
        let exported = LrcExporter().export(parsed)

        XCTAssertFalse(exported.contains("<"))
        XCTAssertFalse(exported.contains("[bg:"))
        XCTAssertTrue(exported.contains("[00:10.000]Main Lyrics"))
    }
}

// MARK: - CompressedTimestampTest.kt

final class CompressedTimestampTests: XCTestCase {

    func testLrcCompressedTimestamps() {
        let lrc = lrcLines("""
            [00:12.50][01:30.20][02:15.00]这里是一句重复的副歌歌词
            """)

        let result = EnhancedLrcParser().parse(lrc)
        // EnhancedLrcParser maps standard LRC to SyncedLine
        XCTAssertEqual(result.lines.count, 3)

        guard case .synced(let line0) = result.lines[0],
              case .synced(let line1) = result.lines[1],
              case .synced(let line2) = result.lines[2] else {
            return XCTFail("压缩时间戳的普通行应解析成 SyncedLine")
        }

        XCTAssertEqual(line0.start, 12_500)
        XCTAssertEqual(line0.content, "这里是一句重复的副歌歌词")

        XCTAssertEqual(line1.start, 90_200)
        XCTAssertEqual(line1.content, "这里是一句重复的副歌歌词")

        XCTAssertEqual(line2.start, 135_000)
        XCTAssertEqual(line2.content, "这里是一句重复的副歌歌词")
    }

    func testEnhancedLrcCompressedTimestamps() {
        let lrc = lrcLines("""
            [00:10.00][00:30.00]<00:00.00>Main <00:00.50>Lyrics<00:00.70>
            """)

        let result = EnhancedLrcParser().parse(lrc)
        XCTAssertEqual(result.lines.count, 2)

        guard case .main(let line1) = result.lines[0],
              case .main(let line2) = result.lines[1] else {
            return XCTFail("带音节的行应解析成 MainKaraokeLine")
        }
        XCTAssertEqual(line1.start, 10_000)
        XCTAssertEqual(line1.syllables.joinedContent, "Main Lyrics")
        XCTAssertEqual(line1.syllables[0].start, 10_000)
        XCTAssertEqual(line1.syllables[1].start, 10_500)

        XCTAssertEqual(line2.start, 30_000)
        XCTAssertEqual(line2.syllables.joinedContent, "Main Lyrics")
        XCTAssertEqual(line2.syllables[0].start, 30_000)
        XCTAssertEqual(line2.syllables[1].start, 30_500)
    }

    func testEnhancedLrcMixedAbsoluteCompressed() {
        // [00:10.00] with absolute <00:10.00>
        let lrc = lrcLines("""
            [00:10.00][00:30.00]<00:10.00>Main <00:10.50>Lyrics<00:10.70>
            """)

        let result = EnhancedLrcParser().parse(lrc)
        XCTAssertEqual(result.lines.count, 2)

        guard case .main(let line1) = result.lines[0],
              case .main(let line2) = result.lines[1] else {
            return XCTFail("带音节的行应解析成 MainKaraokeLine")
        }
        XCTAssertEqual(line1.start, 10_000)
        XCTAssertEqual(line1.syllables[0].start, 10_000)
        XCTAssertEqual(line1.syllables[1].start, 10_500)

        XCTAssertEqual(line2.start, 30_000)
        XCTAssertEqual(line2.syllables[0].start, 30_000)
        XCTAssertEqual(line2.syllables[1].start, 30_500)
    }

    func testEnhancedLrcCompressedWithBg() {
        let lrc = lrcLines("""
            [00:10.00][00:30.00][bg:<00:10.00>Back<00:10.50>]<00:00.00>Main <00:00.50>Lyrics<00:00.70>
            """)

        let result = EnhancedLrcParser().parse(lrc)
        // Should have 2 main lines, each with the background line attached
        XCTAssertEqual(result.lines.count, 2)

        guard case .main(let line1) = result.lines[0],
              case .main(let line2) = result.lines[1] else {
            return XCTFail("带 [bg:…] 的压缩时间戳行应解析成 MainKaraokeLine")
        }
        XCTAssertEqual(line1.accompanimentLines?.count, 1)
        XCTAssertEqual(line1.accompanimentLines?.first?.syllables.first?.content, "Back")

        XCTAssertEqual(line2.accompanimentLines?.count, 1)
        XCTAssertEqual(line2.accompanimentLines?.first?.syllables.first?.content, "Back")
    }

    // MARK: （补充）

    func testCompressedTimestampsShareTheSameTranslationPairing() {
        // （补充）压缩时间戳展开出的多行彼此时间差很大，不会被误当成彼此的译文；
        // 与原文同时间戳的译文行只配给对应的那一行。
        let lrc = lrcLines("""
            [00:10.00][00:30.00]Repeat
            [00:10.00]重复
            [00:30.00]重复
            """)

        let result = EnhancedLrcParser().parse(lrc)

        XCTAssertEqual(result.lines.count, 2)
        guard case .synced(let first) = result.lines[0],
              case .synced(let second) = result.lines[1] else {
            return XCTFail("全普通行应解析成 SyncedLine")
        }
        XCTAssertEqual(first.content, "Repeat")
        XCTAssertEqual(first.translation, "重复")
        XCTAssertEqual(second.content, "Repeat")
        XCTAssertEqual(second.translation, "重复")
    }
}
