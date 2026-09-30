// TTMLParser.swift
// NeriPlayer macOS —— Apple TTML（Syllable Timing）歌词解析（移植规划 M4-T1）。
//
// 来源：accompanist-lyrics-core/src/commonMain/.../parser/TTMLParser.kt（343 行，逐块移植）。
// 依赖：utils/SimpleXmlParser.kt → SimpleXmlParser.swift（容错 XML，别换成 Foundation XMLParser）。
//
// 形状：原库是 `class TTMLParser(private val fallbackPhoneticProvider: PhoneticProvider?)`，
// 这里按 LyricsParser.swift 的统一口径做成无状态 struct，唯一的构造参数同名保留：
//     TTMLParser(fallbackPhoneticProvider: fake).parse(ttml)
// 它是值语义，provider 只是只读配置，所以 Sendable 成立、可以放进 AutoParser 的解析器列表。
//
// 一份 TTML 里同时存在四种信息，解析顺序就是原库的顺序（别调换 —— 后面的步骤会读前面的结果）：
//   1. `<metadata>` 里的 `<ttm:agent>` → 谁唱哪一段（第一个 agent 靠左、其余靠右）；
//   2. `<metadata>` 里的 iTunes 译文/音译表（`<text for="Lx">`，按 itunes:key 索引）；
//   3. `<body>` 下每个 `<p begin end>` → 一行，`<span begin end>` → 一个音节；
//   4. provider 注音回退（只有在整行都没注音时才做）。
//
// 与原库的有意差异，逐条写在各处注释里，汇总如下：
//   1. `getAlignmentFromAgent`（TTMLParser.kt:326）没有移植：原库里只定义、零调用（已 grep 全模块
//      确认），唯一的对齐取值点在内联的 `alignments[agentId] ?? Start`。
//   2. `parsedLines.sortedBy { it.start }` 在 Swift 里显式写成稳定排序：Kotlin 的 sortedBy 稳定、
//      Swift 的 sorted 不稳定，同 start 的多行（合唱/对唱很常见）行序会分叉。
//   3. `parse(lines)` 需要的 Kotlin `String.trimIndent()` Swift 标准库没有，在文件内私有一份实现；
//      不给 String 加扩展是为了不和并行移植的其它文件撞名。
//   4. 实体解码 `decodeXmlEntities` 上移到 `SimpleXmlParser.decodeEntities`（职责归 XML 层），
//      调用点与时机和原库完全一致。
//   5. `KaraokeSyllable`/`SyncedLine` 的时间钳制、`LyricsLine` 的三选一 enum 见共享层文件头。
//      本文件里 `KaraokeLine.MainKaraokeLine` 一律写成 `.main(...)`、`SyncedLine` 写成 `.synced(...)`。
//
// 容错口径（原库的行为，刻意保留）：
//   - `<p>` 缺 `begin` 或 `end` → 整行丢掉（`parseSingleLine` 返回 nil），不是退化成 0；
//     时间戳写错（`parseAsTime` 返回 0）才算 0。两者的区别会影响「这行该不该显示」。
//   - `<span>` 缺 begin/end 或文本为空 → 该音节丢掉，但同一行其它音节照收。
//   - 一个音节都没有、也没有和声轨时，整行退化成逐行对齐的 `SyncedLine`（正文由所有子节点文本拼出）。
//   - 和声 span 没有 begin/end 时，用它的第一个/最后一个音节的时间兜底。

import Foundation

public struct TTMLParser: LyricsParser {

    /// 没有任何注音信息时用来兜底生成注音的 provider；nil 表示不做任何回退。
    private let fallbackPhoneticProvider: (any PhoneticProvider)?

    public init(fallbackPhoneticProvider: (any PhoneticProvider)? = nil) {
        self.fallbackPhoneticProvider = fallbackPhoneticProvider
    }

    /// TTML 的判别特征就是命名空间声明（原库 `canParse`）。
    ///
    /// 注意 AutoParser 的顺序敏感：这个判断很宽，几乎只有真 TTML 才会带这个 URL，
    /// 所以原库把它放在列表第一位，移植后不要因为「看起来太松」而收紧。
    public func canParse(_ content: String) -> Bool {
        content.contains("http://www.w3.org/ns/ttml")
    }

