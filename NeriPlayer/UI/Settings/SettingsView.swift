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
        case .playback: return "音效、输出与播放控制"
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

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    var syncViewModel: SyncViewModel?
    var audioEffectsViewModel: AudioEffectsViewModel?
    var listenTogetherViewModel: ListenTogetherViewModel?
    var onlineViewModel: OnlineViewModel?
    @Environment(\.openWindow) private var openWindow
    @State private var selection: SettingsCategory = .general
    @State private var loginPresented = false

    var body: some View {
        NavigationSplitView {
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
            .navigationTitle("设置")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
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
            .navigationTitle(selection.title)
        }
        .onAppear { viewModel.refreshDirectories() }
        .sheet(isPresented: $loginPresented) {
            if let onlineViewModel { OnlineLoginView(viewModel: onlineViewModel) }
        }
        .safeAreaInset(edge: .bottom) { statusFooter }
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selection {
        case .accounts:
            settingsGroup("在线平台") {
                if let onlineViewModel {
                    HStack {
                        Label(onlineViewModel.account?.name ?? "未登录", systemImage: "person.crop.circle")
                        Spacer()
                        Button(onlineViewModel.account == nil ? "登录" : "管理") { loginPresented = true }
                            .buttonStyle(.borderedProminent)
                    }
                    Picker("平台", selection: Binding(get: { onlineViewModel.source }, set: onlineViewModel.setSource)) {
                        ForEach(MusicSource.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Text("在线服务尚未就绪").foregroundStyle(.secondary)
                }
            }
        case .general:
            settingsGroup("应用行为") {
                Toggle("启动后继续播放上次进度", isOn: resumeBinding)
                HStack {
                    Text("启动音量")
                    Slider(value: volumeBinding, in: PlaybackBehaviorDefaults.volumeRange, step: 1)
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
            if let audioEffectsViewModel { settingsGroup("音效与输出") { AudioEffectsSettingsView(model: audioEffectsViewModel) } }
            settingsGroup("播放提示") {
                Text("播放控制、音质与输出设备设置集中在此。在线音源会在资源失效时自动刷新或切换来源。")
                    .foregroundStyle(.secondary)
            }
        case .lyrics:
            settingsGroup("歌词显示") {
                Text("歌词外观与同步偏好").font(.headline)
                Text("打开歌词窗口后，可在歌词工具栏调整字号、模糊、翻译、音译和单曲偏移。")
                    .foregroundStyle(.secondary)
                Button("打开歌词设置") { }
                    .buttonStyle(.bordered)
            }
        case .network:
            settingsGroup("在线服务") {
                Text("探索页支持网易云音乐、哔哩哔哩和 YouTube Music。")
                Text("下载任务使用独立缓存目录，在线播放的临时地址不会写入播放队列。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .storage:
            settingsGroup("媒体库目录") { libraryDirectoryContent }
        case .backup:
            if let syncViewModel { settingsGroup("备份与同步") { SyncSettingsSections(viewModel: syncViewModel) } }
            else { Text("同步服务尚未就绪").foregroundStyle(.secondary) }
        case .listenTogether:
            if let listenTogetherViewModel { settingsGroup("一起听") { ListenTogetherSettingsView(model: listenTogetherViewModel) } }
            else { Text("一起听服务尚未就绪").foregroundStyle(.secondary) }
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
    private var volumeBinding: Binding<Double> { Binding(get: { viewModel.defaultVolume }, set: viewModel.setDefaultVolume) }
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

extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
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
