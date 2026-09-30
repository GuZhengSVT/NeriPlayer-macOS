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
