// AppInfo.swift
// 应用级常量与纯函数工具。M0-T1 只放最小可测内容，供冒烟测试校验模块可导入。

import Foundation

/// 应用级元信息与工具函数。
public enum AppInfo {
    /// 应用显示名。
    public static let displayName = "NeriPlayer"
    /// macOS 版独立于 Android 版的 SemVer 版本。
    public static let marketingVersion = "0.1.0"
    /// 发布构建号；打包脚本可通过 BUILD_NUMBER 覆盖。
    public static let buildNumber = "1"
    /// 应用标识符，和崩溃日志、URL Scheme 保持一致。
    public static let bundleIdentifier = "moe.ouom.NeriPlayer"
    public static let urlScheme = "neriplayer"

    /// 从 Bundle 读取发布版本，SwiftPM 直接运行时回退到仓库默认值。
    public static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (.some(short), .some(build)): return "\(short) (\(build))"
        case let (.some(short), .none): return short
        case let (.none, .some(build)): return "\(marketingVersion) (\(build))"
        case (.none, .none): return "\(marketingVersion) (\(buildNumber))"
        }
    }

    /// 组合问候/标题文案；空输入回落到应用名。
    public static func makeTitle(with suffix: String?) -> String {
        guard let suffix, !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return displayName
        }
        return "\(displayName) · \(suffix)"
    }
}
