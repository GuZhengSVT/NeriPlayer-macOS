// LyricsTimelineTests.swift
// M4: focused intervals, syllable progress and safe timing arithmetic.
import XCTest
@testable import NeriPlayer

final class LyricsTimelineTests: XCTestCase {
    private func line(_ start: Int, _ end: Int) -> LyricsLine {
        .synced(SyncedLine(content: "line", start: start, end: end))
    }

    private func timeline(_ lines: [LyricsLine]) -> LyricsTimeline {
        LyricsTimeline(lyrics: SyncedLyrics(lines: lines))
    }

    func testEmptyLyricsHaveNoFocusOrScrollTarget() {
        let state = timeline([]).state(at: 1)
        XCTAssertEqual(state.timeMilliseconds, 1000)
        XCTAssertEqual(state.focusedLineIndices, [])
        XCTAssertNil(state.scrollLineIndex)
        XCTAssertEqual(state.syllableProgress, [])
    }

    func testBeforeGapAndAfterKeepValidScrollTargets() {
        let subject = timeline([line(1000, 2000), line(3000, 4000)])
        XCTAssertEqual(subject.state(at: 0).scrollLineIndex, 0)
        XCTAssertEqual(subject.state(at: 2.5).scrollLineIndex, 1)
        XCTAssertEqual(subject.state(at: 100).scrollLineIndex, 1)
        XCTAssertEqual(subject.state(at: 2.5).focusedLineIndices, [])
        XCTAssertEqual(subject.state(at: 100).focusedLineIndices, [])
    }

    func testClosedIntervalsHighlightBothLinesAtSharedBoundary() {
        let subject = timeline([line(1000, 2000), line(2000, 3000)])
        XCTAssertEqual(subject.state(at: 1).focusedLineIndices, [0])
        XCTAssertEqual(subject.state(at: 2).focusedLineIndices, [0, 1])
        XCTAssertEqual(subject.state(at: 2).scrollLineIndex, 0)
        XCTAssertEqual(subject.state(at: 2.001).focusedLineIndices, [1])
        XCTAssertEqual(subject.state(at: 3).focusedLineIndices, [1])
    }

    func testLongOverlappingLineSurvivesExpiredShortLines() {
        let subject = timeline([line(0, 10000), line(1000, 2000), line(3000, 4000)])
        XCTAssertEqual(subject.state(at: 5).focusedLineIndices, [0])
        XCTAssertEqual(subject.state(at: 5).scrollLineIndex, 0)
        XCTAssertEqual(subject.state(at: 3.5).focusedLineIndices, [0, 2])
    }

    func testUnsortedInputPreservesOriginalIndices() {
        let subject = timeline([line(3000, 4000), line(1000, 2000), line(1000, 2500)])
        XCTAssertEqual(subject.state(at: 0).scrollLineIndex, 1)
        XCTAssertEqual(subject.state(at: 1.5).focusedLineIndices, [1, 2])
        XCTAssertEqual(subject.state(at: 2.6).scrollLineIndex, 0)
        XCTAssertEqual(subject.state(at: 5).scrollLineIndex, 0)
    }

    func testZeroLengthAndReversedIntervals() {
        let subject = timeline([line(1000, 1000), line(2000, 1500)])
        XCTAssertEqual(subject.state(at: 1).focusedLineIndices, [0])
        XCTAssertEqual(subject.state(at: 1.001).focusedLineIndices, [])
        XCTAssertEqual(subject.state(at: 2).focusedLineIndices, [])
    }

    func testPositiveOffsetAdvancesLyricsAndNegativeOffsetDelaysThem() {
        let subject = timeline([line(1000, 2000)])
        XCTAssertEqual(subject.state(at: 0.5, offsetMilliseconds: 500).focusedLineIndices, [0])
        XCTAssertEqual(subject.state(at: 1, offsetMilliseconds: -500).focusedLineIndices, [])
        XCTAssertEqual(subject.state(at: 1.5, offsetMilliseconds: -500).timeMilliseconds, 1000)
    }

    func testNegativeOffsetDoesNotPrematurelyFocusFirstLine() {
        let state = timeline([line(0, 1000)]).state(at: 0, offsetMilliseconds: -500)
        XCTAssertEqual(state.timeMilliseconds, -500)
        XCTAssertEqual(state.focusedLineIndices, [])
        XCTAssertEqual(state.scrollLineIndex, 0)
    }

