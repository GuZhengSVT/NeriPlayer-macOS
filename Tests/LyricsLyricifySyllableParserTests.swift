// LyricsLyricifySyllableParserTests.swift
// NeriPlayer macOS —— M4-T1：Lyricify Syllable（LYS）解析器单测。
//
// 用例来自原库 commonTest/parser/LyricifySyllableParserTest.kt（7 个 `@Test` → 7 个 `func testXxx`），
// 期望值一字未改；标注「（补充）」的是本移植新增的边界用例。
//
// 原库用 Kotlin 强转（`as KaraokeLine` / `as KaraokeLine.MainKaraokeLine`）取行，Swift 里改成
// 显式模式匹配（`if case` / `guard case`）：强转失败在原库是测试崩溃，这里用 XCTFail 表达，
// 失败信息更可读，也不会把「行类型不对」和「下标越界」混成同一个崩溃。

import XCTest
@testable import NeriPlayer

final class LyricifySyllableParserTests: XCTestCase {

    private let parser = LyricifySyllableParser()

    // MARK: 辅助

    /// 取出第 `index` 行并要求它是主唱音节行（原库 `data.lines[i] as KaraokeLine.MainKaraokeLine`）。
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

    /// 取出第 `index` 行的伴奏行数组（非主唱行返回空）。
    private func accompanimentLines(_ lyrics: SyncedLyrics, at index: Int) -> [AccompanimentKaraokeLine] {
        guard index < lyrics.lines.count, case .main(let line) = lyrics.lines[index] else { return [] }
        return line.accompanimentLines ?? []
    }

    // MARK: 原库用例

    func testParseLyricifySyllable() {
        let lys = [
            "[4]I (0,214)promise (214,345)that (559,185)you'll (744,154)never (898,334)find (1232,202)another (1434,470)like (1904,363)me(2267,658)",
            "[4]I (3476,185)know (3661,150)that (3811,161)I'm (3972,184)a (4156,155)handful, (4311,672)baby, (4983,672)uh(5655,401)"
        ]
        let data = parser.parse(lys)

        XCTAssertEqual(data.lines.count, 2)

        // 验证第一行
        guard let firstLine = mainLine(data, at: 0) else { return }
        XCTAssertEqual(firstLine.syllables.count, 9)
        XCTAssertEqual(firstLine.syllables[0].content, "I ")
        XCTAssertEqual(firstLine.syllables[0].start, 0)
        XCTAssertEqual(firstLine.syllables[0].end, 214)
        XCTAssertEqual(firstLine.syllables[1].content, "promise ")
        XCTAssertEqual(firstLine.syllables[1].start, 214)
        XCTAssertEqual(firstLine.syllables[1].end, 559)

        // 验证第二行
        guard let secondLine = mainLine(data, at: 1) else { return }
        XCTAssertEqual(secondLine.syllables.count, 8)
        XCTAssertEqual(secondLine.syllables[0].content, "I ")
        XCTAssertEqual(secondLine.syllables[0].start, 3476)
        XCTAssertEqual(secondLine.syllables[0].end, 3661)
    }

    func testParseWithDifferentAttributes() {
        let lys = [
            "[2]Start (0,100)aligned (100,200)line(200,300)",
            "[4]End (400,100)aligned (500,200)line(600,300)",
            "[8]Background (800,100)vocals(900,200)"
        ]
        let data = parser.parse(lys)

        XCTAssertEqual(data.lines.count, 2)

        // Validate KaraokeAlignment
        guard let firstLine = mainLine(data, at: 0), let secondLine = mainLine(data, at: 1) else { return }
        XCTAssertEqual(firstLine.alignment, .end)
        XCTAssertEqual(secondLine.alignment, .start)
        let accompaniment = accompanimentLines(data, at: 1)
        XCTAssertEqual(accompaniment.first?.alignment, .end)

        // Validate types（前两行是主唱行、第三行挂成伴奏行）
        XCTAssertEqual(data.lines.count, 2)
        XCTAssertEqual(accompaniment.count, 1)
        XCTAssertEqual(accompaniment.first?.syllables.joinedContent, "Background vocals")
    }

