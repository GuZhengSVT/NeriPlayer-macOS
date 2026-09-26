// NeriPlayerApp.swift
// SwiftUI 应用入口。M0-T6 起根视图为 MainContentView（主窗口 + 侧栏导航骨架）。
// M0-T4：启动时安装崩溃捕获，并探测上次崩溃记录以标记安全模式。
// M1-T6：启动时创建播放内存态并接入媒体键 / Now Playing；退出清理由 AppState 挂的
// NSApplication.willTerminateNotification 触发（SwiftUI 的 .task 没有对应的结束回调）。

import SwiftUI

@main
struct NeriPlayerApp: App {
    /// 应用级状态；启动时探测 pending 崩溃记录。
    @StateObject private var appState = AppState()

    init() {
        CrashReporter.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            MainContentView()
                .environmentObject(appState)
                .task {
                    // 顺序有讲究：先按崩溃记录决定是否降级，再启动播放集成。
                    appState.detectSafeMode()
                    appState.startPlaybackIntegration()
                }
        }
    }
}