    /// 若干行先各自去掉公共缩进再无条件拼接（原库 `parse(lines)`）。
    ///
    /// 用空串拼接而不是 `\n` 是刻意的：TTML 的空白本身是数据（`<span>` 之间的 `#text` 决定
    /// 词间空格），逐行拼接时额外插入换行会改变解析结果。调用这个入口的多是「按行读进来的
    /// 文件内容」，缩进来自源码/配置文件，去掉更接近原始语义。
    public func parse(_ lines: [String]) -> SyncedLyrics {
        parse(lines.map(Self.trimIndent).joined())
    }

    /// 解析一整段 TTML（原库 `parse(content)`）。
    public func parse(_ content: String) -> SyncedLyrics {
        let root = SimpleXmlParser().parse(preformattingTTML(content))

        let agentAlignments = parseMetadata(root)
        let translations = parseITunesTranslations(root)
        let transliterations = parseITunesTransliterations(root)

        let parsedLines = findAllPElements(root).compactMap { element in
            parseSingleLine(
                element,
                alignments: agentAlignments,
                translations: translations,
                transliterations: transliterations
            )
        }

        let syncedLyrics = SyncedLyrics(lines: Self.sortedByStart(parsedLines))
        return applyFallbackPhonetics(syncedLyrics)
    }

    // MARK: - 预处理

    /// 把 AMLL 等工具不严格合规的 TTML 掰回规范形状（原库 `preformattingTTML`，注释写着
    /// "Workaround for AMLL and other tools not strictly following the spec"）。
    ///
    /// 三步的顺序有依赖，别调换：
    ///   1. 去掉所有双空格 —— 这一步顺带把缩进删了（缩进是 2 的倍数），于是 `<span>` 之间的
    ///      换行+缩进会塌成裸换行，下一步的模式才可能出现；
    ///   2. 原来的 `</span><span` 中间没空格，两个 span 会挤成一个音节，补一个空格；
    ///   3. 同上，但处理 `,</span><span`（英文逗号后直接跟下一个词，AMLL 常见）。
    private func preformattingTTML(_ content: String) -> String {
        content
            .replacingOccurrences(of: "  ", with: "")
            .replacingOccurrences(of: " </span><span", with: "</span> <span")
            .replacingOccurrences(of: ",</span><span", with: ",</span> <span")
    }

    // MARK: - 行

    /// 解析单个 `<p>`（原库 `parseSingleLine`）。返回 nil 表示这行不可用（缺时间戳或没有内容）。
    private func parseSingleLine(
        _ p: XmlElement,
        alignments: [String: KaraokeAlignment],
        translations: [String: String],
        transliterations: [String: [String]]
    ) -> LyricsLine? {
        guard let start = p.attribute("begin").map(LyricsTime.parseAsTime),
              let end = p.attribute("end").map(LyricsTime.parseAsTime) else { return nil }

        let agentId = p.attribute("ttm:agent")
        let itunesKey = p.attribute("itunes:key", "key")

        // 1. 主音轨音节。
        var syllables = parseSyllablesFromChildren(p.children)

        // iTunes 音译表按 itunes:key 索引，只有「数量与音节数完全相等」时才采用：
        // 数量不等说明对不上号，宁可整行不要音译，也不要错位贴上。
        if let key = itunesKey, let phonetics = transliterations[key], phonetics.count == syllables.count {
            syllables = zip(syllables, phonetics).map { syllable, phonetic in
                var copy = syllable
                copy.phonetic = phonetic
                return copy
            }
        }

        // 2. 行级注音（整行一个 `<span ttm:role="x-roman">`）。
        let linePhonetic = p.children.first { $0.name == "span" && $0.hasRole("x-roman") }?
            .text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. 行内译文。带 x-bg 的译文属于和声轨，不算主轨译文。
        let inlineTranslation = p.children.first {
            $0.name == "span" && $0.hasRole("x-translation") && !$0.hasRole("x-bg")
        }?.text.trimmingCharacters(in: .whitespacesAndNewlines)

        let itunesTranslation = lookupTranslation(itunesKey, in: translations).map(splitTranslationByBracket)

        // 4. 和声轨（背景人声）。
        let accompanimentLines = p.children
            .filter { $0.name == "span" && $0.hasRole("x-bg") }
            .compactMap { bgSpan in
                parseAccompaniment(
                    bgSpan,
                    parentKey: itunesKey,
                    alignment: lookupAlignment(agentId, in: alignments),
                    translations: translations
                )
            }

        // 没有任何音节、也没有和声：退化成逐行对齐的歌词。
        // 正文要把所有子节点文本拼起来（译文 span 会被 extractAllText 跳过），
        // 因为这类行常常长成 `<p>正文<span ttm:role="x-translation">译文</span></p>`。
        if syllables.isEmpty && accompanimentLines.isEmpty {
            let content = SimpleXmlParser.decodeEntities(extractAllText(p))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { return nil }
            return .synced(SyncedLine(
                content: content,
                translation: inlineTranslation ?? itunesTranslation?.outside,
                start: start,
                end: end
            ))
        }

        return .main(MainKaraokeLine(
            syllables: syllables,
            translation: inlineTranslation ?? itunesTranslation?.outside,
            alignment: lookupAlignment(agentId, in: alignments) ?? .start,
            start: start,
            end: end,
            phonetic: linePhonetic,
            accompanimentLines: accompanimentLines.isEmpty ? nil : accompanimentLines
        ))
    }