    func testParseWithoutAttributes() {
        let lys = ["Hello (0,100)world(100,200)"]
        let data = parser.parse(lys)

        XCTAssertEqual(data.lines.count, 1)
        guard let line = mainLine(data, at: 0) else { return }
        XCTAssertEqual(line.syllables.count, 2)
        XCTAssertEqual(line.alignment, .start)
    }

    func testParseEmptyLine() {
        let lys = [""]
        let data = parser.parse(lys)

        XCTAssertEqual(data.lines.count, 0)
    }

    func testParseWithSpecialCharacters() {
        let lys = ["[4]Hello, (0,100)world! (100,200)How (200,150)are (350,100)you?(450,200)"]
        let data = parser.parse(lys)

        XCTAssertEqual(data.lines.count, 1)
        guard let line = mainLine(data, at: 0) else { return }
        XCTAssertEqual(line.syllables.count, 5)
        XCTAssertEqual(line.syllables[0].content, "Hello, ")
        XCTAssertEqual(line.syllables[1].content, "world! ")
        XCTAssertEqual(line.syllables[2].content, "How ")
        XCTAssertEqual(line.syllables[3].content, "are ")
        XCTAssertEqual(line.syllables[4].content, "you?")
    }

    func testParseWithMultipleLines() {
        let lys = [
            "[4]First (0,100)line(100,200)",
            "[2]Second (300,150)line(450,250)",
            "[5]Third (700,100)line(800,300)"
        ]
        let data = parser.parse(lys)

        XCTAssertEqual(data.lines.count, 3)

        // Validate time
        XCTAssertEqual(data.lines[0].start, 0)
        XCTAssertEqual(data.lines[0].end, 300)
        XCTAssertEqual(data.lines[1].start, 300)
        XCTAssertEqual(data.lines[1].end, 700)
        XCTAssertEqual(data.lines[2].start, 700)
        XCTAssertEqual(data.lines[2].end, 1100)
    }

    func testParseWithAccompanimentAttributes() {
        let lys = [
            "[6]Background (0,100)vocals(100,200)",
            "[7]Harmony (300,150)part(450,250)"
        ]
        let data = parser.parse(lys)

        XCTAssertEqual(data.lines.count, 2)
        // 首行没有可挂靠的主唱行，两个伴奏行都独立成行。
        for index in 0..<data.lines.count {
            guard case .accompaniment = data.lines[index] else {
                XCTFail("第 \(index) 行应为伴奏行：\(data.lines[index])")
                continue
            }
        }
    }

    // MARK: 补充

    func testCanParseRequiresLettersBeforeSyllableBlock() {
        // 补充：原库 canParse 的探测正则是「字母 + 可选空白 + (数字,数字)」，
        // 所以纯 CJK 逐字（没有拉丁字母）不会被它认领。
        XCTAssertTrue(parser.canParse("[4]I (0,214)promise (214,345)that"))
        XCTAssertFalse(parser.canParse("[4]难 (0,214)以(214,345)"))
        XCTAssertFalse(parser.canParse("[00:12.58]难以忘记"))
    }

    func testAttributeOutOfRangeBecomesAccompaniment() {
        // 补充：属性 `!in 0..5` 即伴奏（`[8]` 就是这条规则的典型受害者：
        // 下面 alignment 那一支虽然写着 `== 8`，但 8 已经被判成伴奏了）。
        let data = parser.parse(["[7]Harmony (0,100)part(100,200)"])

        XCTAssertEqual(data.lines.count, 1)
        guard case .accompaniment(let line) = data.lines[0] else {
            XCTFail("属性 7 应判成伴奏行：\(data.lines[0])")
            return
        }
        XCTAssertEqual(line.alignment, .start)
        XCTAssertEqual(line.syllables.joinedContent, "Harmony part")
    }

