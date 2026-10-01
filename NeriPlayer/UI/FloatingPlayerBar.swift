// FloatingPlayerBar.swift
// NeriPlayer macOS —— 跨 tab 常驻的底部播放器栏。
//
// 关键取舍（对应用户要求）：
//   1) 进度条固定在最上方，且**始终渲染**：引擎尚未加载出时长时显示不确定进度（加载态），
//      而不是把控件撤掉 —— 换歌/首帧不会让整条栏跳一下（防闪）。进度条可拖动跳转。
//   2) 曲目区可显示 1–2 行：标题 + 歌手（宽度够时带真实音频规格），再加一行当前歌词。
//   3) 真实音频规格（编码/比特率/采样率/声道）来自内核实际打开的文件；没有就不显示，绝不编造。
//   4) 控件先按组排序（传输 / 模式 / 收藏 / 展示 / 队列 / 音量），再按窗口宽度把放不下的收进「更多」菜单。
//   5) 队列按钮由本栏自己弹出真正的当前队列（PlaybackQueuePopover），因此不再需要 onOpenQueue。
//   6) 「悬浮歌词」调用 appState.toggleFloatingLyrics()；「歌词」走主窗口的 onLyrics 回调。
//
// 订阅模型（T01 起沿用）：本栏不直接读 appState.playbackStore 的实时属性，而是用一个 @State 捕获
// store 与最近一次快照。store 晚于本视图出现（启动顺序）也能接上：onReceive(appState.$playbackStore)
// 会先回放一次当前值，随后 .task 以 store 的对象标识为 id 订阅快照流。

import SwiftUI

struct FloatingPlayerBar: View {

    @EnvironmentObject private var appState: AppState
    /// 打开主窗口歌词面板（保留给主窗口，主智能体接入）。
    var onLyrics: () -> Void

    /// 捕获的 store 与快照，跨导航与晚启动存活。
    @State private var playbackStore: PlaybackStateStore?
    @State private var snapshot: PlaybackSnapshot?
    /// 队列弹层是否展开。
    @State private var isQueuePresented = false
    /// 是否正在为当前曲新建歌单（驱动命名 sheet）。
    @State private var isCreatingPlaylist = false
    /// 是否在「更多」菜单里展开了音量控件（菜单内点击音量项后弹出）。
    @State private var isMenuVolumePresented = false
    /// 本栏可用宽度，用于「空间不够就把控件收进更多菜单」。
    ///
    /// 通过 .background 里的 GeometryReader 测量并回填，而不是把整条栏包进 GeometryReader：
    /// 后者会强制栏有一个固定高度（GeometryReader 的子视图拿不到父级理想高度），
    /// 于是曲目区从一行变两行时会被裁掉。这里只测宽度，高度仍由内容自然决定。
    @State private var availableWidth: CGFloat = PlayerBarLayout.wideThreshold

