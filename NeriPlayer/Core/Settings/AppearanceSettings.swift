// AppearanceSettings.swift
// NeriPlayer macOS —— 外观相关的设置取值（移植规划 M3-T5）。
//
// 定位：只放「有哪些可选值」与它们的稳定标识（rawValue），不放任何 SwiftUI 类型 ——
// Core/设置取值不该依赖界面框架，界面侧在 UI 层加一层到 ColorScheme/Color 的映射。
//
// 为什么用字符串 rawValue 而不是 Int 序号：设置是持久化数据，序号会在插入新选项时整体错位
// （用户选中的「深色」变成别的），字符串标识不会。未知值一律回落到默认项而不是崩溃 ——
// 设置可能来自更早或更晚的版本，读到不认识的值时应用要能正常启动。

import Foundation

// MARK: - 主题外观

/// 主题外观模式。
public enum AppearanceMode: String, CaseIterable, Sendable {

    /// 跟随系统。
    case system
    /// 始终浅色。
    case light
    /// 始终深色。
    case dark

    /// 设置页展示用的名称。
    public var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// 默认值。
    public static let fallback: AppearanceMode = .system

    /// 由持久化字符串解析；未识别时回落到 system。
    public init(storedValue: String) {
        self = AppearanceMode(rawValue: storedValue) ?? .fallback
    }
}

// MARK: - 强调色

/// 强调色选项。取值是稳定标识，不是颜色本身 —— 颜色在 UI 层映射，便于换主题或微调配色。
public enum AccentColorOption: String, CaseIterable, Sendable {

    case blue
    case purple
    case pink
    case orange
    case green
    case graphite

    /// 设置页展示用的名称。
    public var displayName: String {
        switch self {
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .pink: return "粉色"
        case .orange: return "橙色"
        case .green: return "绿色"
        case .graphite: return "石墨"
        }
    }

    /// 默认值。
    public static let fallback: AccentColorOption = .blue

    /// 由持久化字符串解析；未识别时回落到 blue。
    public init(storedValue: String) {
        self = AccentColorOption(rawValue: storedValue) ?? .fallback
    }
}

// MARK: - 播放行为默认值

/// 播放行为相关设置的允许范围与默认值。
///
/// 集中成一处是为了让「设置页的滑杆范围」与「恢复现场时实际夹取的范围」用同一组常量 ——
/// 否则滑杆给 0–100、读取侧按 0–1 解释这类不一致只能靠人工比对两处代码发现。
public enum PlaybackBehaviorDefaults {

    /// 启动音量的默认值（mpv 量程 0–100）。
    public static let volume: Double = 70
    /// 启动音量的合法区间。
    public static let volumeRange: ClosedRange<Double> = 0...100

    /// 把任意输入夹到合法音量区间。
    public static func clampedVolume(_ value: Double) -> Double {
        guard value.isFinite else { return volume }
        return min(max(value, volumeRange.lowerBound), volumeRange.upperBound)
    }
}

// MARK: - 字体家族（需求 5）

/// 字体家族的稳定标识与展示名。
///
/// 放在 Core 而不是 UI：设置键的默认值要用到「系统字体」这个哨兵标识，
/// 而设置层不该依赖 AppKit。枚举本机可用字体（`NSFontManager`）的部分放在
/// UI/Appearance/AppTypography.swift 的扩展里，保持 Core 只依赖 Foundation。
public enum TypographyFontFamily {

    /// 「系统字体」的稳定标识（持久化用）。刻意用一个不可能与真实家族重名的哨兵值。
    public static let systemID = "__neri_system__"
    /// 「系统字体」的展示名。
    public static let systemDisplayName = "系统字体"

    /// 设置页展示名：系统字体给中文名，其余用家族本名。
    public static func displayName(for family: String) -> String {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == systemID ? systemDisplayName : trimmed
    }

    /// 纯函数版本的可用性判定：空值或未知家族回落到系统字体。
    public static func resolved(_ stored: String, available: Set<String>) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != systemID else { return systemID }
        return available.contains(trimmed) ? trimmed : systemID
    }
}

// MARK: - 字体默认值与取值范围（需求 5）

/// 外观页字体设置的默认值与合法区间。
///
/// 与 `PlaybackBehaviorDefaults` 同一个思路：滑杆范围与读取侧夹取范围共用一组常量，
/// 避免「滑杆给一个区间、读取侧按另一个区间解释」这类只能靠人工比对两处代码才能发现的不一致。
public enum AppTypographyDefaults {

    /// UI 基础字号默认值（相对它缩放 `AppTypography.uiScale`）。
    public static let uiBaseSize: Double = 14
    /// 播放器字号默认值（底部栏标题、播放页曲目信息等）。
    public static let playerTextSize: Double = 17
    /// 底部歌词字号默认值。
    public static let compactLyricsSize: Double = 18
    /// 歌词字号默认值。与 M4 的歌词偏好沿用同一个数值。
    public static let lyricsBaseSize: Double = 28

    /// UI 基础字号区间。
    public static let uiBaseSizeRange: ClosedRange<Double> = 11...20
    /// 播放器字号区间。
    public static let playerTextSizeRange: ClosedRange<Double> = 12...28
    /// 底部歌词字号区间。
    public static let compactLyricsSizeRange: ClosedRange<Double> = 10...32
    /// 歌词字号区间。与歌词窗口既有滑杆（16–44）保持一致。
    public static let lyricsBaseSizeRange: ClosedRange<Double> = 16...44

    /// 把任意输入夹到合法区间；非有限值（NaN / 无穷）回落到默认值。
    public static func clamped(_ value: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
