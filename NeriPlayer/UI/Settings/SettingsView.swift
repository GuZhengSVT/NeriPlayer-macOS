// SettingsView.swift
// NeriPlayer macOS —— 设置页 v1（移植规划 M3-T5）。
//
// 三段：外观（主题 + 强调色）、播放行为（启动续播 + 启动音量）、媒体库目录（查看/增删/重扫）。
// 视图本身不含持久化逻辑，全部转发给 SettingsViewModel；颜色与 ColorScheme 的映射放在本文件
// 末尾 —— 那是界面概念，不该下沉到 Core 的设置取值里。
//
// 边界（不做，见任务书）：多语言（设置项文案目前只写中文）；淡入淡出等音效参数属 M8-T4，
// 理由见本文件末尾的 MIGRATION-TODO。

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    var syncViewModel: SyncViewModel?
    var audioEffectsViewModel: AudioEffectsViewModel?
    var listenTogetherViewModel: ListenTogetherViewModel?

    var body: some View {
        Form {
            appearanceSection
            playbackSection
            if let audioEffectsViewModel {
                AudioEffectsSettingsView(model: audioEffectsViewModel)
            }
            libraryDirectorySection
            if let listenTogetherViewModel { ListenTogetherSettingsView(model: listenTogetherViewModel) }
            if let syncViewModel { SyncSettingsSections(viewModel: syncViewModel) }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        // 每次切到设置页都重读一次目录列表：媒体库 tab 的「导入文件夹」也会记录目录，
        // 那条路径不经过本视图模型（理由见 SettingsViewModel.refreshDirectories）。
        .onAppear { viewModel.refreshDirectories() }
        .safeAreaInset(edge: .bottom) {
            statusFooter
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Section {
            Picker("主题", selection: appearanceBinding) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("强调色", selection: accentBinding) {
                ForEach(AccentColorOption.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } header: {
            Text("外观")
        }
    }

    /// 用自定义 Binding 而不是给 @Published 加 setter：视图不直接改 viewModel 的属性，
    /// 每次选择都走一次「持久化 + 归一化」的方法，避免有人绕过写入路径改内存值。
    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(get: { viewModel.appearance }, set: { viewModel.setAppearance($0) })
    }

    private var accentBinding: Binding<AccentColorOption> {
        Binding(get: { viewModel.accent }, set: { viewModel.setAccent($0) })
    }

    // MARK: - 播放行为

    private var playbackSection: some View {
        Section {
            Toggle("启动后继续播放上次的进度", isOn: resumeBinding)

            HStack {
                Text("启动音量")
                Slider(
                    value: volumeBinding,
                    in: PlaybackBehaviorDefaults.volumeRange,
                    step: 1
                )
                Text("\(Int(viewModel.defaultVolume))")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("播放行为")
        } footer: {
            Text("关闭「继续播放」时，启动后仍会恢复队列与进度，但停在暂停态。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var resumeBinding: Binding<Bool> {
        Binding(get: { viewModel.resumePlaybackOnLaunch }, set: { viewModel.setResumePlaybackOnLaunch($0) })
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { viewModel.defaultVolume }, set: { viewModel.setDefaultVolume($0) })
    }

    // MARK: - 媒体库目录

    private var libraryDirectorySection: some View {
        Section {
            if viewModel.directories.isEmpty {
                Text("还没有配置音乐目录。加入后应用会记住它，之后可以在这里重新扫描。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.directories) { directory in
                    directoryRow(directory)
                }
            }

            HStack {
                Button("添加目录…") { chooseDirectory() }
                Spacer()
                Button("重新扫描全部") { viewModel.rescanAll() }
                    .disabled(viewModel.directories.isEmpty)
            }
        } header: {
            Text("媒体库目录")
        } footer: {
            Text("移除目录只会停止扫描它，已经入库的曲目会保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func directoryRow(_ directory: LibraryDirectory) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(directory.displayName)
                Text(directory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                viewModel.removeDirectory(id: directory.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("从媒体库目录中移除")
        }
    }

    /// 用 NSOpenPanel 选目录。与媒体库 tab 的入口保持同一套参数（只能选目录、不能新建）。
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "加入"
        panel.message = "选择要加入媒体库的音乐文件夹"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            viewModel.addDirectory(url)
        }
    }

    // MARK: - 状态条

    @ViewBuilder
    private var statusFooter: some View {
        if let message = viewModel.statusMessage {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text(message).font(.callout)
                Spacer()
                Button("知道了") { viewModel.clearStatusMessage() }
                    .buttonStyle(.borderless)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .bottom])
        }
    }
}

// MARK: - 设置取值 → 界面类型

extension AppearanceMode {

    /// 交给 SwiftUI 的配色方案；跟随系统时为 nil（不覆盖系统选择）。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension AccentColorOption {

    /// 强调色对应的具体颜色。
    var color: Color {
        switch self {
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .orange: return .orange
        case .green: return .green
        // 石墨用中性灰而不是系统强调色：它的用途就是「不抢视线」，
        // 映射到某个彩色上会与选项名不符。
        case .graphite: return Color(white: 0.42)
        }
    }
}

// MIGRATION-TODO(M8-T4): 淡入淡出 / 交叉淡入淡出 / EQ 等音效参数不在这里暴露。
// 原因是它们目前没有可生效的落地链路（音效系统属 M8-T4，方案见 docs/audio-effects-adr.md），
// 此时加一个存了也不生效的开关就是任务书禁止的「半成品实现」。等 M8-T4 把参数接到
// AVAudioEngine / mpv af 链路上，再在本节补这些设置项。