    var body: some View {
        content(width: availableWidth)
            .background(widthReader)
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
                NewCurrentTrackPlaylistSheet { name in createPlaylist(named: name) }
            }
    }

    /// 只测宽度、不参与布局的背景读取器。
    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { availableWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { width in availableWidth = width }
        }
    }

    // MARK: - 主体

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        let plan = PlayerBarLayout.plan(forWidth: width)
        VStack(spacing: 0) {
            Divider()
            // 进度行固定在最上方，始终在（无曲时空轨道；有曲但时长未出时不确定进度）。
            progressRow
            if let store = playbackStore, let current = snapshot {
                mainRow(store: store, snapshot: current, plan: plan)
            } else {
                placeholderRow
            }
        }
        .background(.regularMaterial)
        .contentShape(Rectangle())
    }

    /// 进度行：左侧已播时间 + 进度条 + 右侧总时长。时间用等宽数字，宽度固定避免跳动。
    private var progressRow: some View {
        HStack(spacing: 8) {
            Text(PlaybackTimeText.text(snapshot?.position ?? 0))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            PlayerProgressBar(
                position: snapshot?.position ?? 0,
                duration: snapshot?.duration ?? 0,
                hasTrack: snapshot?.currentTrack != nil,
                onSeek: { seconds in playbackStore?.seek(to: seconds) }
            )
            Text(PlaybackTimeText.durationText(snapshot?.duration ?? 0))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .frame(height: 18)
    }

    /// 主行固定高度：所有宽度、所有曲目下都稳定，换歌/窄窗不会让整条栏上下跳。
    static let rowHeight: CGFloat = 56

    /// store 未就绪时的稳定占位：栏高度不跳。
    private var placeholderRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
            Text("播放器未就绪").font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(height: Self.rowHeight)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - 主行（分组）

    private func mainRow(store: PlaybackStateStore, snapshot: PlaybackSnapshot, plan: PlayerBarLayoutPlan) -> some View {
        HStack(alignment: .center, spacing: 12) {
            PlayerBarArtwork(track: snapshot.currentTrack)
                .frame(width: 44, height: 44)

            trackInfo(snapshot: snapshot, plan: plan)

            // 中间 flexible 区域：宽窗时用当前歌词填满左侧信息区与右侧按钮之间的空白；
            // 无歌词或窄窗时用等宽空白占位，保证高度与其余控件位置都不变（歌词缺失也保留空间）。
            lyricRegion(plan: plan)

            // 组 1：传输（恒内联）
            transportGroup(store: store, snapshot: snapshot)

            // 组 2–4：模式 / 收藏 / 展示（按档位内联或收进更多）
            inlineOptionalControls(plan: plan, snapshot: snapshot)

            // 组 5：队列（恒内联，自己弹真实队列）
            queueButton

            // 组 6：音量（宽窗内联，窄窗收进更多）
            if plan.isInline(.volume) {
                volumeControl(store: store, snapshot: snapshot)
            }

            // 更多菜单始终在：它同时承载「播放完当前曲后暂停」这类低频动作，
            // 若只在有控件被收起时才出现，宽窗下这个功能就没有入口。
            moreMenu(store: store, snapshot: snapshot, plan: plan)
        }
        .frame(height: Self.rowHeight)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - 曲目信息（标题 / 歌手 / 规格）

    private func trackInfo(snapshot: PlaybackSnapshot, plan: PlayerBarLayoutPlan) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(snapshot.currentTrack?.title ?? "未播放")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            // 第二行恒在（标题 + 歌手），保证主行高度在任意宽度都一致；
            // 宽窗时在歌手后追加真实音频规格，窄窗只显示歌手。
            Text(artistText(snapshot.currentTrack))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if plan.showsArtistLine {
                Text(AudioInfoText.summary(snapshot.audioTrackInfo) ?? "音频信息待加载")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .help(AudioInfoText.summary(snapshot.audioTrackInfo) ?? "音频信息待加载")
            }
        }
        // 固定信息区宽度：把宽窗剩余的横向空白让给中间的歌词区（而不是让信息区无限拉长）。
        .frame(width: Self.infoWidth, alignment: .leading)
    }

    /// 信息区固定宽度。
    static let infoWidth: CGFloat = 200

    /// 中间的歌词区：宽窗展示当前歌词行，占满剩余空白；否则用等宽空白占位。
    ///
    /// 歌词内容放在独立的 @ObservedObject 子视图里（PlayerBarLyricLine）：LyricsViewModel 是
    /// ObservableObject，若在本视图里只读它的属性、不订阅它，歌词语义变化（异步加载完成、
    /// 暂停期间偏移重算）不会触发重绘。播放在进行时 store 进度会顺带刷新本视图，但暂停/加载完成
    /// 这类没有进度事件时刻就不会回流 —— 独立观察子视图可以覆盖这两种情况。
    @ViewBuilder
    private func lyricRegion(plan: PlayerBarLayoutPlan) -> some View {
        if plan.showsLyricLine, let model = appState.lyricsViewModel {
            PlayerBarLyricLine(model: model, trackID: snapshot?.currentTrack?.id)
        } else {
            // 保留同样的 flexible 空白：歌词缺失或窄窗时高度与控件位置不变。
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    private func artistText(_ track: Track?) -> String {
        guard let artist = track?.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty else {
            return "未知歌手"
        }
        return artist
    }

    // MARK: - 传输组

    private func transportGroup(store: PlaybackStateStore, snapshot: PlaybackSnapshot) -> some View {
        let hasTrack = snapshot.currentTrack != nil
        return HStack(spacing: 4) {
            Button { store.previous() } label: { Image(systemName: "backward.end.fill") }
                .help("上一首")
                .disabled(!hasTrack)
            Button { store.togglePlayPause() } label: {
                Image(systemName: isPlaying(snapshot) ? "pause.fill" : "play.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .help("播放或暂停")
            .disabled(!hasTrack)
            Button { store.next(force: true) } label: { Image(systemName: "forward.end.fill") }
                .help("下一首")
                .disabled(!hasTrack)
        }
    }

    private func isPlaying(_ snapshot: PlaybackSnapshot) -> Bool {
        !snapshot.isPaused && !snapshot.isCoreIdle
    }

    // MARK: - 可选控件（按档位内联）

    private func inlineOptionalControls(plan: PlayerBarLayoutPlan, snapshot: PlaybackSnapshot) -> some View {
        HStack(spacing: 4) {
            if plan.isInline(.mode) { modeButton(snapshot: snapshot) }
            if plan.isInline(.pauseAfterCurrent) { pauseAfterCurrentButton(snapshot: snapshot) }
            if plan.isInline(.favorite), let library = appState.libraryViewModel {
                libraryActions(library, placement: .inlineFavorite, snapshot: snapshot)
            }
            if plan.isInline(.addToPlaylist), let library = appState.libraryViewModel {
                libraryActions(library, placement: .inlinePlaylist, snapshot: snapshot)
            }
            if plan.isInline(.lyrics) {
                Button(action: onLyrics) { Image(systemName: "text.alignleft") }.help("打开歌词")
            }
            if plan.isInline(.floatingLyrics) { floatingLyricsButton }
        }
    }

    /// 把「收藏 / 加入歌单」的渲染交给持有 @ObservedObject LibraryViewModel 的子视图。
    ///
    /// 为什么必须独立子视图：收藏状态与歌单列表都在 LibraryViewModel 里（@Published），
    /// 而本栏只订阅 AppState。暂停或没有进度事件时，点收藏或新建歌单后 LibraryViewModel 的变化
    /// 不会冒泡到本栏，按钮/菜单不会刷新（与歌词行同一个坑）。子视图观察 LibraryViewModel 自身即可覆盖。
    private func libraryActions(_ library: LibraryViewModel, placement: PlayerBarLibraryActions.Placement,
                                snapshot: PlaybackSnapshot) -> some View {
        PlayerBarLibraryActions(
            library: library,
            track: snapshot.currentTrack,
            placement: placement,
            onToggleFavorite: { toggleFavorite(snapshot) },
            onAddToPlaylist: { addToPlaylist($0, snapshot: snapshot) },
            onNewPlaylist: { isCreatingPlaylist = true }
        )
    }

    // MARK: - 播完当前曲暂停

    /// 开关式按钮：开启后本曲自然播完停在当前曲（一次性）。图标在开启时高亮以表达状态。
    private func pauseAfterCurrentButton(snapshot: PlaybackSnapshot) -> some View {
        let enabled = snapshot.pauseAfterCurrent
        return Button {
            playbackStore?.setPauseAfterCurrent(!enabled)
        } label: {
            Image(systemName: enabled ? "pause.circle.fill" : "pause.circle")
                .foregroundStyle(enabled ? Color.accentColor : Color.primary)
        }
        .disabled(snapshot.currentTrack == nil)
        .help(enabled ? "已开启：播完当前曲暂停（点击取消）" : "播完当前曲后暂停")
        .accessibilityLabel("播完当前曲暂停")
        .accessibilityValue(enabled ? "已开启" : "已关闭")
    }

    // MARK: - 模式

    /// 一个按钮循环切换四种播放模式，图标随当前模式变化。
    private func modeButton(snapshot: PlaybackSnapshot) -> some View {
        Button {
            playbackStore?.setMode(nextMode(after: snapshot.queue.mode))
        } label: {
            Image(systemName: Self.modeSymbol(snapshot.queue.mode))
        }
        .help("播放模式：\(Self.modeTitle(snapshot.queue.mode))（点击切换）")
        .accessibilityLabel("播放模式")
        .accessibilityValue(Self.modeTitle(snapshot.queue.mode))
    }

    private func nextMode(after mode: PlaybackMode) -> PlaybackMode {
        switch mode {
        case .sequential: return .repeatAll
        case .repeatAll: return .repeatOne
        case .repeatOne: return .shuffle
        case .shuffle: return .sequential
        }
    }

    static func modeSymbol(_ mode: PlaybackMode) -> String {
        switch mode {
        case .sequential: return "arrow.right"
        case .repeatAll: return "repeat"
        case .repeatOne: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }

    static func modeTitle(_ mode: PlaybackMode) -> String {
        switch mode {
        case .sequential: return "顺序播放"
        case .repeatAll: return "列表循环"
        case .repeatOne: return "单曲循环"
        case .shuffle: return "随机播放"
        }
    }

    // MARK: - 悬浮歌词

    private var floatingLyricsButton: some View {
        Button { appState.toggleFloatingLyrics() } label: {
            Image(systemName: "text.bubble")
        }
        .disabled(appState.lyricsViewModel == nil)
        .help("桌面悬浮歌词")
        .accessibilityLabel("桌面悬浮歌词")
    }

    // MARK: - 队列

    /// 队列按钮：就地弹出真实当前队列（不跳媒体库）。
    private var queueButton: some View {
        Button { isQueuePresented.toggle() } label: {
            Image(systemName: "music.note.list")
        }
        .help("播放队列")
        .accessibilityLabel("播放队列")
        .popover(isPresented: $isQueuePresented, arrowEdge: .bottom) {
            PlaybackQueuePopover(
                queue: snapshot?.queue ?? .empty,
                onJump: { index in playbackStore?.jump(toQueueIndex: index) },
                onRemove: { index in playbackStore?.removeFromQueue(at: index) }
            )
        }
    }

    // MARK: - 音量

    private func volumeControl(store: PlaybackStateStore, snapshot: PlaybackSnapshot) -> some View {
        VolumeSlider(value: snapshot.volume) { committed in
            store.setVolume(committed)
        }
    }

    static func volumeSymbol(_ volume: Double) -> String {
        if volume <= 0.5 { return "speaker.slash" }
        if volume < 34 { return "speaker" }
        if volume < 67 { return "speaker.wave.1" }
        return "speaker.wave.2"
    }

    // MARK: - 更多菜单（收起的控件）

    private func moreMenu(store: PlaybackStateStore, snapshot: PlaybackSnapshot, plan: PlayerBarLayoutPlan) -> some View {
        Menu {
            // 音频信息恒在：窄窗把规格从主行收起后，这里仍能读到真实编码/比特率等；
            // 无数据时不编造，显示「音频信息不可用」。
            audioInfoSection(snapshot: snapshot)
            Divider()
            if plan.collapsed.contains(.mode) {
                Menu("播放模式") {
                    // PlaybackMode 只声明了 Equatable（raw string 枚举不会自动获得 Hashable），
                    // 因此这里用 rawValue 做稳定标识，而不是 id: \.self。
                    ForEach(PlaybackMode.allCases, id: \.rawValue) { mode in
                        Button {
                            store.setMode(mode)
                        } label: {
                            Label(Self.modeTitle(mode),
                                  systemImage: snapshot.queue.mode == mode ? "checkmark" : Self.modeSymbol(mode))
                        }
                    }
                }
                Divider()
            }
            if plan.collapsed.contains(.pauseAfterCurrent) {
                Button(snapshot.pauseAfterCurrent ? "取消：播完当前曲暂停" : "播完当前曲暂停") {
                    store.setPauseAfterCurrent(!snapshot.pauseAfterCurrent)
                }
                .disabled(snapshot.currentTrack == nil)
            }
            if plan.collapsed.contains(.favorite) {
                if let library = appState.libraryViewModel {
                    libraryActions(library, placement: .menuFavorite, snapshot: snapshot)
                }
            }
            if plan.collapsed.contains(.addToPlaylist) {
                if let library = appState.libraryViewModel {
                    libraryActions(library, placement: .menuPlaylist, snapshot: snapshot)
                }
            }
            if plan.collapsed.contains(.lyrics) {
                Button("打开歌词") { onLyrics() }
            }
            if plan.collapsed.contains(.floatingLyrics) {
                Button("桌面悬浮歌词") { appState.toggleFloatingLyrics() }
                    .disabled(appState.lyricsViewModel == nil)
            }
            if plan.collapsed.contains(.volume) {
                Divider()
                // 菜单项是按钮，不能承载滑杆；点这一项后由外层 Menu 的 popover 弹出真正的音量滑杆
                // （锚在更多按钮上，菜单关闭后出现，比把 popover 挂在菜单项上稳定）。
                Button("音量…（\(Int(snapshot.volume.rounded()))）") { isMenuVolumePresented = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help("更多")
        .accessibilityLabel("更多")
        .popover(isPresented: $isMenuVolumePresented, arrowEdge: .bottom) {
            VolumeSliderPopover(value: snapshot.volume) { committed in
                store.setVolume(committed)
            }
        }
    }

    /// 「更多」菜单顶部的音频信息：只列内核报告过的字段。
    @ViewBuilder
    private func audioInfoSection(snapshot: PlaybackSnapshot) -> some View {
        if let summary = AudioInfoText.summary(snapshot.audioTrackInfo) {
            Text("音频：\(summary)")
        } else {
            Text("音频信息不可用")
        }
    }

    // MARK: - 收藏 / 歌单动作（本地走库，在线先入库）

    /// 切换当前曲收藏。本地曲走库内切换；在线歌走「先入库再收藏」。
    private func toggleFavorite(_ snapshot: PlaybackSnapshot) {
        guard let library = appState.libraryViewModel else { return }
        switch CurrentTrackLibraryActions.target(for: snapshot.currentTrack, libraryTracks: library.tracks) {
        case .library(let item):
            library.toggleFavorite(item)
        case .online(let song):
            appState.syncViewModel?.addToLibrary(song, favorite: true)
        case nil:
            break
        }
    }

    /// 把当前曲加入某歌单。本地曲直接入单；在线歌先入库再带上歌单 id。
    private func addToPlaylist(_ playlist: PlaylistInfo, snapshot: PlaybackSnapshot) {
        guard let library = appState.libraryViewModel else { return }
        switch CurrentTrackLibraryActions.target(for: snapshot.currentTrack, libraryTracks: library.tracks) {
        case .library(let item):
            library.add(item, to: playlist)
        case .online(let song):
            appState.syncViewModel?.addToLibrary(song, playlistID: playlist.id, favorite: false)
        case nil:
            break
        }
    }

    /// 新建歌单并把当前曲加入。本地曲走 LibraryViewModel（含校验与刷新）；在线歌走入库路径。
    private func createPlaylist(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let library = appState.libraryViewModel else { return }
        switch CurrentTrackLibraryActions.target(for: snapshot?.currentTrack, libraryTracks: library.tracks) {
        case .library(let item):
            library.createPlaylist(named: trimmed, adding: item)
        case .online(let song):
            // 在线曲没有库行，先把歌单建出来，拿到**实际创建的那个** id 再把歌入库入单；
            // 不能用名字回查（同名歌单存在时会误命中已有的那一个）。
            if let created = library.createPlaylist(named: trimmed, adding: nil) {
                appState.syncViewModel?.addToLibrary(song, playlistID: created.id, favorite: false)
            }
        case nil:
            library.createPlaylist(named: trimmed, adding: nil)
        }
    }
}

// MARK: - 新建歌单命名 sheet

// MARK: - 音量滑杆（提交式，无离散刻度）

// MARK: - 当前曲的收藏 / 加入歌单（观察 LibraryViewModel）

/// 收藏按钮与「加入歌单」菜单。持有 @ObservedObject LibraryViewModel，因此收藏状态与歌单列表
/// 变化时会自行刷新 —— 主栏只订阅 AppState，暂停等无进度事件时不会因 LibraryViewModel 变化而重绘。
///
/// 放置方式（inline/menu）决定渲染形态：主栏内联时是独立按钮与菜单；收进「更多」菜单时是同名菜单项
/// 与子菜单。动作仍由主栏注入（收藏/入单需要 store 与 syncViewModel，那些在主栏手上）。
private struct PlayerBarLibraryActions: View {

    enum Placement { case inlineFavorite, inlinePlaylist, menuFavorite, menuPlaylist }

    @ObservedObject var library: LibraryViewModel
    let track: Track?
    let placement: Placement
    let onToggleFavorite: () -> Void
    let onAddToPlaylist: (PlaylistInfo) -> Void
    let onNewPlaylist: () -> Void

    /// 当前曲目的库侧落点（决定是否已收藏、能否收藏）。
    private var target: CurrentTrackLibraryTarget? {
        CurrentTrackLibraryActions.target(for: track, libraryTracks: library.tracks)
    }

    private var isFavorited: Bool {
        CurrentTrackLibraryActions.isFavorited(track, libraryTracks: library.tracks,
                                                favoriteIds: library.favoriteTrackIds)
    }

    /// 当前曲是否可收藏/入单（本地未入库的临时文件不可）。
    private var isActionable: Bool { target != nil }

    var body: some View {
        switch placement {
        case .inlineFavorite:
            favoriteButton
        case .menuFavorite:
            Button(isFavorited ? "取消收藏" : "添加到收藏") { onToggleFavorite() }
                .disabled(!isActionable)
        case .inlinePlaylist:
            playlistMenu
        case .menuPlaylist:
            Menu("加入歌单") { playlistItems }
                .disabled(!isActionable)
        }
    }

    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: isFavorited ? "star.fill" : "star")
                .foregroundStyle(isFavorited ? Color.yellow : Color.primary)
        }
        .disabled(!isActionable)
        .help(isFavorited ? "取消收藏" : "添加到收藏")
        .accessibilityLabel(isFavorited ? "取消收藏" : "添加到收藏")
    }

    private var playlistMenu: some View {
        Menu { playlistItems } label: {
            Image(systemName: "text.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .disabled(!isActionable)
        .help("加入歌单")
        .accessibilityLabel("加入歌单")
    }

    @ViewBuilder
    private var playlistItems: some View {
        if !library.playlists.isEmpty {
            ForEach(library.playlists) { playlist in
                Button(playlist.name) { onAddToPlaylist(playlist) }
            }
            Divider()
        }
        Button("新建歌单…") { onNewPlaylist() }
    }
}

/// 应用音量滑杆：拖动时本地跟手，松开（提交）时一次性写回 store。
///
/// 两个要点：
///   1) **不设 step**。用户反馈过带 step 的滑杆会产生几十个刻度并造成每次拖动都重建/刷新；
///      这里用连续区间，拖动是本视图内部状态，只在松开时提交一次，避免拖动过程中反复触发内核 I/O。
///   2) 松手提交而非实时提交：setVolume 每次都下发引擎并发布快照，实时提交会让拖动产生大量发布。
///      暂停期间切歌等场景不需要实时音量，提交式已足够且更稳。
private struct VolumeSlider: View {
    /// 外部传入的当前音量（用于初始化与外部变化同步）。
    let value: Double
    /// 松手提交回调。
    let onCommit: (Double) -> Void

    @State private var draft: Double
    @State private var isDragging = false

    init(value: Double, onCommit: @escaping (Double) -> Void) {
        self.value = value
        self.onCommit = onCommit
        _draft = State(initialValue: min(max(value, 0), 100))
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: FloatingPlayerBar.volumeSymbol(draft))
                .foregroundStyle(.secondary)
                .font(.caption)
            Text("\(Int(draft.rounded()))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            Slider(
                value: $draft,
                in: PlaybackBehaviorDefaults.volumeRange,
                onEditingChanged: { editing in
                    isDragging = editing
                    // 只在松开（editing == false）时提交，拖动过程中不写内核。
                    if !editing { onCommit(draft) }
                }
            )
            .frame(width: 96)
            .controlSize(.small)
            .accessibilityLabel("音量")
            .accessibilityValue("\(Int(draft.rounded()))")
        }
        // 外部音量变化（启动音量下发、菜单调整）时同步本地草稿；拖动中不打断用户。
        .onChange(of: value) { next in
            if !isDragging { draft = min(max(next, 0), 100) }
        }
    }
}

/// 独立浮层里的音量滑杆（「更多」菜单中点击「音量…」后弹出）。
private struct VolumeSliderPopover: View {
    let value: Double
    let onCommit: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("应用音量").font(.caption).foregroundStyle(.secondary)
            VolumeSlider(value: value, onCommit: onCommit)
        }
        .padding(12)
    }
}

// MARK: - 当前歌词行（独立观察，覆盖暂停/加载完成时无进度事件的情况）

/// 中栏歌词行。作为独立子视图持有 @ObservedObject LyricsViewModel：
/// 播放进行时虽然 store 进度会顺带刷新外层，但暂停、歌词异步加载完成这两类时刻没有进度事件，
/// 外层不会重绘；这里订阅 model 自身的变化即可覆盖。
private struct PlayerBarLyricLine: View {
    @ObservedObject var model: LyricsViewModel
    /// 期望对应的当前曲目 id：与 model 内快照不一致（model 尚未切到新曲）时显示占位。
    let trackID: UUID?

    var body: some View {
        let text = lyricText
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(text)
            .accessibilityLabel("歌词")
            .accessibilityValue(text)
    }

    /// 有真实歌词且对应当前曲时返回该行，否则返回一个明确占位（保留行高与位置，不留空一块）。
    private var lyricText: String {
        guard model.snapshot?.currentTrack?.id == trackID else { return "…" }
        let text = model.currentLyricText
        guard !text.isEmpty, text != "暂无歌词" else { return "…" }
        return text
    }
}

/// 当前曲目的「新建歌单」命名 sheet。命名与库内既有「新建歌单」交互保持一致（去空白校验 + 默认按钮）。
private struct NewCurrentTrackPlaylistSheet: View {
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

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func confirm() {
        guard !trimmedName.isEmpty else { return }
        onConfirm(trimmedName)
        dismiss()
    }
}

// MARK: - 封面

private struct PlayerBarArtwork: View {
    let track: Track?
    var body: some View {
        if let url = track?.onlineSong?.artworkURL {
            OnlineArtwork(url: url)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
    }
}
