// AppState.swift
// M0-T4：应用级运行状态。承载「安全模式」标记与（M1-T6 起）播放集成句柄。
//
// M1-T6 接入点选择：为什么放在 AppState 而不是直接写在 NeriPlayerApp 里 ——
//   1) 生命周期需要一个「跨视图存活」的持有者。AppState 由 App 结构体的 @StateObject 持有，
//      与进程同寿；写在 body 的视图里会随窗口重建而反复创建/销毁。
//   2) App 结构体是值类型，SwiftUI 会在任意时机重建它，字段只作为初值使用；
//      把 PlaybackStateStore / NowPlayingController 这样的引用类型挂上去
//      语义上不安全（可能被复制语义掩盖、也不利于在退出钩子里取回同一实例）。
//   3) AppState 已经在启动路径上（.task 里调 detectSafeMode），顺序天然是
//      「先探测崩溃 → 再启动播放集成」，不需要额外的启动协调代码。
// 安全模式读取启动时的异常记录；正常退出后消费，保留诊断文件；
// 播放集成无条件启动（M1 尚无「安全模式下要禁用的功能」，见 M1-T6 报告遗留问题）。
//
// M3-T2：统计写入管道。startPlaybackStats 在播放集成之后启动，订阅 PlaybackStateStore 的
// 快照流累积收听统计，并按切歌 / 会话结束 / 定时 30 秒 / 退出四种时机批量落库。安全模式下
// 不启动这条管道（统计是「记录用户行为」的副作用，安全模式期间不额外写库；播放仍完全可用）。

import AppKit
import Combine
import Foundation

/// 应用运行状态（启动阶段的标记位 + 播放集成句柄）。
public final class AppState: ObservableObject {

    /// 是否处于安全模式（上次异常退出后进入的降级启动）。
    @Published public private(set) var isSafeMode: Bool

    /// 播放内存态（M1-T5）。启动时创建；libmpv 初始化失败时为 nil（降级：媒体键不可用）。
    @Published public private(set) var playbackStore: PlaybackStateStore?
    /// 媒体键与 Now Playing 控制器（M1-T6）。仅随 playbackStore 一起存在。
    private var nowPlaying: NowPlayingController?
    /// M4: one lyrics adapter shared across windows and navigation.
    @Published private(set) var lyricsViewModel: LyricsViewModel?
    @Published private(set) var onlineViewModel: OnlineViewModel?
    @Published private(set) var libraryOnlineModels: [MusicSource: OnlineViewModel] = [:]
    @Published private(set) var homeViewModel: HomeViewModel?
    @Published private(set) var onlinePlayback: OnlinePlaybackCoordinator?
    private var playbackCache: PlaybackAudioCache?
    @Published private(set) var downloadViewModel: DownloadViewModel?
    private var downloadManager: DownloadManager?
    private var downloadStorage: DownloadStorage?
    /// 媒体库视图模型（M2-T5）。启动时打开数据库后创建；打开失败时为 nil。
    @Published private(set) var libraryViewModel: LibraryViewModel?
    /// 设置页视图模型（M3-T5）。只依赖设置存储，启动时必定创建成功。
    ///
    /// 放在 AppState 而不是让设置页自建：根视图要用它来应用主题与强调色，
    /// 两处必须是同一份状态，否则设置页改完主题、根视图不会重绘。
    @Published private(set) var settingsViewModel: SettingsViewModel?
    @Published private(set) var syncViewModel: SyncViewModel?
    @Published private(set) var audioEffectsViewModel: AudioEffectsViewModel?
    @Published private(set) var listenTogetherViewModel: ListenTogetherViewModel?
    let floatingLyricsPanel = FloatingLyricsPanelController()
    private var globalShortcuts: GlobalShortcutManager?
    /// 媒体库数据库连接（M2-T3）。与 libraryViewModel 同生命周期；本对象关闭即释放。
    private var libraryDatabase: DatabaseProvider?
    /// 统计写入管道（M3-T2）。订阅播放快照累积统计，退出时 flush；未启动为 nil。
    private var playbackStats: PlaybackStatsRecorder?
    /// 统计管道专用的数据库连接（M3-T2）。与 playbackStats 同生命周期。
    private var statsDatabase: DatabaseProvider?
    /// 播放现场录制器（M3-T3）。订阅播放快照保存队列/进度/模式；未启动为 nil。
    private var sessionRecorder: PlaybackSessionRecorder?
    /// 现场录制专用的数据库连接（M3-T3）。与 sessionRecorder 同生命周期。
    private var sessionDatabase: DatabaseProvider?
    /// 设置存储（M3-T3 起用于读取「启动是否自动续播」）。
    private let settings: SettingsStore
    private let crashReporter: CrashReporter
    private var startupCrashReport: CrashReport?
    /// 转发子模型的变化，让根窗口的主题和强调色立即更新。
    private var settingsObservation: AnyCancellable?
    /// 应用退出通知观察者；随 AppState 生命周期注销。
    private var terminateObserver: NSObjectProtocol?

