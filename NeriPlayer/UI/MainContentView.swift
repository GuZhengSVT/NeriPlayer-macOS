// MainContentView.swift
// 主窗口：五个顶层导航项（首页/搜索/媒体库/下载/设置）与应用级底部播放栏。
// explore 的持久化值保留，界面显示为搜索；平台歌单在媒体库独立分栏管理。
//
// 选中项持久化：通过 SettingsStore 的 SettingsKeys.lastSelectedTab 保存/恢复上次选中的 tab；
// 存储值缺失或无法识别时回落到 .home。写回放在 Binding 的 setter 里（而非 onChange），
// 这样在 macOS 13 部署目标下不依赖 onChange(of:initial:) 的新签名，也不产生弃用警告。
//
// M2-T8/M8：窗口底部挂一条跨 tab 常驻的浮动播放器，统一承载当前曲目、进度与播放控制。
// 播放是应用级状态，切 tab 不重建会话；队列在播放栏就地展开。
//
// 2026-10-03 播放体验整改：
//   * 删除旧的「歌词页面」sheet 导航入口（`lyricsPresented`）与相应按钮；歌词改由「歌曲播放页」承载，
//     桌面悬浮歌词入口保留（在播放器栏与播放页里）。
//   * 歌曲播放页在主窗口**内容区**展示为一层覆盖视图（不是 sheet、不是独立窗口）：点底部封面或
//     歌曲信息打开，点页内「返回」回到此前的导航页面 —— 因为只是覆盖，原页面的选中 tab 与滚动
//     位置都不受影响，播放也完全连续；底部常驻播放器栏仍在，页内不再重复一套播放控制。
//   * 在根视图挂上统一字体接口（B 提供的 AppTypographyModifier）：它内部观察设置变化并注入
//     typography，因此设置里的字体/字号改动会即时反映到主窗口、底部栏与播放页。

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
        case .explore: return "搜索"
        case .library: return "媒体库"
        case .downloads: return "下载"
        case .settings: return "设置"
        }
    }

    /// 侧栏图标（SF Symbol）。
    var systemImage: String {
        switch self {
        case .home: return "house"
        case .explore: return "magnifyingglass"
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

/// 主窗口根视图。
struct MainContentView: View {
    @EnvironmentObject private var appState: AppState

    /// 设置存储（可注入，便于测试）。默认使用全局共享实例。
    private let store: SettingsStore
    @State private var selection: MainTab
    /// 是否正在展示「歌曲播放页」。
    @State private var showingNowPlaying = false
    @State private var libraryPage: MediaLibraryPage = .local
    @StateObject private var searchPageModel = SearchPageModel()

    /// 构造时即读出上次选中的 tab，避免首帧先显示 home 再跳转。
    init(store: SettingsStore = .shared) {
        self.store = store
        _selection = State(initialValue: MainTab(storedValue: store.value(for: SettingsKeys.lastSelectedTab)))
    }

    var body: some View {
        // 上下两段：主内容（侧栏 + 详情）占满剩余高度，播放状态条固定在窗口底部。
        // 无当前曲时仍保留播放栏和进度轨道，避免加载时界面跳动。
        ZStack {
            HyperBackgroundView(dark: appState.settingsViewModel?.appearance == .dark)
                .ignoresSafeArea()
                .opacity(0.22)
            VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
            if let coordinator = appState.onlinePlayback { OnlinePlaybackStatusView(coordinator: coordinator) }
            FloatingPlayerBar(onOpenNowPlaying: { showingNowPlaying = true })
        }
        .frame(minWidth: 720, minHeight: 480)
        // M3-T5：外观设置在整个窗口的根上生效，侧栏、状态条与各 tab 一起跟着变。
        // 视图模型缺失（理论上不会发生，设置不依赖任何可失败资源）时保持系统默认外观。
        .preferredColorScheme(appState.settingsViewModel?.appearance.colorScheme)
        .tint(appState.settingsViewModel?.accent.color)
        // 需求 5：统一字体接口在根上注入，主窗口、底部栏与播放页共用同一份排版设置。
        .modifier(AppTypographyModifier(model: appState.settingsViewModel))
        }
    }

    /// 详情区：歌曲播放页叠在导航页**之上**（而不是替换）。
    ///
    /// 用 ZStack 覆盖而不是「showingNowPlaying ? NowPlayingPage : navigationDetail」的替换式写法：
    /// 覆盖时原页面只是被隐藏，它的 @State（选中 tab、滚动位置、展开状态）都还在，返回时原样可见；
    /// 替换则会把原页面重新构造一遍，滚动位置会丢。
    @ViewBuilder
    private var detail: some View {
        ZStack {
            navigationDetail
                .opacity(showingNowPlaying ? 0 : 1)
                .allowsHitTesting(!showingNowPlaying)
            if showingNowPlaying {
                NowPlayingPage(onBack: { showingNowPlaying = false })
            }
        }
    }

    /// 原有导航详情：按选中 tab 分发。初始化失败时保留占位提示。
    @ViewBuilder
    private var navigationDetail: some View {
        if selection == .home, let online = appState.onlineViewModel, let home = appState.homeViewModel {
            HomeView(onlineViewModel: online, homeViewModel: home, libraryViewModel: appState.libraryViewModel,
                     onExplore: { selectionBinding.wrappedValue = .explore },
                     onLibrary: { selectionBinding.wrappedValue = .library },
                     onDownloads: { selectionBinding.wrappedValue = .downloads },
                     onOpenCollection: openCollection)
        } else if selection == .library, let viewModel = appState.libraryViewModel {
            MediaLibraryView(viewModel: viewModel, selection: $libraryPage)
        } else if selection == .explore, let model = appState.onlineViewModel {
            SearchView(viewModel: model, pageModel: searchPageModel, onOpenCollection: openCollection)
        } else if selection == .downloads, let downloads = appState.downloadViewModel {
            DownloadsView(viewModel: downloads)
        } else if selection == .settings, let settingsViewModel = appState.settingsViewModel {
            SettingsView(viewModel: settingsViewModel, syncViewModel: appState.syncViewModel,
                         audioEffectsViewModel: appState.audioEffectsViewModel,
                         listenTogetherViewModel: appState.listenTogetherViewModel,
                         onlineViewModel: appState.onlineViewModel,
                         lyricsViewModel: appState.lyricsViewModel,
                         onNavigate: { destination in
                             switch destination {
                             case .explore: selectionBinding.wrappedValue = .explore
                             case .downloads: selectionBinding.wrappedValue = .downloads
                             }
                         })
        } else {
            PlaceholderDetailView(tab: selection, isSafeMode: appState.isSafeMode)
        }
    }

    /// 左侧导航栏。selection 用自定义 Binding，写入时顺带持久化。
    ///
    /// 侧栏文字刻意不写 `.font(...)`：根视图上挂的 AppTypographyModifier 会把 UI 字体与基础字号
    /// 设在环境里，未显式指定字体的文本自动跟随；这里再指定一次反而会盖掉该设置。
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
    ///
    /// 切 tab 时顺带关闭歌曲播放页：用户点侧栏就是想离开播放页，留在覆盖层上会让人以为点击无效。
    private var selectionBinding: Binding<MainTab> {
        Binding(
            get: { selection },
            set: { newValue in
                showingNowPlaying = false
                selection = newValue
                store.set(newValue.rawValue, for: SettingsKeys.lastSelectedTab)
            }
        )
    }

    private func openCollection(_ collection: OnlineCollection) {
        libraryPage = MediaLibraryPage(source: collection.source)
        appState.libraryOnlineModels[collection.source]?.selectCollection(collection)
        selectionBinding.wrappedValue = .library
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
