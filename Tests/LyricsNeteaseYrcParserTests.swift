// LyricsNeteaseYrcParserTests.swift
// NeriPlayer macOS —— M4-T1：网易云 YRC 解析器单测。
//
// 用例来自原库 commonTest/parser/NeteaseYrcParserTest.kt（5 个 `@Test` → 5 个 `func testXxx`），
// 期望值一字未改；标注「（补充）」的是本移植新增的边界用例。
//
// 原库用 Kotlin 强转（`as KaraokeLine.MainKaraokeLine`）取行，Swift 里改成显式模式匹配：
// 强转失败在原库是测试崩溃，这里用 `guard case` + `XCTFail` 表达，失败信息更可读。

import XCTest
@testable import NeriPlayer

final class NeteaseYrcParserTests: XCTestCase {

    private let parser = NeteaseYrcParser()

    // MARK: 辅助：把「期望是一行主唱音节行」写成一个可复用的守卫

    /// 取出第 `index` 行并要求它是主唱音节行（原库 `as KaraokeLine.MainKaraokeLine`）。
    private func mainLine(
        _ lyrics: SyncedLyrics,
        at index: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> MainKaraokeLine? {
        guard index < lyrics.lines.count else {
            XCTFail("lines 只有 \(lyrics.lines.count) 行，取不到下标 \(index)", file: file, line: line)
            return nil
        }
        guard case .main(let line) = lyrics.lines[index] else {
            XCTFail("第 \(index) 行不是主唱音节行：\(lyrics.lines[index])", file: file, line: line)
            return nil
        }
        return line
    }

    // MARK: 原库用例

    func testCanDetectYrcFormat() {
        let content = """
        [12580,3470](12580,250,0)难(12830,300,0)以(13130,200,0)忘记
        """

        XCTAssertTrue(parser.canParse(content))
        XCTAssertFalse(parser.canParse("[00:12.58]难以忘记"))
        XCTAssertFalse(parser.canParse("[30348,198]<0,33,0>(<33,33,0>And"))
    }

    func testParsesAbsoluteTimedYrcSyllables() {
        let content = """
        [12580,3470](12580,250,0)难(12830,300,0)以(13130,200,0)忘记
        """

        let result = parser.parse(content)
        guard let line = mainLine(result, at: 0) else { return }
        XCTAssertEqual(result.lines.count, 1)

        XCTAssertEqual(line.syllables.count, 3)
        XCTAssertEqual(line.syllables[0].content, "难")
        XCTAssertEqual(line.syllables[0].start, 12580)
        XCTAssertEqual(line.syllables[0].end, 12830)
        XCTAssertEqual(line.syllables[2].content, "忘记")
        XCTAssertEqual(line.syllables[2].start, 13130)
        XCTAssertEqual(line.syllables[2].end, 13330)
    }

    func testRepairsMissingSpacesBetweenEnglishWordSyllables() {
        // 网易云 YRC 真实样本: 部分英文词吞掉词尾空格 (she/in) , 逐字拼接会粘连成 shegot/inthe
        let content = """
        [11490,4740](11490,120,0)And (11610,240,0)she(11850,360,0)got (12210,1020,0)older
        [9420,2000](9420,990,0)fairest (10410,180,0)in(10590,150,0)the (10740,450,0)land
        """

        let result = parser.parse(content)
        guard let first = mainLine(result, at: 0), let second = mainLine(result, at: 1) else { return }

        XCTAssertEqual(first.syllables.joinedContent, "And she got older")
        XCTAssertEqual(second.syllables.joinedContent, "fairest in the land")
    }

    func testKeepsCjkSyllablesTightlyJoinedWithoutInsertingSpaces() {
        // 中文逐字之间不能被插入空格
        let content = """
        [12580,3470](12580,250,0)难(12830,300,0)以(13130,200,0)忘记
        """

        let result = parser.parse(content)
        guard let line = mainLine(result, at: 0) else { return }

        XCTAssertEqual(line.syllables.joinedContent, "难以忘记")
    }

    func testParsesRelativeTimedYrcSyllables() {
        let content = """
        [1000,600](0,180,0)We(180,180,0) glow(360,240,0) now
        """

        let result = parser.parse(content)
        guard let line = mainLine(result, at: 0) else { return }

        XCTAssertEqual(line.start, 1000)
        XCTAssertEqual(line.end, 1600)
        XCTAssertEqual(line.syllables[0].content, "We")
        XCTAssertEqual(line.syllables[0].start, 1000)
        XCTAssertEqual(line.syllables[0].end, 1180)
        XCTAssertEqual(line.syllables[1].content, " glow")
        XCTAssertEqual(line.syllables[2].content, " now")
    }

    // MARK: 原库边界（原测试没覆盖，但实现里有明确分支）

    func testCanParseRejectsLineWithTimingButNoSyllables() {
        // 补充：行头是 YRC 形状，但内容里没有 `(start,duration,...)` 逐字块 → 整份否决。
        XCTAssertFalse(parser.canParse("[12580,3470]难以忘记"))
    }

    func testLineHeaderWithoutSyllablesDegradesToSyncedLine() {
        // 补充：原库 parseLine 里「rawSyllables 为空 → 退化成 SyncedLine」那条分支。
        let result = parser.parse("[12580,3470]难以忘记")
        XCTAssertEqual(result.lines.count, 1)
        guard case .synced(let line) = result.lines[0] else {
            XCTFail("没有逐字块时应退化成逐行对齐的 SyncedLine，实际：\(result.lines[0])")
            return
        }
        XCTAssertEqual(line.content, "难以忘记")
        XCTAssertEqual(line.start, 12580)
        XCTAssertEqual(line.end, 16050)
        XCTAssertNil(line.translation)
    }

    func testBlankLineWithNoSyllablesIsDropped() {
        // 补充：退化分支里正文去空白后为空 → 整行丢弃（parseLine 返回 nil）。
        let result = parser.parse("[12580,3470]   ")
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testJsonCreditLinesAreIgnored() {
        // 补充：新版歌词接口会在开头塞 JSON 版权行，原库靠 `startsWith("{")` 跳过。
        let content = """
        {"tlyric":{"lyric":"ignored"}}
        [12580,3470](12580,250,0)难(12830,300,0)以
        """

        let result = parser.parse(content)
        XCTAssertEqual(result.lines.count, 1)
        guard let line = mainLine(result, at: 0) else { return }
        XCTAssertEqual(line.syllables.joinedContent, "难以")
    }

    func testSyllableWithoutParsableTimeIsSkipped() {
        // 补充：逐字块时间解析不出 Int 时只丢该块，其余块正常保留（与 SYL 的 Error 退化口径不同）。
        let content = "[1000,600](0,180,0)We(99999999999999999999,180,0)glow(360,240,0) now"

        let result = parser.parse(content)
        guard let line = mainLine(result, at: 0) else { return }

        XCTAssertEqual(line.syllables.count, 2)
        XCTAssertEqual(line.syllables.joinedContent, "We now")
    }

    func testLineHeaderWithUnparsableDurationIsDropped() {
        // 补充：行头时长溢出 Int 时整行丢弃（Int(x) 对溢出返回 nil，与 toIntOrNull() 一致）。
        let result = parser.parse("[1000,99999999999999999999](1000,180,0)We")
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testLineEndTakesLaterOfHeaderAndSyllables() {
        // 补充：行头时长比逐字块更短时，行尾取更晚的那个（maxOf(lineEnd, last.end)）。
        let content = "[1000,100](1000,180,0)We"

        let result = parser.parse(content)
        guard let line = mainLine(result, at: 0) else { return }

        XCTAssertEqual(line.start, 1000)
        XCTAssertEqual(line.end, 1180)
    }

    func testPunctuationBoundaryIsNotPaddedWithSpace() {
        // 补充：补空格只发生在「ASCII 词字符 → ASCII 词字符」的边界；
        // 标点（`,`/`'`）与 CJK 都不算词字符，不能被塞空格。
        let content = "[1000,1000](1000,100,0)Hello,(1100,100,0)world(1200,100,0)!"

        let result = parser.parse(content)
        guard let line = mainLine(result, at: 0) else { return }

        XCTAssertEqual(line.syllables.joinedContent, "Hello,world!")
    }

    func testNonBreakingSpaceBoundaryIsNotPadded() {
        // 补充：补格谓词除了「边界字符不是空白」还要求「边界字符是 ASCII 词字符」。
        // U+2007(FIGURE SPACE)/U+202F 这类非换行空白过不了后半条，所以不补格 —— 这一点在
        // 两种空白语义下结论相同：Java 的 `Character.isWhitespace` 对它们是 false，
        // Swift 的 `Character.isWhitespace` 是 true，但它们永远不是 ASCII 词字符，
        // 因此「直接用 Swift 的 isWhitespace」与参考实现等价（差异不可观测）。
        let content = "[1000,1000](1000,180,0)in\u{2007}(1180,180,0)the"

        let result = parser.parse(content)
        guard let line = mainLine(result, at: 0) else { return }

        XCTAssertEqual(line.syllables[0].content, "in\u{2007}")
        XCTAssertEqual(line.syllables.joinedContent, "in\u{2007}the")

        // 真正的补格只发生在「ASCII 词字符 → ASCII 词字符」的边界上
        let ascii = parser.parse("[1000,1000](1000,100,0)in(1100,100,0)the")
        XCTAssertEqual(mainLine(ascii, at: 0)?.syllables[0].content, "in ")
    }
}
