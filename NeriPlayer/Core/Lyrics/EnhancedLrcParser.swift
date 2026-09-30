// EnhancedLrcParser.swift
// NeriPlayer macOS —— Enhanced LRC 解析器（移植规划 M4-T1）。
//
// 来源：accompanist-lyrics-core/src/commonMain/.../parser/EnhancedLrcParser.kt（逐分支移植，
// 分支顺序与原文件一致，没有做任何"顺手优化"）。
//
// 覆盖的写法（原库文件头给的两种）：
//   增强写法： [00:12.34]<00:12.34>Hel<00:12.60>lo <00:12.90>World
//              [bg:<00:12.34>Back<00:12.60>ground<00:12.90>]
//   "坏"卡拉OK（音节时间戳用方括号，靠 detectBracketType 识别）：
//              [00:12.34][00:12.34]Hel[00:12.60]lo [00:12.90]World
//
// 解析流程与原库逐段对应：
//   removeAttributes + 去空行 → parseLine（拆前导标签、拆音节、展开压缩时间戳）
//   → combineRawWithTranslation（同时间戳第二行当译文）
//   → rearrangeAccompanimentAlignment（伴奏行继承上一个主唱行的对齐方式）
//   → rearrangeUncheckedLineTime（末行 end 补 Int.MAX_VALUE / 乱序钳制）
//   → 把伴奏行挂回前一个主唱行的 accompanimentLines
//
// 设计与差异（每条都是"Swift 表达不出来"或"原库依赖 JVM 语义"的地方，不是行为改动）：
//   1. 无状态 struct：原库是 Kotlin object（调用点 `EnhancedLrcParser.parse(x)`）；这里按
//      LyricsParser.swift 的统一口径写成 `EnhancedLrcParser().parse(x)`。
//   2. 正则里的 `\d` 一律写成 `[0-9]`：Java 的 `\d` 默认只匹配 ASCII 数字，Swift 的 `\d` 是
//      Unicode 语义（阿拉伯-印度数字等也算数字）。歌词时间戳只可能是 ASCII，写 `[0-9]` 才和
//      原库逐字等价。
//   3. 原库两处 `runCatching { x.parseAsTime() }.getOrNull()`：Swift 的 LyricsTime.parseAsTime
//      对坏输入返回 0 而不抛错（见 LyricsTimeUtils.swift 的容错口径），这里退化成直接取值。
//      走到这两处的字符串都已经被 isTimestamp 整串匹配筛过，正常输入二者结果一致；只有
//      「原库会抛异常」的极端输入会有差异：原库丢掉该音节，这里得到时间戳 0。
//   4. 原库 `syllables.first()/last()` 抛异常的用法（构造 Main/AccompanimentKaraokeLine 时、
//      算 isRelative 时）：Swift 改成下标取值，前置条件与调用点相同（分支里已判空）。
//   5. `List<ISyncedLine>` → `[LyricsLine]`。原库的 `when (line) { is KaraokeLine -> …;
//      is SyncedLine -> …; else -> … }` 在这里是穷尽 switch：`.main` / `.accompaniment` 都是
//      卡拉OK行，`.synced` 是逐行对齐行（见 LyricsModel.swift 的"为什么用 enum"）。
//   6. 原库 `String.split("/")`（limit = 0）只丢"尾部"空串，Swift 的 split 默认丢所有空串；
//      这里手工只去尾部，保持与 Kotlin 一致。唯一的残留差异是空串输入（Kotlin 给 [""]，Swift
//      给 []），只有 `[ar:]` 这种空标签会碰到，且导出器在两种行为下都不会写 [ar:] 行，故不模拟。
//   7. 原库 `parseLine(content: String?)` 的可空参数：调用点恒传非空串，这里收成非可选。
//   8. 原库 `parseLine` 是一个大函数；这里把其中连续的三段（前导标签扫描 / 标签归类 /
//      v1-v2 标记解析）拆成三个私有方法，纯提取、分支与顺序逐行不变（见 `parseLine` 的注释）。