    /// 和声轨（原库 `parseAccompaniment`）。没有可用的音节就整轨丢掉。
    private func parseAccompaniment(
        _ bgSpan: XmlElement,
        parentKey: String?,
        alignment: KaraokeAlignment?,
        translations: [String: String]
    ) -> AccompanimentKaraokeLine? {
        let syllables = parseSyllablesFromChildren(bgSpan.children)
        if syllables.isEmpty { return nil }

        // 和声自己可以带 itunes:key，没有就继承主行的。
        let bgKey = bgSpan.attribute("itunes:key", "key") ?? parentKey

        let inlineTranslation = bgSpan.children.first { $0.hasRole("x-translation") }?
            .text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 原库的 elvis 链：优先行内译文 span，其次 iTunes 译文表；
        // iTunes 译文走括号拆分，并**优先取括号内**（和声歌词常把和声词放在括号里）。
        let bgTranslation: String?
        if let inlineTranslation {
            bgTranslation = inlineTranslation
        } else if let key = bgKey, let value = translations[key] {
            let split = splitTranslationByBracket(value)
            bgTranslation = split.inside ?? split.outside
        } else {
            bgTranslation = nil
        }

        // 和声 span 缺 begin/end 时用音节边界兜底（与主行「缺时间戳就丢行」不同，
        // 和声是附属信息，丢整轨的代价比用近似时间戳大）。
        let start: Int
        if let begin = bgSpan.attribute("begin") {
            start = LyricsTime.parseAsTime(begin)
        } else {
            start = syllables[0].start
        }
        let end: Int
        if let endAttribute = bgSpan.attribute("end") {
            end = LyricsTime.parseAsTime(endAttribute)
        } else {
            end = syllables[syllables.count - 1].end
        }

        return AccompanimentKaraokeLine(
            syllables: syllables,
            translation: bgTranslation,
            alignment: alignment ?? .start,
            start: start,
            end: end
        )
    }

    // MARK: - 音节

