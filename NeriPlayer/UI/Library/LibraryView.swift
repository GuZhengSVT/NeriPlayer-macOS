// LibraryView.swift
// NeriPlayer macOS —— 媒体库 tab 的界面（移植规划 M2-T5、M2-T6）。
//
// 结构：顶部三段控件（歌曲 / 歌手 / 专辑）+ 导入按钮；下方是搜索栏 + 列表区；底部状态条。
//   - 歌曲：封面缩略图 + 标题 + 歌手 + 时长 + 格式角标，双击即播；
//   - 歌手：按归一化歌手聚合，点进详情看该歌手全部曲目；
//   - 专辑：按 (歌手, 专辑) 聚合，点进详情看整张专辑。
// 所有列表共用同一套行视图与右键菜单（播放 / 下一首播放 / 加入歌单），避免三处各写一份。
//
// 搜索（M2-T6）：搜索栏放在列表区顶部（歌曲段就在其后），查询态由 LibraryViewModel 持有，
// 三个维度共用同一批命中曲目 —— 切到歌手/专辑维度看到的是过滤后的聚合，不是全库聚合。
// 视图本身不再自己过滤（M2-T5 时是本地 filter），因为拼音索引必须由拥有曲目集的视图模型
// 在曲目变化时作废重建，放在视图里没法正确失效。
//
// 数据流：列表内容全部来自注入的 LibraryViewModel（它读 M2-T3/M2-T4 的库），
// 播放入口来自环境的 AppState.playbackStore（M1-T5 的「入队即播」）。二者互不知道对方，
// 视图是唯一的交汇点——播放链路不必认识库模型，库也不依赖播放实现。
//
// 封面读取策略：coverPath 是 M2-T4 同步时落盘的 PNG 路径，直接 NSImage(contentsOfFile:) 读。
// 系统对该构造有缓存，列表滚动不会反复解码原图；无封面时回落到 SF Symbol 占位。
//
// 边界（不做）：歌单详情页、播放队列的编辑 UI、滚动的性能专项优化（验收要求 1000+ 曲目 60fps，
// 用 Instruments 验证；本任务只保证行视图轻量、无每帧计算）。
//
// M2-T8：播放入口打通。歌手/专辑详情头部补「随机播放」（整组入队 + 随机起点，见
// PlaybackEntry），底部补 PlaybackStatusBar（订阅 PlaybackStateStore 快照显示当前曲）。

import AppKit
import SwiftUI

// MARK: - 分段

/// 媒体库的三个浏览维度。
enum LibrarySection: String, CaseIterable, Identifiable {
    case songs
    case artists
    case albums

    var id: String { rawValue }

    var title: String {
        switch self {
        case .songs: return "歌曲"
        case .artists: return "歌手"
        case .albums: return "专辑"
        }
    }
}

// MARK: - 主视图

/// 媒体库 tab 内容视图。
struct LibraryView: View {

    /// 视图模型由上层（MainContentView）持有，这里只观察。
    @ObservedObject var viewModel: LibraryViewModel
    @EnvironmentObject private var appState: AppState