import Foundation

/// Enhanced LRC（逐字/伴奏/压缩时间戳）解析器（原库 `EnhancedLrcParser`）。
public struct EnhancedLrcParser: LyricsParser {

    public init() {}

    // MARK: 正则

    /// `canParse` 用的行时间戳：必须是两位分、两位秒、2~3 位毫秒。
    private static let lineTimestampPattern = #/\[[0-9]{2}:[0-9]{2}\.[0-9]{2,3}\]/#

    /// 多歌手标记：`v1: 歌词` / `v2: 歌词`。
    private static let voicePattern = #/^(v[0-9]+)\s*:\s*(.*)/#

    /// 方括号标签：`[00:12.34]`、`[bg:…]`、`[ti:…]` 都靠它切出来。
    private static let tagPattern = #/\[(.*?)\]/#

    /// 时间戳形状（整串匹配）：`\d+([:.]\d+)+`。
    private static let timestampPattern = #/[0-9]+([:.][0-9]+)+/#

    /// 尖括号音节：`<时间戳>文本`。
    private static let angleSyllablePattern = #/<([^>]+)>([^<]*)/#

    /// 方括号音节（"坏"卡拉OK）：`[时间戳]文本`。
    private static let squareSyllablePattern = #/\[([^\]]+)\]([^\[]*)/#

    /// `detectBracketType` 用：内容里出现 `<数字`。
    private static let anglePrefixPattern = #/<[0-9]+/#

    /// `detectBracketType` 用：内容里出现 `[数字`。
    private static let squarePrefixPattern = #/\[[0-9]+/#

    /// 音节的括号类型（原库 `private enum class BracketType`）。
    private enum BracketType {
        case angle
        case square
    }

    // MARK: canParse

    /// 只要内容里出现标准行时间戳就认（原库 `canParse`：`content.contains(Regex(...))`，
    /// 是"找得到"而不是整串匹配）。
    public func canParse(_ content: String) -> Bool {
        content.firstMatch(of: Self.lineTimestampPattern) != nil
    }

    // MARK: 主入口

    /// 解析若干行（原库 `parse(lines)`）。
    public func parse(_ lines: [String]) -> SyncedLyrics {
        // 先摘掉 [ti:]/[ar:]/[al:]/[offset:]/[length:] 这些头部标签，再丢掉空行。
        // 注意顺序：先删标签再过滤空行，与原库一致。
        let lyricsLines = LrcMetadataHelper.removeAttributes(lines).filter { !isBlank($0) }

        let rawLines = lyricsLines.flatMap { parseLine($0) }
        let combined = combineRawWithTranslation(rawLines)
        let aligned = rearrangeAccompanimentAlignment(combined)
        let rawData = rearrangeUncheckedLineTime(aligned)

        // 把伴奏行挂到"紧邻的前一个主唱行"上；前面不是主唱行就单独留一行
        // （原库 `data.last() is MainKaraokeLine` 的判定）。
        var data: [LyricsLine] = []
        for line in rawData {
            if case .accompaniment(let accompaniment) = line,
               !data.isEmpty,
               case .main(var lastMain) = data[data.count - 1] {
                lastMain.accompanimentLines = (lastMain.accompanimentLines ?? []) + [accompaniment]
                data[data.count - 1] = .main(lastMain)
            } else {
                data.append(line)
            }
        }

        // 头部标签从**原始** lines 里读（不是过滤后的 lyricsLines），与原库一致。
        let attributes = LrcMetadataHelper.parse(lines)
        return SyncedLyrics(
            lines: data,
            title: attributes.title ?? "",
            artists: attributes.artist.map { parseArtists($0) } ?? []
        )
    }

    // MARK: 单行

