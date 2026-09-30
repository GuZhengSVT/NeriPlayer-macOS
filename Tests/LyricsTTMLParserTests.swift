// LyricsTTMLParserTests.swift
// NeriPlayer macOS —— M4-T1 TTML 解析/导出的 golden 测试。
//
// 来源（只读参考）：
//   commonTest/parser/TTMLParserTest.kt（283 行，8 条）  → TTMLParserTests
//   commonTest/exporter/TTMLExporterTest.kt（19 行，1 条）→ TTMLExporterTests
//
// 一个 Kotlin `@Test` 对应一个 `func testXxx`，断言与期望值逐字保留；标「（补充）」的是原库
// 没有、这里补的边界用例。输入 TTML 也照搬（含缩进与换行 —— TTML 里 `<span>` 之间的空白是数据，
// 会变成音节的尾随空白），只做了两处不改语义的排版处理：
//   1. 超长 `<tt>` 标签在属性之间折行：标签内部的换行会被属性解析跳过，解析结果不变；
//   2. 原库里单行写死的 `<p>`（span 之间一旦有空白，音节内容就不再是 "Ka"/"ra"/"oke"）
//      用字符串拼接保持单行，同时不触发 SwiftLint 行宽告警。
//
// Kotlin `parse(ttml)` 里的 `.trimIndent()` 在这里由 Swift 多行字面量承担：闭定界符的缩进
// 就是「公共缩进」，两者对这几段样本的求值结果一致。

import XCTest
@testable import NeriPlayer

// MARK: - 假 PhoneticProvider

/// LINE 粒度的假 provider，固定返回 "Fallback"（对应原库测试里的匿名 object）。
private struct FakeLinePhoneticProvider: PhoneticProvider {
    var phoneticLevel: PhoneticLevel { .line }
    func getPhonetic(_ string: String) -> String { "Fallback" }
}

/// SYLLABLE 粒度的假 provider，固定返回 "Fallback"。
private struct FakeSyllablePhoneticProvider: PhoneticProvider {
    var phoneticLevel: PhoneticLevel { .syllable }
    func getPhonetic(_ string: String) -> String { "Fallback" }
}

/// LINE 粒度、回显输入的 provider：用来断言喂进去的是**整行**拼接文本（补充）。
private struct EchoLinePhoneticProvider: PhoneticProvider {
    var phoneticLevel: PhoneticLevel { .line }
    func getPhonetic(_ string: String) -> String { "[\(string)]" }
}

/// SYLLABLE 粒度、回显输入的 provider：用来断言喂进去的是**单个音节**（补充）。
private struct EchoSyllablePhoneticProvider: PhoneticProvider {
    var phoneticLevel: PhoneticLevel { .syllable }
    func getPhonetic(_ string: String) -> String { "[\(string)]" }
}

// MARK: - 解析器

final class TTMLParserTests: XCTestCase {

    // MARK: 原库 TTMLParserTest.kt 的 8 条 golden case

    func testNoFallbackWhenPhoneticExists() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
            <body><div>
                <p begin="00:00.000" end="00:01.000">
                    <span begin="00:00.000" end="00:01.000">Hello</span>
                    <span ttm:role="x-roman">Existing Phonetic</span>
                </p>
            </div></body>
        </tt>
        """

        let provider = FakeSyllablePhoneticProvider()
        let result = TTMLParser(fallbackPhoneticProvider: provider).parse(ttml)
        guard case .main(let line) = result.lines[0] else {
            return XCTFail("第 0 行应为 MainKaraokeLine")
        }

        // 已有行级注音：不覆盖，也不给音节补注音。
        XCTAssertEqual(line.phonetic, "Existing Phonetic")
        XCTAssertNil(line.syllables[0].phonetic)
    }

    func testNoFallbackWhenSyllablePhoneticExists() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" \
        xmlns:itunes="http://music.apple.com/lyric-ttml-internal">
            <head>
                <metadata>
                    <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
                        <transliterations>
                            <transliteration>
                                <text for="L1">
                                    <span begin="00:00.000" end="00:00.000">SyllablePhonetic</span>
                                </text>
                            </transliteration>
                        </transliterations>
                    </iTunesMetadata>
                </metadata>
            </head>
            <body><div>
                <p begin="00:00.000" end="00:01.000" itunes:key="L1">
                    <span begin="00:00.000" end="00:01.000">Hello</span>
                </p>
            </div></body>
        </tt>
        """

