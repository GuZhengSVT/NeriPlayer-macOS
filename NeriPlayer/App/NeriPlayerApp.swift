// NeriPlayerApp.swift
// SwiftUI 应用入口。M0-T1 仅提供占位窗口，窗口/导航骨架在 M0-T6 补齐。

import SwiftUI

@main
struct NeriPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderRootView()
        }
    }
}

/// M0-T1 占位根视图；后续由主窗口 + 侧栏导航替换。
struct PlaceholderRootView: View {
    var body: some View {
        Text(AppInfo.displayName)
            .font(.largeTitle)
            .padding(40)
            .frame(minWidth: 480, minHeight: 320)
    }
}