    /// 解析一行（原库 `parseLine`），一行可能展开成多行（压缩时间戳）。
    ///
    /// 这里把原库单个大函数拆成了 3 个私有方法（`scanLeadingTags` / `classifyLeadingTags` /
    /// `parseVoiceTag`）：它们分别对应原库连续的三段代码，分支与顺序完全不变，拆出来只是为了
    /// 让每个函数的圈复杂度可读（SwiftLint cyclomatic_complexity）。本方法保留原库
    /// 164–208 行的"时间戳展开"主体。
    private func parseLine(_ string: String) -> [LyricsLine] {
        guard let scanned = scanLeadingTags(string) else { return [] }
        let content = scanned.content
        let (timestamps, bgTag) = classifyLeadingTags(scanned.tags)

        // 括号类型由正文与 bg 标签共同决定，正文优先。
        let bracketType = detectBracketType(content, bgTag: bgTag)

        let bgSyllables = bgTag.map { proceduralParseSyllables($0, bracketType: bracketType) } ?? []
        let mainSyllables = (!timestamps.isEmpty && !isBlank(content))
            ? proceduralParseSyllables(content, bracketType: bracketType)
            : []

        let voice = parseVoiceTag(content)
        let alignment = voice.alignment
        let textContent = voice.textContent

        var results: [LyricsLine] = []
        let firstTimestamp = timestamps.first ?? 0
        // 音节是"相对时间"还是"绝对时间"：第一个音节早于行时间戳就是相对写法
        // （压缩时间戳场景里常见的 <00:00.00> 起头）。
        let isRelative = mainSyllables.first.map { $0.start < firstTimestamp } ?? false
        let bgIsRelative = bgSyllables.first.map { $0.start < firstTimestamp } ?? false

        if !timestamps.isEmpty {
            for startTime in timestamps {
                if !mainSyllables.isEmpty {
                    let offset = isRelative ? startTime : LyricsTime.subtracting(startTime, firstTimestamp)
                    let shifted = shiftedSyllables(mainSyllables, by: offset)
                    results.append(.main(MainKaraokeLine(
                        syllables: shifted,
                        translation: nil,
                        alignment: alignment,
                        start: shifted[0].start,
                        end: shifted[shifted.count - 1].end
                    )))
                } else if !isBlank(textContent) {
                    // 没有逐字音节的普通行（标准 LRC 走这里）：end 先等于 start，
                    // 后面 rearrangeUncheckedLineTime 会把它拉到下一行的 start。
                    results.append(.synced(SyncedLine(
                        content: textContent,
                        translation: nil,
                        start: startTime,
                        end: startTime
                    )))
                }

                if !bgSyllables.isEmpty {
                    let bgOffset = bgIsRelative ? startTime : LyricsTime.subtracting(startTime, firstTimestamp)
                    let shifted = shiftedSyllables(bgSyllables, by: bgOffset)
                    results.append(.accompaniment(AccompanimentKaraokeLine(
                        syllables: shifted,
                        translation: nil,
                        alignment: .unspecified,
                        start: shifted[0].start,
                        end: shifted[shifted.count - 1].end
                    )))
                }
            }
        } else if !bgSyllables.isEmpty {
            // 只有 [bg:…] 没有行时间戳：直接按音节自己的绝对时间成行。
            results.append(.accompaniment(AccompanimentKaraokeLine(
                syllables: bgSyllables,
                translation: nil,
                alignment: .unspecified,
                start: bgSyllables[0].start,
                end: bgSyllables[bgSyllables.count - 1].end
            )))
        }

        return results
    }

