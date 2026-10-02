// NowPlayingPage.swift
// NeriPlayer macOS —— 主窗口内容区里的「歌曲播放页」，由底部播放器的封面或歌曲信息打开。
//
// 形态参考网易云桌面端：左侧大封面与歌曲资料，右侧大字号同步歌词，背景柔和、留白舒展。
// 关键约定：
//   * 播放页是主窗口内容区上的一层**覆盖视图**（MainContentView 用 ZStack 叠在原导航页之上，
//     原页面只是被隐藏、并未销毁），因此返回后原页面的选中项与滚动位置都还在，播放也完全连续；
//     底部的常驻播放器栏始终在，所以页内不再重复放一套播放控制（去掉重复的底部控制是需求 4 的明确要求）。
//   * 歌词直接复用 LyricsView 的 embedded 形态：逐行/逐字高亮、翻译音译、滚动跟随、
//     点击歌词 seek、歌词来源设置与导出能力全部沿用，只是去掉 sheet 头部与重复的底部播放控制。
//   * 封面比例与底部栏同一条规则（需求 10）：网易云/本地/YouTube 方形，Bilibili 用横向容器
//     完整显示原图（scaledToFit，不方形裁切）。
//   * 自适应布局：宽度够（≥ 850pt）时左右分栏；窄窗改为上下结构（小封面 + 资料 + 歌词），
//     封面尺寸由可用宽度算出，不会溢出窗口。
//
// 数据订阅模型与底部栏一致：@State 捕获 store 与最近快照，晚启动也能接上。

import SwiftUI

