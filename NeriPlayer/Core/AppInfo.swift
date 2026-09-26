// AppInfo.swift
// 应用级常量与纯函数工具。M0-T1 只放最小可测内容，供冒烟测试校验模块可导入。

import Foundation

/// 应用级元信息与工具函数。
public enum AppInfo {
    /// 应用显示名。
    public static let displayName = "NeriPlayer"

    /// 组合问候/标题文案；空输入回落到应用名。
    public static func makeTitle(with suffix: String?) -> String {
        guard let suffix, !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return displayName
        }
        return "\(displayName) · \(suffix)"
    }
}