    /// 前置扫描（原库 `parseLine` 的 113–130 行）：收集"前导标签"并取出正文。
    ///
    /// 只吃从行首开始、彼此之间只有空白的标签；遇到第一个非空白前缀就停，剩下的整段算正文
    /// （这决定了一行里 `[00:10.00][00:30.00]<…>` 的展开方式）。整行空白、一个标签都没有、
    /// 或第一个标签前面就有正文时返回 nil。
    private func scanLeadingTags(_ string: String) -> (tags: [String], content: String)? {
        if isBlank(string) { return nil }

        let matches = string.matches(of: Self.tagPattern)
        if matches.isEmpty { return nil }

        var lastEnd = string.startIndex
        var leadingTags: [String] = []
        for match in matches {
            let prefix = string[lastEnd..<match.range.lowerBound]
            if isBlank(String(prefix)) {
                leadingTags.append(String(match.output.1))
                lastEnd = match.range.upperBound
            } else {
                break
            }
        }

        if leadingTags.isEmpty { return nil }

        let content = lastEnd < string.endIndex
            ? String(string[lastEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return (leadingTags, content)
    }

    /// 前导标签归类（原库 `parseLine` 的 132–142 行）。
    ///
    /// `[bg:…]` 收进 bgTag（同一行出现多个时后写的覆盖先写的）；时间戳按出现顺序累加。
    private func classifyLeadingTags(_ tags: [String]) -> (timestamps: [Int], bgTag: String?) {
        var timestamps: [Int] = []
        var bgTag: String?

        for tag in tags {
            let tagContentRaw = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if tagContentRaw.hasPrefix("bg:") {
                // 同原库：去掉 "bg:" 三个字符后再 trim（`[bg: …]` 这种带空格的写法）。
                bgTag = String(tagContentRaw.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if isTimestamp(tagContentRaw) {
                timestamps.append(LyricsTime.parseAsTime(tagContentRaw))
            }
        }

        return (timestamps, bgTag)
    }

    /// 多歌手标记（原库 `parseLine` 的 152–158 行）：`v1:`/`v2:` 决定对齐方式，
    /// 标记本身从正文里去掉（`textContent`）；没有标记时对齐方式是 Unspecified、正文原样。
    private func parseVoiceTag(_ content: String) -> (alignment: KaraokeAlignment, textContent: String) {
        guard let voiceMatch = content.firstMatch(of: Self.voicePattern) else {
            return (.unspecified, content)
        }

        let voiceTag = String(voiceMatch.output.1)
        let alignment: KaraokeAlignment
        if voiceTag == "v1" {
            alignment = .start
        } else if voiceTag == "v2" {
            alignment = .end
        } else {
            alignment = .unspecified
        }

        let textContent = String(voiceMatch.output.2)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (alignment, textContent)
    }

    // MARK: 音节

    /// 按括号类型切音节（原库 `proceduralParseSyllables`）。
    ///
    /// 只认「时间戳 + 文本」形状的标签；时间戳不合法就跳过这个标签（`isTimestamp` 整串匹配）。
    private func proceduralParseSyllables(
        _ content: String,
        bracketType: BracketType = .angle
    ) -> [KaraokeSyllable] {
        if isBlank(content) { return [] }

        // 先把命中项摊平成 (时间戳, 文本)，后面用同一个循环处理两种括号 —— 与原库
        // 「选正则 → findAll → 单个 for」的结构一致。
        let rawMatches: [(Substring, Substring)]
        switch bracketType {
        case .angle:
            rawMatches = content.matches(of: Self.angleSyllablePattern).map { ($0.output.1, $0.output.2) }
        case .square:
            rawMatches = content.matches(of: Self.squareSyllablePattern).map { ($0.output.1, $0.output.2) }
        }

        var syllables: [KaraokeSyllable] = []
        for match in rawMatches {
            let tsPart = String(match.0).trimmingCharacters(in: .whitespacesAndNewlines)
            let text = String(match.1)

            if isTimestamp(tsPart) {
                let time = LyricsTime.parseAsTime(tsPart)
                syllables.append(KaraokeSyllable(content: text, start: time, end: time))
            }
        }

        return syllables.isEmpty ? [] : rearrangeTime(syllables)
    }

    /// 把每个音节的 end 拉成下一个音节的 start；内容为空的**末**音节丢弃
    /// （原库 `rearrangeTime`，`for (i in 0 until size - 1)`）。
    ///
    /// 空末音节是"收尾时间戳"（`…<00:02.50>` 后面没有文本），它只用来标出前一个音节的结束；
    /// 但它只在**最后**才被丢弃 —— 中间的空音节会保留（内容为空，时长是它到下一个音节的距离）。
    private func rearrangeTime(_ syllables: [KaraokeSyllable]) -> [KaraokeSyllable] {
        if syllables.isEmpty { return [] }

        var list: [KaraokeSyllable] = []
        for i in 0..<(syllables.count - 1) {
            var syllable = syllables[i]
            syllable.end = syllables[i + 1].start
            list.append(syllable)
        }

        let last = syllables[syllables.count - 1]
        if !last.content.isEmpty {
            list.append(last)
        }
        return list
    }

    /// 整体平移音节（原库 `it.copy(start = it.start + offset, end = it.end + offset)`：
    /// content 与 phonetic 原样保留）。
    private func shiftedSyllables(_ syllables: [KaraokeSyllable], by offset: Int) -> [KaraokeSyllable] {
        syllables.map {
            KaraokeSyllable(
                content: $0.content,
                start: LyricsTime.adding($0.start, offset),
                end: LyricsTime.adding($0.end, offset),
                phonetic: $0.phonetic
            )
        }
    }

    // MARK: 括号类型

    /// 检测正文/`bg:` 标签里用的是尖括号还是方括号（原库 `detectBracketType`）。
    ///
    /// 判定的是"`<` 紧跟数字"，所以普通歌词里的 `<3` 之类也会被当成尖括号 —— 这是原库行为。
    /// 正文优先于 bg；都判不出来时默认尖括号。
    private func detectBracketType(_ content: String, bgTag: String?) -> BracketType {
        if content.firstMatch(of: Self.anglePrefixPattern) != nil {
            return .angle
        }
        if content.firstMatch(of: Self.squarePrefixPattern) != nil {
            return .square
        }

        if let bgTag {
            if bgTag.firstMatch(of: Self.anglePrefixPattern) != nil {
                return .angle
            }
            if bgTag.firstMatch(of: Self.squarePrefixPattern) != nil {
                return .square
            }
        }

        return .angle
    }

    // MARK: 译文合并

    /// 把"同/近时间戳的下一行"当译文合并进当前行（原库 `combineRawWithTranslation`）。
    ///
    /// 三条与原库逐字对齐的规则：
    ///   - 制作信息行（`作词 : X`、`OP: Y`）既不抢别人的正文当译文，自己也不会成为译文；
    ///   - 候选译文必须类型兼容（同类型 / 伴奏行配主唱行 / 任何行配 SyncedLine），
    ///     且时间差 ≤ 150ms；
    ///   - 被当作译文吃掉的下标不再参与后续配对（`usedIndices`）。
    private func combineRawWithTranslation(_ lines: [LyricsLine]) -> [LyricsLine] {
        var list: [LyricsLine] = []
        var usedIndices = Set<Int>()

        for i in lines.indices {
            if usedIndices.contains(i) { continue }
            let line = lines[i]
            let contentStr = line.trimmedContent

            if LrcMetadataHelper.isCreditLine(contentStr) {
                list.append(line)
                usedIndices.insert(i)
                continue
            }

            var translationFound = false
            for j in (i + 1)..<lines.count {
                if usedIndices.contains(j) { continue }
                let nextLine = lines[j]

                // 兼容逻辑：类型相同，或者伴奏行的译文没带 bg 标签而被识别成主唱行/普通行。
                let isCompatibleType = kind(of: line) == kind(of: nextLine)
                    || (kind(of: line) == .accompaniment && kind(of: nextLine) == .main)
                    || kind(of: nextLine) == .synced

                if isCompatibleType && abs(line.start - nextLine.start) <= 150 {
                    let nextContent = nextLine.trimmedContent
                    // 候选译文是制作信息行就跳过它，继续往后找（不是放弃整行）。
                    if LrcMetadataHelper.isCreditLine(nextContent) { continue }
                    if contentStr != nextContent && !contentStr.isEmpty {
                        list.append(line.withTranslation(nextContent))
                        usedIndices.insert(i)
                        usedIndices.insert(j)
                        translationFound = true
                        break
                    }
                }
            }

            if !translationFound {
                list.append(line)
                usedIndices.insert(i)
            }
        }
        return list
    }

    /// 行的三种形态（原库靠 `line::class` 比较实现的"类型相同"判定）。
    private enum LineKind {
        case synced
        case main
        case accompaniment
    }

    private func kind(of line: LyricsLine) -> LineKind {
        switch line {
        case .synced: return .synced
        case .main: return .main
        case .accompaniment: return .accompaniment
        }
    }

    // MARK: 对齐继承

    /// 伴奏行继承"上一个主唱行"的对齐方式（原库 `rearrangeAccompanimentAlignment`）。
    ///
    /// 主唱行会刷新 `lastAlignment`；逐行对齐的行把它重置为 Unspecified。
    /// 已经是目标对齐方式的伴奏行原样返回（不产生新对象）。
    private func rearrangeAccompanimentAlignment(_ lines: [LyricsLine]) -> [LyricsLine] {
        var lastAlignment = KaraokeAlignment.unspecified
        return lines.map { line in
            switch line {
            case .accompaniment(let accompaniment):
                return accompaniment.alignment == lastAlignment
                    ? line
                    : line.withAlignment(lastAlignment)
            case .main(let main):
                lastAlignment = main.alignment
                return line
            case .synced:
                lastAlignment = .unspecified
                return line
            }
        }
    }

    // MARK: 末行/乱序时间

    /// 逐行对齐的行：end = max(start, 下一行的 start)（原库 `rearrangeUncheckedLineTime`）。
    ///
    /// 两个"为什么"：
    ///   - 末行没有下一行时 end 取 `Int.MAX_VALUE`（原库 Int.MAX_VALUE），也就是"唱到结尾"；
    ///     时长仍由模型层钳到非负。
    ///   - 下一行时间戳早于当前行（乱序文件）时钳成 start，保证这行仍是一个有效的
    ///     非负区间，而不是让整份歌词解析失败。
    private func rearrangeUncheckedLineTime(_ lines: [LyricsLine]) -> [LyricsLine] {
        lines.enumerated().map { index, line in
            guard case .synced(let synced) = line else { return line }
            let nextStart = index + 1 < lines.count ? lines[index + 1].start : Int.max
            let end = max(synced.start, nextStart)
            return line.withEnd(end)
        }
    }

    // MARK: 小工具

    /// 艺术家串 → `[Artist]`（原库 `SyncedLyrics(...)` 里那段 `artist.split("/")`）。
    ///
    /// `A: 甲/B: 乙` 拆成按 `:` 分角色的两位艺术家；没有 `:` 的角色落到 "Main"。
    private func parseArtists(_ artistString: String) -> [Artist] {
        // Kotlin 的默认 split(limit = 0) 只丢"尾部"空串；Swift 默认丢所有空串，这里手工去尾。
        var parts = artistString.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        while parts.last?.isEmpty == true {
            parts.removeLast()
        }

        return parts.map { part in
            // limit = 2：只在第一个 `:` 处切，且保留空段（`A:` → ["A", ""]）。
            let segments = part
                .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .map(String.init)
            if segments.count == 2 {
                return Artist(type: segments[0], name: segments[1])
            }
            return Artist(type: "Main", name: part)
        }
    }

    /// 时间戳整串匹配（原库 `isTimestamp`：`timestampPattern.matches(s.trim())`）。
    private func isTimestamp(_ string: String) -> Bool {
        string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .wholeMatch(of: Self.timestampPattern) != nil
    }
}

/// 对应原库的 `String.isBlank()`（空白串，含空串）。用 `whitespacesAndNewlines` 近似
/// Java 的 `Char.isWhitespace()`；两者对 ASCII 空白完全一致，差异只在个别 Unicode 空白字符上。
private func isBlank(_ string: String) -> Bool {
    string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
