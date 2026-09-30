// TTMLExporter.swift
// NeriPlayer macOS —— TTML 导出（移植规划 M4-T1，原库把它归在 exporter/）。
//
// 来源：accompanist-lyrics-core/src/commonMain/.../exporter/TTMLExporter.kt（126 行，逐块移植）。
//
// 用途：解析后的歌词再导出成 TTML。当前只有测试用它做往返验证（parse → export → parse），
// 但它决定了「歌词能不能无损过一遍序列化」，所以边界处理要按原库逐字节对齐：
//   - SyncedLine 的正文与译文都转义 `& < >`；
//   - 卡拉OK音节的**正文**转义、**译文**不转义 —— 原库这里就没转义（与 SyncedLine 分支不一致）。
//     这是个上游小 bug，但保留：改了会让导出的字节与 Kotlin 版不同，往返测试的期望值也就变了。
//   - 文本先 `trim()` 再转义（音节与译文）；SyncedLine 的正文不 trim，原样转义。
//   - 正文里原本以空格结尾的音节，在 `</span>` 之后补一个空格（歌词的词间空格就是靠它留住的）。
//
// 形状：原库是 Kotlin `object`，这里和 LyricsExporter.swift 的 `LrcExporter` 保持同一口径，
// 写成无状态 `struct` 并 conform `LyricsExporter`，调用点写 `TTMLExporter().export(lyrics)`
// （原库写 `TTMLExporter.export(lyrics)`）。无状态结构体天然 Sendable。
//
// 与原库的有意差异：
//   原库 `when (line) { is MainKaraokeLine -> …; is SyncedLine -> … }` 没有覆盖
//   `AccompanimentKaraokeLine`（顶层和声行）。原库的两个重载函数也接不住这个类型，实际行为就是
//   「跳过」。这里显式 `case .accompaniment: break`，并在注释里标明，避免被误当成遗漏。

import Foundation

public struct TTMLExporter: LyricsExporter {

    public init() {}

    // 复杂度来自「逐行/逐词/伴奏/注音」四类分支的平铺判断，与参考实现一一对应；
    // 为了压复杂度拆成小函数，反而会让「对着原库逐分支核对」变难，故就地放行。
    // swiftlint:disable cyclomatic_complexity
    /// 把整份歌词导出成 TTML（原库 `export`）。
    ///
    /// 空歌词返回空串（原库行为，不是返回一个只有头的空 TTML）。
    public func export(_ lyrics: SyncedLyrics) -> String {
        if lyrics.lines.isEmpty { return "" }

        var output = ""

        // 只有同时存在 Start 与 End 两种对齐时才写 <metadata> 的 v1/v2 agent。
        // 单一对齐方式下没有「对唱」可言，写了反而会让再解析时多出无用的 agent 表。
        var hasStart = false
        var hasEnd = false
        for line in lyrics.lines {
            // 逐行对齐的行 alignment 为 nil，跳过（对应原库 `if (line is KaraokeLine)`）。
            guard let alignment = line.alignment else { continue }
            switch alignment {
            case .start: hasStart = true
            case .end: hasEnd = true
            case .unspecified: break
            }
            if hasStart && hasEnd { break }
        }
        let hasAlignmentData = hasStart && hasEnd

        output += #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        output += Self.ttOpenTag + "\n"
        output += "  <head>\n"
        if hasAlignmentData {
            output += "    <metadata>\n"
            output += #"      <ttm:agent type="person" xml:id="v1"/>"# + "\n"
            output += #"      <ttm:agent type="person" xml:id="v2"/>"# + "\n"
            output += "    </metadata>\n"
        }
        output += "  </head>\n"

        // 总时长取所有行 end 的最大值：原库 `maxOfOrNull { it.end } ?: 0`。
        let totalDuration = lyrics.lines.map(\.end).max() ?? 0
        output += #"  <body dur="\#(LyricsTime.formatted(totalDuration))">"# + "\n"

        // div 的 begin 用第一行的 start（此时列表已排好序，lines 也非空）。
        let firstLineTime = lyrics.lines[0].start
        output += "    <div begin=\"\(LyricsTime.formatted(firstLineTime))\""
            + " end=\"\(LyricsTime.formatted(totalDuration))\">\n"

        for line in lyrics.lines {
            switch line {
            case .main(let karaokeLine): output += Self.pElement(karaokeLine)
            case .synced(let syncedLine): output += Self.pElement(syncedLine)
            case .accompaniment: break
            }
        }

        output += "    </div>\n"
        output += "  </body>\n"
        output += "</tt>\n"

        return output
    }
    // swiftlint:enable cyclomatic_complexity

