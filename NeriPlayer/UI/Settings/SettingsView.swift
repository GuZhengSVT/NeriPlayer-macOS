// SettingsView.swift
// Categorized macOS settings, following the Android two-level settings information architecture.
import AppKit
import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case accounts, general, appearance, playback, lyrics, network, storage, backup, listenTogether, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accounts: return "账号"
        case .general: return "通用"
        case .appearance: return "外观与个性化"
        case .playback: return "播放与音质"
        case .lyrics: return "歌词"
        case .network: return "网络与下载"
        case .storage: return "存储与媒体库"
        case .backup: return "备份与同步"
        case .listenTogether: return "一起听"
        case .about: return "关于"
        }
    }
    var subtitle: String {
        switch self {
        case .accounts: return "管理在线平台登录状态"
        case .general: return "启动、音量与应用行为"
        case .appearance: return "主题、强调色与界面展示"
        case .playback: return "均衡器、响度、淡变与独占输出"
        case .lyrics: return "歌词显示、翻译与偏移"
        case .network: return "在线服务与下载管理"
        case .storage: return "媒体库目录与文件扫描"
        case .backup: return "配置备份与远程同步"
        case .listenTogether: return "房间与协同播放"
        case .about: return "版本、诊断与开源信息"
        }
    }
    var systemImage: String {
        switch self {
        case .accounts: return "person.crop.circle"
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .playback: return "play.circle"
        case .lyrics: return "quote.bubble"
        case .network: return "network"
        case .storage: return "externaldrive"
        case .backup: return "arrow.triangle.2.circlepath"
        case .listenTogether: return "person.2"
        case .about: return "info.circle"
        }
    }
}