    func testAttributeWithLongerBracketSpanIsNotAnAttribute() {
        // 补充：`]` 与 `[` 下标相距 2 才算属性，`[42]`（相距 3）走无属性分支。
        let data = parser.parse(["[42]Text (0,100)here(100,200)"])

        XCTAssertEqual(data.lines.count, 1)
        guard let line = mainLine(data, at: 0) else { return }
        XCTAssertEqual(line.alignment, .start)
        // 无属性分支保留整行原文，所以首音节文本里带着 `[42]` 前缀。
        XCTAssertEqual(line.syllables[0].content, "[42]Text ")
    }

    func testAttributeLineIsRemovedByMetadataHelper() {
        // 补充：`[ti:…]` 这类已知标签行会被 LrcMetadataHelper.removeAttributes 整行剔除。
        let data = parser.parse(["[ti:Song]", "[4]Hello (0,100)world(100,200)"])

        XCTAssertEqual(data.lines.count, 1)
        guard let line = mainLine(data, at: 0) else { return }
        XCTAssertEqual(line.syllables.joinedContent, "Hello world")
    }

    func testWhitespaceOnlyLinesAreSkipped() {
        // 补充：原库判的是 `isNotBlank()`，纯空白行（非空串）也要跳过。
        let data = parser.parse(["   ", "\t", "[4]Hello (0,100)world(100,200)"])
        XCTAssertEqual(data.lines.count, 1)
    }

    func testUnicodeDigitsThatIntCannotParseDegradeToErrorSyllable() {
        // 补充：阿拉伯-印度数字 ٠（U+0660）在 isDigitsOnly 下算数字（Unicode 语义，与原库
        // `Char.isDigit()` 一致），但 `Int(...)` 解析不出，于是退化成 Error 音节 —— 与原库一致。
        // 若把 isDigitsOnly 写成 `"0"..."9"` 的 ASCII 区间判断，这个音节同样会退化成 Error，
        // 只是走另一条分支；所以这里锁定的是"Unicode 数字最终退化成 Error"这一可观察结果。
        let data = parser.parse(["[4]I (\u{0660},100)promise(100,200)"])

        XCTAssertEqual(data.lines.count, 1)
        guard let line = mainLine(data, at: 0) else { return }
        XCTAssertEqual(line.syllables.count, 2)
        XCTAssertEqual(line.syllables[0].content, "Error")
        XCTAssertEqual(line.syllables[0].start, 0)
        XCTAssertEqual(line.syllables[0].end, 0)
        XCTAssertEqual(line.syllables[1].content, "promise")
        XCTAssertEqual(line.syllables[1].start, 100)
        XCTAssertEqual(line.syllables[1].end, 300)
    }

    func testUnicodeDigitsInsideDurationAlsoDegradeToError() {
        // 补充：时长段同样是 Unicode 数字语义（第二个捕获组走同一个 isDigitsOnly 判断）。
        let data = parser.parse(["[4]I (0,\u{0660})promise(100,200)"])

        XCTAssertEqual(data.lines.count, 1)
        guard let line = mainLine(data, at: 0) else { return }
        XCTAssertEqual(line.syllables.count, 2)
        XCTAssertEqual(line.syllables[0].content, "Error")
        XCTAssertEqual(line.syllables[1].content, "promise")
    }

    func testAccompanimentAfterAccompanimentStaysStandalone() {
        // 补充：上一行不是主唱行时，伴奏行独立成行（原库 `data.last()` 分支的 else）。
        let data = parser.parse([
            "[7]First harmony (0,100)part(100,200)",
            "[7]Second harmony (300,100)part(400,200)"
        ])

        XCTAssertEqual(data.lines.count, 2)
        guard case .accompaniment = data.lines[0], case .accompaniment = data.lines[1] else {
            XCTFail("两行都应是独立的伴奏行：\(data.lines)")
            return
        }
    }
}