    func testMillisecondsTruncateTowardZeroIncludingNegativeTimes() {
        let subject = timeline([])
        XCTAssertEqual(subject.state(at: 1.2349).timeMilliseconds, 1234)
        XCTAssertEqual(subject.state(at: -1.2349).timeMilliseconds, -1234)
    }

    func testNonfiniteSecondsFallBackToZeroBeforeApplyingOffset() {
        let subject = timeline([])
        for seconds in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(subject.state(at: seconds).timeMilliseconds, 0)
            XCTAssertEqual(subject.state(at: seconds, offsetMilliseconds: 25).timeMilliseconds, 25)
        }
    }

    func testConversionAndOffsetSaturateWithoutOverflow() {
        let subject = timeline([line(Int.min, Int.max)])
        XCTAssertEqual(subject.state(at: Double.greatestFiniteMagnitude).timeMilliseconds, Int.max)
        XCTAssertEqual(subject.state(at: -Double.greatestFiniteMagnitude).timeMilliseconds, Int.min)
        XCTAssertEqual(subject.state(at: Double(Int.max) / 1000).timeMilliseconds, Int.max)
        XCTAssertEqual(subject.state(at: 1, offsetMilliseconds: Int.max).timeMilliseconds, Int.max)
        XCTAssertEqual(subject.state(at: -1, offsetMilliseconds: Int.min).timeMilliseconds, Int.min)
        XCTAssertEqual(subject.state(at: Double.greatestFiniteMagnitude).focusedLineIndices, [0])
        XCTAssertEqual(subject.state(at: -Double.greatestFiniteMagnitude).focusedLineIndices, [0])
    }

    func testOnlyFocusedKaraokeLinesComputeSyllableProgress() {
        let karaoke = LyricsLine.main(MainKaraokeLine(syllables: [
            KaraokeSyllable(content: "a", start: 1000, end: 2000),
            KaraokeSyllable(content: "b", start: 2000, end: 3000)
        ], start: 1000, end: 3000))
        let subject = timeline([line(0, 500), karaoke])
        XCTAssertEqual(subject.state(at: 1.5).syllableProgress, [[], [0.5, 0]])
        XCTAssertEqual(subject.state(at: 2.5).syllableProgress, [[], [1, 0.5]])
        XCTAssertEqual(subject.state(at: 4).syllableProgress, [[], []])
        XCTAssertEqual(subject.progress(for: 1, at: 4000), [1, 1])
        XCTAssertEqual(subject.progress(for: -1, at: 0), [])
        XCTAssertEqual(subject.progress(for: 2, at: 0), [])
    }

    func testAccompanimentAndZeroDurationSyllablesUseModelProgress() {
        let accompaniment = LyricsLine.accompaniment(AccompanimentKaraokeLine(syllables: [
            KaraokeSyllable(content: "a", start: 1000, end: 1000)
        ], start: 1000, end: 2000))
        XCTAssertEqual(timeline([accompaniment]).state(at: 1).syllableProgress, [[1]])
    }

    func testLargeNestedInputMatchesDirectIntervalChecks() {
        let lines = [line(0, 20000)] + (0..<1000).map { line($0 * 10, $0 * 10 + 5) }
        let subject = timeline(lines)
        for seconds in [-1.0, 0, 0.5, 5, 9.99, 10, 15, 25] {
            let state = subject.state(at: seconds)
            let expected = lines.indices.filter { lines[$0].isFocused(current: state.timeMilliseconds) }
            XCTAssertEqual(state.focusedLineIndices, expected)
        }
    }

    func testSeekReversesOffsetAndClampsNegativeTargets() {
        XCTAssertEqual(LyricsTimeline.seekSeconds(for: line(1500, 2000)), 1.5)
        XCTAssertEqual(LyricsTimeline.seekSeconds(for: line(1500, 2000), offsetMilliseconds: 500), 1)
        XCTAssertEqual(LyricsTimeline.seekSeconds(for: line(1500, 2000), offsetMilliseconds: -500), 2)
        XCTAssertEqual(LyricsTimeline.seekSeconds(for: line(1500, 2000), offsetMilliseconds: 2000), 0)
        XCTAssertEqual(LyricsTimeline.seekSeconds(for: line(-1000, 0)), 0)
    }

    func testSeekSaturatesExtremeOffsets() {
        XCTAssertEqual(LyricsTimeline.seekSeconds(for: line(Int.max, Int.max), offsetMilliseconds: Int.min),
                       Double(Int.max) / 1000)
        XCTAssertEqual(LyricsTimeline.seekSeconds(for: line(Int.min, Int.min), offsetMilliseconds: Int.max), 0)
    }
}
