// KaraokeModel.swift
// NeriPlayer macOS —— 逐字（卡拉OK）歌词模型层（移植规划 M4-T1）。
//
// 来源：accompanist-lyrics-core 的 model/karaoke/ 与 model/*/mapper/ 目录，纯 KMP 逻辑：
//   model/karaoke/KaraokeAlignment.kt               → KaraokeAlignment
//   model/karaoke/PhoneticLevel.kt                  → PhoneticLevel
//   model/karaoke/KaraokeSyllable.kt                → KaraokeSyllable
//   model/karaoke/KaraokeLine.kt                    → KaraokeLine 协议 + 两个实现 + progress/isFocused
//   model/karaoke/mapper/KaraokeSyllableCollectionMapper.kt → joinedContent / joinedPhonetic
//   model/karaoke/mapper/SyncedLineMapper.kt        → SyncedLine.toKaraokeLine()
//   model/synced/mapper/KaraokeLineMapper.kt        → KaraokeLine.toSyncedLine()
//
// 与原库的唯一语义差异（有意为之，两处都写在下面对应成员的注释里）：
//   1. KaraokeSyllable 原库用 `require(end >= start)` 抛异常；这里把 duration 钳到非负。
//      理由：解析器手上是用户提供的歌词文件，一个坏音节不该让整首歌变成无歌词。
//   2. 因此 duration == 0 时 progress 不能照抄除法（会得到 NaN）—— 直接判定为已走完，
//      让渲染端拿到 0…1 的值而不是 NaN。
//
// 原库 `KaraokeLine.copy(...)`（带全部默认参数的扩展函数）没有逐字搬：Swift 的参数默认值
// 不能引用 self，写不出「不传就保持原值」的签名。取而代之：两个实现类型的字段都是 var，
// 需要局部改写时改副本；跨枚举改写用 LyricsModel.swift 里的 withXxx 系列。

import Foundation

// MARK: - 枚举

/// 一行歌词的对齐方式（原库 `model/karaoke/KaraokeAlignment.kt`）。
public enum KaraokeAlignment: String, Sendable, CaseIterable {

    /// 靠左（多歌手场景的第一位）。
    case start

    /// 靠右（多歌手场景的第二位）。
    case end

    /// 未指定。
    case unspecified
}

/// 注音的粒度（原库 `model/karaoke/PhoneticLevel.kt`）。
public enum PhoneticLevel: String, Sendable, CaseIterable {

    /// 整行一个注音串。
    case line

    /// 每个音节一个注音。
    case syllable
}

// MARK: - 音节

/// 一个音节（原库 `model/karaoke/KaraokeSyllable.kt`）。
public struct KaraokeSyllable: Sendable, Equatable {

    /// 音节文本。
    public var content: String

    /// 起始时间，毫秒。
    public var start: Int

    /// 结束时间，毫秒。
    public var end: Int

    /// 该音节的注音，没有则为 nil。
    public var phonetic: String?

    public init(content: String, start: Int, end: Int, phonetic: String? = nil) {
        self.content = content
        self.start = start
        self.end = end
        self.phonetic = phonetic
    }

    /// 时长，毫秒。
    ///
    /// 原库在这里 `require(end >= start)`，坏数据会抛异常中断整份解析。移植后改成钳到非负：
    /// 解析器已经在能修的地方修（`rearrangeTime` 会把前一音节的 end 拉到后一音节的 start），
    /// 修不了的地方也不该炸掉整首歌。
    public var duration: Int { max(end - start, 0) }

    /// 当前时间在本音节内的进度 0…1。
    ///
    /// 原库 `progress(current)`；差别只在 `duration == 0`：原库会算出 NaN（0/0），
    /// 这里判定为「已走完」返回 1，渲染端不至于拿到 NaN 去乘宽度。
    public func progress(current: Int) -> Float {
        let value: Float
        if current < start {
            value = 0
        } else if current <= end {
            value = duration > 0 ? Float(current - start) / Float(duration) : 1
        } else {
            value = 1
        }
        return min(max(value, 0), 1)
    }
}

extension Collection where Element == KaraokeSyllable {

    /// 把所有音节文本拼起来（原库 `Collection<KaraokeSyllable>.contentToString()`，分隔符为空串）。
    public var joinedContent: String {
        map(\.content).joined()
    }

    /// 把所有音节注音拼起来（原库 `phoneticToString()`，分隔符是单个空格，缺注音的音节留空）。
    public var joinedPhonetic: String {
        map { $0.phonetic ?? "" }.joined(separator: " ")
    }
}

// MARK: - 音节对齐行

