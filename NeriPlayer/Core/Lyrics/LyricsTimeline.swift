// LyricsTimeline.swift
// M4-T3/T5: overlap-safe playback-to-lyrics time binding.
import Foundation

/// A playback-time projection. Line indices always refer to the original lyrics array.
public struct LyricsTimelineState: Sendable, Equatable {
    public let timeMilliseconds: Int
    public let focusedLineIndices: [Int]
    public let scrollLineIndex: Int?

    /// One entry per lyric line. Only focused karaoke lines contain progress values;
    /// inactive and plain-text lines contain empty arrays.
    public let syllableProgress: [[Float]]

    public init(timeMilliseconds: Int, focusedLineIndices: [Int], scrollLineIndex: Int?, syllableProgress: [[Float]]) {
        self.timeMilliseconds = timeMilliseconds
        self.focusedLineIndices = focusedLineIndices
        self.scrollLineIndex = scrollLineIndex
        self.syllableProgress = syllableProgress
    }
}

/// Immutable interval index for playback binding, independent of the player and UI.
public struct LyricsTimeline: Sendable {
    private struct Interval: Sendable {
        let lineIndex: Int
        let start: Int
        let end: Int
    }

    public let lyrics: SyncedLyrics
    private let intervals: [Interval]
    private let maximumEnds: [Int]
    private let syllables: [[KaraokeSyllable]]

    public init(lyrics: SyncedLyrics) {
        self.lyrics = lyrics
        var unsortedIntervals: [Interval] = []
        unsortedIntervals.reserveCapacity(lyrics.lines.count)
        for (index, line) in lyrics.lines.enumerated() {
            unsortedIntervals.append(Interval(lineIndex: index, start: line.start, end: line.end))
        }
        let sortedIntervals = unsortedIntervals.sorted { left, right in
            if left.start != right.start { return left.start < right.start }
            return left.lineIndex < right.lineIndex
        }
        intervals = sortedIntervals
        var lineSyllables: [[KaraokeSyllable]] = []
        lineSyllables.reserveCapacity(lyrics.lines.count)
        for line in lyrics.lines { lineSyllables.append(line.karaokeLine?.syllables ?? []) }
        syllables = lineSyllables

        // A range maximum tree prunes expired subranges even when an early long line
        // overlaps thousands of later, shorter lines.
        var ends = Array(repeating: Int.min, count: max(1, sortedIntervals.count * 4))
        Self.buildMaximumEnds(sortedIntervals, into: &ends, node: 1, lower: 0, upper: sortedIntervals.count)
        maximumEnds = ends
    }

    /// Positive offset advances the lyrics. The caller combines file and user offsets.
    /// Nonfinite seconds fall back to zero; finite out-of-range values saturate.
    public func state(at seconds: Double, offsetMilliseconds: Int = 0) -> LyricsTimelineState {
        let current = LyricsTime.adding(Self.milliseconds(from: seconds), offsetMilliseconds)
        let firstAfter = firstInterval(after: current)
        var focused: [Int] = []
        collectFocused(at: current, before: firstAfter, node: 1, lower: 0,
                       upper: intervals.count, into: &focused)
        focused.sort()

        let scrollIndex: Int?
        if let firstFocused = focused.first {
            scrollIndex = firstFocused
        } else if firstAfter < intervals.count {
            scrollIndex = intervals[firstAfter].lineIndex
        } else {
            scrollIndex = intervals.last?.lineIndex
        }

        var progress = Array(repeating: [Float](), count: syllables.count)
        for index in focused {
            progress[index] = self.progress(for: index, at: current)
        }
        return LyricsTimelineState(timeMilliseconds: current, focusedLineIndices: focused,
                                   scrollLineIndex: scrollIndex, syllableProgress: progress)
    }

    /// Exact syllable progress for any original line index, including inactive lines.
    public func progress(for lineIndex: Int, at timeMilliseconds: Int) -> [Float] {
        guard syllables.indices.contains(lineIndex) else { return [] }
        return syllables[lineIndex].map { $0.progress(current: timeMilliseconds) }
    }

    /// Inverse of the playback offset, bounded to nonnegative playback time.
    public static func seekSeconds(for line: LyricsLine, offsetMilliseconds: Int = 0) -> Double {
        Double(max(0, LyricsTime.subtracting(line.start, offsetMilliseconds))) / 1000
    }

    private static func milliseconds(from seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        let milliseconds = seconds * 1000
        if milliseconds >= Double(Int.max) { return Int.max }
        if milliseconds <= Double(Int.min) { return Int.min }
        // Correct a one-ULP multiplication error at exact millisecond boundaries.
        let corrected = milliseconds >= 0 ? milliseconds.nextUp : milliseconds.nextDown
        return Int(corrected.rounded(.towardZero))
    }

    private func firstInterval(after time: Int) -> Int {
        var lower = 0
        var upper = intervals.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if intervals[middle].start <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func buildMaximumEnds(
        _ intervals: [Interval], into ends: inout [Int], node: Int, lower: Int, upper: Int
    ) {
        guard lower < upper else { return }
        if upper - lower == 1 {
            ends[node] = intervals[lower].end
            return
        }
        let middle = lower + (upper - lower) / 2
        buildMaximumEnds(intervals, into: &ends, node: node * 2, lower: lower, upper: middle)
        buildMaximumEnds(intervals, into: &ends, node: node * 2 + 1, lower: middle, upper: upper)
        ends[node] = max(ends[node * 2], ends[node * 2 + 1])
    }

    // Tree traversal keeps node and interval bounds explicit.
    // swiftlint:disable:next function_parameter_count
    private func collectFocused(
        at time: Int, before firstAfter: Int, node: Int, lower: Int, upper: Int,
        into focused: inout [Int]
    ) {
        guard lower < upper, lower < firstAfter, maximumEnds[node] >= time else { return }
        if upper - lower == 1 {
            let interval = intervals[lower]
            if time >= interval.start, time <= interval.end {
                focused.append(interval.lineIndex)
            }
            return
        }
        let middle = lower + (upper - lower) / 2
        collectFocused(at: time, before: firstAfter, node: node * 2,
                       lower: lower, upper: middle, into: &focused)
        collectFocused(at: time, before: firstAfter, node: node * 2 + 1,
                       lower: middle, upper: upper, into: &focused)
    }
}
