// HomeView.swift
// 桌面首页：继续播放 + 本地媒体库汇总 + 网易云真实分区（推荐歌单 / 榜单 / 私人雷达 /
// 私人 FM）+ YouTube Music 首页栏。
//
// 每个在线分区独立渲染加载、错误与空态：一个分区失败不会隐藏其余分区。
// 点击歌曲直接播放；点击在线歌单通过 onOpenCollection 交还导航（主智能体决定落到
// 探索详情或媒体库），首页自身不持有跳转逻辑。
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var onlineViewModel: OnlineViewModel
    @ObservedObject var homeViewModel: HomeViewModel
    var libraryViewModel: LibraryViewModel?
    var onExplore: () -> Void
    var onLibrary: () -> Void
    var onDownloads: () -> Void
    /// 点击在线歌单/合集时回调。默认空实现，由主智能体接到媒体库或探索详情。
    var onOpenCollection: (OnlineCollection) -> Void = { _ in }

    @State private var snapshot: PlaybackSnapshot?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                welcomeHeader
                continueSection
                neteaseSections
                youtubeSection
                libraryOverview
            }
            .padding(24)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("首页")
        .task {
            homeViewModel.load()
            if let libraryViewModel, !libraryViewModel.hasLoaded { libraryViewModel.load() }
        }
        .task(id: appState.playbackStore.map(ObjectIdentifier.init)) {
            guard let store = appState.playbackStore else { snapshot = nil; return }
            for await value in store.observeState() {
                guard !Task.isCancelled else { return }
                snapshot = value
            }
        }
    }

    // MARK: - 顶部

    private var welcomeHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("发现音乐").font(.title.weight(.bold))
            HStack(spacing: 8) {
                Text("网易云推荐与 YouTube Music").foregroundStyle(.secondary)
                if !homeViewModel.hasLogin {
                    Text("网易云未登录").font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            HomeAction(title: "搜索音乐", subtitle: "网易云 · Bilibili · YouTube", systemImage: "magnifyingglass") { onExplore() }
            HomeAction(title: "打开媒体库", subtitle: "本地曲目与歌单", systemImage: "music.note.list") { onLibrary() }
            HomeAction(title: "查看下载", subtitle: "离线音频与任务", systemImage: "arrow.down.circle") { onDownloads() }
        }
    }

    @ViewBuilder
    private var continueSection: some View {
        if let track = snapshot?.currentTrack {
            HomeSection(title: "继续播放", systemImage: "play.circle.fill") {
                HStack(spacing: 16) {
                    HomeTrackArtwork(track: track).frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title).font(.title3.weight(.semibold)).lineLimit(1)
                        Text(track.artist ?? "未知歌手").foregroundStyle(.secondary).lineLimit(1)
                        Text(snapshot?.isPaused == true ? "已暂停" : (snapshot?.isCoreIdle == true ? "已停止" : "正在播放"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let store = appState.playbackStore {
                        Button { store.togglePlayPause() } label: {
                            Image(systemName: snapshot?.isPaused == false && snapshot?.isCoreIdle == false ? "pause.fill" : "play.fill")
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.borderedProminent)
                        .help("播放或暂停")
                    }
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - 网易云分区

    private var neteaseSections: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Label("网易云推荐", systemImage: "sparkles").font(.headline)
                if let date = homeViewModel.lastUpdatedAt {
                    Text(date, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if homeViewModel.isRefreshing { ProgressView().controlSize(.small) }
                Button { homeViewModel.reloadNetease() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新网易云推荐").disabled(homeViewModel.isRefreshing)
            }

            ForEach(homeViewModel.snapshot.radarSongSections) { entry in
                HomeSongSectionView(
                    source: entry.source.title,
                    section: entry.section,
                    onRetry: { homeViewModel.reloadNetease() },
                    onPlay: { play($0, songs: entry.section.items) }
                )
            }
            HomeCollectionSectionView(
                title: "私人雷达歌单",
                systemImage: "dot.radiowaves.left.and.right",
                section: homeViewModel.snapshot.radarPlaylists,
                onRetry: { homeViewModel.reloadNetease() },
                onOpen: onOpenCollection
            )
            ForEach(homeViewModel.snapshot.trendingSongSections) { entry in
                HomeSongSectionView(
                    source: entry.source.title,
                    section: entry.section,
                    onRetry: { homeViewModel.reloadNetease() },
                    onPlay: { play($0, songs: entry.section.items) }
                )
            }
            ForEach(homeViewModel.snapshot.playlistSections) { entry in
                HomeCollectionSectionView(
                    title: entry.source.title,
                    systemImage: "music.note.list",
                    section: entry.section,
                    onRetry: { homeViewModel.reloadNetease() },
                    onOpen: onOpenCollection
                )
            }
        }
    }

    // MARK: - YouTube Music

    @ViewBuilder
    private var youtubeSection: some View {
        let section = homeViewModel.snapshot.youtubeShelves
        if section.isLoading || !section.items.isEmpty || section.error != nil {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Label("YouTube Music", systemImage: "play.rectangle").font(.headline)
                    Spacer()
                    Button { homeViewModel.loadYouTubeMusic(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .help("刷新 YouTube Music 首页").disabled(section.isLoading)
                }
                if section.isLoading && section.items.isEmpty {
                    HomeLoadingRow(text: "正在加载 YouTube Music…")
                } else if let error = section.error, section.items.isEmpty {
                    HomeErrorRow(message: error) { homeViewModel.loadYouTubeMusic(force: true) }
                } else if section.items.isEmpty {
                    Text("YouTube Music 未返回推荐内容。").font(.caption).foregroundStyle(.secondary)
                } else {
                    if let error = section.error { HomeInlineWarning(text: error) }
                    // 按索引渲染：不同栏可能重名，标题不足以做稳定身份。
                    ForEach(Array(section.items.enumerated()), id: \.offset) { entry in
                        HomeYouTubeShelfView(shelf: entry.element) { item in
                            if let collection = item.asCollection { onOpenCollection(collection) } else if let song = item.song { onlineViewModel.play(song) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 媒体库

    private func play(_ song: SongData, songs: [SongData]) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        appState.playbackStore?.setQueue(songs.map { $0.track() }, startIndex: index)
    }

    @ViewBuilder
    private var libraryOverview: some View {
        if let libraryViewModel {
            HomeLibraryOverview(viewModel: libraryViewModel, onRetry: libraryViewModel.load, onOpen: onLibrary)
        } else {
            HomeSection(title: "媒体库", systemImage: "music.note.list") {
                Text("媒体库尚未就绪。在线推荐仍可使用。").font(.caption).foregroundStyle(.secondary)
                Button("重试媒体库") { appState.startLibrary() }
            }
        }
    }
}

// MARK: - 分区视图

/// 一组歌曲分区：标题 + 横向卡片。加载 / 错误 / 空态互斥，错误不隐藏已有内容。
private struct HomeSongSectionView: View {
    let source: String
    let section: HomeSectionState<SongData>
    let onRetry: () -> Void
    let onPlay: (SongData) -> Void

    /// 当前悬停的卡片 id。只用于加深底色，不参与任何尺寸计算 —— 需求 7 明确
    /// 「悬停反馈不得改变卡片尺寸」，否则横向列表会随鼠标轻微抖动。
    @State private var hoveredSongID: String?

    /// 行高：52pt 封面 + 卡片上下各 6pt 内边距 = 64pt。固定高度是需求 7「悬停不得改变
    /// 卡片尺寸」的前提 —— 高度由 GridItem 给定，卡片只填满它，鼠标掠过不会撑高任何一行。
    private static let rowHeight: CGFloat = 64
    private static let cardVerticalPadding: CGFloat = 6

    var body: some View {
        HomeSection(title: source, systemImage: "music.note") {
            if section.isLoading && section.items.isEmpty {
                HomeLoadingRow(text: "正在加载 \(source)…")
            } else if let error = section.error, section.items.isEmpty {
                HomeErrorRow(message: error, retry: onRetry)
            } else if section.items.isEmpty {
                Text("暂无内容。").font(.caption).foregroundStyle(.secondary)
            } else {
                if let error = section.error { HomeInlineWarning(text: error) }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(Self.rowHeight), spacing: 8), count: 3), spacing: 14) {
                        ForEach(section.items) { song in
                            songCard(song)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// 单首歌曲卡片。
    ///
    /// 底色与内边距是本轮需求 7 的核心：原先相邻歌曲之间没有任何视觉边界，一行末尾的
    /// 播放三角很容易被读成「播下一首」。加一层低透明度圆角底并留出内边距后，卡片边界一眼可见，
    /// 但底色刻意做得很淡（0.06/0.11）以免盖过封面。
    ///
    /// 悬停只改 `fill`，`frame` 与 `padding` 恒定；着色用 `background(_:in:)` 的现成形状，
    /// 因此不会触发布局重算，鼠标掠过时卡片既不移动也不变宽。
    private func songCard(_ song: SongData) -> some View {
        let isHovered = hoveredSongID == song.id
        return Button { onPlay(song) } label: {
            HStack(spacing: 10) {
                // 网易云的推荐/榜单曲目保持方形；若某首来自 Bilibili，则按 16:9 横向完整显示原图。
                OnlineArtworkThumbnail(url: song.artworkURL, platform: song.source, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill").font(.caption).foregroundStyle(.secondary)
            }
            // 宽度固定为 300：卡片内边距不能靠挤压内容来换取，否则标题的可见字数会随悬停变化。
            .frame(width: Self.cardWidth, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, Self.cardVerticalPadding)
            .background(cardBackground(isHovered: isHovered), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("播放「\(song.title)」")
        .onHover { inside in
            if inside { hoveredSongID = song.id } else if hoveredSongID == song.id { hoveredSongID = nil }
        }
    }

    /// 卡片内容宽度。300 是旧版卡片的外框宽度，本轮把「内边距」加在外框之外，
    /// 因此卡片内部可见内容的宽度与位置一字未变，只是外面多了一圈底色与留白。
    private static let cardWidth: CGFloat = 300

    /// 卡片底色：悬停时在同一色相上加深。两档都保持在低透明度，浅色与深色外观下都能看出
    /// 边界；与同一分区的 loading/error 占位（同样是「系统语义色 + 低透明度圆角块」）风格一致，
    /// 切换明暗外观时两边一起变，不会出现某一档失配。
    private func cardBackground(isHovered: Bool) -> Color {
        Color.secondary.opacity(isHovered ? 0.11 : 0.06)
    }
}

/// 一组歌单分区：网格卡片。点击通过 onOpen 交回导航。
private struct HomeCollectionSectionView: View {
    @ObservedObject private var favorites = CollectionFavoritesStore.shared
    let title: String
    let systemImage: String
    let section: HomeSectionState<OnlineCollection>
    let onRetry: () -> Void
    let onOpen: (OnlineCollection) -> Void

    var body: some View {
        HomeSection(title: title, systemImage: systemImage) {
            if section.isLoading && section.items.isEmpty {
                HomeLoadingRow(text: "正在加载 \(title)…")
            } else if let error = section.error, section.items.isEmpty {
                HomeErrorRow(message: error, retry: onRetry)
            } else if section.items.isEmpty {
                Text("暂无内容。").font(.caption).foregroundStyle(.secondary)
            } else {
                if let error = section.error { HomeInlineWarning(text: error) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14)],
                          alignment: .leading, spacing: 14) {
                    ForEach(section.items) { collection in
                        Button { onOpen(collection) } label: { HomeCollectionCard(collection: collection) }
                            .buttonStyle(.plain)
                            .help("打开「\(collection.title)」")
                            .contextMenu {
                                Button(favorites.contains(collection) ? "取消收藏歌单" : "收藏歌单") { favorites.toggle(collection) }
                            }
                    }
                }
            }
        }
    }
}

private struct HomeYouTubeShelfView: View {
    let shelf: YouTubeMusicHomeShelf
    let onSelect: (YouTubeMusicHomeItem) -> Void

    var body: some View {
        HomeSection(title: shelf.title, systemImage: "play.rectangle") {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(shelf.items) { item in
                        Button { onSelect(item) } label: { HomeYouTubeCard(item: item) }
                            .buttonStyle(.plain)
                            .help("打开「\(item.title)」")
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - 卡片

private struct HomeSongCard: View {
    let song: SongData

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            OnlineArtwork(url: song.artworkURL).frame(width: 132, height: 132)
            Text(song.title).font(.callout.weight(.medium)).lineLimit(1)
            Text(song.artist.isEmpty ? song.source.title : song.artist)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 132, alignment: .leading)
    }
}

private struct HomeCollectionCard: View {
    let collection: OnlineCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OnlineArtwork(url: collection.artworkURL).aspectRatio(1, contentMode: .fit)
            Text(collection.title).font(.callout.weight(.medium)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(HomeCollectionCard.subtitle(for: collection))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    static func subtitle(for collection: OnlineCollection) -> String {
        var parts: [String] = []
        if !collection.subtitle.isEmpty { parts.append(collection.subtitle) }
        if let count = collection.trackCount, count > 0 { parts.append("\(count) 首") }
        if parts.isEmpty { parts.append(collection.source.title) }
        return parts.joined(separator: " · ")
    }
}

private struct HomeYouTubeCard: View {
    let item: YouTubeMusicHomeItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            OnlineArtwork(url: item.artworkURL).frame(width: 132, height: 132)
            Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
            Text(item.subtitle.isEmpty ? "YouTube Music" : item.subtitle)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 132, alignment: .leading)
    }
}

// MARK: - 通用小部件

private struct HomeLibraryOverview: View {
    @ObservedObject var viewModel: LibraryViewModel
    var onRetry: () -> Void
    var onOpen: () -> Void

    var body: some View {
        HomeSection(title: "媒体库", systemImage: "music.note.list") {
            if !viewModel.hasLoaded { ProgressView("正在加载媒体库…") }
            if let error = viewModel.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("重新加载媒体库", action: onRetry)
            }
            HStack(spacing: 12) {
                HomeMetric(value: "\(viewModel.tracks.count)", label: "首曲目")
                HomeMetric(value: "\(viewModel.albumGroups.count)", label: "张专辑")
                HomeMetric(value: "\(viewModel.playlists.count)", label: "个歌单")
                Spacer()
                Button("管理媒体库", action: onOpen).buttonStyle(.bordered)
            }
        }
    }
}

private struct HomeAction: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct HomeSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
    }
}

private struct HomeMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 86, alignment: .leading)
    }
}

private struct HomeLoadingRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

private struct HomeErrorRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("重试", action: retry).controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct HomeInlineWarning: View {
    let text: String

    var body: some View {
        Label("刷新失败，显示上次内容：\(text)", systemImage: "exclamationmark.triangle")
            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
    }
}

private struct HomeTrackArtwork: View {
    let track: Track

    var body: some View {
        if let url = track.onlineSong?.artworkURL {
            OnlineArtwork(url: url)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
                .overlay(Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary))
        }
    }
}
