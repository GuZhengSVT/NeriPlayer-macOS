// NeteaseYrcParser.swift
// NeriPlayer macOS —— 网易云 YRC（逐字）歌词解析器（移植规划 M4-T1）。
//
// 来源：accompanist-lyrics-core/src/commonMain/.../parser/NeteaseYrcParser.kt（125 行，逐分支移植）。
//
// 典型行格式：`[12580,3470](12580,250,0)难(12830,300,0)以...`
// 行头 `[起始时间,时长]`（毫秒）之后是若干 `(起始时间,时长,0)文本` 逐字块。
//
// 移植后的形状差异（与原库语义无关，仅语法）：原库是 Kotlin `object`，这里是
// `public struct NeteaseYrcParser: LyricsParser { public init() {} }` —— 与 LyricsParser.swift
// 的统一约定一致（协议要求实例方法，AutoParser 还要把解析器当值放进列表），调用点写
// `NeteaseYrcParser().parse(x)`。
//
// 有意保留的三处原始行为（都算「照抄」，不是遗漏）：
//   1. 只跳过「空行」和以 `{` 开头的行（新版歌词接口会在开头塞 JSON 版权行），
//      不额外做制作信息行过滤 —— 原库这个解析器就没调用 LrcMetadataHelper.isCreditLine。
//   2. 行头时间或时长解析不出 Int 就整行丢弃。`Int(x)` 对溢出返回 nil，与 Kotlin
//      `toIntOrNull()` 的溢出即 null 一致（逐字块那边不是这个口径，见第 3 条）。
//   3. 逐字块的 start/duration 解析不出 Int 时**跳过该块**，而不是退化成 Error 音节
//      （Lyricify SYL 解析器才是退化口径）。整行一个块都没有时退化成 `SyncedLine`。
//
// 另外两处与原库逐字对齐的实现细节：
//   - 正则用 Swift 原生 regex 字面量（≈ Kotlin `matchEntire` / `findAll`），
//     `](.*)` 里的 `]` 不需要转义：正则字面量里只有 `/(`（或 `\/`）会终止解析。
//   - 「英文词吞空格」的补偿里，`Char.isWhitespace()` 用本文件自带的 `isSpacingWhitespace`
//     表达，而不是 `Character.isWhitespace`：后者把 U+00A0 等也算空白，会让原本该补空格的
//     窄空格边界被跳过（详见该方法的注释）。

import Foundation

/// 网易云 YRC 逐字歌词解析器（原库 `NeteaseYrcParser`）。
public struct NeteaseYrcParser: LyricsParser {

    public init() {}

    /// 行头：`[起始时间,时长]` + 剩余内容。
    private static let lineRegex = #/^\[(\d+),\s*(\d+)](.*)$/#

    /// 逐字块：`(起始时间,时长,第三个字段)文本`。
    ///
    /// 第三个字段原库收 `-?\d+` 但完全不使用（网易云固定写 0），保留同样的容忍度。
    /// 文本段用 `[^()\r\n]*`（与 Kotlin 一致），遇到 `(` 就停，不会把下一个块吞进来。
    private static let syllableRegex = #/\((\d+),\s*(\d+),\s*-?\d+\)([^()\r\n]*)/#

