// LyricsModelTests.swift
// NeriPlayer macOS —— M4-T1 模型层/工具层单测。
//
// 覆盖三块：时间戳工具（LyricsTime）、LRC 元数据工具（LrcMetadataHelper）、模型层
// （SyncedLine / KaraokeSyllable / LyricsLine / SyncedLyrics 的二分查找）。
//
// 时间戳工具的用例直接来自原库 commonTest/utils/TimeUtilsTest.kt（7 条），
// 二分查找的用例是照原库实现手推的期望值（原库没有对应测试）——重点覆盖
// 「落在行内 / 落在空隙 / 在所有行之前 / 在所有行之后 / 多行重叠」五种位置。

import XCTest
@testable import NeriPlayer

final class LyricsTimeTests: XCTestCase {

    // MARK: 原库 TimeUtilsTest.kt 的 7 条 golden case

    func testThreeDigitMillisParse() {
        XCTAssertEqual(LyricsTime.parseAsTime("00:00.123"), 123)
    }

    func testTwoDigitMillisParse() {
        XCTAssertEqual(LyricsTime.parseAsTime("00:00.12"), 120)
    }

    func testOneDigitMillisParse() {
        XCTAssertEqual(LyricsTime.parseAsTime("00:00.1"), 100)
    }

    func testNoMillisParse() {
        XCTAssertEqual(LyricsTime.parseAsTime("00:00"), 0)
    }

    func testInvalidTimeParse() {
        XCTAssertEqual(LyricsTime.parseAsTime("invalid"), 0)
    }

    func testNoHoursAndMinutesParse() {
        XCTAssertEqual(LyricsTime.parseAsTime("00.123"), 123)
    }

    func testNoHoursParse() {
        XCTAssertEqual(LyricsTime.parseAsTime("00:00.123"), 123)
    }

    // MARK: 补充边界

    func testEmptyStringParsesToZero() {
        XCTAssertEqual(LyricsTime.parseAsTime(""), 0)
    }

    func testHoursMinutesSeconds() {
        // 01:02:03.456 = 3600_000 + 120_000 + 3_456
        XCTAssertEqual(LyricsTime.parseAsTime("01:02:03.456"), 3_723_456)
    }

    func testSubSecondOnly() {
        XCTAssertEqual(LyricsTime.parseAsTime("1.5"), 1_500)
    }

    func testMoreThanThreeMillisDigitsTruncates() {
        // 原库把超过 3 位的小数部分截到前 3 位
        XCTAssertEqual(LyricsTime.parseAsTime("00:00.1234"), 123)
    }

    func testTrailingDotIsTreatedAsNoMillis() {
        XCTAssertEqual(LyricsTime.parseAsTime("00:01."), 1_000)
    }

    func testGarbageMinutesParseAsZero() {
        // 分钟段不是数字时按 0 处理，秒段仍正常解析
        XCTAssertEqual(LyricsTime.parseAsTime("ab:01.5"), 1_500)
    }

    func testColonOnlyParsesToZero() {
        XCTAssertEqual(LyricsTime.parseAsTime(":"), 0)
    }

    func testNegativeMinuteFieldIsPreserved() {
        // 符号算在"分钟段"上：`-00:01.000` 的分钟段是 -0 == 0，结果仍是 +1000；
        // `-1:00.000` 才是负的。两者都与原库一致，这里不做额外钳制。
        XCTAssertEqual(LyricsTime.parseAsTime("-00:01.000"), 1_000)
        XCTAssertEqual(LyricsTime.parseAsTime("-1:00.000"), -60_000)
    }

    // MARK: 格式化

    func testFormattedPadsAllFields() {
        XCTAssertEqual(LyricsTime.formatted(0), "00:00.000")
        XCTAssertEqual(LyricsTime.formatted(1), "00:00.001")
        XCTAssertEqual(LyricsTime.formatted(1_234), "00:01.234")
        XCTAssertEqual(LyricsTime.formatted(62_500), "01:02.500")
    }

