// LyricsModel.swift
// NeriPlayer macOS —— 歌词模型层（移植规划 M4-T1）。
//
// 来源：accompanist-lyrics-core 的 model/ 目录，纯 KMP 逻辑，逐文件移植、不改语义：
//   model/ISyncedLine.kt       → LyricsTimedLine
//   model/synced/SyncedLine.kt → SyncedLine
//   model/SyncedLyrics.kt      → SyncedLyrics（含两个二分查找）
//   model/Attributes.kt        → Attributes
//   model/Artist.kt            → Artist
//
// 时间单位：全模块统一毫秒 Int（与原库一致）。它与 Track.duration（秒，Double?）不是一回事，
// 换算是 M4-T3 的事；模型层不做任何单位转换 —— 少一次转换就少一次舍入。
//
// 为什么把 List<ISyncedLine> 表达成 enum LyricsLine：
// 原库用 sealed interface 表达「一行要么是逐行对齐的 SyncedLine，要么是按音节对齐的
// MainKaraokeLine / AccompanimentKaraokeLine」，解析器里到处是
// `when (line) { is KaraokeLine -> …; is SyncedLine -> … }`。Swift 里「三选一」最贴的载体是
// enum：解析端 switch 必须穷尽（原库那些 `else -> ""` 兜底分支移植后编译期就不存在了），
// 渲染端也能直接拿到音节数组。协议 LyricsTimedLine 保留下来，给只关心 start/end/duration
// 的通用逻辑用。
//
// 容错口径：原库 SyncedLine/KaraokeLine 都把 duration 钳到非负（`(end - start).coerceAtLeast(0)`），
// 因为乱序时间戳不该让整份歌词解析失败。这里保持同样口径，并把 KaraokeSyllable 里会抛异常的
// `require(end >= start)` 也改成钳制（见 KaraokeModel.swift）—— 一个音节坏掉就让整首歌没歌词，
// 对播放器是不可接受的降级。
//
// `UncheckedSyncedLine`（原库同文件的过渡类型，允许 end < start）也一并移植，但不进
// `LyricsLine` 联合类型：原模块里没有任何解析器产出它（全模块 grep 确认），加 case 只会让
// 所有 switch 多出一条走不到的分支；将来真有消费者时再加，编译器会把要补的地方逐个点出来。

import Foundation

// MARK: - 时间轴行

/// 一行带时间轴的歌词（原库 `model/ISyncedLine.kt`）。
///
/// 只描述「什么时候开始 / 什么时候结束」，不关心这行是逐行对齐还是按音节对齐。
public protocol LyricsTimedLine: Equatable, Sendable {

    /// 起始时间，毫秒。
    var start: Int { get }

    /// 结束时间，毫秒。
    var end: Int { get }

    /// 时长，毫秒。已钳到非负。
    var duration: Int { get }
}

/// 逐行对齐的一句歌词（原库 `model/synced/SyncedLine.kt`）。
public struct SyncedLine: LyricsTimedLine {

    /// 歌词正文。
    public var content: String

    /// 译文，没有则为 nil。
    public var translation: String?

    /// 起始时间，毫秒。
    public var start: Int

    /// 结束时间，毫秒。
    public var end: Int

    /// 时长，毫秒。
    ///
    /// 原库注释：乱序/异常时间戳会让 end < start，此处把时长钳到非负，避免单行构造失败导致
    /// 整份歌词解析不出来。
    public var duration: Int { LyricsTime.duration(start: start, end: end) }

    public init(content: String, translation: String? = nil, start: Int, end: Int) {
        self.content = content
        self.translation = translation
        self.start = start
        self.end = end
    }
}

/// 逐行歌词的「未校验」版本（原库 `model/synced/SyncedLine.kt` 的 `UncheckedSyncedLine`）。
///
/// 原库把它当解析中途的过渡类型用：中途允许 `end < start`，最后再 `toSyncedLine()` 收敛。
/// 移植后它与 `SyncedLine` 的差别只剩类型名 —— Swift 的 `SyncedLine` 构造本来就不抛错，
/// 两者的 `duration` 钳制口径完全一致。
public struct UncheckedSyncedLine: LyricsTimedLine {

    /// 歌词正文。
    public var content: String

    /// 译文，没有则为 nil。
    public var translation: String?

    /// 起始时间，毫秒。
    public var start: Int

    /// 结束时间，毫秒。
    public var end: Int

    /// 时长，毫秒，钳到非负（原库 `takeIf { it >= 0 } ?: 0`，与 `SyncedLine` 同口径）。
    public var duration: Int { LyricsTime.duration(start: start, end: end) }

    public init(content: String, translation: String? = nil, start: Int, end: Int) {
        self.content = content
        self.translation = translation
        self.start = start
        self.end = end
    }

    /// 收敛成校验过的逐行歌词（原库 `toSyncedLine()`）。
    public func toSyncedLine() -> SyncedLine {
        SyncedLine(content: content, translation: translation, start: start, end: end)
    }
}

