// AutoParser.swift
// NeriPlayer macOS —— 歌词格式自动识别（移植规划 M4-T1）。
//
// 来源：accompanist-lyrics-core/src/commonMain/.../parser/AutoParser.kt。
//
// 做法：按固定顺序问每个解析器「你能不能解析」，取第一个说能的；都不行就返回空歌词。
// 顺序本身是逻辑的一部分，不能重排 —— 越宽松/越容易误吞别的格式的解析器排得越前：
// TTML 认 XML 骨架，网易云 YRC 的 `[start,duration]` 行头也容易被通用时间戳正则吃掉，
// 所以它们都排在逐行 LRC 前面；EnhancedLrc 是兜底（几乎所有带 `[mm:ss]` 的都能进），
// KugouKrc 最后。原库默认列表：TTML、NeteaseYrc、LyricifySyllable、EnhancedLrc、KugouKrc。
//
// 与原库的形状差异：Kotlin 用默认参数表达式给默认解析器列表；Swift 的默认参数不能引用
// 其它参数（`fallbackPhoneticProvider` 要传给 TTMLParser），所以这里用 `parsers: nil`
// 表示「用默认列表」，显式传 `[]` 表示「一个解析器都不用」。

import Foundation

/// 按顺序尝试各解析器的自动解析器（原库 `AutoParser`）。
public struct AutoParser: LyricsParser {

    private let parsers: [any LyricsParser]

    /// 构造。
    ///
    /// - Parameters:
    ///   - fallbackPhoneticProvider: 传给 TTML 解析器的注音兜底来源，没有就传 nil。
    ///   - parsers: 自定义解析器列表；传 nil（默认）用原库那套默认列表。
    public init(
        fallbackPhoneticProvider: (any PhoneticProvider)? = nil,
        parsers: [any LyricsParser]? = nil
    ) {
        self.parsers = parsers ?? [
            TTMLParser(fallbackPhoneticProvider: fallbackPhoneticProvider),
            NeteaseYrcParser(),
            LyricifySyllableParser(),
            EnhancedLrcParser(),
            KugouKrcParser()
        ]
    }

    /// 只要有一个解析器说能解析就返回 true。
    public func canParse(_ content: String) -> Bool {
        parsers.contains { $0.canParse(content) }
    }

    /// 取第一个能解析的解析器的结果；都不行返回空歌词（原库也返回空，不抛错）。
    public func parse(_ content: String) -> SyncedLyrics {
        guard let parser = parsers.first(where: { $0.canParse(content) }) else {
            return SyncedLyrics()
        }
        return parser.parse(content)
    }
}
