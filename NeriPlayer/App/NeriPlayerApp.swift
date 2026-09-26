// NeriPlayerApp.swift
// SwiftUI 应用入口。M0-T6 起根视图为 MainContentView（主窗口 + 侧栏导航骨架）。
// M0-T4：启动时安装崩溃捕获，并探测上次崩溃记录以标记安全模式。

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
                    appState.detectSafeMode()
                }
        }
    }
}