    /// `<tt>` 开标签（原库一行超长字面量；这里是同一个字符串，仅为满足 SwiftLint 行宽而拼接）。
    private static let ttOpenTag = #"<tt xmlns="http://www.w3.org/ns/ttml" "#
        + #"xmlns:itunes="http://music.apple.com/lyric-ttml-internal" "#
        + #"xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word">"#

    // MARK: - 行

    /// 主唱（音节对齐）行 → `<p>`（原库 `appendPElement(MainKaraokeLine)`）。
    private static func pElement(_ line: MainKaraokeLine) -> String {
        let agent: String
        switch line.alignment {
        case .start: agent = #" ttm:agent="v1""#
        case .end: agent = #" ttm:agent="v2""#
        case .unspecified: agent = ""
        }

        var output = "      <p begin=\"\(LyricsTime.formatted(line.start))\""
            + " end=\"\(LyricsTime.formatted(line.end))\"\(agent)>"

        output += Self.content(syllables: line.syllables, translation: line.translation)

        // 和声轨嵌在主行里；它自带 begin/end 与自己的音节时间。
        if let accompanimentLines = line.accompanimentLines {
            for bgLine in accompanimentLines {
                output += #"<span ttm:role="x-bg" begin="\#(LyricsTime.formatted(bgLine.start))""#
                    + #" end="\#(LyricsTime.formatted(bgLine.end))">"#
                output += Self.content(syllables: bgLine.syllables, translation: bgLine.translation)
                output += #"</span>"#
            }
        }

        output += "</p>\n"
        return output
    }

    /// 逐行对齐的行 → `<p>`（原库 `appendPElement(SyncedLine)`）。
    private static func pElement(_ line: SyncedLine) -> String {
        var output = "      <p begin=\"\(LyricsTime.formatted(line.start))\""
            + " end=\"\(LyricsTime.formatted(line.end))\">"
        output += Self.escapeXML(line.content)

        if let translation = line.translation {
            output += #"<span ttm:role="x-translation" xml:lang="zh-CN">"#
                + Self.escapeXML(translation.trimmingCharacters(in: .whitespacesAndNewlines))
                + #"</span>"#
        }

        output += "</p>\n"
        return output
    }

    /// 音节序列 + 译文 → 内联片段（原库 `buildContent`）。
    private static func content(syllables: [KaraokeSyllable], translation: String?) -> String {
        var output = ""
        for syllable in syllables {
            let rawContent = syllable.content
            output += "<span begin=\"\(LyricsTime.formatted(syllable.start))\""
                + " end=\"\(LyricsTime.formatted(syllable.end))\">"
                + Self.escapeXML(rawContent.trimmingCharacters(in: .whitespacesAndNewlines))
                + "</span>"
            // 原库判断的是**原始**内容（不是 trim 之后的）是否以空格结尾。
            if rawContent.hasSuffix(" ") { output += " " }
        }
        if let translation {
            // 注意：这里没有 escapeXML —— 与原库一致（见文件头「有意差异」前的说明）。
            output += #"<span ttm:role="x-translation" xml:lang="zh-CN">"#
                + translation.trimmingCharacters(in: .whitespacesAndNewlines)
                + #"</span>"#
        }
        return output
    }

    /// 转义 XML 文本（原库 `replace("&", …).replace("<", …).replace(">", …)`）。
    ///
    /// 顺序必须是 `&` 在最前：反过来的话 `&lt;` 里的 `&` 会被二次转义成 `&amp;lt;`。
    private static func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
