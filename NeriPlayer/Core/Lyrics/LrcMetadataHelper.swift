// LrcMetadataHelper.swift
// NeriPlayer macOS —— LRC 头部元数据与制作信息行的识别（移植规划 M4-T1）。
//
// 来源：accompanist-lyrics-core/src/commonMain/.../utils/LrcMetadataHelper.kt（纯逻辑，逐分支移植）。
//
// 这个工具只处理「已知标签」和「已知角色」，这一点是刻意的：
//   - 头部标签只认 `[ar:][ti:][al:][offset:][length:]`，其余标签（典型是 `[bg:…]`、`[by:…]`）
//     一律原样保留。`[bg:…]` 是伴奏歌词的容器，删掉它等于删掉和声。
//   - 制作信息行只认「已知角色 + 冒号 + 非空内容」的形状（`作词 : 罗言`、`OP: 唯迹文化`），
//     普通歌词里出现冒号（`[00:10.00]爱：是…`）不会被误删。
//
// 与原库的一处实现差异：原库 `parse` 里 `.toMap()` 对重复标签保留最后一次出现的值，
// 这里用顺序覆盖的字典保持同样行为（`[ti:A]` 和 `[ti:B]` 同时存在时取 B）。

import Foundation

/// LRC 头部元数据解析与制作信息行识别（原库 `LrcMetadataHelper`）。
public enum LrcMetadataHelper {

    /// 会被识别并（在 `removeAttributes` 中）移除的已知标签。
    ///
    /// 原库注释：其余标签（如 `bg`）会被忽略 —— 忽略指"不删"，不是"不解析"。
    public static let metadataTags: Set<String> = ["ar", "ti", "al", "offset", "length"]

    /// 常见的制作信息角色（简繁 + 英文），用于识别"作词 : X""OP: Y"这类非歌词的元数据行。
    ///
    /// 与原库逐字对应。判定前会把角色 lowercased，所以英文项这里都是小写。
    public static let creditRoles: Set<String> = [
        "作词", "作詞", "作曲", "编曲", "編曲", "制作人", "製作人", "制作", "製作",
        "出品", "出品人", "联合出品", "聯合出品", "营销", "營銷", "策划", "策劃",
        "企划", "企劃", "监制", "監製", "统筹", "統籌", "发行", "發行", "混音",
        "母带", "母帶", "录音", "錄音", "和声", "和聲", "和音", "配唱", "演唱",
        "原唱", "词", "詞", "曲", "吉他", "贝斯", "貝斯", "鼓", "键盘", "鍵盤",
        "弦乐", "弦樂", "录音师", "錄音師", "混音师", "混音師", "母带工程师",
        "制作公司", "版权", "版權", "鸣谢", "鳴謝", "特别鸣谢", "特別鳴謝",
        "op", "sp", "lyricist", "composer", "arranger", "producer", "mixing",
        "mastering", "recording", "vocal", "guitar", "bass", "drums", "keyboard",
        "strings"
    ]

    /// `[tag:value]` 的通用形状，用于挑出候选行。
    private static let attributeParser = #/^\[([a-zA-Z]+):\s*(.*)\]\s*$/#

    /// 从若干行里抽出已知标签的值（原库 `parse(lines)`）。
    ///
    /// 缺失的 `offset`/`length` 落到 0（不是 nil），与 `Attributes` 的默认口径一致。
    public static func parse(_ lines: [String]) -> Attributes {
        var values: [String: String] = [:]

        for line in lines {
            guard let match = line.wholeMatch(of: attributeParser) else { continue }
            let tag = String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard metadataTags.contains(tag) else { continue }
            let value = String(match.output.2).trimmingCharacters(in: .whitespacesAndNewlines)
            values[tag] = value
        }

        return Attributes(
            artist: values["ar"],
            album: values["al"],
            title: values["ti"],
            offset: values["offset"].flatMap { Int($0) } ?? 0,
            duration: values["length"].flatMap { Int($0) } ?? 0
        )
    }

    /// 只移除已知标签所在的行（原库 `removeAttributes(lines)`）。
    ///
    /// `[bg:…]` 这类未知标签会被保留 —— 它们承载的是内容，不是元数据。
    public static func removeAttributes(_ lines: [String]) -> [String] {
        lines.filter { line in
            guard let match = line.wholeMatch(of: attributeParser) else { return true }
            return !metadataTags.contains(String(match.output.1))
        }
    }

    /// 判断一行正文是否是制作信息（原库 `isCreditLine(content)`）。
    ///
    /// 只有分隔符**之前**的 token 是已知角色时才算制作信息，所以普通歌词里出现冒号不受影响。
    /// 原库注释提到这个实现刻意不用 unicode-property 正则，为的是 KMP 平台兼容；移植后同样
    /// 保留手写扫描，行为与原库逐条对齐。
    public static func isCreditLine(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }

        let separatorOffset = trimmed.distance(from: trimmed.startIndex, to: separator)
        if separatorOffset <= 0 { return false }

        let role = String(trimmed[trimmed.startIndex..<separator])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if role.isEmpty || role.count > 12 { return false }
        if role.contains(where: { $0.isWhitespace }) { return false }

        let rest = trimmed[trimmed.index(after: separator)...]
        if rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }

        return creditRoles.contains(role)
    }
}
