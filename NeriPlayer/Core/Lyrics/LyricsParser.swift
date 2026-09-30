// LyricsParser.swift
// NeriPlayer macOS —— 歌词解析器接口（移植规划 M4-T1）。
//
// 来源：accompanist-lyrics-core 的 parser/ILyricsParser.kt 与 utils/PhoneticProvider.kt。
//
// 与原库的形状差异：原库的解析器都是 Kotlin `object`，调用点写 `EnhancedLrcParser.parse(x)`。
// Swift 里协议要求的是实例方法，`AutoParser` 又需要把解析器当值放进列表，所以这里把解析器
// 统一成无状态 struct（`TTMLParser(fallbackPhoneticProvider:)` 这类带配置的也一样），
// 调用点写 `EnhancedLrcParser().parse(x)`。无状态 struct 顺带天然 Sendable。
//
// 注意两个 `parse` 的默认实现互相调用（原库就是这样）：具体解析器只要覆写其中一个即可。
// 两个都不覆写会无限递归 —— 这一点和原库一致，不额外加防护，免得掩盖实现遗漏。

import Foundation

/// 注音提供者（原库 `utils/PhoneticProvider.kt`）。
///
/// M4-T1 只落接口：原库有两个实现（日文假名、中文拼音），都属于后续任务，
/// 解析器在没有 provider 时必须能正常工作（TTML 的注音回退就是这么用的）。
public protocol PhoneticProvider: Sendable {

    /// 注音粒度：整行一个，还是每个音节一个。
    var phoneticLevel: PhoneticLevel { get }

    /// 取一段文本的注音。
    func getPhonetic(_ string: String) -> String
}

/// 歌词解析器（原库 `parser/ILyricsParser.kt`）。
public protocol LyricsParser: Sendable {

    /// 判断这份内容能不能被本解析器解析。
    func canParse(_ content: String) -> Bool

    /// 解析若干行。
    func parse(_ lines: [String]) -> SyncedLyrics

    /// 解析一整段文本（按 `\n` 切行）。
    func parse(_ content: String) -> SyncedLyrics
}

extension LyricsParser {

    /// 默认实现：拼回一整段再解析（原库 `parse(lines)` 默认实现）。
    public func parse(_ lines: [String]) -> SyncedLyrics {
        parse(lines.joined(separator: "\n"))
    }

    /// 默认实现：按 `\n` 切行再解析（原库 `parse(content)` 默认实现）。
    ///
    /// `omittingEmptySubsequences: false` 是必须的：空行在 LRC/逐字歌词里是有意义的
    /// （对时间的空行、以及解析器靠行号对齐译文），删掉空行会让行号错位。
    public func parse(_ content: String) -> SyncedLyrics {
        parse(content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    }
}