    func testIsDigitsOnlyIsUnicodeAware() {
        XCTAssertTrue(LyricsTime.isDigitsOnly("0123456789"))
        // Kotlin `Char.isDigit()` 是 Nd 类别，阿拉伯-印度数字也算数字
        XCTAssertTrue(LyricsTime.isDigitsOnly("\u{0663}"))
        // 空串与原库 `all {}` 一致返回 true（调用点的 `(\d+)` 捕获组保证非空）
        XCTAssertTrue(LyricsTime.isDigitsOnly(""))
        XCTAssertFalse(LyricsTime.isDigitsOnly("12a"))
        XCTAssertFalse(LyricsTime.isDigitsOnly("-1"))
    }

    func testFormattedNegativeClampsToZero() {
        XCTAssertEqual(LyricsTime.formatted(-1), "00:00.000")
    }

    func testFormattedDoesNotFoldIntoHours() {
        // 与原库一致：75 分钟就是 "75:00.000"
        XCTAssertEqual(LyricsTime.formatted(75 * 60_000), "75:00.000")
    }

    func testParseFormatRoundTrip() {
        for value in [0, 1, 999, 1_000, 12_345, 600_000, 3_723_456] {
            let text = LyricsTime.formatted(value)
            XCTAssertEqual(LyricsTime.parseAsTime(text), value, "round trip failed for \(text)")
        }
    }
}

final class LrcMetadataHelperTests: XCTestCase {

    func testParseKnownTags() {
        let attributes = LrcMetadataHelper.parse([
            "[ti:Song Title]",
            "[ar:Artist Name]",
            "[al:Album]",
            "[offset:-500]",
            "[length:03:20]"
        ])
        XCTAssertEqual(attributes.title, "Song Title")
        XCTAssertEqual(attributes.artist, "Artist Name")
        XCTAssertEqual(attributes.album, "Album")
        XCTAssertEqual(attributes.offset, -500)
        // length 不是纯数字，落回 0
        XCTAssertEqual(attributes.duration, 0)
    }

    func testParseMissingTagsFallsBackToZero() {
        let attributes = LrcMetadataHelper.parse(["[00:01.00]Lyric"])
        XCTAssertNil(attributes.artist)
        XCTAssertNil(attributes.title)
        XCTAssertNil(attributes.album)
        XCTAssertEqual(attributes.offset, 0)
        XCTAssertEqual(attributes.duration, 0)
    }

    func testParseLastDuplicateWins() {
        // 原库 .toMap() 对重复 key 保留最后一次
        let attributes = LrcMetadataHelper.parse(["[ti:First]", "[ti:Second]"])
        XCTAssertEqual(attributes.title, "Second")
    }

    func testParseIgnoresUnknownTags() {
        let attributes = LrcMetadataHelper.parse(["[bg:background]", "[by:someone]", "[ti:T]"])
        XCTAssertEqual(attributes.title, "T")
    }

    func testRemoveAttributesKeepsUnknownTags() {
        let lines = [
            "[ti:T]",
            "[bg:<00:10.00>Back]",
            "[00:01.00]Lyric",
            "[offset:100]"
        ]
        XCTAssertEqual(
            LrcMetadataHelper.removeAttributes(lines),
            ["[bg:<00:10.00>Back]", "[00:01.00]Lyric"]
        )
    }

    func testCreditLineRecognizesChineseRole() {
        XCTAssertTrue(LrcMetadataHelper.isCreditLine("作词 : 罗言"))
        XCTAssertTrue(LrcMetadataHelper.isCreditLine("作曲：某人"))
        XCTAssertTrue(LrcMetadataHelper.isCreditLine("混音师 : Bob"))
    }

    func testCreditLineIsCaseInsensitiveForEnglishRole() {
        XCTAssertTrue(LrcMetadataHelper.isCreditLine("OP: 唯迹文化"))
        XCTAssertTrue(LrcMetadataHelper.isCreditLine("producer: someone"))
    }

    func testCreditLineRejectsOrdinaryLyricWithColon() {
        XCTAssertFalse(LrcMetadataHelper.isCreditLine("爱：是不能够停止的"))
        XCTAssertFalse(LrcMetadataHelper.isCreditLine("00:01.00 not a credit"))
    }

    func testCreditLineRejectsEmptyValue() {
        XCTAssertFalse(LrcMetadataHelper.isCreditLine("作词:"))
        XCTAssertFalse(LrcMetadataHelper.isCreditLine("作词:   "))
    }

