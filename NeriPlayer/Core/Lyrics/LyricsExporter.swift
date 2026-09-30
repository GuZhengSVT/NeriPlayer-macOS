// LyricsExporter.swift
// NeriPlayer macOS —— 歌词导出器接口与标准 LRC 导出器（移植规划 M4-T1）。
//
// 来源：accompanist-lyrics-core/src/commonMain/.../exporter/
//   ILyricsExporter.kt → LyricsExporter 协议
//   LrcExporter.kt     → LrcExporter
//
// 导出器是往返测试（parse → export → parse）的另一半：解析器把文件读成
// SyncedLyrics，导出器把它写回文本，两者对"同一份歌词"的理解必须一致，
// 否则往返测试会掩盖解析器的偏差。
//
// 与原库的形状差异：
//   1. Kotlin object → 无状态 struct（与解析器同一口径），调用点写 `LrcExporter().export(x)`。
//   2. `appendLine` 在 JVM 上追加的是行分隔符（"\n"），这里显式拼 "\n"，行为一致；
//      不做平台相关的换行适配 —— LRC 是文本交换格式，统一用 "\n"。
//   3. 原库 `when (line) { is KaraokeLine -> …; is SyncedLine -> line; else -> … }` 在 Swift 里是
//      穷尽 switch（enum 没有"其他类型"这一档）。卡拉OK行一律折算成逐行对齐行导出：
//      标准 LRC 没有音节/伴奏的概念。

import Foundation

/// 歌词导出器（原库 `ILyricsExporter`）。
public protocol LyricsExporter: Sendable {

    /// 把歌词导出成文本。
    func export(_ lyrics: SyncedLyrics) -> String
}

extension LyricsExporter {

    /// 两个 LRC 导出器逐字相同的头部写法（原库 LrcExporter / EnhancedLrcExporter 里各写了一遍）：
    /// `[ti:…]` 与 `[ar:…]`，各占一行、行尾带 "\n"。
    ///
    /// `[ar:]` 只在"所有艺术家名都非空"时写：半截的艺术家列表比没有更糟（原库 `all {}` 的用意）。
    /// 放在协议扩展里只是去重 —— 输出与两处原库实现逐字节相同。
    func exportLrcHeader(_ lyrics: SyncedLyrics) -> String {
        var header = ""

        if !isBlank(lyrics.title) {
            header += "[ti:\(lyrics.title)]\n"
        }
        // 只要有一位艺术家名字是空白就整条 [ar:] 不写。
        if let artists = lyrics.artists, !artists.isEmpty, artists.allSatisfy({ !isBlank($0.name) }) {
            header += "[ar:\(artists.map(\.name).joined(separator: "/"))]\n"
        }

        return header
    }
}

/// 标准 LRC 导出器（原库 `LrcExporter`）。
///
/// 丢掉音节与 `[bg:…]` 伴奏行，只保留 `[ti:]`/`[ar:]`、行时间戳与"同时间戳的第二行 = 译文"。
public struct LrcExporter: LyricsExporter {

    public init() {}

    public func export(_ lyrics: SyncedLyrics) -> String {
        if lyrics.lines.isEmpty { return "" }

        var builder = exportLrcHeader(lyrics)

        for line in lyrics.lines {
            let normalizedLine: SyncedLine
            switch line {
            case .synced(let synced):
                normalizedLine = synced
            case .main, .accompaniment:
                normalizedLine = line.toSyncedLine()
            }

            let timeTag = "[\(LyricsTime.formatted(normalizedLine.start))]"

            builder += "\(timeTag)\(normalizedLine.content)\n"
            if let translation = normalizedLine.translation {
                builder += "\(timeTag)\(translation)\n"
            }
        }

        return builder
    }
}

/// 对应原库的 `String.isBlank()`（同 EnhancedLrcParser.swift 里的同名私有工具）。
private func isBlank(_ string: String) -> Bool {
    string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