/// 设置页可请求的顶层导航目的地。由 MainContentView 注入 `onNavigate` 后才会生效：
/// 未注入时设置页只显示说明文字，不渲染按钮，因此不会出现点了没反应的入口。
enum SettingsDestination {
    case explore
    case downloads
}

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    var syncViewModel: SyncViewModel?
    var audioEffectsViewModel: AudioEffectsViewModel?
    var listenTogetherViewModel: ListenTogetherViewModel?
    var onlineViewModel: OnlineViewModel?
    /// 应用级歌词模型。由 MainContentView 传入 AppState.lyricsViewModel；缺失时歌词偏好不可用。
    var lyricsViewModel: LyricsViewModel?
    /// 打开搜索 / 下载页的导航回调。由 MainContentView 注入；未注入时相关按钮不显示。
    var onNavigate: ((SettingsDestination) -> Void)?
    @Environment(\.openWindow) private var openWindow
    // 默认停在「通用」：与既有行为一致，也避免切到设置 tab 时先渲染重页（播放与音质 / 存储）。
    @State private var selection: SettingsCategory = .general
    @State private var activeSheet: SettingsSheet?

    var body: some View {
        // 刻意不用嵌套 NavigationSplitView：它是主窗口里第二个 split view，分类切换要走列转场，
        // 详情树每次都要连同列动画整体重排。这里用稳定的 HStack 两栏，切换只重算被替换的
        // 详情内容，不再触发第二个 split view 的列转场。
        HStack(spacing: 0) {
            categoryList
            Divider()
            categoryDetail
        }
        .onAppear { viewModel.refreshDirectories() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .login:
                if let onlineViewModel { OnlineLoginView(viewModel: onlineViewModel) }
            case .lyrics:
                if let lyricsViewModel { LyricsPreferencesView(model: lyricsViewModel) }
            }
        }
        .safeAreaInset(edge: .bottom) { statusFooter }
    }

    /// 左侧分类列表。与详情同处一个稳定 HStack，不再触发 NavigationSplitView 的列转场。
    private var categoryList: some View {
        List(SettingsCategory.allCases, selection: $selection) { category in
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                    Text(category.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: category.systemImage)
            }
            .padding(.vertical, 4)
            .tag(category)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
        .navigationTitle("设置")
    }

    /// 右侧详情。切换分类时禁用隐式动画，避免为新旧内容做交叉淡入与布局动画。
    private var categoryDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(selection.title).font(.title2.weight(.semibold))
                Text(selection.subtitle).foregroundStyle(.secondary)
                categoryContent
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle(selection.title)
        .transaction { $0.disablesAnimations = true }
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selection {
        case .accounts:
            settingsGroup("在线平台") {
                if let onlineViewModel {
                    AccountSettingsSection(model: onlineViewModel, onManage: { activeSheet = .login })
                } else {
                    Text("在线服务尚未就绪").foregroundStyle(.secondary)
                }
            }
        case .general:
            settingsGroup("应用行为") {
                Toggle("启动后继续播放上次进度", isOn: resumeBinding)
                HStack {
                    Text("启动音量")
                    // 不传 step：macOS 上带 step 的 Slider 会让 AppKit 为每个刻度绘制 tick mark
                    // （0–100 即 101 个），切页时触发 -[NSSliderTickMarks _rebuildTickMarkRectCache]。
                    // 吸附改在 binding 里做，行为与 step: 1 一致。
                    Slider(value: volumeBinding, in: PlaybackBehaviorDefaults.volumeRange)
                    Text("\(Int(viewModel.defaultVolume))").monospacedDigit().foregroundStyle(.secondary).frame(width: 36)
                }
                Text("关闭继续播放时，队列与进度仍会恢复，但应用保持暂停。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .appearance:
            settingsGroup("主题") {
                Picker("配色模式", selection: appearanceBinding) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.pickerStyle(.segmented)
                Picker("强调色", selection: accentBinding) {
                    ForEach(AccentColorOption.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        case .playback:
            if let audioEffectsViewModel { settingsGroup("音效与输出") { AudioEffectsSettingsView(model: audioEffectsViewModel) } } else {
                settingsGroup("音效与输出") { Text("音效设置尚未就绪。").foregroundStyle(.secondary) }
            }
            settingsGroup("播放控制") {
                Text("播放 / 暂停、上一首、下一首与进度在窗口底部的播放控制栏。")
                    .foregroundStyle(.secondary)
            }
        case .lyrics:
            settingsGroup("歌词偏好") {
                if lyricsViewModel != nil {
                    Text("字号、模糊非当前行、翻译与音译立即生效，未播放时也可调整；单曲偏移与网易云匹配在播放后可用。")
                        .foregroundStyle(.secondary)
                    Button("打开歌词设置") { activeSheet = .lyrics }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("播放引擎尚未就绪，暂时无法调整歌词偏好。")
                        .foregroundStyle(.secondary)
                }
            }
        case .network:
            settingsGroup("在线服务") {
                Text("探索页提供网易云音乐、哔哩哔哩和 YouTube Music 的搜索与浏览。")
                    .foregroundStyle(.secondary)
                if let onNavigate { Button("打开搜索") { onNavigate(.explore) }.buttonStyle(.bordered) }
            }
            settingsGroup("下载") {
                Text("下载进度、暂停 / 续传与清理在「下载」页。")
                    .foregroundStyle(.secondary)
                if let onNavigate { Button("打开下载") { onNavigate(.downloads) }.buttonStyle(.bordered) }
            }
        case .storage:
            settingsGroup("媒体库目录") { libraryDirectoryContent }
        case .backup:
            if let syncViewModel { settingsGroup("备份与同步") { SyncSettingsSections(viewModel: syncViewModel) } } else {
                Text("同步服务尚未就绪").foregroundStyle(.secondary)
            }
        case .listenTogether:
            if let listenTogetherViewModel { settingsGroup("一起听") { ListenTogetherSettingsView(model: listenTogetherViewModel) } } else {
                Text("一起听服务尚未就绪").foregroundStyle(.secondary)
            }
        case .about:
            settingsGroup("NeriPlayer") {
                Text("版本 \(AppInfo.versionString)").font(.headline)
                Text("原生 macOS 音乐播放器").foregroundStyle(.secondary)
                Button("打开诊断信息") { openWindow(id: "diagnostics") }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var resumeBinding: Binding<Bool> { Binding(get: { viewModel.resumePlaybackOnLaunch }, set: viewModel.setResumePlaybackOnLaunch) }
    private var volumeBinding: Binding<Double> {
        Binding(get: { viewModel.defaultVolume }, set: { viewModel.setDefaultVolume($0.rounded()) })
    }
    private var appearanceBinding: Binding<AppearanceMode> { Binding(get: { viewModel.appearance }, set: viewModel.setAppearance) }
    private var accentBinding: Binding<AccentColorOption> { Binding(get: { viewModel.accent }, set: viewModel.setAccent) }

    private var libraryDirectoryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.directories.isEmpty {
                Text("还没有配置音乐目录。加入后应用会记住它，并可在这里重新扫描。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.directories) { directory in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(directory.displayName)
                            Text(directory.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { viewModel.removeDirectory(id: directory.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("移除目录")
                    }
                }
            }
            HStack {
                Button("添加目录…") { chooseDirectory() }
                Spacer()
                Button("重新扫描全部") { viewModel.rescanAll() }.disabled(viewModel.directories.isEmpty)
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false; panel.prompt = "加入"; panel.message = "选择要加入媒体库的音乐文件夹"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(viewModel.addDirectory)
    }

    @ViewBuilder private var statusFooter: some View {
        if let message = viewModel.statusMessage {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text(message).font(.callout)
                Spacer()
                Button("知道了") { viewModel.clearStatusMessage() }.buttonStyle(.borderless)
            }
            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding([.horizontal, .bottom])
        }
    }
}

private enum SettingsSheet: String, Identifiable {
    case login
    case lyrics
    var id: String { rawValue }
}

/// 账号分类内容。独立成子视图的原因：
///   - SettingsView.onlineViewModel 是普通 var，读取它不会建立订阅，账号异步加载完成后
///     父视图不会重绘；这里用 ObservedObject 订阅，账号 / 登录态变化才能反映到界面。
///   - 账号页只需要账号状态：task 基于当前平台只拉一次账号，不再连带推荐 / 歌单等浏览数据。
private struct AccountSettingsSection: View {
    @ObservedObject var model: OnlineViewModel
    var onManage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.account?.name ?? "未登录", systemImage: "person.crop.circle")
                if model.isLoadingAccount { ProgressView().controlSize(.small) }
                Spacer()
                Button(model.account == nil ? "登录" : "管理", action: onManage)
                    .buttonStyle(.borderedProminent)
            }
            Picker("平台", selection: Binding(get: { model.source }, set: model.setSource)) {
                ForEach(MusicSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if let message = model.browseErrors["账号"] {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        // 平台切换时重新读取新平台的账号：source 变化会让这条 task 重跑。
        .task(id: model.source) { model.loadAccountContent() }
    }
}

extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension AccentColorOption {
    var color: Color {
        switch self {
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .orange: return .orange
        case .green: return .green
        case .graphite: return Color(white: 0.42)
        }
    }
}
