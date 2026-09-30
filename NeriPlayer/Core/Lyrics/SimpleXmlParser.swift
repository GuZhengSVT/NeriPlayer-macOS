// SimpleXmlParser.swift
// NeriPlayer macOS —— 极简 XML 解析器（移植规划 M4-T1）。
//
// 来源：accompanist-lyrics-core/src/commonMain/.../utils/SimpleXmlParser.kt（148 行，逐分支移植）。
//
// 为什么不用 Foundation 的 XMLParser：
//   1. 原库是刻意手写的「能读多少读多少」解析器 —— 找不到 `>` 就停下、闭合标签与开标签不匹配
//      就忽略、根节点自闭合也照收。TTML 的实际输入常来自 AMLL、音乐 App 导出等工具，XML 未必
//      严格合法（重复属性、缺闭合、裸 `&`）。Foundation 的 XMLParser 遇到不合法输入会直接报
//      delegate 错误并丢掉后续内容，TTMLParser 依赖的正是「坏输入也能拿到部分结果」。
//   2. 原库把「空白文本」单独建成 `#text` 子节点，TTMLParser 靠它判断 `<span>` 之后有没有空格
//      （逐字歌词的词间空格就是这么恢复的）。XMLParser 的 delegate 回调模型要在
//      foundCharacters 里自己拼状态机，反而更容易在这一步走样。
//
// 索引口径：Kotlin 的 `String.indexOf(char, start)` / `substring` 按 UTF-16 code unit 计数，
// 这里统一用 `Array<Character>` 按「字符」计数。XML 标记与属性名都是 ASCII，两者结果一致；
// 文本节点上按字符切分反而不会把代理对/组合字符切开，比原库更稳。
//
// 与原库的实现差异（有意为之）：
//   - `decodeXmlEntities`：原库放在 TTMLParser 里（TTMLParser.kt:41），职责上属于 XML 层，
//     这里上移到 `SimpleXmlParser.decodeEntities`，每个实体只解码一次，支持合法数字实体。
//     TTMLParser 在「取文本」时调用它。
//   - Kotlin 的 `MutableElement` 是可变累加器，Swift 里保留同名 private struct：解析中途
//     必须往子节点数组和文本缓冲里追加，纯值类型整体替换会写成 O(n²)。
//   - 原库的 `internal class SimpleXmlParser`（需要 new 一个实例）改成无状态 `public struct` +
//     静态方法，与 LyricsParser.swift 里「解析器都是 struct」的口径一致，也让 Sendable 免费成立。

import Foundation

// MARK: - 节点

/// 一个 XML 属性（原库 `XmlAttribute`）。
public struct XmlAttribute: Sendable, Equatable, Hashable {

    /// 属性名，原样保留（含 `ttm:` / `itunes:` 这类前缀）。
    public let name: String

    /// 属性值，**不做**实体解码（解码由使用方在取文本时决定，见 `decodeEntities`）。
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// 一个 XML 元素（原库 `XmlElement`）。
///
/// `text` 只装「直接子文本节点」：原库把每个文本片段 `trim()` 后再追加，所以相邻文本会被
/// 拼接（`Hel` + `lo` → `Hello`），而标签之间的空白、缩进不会混进来（它们变成 `#text` 子节点）。
public struct XmlElement: Sendable, Equatable {

    /// 标签名，原样保留（含 `ttm:agent` 这类前缀）。
    ///
    /// 自闭合标签与 `</x>` 不匹配等情况下可能是空串（原库在解析出空栈时返回空元素）。
    public let name: String

    /// 属性列表，按出现顺序。
    public let attributes: [XmlAttribute]

    /// 子元素和所有直接文本片段，按文档顺序排列；文本使用 `#text` 节点。
    public let children: [XmlElement]

    /// 直接文本内容（已 trim、未做实体解码）。
    public let text: String

    public init(name: String, attributes: [XmlAttribute], children: [XmlElement], text: String) {
        self.name = name
        self.attributes = attributes
        self.children = children
        self.text = text
    }

    /// 按名取属性，取第一个命中的（原库 `XmlElement.attr(vararg names)`）。
    ///
    /// 原库用 `attributes.firstOrNull { it.name in names }`，而不是精确单名匹配 ——
    /// TTML 里同一个属性可能有 `itunes:key` 和 `key` 两种写法，调用方一次传多个候选名。
    public func attribute(_ names: String...) -> String? {
        attributes.first { names.contains($0.name) }?.value
    }

    /// 是否存在角色属性等于 `role`（原库 `XmlElement.hasRole`）。
    ///
    /// 属性名以 `:role` 结尾即可，不限定前缀：`ttm:role`、`role` 都能命中，因为不同工具
    /// 导出的 TTML 前缀并不统一。
    public func hasRole(_ role: String) -> Bool {
        attributes.contains { ($0.name == "role" || $0.name.hasSuffix(":role")) && $0.value == role }
    }
}

// MARK: - 解析器

/// 极简 XML 解析器（原库 `SimpleXmlParser`）。
///
/// 只做三件事：识别标签（开/闭/自闭合/注释/处理指令）、拆属性、收集文本与空白节点。
/// 不做命名空间校验、不做 DTD、不校验标签配对 —— 容错优先，见文件头。
public struct SimpleXmlParser: Sendable {