        let provider = FakeLinePhoneticProvider()
        let result = TTMLParser(fallbackPhoneticProvider: provider).parse(ttml)
        guard case .main(let line) = result.lines[0] else {
            return XCTFail("第 0 行应为 MainKaraokeLine")
        }

        // 已有音节级注音（来自 iTunes 音译表）：不给整行补注音。
        XCTAssertEqual(line.syllables[0].phonetic, "SyllablePhonetic")
        XCTAssertNil(line.phonetic)
    }

    func testBgPositioning() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
            <body><div>
                <p begin="00:01.000" end="00:05.000">
                    <span ttm:role="x-bg" begin="00:01.000" end="00:02.000">
                        <span begin="00:01.000" end="00:02.000">(Before)</span>
                    </span>
                    <span begin="00:02.000" end="00:03.000">Main</span>
                    <span ttm:role="x-bg" begin="00:03.000" end="00:04.000">
                        <span begin="00:03.000" end="00:04.000">(After)</span>
                    </span>
                </p>
            </div></body>
        </tt>
        """

        let result = TTMLParser().parse(ttml)
        XCTAssertEqual(result.lines.count, 1)

        guard case .main(let line) = result.lines[0] else {
            return XCTFail("第 0 行应为 MainKaraokeLine")
        }
        XCTAssertEqual(
            line.syllables.map(\.content).joined().trimmingCharacters(in: .whitespacesAndNewlines),
            "Main"
        )

        let bgs = try XCTUnwrap(line.accompanimentLines)
        XCTAssertEqual(bgs.count, 2)
        XCTAssertEqual(
            bgs[0].syllables.map(\.content).joined().trimmingCharacters(in: .whitespacesAndNewlines),
            "(Before)"
        )
        XCTAssertEqual(
            bgs[1].syllables.map(\.content).joined().trimmingCharacters(in: .whitespacesAndNewlines),
            "(After)"
        )
    }

    func testNestedTranslationAndSyllables() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
            <body><div>
                <p begin="00:10.000" end="00:15.000">
                    <span begin="00:10.000" end="00:11.000">Hello</span>
                    <span ttm:role="x-bg" begin="00:11.000" end="00:12.000">
                        <span begin="00:11.000" end="00:12.000">World</span>
                        <span ttm:role="x-translation">世界</span>
                    </span>
                    <span ttm:role="x-translation">你好</span>
                </p>
            </div></body>
        </tt>
        """

        let result = TTMLParser().parse(ttml)
        guard case .main(let line) = result.lines[0] else {
            return XCTFail("第 0 行应为 MainKaraokeLine")
        }
        // 主行译文取不带 x-bg 的那个 span（和声里的译文属于和声）。
        XCTAssertEqual(line.translation, "你好")

        let bg = try XCTUnwrap(line.accompanimentLines?.first)
        XCTAssertEqual(bg.translation, "世界")
        XCTAssertEqual(
            bg.syllables.first?.content.trimmingCharacters(in: .whitespacesAndNewlines),
            "World"
        )
    }

    func testLinePhonetic() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" \
        xmlns:tts="http://www.w3.org/ns/ttml#styling" xmlns:amll="http://www.example.com/ns/amll" \
        xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="None">
            <head>
                <metadata>
                    <ttm:agent type="person" xml:id="v1" />
                </metadata>
            </head>
            <body dur="00:00.000">
                <div begin="00:00.000" end="00:00.000">
                    <p begin="00:00.000" end="00:00.000" ttm:agent="v1" itunes:key="L1">
                        <span begin="00:00.000" end="00:00.000">Hello</span>
                        <span begin="00:00.000" end="00:00.000">World</span>
                        <span ttm:role="x-translation" xml:lang="zh-CN">你好世界</span>
                        <span ttm:role="x-roman">Halo Waludo</span>
                    </p>
                </div>
            </body>
        </tt>
        """

        let result = TTMLParser().parse(ttml)
        guard case .main(let line) = result.lines[0] else {
            return XCTFail("第 0 行应为 MainKaraokeLine")
        }
        XCTAssertEqual(line.phonetic, "Halo Waludo")
    }

    func testSyllablePhonetic() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" \
        xmlns:tts="http://www.w3.org/ns/ttml#styling" xmlns:amll="http://www.example.com/ns/amll" \
        xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="None">
            <head>
                <metadata>
                    <ttm:agent type="person" xml:id="v1" />
                    <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
                        <transliterations>
                            <transliteration>
                                <text for="L1">
                                    <span begin="00:00.000" end="00:00.000">Halo</span>
                                    <span begin="00:00.000" end="00:00.000">waludo</span>
                                </text>
                            </transliteration>
                        </transliterations>
                    </iTunesMetadata>
                </metadata>
            </head>
            <body dur="00:00.000">
                <div begin="00:00.000" end="00:00.000">
                    <p begin="00:00.000" end="00:00.000" ttm:agent="v1" itunes:key="L1">
                        <span begin="00:00.000" end="00:00.000">Hello</span>
                        <span begin="00:00.000" end="00:00.000">World</span>
                        <span ttm:role="x-translation" xml:lang="zh-CN">你好世界</span>
                    </p>
                </div>
            </body>
        </tt>
        """

        let result = TTMLParser().parse(ttml)
        guard case .main(let line) = result.lines[0] else {
            return XCTFail("第 0 行应为 MainKaraokeLine")
        }
        // 音译表与音节按顺序一一对应。
        XCTAssertEqual(line.syllables[0].phonetic, "Halo")
        XCTAssertEqual(line.syllables[1].phonetic, "waludo")
    }

    func testTTMLRoundTrip() throws {
        let originalTtml = """
        <tt xmlns="http://www.w3.org/ns/ttml" \
        xmlns:itunes="http://music.apple.com/lyric-ttml-internal" \
        xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word">
          <head>
            <metadata>
              <ttm:agent type="person" xml:id="v1"/>
              <ttm:agent type="person" xml:id="v2"/>
            </metadata>
          </head>
          <body dur="00:05.000">
            <div begin="00:01.000" end="00:05.000">
              <p begin="00:01.000" end="00:05.000" ttm:agent="v1">
                <span begin="00:01.000" end="00:02.000">Main</span>
                <span ttm:role="x-translation" xml:lang="zh-CN">主词</span>
                <span ttm:role="x-bg" begin="00:02.000" end="00:03.000">
                  <span begin="00:02.000" end="00:03.000">BG</span>
                  <span ttm:role="x-translation" xml:lang="zh-CN">背景</span>
                </span>
              </p>
            </div>
          </body>
        </tt>
        """

        let parsed = TTMLParser().parse(originalTtml)
        let exported = TTMLExporter().export(parsed)

        // 第二次解析确保数据一致性
        let reParsed = TTMLParser().parse(exported)
        XCTAssertEqual(parsed.lines.count, reParsed.lines.count)

        guard case .main(let p1) = parsed.lines[0], case .main(let p2) = reParsed.lines[0] else {
            return XCTFail("往返后的第 0 行应为 MainKaraokeLine")
        }

        XCTAssertEqual(p1.translation, p2.translation)
        XCTAssertEqual(p1.accompanimentLines?.count, p2.accompanimentLines?.count)
        XCTAssertEqual(p1.accompanimentLines?.first?.translation, p2.accompanimentLines?.first?.translation)
    }

    func testParseSyncedLineAndMixedLines() {
        // span 之间不能有空白，否则音节内容会变成 "Ka\n…"；原库也正是把它写成一行的。
        let karaokeParagraph = #"<p begin="00:02.000" end="00:05.000">"#
            + #"<span begin="00:02.000" end="00:03.000">Ka</span>"#
            + #"<span begin="00:03.000" end="00:04.000">ra</span>"#
            + #"<span begin="00:04.000" end="00:05.000">oke</span></p>"#

        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
            <body><div>
                <p begin="00:00.000" end="00:02.000">This is a regular synced line without syllables</p>
                \(karaokeParagraph)
                <p begin="00:05.000" end="00:07.000">Another synced line<span ttm:role="x-translation">Translation here</span></p>
            </div></body>
        </tt>
        """

        let result = TTMLParser().parse(ttml)
        let lines = result.lines

        XCTAssertEqual(lines.count, 3)

        guard case .synced(let synced0) = lines[0] else {
            return XCTFail("第 0 行应为 SyncedLine")
        }
        XCTAssertEqual(
            synced0.content.trimmingCharacters(in: .whitespacesAndNewlines),
            "This is a regular synced line without syllables"
        )
        XCTAssertEqual(lines[0].start, 0)
        XCTAssertEqual(lines[0].end, 2_000)

        guard case .main(let karaokeLine) = lines[1] else {
            return XCTFail("第 1 行应为 MainKaraokeLine")
        }
        XCTAssertEqual(karaokeLine.syllables.count, 3)
        XCTAssertEqual(karaokeLine.syllables[0].content, "Ka")
        XCTAssertEqual(karaokeLine.syllables[0].start, 2_000)
        XCTAssertEqual(karaokeLine.syllables[1].content, "ra")
        XCTAssertEqual(karaokeLine.syllables[1].start, 3_000)
        XCTAssertEqual(karaokeLine.syllables[2].content, "oke")
        XCTAssertEqual(karaokeLine.syllables[2].start, 4_000)

        guard case .synced(let synced2) = lines[2] else {
            return XCTFail("第 2 行应为 SyncedLine")
        }
        XCTAssertEqual(
            synced2.content.trimmingCharacters(in: .whitespacesAndNewlines),
            "Another synced line"
        )
        XCTAssertEqual(
            synced2.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
            "Translation here"
        )
    }

    // MARK: 补充边界（原库没有对应用例）

    func testCanParseDetectsTtmlNamespace() {
        // 判别特征就是命名空间 URL，不带它的歌词不该被 TTML 解析器接走。
        XCTAssertTrue(TTMLParser().canParse("<tt xmlns=\"http://www.w3.org/ns/ttml\"></tt>"))
        XCTAssertFalse(TTMLParser().canParse("[00:01.00]普通的 LRC 歌词"))
    }

    func testParseFromLinesAppliesTrimIndent() {
        // 覆盖 `parse(lines)` 分支：逐行去公共缩进后**无分隔符**拼接。
        let lines = [
            "    <tt xmlns=\"http://www.w3.org/ns/ttml\">",
            "        <body><div>",
            "            <p begin=\"00:00.000\" end=\"00:01.000\">Hello</p>",
            "        </div></body>",
            "    </tt>"
        ]

        let result = TTMLParser().parse(lines)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].content, "Hello")
    }

    func testCommentsAndProcessingInstructionsAreIgnored() {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- 这是注释 -->
        <tt xmlns="http://www.w3.org/ns/ttml">
            <body><div>
                <p begin="00:00.000" end="00:01.000">Hello</p>
            </div></body>
        </tt>
        """

        let result = TTMLParser().parse(ttml)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].content, "Hello")
    }

    func testXmlEntitiesAreDecoded() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml">
            <body><div>
                <p begin="00:00.000" end="00:01.000">A &amp; B &lt;C&gt;</p>
            </div></body>
        </tt>
        """

        let result = TTMLParser().parse(ttml)
        guard case .synced(let line) = result.lines[0] else {
            return XCTFail("第 0 行应为 SyncedLine")
        }
        XCTAssertEqual(line.content, "A & B <C>")
    }

    func testLineWithoutEndAttributeIsDropped() {
        // 缺 begin/end 的 <p> 整行丢掉；时间戳写错（parseAsTime 得 0）的行则保留。
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml">
            <body><div>
                <p begin="00:00.000">No end attribute</p>
                <p begin="00:01.000" end="00:02.000">Kept</p>
            </div></body>
        </tt>
        """

        let result = TTMLParser().parse(ttml)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].content, "Kept")
    }

    func testEqualStartTimesKeepDocumentOrder() {
        // sortedBy → 稳定排序：同 start 的行保持 XML 中出现顺序（Swift sorted 本身不保证稳定）。
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml">
            <body><div>
                <p begin="00:01.000" end="00:02.000">First</p>
                <p begin="00:01.000" end="00:03.000">Second</p>
            </div></body>
        </tt>
        """

        let result = TTMLParser().parse(ttml)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0].content, "First")
        XCTAssertEqual(result.lines[1].content, "Second")
    }

    func testFallbackLineLevelUsesJoinedSyllables() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml">
            <body><div>
                <p begin="00:00.000" end="00:01.000"><span begin="00:00.000" end="00:01.000">Hello</span></p>
            </div></body>
        </tt>
        """

        let result = TTMLParser(fallbackPhoneticProvider: EchoLinePhoneticProvider()).parse(ttml)
        guard case .main(let line) = result.lines[0] else {
            return XCTFail("第 0 行应为 MainKaraokeLine")
        }
        // LINE 粒度：输入是整行音节拼接文本，结果写在行级 phonetic 上。
        XCTAssertEqual(line.phonetic, "[Hello]")
        XCTAssertNil(line.syllables[0].phonetic)
    }

    func testFallbackSyllableLevelUsesEachSyllable() {
        let karaokeParagraph = #"<p begin="00:00.000" end="00:02.000">"#
            + #"<span begin="00:00.000" end="00:01.000">Ka</span>"#
            + #"<span begin="00:01.000" end="00:02.000">ra</span></p>"#

        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml">
            <body><div>
                \(karaokeParagraph)
            </div></body>
        </tt>
        """

        let result = TTMLParser(fallbackPhoneticProvider: EchoSyllablePhoneticProvider()).parse(ttml)
        guard case .main(let line) = result.lines[0] else {
            return XCTFail("第 0 行应为 MainKaraokeLine")
        }
        // SYLLABLE 粒度：每个音节单独喂，行级 phonetic 保持 nil。
        XCTAssertEqual(line.syllables.map(\.phonetic), ["[Ka]", "[ra]"])
        XCTAssertNil(line.phonetic)
    }

    func testNoFallbackWithoutProvider() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml">
            <body><div>
                <p begin="00:00.000" end="00:01.000"><span begin="00:00.000" end="00:01.000">Hello</span></p>
            </div></body>
        </tt>
        """

        let result = TTMLParser().parse(ttml)
        guard case .main(let line) = result.lines[0] else {
            return XCTFail("第 0 行应为 MainKaraokeLine")
        }
        XCTAssertNil(line.phonetic)
        XCTAssertNil(line.syllables[0].phonetic)
    }

    func testITunesTranslationIsSplitByFullWidthBrackets() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal">
            <head>
                <metadata>
                    <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
                        <translations>
                            <translation>
                                <text for="L1">正文（かたかな）</text>
                            </translation>
                        </translations>
                    </iTunesMetadata>
                </metadata>
            </head>
            <body><div>
                <p begin="00:00.000" end="00:01.000" itunes:key="L1">
                    <span begin="00:00.000" end="00:01.000">Main</span>
                </p>
            </div></body>
        </tt>
        """

        let result = TTMLParser().parse(ttml)
        guard case .main(let line) = result.lines[0] else {
            return XCTFail("第 0 行应为 MainKaraokeLine")
        }
        // 行内没有译文 span 时用 iTunes 表；括号外的正文是译文，括号内的假名不显示在译文位置。
        XCTAssertEqual(line.translation, "正文")
    }

    func testITunesTranslationWithoutBracketsIsKeptWhole() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal">
            <head>
                <metadata>
                    <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
                        <translations>
                            <translation>
                                <text for="L1">整句译文</text>
                            </translation>
                        </translations>
                    </iTunesMetadata>
                </metadata>
            </head>
            <body><div>
                <p begin="00:00.000" end="00:01.000" itunes:key="L1">
                    <span begin="00:00.000" end="00:01.000">Main</span>
                </p>
            </div></body>
        </tt>
        """

        let result = TTMLParser().parse(ttml)
        guard case .main(let line) = result.lines[0] else {
            return XCTFail("第 0 行应为 MainKaraokeLine")
        }
        XCTAssertEqual(line.translation, "整句译文")
    }

    func testAccompanimentPrefersBracketInsideOfITunesTranslation() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" \
        xmlns:itunes="http://music.apple.com/lyric-ttml-internal">
            <head>
                <metadata>
                    <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
                        <translations>
                            <translation>
                                <text for="L2">背景（はいけい）</text>
                            </translation>
                        </translations>
                    </iTunesMetadata>
                </metadata>
            </head>
            <body><div>
                <p begin="00:01.000" end="00:02.000" itunes:key="L1">
                    <span begin="00:01.000" end="00:02.000">Main</span>
                    <span ttm:role="x-bg" begin="00:01.000" end="00:02.000" itunes:key="L2">
                        <span begin="00:01.000" end="00:02.000">BG</span>
                    </span>
                </p>
            </div></body>
        </tt>
        """

        let result = TTMLParser().parse(ttml)
        guard case .main(let line) = result.lines[0] else {
            return XCTFail("第 0 行应为 MainKaraokeLine")
        }
        // 和声走 iTunes 译文表时**优先取括号内**（和声词常写在括号里），与主行相反。
        XCTAssertEqual(line.accompanimentLines?.first?.translation, "はいけい")
    }
}

// MARK: - 导出器

final class TTMLExporterTests: XCTestCase {

    // MARK: 原库 TTMLExporterTest.kt 的 1 条 golden case

    func testExportWithSyncedLine() {
        let lyrics = SyncedLyrics(
            lines: [
                .synced(SyncedLine(content: "Hello <World>", translation: "你好 & 世界", start: 0, end: 2_000))
            ]
        )
        let exported = TTMLExporter().export(lyrics)

        XCTAssertTrue(exported.contains(
            #"<p begin="00:00.000" end="00:02.000">Hello &lt;World&gt;"#
                + #"<span ttm:role="x-translation" xml:lang="zh-CN">你好 &amp; 世界</span></p>"#
        ))
    }

    // MARK: 补充边界（原库没有对应用例）

    func testExportEmptyLyricsReturnsEmptyString() {
        XCTAssertEqual(TTMLExporter().export(SyncedLyrics()), "")
    }

    func testExportWritesAgentMetadataOnlyWhenBothAlignmentsPresent() {
        let bothAlignments = SyncedLyrics(lines: [
            .main(MainKaraokeLine(
                syllables: [KaraokeSyllable(content: "Left", start: 0, end: 1_000)],
                alignment: .start, start: 0, end: 1_000
            )),
            .main(MainKaraokeLine(
                syllables: [KaraokeSyllable(content: "Right", start: 1_000, end: 2_000)],
                alignment: .end, start: 1_000, end: 2_000
            ))
        ])
        let exported = TTMLExporter().export(bothAlignments)
        XCTAssertTrue(exported.contains(#"<ttm:agent type="person" xml:id="v1"/>"#))
        XCTAssertTrue(exported.contains(#"<ttm:agent type="person" xml:id="v2"/>"#))
        XCTAssertTrue(exported.contains(#"ttm:agent="v1""#))
        XCTAssertTrue(exported.contains(#"ttm:agent="v2""#))

        let onlyStart = SyncedLyrics(lines: [
            .main(MainKaraokeLine(
                syllables: [KaraokeSyllable(content: "Left", start: 0, end: 1_000)],
                alignment: .start, start: 0, end: 1_000
            ))
        ])
        XCTAssertFalse(TTMLExporter().export(onlyStart).contains("<metadata>"))
    }

    func testExportKaraokeSyllableKeepsTrailingSpace() {
        let lyrics = SyncedLyrics(lines: [
            .main(MainKaraokeLine(
                syllables: [KaraokeSyllable(content: "Hello ", start: 0, end: 1_000)],
                alignment: .unspecified, start: 0, end: 1_000
            ))
        ])
        // 音节文本 trim 后写进 span，但原始文本以空格结尾时要在 span 外补一个空格 —— 词间空格靠它。
        XCTAssertTrue(TTMLExporter().export(lyrics)
            .contains(#"<span begin="00:00.000" end="00:01.000">Hello</span> "#))
    }

    func testExportEscapesKaraokeSyllableContent() {
        let lyrics = SyncedLyrics(lines: [
            .main(MainKaraokeLine(
                syllables: [KaraokeSyllable(content: "a<b&c>", start: 0, end: 1_000)],
                alignment: .unspecified, start: 0, end: 1_000
            ))
        ])
        XCTAssertTrue(TTMLExporter().export(lyrics).contains(">a&lt;b&amp;c&gt;</span>"))
    }

    func testExportSkipsTopLevelAccompanimentLine() {
        // 原库的 when/重载都没有覆盖「顶层和声行」，实际行为就是跳过；这里把该行为钉住。
        let lyrics = SyncedLyrics(lines: [
            .accompaniment(AccompanimentKaraokeLine(
                syllables: [KaraokeSyllable(content: "BG", start: 0, end: 1_000)],
                alignment: .start, start: 0, end: 1_000
            ))
        ])
        let exported = TTMLExporter().export(lyrics)
        XCTAssertFalse(exported.contains("BG"))
        XCTAssertTrue(exported.contains("<body dur="))
    }
}
