// FloatingPlayerBar.swift
// NeriPlayer macOS —— 跨 tab 常驻的底部播放器栏。
//
// 本轮（2026-10-03）排版规格：**三区布局，左右等宽**。
//   1) 左区（左对齐）：封面贴窗口左边界（水平内边距 14），右侧紧接曲名 / 歌手 / 歌曲数据（并排）
//      / 当前歌词；曲名约 17pt，歌手与数据约 13pt。音乐来源不再单独一行，而是并入歌曲数据行
//      （形如「某歌手 网易云 · AAC · 128 kbps · 48 kHz · 2ch」）。本地曲没有平台来源，只显示规格。
//   2) 中区（居中）：上面一行「已播时间 + 进度条 + 总时长」，下面传输组（上一首 / 播放暂停 / 下一首），
//      播放按钮明显放大。宽度固定（PlayerBarLayout.centerWidth），保证居中不随左右内容漂移。
//   3) 右区（右对齐）：模式、播完暂停、收藏、加入歌单、桌面歌词、队列、音量、更多。
//      全部走同一字号与同一间距（14），不分组建。
//
// 为什么左右等宽：中区要落在**整窗水平中心**。若写成「左信息 + Spacer + 中区 + Spacer + 右动作」，
// 两个 Spacer 均分的是「左信息之后、右动作之前」的剩余空间 —— 两侧内容宽度不等时中区就会偏斜。
// 把左右两区固定成同一个宽度，中区中心天然等于整窗中心。
//
// 关键取舍：
//   1) 进度条固定在栏内（在控制按钮上方），且**始终渲染**：引擎尚未加载出时长时显示不确定进度，
//      而不是把控件撤掉 —— 换歌/首帧不会让整条栏跳一下。播放中的 seek 也不会触发整栏加载占位。
//   2) 真实音频规格（编码/比特率/采样率/声道）来自内核实际打开的文件；没有就不编造，显示待加载。
//   3) 控件按窗口宽度收起次要动作、保留传输组与队列入口；收起项仍能在「更多」菜单里找到。
//   4) 队列按钮由本栏自己弹出真正的当前队列（PlaybackQueuePopover），因此不再需要 onOpenQueue。
//   5) 旧「打开歌词页」按钮与主窗口 sheet 导航入口已删除；点封面或歌曲信息打开「歌曲播放页」，
//      桌面悬浮歌词入口保留。
//   6) 栏内所有可点击按钮都带 `.help`（macOS 原生悬停提示），文案反映当前状态。
//
// 订阅模型（T01 起沿用）：本栏不直接读 appState.playbackStore 的实时属性，而是用一个 @State 捕获
// store 与最近一次快照。store 晚于本视图出现（启动顺序）也能接上：onReceive(appState.$playbackStore)
// 会先回放一次当前值，随后 .task 以 store 的对象标识为 id 订阅快照流。

import SwiftUI

struct FloatingPlayerBar: View {

    @EnvironmentObject private var appState: AppState
    /// 统一字体接口（B 提供）。视图只读它，不自己拼 Font.system。
    @Environment(\.appTypography) private var typography
    /// 打开主窗口的「歌曲播放页」。默认空实现，方便测试与预览单独渲染本栏。
    var onOpenNowPlaying: () -> Void = {}

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
    /// 于是内容会被裁掉。这里只测宽度，高度仍由内容自然决定。
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

    private func content(width: CGFloat) -> some View {
        let plan = PlayerBarLayout.plan(forWidth: width)
        // 无曲/换歌期间也走同一条 row：文字落到占位文案、控件置灰，骨架与栏高完全不变。
        return VStack(spacing: 0) {
            Divider()
            mainRow(store: playbackStore, snapshot: snapshot, plan: plan, width: width)
        }
        .background(.regularMaterial)
        .contentShape(Rectangle())
    }

    // MARK: - 主行（左信息 / 中控制 / 右动作）

