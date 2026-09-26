// AppState.swift
// M0-T4：应用级运行状态。当前只承载「安全模式」标记，供启动探测与占位 UI 使用。

import Combine
import Foundation

/// 应用运行状态（启动阶段的标记位）。
public final class AppState: ObservableObject {

    /// 是否处于安全模式（上次异常退出后进入的降级启动）。
    @Published public private(set) var isSafeMode: Bool

    public init(isSafeMode: Bool = false) {
        self.isSafeMode = isSafeMode
    }

    /// 启动探测：若存在待处理崩溃记录则进入安全模式。
    @discardableResult
    public func detectSafeMode() -> Bool {
        guard CrashState.isSafeModeRequired else { return false }
        isSafeMode = true
        Log.error("pending crash report detected; entering safe mode", to: Log.ui)
        return true
    }
}