// MARK: - 行的三选一表示

/// 歌词列表里的一行（原库 `List<ISyncedLine>` 的元素，见文件头「为什么用 enum」）。
public enum LyricsLine: Sendable, Equatable {

    /// 逐行对齐的一行。
    case synced(SyncedLine)

    /// 主唱的音节对齐行（原库 `KaraokeLine.MainKaraokeLine`），可能带伴奏行。
    case main(MainKaraokeLine)

    /// 伴奏/和声的音节对齐行（原库 `KaraokeLine.AccompanimentKaraokeLine`）。
    case accompaniment(AccompanimentKaraokeLine)
}

extension LyricsLine: LyricsTimedLine {

    public var start: Int {
        switch self {
        case .synced(let line): return line.start
        case .main(let line): return line.start
        case .accompaniment(let line): return line.start
        }
    }

    public var end: Int {
        switch self {
        case .synced(let line): return line.end
        case .main(let line): return line.end
        case .accompaniment(let line): return line.end
        }
    }

    public var duration: Int {
        switch self {
        case .synced(let line): return line.duration
        case .main(let line): return line.duration
        case .accompaniment(let line): return line.duration
        }
    }

    /// 音节对齐行视图；逐行对齐的行返回 nil。
    public var karaokeLine: (any KaraokeLine)? {
        switch self {
        case .synced: return nil
        case .main(let line): return line
        case .accompaniment(let line): return line
        }
    }