    /// 从一组子节点里抽出音节（原库 `parseSyllablesFromChildren`）。
    ///
    /// 词间空格不在 `<span>` 里面，而是藏在「下一个兄弟节点是 `#text`」这个事实里
    /// （SimpleXmlParser 把空白单独建节点）。所以这里必须按兄弟顺序遍历、而不是只 filter span。
    private func parseSyllablesFromChildren(_ children: [XmlElement]) -> [KaraokeSyllable] {
        var syllables: [KaraokeSyllable] = []

        for (index, child) in children.enumerated() {
            // 只认 span；译文/和声 span 在这一层不是音节。
            guard child.name == "span" else { continue }
            let isMetadataSpan = child.attributes.contains {
                $0.name.hasSuffix(":role") && ($0.value == "x-translation" || $0.value == "x-bg")
            }
            guard !isMetadataSpan else { continue }

            guard let spanBegin = child.attributes.first(where: { $0.name == "begin" })?.value,
                  let spanEnd = child.attributes.first(where: { $0.name == "end" })?.value,
                  !child.text.isEmpty else { continue }

            var syllableContent = SimpleXmlParser.decodeEntities(child.text)

            // 只往后看一格：原库不会跨过别的节点去找空格，跨过就等于把间距算到了错误的词上。
            let nextSibling = index + 1 < children.count ? children[index + 1] : nil
            if let nextSibling, nextSibling.name == "#text" {
                syllableContent += SimpleXmlParser.decodeEntities(nextSibling.text)
            }

            syllables.append(KaraokeSyllable(
                content: syllableContent,
                start: LyricsTime.parseAsTime(spanBegin),
                end: LyricsTime.parseAsTime(spanEnd)
            ))
        }

        // 最后一个音节的尾部空白去掉：行尾空格没有显示意义，留着还会让「行内容 == 音节拼接」
        // 这类比较失败。
        if let last = syllables.last {
            var trimmed = last
            trimmed.content = Self.trimEnd(last.content)
            syllables[syllables.count - 1] = trimmed
        }

        return syllables
    }

    // MARK: - iTunes 译文 / 音译表

