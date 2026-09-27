// MainContentView.swift
// M0-T6：主窗口 + 侧栏导航骨架。左侧 Sidebar 列出五个顶层导航项（首页/探索/媒体库/下载/设置），
// 右侧详情区渲染选中项对应的占位视图。本任务只做骨架，详情区不含任何业务功能，
// 真实内容由后续里程碑任务替换。
// M2-T5：媒体库 tab 的占位视图替换为 LibraryView（数据来自 AppState.libraryViewModel）。
//
// 选中项持久化：通过 SettingsStore 的 SettingsKeys.lastSelectedTab 保存/恢复上次选中的 tab；
// 存储值缺失或无法识别时回落到 .home。写回放在 Binding 的 setter 里（而非 onChange），
// 这样在 macOS 13 部署目标下不依赖 onChange(of:initial:) 的新签名，也不产生弃用警告。

import SwiftUI

// MARK: - 导航项

/// 顶层导航项。rawValue 即持久化到 SettingsKeys.lastSelectedTab 的标识。
enum MainTab: String, CaseIterable, Identifiable, Hashable {
    case home
    case explore
    case library
    case downloads
    case settings

    var id: String { rawValue }

    /// 侧栏显示名。
    var title: String {
        switch self {
        case .home: return "首页"
        case .explore: return "探索"
        case .library: return "媒体库"
        case .downloads: return "下载"
        case .settings: return "设置"
        }
    }

    /// 侧栏图标（SF Symbol）。
    var systemImage: String {
        switch self {
        case .home: return "house"
        case .explore: return "safari"
        case .library: return "music.note.list"
        case .downloads: return "arrow.down.circle"
        case .settings: return "gearshape"
        }
    }

    /// 从持久化的字符串恢复；空值或未识别的值回落到 .home。
    init(storedValue: String) {
        self = MainTab(rawValue: storedValue) ?? .home
    }
}

// MARK: - 主视图

/// 主窗口根视图：NavigationSplitView 侧栏 + 占位详情区。
struct MainContentView: View {
    @EnvironmentObject private var appState: AppState

    /// 设置存储（可注入，便于测试）。默认使用全局共享实例。
    private let store: SettingsStore
    @State private var selection: MainTab

    /// 构造时即读出上次选中的 tab，避免首帧先显示 home 再跳转。
    init(store: SettingsStore = .shared) {
        self.store = store
        _selection = State(initialValue: MainTab(storedValue: store.value(for: SettingsKeys.lastSelectedTab)))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    /// 详情区。媒体库 tab 分派到真实视图，其余 tab 仍是占位。
    @ViewBuilder
    private var detail: some View {
        if selection == .library, let viewModel = appState.libraryViewModel {
            LibraryView(viewModel: viewModel)
        } else {
            PlaceholderDetailView(tab: selection, isSafeMode: appState.isSafeMode)
        }
    }

    /// 左侧导航栏。selection 用自定义 Binding，写入时顺带持久化。
    private var sidebar: some View {
        List(selection: selectionBinding) {
            ForEach(MainTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
        .navigationTitle(AppInfo.displayName)
    }

    /// 选中项读写：更新 @State 的同时把 tab 标识写入设置存储。
    private var selectionBinding: Binding<MainTab> {
        Binding(
            get: { selection },
            set: { newValue in
                selection = newValue
                store.set(newValue.rawValue, for: SettingsKeys.lastSelectedTab)
            }
        )
    }
}

// MARK: - 占位详情

/// 占位详情视图：显示当前 tab 的名称与图标；安全模式下在顶部给出提示条。
/// 各 tab 的真实内容由后续里程碑任务替换。
struct PlaceholderDetailView: View {
    let tab: MainTab
    let isSafeMode: Bool

    var body: some View {
        VStack(spacing: 16) {
            if isSafeMode {
                safeModeBanner
            }
            Spacer()
            Image(systemName: tab.systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(tab.title)
                .font(.title2)
            Text("占位视图 · M0-T6 仅有导航骨架")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(tab.title)
    }

    /// 安全模式提示条。保持 M0-T4 的降级提示可见。
    private var safeModeBanner: some View {
        Label("安全模式：上次异常退出，部分功能可能不可用", systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .padding([.horizontal, .top])
    }
}