    /// 三区布局：左右两侧各占剩余宽度的**一半**，中间控制区因此落在整窗水平中心。
    ///
    /// 为什么是 `maxWidth: .infinity` 而不是算出一个固定 sideWidth：
    /// 固定宽度一旦遇到「算出来比窗口还窄」的情况（旧实现有 `max(120, …)` 下限），
    /// 三区总宽就会超过窗口，左右两侧的内容被裁掉。交给 SwiftUI 分剩余空间后，
    /// 两侧永远只会被压缩到 0 而不是溢出：左区左对齐、右区右对齐，中间固定宽度居中。
    /// 中区给更高的 layoutPriority，保证被压缩的是两侧文字而不是进度条与传输组。
    private func mainRow(store: PlaybackStateStore?, snapshot: PlaybackSnapshot?,
                         plan: PlayerBarLayoutPlan, width: CGFloat) -> some View {
        return HStack(spacing: 0) {
            informationRegion(store: store, snapshot: snapshot, plan: plan)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)
                .clipped()
            centerRegion(store: store, snapshot: snapshot)
                .frame(width: PlayerBarLayout.centerWidth)
                .layoutPriority(1)
            actionsRegion(store: store, snapshot: snapshot, plan: plan)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .layoutPriority(0)
                .clipped()
        }
        // 栏高约等于封面高度（72）。用 minHeight 而不是固定 height：默认字号下正好 72，
        // 用户把播放器/歌词字号调到上限时文字不被裁掉，栏随之略长。
        .frame(minHeight: PlayerArtwork.barRowHeight)
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 4)
    }

    /// 栏的水平内边距。封面因此贴住窗口左边界（14pt），与需求一致；同一常量参与左右等宽的计算。
    static let horizontalPadding: CGFloat = 14

    // MARK: - 左区：封面 + 曲名 / 歌手与数据 / 歌词

    private func informationRegion(store: PlaybackStateStore?, snapshot: PlaybackSnapshot?,
                                   plan: PlayerBarLayoutPlan) -> some View {
        let track = snapshot?.currentTrack
        let size = PlayerArtwork.barSize(for: track)
        return HStack(spacing: 14) {
            // 封面在最左，由外层的 14pt 水平内边距贴住窗口左边界。
            artworkButton(track: track)
                .frame(width: size.width, height: size.height)
            trackInfo(snapshot: snapshot, plan: plan)
        }
    }

    /// 封面即「打开歌曲播放页」的入口。
    private func artworkButton(track: Track?) -> some View {
        Button { onOpenNowPlaying() } label: {
            PlayerArtwork(content: PlayerArtwork.content(for: track, library: appState.libraryViewModel),
                          shape: PlayerArtwork.shape(for: track),
                          cornerRadius: 8, symbolSize: 22)
        }
        .buttonStyle(.plain)
        .help("打开歌曲播放页")
        .accessibilityLabel("打开歌曲播放页")
    }

    private func trackInfo(snapshot: PlaybackSnapshot?, plan: PlayerBarLayoutPlan) -> some View {
        let track = snapshot?.currentTrack
        return VStack(alignment: .leading, spacing: 2) {
            // 标题与歌手/数据都包在按钮里：点歌曲信息同样进入播放页。
            Button { onOpenNowPlaying() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? "未播放")
                        // 播放器字号设置在此生效（17pt 是设计基准，缩放在接口内完成）。
                        .font(typography.playerFont(scaledFromBase: 17))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if plan.showsArtistLine {
                        // 歌手 + 来源 + 音频规格合并成一行：来源不再单独占一行。
                        HStack(spacing: 6) {
                            Text(artistText(track))
                                .font(typography.uiFont(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(sourceAndSpecText(snapshot))
                                .font(typography.uiFont(size: 13))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .help(sourceAndSpecText(snapshot))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开歌曲播放页")
            // 当前歌词行：用「底部歌词字号」设置，独立观察 LyricsViewModel，
            // 覆盖暂停、歌词异步加载完成这两类没有进度事件的时刻。
            if plan.showsLyricLine, let model = appState.lyricsViewModel {
                PlayerBarLyricLine(model: model, trackID: track?.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func artistText(_ track: Track?) -> String {
        guard let artist = track?.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty else {
            return "未知歌手"
        }
        return artist
    }

    /// 歌曲数据行（不含歌手）：平台来源 + 真实音频规格，用 " · " 连接。
    ///
    /// 来源只在在线曲出现（本地曲没有平台）；规格只列内核实际报告过的字段，缺一项就不显示那一项，
    /// 全缺时给一个明确占位而不是空白。
    private func sourceAndSpecText(_ snapshot: PlaybackSnapshot?) -> String {
        let source = snapshot?.currentTrack?.onlineSong?.source.title
        let spec = AudioInfoText.summary(snapshot?.audioTrackInfo)
        let parts = [source, spec].compactMap { $0 }
        return parts.isEmpty ? "音频信息待加载" : parts.joined(separator: " · ")
    }

    // MARK: - 中区：进度行 + 传输组

    /// 中区固定宽度，上下两行：进度行在上，传输组在下；播放按钮明显放大。
    private func centerRegion(store: PlaybackStateStore?, snapshot: PlaybackSnapshot?) -> some View {
        VStack(spacing: 4) {
            progressRow(store: store, snapshot: snapshot)
            transportGroup(store: store, snapshot: snapshot)
        }
    }

    /// 进度行：已播时间 + 进度条 + 总时长。时间用等宽数字、宽度固定，避免数字变化时抖动。
    private func progressRow(store: PlaybackStateStore?, snapshot: PlaybackSnapshot?) -> some View {
        let position = snapshot?.position ?? 0
        let duration = snapshot?.duration ?? 0
        return HStack(spacing: 8) {
            Text(PlaybackTimeText.text(position))
                .font(typography.uiFont(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            PlayerProgressBar(
                position: position,
                duration: duration,
                hasTrack: snapshot?.currentTrack != nil,
                trackID: snapshot?.currentTrack?.id,
                onSeek: { seconds in store?.seek(to: seconds) }
            )
            Text(PlaybackTimeText.durationText(duration))
                .font(typography.uiFont(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func transportGroup(store: PlaybackStateStore?, snapshot: PlaybackSnapshot?) -> some View {
        let hasTrack = snapshot?.currentTrack != nil
        let playing = snapshot.map(isPlaying) ?? false
        return HStack(spacing: 10) {
            Button { store?.previous() } label: {
                Image(systemName: "backward.end.fill").font(typography.playerFont(scaledFromBase: 20))
            }
            .help("上一首")
            .disabled(!hasTrack)
            Button { store?.togglePlayPause() } label: {
                // 播放按钮明显放大：48pt 圆形实心按钮，是整条栏的视觉焦点。
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(typography.playerFont(scaledFromBase: 22))
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help(playing ? "暂停" : "播放")
            .disabled(!hasTrack)
            Button { store?.next(force: true) } label: {
                Image(systemName: "forward.end.fill").font(typography.playerFont(scaledFromBase: 20))
            }
            .help("下一首")
            .disabled(!hasTrack)
        }
        .buttonStyle(.borderless)
    }

    private func isPlaying(_ snapshot: PlaybackSnapshot) -> Bool {
        !snapshot.isPaused && !snapshot.isCoreIdle
    }

    // MARK: - 右区：模式 / 播完暂停 / 收藏 / 歌单 / 桌面歌词 / 队列 / 音量 / 更多

    /// 右对齐、大小相等、间隔相等，不分组建：整组共用同一字号、同一间距与同一按钮尺寸。
    private func actionsRegion(store: PlaybackStateStore?, snapshot: PlaybackSnapshot?,
                               plan: PlayerBarLayoutPlan) -> some View {
        HStack(spacing: Self.actionSpacing) {
            if plan.isInline(.mode) { modeButton(store: store, snapshot: snapshot) }
            if plan.isInline(.pauseAfterCurrent) { pauseAfterCurrentButton(store: store, snapshot: snapshot) }
            if plan.isInline(.favorite), let library = appState.libraryViewModel {
                libraryActions(library, placement: .inlineFavorite, snapshot: snapshot)
            }
            if plan.isInline(.addToPlaylist), let library = appState.libraryViewModel {
                libraryActions(library, placement: .inlinePlaylist, snapshot: snapshot)
            }
            if plan.isInline(.floatingLyrics) { floatingLyricsButton }
            // 队列恒内联：它是打开真实队列列表的唯一入口。
            queueButton
            if plan.isInline(.volume) { volumeControl(store: store, snapshot: snapshot) }
            // 「更多」只在确有控件被收起时才出现 —— 它是一个溢出容器，不是常驻入口。
            // 宽窗下所有控件都已内联，此时若还留着，用户点开只会看到音频信息，
            // 既占位置又让人误以为漏了什么（用户反馈的第 3 点）。
            if !plan.collapsed.isEmpty {
                moreMenu(store: store, snapshot: snapshot, plan: plan)
            }
        }
        .font(typography.playerFont(scaledFromBase: 17))
    }

    /// 右侧图标的统一间距；与统一按钮尺寸一起保证「大小相等、间隔相等」。
    static let actionSpacing: CGFloat = 14
    /// 右侧图标按钮的统一触达尺寸。所有图标都被撑到这个正方形里居中，
    /// 因此按钮大小一致、图标也各自在自己的交互区域正中央（用户反馈的第 4 点）。
    static let actionButtonSize: CGFloat = 26

    /// 把「收藏 / 加入歌单」的渲染交给持有 @ObservedObject LibraryViewModel 的子视图。
    ///
    /// 为什么必须独立子视图：收藏状态与歌单列表都在 LibraryViewModel 里（@Published），
    /// 而本栏只订阅 AppState。暂停或没有进度事件时，点收藏或新建歌单后 LibraryViewModel 的变化
    /// 不会冒泡到本栏，按钮/菜单不会刷新（与歌词行同一个坑）。子视图观察 LibraryViewModel 自身即可覆盖。
    private func libraryActions(_ library: LibraryViewModel, placement: PlayerBarLibraryActions.Placement,
                                snapshot: PlaybackSnapshot?) -> some View {
        PlayerBarLibraryActions(
            library: library,
            track: snapshot?.currentTrack,
            placement: placement,
            onToggleFavorite: { toggleFavorite(snapshot) },
            onAddToPlaylist: { addToPlaylist($0, snapshot: snapshot) },
            onNewPlaylist: { isCreatingPlaylist = true }
        )
    }

    // MARK: - 播完当前曲暂停

    /// 开关式按钮：开启后本曲自然播完停在当前曲（一次性）。图标在开启时高亮以表达状态。
    private func pauseAfterCurrentButton(store: PlaybackStateStore?, snapshot: PlaybackSnapshot?) -> some View {
        let enabled = snapshot?.pauseAfterCurrent ?? false
        return Button {
            store?.setPauseAfterCurrent(!enabled)
        } label: {
            Image(systemName: enabled ? "pause.circle.fill" : "pause.circle")
                .foregroundStyle(enabled ? Color.accentColor : Color.primary)
                .frame(width: Self.actionButtonSize, height: Self.actionButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(snapshot?.currentTrack == nil)
        .help(enabled ? "已开启：播完当前曲暂停（点击取消）" : "播完当前曲后暂停")
        .accessibilityLabel("播完当前曲暂停")
        .accessibilityValue(enabled ? "已开启" : "已关闭")
    }

    // MARK: - 模式

    /// 一个按钮循环切换四种播放模式，图标随当前模式变化。
    private func modeButton(store: PlaybackStateStore?, snapshot: PlaybackSnapshot?) -> some View {
        let mode = snapshot?.queue.mode ?? .sequential
        return Button {
            store?.setMode(nextMode(after: mode))
        } label: {
            Image(systemName: Self.modeSymbol(mode))
                .frame(width: Self.actionButtonSize, height: Self.actionButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("\(Self.modeTitle(mode))（点击切换播放模式）")
        .accessibilityLabel("播放模式")
        .accessibilityValue(Self.modeTitle(mode))
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

    // MARK: - 桌面悬浮歌词

    private var floatingLyricsButton: some View {
        Button { appState.toggleFloatingLyrics() } label: {
            Image(systemName: "text.bubble")
                .frame(width: Self.actionButtonSize, height: Self.actionButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(appState.lyricsViewModel == nil)
        .help("桌面悬浮歌词")
        .accessibilityLabel("桌面悬浮歌词")
    }

    // MARK: - 队列

    /// 队列按钮：就地弹出真实当前队列（不跳媒体库）。
    private var queueButton: some View {
        Button { isQueuePresented.toggle() } label: {
            Image(systemName: "music.note.list")
                .frame(width: Self.actionButtonSize, height: Self.actionButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
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

    private func volumeControl(store: PlaybackStateStore?, snapshot: PlaybackSnapshot?) -> some View {
        VolumeSlider(value: snapshot?.volume ?? 0) { committed in
            store?.setVolume(committed)
        }
    }

    static func volumeSymbol(_ volume: Double) -> String {
        if volume <= 0.5 { return "speaker.slash" }
        if volume < 34 { return "speaker" }
        if volume < 67 { return "speaker.wave.1" }
        return "speaker.wave.2"
    }

    // MARK: - 更多菜单（仅承载被收起的控件）

    /// 「更多」是**溢出容器**：只有 `plan.collapsed` 非空时才会被渲染（见 actionsRegion）。
    ///
    /// 这里刻意不再放音频信息 —— 音频规格已经并进主行的歌曲数据行，
    /// 让这个按钮只表示「还有控件被收起了」，点开看到的就是那些控件（用户反馈的第 3 点）。
    private func moreMenu(store: PlaybackStateStore?, snapshot: PlaybackSnapshot?,
                          plan: PlayerBarLayoutPlan) -> some View {
        Menu {
            if plan.collapsed.contains(.mode) {
                Menu("播放模式") {
                    // PlaybackMode 只声明了 Equatable（raw string 枚举不会自动获得 Hashable），
                    // 因此这里用 rawValue 做稳定标识，而不是 id: \.self。
                    ForEach(PlaybackMode.allCases, id: \.rawValue) { mode in
                        Button {
                            store?.setMode(mode)
                        } label: {
                            Label(Self.modeTitle(mode),
                                  systemImage: snapshot?.queue.mode == mode ? "checkmark" : Self.modeSymbol(mode))
                        }
                    }
                }
                Divider()
            }
            if plan.collapsed.contains(.pauseAfterCurrent) {
                Button(snapshot?.pauseAfterCurrent == true ? "取消：播完当前曲暂停" : "播完当前曲暂停") {
                    store?.setPauseAfterCurrent(!(snapshot?.pauseAfterCurrent ?? false))
                }
                .disabled(snapshot?.currentTrack == nil)
            }
            if plan.collapsed.contains(.favorite), let library = appState.libraryViewModel {
                libraryActions(library, placement: .menuFavorite, snapshot: snapshot)
            }
            if plan.collapsed.contains(.addToPlaylist), let library = appState.libraryViewModel {
                libraryActions(library, placement: .menuPlaylist, snapshot: snapshot)
            }
            if plan.collapsed.contains(.floatingLyrics) {
                Button("桌面悬浮歌词") { appState.toggleFloatingLyrics() }
                    .disabled(appState.lyricsViewModel == nil)
            }
            if plan.collapsed.contains(.volume) {
                Divider()
                // 菜单项是按钮，不能承载滑杆；点这一项后由外层 Menu 的 popover 弹出真正的音量滑杆
                // （锚在更多按钮上，菜单关闭后出现，比把 popover 挂在菜单项上稳定）。
                Button("音量…（\(Int((snapshot?.volume ?? 0).rounded()))）") { isMenuVolumePresented = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: Self.actionButtonSize, height: Self.actionButtonSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多：显示放不下的控件")
        .accessibilityLabel("更多")
        .popover(isPresented: $isMenuVolumePresented, arrowEdge: .bottom) {
            VolumeSliderPopover(value: snapshot?.volume ?? 0) { committed in
                store?.setVolume(committed)
            }
        }
    }

    // MARK: - 收藏 / 歌单动作（本地走库，在线先入库）

    /// 切换当前曲收藏。本地曲走库内切换；在线歌走「先入库再收藏」。
    private func toggleFavorite(_ snapshot: PlaybackSnapshot?) {
        guard let library = appState.libraryViewModel else { return }
        switch CurrentTrackLibraryActions.target(for: snapshot?.currentTrack, libraryTracks: library.tracks) {
        case .library(let item):
            library.toggleFavorite(item)
        case .online(let song):
            appState.syncViewModel?.addToLibrary(song, favorite: true)
        case nil:
            break
        }
    }

    /// 把当前曲加入某歌单。本地曲直接入单；在线歌先入库再带上歌单 id。
    private func addToPlaylist(_ playlist: PlaylistInfo, snapshot: PlaybackSnapshot?) {
        guard let library = appState.libraryViewModel else { return }
        switch CurrentTrackLibraryActions.target(for: snapshot?.currentTrack, libraryTracks: library.tracks) {
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
            // 菜单项写「取消收藏」而不是「已收藏」，让文案直接说明点击后的动作。
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
                .frame(width: FloatingPlayerBar.actionButtonSize, height: FloatingPlayerBar.actionButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!isActionable)
        .help(isFavorited ? "取消收藏" : "添加到收藏")
        .accessibilityLabel(isFavorited ? "取消收藏" : "添加到收藏")
    }

    /// 「加入歌单」：用 `.menuIndicator(.hidden)` 去掉下拉箭头。
    ///
    /// 箭头会让 Menu 比普通按钮宽出一截（用户反馈的第 2 点「按钮太长」），
    /// 图标也会因为箭头占位而偏左、不在交互区中央（第 4 点）。
    /// 隐藏箭头后它与其余图标按钮同宽同高，点击仍照常弹菜单。
    private var playlistMenu: some View {
        Menu { playlistItems } label: {
            Image(systemName: "text.badge.plus")
                .frame(width: FloatingPlayerBar.actionButtonSize, height: FloatingPlayerBar.actionButtonSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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

// MARK: - 音量滑杆（提交式，无离散刻度）

/// 应用音量滑杆：拖动时本地跟手，松开（提交）时一次性写回 store。
///
/// 两个要点：
///   1) **不设 step**。用户反馈过带 step 的滑杆会产生几十个刻度并造成每次拖动都重建/刷新；
///      这里用连续区间，拖动是本视图内部状态，只在松开时提交一次，避免拖动过程中反复触发内核 I/O。
///   2) 松手提交而非实时提交：setVolume 每次都下发引擎并发布快照，实时提交会让拖动产生大量发布。
///      暂停期间切歌等场景不需要实时音量，提交式已足够且更稳。
///
/// 宽度是算过的：右区在最宽档下要同时放下 8 个按钮，音量控件（图标 22 + 数字 24 + 滑杆 84 + 间距 12
/// = 142）加上其余 7 个按钮与间距刚好不超过左右等宽区，否则右侧内容会把窗口撑宽。
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
            .frame(width: 84)
            .controlSize(.small)
            .help("应用音量（\(Int(draft.rounded()))）")
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

/// 曲目信息里的当前歌词行。作为独立子视图持有 @ObservedObject LyricsViewModel：
/// 播放进行时虽然 store 进度会顺带刷新外层，但暂停、歌词异步加载完成这两类时刻没有进度事件，
/// 外层不会重绘；这里订阅 model 自身的变化即可覆盖。
///
/// 字号走统一字体接口的「底部歌词字号」（compactLyricsSize），并套用用户选择的歌词字体，
/// 因此外观页调这一项时本行即时跟随。
private struct PlayerBarLyricLine: View {
    @ObservedObject var model: LyricsViewModel
    @Environment(\.appTypography) private var typography
    /// 期望对应的当前曲目 id：与 model 内快照不一致（model 尚未切到新曲）时显示占位。
    let trackID: UUID?

    var body: some View {
        let text = lyricText
        Text(text)
            .font(typography.lyricFont(size: typography.compactLyricsSize, weight: .semibold))
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