    public init() {}

    // 这是个手写状态机（标签/属性/文本/实体/自闭合各一支），复杂度就是它要处理的分支数；
    // 拆开会让「读到哪一步停在哪」这个容错语义更难看出来，故就地放行。
    // swiftlint:disable cyclomatic_complexity
    /// 解析一段 XML 文本。
    ///
    /// 永远不抛错：解析不动的地方直接停下，返回已经拼出来的那棵树；连根标签都没解析到时
    /// 返回空元素（`name == ""`），调用方按「没解析到东西」处理即可。
    public func parse(_ xml: String) -> XmlElement {
        let characters = Array(xml)
        var stack: [MutableElement] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "<" {
                if index + 1 < characters.count && characters[index + 1] == "/" {
                    // 闭合标签：把栈顶弹出交给它的父节点。
                    // `stack.count > 1` 的判断是刻意的：根标签的闭合标签不弹栈，
                    // 这样根元素始终留在栈底（原库行为，返回根节点时靠它）。
                    guard let endIndex = Self.firstIndex(of: ">", in: characters, from: index + 1) else { break }
                    if stack.count > 1 {
                        let current = stack.removeLast().toXmlElement()
                        stack[stack.count - 1].children.append(current)
                    }
                    index = endIndex + 1
                } else if index + 1 < characters.count && characters[index + 1] == "!"
                            && Self.matches(Array("!--"), in: characters, at: index + 1) {
                    // 注释：整段丢掉（含 `<!--` 与 `-->`）。没找到 `-->` 就是读到末尾。
                    let endIndex = Self.firstIndexOf("-->", in: characters, from: index + 3)
                    index = endIndex.map { $0 + 3 } ?? characters.count
                } else if index + 1 < characters.count && characters[index + 1] == "?" {
                    // 声明/处理指令：`<?xml …?>` 之类，整段丢掉。
                    let endIndex = Self.firstIndexOf("?>", in: characters, from: index + 2)
                    index = endIndex.map { $0 + 2 } ?? characters.count
                } else {
                    // A quoted attribute may contain a literal >.
                    guard let endIndex = Self.tagEnd(in: characters, from: index + 1) else { break }

                    var tagPart = String(characters[(index + 1)..<endIndex])
                    let isSelfClosing = tagPart.hasSuffix("/")
                    if isSelfClosing {
                        // 归一化 `/ >`、`/  >` 这类写法：切掉 `/` 再 trim，属性解析器只认 `name="v"`。
                        tagPart = String(tagPart.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                    let (tagName, attributes) = Self.parseTagAndAttributes(tagPart)
                    let newElement = MutableElement(name: tagName, attributes: attributes)

                    if isSelfClosing {
                        if stack.isEmpty {
                            // 根节点自闭合：直接就是结果。
                            return newElement.toXmlElement()
                        }
                        stack[stack.count - 1].children.append(newElement.toXmlElement())
                    } else {
                        stack.append(newElement)
                    }
                    index = endIndex + 1
                }
            } else if character.isWhitespace {
                // 空白单独成节点：TTMLParser 靠 `#text` 兄弟节点恢复 `<span>` 之间的词间空格。
                // 注意这里整段空白一起取，且原样保留（不 trim），所以缩进也会带进去，
                // 由使用方在拼接后自行 trim。
                var end = index
                while end < characters.count && characters[end].isWhitespace { end += 1 }
                if !stack.isEmpty {
                    let whitespace = String(characters[index..<end])
                    stack[stack.count - 1].children.append(
                        XmlElement(name: "#text", attributes: [], children: [], text: whitespace)
                    )
                }
                index = end
            } else {
                // 文本内容：一直到下一个 `<` 为止。原库对每段分别 trim 再追加，
                // 于是 "Hel" + "lo" 会拼成 "Hello"，而首尾的换行/缩进被丢掉。
                let nextTagIndex = Self.firstIndex(of: "<", in: characters, from: index)
                let rawText = nextTagIndex.map { String(characters[index..<$0]) } ?? String(characters[index...])
                if !rawText.isEmpty && !stack.isEmpty {
                    stack[stack.count - 1].text += rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    stack[stack.count - 1].children.append(
                        XmlElement(name: "#text", attributes: [], children: [], text: rawText)
                    )
                }
                index = nextTagIndex ?? characters.count
            }
        }

        guard let root = stack.first else {
            return XmlElement(name: "", attributes: [], children: [], text: "")
        }
        return root.toXmlElement()
    }
    // swiftlint:enable cyclomatic_complexity

    /// 解码 XML 常见实体（原库 `TTMLParser.decodeXmlEntities`）。
    ///
    /// Decode named and valid numeric references once; malformed references remain literal.
    /// No external entity/DTD loading is performed.
    public static func decodeEntities(_ text: String) -> String {
        if !text.contains("&") { return text }
        var result = ""
        var cursor = text.startIndex
        let named = ["amp": "&", "lt": "<", "gt": ">", "apos": "'", "quot": "\""]
        while cursor < text.endIndex {
            guard text[cursor] == "&", let end = text[cursor...].prefix(32).firstIndex(of: ";") else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }
            let name = String(text[text.index(after: cursor)..<end])
            var decoded = named[name]
            if name.hasPrefix("#") {
                let hex = name.hasPrefix("#x")
                if let code = UInt32(name.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                   code == 9 || code == 10 || code == 13 || (0x20...0xD7FF).contains(code)
                    || (0xE000...0xFFFD).contains(code) || (0x10000...0x10FFFF).contains(code),
                   let scalar = UnicodeScalar(code) {
                    decoded = String(scalar)
                }
            }
            if let decoded {
                result += decoded
                cursor = text.index(after: end)
            } else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
            }
        }
        return result
    }