    func testCreditLineRejectsLeadingColon() {
        XCTAssertFalse(LrcMetadataHelper.isCreditLine(": 作词"))
    }

    func testCreditLineRejectsRoleWithEmbeddedWhitespace() {
        XCTAssertFalse(LrcMetadataHelper.isCreditLine("作 词: 某人"))
    }

    func testCreditLineRejectsOverlongRole() {
        XCTAssertFalse(LrcMetadataHelper.isCreditLine("这是一个非常长的角色名称啊啊: X"))
    }
}

final class SyncedLyricsSearchTests: XCTestCase {

    /// 固定样本：两行不重叠 + 两行重叠。
    private func makeLyrics() -> SyncedLyrics {
        SyncedLyrics(lines: [
            .synced(SyncedLine(content: "L0", start: 0, end: 1_000)),
            .synced(SyncedLine(content: "L1", start: 2_000, end: 3_000)),
            .synced(SyncedLine(content: "L2", start: 5_000, end: 6_000)),
            .synced(SyncedLine(content: "L3", start: 5_000, end: 7_000))
        ])
    }

    func testFirstHighlightInsideLine() {
        XCTAssertEqual(makeLyrics().currentFirstHighlightLineIndex(at: 500), 0)
        XCTAssertEqual(makeLyrics().currentFirstHighlightLineIndex(at: 2_500), 1)
    }

    func testFirstHighlightReturnsFirstOfOverlappingLines() {
        XCTAssertEqual(makeLyrics().currentFirstHighlightLineIndex(at: 5_500), 2)
    }

    func testFirstHighlightInGapReturnsNextLine() {
        XCTAssertEqual(makeLyrics().currentFirstHighlightLineIndex(at: 1_500), 1)
        XCTAssertEqual(makeLyrics().currentFirstHighlightLineIndex(at: 4_000), 2)
    }

    func testFirstHighlightBeforeAllLines() {
        XCTAssertEqual(makeLyrics().currentFirstHighlightLineIndex(at: -100), 0)
    }

    func testFirstHighlightAfterAllLinesReturnsCount() {
        XCTAssertEqual(makeLyrics().currentFirstHighlightLineIndex(at: 99_999), 4)
    }

    func testFirstHighlightOnBoundaries() {
        XCTAssertEqual(makeLyrics().currentFirstHighlightLineIndex(at: 0), 0)
        XCTAssertEqual(makeLyrics().currentFirstHighlightLineIndex(at: 1_000), 0)
        XCTAssertEqual(makeLyrics().currentFirstHighlightLineIndex(at: 1_001), 1)
        XCTAssertEqual(makeLyrics().currentFirstHighlightLineIndex(at: 2_000), 1)
    }

    func testFirstHighlightEmptyLyricsReturnsZero() {
        XCTAssertEqual(SyncedLyrics().currentFirstHighlightLineIndex(at: 1_000), 0)
    }

    func testAllHighlightReturnsEveryOverlappingLine() {
        XCTAssertEqual(makeLyrics().currentAllHighlightLineIndices(at: 5_500), [2, 3])
        XCTAssertEqual(makeLyrics().currentAllHighlightLineIndices(at: 2_500), [1])
    }

    func testAllHighlightReturnsEmptyInGap() {
        XCTAssertEqual(makeLyrics().currentAllHighlightLineIndices(at: 1_500), [])
        XCTAssertEqual(makeLyrics().currentAllHighlightLineIndices(at: 99_999), [])
    }

    func testAllHighlightBeforeAllLinesIsEmpty() {
        // 注意与 currentFirstHighlightLineIndex 的语义差异：这里没有"下一行"兜底
        XCTAssertEqual(makeLyrics().currentAllHighlightLineIndices(at: -100), [])
    }

    func testAllHighlightEmptyLyrics() {
        XCTAssertEqual(SyncedLyrics().currentAllHighlightLineIndices(at: 0), [])
    }

    func testDefaultMetadata() {
        let lyrics = SyncedLyrics()
        XCTAssertEqual(lyrics.title, "")
        XCTAssertEqual(lyrics.id, "0")
        XCTAssertEqual(lyrics.artists, [])
    }
}

final class LyricsLineModelTests: XCTestCase {

