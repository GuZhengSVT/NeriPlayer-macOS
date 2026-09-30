// LyricsAutoParserTests.swift
// NeriPlayer macOS —— M4-T1：`AutoParser` 的格式分流单测。
//
// 来源：`commonTest/.../parser/AutoParserTest.kt`（逐条对应，期望值不变）。
//
// 这份测试守的是「分流」而不是每种格式的解析细节 —— 后者已经在各自的解析器测试里逐字段
// 断言过了。所以这里每个格式只放一条能代表它特征的样本，重点确认：能不能被认出来、
// 认出来之后交给的是不是对的那个解析器（用行数/音节数/对齐方式这些"指纹"间接确认）。
//
// 酷狗那条的样本约 28KB，原库在 KugouParserTest 与 AutoParserTest 里各内嵌了一份，
// 这里收敛成共享 fixture `Tests/Fixtures/Lyrics/kugou-come-alive.krc`（Package.swift 的
// testTarget resources 以 `.copy("Fixtures/Lyrics")` 打进测试 bundle）。

import XCTest
@testable import NeriPlayer

final class AutoParserTests: XCTestCase {

    private func krcFixture(_ name: String = "kugou-come-alive") throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "krc", subdirectory: "Lyrics"),
            "缺少测试素材 \(name).krc"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 判定一行是不是逐行对齐（非音节）行。
    private func isSynced(_ line: LyricsLine) -> Bool {
        if case .synced = line { return true }
        return false
    }

    // MARK: 分流

    func testParseLrc() {
        let lrc = """
            [ti:Apt 22]
            [ar:Joesef/Barney Lister]
            [al:Permanent Damage (Explicit)]
            [00:25.50]You're on my mind
            [00:31.38]Sometimes I still wake up thinking you're by my side
            """
        let result = AutoParser().parse(lrc)
        XCTAssertTrue(result.lines.allSatisfy(isSynced), "普通 LRC 应当被解析成逐行歌词")
        XCTAssertEqual(result.lines.count, 2)
    }

    func testParseEnhancedLrc() throws {
        let enhancedLrc = [
            "[00:29.299]v1:<00:29.299>Baby <00:29.508>we're <00:29.811>far <00:30.992>from <00:31.217>perfect<00:31.817>",
            "[00:29.299]<00:29.299>宝贝 我们并不完美<00:32.310>",
            "[00:32.313]v2:<00:32.313>Oh <00:32.521>I <00:32.704>know <00:32.914>all <00:33.080>about <00:33.265>you<00:33.670>",
            "[00:32.313]<00:32.313>我对你了如指掌<00:33.940>",
            "[bg: <00:33.940>Background <00:34.200>vocals<00:34.500>]",
            "[00:33.940]<00:33.940>背景音<00:34.500>"
        ]

        let data = AutoParser().parse(enhancedLrc)

        XCTAssertEqual(data.lines.count, 2)

        // v1 的对齐方式与译文
        let v1Line = try XCTUnwrap(data.lines[0].karaokeLine as? MainKaraokeLine)
        XCTAssertEqual(v1Line.alignment, .start)
        XCTAssertEqual(v1Line.translation, "宝贝 我们并不完美")

        // v2 的对齐方式与译文
        let v2Line = try XCTUnwrap(data.lines[1].karaokeLine as? MainKaraokeLine)
        XCTAssertEqual(v2Line.alignment, .end)
        XCTAssertEqual(v2Line.translation, "我对你了如指掌")

        // bg 行跟随 v2 的 End 对齐，并且也拿到译文
        let bgLine = try XCTUnwrap(v2Line.accompanimentLines?.first)
        XCTAssertEqual(bgLine.alignment, .end)
        XCTAssertEqual(bgLine.translation, "背景音")
    }

    func testParseTtml() throws {
        let ttml = """
            <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
                <body><div>
                    <p begin="00:00.130" end="00:02.820">
                        <span begin="00:00.130" end="00:00.230">I</span> <span begin="00:00.230" end="00:00.450">promise</span>
                    </p>
                </div></body>
            </tt>
            """
        let result = AutoParser().parse(ttml)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(try XCTUnwrap(result.lines[0].karaokeLine).syllables.count, 2)
    }

    func testParseLyricifySyllable() throws {
        let lys = "[4]I (0,214)promise (214,345)that (559,185)you'll (744,154)never (898,334)find (1232,202)another (1434,470)like (1904,363)me(2267,658)"
        let result = AutoParser().parse(lys)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(try XCTUnwrap(result.lines[0].karaokeLine).syllables.count, 9)
    }

    func testParseUnknownFormat() {
        let result = AutoParser().parse("just some random text")
        XCTAssertEqual(result.lines.count, 0)
    }

    func testParseKugouKrc() throws {
        let result = AutoParser().parse(try krcFixture())

        // 100 行主歌词（译文由 [language:…] 里的 base64 元数据合并而来）
        XCTAssertEqual(result.lines.count, 100)

        let nineLine = try XCTUnwrap(result.lines[8].karaokeLine)
        let tenLine = try XCTUnwrap(result.lines[9].karaokeLine)
        let ninetyNineLine = try XCTUnwrap(result.lines[99].karaokeLine)

        XCTAssertEqual(
            nineLine.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
            "还能"
        )
        XCTAssertEqual(
            tenLine.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
            "抵抗多久？"
        )
        XCTAssertEqual(nineLine.syllables.first?.content, "How ")
        XCTAssertEqual(tenLine.syllables.first?.content, "Can ")
        XCTAssertEqual(
            ninetyNineLine.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
            "我们终将走出迷惘"
        )
        XCTAssertEqual(ninetyNineLine.syllables.count > 2 ? ninetyNineLine.syllables[2].content : nil, "make ")
    }

    // MARK: 分流顺序（补充）

    /// 显式传入自定义解析器列表时，顺序决定谁先拿到内容。
    func testCustomParserListOrderIsRespected() {
        struct AlwaysParser: LyricsParser {
            let marker: String
            func canParse(_ content: String) -> Bool { true }
            func parse(_ content: String) -> SyncedLyrics {
                SyncedLyrics(lines: [.synced(SyncedLine(content: marker, start: 0, end: 1))])
            }
        }

        let parser = AutoParser(parsers: [AlwaysParser(marker: "first"), AlwaysParser(marker: "second")])
        XCTAssertEqual(parser.parse("whatever").lines.first?.content, "first")
    }

    /// 显式传空列表：没有任何解析器，`canParse` 为假、解析结果是空歌词。
    func testEmptyParserListFallsBackToEmptyLyrics() {
        let parser = AutoParser(parsers: [])
        XCTAssertFalse(parser.canParse("[00:01.00]x"))
        XCTAssertEqual(parser.parse("[00:01.00]x").lines.count, 0)
    }
}
