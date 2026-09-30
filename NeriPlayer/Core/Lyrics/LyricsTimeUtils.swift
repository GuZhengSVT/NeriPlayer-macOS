// LyricsTimeUtils.swift
// NeriPlayer macOS —— 歌词时间戳解析/格式化（移植规划 M4-T1）。
//
// 来源：accompanist-lyrics-core/src/commonMain/.../utils/TimeUtils.kt（纯逻辑，逐分支移植）。
//
// 为什么不用 DateFormatter/ISO8601：歌词里的时间戳不是合法时间，而是「分:秒.毫秒」这种
// 缺位补零的写法（`00:01.5` 表示 1.5 秒而不是 1 秒 5 毫秒），且有 `00:12.50`、`1:2:3`、
// 纯数字等一堆变体。用系统解析器要先把字符串补全成合法时间，反而更容易在补零规则上出错；
// 直接按原库的规则手写，行为一目了然，也能和原库的 golden test 一一对上。
//
// 原库这两个函数是 `String`/`Int` 的扩展；这里收进 `LyricsTime` 命名空间，
// 免得给全工程的 String / Int 加容易撞名的方法（移植时读作 `LyricsTime.parseAsTime(x)`）。
//
// 未移植：原库 `String.isDigitsOnly()`，它只被尚未移植的 LyricifySyllableParser 使用。
// 注意它是 Unicode 语义的 `Char.isDigit()`（阿拉伯数字等也算），将来移植时不能写成
// `"0"..."9"` 的 ASCII 判断。

import Foundation

/// 歌词时间戳的解析与格式化。
public enum LyricsTime {

    /// 把时间戳字符串解析成毫秒（原库 `String.parseAsTime()`）。
    ///
    /// 支持的写法与舍入规则：
    ///   - `mm:ss.SSS` / `hh:mm:ss.SSS`：小时段可以省略，冒号数量决定怎么切。
    ///   - 小数部分不足 3 位按「左对齐补零」处理：`.5` → 500ms、`.50` → 500ms、`.500` → 500ms；
    ///     超过 3 位截断到毫秒（`.1234` → 123ms）。这是原库行为，也符合歌词时间戳的直觉。
    ///   - 完全没有冒号时整串按「秒.毫秒」解析（`"00.123"` → 123ms）。
    ///   - 空串、非法内容、缺字段一律返回 0，不抛错：坏时间戳只该让这一行退化成 0，而不是
    ///     让整份歌词解析失败。
    public static func parseAsTime(_ string: String) -> Int {
        if string.isEmpty { return 0 }

        func parseSecondsAndMillis(_ part: String) -> Int {
            guard let dotIndex = part.firstIndex(of: ".") else {
                return (Int(part) ?? 0) * 1000
            }
            let seconds = (Int(part[part.startIndex..<dotIndex]) ?? 0) * 1000
            let millisPart = part[part.index(after: dotIndex)...]

            if millisPart.isEmpty { return seconds }

            let normalizedMillis: String
            switch millisPart.count {
            case 1: normalizedMillis = millisPart + "00"
            case 2: normalizedMillis = millisPart + "0"
            case 3: normalizedMillis = String(millisPart)
            default: normalizedMillis = String(millisPart.prefix(3))
            }
            return seconds + (Int(normalizedMillis) ?? 0)
        }

        guard let firstColon = string.firstIndex(of: ":") else {
            return parseSecondsAndMillis(string)
        }

        guard let lastColon = string.lastIndex(of: ":") else { return 0 }
        if firstColon == lastColon {
            // mm:ss.ms
            let minutes = (Int(string[string.startIndex..<firstColon]) ?? 0) * 60_000
            return minutes + parseSecondsAndMillis(String(string[string.index(after: firstColon)...]))
        } else {
            // hh:mm:ss.ms
            let hours = (Int(string[string.startIndex..<firstColon]) ?? 0) * 3_600_000
            let minutes = (Int(string[string.index(after: firstColon)..<lastColon]) ?? 0) * 60_000
            return hours + minutes + parseSecondsAndMillis(String(string[string.index(after: lastColon)...]))
        }
    }

    /// 把毫秒格式化成 `mm:ss.SSS`（原库 `Int.toTimeFormattedString()`）。
    ///
    /// 只在导出歌词（`[00:05.000]`）和调试日志里用。负数返回 `"00:00.000"`，与原库一致。
    /// 注意分钟不折进小时：超过 60 分钟会打印成 `"75:03.000"`，这也是原库行为。
    public static func formatted(_ milliseconds: Int) -> String {
        if milliseconds < 0 { return "00:00.000" }

        let totalSeconds = milliseconds / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let millis = milliseconds % 1000

        let m = minutes < 10 ? "0\(minutes)" : "\(minutes)"
        let s = seconds < 10 ? "0\(seconds)" : "\(seconds)"
        let ms: String
        switch millis {
        case 0..<10: ms = "00\(millis)"
        case 10..<100: ms = "0\(millis)"
        default: ms = "\(millis)"
        }
        return "\(m):\(s).\(ms)"
    }
}