    /// 判断这份内容是不是 YRC（原库 `canParse`）。
    ///
    /// 逐行都必须**整行**匹配行头（`matchEntire` → `wholeMatch`），且内容里至少有一个逐字块；
    /// 任何一行不满足就整份否决。所以 `[00:12.58]难以忘记`（LRC）与
    /// `[30348,198]<0,33,0>(<33,33,0>And`（逐字块用 `<>` 而不是 `()`）都会被拒。
    public func canParse(_ content: String) -> Bool {
        return content.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = trimmedLine.wholeMatch(of: Self.lineRegex) else { return false }
            // `containsMatchIn` ≈ 在子串上做第一次 `firstMatch`。
            return String(match.output.3).firstMatch(of: Self.syllableRegex) != nil
        }
    }

    /// 逐个解析每一行，解析不出的行直接丢掉（原库 `lines.mapNotNull(::parseLine)`）。
    public func parse(_ lines: [String]) -> SyncedLyrics {
        SyncedLyrics(lines: lines.compactMap(parseLine))
    }

    /// 解析一行；返回 nil 表示这行不是可用的 YRC 行（原库 `parseLine`）。
    private func parseLine(_ rawLine: String) -> LyricsLine? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("{") {
            return nil
        }

        guard let match = line.wholeMatch(of: Self.lineRegex) else { return nil }
        guard let lineStart = Int(match.output.1) else { return nil }
        guard let lineDuration = Int(match.output.2) else { return nil }
        let lineEnd = LyricsTime.adding(lineStart, lineDuration)
        let content = String(match.output.3)

        let rawSyllables = content.matches(of: Self.syllableRegex).compactMap { syllableMatch -> KaraokeSyllable? in
            guard let rawStart = Int(syllableMatch.output.1) else { return nil }
            guard let duration = Int(syllableMatch.output.2) else { return nil }
            return KaraokeSyllable(
                content: String(syllableMatch.output.3),
                start: rawStart,
                end: LyricsTime.adding(rawStart, duration)
            )
        }

        if rawSyllables.isEmpty {
            // 有行头时间却没有逐字块：退化成逐行对齐的 SyncedLine（内容为空则整行丢掉）。
            let plainText = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plainText.isEmpty else { return nil }
            return .synced(SyncedLine(
                content: plainText,
                translation: nil,
                start: lineStart,
                end: lineEnd
            ))
        }

        let syllables = normalizeSyllableSpacing(normalizeSyllableTimes(rawSyllables, lineStart: lineStart))
        guard let firstSyllable = syllables.first, let lastSyllable = syllables.last else { return nil }
        let effectiveStart = firstSyllable.start
        // 原库 `maxOf(lineEnd, syllables.last().end)`：行头时长可能比逐字块更短，取更晚的收尾。
        let effectiveEnd = max(lineEnd, lastSyllable.end)
        return .main(MainKaraokeLine(
            syllables: syllables,
            translation: nil,
            alignment: .unspecified,
            start: effectiveStart,
            end: effectiveEnd
        ))
    }

    /// 给相邻的 ASCII 单词音节补回被数据吞掉的词尾空格（原库 `normalizeSyllableSpacing`）。
    ///
    /// 网易云 YRC 里部分英文词会吞掉词尾空格（`(..)in(..)the` 本应是 "in the"），逐字渲染时
    /// 直接拼接就粘连成 "inthe"。这里只在「前一个音节以 ASCII 字母/数字结尾」且
    /// 「后一个音节以 ASCII 字母/数字开头」时补一个空格：CJK 逐字（字与字之间本来就没有空格）
    /// 与标点边界不满足条件，不受影响。
    private func normalizeSyllableSpacing(_ syllables: [KaraokeSyllable]) -> [KaraokeSyllable] {
        if syllables.count < 2 {
            return syllables
        }
        return syllables.enumerated().map { index, syllable in
            if index == syllables.count - 1 {
                return syllable
            }
            let current = syllable.content
            let next = syllables[index + 1].content
            // `guard let` 在 Swift 里是"必然成功"的取字符写法（用来替代原库 `String.last()` 的空判断
            // 与随后的 `!` 解包）；空串在 `guard let` 之前就被 `isEmpty` 挡掉了。
            guard let currentLast = current.last, let nextFirst = next.first else { return syllable }
            let needsSpace = !current.isEmpty && !next.isEmpty
                && !Self.isSpacingWhitespace(currentLast) && !Self.isSpacingWhitespace(nextFirst)
                && Self.isAsciiWordChar(currentLast) && Self.isAsciiWordChar(nextFirst)
            if needsSpace {
                var spaced = syllable
                spaced.content = current + " "
                return spaced
            }
            return syllable
        }
    }

    /// 音节时间是否是相对行首的（原库 `normalizeSyllableTimes`）。
    ///
    /// 判据只看首块：首块 start 小于行头 start 就认定整行都是相对时间，统一加上行头 start。
    /// 网易云的两种真实形态（绝对时间 / 相对时间）不会混在同一个行里。
    private func normalizeSyllableTimes(_ syllables: [KaraokeSyllable], lineStart: Int) -> [KaraokeSyllable] {
        guard let firstSyllable = syllables.first else { return syllables }
        let usesRelativeTime = firstSyllable.start < lineStart
        if !usesRelativeTime {
            return syllables
        }

        return syllables.map { syllable in
            var adjusted = syllable
            adjusted.start = LyricsTime.adding(lineStart, syllable.start)
            adjusted.end = LyricsTime.adding(lineStart, syllable.end)
            return adjusted
        }
    }

    /// 该字符是不是 ASCII 字母或数字（原库 `Char.isAsciiWordChar`）。
    private static func isAsciiWordChar(_ character: Character) -> Bool {
        return ("a"..."z").contains(character) || ("A"..."Z").contains(character) || ("0"..."9").contains(character)
    }

    /// 该字符是不是「会造成词间分隔的空白」（原库 `Char.isWhitespace()` 的移植）。
    ///
    /// 为什么不直接用 `Character.isWhitespace`：Swift 把 U+00A0（NBSP）、U+2007 等也算空白，
    /// 于是 `(1,2,0)in\u{00A0}(3,4,0)the` 这种「词尾是窄空格」的数据会被判成"已经有空格"
    /// 而跳过补偿；Kotlin 的 `Char.isWhitespace()` 对 U+00A0 返回 false，会补格，结果就分叉了。
    /// 所以这里显式列出空白码点：Kotlin 认的 ASCII 六个（`\t \n \u{0B} \u{0C} \r 空格`）加
    /// 各档 Unicode 空格（U+1680 / U+2000–U+2006 / U+2008–U+200A / U+2028 / U+2029 / U+205F /
    /// U+3000）加分隔控制符；**不含** U+00A0 / U+2007 / U+202F 这三个"不换行空格"和 U+200B
    /// 零宽断词符 —— 这几档在原库里都不算空白，必须补格，否则英文粘连的修复会漏。
    private static func isSpacingWhitespace(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            // 非单标量字符（emoji、组合序列）在原库视角下也走不到"空白"分支。
            return false
        }
        switch scalar {
        case "\t", "\n", "\u{0B}", "\u{0C}", "\r", " ":
            return true
        case "\u{1C}"..."\u{1F}", "\u{85}", "\u{1680}", "\u{2000}"..."\u{2006}",
             "\u{2008}"..."\u{200A}", "\u{2028}", "\u{2029}", "\u{205F}", "\u{3000}":
            return true
        default:
            return false
        }
    }
}