    public init(
        isSafeMode: Bool = false,
        settings: SettingsStore = .shared,
        crashReporter: CrashReporter = .shared
    ) {
        self.isSafeMode = isSafeMode
        self.settings = settings
        self.crashReporter = crashReporter
        // 即使播放引擎启动失败，也必须执行应用级退出清理。
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.stopPlaybackIntegration()
            self?.acknowledgeStartupCrash()
        }
    }

    deinit {
        // 兜底：正常路径由 willTerminateNotification 清理；deinit 只做等价收尾，
        // 且刻意不写 @Published 字段（对象销毁过程中无需再发变更通知）。
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        // 退出前最后一道：把内存里没落库的统计写出去（正常路径已由退出通知触发）。
        playbackStats?.stop()
        // 现场同理：兜底保存一份，避免绕过 willTerminate 的退出路径丢现场。
        sessionRecorder?.flushNow(reason: "AppState 释放")
        sessionRecorder?.stop()
        nowPlaying?.stop()
        playbackStore?.stop()
    }

    /// 启动探测：若存在待处理崩溃记录则进入安全模式。
    @discardableResult
    public func detectSafeMode() -> Bool {
        guard crashReporter.hasPendingCrashReport() else { return false }
        startupCrashReport = crashReporter.loadReport()
        isSafeMode = true
        Log.error("pending crash report detected; entering safe mode", to: Log.ui)
        return true
    }

    /// 只在正常退出时消费本次启动时看到的记录，不吞掉本次运行中新产生的异常。
    func acknowledgeStartupCrash() {
        guard let startupCrashReport, crashReporter.loadReport() == startupCrashReport else { return }
        crashReporter.markCrashHandled()
        self.startupCrashReport = nil
    }

    // MARK: - 播放集成（M1-T6）

    /// 打开媒体库数据库并创建视图模型（M2-T5）。幂等：已就绪则直接返回。
    ///
    /// 放在 AppState 的理由与播放集成一致：数据库连接与视图模型都要与进程同寿，
    /// 由 App 结构体的 @StateObject 持有才不会被窗口重建带走。失败只记录日志并保持 nil，
    /// 媒体库 tab 会回落占位视图，不影响其余功能（与 libmpv 缺失的降级策略一致）。
    @MainActor
    public func startLibrary() {
        guard libraryViewModel == nil else { return }
        do {
            let database = try DatabaseProvider()
            try database.setupIfNeeded()
            libraryDatabase = database
            libraryViewModel = LibraryViewModel(database: database)
            Log.db.info("媒体库已就绪：\(database.databaseURL.path, privacy: .public)")
        } catch {
            Log.db.error("媒体库初始化失败（媒体库 tab 不可用）：\(error.localizedDescription)")
        }
    }

    /// 启动播放集成：创建 PlaybackStateStore，接入媒体键与 Now Playing，并挂上退出清理。
    /// 幂等：已启动则直接返回。创建失败（如 libmpv 缺失）只记录日志，不改安全模式。
    public func startPlaybackIntegration() {
        guard playbackStore == nil, nowPlaying == nil else { return }
        do {
            let store = try PlaybackStateStore()
            playbackStore = store
            nowPlaying = NowPlayingController().attach(to: store)
            globalShortcuts = GlobalShortcutManager(
                play: { [weak store] in store?.togglePlayPause() },
                pause: { [weak store] in store?.togglePlayPause() },
                next: { [weak store] in store?.next(force: true) },
                previous: { [weak store] in store?.previous() }
            )
            globalShortcuts?.start()
            Log.player.info("播放集成已启动：媒体键、Now Playing 与快捷键已接入")
        } catch {
            Log.player.error("播放集成启动失败（媒体键与 Now Playing 不可用）：\(error.localizedDescription)")
        }
    }

    /// 清理播放集成：注销媒体键命令、停止快照订阅、清空 Now Playing。
    /// 幂等，可重复调用（退出通知与 deinit 都会走这里）。
    public func stopPlaybackIntegration() {
        // 顺序关键：现场必须趁 store 还在、快照还有值时落库。等 store.stop() 之后再来读，
        // 队列与进度都已经被清空，写下去的会是一份「空现场」，重启后什么都恢复不了。
        sessionRecorder?.flushNow(reason: "应用退出")
        sessionRecorder?.stop()
        sessionRecorder = nil
        sessionDatabase = nil

        // 统计管道同理：stop() 会把内存里没落库的那段收听写出去。
        playbackStats?.stop()
        playbackStats = nil
        statsDatabase = nil

        if let model = onlineViewModel {
            onlineViewModel = nil
            Task { @MainActor in model.stop() }
        }
        let libraryModels = Array(libraryOnlineModels.values)
        libraryOnlineModels = [:]
        Task { @MainActor in libraryModels.forEach { $0.stop() } }
        if let model = homeViewModel {
            homeViewModel = nil
            Task { @MainActor in model.stop() }
        }
        if let coordinator = onlinePlayback {
            onlinePlayback = nil
            Task { @MainActor in coordinator.stop() }
        }
        playbackCache = nil
        if let manager = downloadManager {
            downloadManager = nil
            downloadViewModel = nil
            Task { try? await manager.stop() }
        }
        downloadStorage = nil
        if let lyrics = lyricsViewModel {
            lyricsViewModel = nil
            Task { @MainActor in lyrics.stop() }
        }
        Task { @MainActor [floatingLyricsPanel] in floatingLyricsPanel.hide() }
        globalShortcuts?.stop()
        globalShortcuts = nil
        guard let store = playbackStore, let nowPlaying else { return }
        nowPlaying.stop()
        store.stop()
        self.nowPlaying = nil
        playbackStore = nil
        Log.player.info("播放集成已清理：媒体键命令已注销，Now Playing 已清空")
    }

    // MARK: - 统计写入管道（M3-T2）

    /// 启动统计写入管道：订阅播放内存态快照，按切歌 / 会话结束 / 定时 30 秒 / 退出四种时机落库。
    ///
    /// 前置：播放集成已启动（playbackStore 非 nil）。幂等：已启动则直接返回。
    /// 安全模式下不启动 —— 统计只是「记录用户行为」的副作用，安全模式期间不额外写库；
    /// 开库失败只记录日志并保持 nil，播放与媒体库功能不受影响。
    public func startPlaybackStats() {
        guard !isSafeMode, playbackStats == nil, let store = playbackStore else { return }
        do {
            // 统计管道与媒体库各持一个 DatabaseProvider：两者都是「一个库文件一个实例」的连接
            // 对象，指向同一个库文件即可，不需要（也不应该）跨模块传递连接。
            let database = try DatabaseProvider()
            try database.setupIfNeeded()
            let handler = PlaybackStatsFlushHandler(database)
            let recorder = PlaybackStatsRecorder(prepareTrack: { track in
                try SyncRepository(database).registerPlaybackTrack(track)
            }, flush: { deltas in try handler.callAsFunction(deltas) })
            recorder.attach(to: store)
            statsDatabase = database
            playbackStats = recorder
            Log.player.info("统计写入管道已就绪：\(database.databaseURL.path, privacy: .public)")
        } catch {
            Log.player.error("统计写入管道启动失败（统计不落库，播放不受影响）：\(error.localizedDescription)")
        }
    }

    // MARK: - 播放现场（M3-T3）

    /// 启动播放现场：先把上次退出的现场恢复到播放内存态，再开始录制新的变化。
    ///
    /// 前置：播放集成已启动（playbackStore 非 nil）。幂等：已启动则直接返回。
    /// 安全模式下不启动 —— 与统计管道同一条理由（安全模式期间不额外读写库），
    /// 此时应用表现为「每次都从空队列开始」，这是可接受的降级。
    ///
    /// 顺序为什么不能反：录制器一订阅就会收到一次当前快照。若先订阅再恢复，那次「空队列」
    /// 快照会被判成「用户清空了现场」而把刚读出来的行删掉 —— 现场只能在恢复之后才开始录制。
    public func startPlaybackSession() {
        guard !isSafeMode, sessionRecorder == nil, let store = playbackStore else { return }
        do {
            let database = try DatabaseProvider()
            try database.setupIfNeeded()
            let repository = PlayerStateRepository(database)

            if let saved = try repository.load() {
                store.restore(saved, resumePlayback: shouldResumePlayback(for: saved))
                Log.player.info(
                    "已恢复上次播放现场：队列 \(saved.tracks.count) 首，位置 \(Int(saved.position))s，自动续播=\(saved.shouldResumePlayback)"
                )
            }

            let recorder = PlaybackSessionRecorder(
                save: { try repository.save($0) },
                clear: { try repository.clear() }
            )
            recorder.attach(to: store)
            sessionDatabase = database
            sessionRecorder = recorder
            Log.player.info("播放现场录制已就绪：\(database.databaseURL.path, privacy: .public)")
        } catch {
            Log.player.error("播放现场启动失败（不恢复也不记录现场，播放不受影响）：\(error.localizedDescription)")
        }
    }

    /// 恢复现场时是否自动续播：既要退出时确实在播，也要用户开了「启动后继续播放」。
    private func shouldResumePlayback(for saved: PlayerState) -> Bool {
        guard saved.shouldResumePlayback else { return false }
        return settings.value(for: SettingsKeys.resumePlaybackOnLaunch)
    }

    // MARK: - Online sources (M5)

    @MainActor
    func startOnlineSources() {
        guard onlineViewModel == nil else { return }
        let sessions = OnlineSessionStore.shared
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NeriPlayer/YouTubeMusic/bootstrap.json")
        let clients: [any OnlineMusicClient] = [NeteaseClient(sessions: sessions), BilibiliClient(sessions: sessions),
                                                YouTubeMusicClient(sessionStore: sessions, cacheURL: cache)]
        let manager = OnlineSearchManager(clients: clients)
        if let store = playbackStore {
            do {
                if playbackCache == nil {
                    let storage = try DownloadStorage.standard()
                    playbackCache = try PlaybackAudioCache(root: storage.cacheRoot.appendingPathComponent("Playback", isDirectory: true))
                }
                store.setPlaybackCache(playbackCache)
            } catch { Log.net.error("播放缓存初始化失败：\(error.localizedDescription)") }
            onlinePlayback = OnlinePlaybackCoordinator(store: store, resolver: PlaybackResolver(clients: clients), searchManager: manager, cache: playbackCache)
        }
        var pageCache: OnlineContentCache?
        do {
            let database = try DatabaseProvider()
            try database.setupIfNeeded()
            pageCache = OnlineContentCache(database: database)
        } catch { Log.db.error("在线页面缓存初始化失败：\(error.localizedDescription)") }
        let content = OnlineContentRepository(clients: clients, sessions: sessions, cache: pageCache)
        onlineViewModel = OnlineViewModel(clients: clients, sessions: sessions, store: playbackStore, content: content, loadsBrowseContent: false)
        libraryOnlineModels = Dictionary(uniqueKeysWithValues: MusicSource.allCases.map { source in
            let model = OnlineViewModel(clients: clients, sessions: sessions, store: playbackStore, content: content)
            model.configureLibrarySource(source)
            model.loadsRecommendations = false
            return (source, model)
        })
        homeViewModel = HomeViewModel(content: content, sessions: sessions)
    }

    // MARK: - Downloads (M6)

    @MainActor
    func startDownloads() {
        guard downloadViewModel == nil else { return }
        do {
            let storage = try DownloadStorage.standard()
            let cache: PlaybackAudioCache
            if let existing = playbackCache {
                cache = existing
            } else {
                cache = try PlaybackAudioCache(root: storage.cacheRoot.appendingPathComponent("Playback", isDirectory: true))
                playbackCache = cache
            }
            playbackStore?.setPlaybackCache(cache)
            let clients = [NeteaseClient(sessions: .shared), BilibiliClient(sessions: .shared),
                           YouTubeMusicClient(sessionStore: .shared, cacheURL: nil)] as [any OnlineMusicClient]
            let resolver = DownloadResolver(clients: clients)
            let manager = try DownloadManager(storage: storage, resolve: { song in try await resolver.resolve(song) })
            downloadStorage = storage; downloadManager = manager
            downloadViewModel = DownloadViewModel(manager: manager, storage: storage, cache: cache)
        } catch { Log.net.error("下载服务初始化失败：\(error.localizedDescription)") }
    }

    @MainActor
    func enqueueDownload(_ song: SongData) { downloadViewModel?.enqueue(song) }

    // MARK: - 歌词（M4）

    @MainActor
    func startLyrics() {
        guard let store = playbackStore else { return }
        if lyricsViewModel == nil { lyricsViewModel = LyricsViewModel(settings: settings) }
        lyricsViewModel?.attach(to: store)
    }

    // MARK: - M8 desktop commands

    @MainActor
    func handle(url: URL) {
        guard let action = AppURLRouter.action(for: url), let store = playbackStore else { return }
        switch action {
        case .play, .pause: store.togglePlayPause()
        case .next: store.next(force: true)
        case .previous: store.previous()
        }
    }

    @MainActor
    func toggleFloatingLyrics() {
        guard let lyricsViewModel else { return }
        floatingLyricsPanel.toggle(model: lyricsViewModel)
    }

    // MARK: - Audio effects (M8)

    @MainActor
    func startAudioEffects() {
        guard audioEffectsViewModel == nil else { return }
        audioEffectsViewModel = AudioEffectsViewModel(settingsStore: settings) { [weak self] value in
            self?.playbackStore?.applyAudioEffects(value)
        }
        if let value = audioEffectsViewModel?.settings { playbackStore?.applyAudioEffects(value) }
    }

    @MainActor
    func startListenTogether() {
        guard listenTogetherViewModel == nil, let playbackStore else { return }
        listenTogetherViewModel = ListenTogetherViewModel(store: playbackStore)
    }

    // MARK: - Sync and backup (M7)

    @MainActor
    func startSync() {
        guard !isSafeMode, syncViewModel == nil, let database = libraryDatabase else { return }
        syncViewModel = SyncViewModel(database: database, settings: settings,
            beforeCapture: { [weak self] in self?.playbackStats?.flush() },
            beforeRestore: { [weak self] in
                self?.sessionRecorder?.flushNow(reason: "备份恢复前")
                self?.playbackStore?.stop()
                self?.playbackStats?.stop()
                self?.playbackStats = nil
                self?.sessionRecorder?.stop()
                self?.sessionRecorder = nil
            }, afterRestore: { [weak self] in
                self?.startPlaybackStats()
                self?.startPlaybackSession()
            }, refresh: { [weak self] in
                self?.libraryViewModel?.refresh()
                self?.settingsViewModel?.reloadSettings()
            })
    }

    // MARK: - 设置（M3-T5）

    /// 创建设置页视图模型。幂等。
    ///
    /// 重扫描动作注入的是本对象持有的媒体库视图模型：设置页因此不需要知道媒体库的存在，
    /// 两者不会互相强引用。媒体库尚未就绪（开库失败）时注入的动作是空操作，
    /// 此时目录仍可增删，只是不会立刻扫描。
    @MainActor
    public func startSettings() {
        guard settingsViewModel == nil else { return }
        let viewModel = SettingsViewModel(
            settings: settings,
            rescanHandler: { [weak self] url in
                self?.libraryViewModel?.importDirectory(url)
            }
        )
        settingsViewModel = viewModel
        settingsObservation = viewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        applyDefaultVolume()
    }

    /// 把「启动音量」下发给播放引擎。幂等：可重复调用。
    ///
    /// 为什么在设置就绪之后单独下发而不是塞进播放集成启动流程：音量是用户偏好，
    /// 与「引擎能否起来」无关；引擎缺失时这里只是空转，不必让调用方分两种情况。
    @MainActor
    public func applyDefaultVolume() {
        guard let store = playbackStore else { return }
        let volume = PlaybackBehaviorDefaults.clampedVolume(settings.value(for: SettingsKeys.defaultVolume))
        store.setVolume(volume)
        Log.player.info("已应用启动音量：\(Int(volume))")
    }
}