    /// 显示用正文。
    ///
    /// 对应原库 `when (line) { is KaraokeLine -> line.syllables.contentToString().trim();
    /// is SyncedLine -> line.content }`：音节行的正文由音节拼出并去掉首尾空白，
    /// 逐行对齐的行原样返回（原库那个 `else -> ""` 兜底分支在 enum 上没有对应物）。
    public var content: String {
        switch self {
        case .synced(let line): return line.content
        case .main(let line): return line.syllables.joinedContent.trimmingCharacters(in: .whitespacesAndNewlines)
        case .accompaniment(let line):
            return line.syllables.joinedContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 两种行都去空白后的正文（原库另一些分支对 SyncedLine 也调了 `trim()`）。
    public var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 译文，没有则为 nil。
    public var translation: String? {
        switch self {
        case .synced(let line): return line.translation
        case .main(let line): return line.translation
        case .accompaniment(let line): return line.translation
        }
    }

    /// 对齐方式；逐行对齐的行返回 nil（它没有多歌手对齐的概念）。
    public var alignment: KaraokeAlignment? {
        switch self {
        case .synced: return nil
        case .main(let line): return line.alignment
        case .accompaniment(let line): return line.alignment
        }
    }

    /// 换一行译文，其余字段不变。
    public func withTranslation(_ translation: String?) -> LyricsLine {
        switch self {
        case .synced(var line):
            line.translation = translation
            return .synced(line)
        case .main(var line):
            line.translation = translation
            return .main(line)
        case .accompaniment(var line):
            line.translation = translation
            return .accompaniment(line)
        }
    }

    /// 换对齐方式，其余字段不变。逐行对齐的行没有对齐概念，原样返回。
    public func withAlignment(_ alignment: KaraokeAlignment) -> LyricsLine {
        switch self {
        case .synced:
            return self
        case .main(var line):
            line.alignment = alignment
            return .main(line)
        case .accompaniment(var line):
            line.alignment = alignment
            return .accompaniment(line)
        }
    }

    /// 换结束时间，其余字段不变。
    public func withEnd(_ end: Int) -> LyricsLine {
        switch self {
        case .synced(var line):
            line.end = end
            return .synced(line)
        case .main(var line):
            line.end = end
            return .main(line)
        case .accompaniment(var line):
            line.end = end
            return .accompaniment(line)
        }
    }

    /// 换起始时间，其余字段不变。
    public func withStart(_ start: Int) -> LyricsLine {
        switch self {
        case .synced(var line):
            line.start = start
            return .synced(line)
        case .main(var line):
            line.start = start
            return .main(line)
        case .accompaniment(var line):
            line.start = start
            return .accompaniment(line)
        }
    }

    /// 换音节，其余字段不变。逐行对齐的行原样返回。
    public func withSyllables(_ syllables: [KaraokeSyllable]) -> LyricsLine {
        switch self {
        case .synced:
            return self
        case .main(var line):
            line.syllables = syllables
            return .main(line)
        case .accompaniment(var line):
            line.syllables = syllables
            return .accompaniment(line)
        }
    }

    /// 换注音，其余字段不变。逐行对齐的行原样返回。
    public func withPhonetic(_ phonetic: String?) -> LyricsLine {
        switch self {
        case .synced:
            return self
        case .main(var line):
            line.phonetic = phonetic
            return .main(line)
        case .accompaniment(var line):
            line.phonetic = phonetic
            return .accompaniment(line)
        }
    }

    /// 折算成逐行对齐的行（原库 `KaraokeLine.toSyncedLine()`）；已经是逐行对齐就原样返回。
    public func toSyncedLine() -> SyncedLine {
        switch self {
        case .synced(let line): return line
        case .main(let line): return line.toSyncedLine()
        case .accompaniment(let line): return line.toSyncedLine()
        }
    }

    /// 当前时间的播放进度 0…1。逐行对齐的行按行内线性插值（原库 SyncedLine 没有该方法，
    /// 但渲染端 T4 需要它，故在此统一；算法与卡拉OK 行的 `progress(current:)` 一致）。
    public func progress(current: Int) -> Float {
        switch self {
        case .synced(let line):
            return LyricsTime.progress(current: current, start: line.start, end: line.end)
        case .main(let line): return line.progress(current: current)
        case .accompaniment(let line): return line.progress(current: current)
        }
    }

    /// 当前时间是否落在这行的区间内。
    public func isFocused(current: Int) -> Bool {
        current >= start && current <= end
    }
}

// MARK: - 元数据

/// 歌词文件里的制作人员（原库 `model/Artist.kt`）。
public struct Artist: Sendable, Equatable {

    /// 角色，例如 "作词"。
    public var type: String

    /// 姓名。
    public var name: String

    public init(type: String, name: String) {
        self.type = type
        self.name = name
    }
}

/// LRC 头部的已知元数据（原库 `model/Attributes.kt`）。
///
/// `offset`/`duration` 在 `LrcMetadataHelper.parse` 里缺失时落到 0（不是 nil），
/// 与原库一致；保留可选类型是为了沿用原库字段定义。
public struct Attributes: Sendable, Equatable {

    public var artist: String?
    public var album: String?
    public var title: String?
    public var offset: Int?
    public var duration: Int?

    public init(
        artist: String? = nil,
        album: String? = nil,
        title: String? = nil,
        offset: Int? = nil,
        duration: Int? = nil
    ) {
        self.artist = artist
        self.album = album
        self.title = title
        self.offset = offset
        self.duration = duration
    }
}

// MARK: - 整份歌词

/// 一整份时间轴歌词（原库 `model/SyncedLyrics.kt`）。
public struct SyncedLyrics: Sendable, Equatable {

    /// 所有行，按时间升序（解析器负责排序）。
    public var lines: [LyricsLine]

    /// 歌名，来自 `[ti:…]`。
    public var title: String

    /// 原库的歌曲 id，默认 "0"。
    public var id: String

    /// 演唱者列表；原库默认是空列表而不是 nil。
    public var artists: [Artist]?

    public init(
        lines: [LyricsLine] = [],
        title: String = "",
        id: String = "0",
        artists: [Artist]? = []
    ) {
        self.lines = lines
        self.title = title
        self.id = id
        self.artists = artists
    }

    /// 找出在 `time` 时刻应当高亮的第一行（原库 `getCurrentFirstHighlightLineIndexByTime`）。
    ///
    /// 在 `lines` 上做二分：命中某行的 `start...end` 就返回该行下标；没有任何行覆盖 `time` 时，
    /// 返回紧随其后的那一行下标（`time` 在所有行之后则返回 `lines.count`）。
    /// 空列表返回 0，与原库一致。
    public func currentFirstHighlightLineIndex(at time: Int) -> Int {
        if lines.isEmpty { return 0 }

        var low = 0
        var high = lines.count - 1
        var resultIndex = lines.count

        while low <= high {
            let mid = low + (high - low) / 2
            let line = lines[mid]

            if line.start > time {
                resultIndex = mid
                high = mid - 1
            } else if line.end < time {
                low = mid + 1
            } else {
                resultIndex = mid
                high = mid - 1
            }
        }

        if resultIndex < lines.count, time >= lines[resultIndex].start, time <= lines[resultIndex].end {
            return resultIndex
        }
        return min(low, lines.count)
    }

    /// 找出在 `time` 时刻应当高亮的**所有**行（原库 `getCurrentAllHighlightLineIndicesByTime`）。
    ///
    /// 给对唱/和声这类时间轴重叠的歌词用。返回值升序；没有命中就返回空数组。
    ///
    /// 注意它与 `currentFirstHighlightLineIndex(at:)` 的返回语义**不同**：这里没有命中返回 `[]`，
    /// 而前者会返回"下一行"的下标。两者都是原库行为，改动会让 T3/T4 的高亮逻辑对不上。
    public func currentAllHighlightLineIndices(at time: Int) -> [Int] {
        if lines.isEmpty { return [] }

        var results: [Int] = []

        var low = 0
        var high = lines.count - 1
        var firstAfterIndex = lines.count

        while low <= high {
            let mid = low + (high - low) / 2
            if lines[mid].start > time {
                firstAfterIndex = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }

        var index = firstAfterIndex - 1
        while index >= 0 {
            let line = lines[index]
            if time >= line.start, time <= line.end {
                results.append(index)
            }
            index -= 1
        }

        return results.sorted()
    }
}
