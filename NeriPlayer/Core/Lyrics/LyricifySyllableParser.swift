// LyricifySyllableParser.swift
// NeriPlayer macOS —— Lyricify Syllable（LYS）逐字歌词解析器（移植规划 M4-T1）。
//
// 来源：accompanist-lyrics-core/src/commonMain/.../parser/LyricifySyllableParser.kt（96 行，逐分支移植）。
// 格式规范：https://github.com/WXRIW/Lyricify-App/blob/main/docs/Lyricify%204/Lyrics.md
//   形如 `[4]I (0,214)promise (214,345)that ...`；`[n]` 是小节属性，后面的每个
//   `(起始时间,时长)文本` 是一个音节，时间是**相对**本行的毫秒数。
//
// 移植后的形状差异（与原库语义无关，仅语法）：原库是 Kotlin `object`，这里是
// `public struct LyricifySyllableParser: LyricsParser { public init() {} }` —— 与 LyricsParser.swift
// 的统一约定一致，调用点写 `LyricifySyllableParser().parse(x)`。
//
// 有三个地方是**有意的宽容**，都对齐原库（不是漏判）：
//   1. `Int(x)` 失败时音节退化成 `("Error", 0, 0)`，整行仍然保留 —— 原库是
//      `KaraokeSyllable("Error", 0, 0)`，宁可显示一个占位音节也不丢整行。
//   2. 属性数字解析失败（`[x]`）落回 0，按主唱行处理。
//   3. 「前有主唱行就挂成伴奏」这一步不递归/不回溯：遇到伴奏行时若上一行也是伴奏行，
//      就直接独立成行（原库的 `data.last()` 分支就是这样）。
//
// 关于 `isDigitsOnly()`：原库放在 utils/TimeUtils.kt（只有本解析器调用），移植后同样放在对应的
// `LyricsTime` 里（`LyricsTime.isDigitsOnly`），不另开私有实现 —— 保持与原库的文件归属一致。

import Foundation

/// Lyricify Syllable 解析器（原库 `LyricifySyllableParser`）。
public struct LyricifySyllableParser: LyricsParser {

    public init() {}

    /// 音节块：`(起始时间,时长)文本`，文本取到下一个 `(` 之前（`.*?` 非贪婪，允许空文本）。
    private static let syllableRegex = #/(.*?)\((\d+),(\d+)\)/#

    /// `[数字]` 小节属性。
    private static let attributeRegex = #/\[(\d+)\]/#

    /// 判断这份内容是不是 LYS（原库 `canParse`）。
    ///
    /// 注意原库这里是**运行时构造正则**（`"[a-zA-Z]+\s*\(\d+,\d+\)".toRegex()`）而不是像
    /// 其他正则那样放进字段里；移植后提成静态常量更省重复编译，判据完全一样：
    /// 「字母 + 可选空白 + `(数字,数字)`」出现过就算 LYS。
    private static let detector = #/[a-zA-Z]+\s*\(\d+,\d+\)/#

    public func canParse(_ content: String) -> Bool {
        return content.firstMatch(of: Self.detector) != nil
    }

    /// 解析若干行（原库 `parse(lines)`）。
    ///
    /// 先剔除已知 LRC 头部标签行（`removeAttributes`），再逐行解析；`[n]` 属性落在 0…5 之外的
    /// 行是伴奏/和声：如果上一行是主唱行就挂到它的 `accompanimentLines`，否则独立成行。
    public func parse(_ lines: [String]) -> SyncedLyrics {
        let lyricsLines = LrcMetadataHelper.removeAttributes(lines)
        var data: [LyricsLine] = []
        // `where` 子句对应原库 `forEach { if (line.isNotBlank()) { … } }` 的外层判断：
        // 全空白行直接跳过（`isNotBlank()` 不是 `isNotEmpty()`）。
        for line in lyricsLines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = parseLine(line)
            // `data.last` 是可选值，`case ... =` 会在它为空时匹配失败并落到 else 分支。
            if case .accompaniment(let accompaniment) = parsed,
               case .main(var last) = data.last {
                // 上一行是主唱行：把它变成"带伴奏"的主唱行。
                last.accompanimentLines = (last.accompanimentLines ?? []) + [accompaniment]
                data[data.count - 1] = .main(last)
            } else {
                data.append(parsed)
            }
        }
        return SyncedLyrics(lines: data)
    }

    /// 解析一行（原库 `parseLine`）。
    private func parseLine(_ line: String) -> LyricsLine {
        let real: String
        var isAccompaniment = false
        let alignment: KaraokeAlignment

        // 原库判据：同时含 `]` 与 `[`，且两者下标相差 2 —— 等价于"最前面的 `[x]` 里只有一个字符"。
        if line.contains("]"), let bracketStart = line.firstIndex(of: "["),
           let bracketEnd = line.firstIndex(of: "]"),
           line.distance(from: bracketStart, to: bracketEnd) == 2 {
            real = String(line[line.index(after: bracketEnd)...])
            let attribute = line.firstMatch(of: Self.attributeRegex).flatMap { Int($0.output.1) } ?? 0

            if !(0...5).contains(attribute) {
                isAccompaniment = true
            }
            // 注意 `attribute == 8` 这一支永远走不到（8 已经被上一步判成伴奏），
            // 原库就是这样写的，这里照样保留，避免"看起来修正了"却与原库行为分叉。
            alignment = (attribute == 2 || attribute == 5 || attribute == 8) ? .end : .start
        } else {
            real = line
            isAccompaniment = false
            alignment = .start
        }

        let syllables = real.matches(of: Self.syllableRegex).map { matched -> KaraokeSyllable in
            let startText = String(matched.output.2)
            let durationText = String(matched.output.3)
            // 原库若"数字"不是纯数字字符就退化成 Error；`Int(...)` 负责真正的数值转换
            // （全角数字 `١` 虽能通过字符判断，但 Int 解析不出，同样退化成 0，与原库一致）。
            if LyricsTime.isDigitsOnly(startText), LyricsTime.isDigitsOnly(durationText),
               let start = Int(startText), let duration = Int(durationText) {
                return KaraokeSyllable(content: String(matched.output.1), start: start, end: start + duration)
            }
            return KaraokeSyllable(content: "Error", start: 0, end: 0)
        }

        let startTime = syllables.first?.start ?? 0
        let endTime = syllables.last?.end ?? 0

        return isAccompaniment
            ? .accompaniment(AccompanimentKaraokeLine(
                syllables: syllables,
                translation: nil,
                alignment: alignment,
                start: startTime,
                end: endTime
            ))
            : .main(MainKaraokeLine(
                syllables: syllables,
                translation: nil,
                alignment: alignment,
                start: startTime,
                end: endTime
            ))
    }
}