    func testSyncedLineDurationClampsNegativeToZero() {
        let line = SyncedLine(content: "x", start: 1_000, end: 500)
        XCTAssertEqual(line.duration, 0)
    }

    func testUncheckedSyncedLineConvergesToSyncedLine() {
        let unchecked = UncheckedSyncedLine(content: "x", translation: "t", start: 100, end: 300)
        XCTAssertEqual(unchecked.duration, 200)
        XCTAssertEqual(
            unchecked.toSyncedLine(),
            SyncedLine(content: "x", translation: "t", start: 100, end: 300)
        )
    }

    func testUncheckedSyncedLineToleratesReversedTimes() {
        // 这正是它作为「过渡类型」的意义：中途允许 end < start，时长按原库口径落 0
        let unchecked = UncheckedSyncedLine(content: "x", start: 300, end: 100)
        XCTAssertEqual(unchecked.duration, 0)
        XCTAssertEqual(unchecked.toSyncedLine().duration, 0)
    }

    func testSyncedLineDurationNormal() {
        XCTAssertEqual(SyncedLine(content: "x", start: 1_000, end: 2_500).duration, 1_500)
    }

    func testSyncedLineProgress() {
        // 进度是 LyricsLine 层统一提供的（原库 SyncedLine 自己没有这个方法，渲染端需要）
        let line = LyricsLine.synced(SyncedLine(content: "x", start: 1_000, end: 2_000))
        XCTAssertEqual(line.progress(current: 500), 0)
        XCTAssertEqual(line.progress(current: 1_500), 0.5, accuracy: 0.0001)
        XCTAssertEqual(line.progress(current: 2_000), 1)
        XCTAssertEqual(line.progress(current: 9_000), 1)
    }

    func testSyncedLineZeroDurationProgressIsComplete() {
        // 首尾同刻的行（纯时间戳行）没有可插值的区间，按"已走完"处理而不是 NaN
        let line = LyricsLine.synced(SyncedLine(content: "x", start: 1_000, end: 1_000))
        XCTAssertEqual(line.progress(current: 1_000), 1)
    }

    func testKaraokeSyllableDurationAndProgress() {
        let syllable = KaraokeSyllable(content: "a", start: 100, end: 300)
        XCTAssertEqual(syllable.duration, 200)
        XCTAssertEqual(syllable.progress(current: 0), 0)
        XCTAssertEqual(syllable.progress(current: 200), 0.5, accuracy: 0.0001)
        XCTAssertEqual(syllable.progress(current: 300), 1)
        XCTAssertEqual(syllable.progress(current: 400), 1)
    }

    func testKaraokeSyllableReversedTimesAreClamped() {
        // 原库这里会 require 抛异常；本移植改为钳制，不炸整份歌词
        let syllable = KaraokeSyllable(content: "a", start: 300, end: 100)
        XCTAssertEqual(syllable.duration, 0)
        XCTAssertEqual(syllable.progress(current: 200), 0)
        XCTAssertEqual(syllable.progress(current: 300), 1)
        XCTAssertEqual(syllable.progress(current: 400), 1)
    }

    func testJoinedContentAndPhonetic() {
        let syllables = [
            KaraokeSyllable(content: "你", start: 0, end: 100, phonetic: "ni"),
            KaraokeSyllable(content: "好", start: 100, end: 200)
        ]
        XCTAssertEqual(syllables.joinedContent, "你好")
        // 缺注音的音节留空占位，保持音节与注音的下标对齐
        XCTAssertEqual(syllables.joinedPhonetic, "ni ")
    }

    func testKaraokeLineProgressAndFocus() {
        let line = MainKaraokeLine(
            syllables: [KaraokeSyllable(content: "a", start: 1_000, end: 2_000)],
            start: 1_000,
            end: 2_000
        )
        XCTAssertEqual(line.progress(current: 0), 0)
        XCTAssertEqual(line.progress(current: 1_500), 0.5, accuracy: 0.0001)
        XCTAssertEqual(line.progress(current: 3_000), 1)
        XCTAssertTrue(line.isFocused(current: 1_000))
        XCTAssertTrue(line.isFocused(current: 2_000))
        XCTAssertFalse(line.isFocused(current: 999))
    }

