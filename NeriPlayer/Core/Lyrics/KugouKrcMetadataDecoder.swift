// KugouKrcMetadataDecoder.swift
// NeriPlayer macOS —— 酷狗 KRC 的 `[language:…]` 元数据解码（移植规划 M4-T1）。
//
// 来源：accompanist-lyrics-core/src/commonMain/kotlin/com/mocharealm/accompanist/lyrics/core/utils/KugouKrcMetadataDecoder.kt
//
// KRC 把译文和逐音节注音塞进头部的一行 `[language:<base64(JSON)>]`，JSON 形如：
//
//   {"content": [{"type": 1, "lyricContent": [["还能"], ["抵抗多久？"], …]},
//                {"type": 0, "lyricContent": [[["huan"], ["neng"]], …]}],
//    "version": 1}
//
//   - `type == 1`：一行一条译文，`lyricContent` 的每一项是「若干片段」，拼起来才是整行；
//   - `type == 0`：一行一条注音，`lyricContent` 的每一项又是「音节 → 片段」两层数组。
//
// 数组下标就是主歌词的行号（解析器按行序取用），所以译文的空行会保留成 `" "` 这类占位，
// 由 KugouKrcParser 判空后丢弃 —— 解码层不做对齐修正，否则下标会错位。
//
// 实现路线（任务约定的「例外」走 (a) 条）：base64 用 Foundation 的 `Data(base64Encoded:)`
// —— 原库 `kotlin.io.encoding.Base64` 的默认实例就是标准 RFC 4648 带 `=` 补齐，两者等价；
// JSON 侧原库用的是 kotlinx.serialization，但本文件只用到「取 object 的某个 key + 判断数组
// 形状」这一点能力，Foundation 的 JSONSerialization 足够等价。因此本文件没有 MIGRATION-TODO，
// 也没有为了 JSON 引入第三方依赖。
//
// 与原库的三处差异（都不影响解析结果，理由逐条写清）：
//   1. 原库 catch 里 `e.printStackTrace()`，这里静默落回空元数据。解析层的容错口径是
//      「坏元数据不许让整首歌没歌词」，而往 stderr 打栈不是本层该干的事（M4 还没有统一日志口）。
//   2. kotlinx 的 `JsonPrimitive.content` 返回 JSON 字面量的**原始文本**（`1e2` 就是 "1e2"），
//      JSONSerialization 只给 NSNumber（`1e2` 变成 "100"）。KRC 的译文/注音全是字符串，
//      这个差别只在「元数据里混进数字」这种畸形输入上可见。
//   3. `JsonPrimitive.intOrNull` 对布尔和浮点都返回 nil（它按文本 `toIntOrNull()`，
//      `true`/`1.0` 都失败），这里用 NSNumber 的 `objCType` 复刻同一条规则。注意不能用
//      `as? Bool` 区分布尔：Swift 的 NSNumber 桥接下 `NSNumber(1) as? Bool` 也是非 nil（实测）。

import Foundation

/// `[language:…]` 头部的解码器（原库 `object KugouKrcMetadataDecoder`）。
public enum KugouKrcMetadataDecoder {

    /// 头部标记。KugouKrcParser 也用它来识别/跳过元数据行，放这里做单一事实来源。
    public static let languageTag = "[language:"

    /// 解出来的附加歌词（原库 `KugouKrcMetadataDecoder.Metadata`）。
    public struct Metadata: Sendable, Equatable {

        /// 逐行译文，下标对应主歌词行号。
        public var translations: [String]

        /// 逐行逐音节注音：外层按行、内层按音节。
        public var phonetics: [[String]]

        public init(translations: [String] = [], phonetics: [[String]] = []) {
            self.translations = translations
            self.phonetics = phonetics
        }
    }

    /// 从一行 `[language:…]` 里解出译文与注音（原库 `decode`）。
    ///
    /// 传 nil / 空串 / 纯空白、base64 非法、JSON 不是预期形状，一律返回空 `Metadata()`
    /// —— 这一层不抛错，调用方（解析器）继续按「没有译文」处理即可。
    public static func decode(_ languageHeader: String?) -> Metadata {
        guard let languageHeader,
              !languageHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Metadata()
        }

        let contentBase64 = extractBase64(languageHeader)
        if contentBase64.isEmpty { return Metadata() }

        guard let decoded = Data(base64Encoded: contentBase64) else { return Metadata() }