/// 按音节对齐的一行歌词（原库 `model/karaoke/KaraokeLine.kt` 的 sealed interface）。
///
/// 有两个实现：主唱行 `MainKaraokeLine`（可以挂伴奏行）与伴奏行 `AccompanimentKaraokeLine`。
public protocol KaraokeLine: LyricsTimedLine {

    /// 本行的音节序列。
    var syllables: [KaraokeSyllable] { get }

    /// 译文，没有则为 nil。
    var translation: String? { get }

    /// 多歌手场景下的对齐方式。
    var alignment: KaraokeAlignment { get }

    /// 注音，没有则为 nil。
    var phonetic: String? { get }
}

extension KaraokeLine {

    /// 当前时间在本行内的进度 0…1（原库 `KaraokeLine.progress`）。
    public func progress(current: Int) -> Float {
        let value: Float
        if current < start {
            value = 0
        } else if isFocused(current: current) {
            value = duration > 0 ? Float(current - start) / Float(duration) : 1
        } else if current > end {
            value = 1
        } else {
            value = 0
        }
        return min(max(value, 0), 1)
    }

    /// 当前时间是否落在本行区间内（原库 `KaraokeLine.isFocused`）。
    ///
    /// 原库注释提到「伴奏行的判定会略微提前/延后开始，好让它多显示一会儿」，但代码里
    /// Main/Accompaniment 都没有覆写这个方法，实际行为就是闭区间判定。移植保持实际行为。
    public func isFocused(current: Int) -> Bool {
        current >= start && current <= end
    }

    /// 折算成逐行对齐的行（原库 `model/synced/mapper/KaraokeLineMapper.kt`）：
    /// 正文由音节拼出并去掉首尾空白。
    public func toSyncedLine() -> SyncedLine {
        SyncedLine(
            content: syllables.joinedContent.trimmingCharacters(in: .whitespacesAndNewlines),
            translation: translation,
            start: start,
            end: end
        )
    }
}

/// 主唱的音节对齐行（原库 `KaraokeLine.MainKaraokeLine`）。
public struct MainKaraokeLine: KaraokeLine {

    public var syllables: [KaraokeSyllable]
    public var translation: String?
    public var alignment: KaraokeAlignment
    public var start: Int
    public var end: Int
    public var phonetic: String?

    /// 同一时间点上的伴奏/和声行，来自 `[bg:…]` 标签。
    public var accompanimentLines: [AccompanimentKaraokeLine]?

    /// 时长，毫秒。容错口径同 `SyncedLine`：音节乱序时钳到非负。
    public var duration: Int { max(end - start, 0) }

    public init(
        syllables: [KaraokeSyllable],
        translation: String? = nil,
        alignment: KaraokeAlignment = .unspecified,
        start: Int,
        end: Int,
        phonetic: String? = nil,
        accompanimentLines: [AccompanimentKaraokeLine]? = nil
    ) {
        self.syllables = syllables
        self.translation = translation
        self.alignment = alignment
        self.start = start
        self.end = end
        self.phonetic = phonetic
        self.accompanimentLines = accompanimentLines
    }
}

/// 伴奏/和声的音节对齐行（原库 `KaraokeLine.AccompanimentKaraokeLine`）。
public struct AccompanimentKaraokeLine: KaraokeLine {

    public var syllables: [KaraokeSyllable]
    public var translation: String?
    public var alignment: KaraokeAlignment
    public var start: Int
    public var end: Int
    public var phonetic: String?

    /// 时长，毫秒。容错口径同 `SyncedLine`。
    public var duration: Int { max(end - start, 0) }

    public init(
        syllables: [KaraokeSyllable],
        translation: String? = nil,
        alignment: KaraokeAlignment = .unspecified,
        start: Int,
        end: Int,
        phonetic: String? = nil
    ) {
        self.syllables = syllables
        self.translation = translation
        self.alignment = alignment
        self.start = start
        self.end = end
        self.phonetic = phonetic
    }
}

// MARK: - 互转

extension SyncedLine {

    /// 把逐行对齐的行折算成单音节的主唱行（原库 `model/karaoke/mapper/SyncedLineMapper.kt`）。
    ///
    /// 原库这里构造 `KaraokeSyllable` 时若 `end < start` 会抛异常；本移植靠 `KaraokeSyllable`
    /// 的钳制容错（见该类型注释）。
    public func toKaraokeLine() -> MainKaraokeLine {
        MainKaraokeLine(
            syllables: [KaraokeSyllable(content: content, start: start, end: end)],
            translation: translation,
            alignment: .unspecified,
            start: start,
            end: end
        )
    }
}