    /// 收集 `<translation>`/`<itunes:translation>` 下的 `<text for="key">` 文本（原库
    /// `parseITunesTranslations`）。key 来自 `for` 属性，与 `<p>` 的 `itunes:key` 对应。
    private func parseITunesTranslations(_ element: XmlElement) -> [String: String] {
        var translations: [String: String] = [:]

        func findTranslations(_ element: XmlElement) {
            if element.name == "translation" || element.name.hasSuffix(":translation") {
                for textElement in element.children where textElement.name == "text" {
                    guard let key = textElement.attributes.first(where: { $0.name == "for" })?.value else { continue }
                    // 空白文本不算译文（`<text>` 里只有缩进是常态）。
                    if !Self.isBlank(textElement.text) {
                        translations[key] = textElement.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            for child in element.children { findTranslations(child) }
        }

        findTranslations(element)
        return translations
    }

    /// 收集 `<transliterations>/<transliteration>/<text for="key">` 下每个内部 `<span>` 的文本
    /// 作为逐音节音标（原库 `parseITunesTransliterations`）。
    ///
    /// 注意取的是 span 的 `text`（直接文本），span 自己的时间戳在这里被忽略 ——
    /// 音译的对应关系靠「顺序」，不靠时间。
    private func parseITunesTransliterations(_ element: XmlElement) -> [String: [String]] {
        var transliterations: [String: [String]] = [:]

        func findTransliterations(_ element: XmlElement) {
            if element.name == "transliterations" || element.name.hasSuffix(":transliterations") {
                for transElement in element.children
                where transElement.name == "transliteration" || transElement.name.hasSuffix(":transliteration") {
                    for textElement in transElement.children where textElement.name == "text" {
                        guard let key = textElement.attributes.first(where: { $0.name == "for" })?.value else { continue }
                        let phoneticSpans = textElement.children
                            .filter { $0.name == "span" }
                            .map {
                                SimpleXmlParser.decodeEntities($0.text)
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        if !phoneticSpans.isEmpty {
                            transliterations[key] = phoneticSpans
                        }
                    }
                }
            }
            for child in element.children { findTransliterations(child) }
        }

        findTransliterations(element)
        return transliterations
    }

    // MARK: - 元数据

    /// 找 `<metadata>` 里的 agent，按出现顺序定对齐方式（原库 `parseMetadata`）。
    ///
    /// 第一个 agent 是 `.start`（主唱靠左），其余都是 `.end`。TTML 没有更细的语义，
    /// 渲染层就靠这两档分左右。id 取 `xml:id`，兼容只写 `id` 的非标准导出。
    private func parseMetadata(_ element: XmlElement) -> [String: KaraokeAlignment] {
        func findMetadata(_ element: XmlElement) -> XmlElement? {
            if element.name == "metadata" { return element }
            for child in element.children {
                if let found = findMetadata(child) { return found }
            }
            return nil
        }

        guard let metadata = findMetadata(element) else { return [:] }

        var alignments: [String: KaraokeAlignment] = [:]
        let agents = metadata.children.filter { $0.name.hasSuffix(":agent") || $0.name == "agent" }
        for (index, agent) in agents.enumerated() {
            let id = agent.attributes.first { $0.name == "xml:id" || $0.name == "id" }?.value ?? ""
            // 重复 id 时后者覆盖前者（对应原库 `.toMap()`），下标仍按列表位置算。
            alignments[id] = index == 0 ? .start : .end
        }
        return alignments
    }

    // MARK: - 注音回退

    /// 对没有任何注音的行用 provider 兜底（原库 `applyFallbackPhonetics`）。
    ///
    /// provider 为 nil 时原样返回 —— 这正是「TTML 里已经带了注音就完全不需要 provider」的用法，
    /// 也是 M4-T1 只有接口、没有实现时的默认路径。
    ///
    /// 判定粒度按 `provider.phoneticLevel`：
    ///   - `.line`：整个音节的拼接文本喂进去，结果写回行级 `phonetic`；
    ///   - `.syllable`：每个音节单独喂，结果写回各音节的 `phonetic`。
    /// 回退前先看这一行有没有**任何**注音（行级或音节级），有就整行不动：半覆盖会把已有的、
    /// 通常更准的注音盖掉。
    private func applyFallbackPhonetics(_ syncedLyrics: SyncedLyrics) -> SyncedLyrics {
        guard let provider = fallbackPhoneticProvider else { return syncedLyrics }

        let processedLines = syncedLyrics.lines.map { line -> LyricsLine in
            // 逐行对齐的行没有注音概念（原库 `if (line !is KaraokeLine) return@map line`）。
            guard let karaokeLine = line.karaokeLine else { return line }

            let hasExistingPhonetic = Self.hasContent(karaokeLine.phonetic)
                || karaokeLine.syllables.contains { Self.hasContent($0.phonetic) }
            if hasExistingPhonetic { return line }

            switch provider.phoneticLevel {
            case .line:
                return line.withPhonetic(provider.getPhonetic(karaokeLine.syllables.joinedContent))
            case .syllable:
                let phonetics = karaokeLine.syllables.map { syllable -> KaraokeSyllable in
                    var copy = syllable
                    copy.phonetic = provider.getPhonetic(syllable.content)
                    return copy
                }
                return line.withSyllables(phonetics)
            }
        }

        return SyncedLyrics(lines: processedLines)
    }

    // MARK: - 遍历与工具

    /// 正文提取（原库 `extractAllText`）：跳过译文/和声/注音 span，其余子节点递归收集。
    ///
    /// 只用于「一行没有任何音节」的降级路径，所以这里不必保留 `#text` 的空白语义 ——
    /// 那些空白节点会走进递归，但它们的 `text` 原样拼上后再由调用方 trim，正合原库意图。
    private func extractAllText(_ element: XmlElement) -> String {
        var text = element.text
        for child in element.children {
            if child.name == "span"
                && (child.hasRole("x-translation") || child.hasRole("x-bg") || child.hasRole("x-roman")) {
                continue
            }
            text += extractAllText(child)
        }
        return text
    }

    /// 先序收集所有 `<p>`（原库 `findAllPElements`）。
    private func findAllPElements(_ element: XmlElement) -> [XmlElement] {
        var elements: [XmlElement] = []
        if element.name == "p" { elements.append(element) }
        for child in element.children {
            elements.append(contentsOf: findAllPElements(child))
        }
        return elements
    }

    /// 取 `itunes:key`（兼容简写 `key`）对应的译文（原库 `translations[itunesKey]`）。
    private func lookupTranslation(_ key: String?, in translations: [String: String]) -> String? {
        guard let key else { return nil }
        return translations[key]
    }

    /// 取 agent 的对齐方式（原库 `alignments[agentId]`，没有就 nil 由调用方兜底）。
    private func lookupAlignment(
        _ agentId: String?,
        in alignments: [String: KaraokeAlignment]
    ) -> KaraokeAlignment? {
        guard let agentId else { return nil }
        return alignments[agentId]
    }

    /// 行尾括号拆分（原库 `splitTranslationByBracket`）。
    ///
    /// 只认全角 `（）`：这是 Apple/iTunes 歌词的约定（整行译文写成「正文（假名/罗马音）」），
    /// 半角括号在正文里太常见，认了会误伤。
    ///
    /// 返回 `outside`（括号前）与 `inside`（括号内，空则为 nil）。注意 `）` 结尾但找不到 `（`
    /// 时只 trim、不拆分；`inside` 为空串按 nil 处理 —— 原库 `inside.ifEmpty { null }`。
    private func splitTranslationByBracket(_ text: String) -> BracketSplit {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasSuffix("）") else { return BracketSplit(outside: trimmed, inside: nil) }
        guard let bracketStart = text.lastIndex(of: "（") else { return BracketSplit(outside: trimmed, inside: nil) }

        let outside = String(text[text.startIndex..<bracketStart])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let inside = String(text[text.index(after: bracketStart)..<text.index(before: text.endIndex)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return BracketSplit(outside: outside, inside: inside.isEmpty ? nil : inside)
    }

    /// `splitTranslationByBracket` 的结果（对应 Kotlin 的 `Pair<String, String?>`）。
    private struct BracketSplit {
        let outside: String
        let inside: String?
    }

    /// 按 start 升序排序（原库 `parsedLines.sortedBy { it.start }`）。
    ///
    /// Kotlin 的 `sortedBy` 是稳定排序，Swift 的 `sorted` 不保证稳定。同 start 的行在 TTML 里
    /// 很常见（合唱段多行同时开始），行序一旦分叉，渲染层的行号和高亮都会跟着漂，
    /// 所以这里显式用「start，原始下标」做键把稳定性写死。
    private static func sortedByStart(_ lines: [LyricsLine]) -> [LyricsLine] {
        lines.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.start != rhs.element.start { return lhs.element.start < rhs.element.start }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// `!String?.isNullOrBlank()`：nil 或全空白都算「没有内容」。
    private static func hasContent(_ text: String?) -> Bool {
        guard let text else { return false }
        return !isBlank(text)
    }

    /// Kotlin `String.isBlank()`：空串也算空白。
    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy { $0.isWhitespace }
    }

    /// Kotlin `String.trimEnd()`：只去尾部空白（默认谓词 `Char.isWhitespace`）。
    ///
    /// Swift 只有「两端都去」的 `trimmingCharacters`，不能拿它顶替 —— 音节开头的空格可能
    /// 是刻意的（中文歌里 `hello world` 的前导空格），原库只去尾。
    private static func trimEnd(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous].isWhitespace else { break }
            end = previous
        }
        return String(text[text.startIndex..<end])
    }

    /// Kotlin `String.trimIndent()`：去掉所有非空行的公共缩进，并丢掉首尾空行。
    ///
    /// 只给 `parse(lines)` 用。实现照 Kotlin 标准库的 replaceIndent("")：
    /// 最小缩进取「非空行里最小的前导空白字符数」，逐行 `drop(n)`（不足则整行变空）。
    private static func trimIndent(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let minCommonIndent = lines.filter { !isBlank($0) }.map(indentWidth).min() ?? 0

        var result: [String] = []
        for (index, line) in lines.enumerated() {
            if (index == 0 || index == lines.count - 1) && isBlank(line) { continue }
            result.append(String(line.dropFirst(min(minCommonIndent, line.count))))
        }
        return result.joined(separator: "\n")
    }

    /// 一行开头连续空白字符的个数（Kotlin `String.indentWidth()`）。
    private static func indentWidth(_ line: String) -> Int {
        guard let firstNonWhitespace = line.firstIndex(where: { !$0.isWhitespace }) else { return line.count }
        return line.distance(from: line.startIndex, to: firstNonWhitespace)
    }
}