        // 原库 `decodeToString()` 的默认参数 throwOnInvalidSequence = false：非法字节替换成
        // U+FFFD 而不是抛错。`String(decoding:as:)` 是同样的「不抛」口径，别换成
        // `String(data:encoding:)`（那个会返回 nil，行为会变成「整段丢掉」）。
        // swiftlint:disable:next optional_data_string_conversion
        let jsonText = String(decoding: decoded, as: UTF8.self)
        return (try? parseJsonContent(jsonText)) ?? Metadata()
    }

    // MARK: - 取 base64 文本

    /// 取出 `[language:` 与最后一个 `]` 之间的内容（原库
    /// `substringAfter("[language:")` + `substringBeforeLast("]")` + `trim()`）。
    ///
    /// 找不到分隔符时，Kotlin 的 `substringAfter` / `substringBeforeLast` 都返回原串，
    /// 这里保持同样行为：于是「不含 `[language:` 的普通文本」会被当成 base64 送去解码，
    /// 解码失败后照样落回空元数据 —— 结果一致，但不必为调用约定多加一层前置检查。
    private static func extractBase64(_ languageHeader: String) -> String {
        let afterTag: Substring
        if let tagRange = languageHeader.range(of: languageTag) {
            afterTag = languageHeader[tagRange.upperBound...]
        } else {
            afterTag = languageHeader[...]
        }

        let body: Substring
        if let lastClosingBracket = afterTag.lastIndex(of: "]") {
            body = afterTag[..<lastClosingBracket]
        } else {
            body = afterTag
        }

        return String(body).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - JSON

    /// 解析 base64 里的 JSON（原库 `parseJsonContent`）。
    ///
    /// 抛出 = 整段放弃（外层 `try?` 落回空元数据）。这条控制流是照原库复刻的：原库把整个
    /// `parseJsonContent` 包在一个 try/catch 里，所以只要某一行的形状不对，**已经解析出来的**
    /// 译文/注音也一并丢掉。半份元数据的下标和行号对不上，比没有更糟，故保持「全有或全无」。
    private static func parseJsonContent(_ jsonText: String) throws -> Metadata {
        guard let jsonData = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData),
              let rootObject = root as? [String: Any],
              let contentArray = rootObject["content"] as? [Any] else {
            return Metadata()
        }

        var translations: [String] = []
        var phonetics: [[String]] = []

        for element in contentArray {
            let entry = try jsonObject(element)
            let type = intValue(entry["type"])

            if type == 1 {
                guard let rows = entry["lyricContent"] as? [Any] else { continue }
                for row in rows {
                    translations.append(try jsonArray(row).map { try primitiveContent($0) }.joined())
                }
            } else if type == 0 {
                guard let rows = entry["lyricContent"] as? [Any] else { continue }
                for row in rows {
                    let syllables = try jsonArray(row).map { syllableParts -> String in
                        try jsonArray(syllableParts).map { try primitiveContent($0) }.joined()
                    }
                    phonetics.append(syllables)
                }
            }
            // 其余 type（含缺失）原库直接忽略：KRC 目前只用到 0/1 两种。
        }

        return Metadata(translations: translations, phonetics: phonetics)
    }

    /// 只为「形状不符 → 整段放弃」这条控制流服务的内部错误，不对外暴露。
    ///
    /// 对应 kotlinx 在 `jsonObject` / `jsonArray` / `jsonPrimitive` 上抛的异常。
    private struct UnexpectedJsonShape: Error {}

    private static func jsonObject(_ value: Any) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw UnexpectedJsonShape() }
        return object
    }

    private static func jsonArray(_ value: Any) throws -> [Any] {
        guard let array = value as? [Any] else { throw UnexpectedJsonShape() }
        return array
    }

    /// `JsonPrimitive.content` 的等价物：取字面量文本。
    ///
    /// 对象/数组/`null` 在原库会因 `jsonPrimitive` 抛异常，这里同样抛（→ 整段放弃）。
    private static func primitiveContent(_ value: Any) throws -> String {
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            // JSON 的 true/false 也是 NSNumber，但 `content` 给的是 "true"/"false"
            return isBooleanNumber(number) ? (number.boolValue ? "true" : "false") : number.description
        default:
            throw UnexpectedJsonShape()
        }
    }

    /// `JsonPrimitive.intOrNull` 的等价物：按字面量文本解析整数，失败为 nil。
    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let text as String:
            return Int(text)
        case let number as NSNumber:
            guard !isBooleanNumber(number), !isFloatingPointNumber(number) else { return nil }
            return number.intValue
        default:
            return nil
        }
    }

    /// NSNumber 装的是 JSON 布尔吗（`objCType` 为 `c`/`B`）。
    private static func isBooleanNumber(_ number: NSNumber) -> Bool {
        let encoding = String(cString: number.objCType)
        return encoding == "c" || encoding == "B"
    }

    /// NSNumber 装的是 JSON 浮点吗（`objCType` 为 `d`/`f`）。
    private static func isFloatingPointNumber(_ number: NSNumber) -> Bool {
        let encoding = String(cString: number.objCType)
        return encoding == "d" || encoding == "f"
    }
}
