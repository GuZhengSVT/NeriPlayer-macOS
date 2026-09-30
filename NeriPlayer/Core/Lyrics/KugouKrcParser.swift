// KugouKrcParser.swift
// NeriPlayer macOS —— 酷狗 KRC 解析器（移植规划 M4-T1）。
//
// 来源：accompanist-lyrics-core/src/commonMain/kotlin/com/mocharealm/accompanist/lyrics/core/parser/KugouKrcParser.kt
//
// KRC 的正文是「行时间 + 逐字时间」两层，时间单位毫秒：
//
//   [12348,882]<0,294,0>戚<294,294,0>琦<588,294,0>：
//   └ 行起点/行时长 └ 音节：相对行首的偏移、时长、保留字段（KRC 里恒为 0）+ 音节文本
//
// 逐块对应的原库逻辑：
//   - 头部 `[language:…]` 交给 KugouKrcMetadataDecoder 解出译文/注音，译文按**行号**对齐；
//   - `[bg:…]` 行是伴奏/和声，挂到前一条主唱行上（前一条不是主唱行时自成一行）；
//   - 音节文本 = 当前 `<…>` 标签之后、下一个 `<…>` 标签之前的全部字符。所以空格、英文
//     单词、`-`、`/` 都归前一个音节（"How " / "Come " 各自带尾空格）；
//   - 「文本 + 紧跟的 `：`/`:`」两个音节合并成一个音节（时长相加），冒号就不会被当成独立
//     音节去高亮；
//   - 整行拼起来之后，文本**以冒号开头或结尾**时切换歌手对齐状态（Start ↔ End）。注意是
//     整行判断：`作词：雷声` 这种行中间的冒号不触发，只有 `戚琦：` 这种收尾才触发。
//
// 原库里 `[start,duration]` 的 duration 字段没有参与计算：行的 end 取最后一个音节的 end
// （即最后一个音节的起点 + 时长）。移植保持同样口径，别"顺手"用行 duration 去修正 end。
//
// 与原库的有意差异（两处，都写在对应位置的注释里）：
//   1. 行起点解析失败（数字溢出 Int）时**跳过该行**：原库 `toInt()` 会抛
//      NumberFormatException 中断整份解析，对播放器来说"少一行"远好过"没歌词"。
//   2. 音节扫描用 `matches(of:)` 一次取全部匹配，等价于原库那个「从 cursor 反复 find」的
//      循环（非重叠匹配按序返回，下一个匹配的起点必然 ≥ 当前匹配的终点），因此原库里那句
//      防御性的 `if (textStart > textEnd) break` 永远不会触发，没有搬过来。

import Foundation

/// 酷狗 KRC 解析器（原库 `object KugouKrcParser`）。
///
/// 无状态 struct：协议要的是实例方法，`AutoParser` 也要把解析器当值放进列表
/// （见 LyricsParser.swift 的文件头）。
public struct KugouKrcParser: LyricsParser {

    public init() {}

    // MARK: - 正则

    /// `canParse` 的两条探测正则（原库 `lineTimeRegex` / `wordTimeRegex`）。
    private static let lineTimeProbe = #/^\[\d+,\d+\]/#
    private static let wordTimeProbe = #/<\d+,\d+,\d+>.{1}/#

    /// 正文行 `[行起点,行时长]正文`（原库 `KRC_LINE_REGEX`，用 `find` → `firstMatch`）。
    private static let krcLine = #/^\[(\d+),(\d+)\](.*)$/#

    /// 单个逐字标签 `<偏移,时长,保留>`（原库 `SYLLABLE_REGEX`，用 `find` → `firstMatch`/`matches`）。
    private static let syllable = #/<(\d+),(\d+),\d+>/#

    /// 伴奏行 `[bg:正文]尾随正文`（原库 `BG_LINE_REGEX`）。贪婪的 `(.*)` 会吃到最后一个 `]` 之前，
    /// 所以正文里带 `]` 也能解析 —— 与原库一致。
    private static let backgroundLine = #/^\[bg:(.*)\](.*)$/#

    /// 头部元数据行前缀，与 KugouKrcMetadataDecoder 共用同一字面量。
    private static let languageTagStart = KugouKrcMetadataDecoder.languageTag

    // MARK: - 识别

