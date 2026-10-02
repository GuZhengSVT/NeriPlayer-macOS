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

/// 设置页使用的文字尺寸（相对 14pt UI 基准）。
///
/// 为什么集中成常量：设置页原本散落 `font(.caption)/.headline/.title2` 这类语义字体，
/// 它们会覆盖根字体，不受「UI 字体 / UI 基础字号」影响。改为 `typography.uiFont(size:)`
/// 后，尺寸语义仍要可读、可统一调整，于是收成这一组常量。
enum SettingsTextSize {
    static let caption: CGFloat = 11
    static let body: CGFloat = 14
    static let callout: CGFloat = 13
    static let headline: CGFloat = 15
    static let title: CGFloat = 20
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
    /// 当前生效的字体设置（根视图注入）。外观页的「实时预览」用它渲染样张，
    /// 因此预览与真实界面必然同源：同一份环境值、同一套字体构造函数。
    @Environment(\.appTypography) private var typography
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
                    Text(category.title).font(typography.uiFont(size: SettingsTextSize.body))
                    Text(category.subtitle)
                        .font(typography.uiFont(size: SettingsTextSize.caption))
                        .foregroundStyle(.secondary)
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
                Text(selection.title).font(typography.uiFont(size: SettingsTextSize.title, weight: .semibold))
                Text(selection.subtitle)
                    .font(typography.uiFont(size: SettingsTextSize.callout)).foregroundStyle(.secondary)
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
                    .font(typography.uiFont(size: SettingsTextSize.caption)).foregroundStyle(.secondary)
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
            TypographySettingsSection(viewModel: viewModel, typography: typography)
        case .playback:
            if let audioEffectsViewModel { settingsGroup("音效与输出") { AudioEffectsSettingsView(model: audioEffectsViewModel) } } else {
                settingsGroup("音效与输出") { Text("音效设置尚未就绪。").foregroundStyle(.secondary) }
            }
            settingsGroup("在线音质") { audioQualityContent }
            settingsGroup("播放控制") {
                Text("播放 / 暂停、上一首、下一首与进度在窗口底部的播放控制栏。")
                    .foregroundStyle(.secondary)
            }
        case .lyrics:
            settingsGroup("歌词偏好") {
                if lyricsViewModel != nil {
                    Text("字号、字体与外观页共用同一份设置，两处改一处另一处会跟着变；模糊非当前行、翻译与音译立即生效，未播放时也可调整。")
                        .font(typography.uiFont(size: SettingsTextSize.callout)).foregroundStyle(.secondary)
                    Button("打开歌词设置") { activeSheet = .lyrics }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("播放引擎尚未就绪，暂时无法调整歌词偏好。")
                        .font(typography.uiFont(size: SettingsTextSize.callout)).foregroundStyle(.secondary)
                }
            }
        case .network:
            settingsGroup("在线服务") {
                Text("探索页提供网易云音乐、哔哩哔哩和 YouTube Music 的搜索与浏览。")
                    .font(typography.uiFont(size: SettingsTextSize.callout)).foregroundStyle(.secondary)
                if let onNavigate { Button("打开搜索") { onNavigate(.explore) }.buttonStyle(.bordered) }
            }
            settingsGroup("下载") {
                Text("下载进度、暂停 / 续传与清理在「下载」页。")
                    .font(typography.uiFont(size: SettingsTextSize.callout)).foregroundStyle(.secondary)
                if let onNavigate { Button("打开下载") { onNavigate(.downloads) }.buttonStyle(.bordered) }
            }
        case .storage:
            settingsGroup("媒体库目录") { libraryDirectoryContent }
        case .backup:
            if let syncViewModel { settingsGroup("备份与同步") { SyncSettingsSections(viewModel: syncViewModel) } } else {
                Text("同步服务尚未就绪")
                    .font(typography.uiFont(size: SettingsTextSize.callout)).foregroundStyle(.secondary)
            }
        case .listenTogether:
            if let listenTogetherViewModel { settingsGroup("一起听") { ListenTogetherSettingsView(model: listenTogetherViewModel) } } else {
                Text("一起听服务尚未就绪")
                    .font(typography.uiFont(size: SettingsTextSize.callout)).foregroundStyle(.secondary)
            }
        case .about:
            settingsGroup("NeriPlayer") {
                Text("版本 \(AppInfo.versionString)").font(typography.uiFont(size: SettingsTextSize.headline, weight: .semibold))
                Text("原生 macOS 音乐播放器")
                    .font(typography.uiFont(size: SettingsTextSize.callout)).foregroundStyle(.secondary)
                Button("打开诊断信息") { openWindow(id: "diagnostics") }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(typography.uiFont(size: SettingsTextSize.headline, weight: .semibold))
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
    private var neteaseQualityBinding: Binding<NeteaseQuality> {
        Binding(get: { viewModel.neteaseQuality }, set: viewModel.setNeteaseQuality)
    }
    private var youtubeMusicQualityBinding: Binding<YouTubeQuality> {
        Binding(get: { viewModel.youtubeMusicQuality }, set: viewModel.setYouTubeMusicQuality)
    }
    private var bilibiliQualityBinding: Binding<BilibiliQuality> {
        Binding(get: { viewModel.bilibiliQuality }, set: viewModel.setBilibiliQuality)
    }

    /// 「在线音质」分组：三个平台各一个下拉项。
    ///
    /// 为什么与「音效与输出」并列成独立分组：这一组是**在线解析**的偏好（决定请求哪一档、
    /// 挑哪条音轨），而音效组是**本机输出**链路（均衡器、响度、独占）。两者互不影响，
    /// 混在一组里会让「音质没生效」的排查方向变模糊。
    /// 本组不依赖 audioEffectsViewModel，后者缺失时同样渲染。
    private var audioQualityContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 网易云用 menuTitle：无损及以上需要会员，下拉项里直接标出「（需会员）」。
            Picker("网易云", selection: neteaseQualityBinding) {
                ForEach(NeteaseQuality.allCases) { quality in
                    Text(quality.menuTitle).tag(quality)
                }
            }
            Picker("YouTube Music", selection: youtubeMusicQualityBinding) {
                ForEach(YouTubeQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            Picker("Bilibili", selection: bilibiliQualityBinding) {
                ForEach(BilibiliQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            Text("平台未提供所选档位时会自动降级到下一档，不会因此播不出来；"
                 + "标有「需会员」的档位需要对应平台的会员权益。")
                .font(typography.uiFont(size: SettingsTextSize.caption)).foregroundStyle(.secondary)
        }
    }

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
                            Text(directory.path)
                                .font(typography.uiFont(size: SettingsTextSize.caption))
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
                Text(message).font(typography.uiFont(size: SettingsTextSize.callout))
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

// MARK: - 字体设置（需求 5）

/// 外观页的字体分组：UI 字体 / UI 基础字号 / 播放器字号 / 歌词字体 / 歌词字号 / 底部歌词字号，
/// 加一段实时预览与「恢复默认」。
///
/// 为什么单独成一个子视图：它需要 `@Environment(\.appTypography)` 来画预览样张，
/// 而 AppTypography 只在根视图注入一次，这里只是消费者；把六个控件与预览收在一处，
/// 外观分类的其余内容（主题、强调色）就不必跟着这套状态重算。
private struct TypographySettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    /// 根视图注入的当前字体设置，直接用于样张，保证「预览」与真实界面同源。
    let typography: AppTypography

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("字体与字号").font(typography.uiFont(size: SettingsTextSize.headline, weight: .semibold))
                Spacer()
                Button("恢复默认") { viewModel.restoreTypographyDefaults() }
                    .buttonStyle(.borderless)
                    .help("把 UI 字体、字号与歌词字体恢复为系统默认值")
            }
            fontFamilyPicker("UI 字体", selection: viewModel.uiFontFamily, set: viewModel.setUIFontFamily)
            fontSizeSlider("UI 基础字号", value: viewModel.uiBaseFontSize,
                           range: AppTypographyDefaults.uiBaseSizeRange, set: viewModel.setUIBaseFontSize)
            Text("UI 基础字号影响侧栏、列表与按钮等常用界面文字。")
                .font(typography.uiFont(size: SettingsTextSize.caption)).foregroundStyle(.secondary)
            fontSizeSlider("播放器字号", value: viewModel.playerFontSize,
                           range: AppTypographyDefaults.playerTextSizeRange, set: viewModel.setPlayerFontSize)
            fontFamilyPicker("歌词字体", selection: viewModel.lyricsFontFamily, set: viewModel.setLyricsFontFamily)
            fontSizeSlider("歌词字号", value: viewModel.lyricsFontSize,
                           range: AppTypographyDefaults.lyricsBaseSizeRange, set: viewModel.setLyricsFontSize)
            fontSizeSlider("底部歌词字号", value: viewModel.compactLyricsFontSize,
                           range: AppTypographyDefaults.compactLyricsSizeRange, set: viewModel.setCompactLyricsFontSize)
            Text("歌词字号与歌词窗口的滑杆共用同一个设置，两边修改都会同步。")
                .font(typography.uiFont(size: SettingsTextSize.caption)).foregroundStyle(.secondary)
            preview
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func fontFamilyPicker(_ title: String, selection: String, set: @escaping (String) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selection }, set: set)) {
            Text(TypographyFontFamily.systemDisplayName).tag(TypographyFontFamily.systemID)
            ForEach(viewModel.availableFontFamilies, id: \.self) { family in
                Text(family).tag(family)
            }
            // 已存的家族若不在本机列表里（卸载字体 / 备份来自别处），补一个禁用项，
            // Picker 才不会因为找不到当前值而显示空白。
            if selection != TypographyFontFamily.systemID, !viewModel.availableFontFamilies.contains(selection) {
                Text("\(selection)（本机不可用）").tag(selection)
            }
        }
    }

    private func fontSizeSlider(_ title: String, value: Double, range: ClosedRange<Double>,
                                set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).frame(width: 96, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { set($0.rounded()) }), in: range)
            Text("\(Int(value)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
        }
    }

    /// 实时预览：样张用与真实界面相同的 AppTypography 与同一套字体构造函数，
    /// 因此拖动滑杆时预览与主界面同时变化，不存在「预览和实际不一致」。
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("实时预览").font(typography.uiFont(size: SettingsTextSize.caption)).foregroundStyle(.secondary)
            Text("媒体库 · 搜索 · 设置").font(typography.uiFont(size: AppTypography.baseFontSize))
            Text("当前播放：示例歌曲 — 示例歌手").font(typography.playerFont(scaledFromBase: 15))
            HStack {
                Text("底部歌词").font(typography.uiFont(size: SettingsTextSize.caption)).foregroundStyle(.secondary)
                Text("示例歌词行 · 逐字高亮效果")
                    .font(typography.lyricFont(size: typography.compactLyricsSize, weight: .semibold))
            }
            Text("歌词预览行，随歌词字号与字体变化。")
                .font(typography.lyricFont(scaledFromBase: 20))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 账号分类内容。独立成子视图的原因：
///   - SettingsView.onlineViewModel 是普通 var，读取它不会建立订阅，账号异步加载完成后
///     父视图不会重绘；这里用 ObservedObject 订阅，账号 / 登录态变化才能反映到界面。
///   - 账号页只需要账号状态：task 基于当前平台只拉一次账号，不再连带推荐 / 歌单等浏览数据。
private struct AccountSettingsSection: View {
    @ObservedObject var model: OnlineViewModel
    var onManage: () -> Void
    /// 账号段是独立子视图，需要自己取字体环境（设置页其余部分的注入不会自动带进来）。
    @Environment(\.appTypography) private var typography

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
                Text(message).font(typography.uiFont(size: SettingsTextSize.caption)).foregroundStyle(.secondary)
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