struct NowPlayingPage: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.appTypography) private var typography
    /// 返回原导航页面。
    var onBack: () -> Void

    @State private var playbackStore: PlaybackStateStore?
    @State private var snapshot: PlaybackSnapshot?
    @State private var isQueuePresented = false
    @State private var isCreatingPlaylist = false

    /// 左右分栏的最小宽度。窄于此值改用上下结构（主窗口最小宽度是 720）。
    static let twoColumnThreshold: CGFloat = 850
    /// 左列固定宽度（宽窗）。右列歌词因此拿到窗口剩余的全部宽度，大字号歌词才有舒展的留白。
    static let leftColumnWidth: CGFloat = 460
    /// 左列左右留白。
    static let columnPadding: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            layout(width: proxy.size.width)
        }
        .background(pageBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(appState.$playbackStore) { store in
            playbackStore = store
            snapshot = store?.snapshot
        }
        .task(id: playbackStore.map(ObjectIdentifier.init)) {
            guard let store = playbackStore else { snapshot = nil; return }
            for await value in store.observeState() {
                guard !Task.isCancelled else { return }
                snapshot = value
            }
        }
        .sheet(isPresented: $isCreatingPlaylist) {
            NowPlayingPlaylistSheet { name in createPlaylist(named: name) }
        }
    }

    /// 柔和背景：强调色的极淡渐变，避免大片纯色，也不引入逐帧绘制。
    private var pageBackground: some View {
        LinearGradient(colors: [Color.accentColor.opacity(0.10), Color.clear, Color.accentColor.opacity(0.04)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }

    @ViewBuilder
    private func layout(width: CGFloat) -> some View {
        if width >= Self.twoColumnThreshold {
            HStack(spacing: 0) {
                leftColumn(width: Self.leftColumnWidth)
                    .frame(width: Self.leftColumnWidth)
                Divider()
                lyricsColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                compactHeader(width: width)
                Divider()
                lyricsColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - 宽窗：左列大封面与歌曲资料

    private func leftColumn(width: CGFloat) -> some View {
        let track = snapshot?.currentTrack
        let available = max(120, width - Self.columnPadding * 2)
        let size = coverSize(track: track, availableWidth: available)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                backButton
                PlayerArtwork(content: PlayerArtwork.content(for: track, library: appState.libraryViewModel),
                              shape: PlayerArtwork.shape(for: track),
                              cornerRadius: 12, symbolSize: 44)
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                    .frame(maxWidth: .infinity, alignment: .center)
                titleBlock(titleSize: 24, artistSize: 15)
                metaBlock
                actionRow(compact: false)
                Spacer(minLength: 0)
            }
            .padding(Self.columnPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 播放页封面尺寸：按左列可用宽度等比缩小，窄窗不溢出。
    private func coverSize(track: Track?, availableWidth: CGFloat) -> CGSize {
        let base = PlayerArtwork.pageSize(for: track)
        guard base.width > 0, availableWidth > 0 else { return base }
        let scale = min(1, availableWidth / base.width)
        // 等比缩放：横向（Bilibili）保持 16:9 的完整原图，不被压成方形。
        return CGSize(width: (base.width * scale).rounded(), height: (base.height * scale).rounded())
    }

    // MARK: - 窄窗：上下结构

    private func compactHeader(width: CGFloat) -> some View {
        let track = snapshot?.currentTrack
        let size = compactCoverSize(track: track, availableWidth: max(120, width - 40))
        return VStack(alignment: .leading, spacing: 12) {
            backButton
            HStack(alignment: .top, spacing: 14) {
                PlayerArtwork(content: PlayerArtwork.content(for: track, library: appState.libraryViewModel),
                              shape: PlayerArtwork.shape(for: track),
                              cornerRadius: 10, symbolSize: 26)
                    .frame(width: size.width, height: size.height)
                titleBlock(titleSize: 19, artistSize: 13)
                Spacer(minLength: 0)
            }
            metaBlock
            actionRow(compact: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 窄窗里的小封面：高度固定为一个紧凑值，宽度按平台比例算出（方形 1:1，横向 16:9）。
    private func compactCoverSize(track: Track?, availableWidth: CGFloat) -> CGSize {
        let base = PlayerArtwork.pageSize(for: track)
        guard base.height > 0 else { return CGSize(width: 120, height: 120) }
        let height: CGFloat = 132
        let width = height * (base.width / base.height)
        let scale = min(1, availableWidth / width)
        return CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
    }

    // MARK: - 共用部件

    /// 页内返回入口。播放页是内容区上的一层覆盖视图（这样返回时能原样回到此前的导航页面），
    /// 因此不使用窗口工具栏，返回按钮直接画在页内。
    private var backButton: some View {
        Button { onBack() } label: {
            Label("返回", systemImage: "chevron.left")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("返回上一页（播放继续）")
        .accessibilityLabel("返回")
    }

    private func titleBlock(titleSize: CGFloat, artistSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot?.currentTrack?.title ?? "未播放")
                .font(typography.playerFont(scaledFromBase: titleSize, weight: .bold))
                .lineLimit(2)
            Text(artistText)
                .font(typography.uiFont(size: artistSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let album = albumText {
                Text(album)
                    .font(typography.uiFont(size: artistSize - 2))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 音频规格：只显示内核实际报告过的字段（编码 → 比特率 → 采样率 → 声道，缺值不编造）。
    private var metaBlock: some View {
        Group {
            if let summary = AudioInfoText.summary(snapshot?.audioTrackInfo) {
                Label(summary, systemImage: "waveform")
                    .font(typography.uiFont(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Label("音频信息待加载", systemImage: "waveform")
                    .font(typography.uiFont(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 常用动作：收藏、加入歌单、队列、桌面歌词。窄窗只留图标，避免一行放不下。
    /// 注意这里**没有**播放/暂停/上下首：底部常驻播放器栏一直在，重复一套控制是多余的。
    private func actionRow(compact: Bool) -> some View {
        Group {
            if compact {
                actionRowContent.labelStyle(.iconOnly)
            } else {
                actionRowContent.labelStyle(.titleAndIcon)
            }
        }
        .disabled(snapshot?.currentTrack == nil)
    }

    private var actionRowContent: some View {
        HStack(spacing: 12) {
            favoriteButton
            playlistMenu
            Button { isQueuePresented.toggle() } label: {
                Label("队列", systemImage: "music.note.list")
            }
            .help("播放队列")
            .popover(isPresented: $isQueuePresented, arrowEdge: .bottom) {
                PlaybackQueuePopover(
                    queue: snapshot?.queue ?? .empty,
                    onJump: { index in playbackStore?.jump(toQueueIndex: index) },
                    onRemove: { index in playbackStore?.removeFromQueue(at: index) }
                )
            }
            Button { appState.toggleFloatingLyrics() } label: {
                Label("桌面歌词", systemImage: "text.bubble")
            }
            .disabled(appState.lyricsViewModel == nil)
            .help("桌面悬浮歌词")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private var favoriteButton: some View {
        Button { toggleFavorite() } label: {
            Label(isFavorited ? "已收藏" : "收藏", systemImage: isFavorited ? "star.fill" : "star")
                .foregroundStyle(isFavorited ? Color.yellow : Color.primary)
        }
        .disabled(target == nil)
        .help(isFavorited ? "取消收藏" : "添加到收藏")
    }

    private var playlistMenu: some View {
        Menu {
            if let library = appState.libraryViewModel, !library.playlists.isEmpty {
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) { addToPlaylist(playlist) }
                }
                Divider()
            }
            Button("新建歌单…") { isCreatingPlaylist = true }
        } label: {
            Label("加入歌单", systemImage: "text.badge.plus")
        }
        .disabled(target == nil)
        .help("加入歌单")
    }

    // MARK: - 右列：歌词

    @ViewBuilder
    private var lyricsColumn: some View {
        if let model = appState.lyricsViewModel {
            // embedded：复用逐行/逐字高亮、翻译音译、滚动跟随、点击 seek、来源设置与导出，
            // 但不渲染 sheet 头部与底部播放控制（播放控制由常驻播放器栏承担）。
            LyricsView(model: model, embedded: true)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "text.alignleft").font(.system(size: 32)).foregroundStyle(.secondary)
                Text("歌词功能尚未就绪").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 文本与库动作

    private var artistText: String {
        guard let artist = snapshot?.currentTrack?.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
              !artist.isEmpty else { return "未知歌手" }
        return artist
    }

    private var albumText: String? {
        guard let album = snapshot?.currentTrack?.onlineSong?.album.trimmingCharacters(in: .whitespacesAndNewlines),
              !album.isEmpty else { return nil }
        return album
    }

    /// 当前曲目在库侧的落点（决定收藏状态与动作路径），与底部栏用同一套判定。
    private var target: CurrentTrackLibraryTarget? {
        CurrentTrackLibraryActions.target(for: snapshot?.currentTrack,
                                          libraryTracks: appState.libraryViewModel?.tracks ?? [])
    }

    private var isFavorited: Bool {
        CurrentTrackLibraryActions.isFavorited(snapshot?.currentTrack,
                                                libraryTracks: appState.libraryViewModel?.tracks ?? [],
                                                favoriteIds: appState.libraryViewModel?.favoriteTrackIds ?? [])
    }

    private func toggleFavorite() {
        guard let library = appState.libraryViewModel else { return }
        switch target {
        case .library(let item): library.toggleFavorite(item)
        case .online(let song): appState.syncViewModel?.addToLibrary(song, favorite: true)
        case nil: break
        }
    }

    private func addToPlaylist(_ playlist: PlaylistInfo) {
        guard let library = appState.libraryViewModel else { return }
        switch target {
        case .library(let item): library.add(item, to: playlist)
        case .online(let song): appState.syncViewModel?.addToLibrary(song, playlistID: playlist.id, favorite: false)
        case nil: break
        }
    }

    /// 新建歌单并把当前曲加入。在线曲先建单拿到实际 id 再入库入单（不能用名字回查）。
    private func createPlaylist(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let library = appState.libraryViewModel else { return }
        switch target {
        case .library(let item):
            library.createPlaylist(named: trimmed, adding: item)
        case .online(let song):
            if let created = library.createPlaylist(named: trimmed, adding: nil) {
                appState.syncViewModel?.addToLibrary(song, playlistID: created.id, favorite: false)
            }
        case nil:
            library.createPlaylist(named: trimmed, adding: nil)
        }
    }
}

// MARK: - 新建歌单命名 sheet

private struct NowPlayingPlaylistSheet: View {
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建歌单").font(.headline)
            TextField("歌单名", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("新建", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func confirm() {
        guard !trimmedName.isEmpty else { return }
        onConfirm(trimmedName)
        dismiss()
    }
}