    /// 任意一行同时带行时间戳和一个「后面还有字」的逐字标签，就算 KRC（原库 `canParse`）。
    ///
    /// 逐字标签后要求至少 1 个字符（`.{1}`）是原库的条件，用来避开只有时间戳没有内容的行；
    /// 另外 KRC 的时间戳是不带冒号的纯数字、行列用逗号分隔，这一点能让它和 EnhancedLRC 的
    /// `[00:01.00]<00:01.00>` 区分开。
    ///
    /// Kotlin 的 `lineSequence()` 还认 `\r\n` 与单独的 `\r`；这里只按 `\n` 切，但下面每个
    /// 使用点都会先 trim（`\r` 属于空白），所以 CRLF 的 KRC 结果一致。
    public func canParse(_ content: String) -> Bool {
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.firstMatch(of: Self.lineTimeProbe) != nil,
               line.firstMatch(of: Self.wordTimeProbe) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - 解析

    public func parse(_ lines: [String]) -> SyncedLyrics {
        parseInternal(lines)
    }

    /// 与原库一样，按 `\n` 切行后走同一条内部路径（CRLF 的说明见 `canParse`）。
    public func parse(_ content: String) -> SyncedLyrics {
        parseInternal(content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    }

    private func parseInternal(_ rawLines: [String]) -> SyncedLyrics {
        // 元数据行可能在任意位置，但取「第一个」；注意传给解码器的是**未 trim** 的原始行
        // （原库也是），解码器自己会切出 `[language:` 与最后一个 `]` 之间的内容再 trim。
        let languageLine = rawLines.first {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(Self.languageTagStart)
        }
        let metadata = KugouKrcMetadataDecoder.decode(languageLine)

        var resultLines: [LyricsLine] = []

        var currentRoleState = KaraokeAlignment.start
        var lyricLineIndex = 0
        var lastLineStartTime = -1

        for raw in rawLines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(Self.languageTagStart) { continue }

            if line.hasPrefix("[bg:") {
                if let backgroundLine = parseBackgroundLine(line) {
                    if let last = resultLines.last, case .main(var mainLine) = last {
                        // 原库 `last.copy(accompanimentLines = (last.accompanimentLines ?: emptyList()) + bgLine)`：
                        // accompanimentLines 为 nil 时从这里开始变成非 nil，后续的 bg 继续追加。
                        mainLine.accompanimentLines = (mainLine.accompanimentLines ?? []) + [backgroundLine]
                        resultLines[resultLines.count - 1] = .main(mainLine)
                    } else {
                        resultLines.append(.accompaniment(backgroundLine))
                    }
                }
                continue
            }

            guard let match = line.firstMatch(of: Self.krcLine) else { continue }

            // 差异 1：原库 `match.groupValues[1].toInt()`，溢出会抛异常中断整份解析；
            // 这里跳过该行（`\d+` 已经保证是数字，只有超长数字才走到这里）。
            guard var lineStart = Int(match.output.1) else { continue }

            // 时间轴不允许回退：起点不前进就把它推到上一行 +3ms。原库用 -1 当"还没有上一行"。
            if lastLineStartTime != -1, lineStart <= lastLineStartTime {
                lineStart = lastLineStartTime + 3
            }
            lastLineStartTime = lineStart

            let contentPart = String(match.output.3)
            let rawSyllables = parseSyllablesAndMergeColons(contentPart, baseStartTime: lineStart)
            let syllablesWithPhonetics = injectPhonetics(
                rawSyllables,
                allPhonetics: metadata.phonetics,
                lineIndex: lyricLineIndex
            )

            let (alignment, finalSyllables, nextState) = determineRole(
                syllablesWithPhonetics,
                currentState: currentRoleState
            )
            currentRoleState = nextState

            // 译文按行号取；空行（`" "` 这类占位）视为没有译文。注意返回的是原串（未 trim），
            // 与原库 `takeIf { it.isNotBlank() }` 一致。
            let translation = translation(at: lyricLineIndex, in: metadata.translations)

            if !finalSyllables.isEmpty {
                // 行的 start/end 直接取首尾音节：原库也是这么定的，不参考 `[start,duration]`。
                resultLines.append(.main(MainKaraokeLine(
                    syllables: finalSyllables,
                    translation: translation,
                    alignment: alignment,
                    start: finalSyllables[0].start,
                    end: finalSyllables[finalSyllables.count - 1].end
                )))
            }

            // 行号只在「命中行时间戳」时前进：译文是按主歌词行编号的，元数据行不占号。
            lyricLineIndex += 1
        }

        return SyncedLyrics(lines: resultLines)
    }

    /// 取第 `lineIndex` 条译文，空串/纯空白按"没有"处理（原库 `getOrNull(i)?.takeIf { it.isNotBlank() }`）。
    private func translation(at lineIndex: Int, in translations: [String]) -> String? {
        guard translations.indices.contains(lineIndex) else { return nil }
        let candidate = translations[lineIndex]
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : candidate
    }

    // MARK: - 伴奏行

    /// 解析 `[bg:…]` 行（原库 `parseBackgroundLine`）。
    ///
    /// 伴奏行的音节时间以 0 为基准（不带行时间），对齐方式是 `.unspecified`，没有译文。
    private func parseBackgroundLine(_ line: String) -> AccompanimentKaraokeLine? {
        guard let match = line.firstMatch(of: Self.backgroundLine) else { return nil }

        let content = String(match.output.1)
        let syllables = parseSyllablesAndMergeColons(content, baseStartTime: 0)
        guard let first = syllables.first, let last = syllables.last else { return nil }

        return AccompanimentKaraokeLine(
            syllables: syllables,
            translation: nil,
            alignment: .unspecified,
            start: first.start,
            end: last.end
        )
    }

    // MARK: - 音节

    /// 注入逐音节注音（原库 `injectPhonetics`）。
    ///
    /// 只有「行号存在」且「注音个数与音节个数相等」时才注入 —— 个数不等说明这份注音对不上
    /// 这一行（KRC 的注音是按发音给的，遇到纯器乐/空白行会错位），宁可不注音也不能错配。
    private func injectPhonetics(
        _ syllables: [KaraokeSyllable],
        allPhonetics: [[String]],
        lineIndex: Int
    ) -> [KaraokeSyllable] {
        guard allPhonetics.indices.contains(lineIndex) else { return syllables }
        let linePhonetics = allPhonetics[lineIndex]
        guard linePhonetics.count == syllables.count else { return syllables }

        return syllables.enumerated().map { index, syllable in
            var copy = syllable
            // 原库 `s.copy(phonetic = linePhonetics[i])`：空串也会覆盖（不是"为空就跳过"）
            copy.phonetic = linePhonetics[index]
            return copy
        }
    }

    /// 把正文切成音节，并把「文本 + `：`/`:`」合并（原库 `parseSyllablesAndMergeColons`）。
    ///
    /// 时间戳偏移以 `baseStartTime`（行起点，伴奏行是 0）为基准。
    private func parseSyllablesAndMergeColons(
        _ content: String,
        baseStartTime: Int
    ) -> [KaraokeSyllable] {

        /// 原库里是函数内的 `data class TempToken`；Swift 的嵌套类型不能捕获外部泛型，
        /// 这里放在函数内仅为贴近原意，字段一一对应。
        struct Token {
            let offset: Int
            let duration: Int
            let text: String
        }

        var tokens: [Token] = []

        // 差异 2：一次取出全部匹配（`matches(of:)` ≈ Kotlin `findAll`，非重叠且按下标升序），
        // 与原库「find 一次、推进 cursor 再 find」的扫描结果相同。
        let matches = Array(content.matches(of: Self.syllable))
        for (index, match) in matches.enumerated() {
            // `toIntOrNull() ?: 0`：正则保证是数字，只有超长数字会走到 0
            let offset = Int(match.output.1) ?? 0
            let duration = Int(match.output.2) ?? 0

            let textStart = match.range.upperBound
            let textEnd = index + 1 < matches.count
                ? matches[index + 1].range.lowerBound
                : content.endIndex

            tokens.append(Token(
                offset: offset,
                duration: duration,
                text: String(content[textStart..<textEnd])
            ))
        }

        if tokens.isEmpty { return [] }

        var mergedSyllables: [KaraokeSyllable] = []
        var index = 0
        while index < tokens.count {
            let current = tokens[index]
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil

            // 只看「下一个」是不是冒号：合并后冒号跟着前一个字，高亮时不会单独闪一下
            if let next, next.text == "：" || next.text == ":" {
                let start = baseStartTime + current.offset
                let end = start + current.duration + next.duration
                mergedSyllables.append(KaraokeSyllable(
                    content: current.text + next.text,
                    start: start,
                    end: end
                ))
                index += 2
            } else {
                let start = baseStartTime + current.offset
                let end = start + current.duration
                mergedSyllables.append(KaraokeSyllable(
                    content: current.text,
                    start: start,
                    end: end
                ))
                index += 1
            }
        }
        return mergedSyllables
    }

    // MARK: - 对齐状态机

    // 三个返回值同属一次判定结果，为满足 lint 拆成 struct 只会多一层间接。
    // swiftlint:disable large_tuple
    /// 判断这一行属于哪位歌手（原库 `determineRole`）。
    ///
    /// 返回（本行的对齐方式、最终音节、下一个状态）。整行文本以冒号开头或结尾时切换状态，
    /// 否则沿用当前状态。空音节序列原样返回 `.unspecified`（此时上层不会建行）。
    private func determineRole(
        _ syllables: [KaraokeSyllable],
        currentState: KaraokeAlignment
    ) -> (alignment: KaraokeAlignment, syllables: [KaraokeSyllable], nextState: KaraokeAlignment) {
        if syllables.isEmpty {
            return (.unspecified, syllables, currentState)
        }

        let rawText = syllables.joinedContent
        let hasMarker = rawText.hasPrefix("：") || rawText.hasPrefix(":")
            || rawText.hasSuffix("：") || rawText.hasSuffix(":")

        if hasMarker {
            let newState: KaraokeAlignment = currentState == .start ? .end : .start
            return (newState, syllables, newState)
        }

        return (currentState, syllables, currentState)
    }
    // swiftlint:enable large_tuple
}