    @State private var section: LibrarySection = .songs
    /// 右键「新建歌单…」时待加入的曲目；非 nil 即弹出命名面板。
    @State private var pendingNewPlaylistTrack: LibraryTrack?
    /// 歌单管理面板是否打开。
    @State private var isShowingPlaylists = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            content
            Divider()
            LibraryStatusBar(viewModel: viewModel, section: section)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("媒体库")
        .task {
            // 首次进入时读库；重复进入不重读（refresh 会由导入动作显式触发）。
            if !viewModel.hasLoaded { viewModel.load() }
        }
        .onChange(of: section) { _ in
            // 切换维度时退出详情页，避免「歌手详情」残留在专辑维度下。
            viewModel.selectedArtist = nil
            viewModel.selectedAlbum = nil
        }
        .alert("媒体库", isPresented: errorPresented) {
            Button("好", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(item: $pendingNewPlaylistTrack) { track in
            NewPlaylistSheet(track: track, viewModel: viewModel)
        }
        .sheet(isPresented: $isShowingPlaylists) {
            PlaylistListView(viewModel: viewModel)
        }
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(spacing: 12) {
            Picker("浏览维度", selection: $section) {
                ForEach(LibrarySection.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)

            Spacer(minLength: 8)

            Toggle(isOn: $viewModel.onlyFavorites) {
                Label("只看收藏", systemImage: "star")
            }
            .toggleStyle(.button)
            .help("当前列表只显示已收藏的曲目")

            Button {
                isShowingPlaylists = true
            } label: {
                Label("歌单", systemImage: "music.note.list")
            }
            .help("管理歌单：新建、重命名、删除、排序")

            Button {
                viewModel.addDirectoryAndSync()
            } label: {
                Label("导入文件夹", systemImage: "folder.badge.plus")
            }
            .disabled(viewModel.isSyncing)
            .help("扫描一个文件夹并把其中的音乐加入媒体库")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 搜索栏：位于列表区顶部，三个维度共用。
    /// 输入即写入 viewModel.searchQuery（视图模型负责 200ms 防抖 + 后台建拼音索引），
    /// 命中的曲目与聚合都从视图模型读，视图在这里不持有任何过滤状态。
    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索标题、歌手、专辑，或拼音首字母（如 zl）", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                if viewModel.isSearchSettling {
                    ProgressView().controlSize(.small)
                }
                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
            .overlay(Capsule().stroke(Color(nsColor: .separatorColor)))
            .frame(maxWidth: 460)

            if viewModel.isSearching {
                Text("\(viewModel.searchResults.count) 首匹配")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: 内容区

    @ViewBuilder
    private var content: some View {
        if !viewModel.hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.isEmpty {
            emptyLibrary
        } else if viewModel.isFavoritesFilterEmpty {
            // 「只看收藏」开着但一首都没收藏：给专门的提示，而不是让用户以为曲目被删了。
            noFavorites
        } else if viewModel.isSearching && viewModel.searchResults.isEmpty {
            noSearchResults
        } else {
            switch section {
            case .songs: trackList(viewModel.searchResults)
            case .artists: artistsArea
            case .albums: albumsArea
            }
        }
    }

    private func trackList(_ tracks: [LibraryTrack]) -> some View {
        LibraryTrackList(tracks: tracks, viewModel: viewModel, onNewPlaylist: requestNewPlaylist)
    }

    /// 歌手维度：未选歌手时是聚合列表，选中后是该歌手详情。
    @ViewBuilder
    private var artistsArea: some View {
        if let selected = viewModel.selectedArtist {
            ArtistDetailView(group: selected, viewModel: viewModel, onNewPlaylist: requestNewPlaylist)
        } else {
            List(artistGroups) { group in
                Button {
                    viewModel.selectedArtist = group
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "music.mic")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 36)
                        Text(group.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(group.count) 首")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 专辑维度：未选专辑时是聚合列表，选中后是整张专辑。
    @ViewBuilder
    private var albumsArea: some View {
        if let selected = viewModel.selectedAlbum {
            AlbumDetailView(group: selected, viewModel: viewModel, onNewPlaylist: requestNewPlaylist)
        } else {
            List(albumGroups) { group in
                Button {
                    viewModel.selectedAlbum = group
                } label: {
                    HStack(spacing: 12) {
                        CoverThumbnail(path: group.coverPath, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.album).lineLimit(1)
                            Text(group.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text("\(group.count) 首")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 首次启动引导：库为空时的落点。
    private var emptyLibrary: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("媒体库还是空的")
                .font(.title3)
            Text("选择你存放音乐的文件夹，NeriPlayer 会扫描并建立索引。")
                .font(.callout)
                .foregroundStyle(.secondary)
            importButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var importButton: some View {
        Button {
            viewModel.addDirectoryAndSync()
        } label: {
            if viewModel.isSyncing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描…")
                }
            } else {
                Label("选择音乐文件夹", systemImage: "folder.badge.plus")
            }
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(viewModel.isSyncing)
    }

    private var noSearchResults: some View {
        VStack(spacing: 8) {
            Text("没有匹配「\(viewModel.searchQuery)」的内容")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("清除搜索") { viewModel.searchQuery = "" }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 「只看收藏」下的空态：提示去收藏，并给一键关闭开关的出口。
    private var noFavorites: some View {
        VStack(spacing: 10) {
            Image(systemName: "star")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("还没有收藏的曲目")
                .font(.title3)
            Text("在歌曲行上点星标，或右键选「添加到收藏」。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("显示全部曲目") { viewModel.onlyFavorites = false }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 数据

    /// 歌手聚合：搜索态用视图模型的过滤聚合，否则用全量聚合。
    private var artistGroups: [ArtistGroup] {
        viewModel.isSearching ? viewModel.searchArtistGroups : viewModel.artistGroups
    }

    /// 专辑聚合，规则同上。
    private var albumGroups: [AlbumGroup] {
        viewModel.isSearching ? viewModel.searchAlbumGroups : viewModel.albumGroups
    }

    /// 错误提示的展示绑定：非 nil 即弹窗，关闭时清空。
    private var errorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private func requestNewPlaylist(_ track: LibraryTrack) {
        pendingNewPlaylistTrack = track
    }
}

// MARK: - 曲目列表（歌曲 / 歌手详情 / 专辑详情共用）

/// 可复用的曲目列表：封面 + 标题 + 歌手（+ 专辑）+ 时长，双击播放，右键菜单。
struct LibraryTrackList: View {

    let tracks: [LibraryTrack]
    let viewModel: LibraryViewModel
    /// 右键「新建歌单…」的回调，由上层弹命名面板。
    let onNewPlaylist: (LibraryTrack) -> Void
    /// 副标题是否显示专辑（专辑详情页内显示专辑名是冗余的）。
    var showsAlbum: Bool = true

    @EnvironmentObject private var appState: AppState
    @State private var selectedTrackID: UUID?

    var body: some View {
        List(selection: $selectedTrackID) {
            ForEach(tracks) { track in
                LibraryTrackRow(
                    track: track,
                    showsAlbum: showsAlbum,
                    isFavorited: viewModel.isFavorited(track),
                    onToggleFavorite: { viewModel.toggleFavorite(track) }
                )
                    .tag(Optional(track.id))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { play(track) }
                    .contextMenu { contextMenu(for: track) }
            }
        }
    }

    /// 右键菜单：播放 / 下一首播放 / 收藏 / 加入歌单。
    @ViewBuilder
    private func contextMenu(for track: LibraryTrack) -> some View {
        Button("播放") { play(track) }
            .disabled(appState.playbackStore == nil)
        Button("下一首播放") { enqueueNext(track) }
            .disabled(appState.playbackStore == nil)
        Divider()
        // 文案随状态切换：一个开关式的菜单项，比「添加到收藏/取消收藏」两个并列项少一次误点。
        Button(viewModel.isFavorited(track) ? "取消收藏" : "添加到收藏") {
            viewModel.toggleFavorite(track)
        }
        Divider()
        Menu("加入歌单") {
            ForEach(viewModel.playlists) { playlist in
                Button(playlist.name) { viewModel.add(track, to: playlist) }
            }
            if !viewModel.playlists.isEmpty { Divider() }
            Button("新建歌单…") { onNewPlaylist(track) }
        }
    }

    private func play(_ track: LibraryTrack) {
        selectedTrackID = track.id
        appState.playbackStore?.playTrack(track.track)
    }

    private func enqueueNext(_ track: LibraryTrack) {
        appState.playbackStore?.enqueueNext(track.track)
    }
}

// MARK: - 曲目行

/// 单行曲目：封面缩略图 + 标题 + 歌手/专辑 + 格式角标 + 时长。
struct LibraryTrackRow: View {

    let track: LibraryTrack
    var showsAlbum: Bool = true
    /// 是否已收藏；由调用方从视图模型的收藏集合读出（行本身不查库）。
    var isFavorited: Bool = false
    /// 点星标的回调；nil 表示这一处不需要收藏交互（例如歌单详情里的行由上层另给）。
    var onToggleFavorite: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            CoverThumbnail(path: track.coverPath, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            favoriteStar
            if let format = track.format, !format.isEmpty {
                Text(format.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            Text(LibraryTrackRow.durationText(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    /// 收藏星标。已收藏为实心黄星，未收藏为空心灰星（悬停提示说明动作）。
    /// 没有回调时不渲染（保持纯展示行）。
    @ViewBuilder
    private var favoriteStar: some View {
        if let onToggleFavorite {
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorited ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(isFavorited ? Color.yellow : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(isFavorited ? "取消收藏" : "添加到收藏")
        }
    }

    private var subtitle: String {
        let artist = track.artist.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? LibraryGrouping.unknownArtist
        guard showsAlbum else { return artist }
        let album = track.album.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let album else { return artist }
        return artist + " · " + album
    }

    /// 时长文本；未知或非有限值时显示 --:--（不显示 0:00，避免与真实零秒混淆）。
    static func durationText(_ duration: Double?) -> String {
        guard let duration, duration.isFinite, duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 封面

/// 封面缩略图：有落盘文件则读图，否则显示音符占位。
struct CoverThumbnail: View {

    let path: String?
    let size: CGFloat
    var cornerRadius: CGFloat = 4

    var body: some View {
        Group {
            if let image = Self.loadImage(path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }

    /// 读封面文件。路径为空或文件不可解码时返回 nil，由调用方回落占位图。
    private static func loadImage(_ path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        return NSImage(contentsOfFile: path)
    }
}

// MARK: - 歌手详情

/// 歌手详情：该歌手全部曲目，复用曲目行视图；可整组入队播放。
struct ArtistDetailView: View {

    let group: ArtistGroup
    let viewModel: LibraryViewModel
    let onNewPlaylist: (LibraryTrack) -> Void
    /// 随机播放的取数过程是否可复现（默认真随机；测试时打开）。
    var isShuffleSeedFixed = false

    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            LibraryDetailHeader(
                iconSystemName: "music.mic",
                title: group.name,
                subtitle: "\(tracks.count) 首",
                backHelp: "返回歌手列表",
                onBack: { viewModel.selectedArtist = nil },
                onPlayAll: { playAll() },
                onShuffle: { shuffleAll() },
                isPlayEnabled: appState.playbackStore != nil && !tracks.isEmpty
            )
            Divider()
            LibraryTrackList(
                tracks: tracks,
                viewModel: viewModel,
                onNewPlaylist: onNewPlaylist
            )
        }
    }

    private var tracks: [LibraryTrack] { viewModel.tracks(for: group) }

    private func playAll() {
        appState.playbackStore?.setQueue(tracks.map(\.track), startIndex: 0)
    }

    /// 随机播放：整组先全量入队，再从队列里挑一个随机起点跳过去。
    /// 取舍说明见 PlaybackEntry 头注释（不切换 queue.mode）。
    private func shuffleAll() {
        guard let store = appState.playbackStore else { return }
        PlaybackEntry.shuffle(tracks.map(\.track), store: store, isSeedFixed: isShuffleSeedFixed)
    }
}

// MARK: - 专辑详情

/// 专辑详情：整张专辑的曲目，复用曲目行视图；副标题不再重复显示专辑名。
struct AlbumDetailView: View {

    let group: AlbumGroup
    let viewModel: LibraryViewModel
    let onNewPlaylist: (LibraryTrack) -> Void
    /// 随机播放的取数过程是否可复现（默认真随机；测试时打开）。
    var isShuffleSeedFixed = false

    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            LibraryDetailHeader(
                iconSystemName: nil,
                iconCoverPath: group.coverPath,
                title: group.album,
                subtitle: "\(group.artist) · \(tracks.count) 首",
                backHelp: "返回专辑列表",
                onBack: { viewModel.selectedAlbum = nil },
                onPlayAll: { playAll() },
                onShuffle: { shuffleAll() },
                isPlayEnabled: appState.playbackStore != nil && !tracks.isEmpty
            )
            Divider()
            LibraryTrackList(
                tracks: tracks,
                viewModel: viewModel,
                onNewPlaylist: onNewPlaylist,
                showsAlbum: false
            )
        }
    }

    private var tracks: [LibraryTrack] { viewModel.tracks(for: group) }

    private func playAll() {
        appState.playbackStore?.setQueue(tracks.map(\.track), startIndex: 0)
    }

    /// 随机播放：与歌手详情同一条路径，起点从该专辑曲目里随机取。
    private func shuffleAll() {
        guard let store = appState.playbackStore else { return }
        PlaybackEntry.shuffle(tracks.map(\.track), store: store, isSeedFixed: isShuffleSeedFixed)
    }
}

// MARK: - 详情页头

/// 歌手/专辑详情共用的头部：返回按钮 + 图标或封面 + 标题 + 副标题 + 「播放全部 / 随机播放」。
struct LibraryDetailHeader: View {

    let iconSystemName: String?
    var iconCoverPath: String?
    let title: String
    let subtitle: String
    let backHelp: String
    let onBack: () -> Void
    let onPlayAll: () -> Void
    let onShuffle: () -> Void
    /// 整组为空或播放集成未就绪时为 false：两个按钮一起禁用（空库/空歌单防呆）。
    let isPlayEnabled: Bool

    init(
        iconSystemName: String?,
        iconCoverPath: String? = nil,
        title: String,
        subtitle: String,
        backHelp: String,
        onBack: @escaping () -> Void,
        onPlayAll: @escaping () -> Void,
        onShuffle: @escaping () -> Void,
        isPlayEnabled: Bool
    ) {
        self.iconSystemName = iconSystemName
        self.iconCoverPath = iconCoverPath
        self.title = title
        self.subtitle = subtitle
        self.backHelp = backHelp
        self.onBack = onBack
        self.onPlayAll = onPlayAll
        self.onShuffle = onShuffle
        self.isPlayEnabled = isPlayEnabled
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Label("返回", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .help(backHelp)

            if let iconCoverPath {
                CoverThumbnail(path: iconCoverPath, size: 48, cornerRadius: 6)
            } else if let iconSystemName {
                Image(systemName: iconSystemName)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 48)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // 两个按钮共用一次可用性判定：组里没有曲目（或播放集成未就绪）时都禁用。
            Button(action: onPlayAll) {
                Label("播放全部", systemImage: "play.fill")
            }
            .disabled(!isPlayEnabled)

            Button(action: onShuffle) {
                Label("随机播放", systemImage: "shuffle")
            }
            .disabled(!isPlayEnabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - 新建歌单

/// 新建歌单的小面板：输入名字，确认后建单并把这唯一一首歌加进去。
struct NewPlaylistSheet: View {

    let track: LibraryTrack
    @ObservedObject var viewModel: LibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建歌单")
                .font(.headline)
            Text("将「\(track.title)」加入新歌单")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("歌单名称", text: $name)
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

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func confirm() {
        guard !trimmedName.isEmpty else { return }
        viewModel.createPlaylist(named: trimmedName, adding: track)
        dismiss()
    }
}
