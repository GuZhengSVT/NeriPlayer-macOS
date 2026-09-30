// EnhancedLrcExporter.swift
// NeriPlayer macOS —— Enhanced LRC 导出器（移植规划 M4-T1）。
//
// 来源：accompanist-lyrics-core/src/commonMain/.../exporter/EnhancedLrcExporter.kt（逐分支移植）。
//
// 输出形状（原库支持的全部四件事）：
//   [ti:…] / [ar:…]                    头部标签
//   [mm:ss.SSS]<mm:ss.SSS>音节…<end>   行时间戳 + 音节时间戳 + 收尾时间戳
//   [bg:<…>音节…<end>]                 伴奏行
//   [mm:ss.SSS]译文                    同时间戳的第二行当译文
//
// 与原库的形状差异：
//   1. Kotlin object → 无状态 struct，调用点写 `EnhancedLrcExporter().export(x)`。
//   2. 原库 `when (line) { is SyncedLine -> …; is KaraokeLine -> … }`：这里 enum 没有"其他"
//      分支，改成三个 case（`.main` / `.accompaniment` 合起来就是原库的 KaraokeLine 分支，
//      只有主唱行才导出它挂着的 accompanimentLines）。
//   3. 音节串由私有方法 `syllableTimingString` 生成，两种卡拉OK行共用 —— 原库也是同一个
//      `joinToString("") { … } + "<end>"` 表达式，抽出来只是去重，输出逐字节相同；
//      同理 `exportKaraoke`（卡拉OK行 + 译文两行）与协议扩展里的 `exportLrcHeader`
//      （[ti:]/[ar:] 头部）也只是把原库重复的段落提取成方法。
//   4. 与 LrcExporter 一样显式拼 "\n"（JVM `appendLine` 的行为），不做平台换行适配。

import Foundation

/// Enhanced LRC / 逐字歌词导出器（原库 `EnhancedLrcExporter`）。
public struct EnhancedLrcExporter: LyricsExporter {

    public init() {}

    public func export(_ lyrics: SyncedLyrics) -> String {
        if lyrics.lines.isEmpty { return "" }

        var builder = exportLrcHeader(lyrics)

        for line in lyrics.lines {
            let timeTag = "[\(LyricsTime.formatted(line.start))]"

            switch line {
            case .synced(let synced):
                builder += "\(timeTag)\(synced.content)\n"
                if let translation = synced.translation {
                    builder += "\(timeTag)\(translation)\n"
                }

            case .main(let main):
                builder += exportKaraoke(main, timeTag: timeTag)
                for bgLine in main.accompanimentLines ?? [] {
                    builder += "[bg:\(syllableTimingString(bgLine))]\n"
                    if let translation = bgLine.translation {
                        // 伴奏行的译文也包在 [bg:…] 里，用音节的起止时间戳夹住，好让重新解析时
                        // 还能被 combineRawWithTranslation 配回这一行。
                        builder += "[bg:<\(LyricsTime.formatted(bgLine.start))>"
                            + "\(translation)"
                            + "<\(LyricsTime.formatted(bgLine.end))>]\n"
                    }
                }

            case .accompaniment(let accompaniment):
                // 原库的 KaraokeLine 分支对伴奏行与主唱行一视同仁（伴奏行没有 accompanimentLines，
                // 所以这里只导出它自己）。
                builder += exportKaraoke(accompaniment, timeTag: timeTag)
            }
        }

        return builder
    }

    /// 卡拉OK行（主唱/伴奏）共用的导出形状：行时间戳 + 音节串一行，译文再起一行同时间戳
    /// （原库 `is KaraokeLine` 分支里的前两行 `appendLine`）。
    private func exportKaraoke(_ line: any KaraokeLine, timeTag: String) -> String {
        var block = "\(timeTag)\(syllableTimingString(line))\n"
        if let translation = line.translation {
            block += "\(timeTag)\(translation)\n"
        }
        return block
    }

    /// `<start>内容` 逐个音节拼起来，末尾补一个 `<end>` 收尾时间戳
    /// （原库 `syllables.joinToString("") { … } + "<${line.end.toTimeFormattedString()}>"`）。
    ///
    /// 收尾时间戳是必须的：解析时它给出最后一个音节的结束时间（见 EnhancedLrcParser.rearrangeTime）。
    private func syllableTimingString(_ line: any KaraokeLine) -> String {
        var result = ""
        for syllable in line.syllables {
            result += "<\(LyricsTime.formatted(syllable.start))>\(syllable.content)"
        }
        result += "<\(LyricsTime.formatted(line.end))>"
        return result
    }
}

/// 对应原库的 `String.isBlank()`（同 EnhancedLrcParser.swift 里的同名私有工具）。
private func isBlank(_ string: String) -> Bool {
    string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