    func testKaraokeLineToSyncedLineTrimsJoinedContent() {
        let line = AccompanimentKaraokeLine(
            syllables: [
                KaraokeSyllable(content: " Back", start: 0, end: 100),
                KaraokeSyllable(content: "ing ", start: 100, end: 200)
            ],
            translation: "和声",
            start: 0,
            end: 200
        )
        let synced = line.toSyncedLine()
        XCTAssertEqual(synced.content, "Backing")
        XCTAssertEqual(synced.translation, "和声")
        XCTAssertEqual(synced.start, 0)
        XCTAssertEqual(synced.end, 200)
    }

    func testSyncedLineToKaraokeLineIsSingleSyllable() {
        let line = SyncedLine(content: "你好", translation: "hello", start: 10, end: 20).toKaraokeLine()
        XCTAssertEqual(line.syllables.count, 1)
        XCTAssertEqual(line.syllables[0].content, "你好")
        XCTAssertEqual(line.syllables[0].start, 10)
        XCTAssertEqual(line.syllables[0].end, 20)
        XCTAssertEqual(line.translation, "hello")
        XCTAssertEqual(line.alignment, .unspecified)
    }

    func testSyncedLineToKaraokeLineToleratesReversedTimes() {
        // 原库这里会因 KaraokeSyllable 的 require 抛异常
        let line = SyncedLine(content: "坏", start: 500, end: 100).toKaraokeLine()
        XCTAssertEqual(line.syllables[0].duration, 0)
    }

    func testLyricsLineAccessors() {
        let synced = LyricsLine.synced(SyncedLine(content: " hi ", translation: "t", start: 0, end: 100))
        let main = LyricsLine.main(MainKaraokeLine(
            syllables: [KaraokeSyllable(content: "你 ", start: 0, end: 100)],
            start: 0,
            end: 100
        ))

        XCTAssertNil(synced.karaokeLine)
        XCTAssertNotNil(main.karaokeLine)
        // 逐行对齐的正文原样返回，音节行的正文拼接后去空白
        XCTAssertEqual(synced.content, " hi ")
        XCTAssertEqual(synced.trimmedContent, "hi")
        XCTAssertEqual(main.content, "你")
        XCTAssertNil(synced.alignment)
        XCTAssertEqual(main.alignment, .unspecified)
        XCTAssertEqual(synced.translation, "t")
    }

    func testLyricsLineWithHelpersRoundTrip() {
        let line = LyricsLine.main(MainKaraokeLine(
            syllables: [KaraokeSyllable(content: "a", start: 0, end: 100)],
            start: 0,
            end: 100
        ))

        let updated = line
            .withTranslation("译文")
            .withAlignment(.end)
            .withStart(50)
            .withEnd(150)
            .withPhonetic("a")
            .withSyllables([KaraokeSyllable(content: "b", start: 50, end: 150)])

        XCTAssertEqual(updated.translation, "译文")
        XCTAssertEqual(updated.alignment, .end)
        XCTAssertEqual(updated.start, 50)
        XCTAssertEqual(updated.end, 150)
        XCTAssertEqual(updated.content, "b")
        if case .main(let main) = updated {
            XCTAssertEqual(main.phonetic, "a")
        } else {
            XCTFail("expected a main karaoke line")
        }

        // 逐行对齐的行没有音节/对齐概念，这些 helper 应当原样返回
        let synced = LyricsLine.synced(SyncedLine(content: "x", start: 0, end: 10))
        XCTAssertEqual(synced.withAlignment(.end), synced)
        XCTAssertEqual(synced.withSyllables([]), synced)
        XCTAssertEqual(synced.withPhonetic("x"), synced)
    }

    func testLyricsLineToSyncedLinePassesThrough() {
        let synced = SyncedLine(content: "x", start: 0, end: 10)
        XCTAssertEqual(LyricsLine.synced(synced).toSyncedLine(), synced)
    }

    func testLyricsLineDurationAndFocus() {
        let line = LyricsLine.synced(SyncedLine(content: "x", start: 100, end: 300))
        XCTAssertEqual(line.duration, 200)
        XCTAssertTrue(line.isFocused(current: 200))
        XCTAssertFalse(line.isFocused(current: 301))
    }
}
