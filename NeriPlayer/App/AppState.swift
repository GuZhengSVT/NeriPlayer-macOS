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
// 安全模式逻辑保持原样：detectSafeMode 与 CrashState 读取都不做改动；
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
    /// 媒体库视图模型（M2-T5）。启动时打开数据库后创建；打开失败时为 nil。
    @Published private(set) var libraryViewModel: LibraryViewModel?
    /// 媒体库数据库连接（M2-T3）。与 libraryViewModel 同生命周期；本对象关闭即释放。
    private var libraryDatabase: DatabaseProvider?
    /// 统计写入管道（M3-T2）。订阅播放快照累积统计，退出时 flush；未启动为 nil。
    private var playbackStats: PlaybackStatsRecorder?
    /// 统计管道专用的数据库连接（M3-T2）。与 playbackStats 同生命周期。
    private var statsDatabase: DatabaseProvider?
    /// 应用退出通知观察者；stopPlaybackIntegration 时注销。
    private var terminateObserver: NSObjectProtocol?

    public init(isSafeMode: Bool = false) {
        self.isSafeMode = isSafeMode
    }

    deinit {
        // 兜底：正常路径由 willTerminateNotification 清理；deinit 只做等价收尾，
        // 且刻意不写 @Published 字段（对象销毁过程中无需再发变更通知）。
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        // 退出前最后一道：把内存里没落库的统计写出去（正常路径已由退出通知触发）。
        playbackStats?.stop()
        nowPlaying?.stop()
        playbackStore?.stop()
    }

    /// 启动探测：若存在待处理崩溃记录则进入安全模式。
    @discardableResult
    public func detectSafeMode() -> Bool {
        guard CrashState.isSafeModeRequired else { return false }
        isSafeMode = true
        Log.error("pending crash report detected; entering safe mode", to: Log.ui)
        return true
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
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.stopPlaybackIntegration()
            }
            Log.player.info("播放集成已启动：媒体键与 Now Playing 已接入")
        } catch {
            Log.player.error("播放集成启动失败（媒体键与 Now Playing 不可用）：\(error.localizedDescription)")
        }
    }

    /// 清理播放集成：注销媒体键命令、停止快照订阅、清空 Now Playing。
    /// 幂等，可重复调用（退出通知与 deinit 都会走这里）。
    public func stopPlaybackIntegration() {
        guard let store = playbackStore, let nowPlaying else { return }
        nowPlaying.stop()
        store.stop()
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        terminateObserver = nil
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
            let recorder = PlaybackStatsRecorder(flush: { deltas in try handler.callAsFunction(deltas) })
            recorder.attach(to: store)
            statsDatabase = database
            playbackStats = recorder
            Log.player.info("统计写入管道已就绪：\(database.databaseURL.path, privacy: .public)")
        } catch {
            Log.player.error("统计写入管道启动失败（统计不落库，播放不受影响）：\(error.localizedDescription)")
        }
    }
}
