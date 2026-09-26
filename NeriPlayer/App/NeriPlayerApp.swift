// NeriPlayerApp.swift
// SwiftUI 应用入口。M0-T1 仅提供占位窗口，窗口/导航骨架在 M0-T6 补齐。
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
            PlaceholderRootView()
                .environmentObject(appState)
                .task {
                    appState.detectSafeMode()
                }
        }
    }
}

/// M0-T1 占位根视图；后续由主窗口 + 侧栏导航替换。
struct PlaceholderRootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 12) {
            Text(AppInfo.displayName)
                .font(.largeTitle)
            if appState.isSafeMode {
                Text("安全模式")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}
