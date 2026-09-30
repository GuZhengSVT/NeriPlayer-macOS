import XCTest
@testable import NeriPlayer

final class LyricsSafetyRegressionTests: XCTestCase {
    func testExtremeTimestampArithmeticAndRoundTrip() {
        XCTAssertEqual(LyricsTime.parseAsTime(String(Int.max)), Int.max)
        XCTAssertEqual(LyricsTime.parseAsTime(String(Int.min)), Int.min)
        XCTAssertEqual(LyricsTime.parseAsTime(LyricsTime.formatted(Int.max)), Int.max)
        XCTAssertEqual(LyricsTime.adding(Int.max, 1), Int.max)
        XCTAssertEqual(LyricsTime.adding(Int.min, -1), Int.min)
        XCTAssertEqual(LyricsTime.subtracting(Int.max, Int.min), Int.max)
        XCTAssertEqual(LyricsTime.subtracting(Int.min, Int.max), Int.min)
    }

    func testExtremeDurationsAndProgressDoNotOverflow() {
        let syllable = KaraokeSyllable(content: "x", start: Int.min, end: Int.max)
        XCTAssertEqual(syllable.duration, Int.max)
        XCTAssertEqual(syllable.progress(current: 0), 0.5, accuracy: 0.0001)
        let main = MainKaraokeLine(syllables: [syllable], start: Int.min, end: Int.max)
        XCTAssertEqual(main.progress(current: 0), 0.5, accuracy: 0.0001)
        let synced = LyricsLine.synced(SyncedLine(content: "x", start: Int.min, end: Int.max))
        XCTAssertEqual(synced.progress(current: 0), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SyncedLine(content: "x", start: Int.max, end: Int.min).duration, 0)
        XCTAssertEqual(UncheckedSyncedLine(content: "x", start: Int.min, end: Int.max).duration, Int.max)
        XCTAssertEqual(AccompanimentKaraokeLine(syllables: [], start: Int.min, end: Int.max).duration, Int.max)
    }

    func testNumericParserAdditionsSaturate() {
        let yrc = NeteaseYrcParser().parse(["[\(Int.max),1](1,\(Int.max),0)x"])
        XCTAssertEqual(yrc.lines.first?.end, Int.max)
        let krc = KugouKrcParser().parse(["[\(Int.max),1]<1,\(Int.max),0>x<1,1,0>:", "[0,1]<1,1,0>y"])
        XCTAssertEqual(krc.lines.count, 2)
        XCTAssertTrue(krc.lines.allSatisfy { $0.end == Int.max })
        let syl = LyricifySyllableParser().parse(["[4]x(\(Int.max),1)"])
        XCTAssertEqual(syl.lines.first?.end, Int.max)
    }

    func testUnicodeDigitClassificationUsesDecimalNumbers() {
        XCTAssertTrue(LyricsTime.isDigitsOnly("٣३"))
        XCTAssertFalse(LyricsTime.isDigitsOnly("²½Ⅳ"))
        XCTAssertFalse(LyricsTime.isDigitsOnly("1️⃣"))
    }

    func testXmlEntitiesDecodeExactlyOnce() {
        XCTAssertEqual(SimpleXmlParser.decodeEntities("&amp;lt; &amp;#65; &#65; &#x1F600;"), "&lt; &#65; A 😀")
        XCTAssertEqual(SimpleXmlParser.decodeEntities("&#0; &#xD800; &#x110000; &unknown;"), "&#0; &#xD800; &#x110000; &unknown;")
    }

    func testXmlTagWhitespaceAndQuotedDelimiter() {
        let xml = "<tt><p\tbegin=\"0\" end=\"1\" title=\"a > b\">hello</p></tt>"
        XCTAssertEqual(TTMLParser().parse(xml).lines.first?.content, "hello")
    }

    func testMixedTextOrderAndWhitespace() {
        let xml = #"<tt><body><p begin="0" end="1">A  <span>B👩‍👩‍👧‍👦</span> C<span role="x-translation">&amp;lt;</span></p></body></tt>"#
        let line = TTMLParser().parse(xml).lines.first
        XCTAssertEqual(line?.content, "A  B👩‍👩‍👧‍👦 C")
        XCTAssertEqual(line?.translation, "&lt;")
    }

    func testTextAndTranslationsSurviveTTMLRoundTrip() {
        let translation = "译 <tag> & &lt; 😀"
        let original = SyncedLyrics(lines: [
            .synced(SyncedLine(content: "literal &lt;  😀", translation: translation, start: 0, end: 100)),
            .main(MainKaraokeLine(syllables: [KaraokeSyllable(content: "&lt;😀", start: 100, end: 200)],
                                  translation: translation, start: 100, end: 200,
                                  accompanimentLines: [AccompanimentKaraokeLine(
                                                        syllables: [KaraokeSyllable(content: "背景", start: 100, end: 200)],
                                                        translation: translation, start: 100, end: 200)]))
        ])
        let parsed = TTMLParser().parse(TTMLExporter().export(original))
        XCTAssertEqual(parsed.lines.map(\.content), original.lines.map(\.content))
        XCTAssertEqual(parsed.lines.map(\.translation), original.lines.map(\.translation))
        guard case .main(let main) = parsed.lines.last else { return XCTFail("Expected karaoke line") }
        XCTAssertEqual(main.accompanimentLines?.first?.translation, translation)
    }
}