    // MARK: 标签与属性

    /// 拆出标签名与属性（原库 `parseTagAndAttributes`）。
    ///
    /// 原库只看**字面空格**来切标签名（不是任意空白），这里保持一致：`<span\tbegin=…>` 这种
    /// 用 tab 分隔的写法会把 `span\tbegin` 当成标签名，属性一个都取不到。这类输入在真实 TTML
    /// 里不存在，改宽反而会和原库行为分叉。
    private static func parseTagAndAttributes(_ tagPart: String) -> (name: String, attributes: [XmlAttribute]) {
        let characters = Array(tagPart)
        guard let firstSpace = characters.firstIndex(where: { $0.isWhitespace }) else { return (tagPart, []) }

        let tagName = String(characters[0..<firstSpace])
        var attributes: [XmlAttribute] = []

        var index = firstSpace + 1
        while index < characters.count {
            while index < characters.count && characters[index].isWhitespace { index += 1 }
            if index >= characters.count { break }

            guard let equalsIndex = characters[index...].firstIndex(of: "=") else { break }
            // 属性名 trim：`a="1"  b="2"` 里第二个属性名会带着前导空格。
            let name = String(characters[index..<equalsIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            index = equalsIndex + 1

            while index < characters.count && characters[index].isWhitespace { index += 1 }
            if index >= characters.count { break }

            let quote = characters[index]
            if quote == "\"" || quote == "'" {
                guard let nextQuote = characters[(index + 1)...].firstIndex(of: quote) else { break }
                attributes.append(XmlAttribute(name: name, value: String(characters[(index + 1)..<nextQuote])))
                index = nextQuote + 1
            } else {
                // 无引号值：读到下一个空白为止（原库允许这种非标准写法）。
                var end = index
                while end < characters.count && !characters[end].isWhitespace { end += 1 }
                attributes.append(XmlAttribute(name: name, value: String(characters[index..<end])))
                index = end
            }
        }

        return (tagName, attributes)
    }

    // MARK: 索引工具（对应 Kotlin 的 indexOf / startsWith）

    private static func tagEnd(in characters: [Character], from start: Int) -> Int? {
        var quote: Character?
        for index in start..<characters.count {
            let character = characters[index]
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == ">" {
                return index
            }
        }
        return nil
    }

    private static func firstIndex(of needle: Character, in characters: [Character], from start: Int) -> Int? {
        guard start >= 0 else { return nil }
        var index = start
        while index < characters.count {
            if characters[index] == needle { return index }
            index += 1
        }
        return nil
    }

    private static func firstIndexOf(_ needle: String, in characters: [Character], from start: Int) -> Int? {
        let pattern = Array(needle)
        guard !pattern.isEmpty else { return max(start, 0) }
        var index = max(start, 0)
        while index + pattern.count <= characters.count {
            if matches(pattern, in: characters, at: index) { return index }
            index += 1
        }
        return nil
    }

    private static func matches(_ needle: [Character], in characters: [Character], at index: Int) -> Bool {
        guard index >= 0, index + needle.count <= characters.count else { return false }
        for offset in 0..<needle.count where characters[index + offset] != needle[offset] {
            return false
        }
        return true
    }
}

// MARK: - 构建用的可变累加器

/// 解析途中使用的可变元素（原库 `SimpleXmlParser.MutableElement`）。
private struct MutableElement {

    let name: String
    let attributes: [XmlAttribute]
    var children: [XmlElement] = []
    var text: String = ""

    func toXmlElement() -> XmlElement {
        XmlElement(name: name, attributes: attributes, children: children, text: text)
    }
}
