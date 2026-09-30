// NowPlayingController.swift
// NeriPlayer macOS —— 媒体键与 Now Playing 集成（移植规划 M1-T6）。
//
// 职责：把 M1-T5 的播放内存态（PlaybackStateStore）接到系统媒体层两端 ——
//   1) 远程命令：MPRemoteCommandCenter 的 play / pause / togglePlayPause / nextTrack /
//      previousTrack / changePlaybackPosition 六类命令注册到本类，转发成对 store 的调用；
//   2) 状态回填：订阅 store 的快照流，把当前曲目/时长/进度/播放速率写进
//      MPNowPlayingInfoCenter，控制中心与媒体键界面据此显示。
//
// 为什么命令侧用「注入的闭包集」（NowPlayingCommands）而不是直接持有 PlaybackStateStore：
//   MPRemoteCommandCenter 的回调由系统触发，测试进程无法主动调用已注册的 handler，
//   所以「注册是否真的发生」「事件参数是否原样转发」只有在注册入口可替换时才可断言。
//   把 registrar（注册后端）与 publisher（信息后端）抽象成协议，生产路径分别落到
//   MPRemoteCommandCenter.shared() / MPNowPlayingInfoCenter.default()，
//   测试路径落到假实现；命令语义本身则收在 NowPlayingCommands 的闭包里，
//   由 NowPlayingCommands.playbackStore(_:) 一处绑定到 PlaybackStateStore，
//   使 Core 层不硬依赖 store 具体类型（M8 菜单栏、后续 Now Playing 面板可复用同一套命令）。
//
// 节流（为什么需要）：libmpv 的 time-pos 约每 0.2–0.5s 推一次，若每次都快照全量回填，
// 进程会被无谓的跨进程信息更新拖住；而系统本就用 ElapsedPlaybackTime + PlaybackRate
// 自行外推进度，所以位置类更新按「≥ minimumUpdateInterval（默认 0.5s）」节流不会让
// 控制中心进度条停滞。判据分两类：
//   - 关键字段变化（曲目 id/标题/歌手/时长/暂停/空闲）→ 立即发布，绝不延迟；
//   - 仅进度变化 → 距上次发布满 0.5s 才发布。
// 判定抽成纯值类型 NowPlayingUpdateThrottle，可注入时钟，因此节流逻辑可确定性单测。
//
// 线程模型：与 M1-T5 一致 —— NSLock 串行化 commands/throttle/subscription 状态；
// 命令回调由系统线程触发，回调内只读取闭包并转发，不做阻塞。
// setup/stop 涉及 MediaPlayer 全局对象，约定由主线程调用（SwiftUI 的 .task 即主线程）。
//
// 边界（不做）：菜单栏 / 控制中心自绘控件（M8）、Dock 菜单、专辑封面（M6/M7）、
// 播放速率与循环模式命令（本阶段只要求六类）、播放队列持久化（M3）。

import AppKit
import Foundation
import MediaPlayer

// MARK: - 命令种类

/// 本任务注册的六类远程命令。rawValue 仅用于日志与调试。
public enum NowPlayingCommand: String, CaseIterable, Sendable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
    case seekPosition
}

// MARK: - 命令回调集

/// 六类命令的回调集合。返回 true 表示本次命令已被处理（映射为 .success），
/// false 表示当前没有可作用的内容（映射为 .noActionableNowPlayingItem）。
public struct NowPlayingCommands: Sendable {

    public var play: @Sendable () -> Bool
    public var pause: @Sendable () -> Bool
    public var togglePlayPause: @Sendable () -> Bool
    public var nextTrack: @Sendable () -> Bool
    public var previousTrack: @Sendable () -> Bool
    public var seekPosition: @Sendable (Double) -> Bool

    public init(
        play: @escaping @Sendable () -> Bool,
        pause: @escaping @Sendable () -> Bool,
        togglePlayPause: @escaping @Sendable () -> Bool,
        nextTrack: @escaping @Sendable () -> Bool,
        previousTrack: @escaping @Sendable () -> Bool,
        seekPosition: @escaping @Sendable (Double) -> Bool
    ) {
        self.play = play
        self.pause = pause
        self.togglePlayPause = togglePlayPause
        self.nextTrack = nextTrack
        self.previousTrack = previousTrack
        self.seekPosition = seekPosition
    }
}

public extension NowPlayingCommands {

    /// 把命令绑定到 PlaybackStateStore（生产路径）。语义映射：
    ///   - play：已暂停或内核空闲时恢复播放（空闲态由 store 重新加载队列当前曲）；
    ///   - pause：播放中才暂停，已在暂停或空闲时视为不可用（返回 false）；
    ///   - togglePlayPause：队列当前曲存在即可切换（空闲态同样走「重新加载并播放」）；
    ///   - nextTrack / previousTrack：队列非空才动作（顺序模式末尾由 store 决定是否回卷）；
    ///   - seekPosition：按传入秒数跳转，负值钳到 0，已知时长则上限钳到时长。
    static func playbackStore(_ store: PlaybackStateStore) -> NowPlayingCommands {
        NowPlayingCommands(
            play: {
                let snapshot = store.snapshot
                guard snapshot.currentTrack != nil else { return false }
                if snapshot.isPaused || !store.hasLoadedFile {
                    store.togglePlayPause()
                }
                return true
            },
            pause: {
                let snapshot = store.snapshot
                guard snapshot.currentTrack != nil, !snapshot.isPaused, store.hasLoadedFile else {
                    return false
                }
                store.togglePlayPause()
                return true
            },
            togglePlayPause: {
                guard store.currentTrack != nil else { return false }
                store.togglePlayPause()
                return true
            },
            nextTrack: {
                guard !store.queueState.isEmpty else { return false }
                store.next()
                return true
            },
            previousTrack: {
                guard !store.queueState.isEmpty else { return false }
                store.previous()
                return true
            },
            seekPosition: { position in
                let snapshot = store.snapshot
                guard snapshot.currentTrack != nil, store.hasLoadedFile, position.isFinite else { return false }
                let lowerBounded = max(position, 0)
                let target = snapshot.duration > 0 ? min(lowerBounded, snapshot.duration) : lowerBounded
                store.seek(to: target)
                return true
            }
        )
    }
}

// MARK: - 注册 / 发布后端

/// 远程命令注册后端。抽成协议是为了让「注册了哪些命令」「事件参数如何转发」可被断言，
/// 生产实现是 SystemNowPlayingCommandRegistrar（MPRemoteCommandCenter.shared）。
public protocol NowPlayingCommandRegistering: AnyObject {

    /// 为某类命令注册 handler；handler 参数为 seek 位置（非 seek 命令为 0）。
    /// - Returns: 可用于注销的令牌，原样交给 removeAllHandlers 清理。
    @discardableResult
    func addHandler(for command: NowPlayingCommand, handler: @escaping @Sendable (Double) -> Bool) -> Any

    /// 注销本后端登记过的全部 handler。
    func removeAllHandlers()
}

/// Now Playing 信息发布后端。生产实现是 SystemNowPlayingInfoPublisher。
public protocol NowPlayingInfoPublishing: AnyObject {

    /// 写入（或置 nil 清空）Now Playing 信息与播放状态。
    func publish(nowPlayingInfo: [String: Any]?, playbackState: MPNowPlayingPlaybackState)
}

/// MPRemoteCommandCenter 的生产实现。
public final class SystemNowPlayingCommandRegistrar: NowPlayingCommandRegistering {

    private let center: MPRemoteCommandCenter
    private var registrations: [(command: MPRemoteCommand, token: Any)] = []

    public init(center: MPRemoteCommandCenter = .shared()) {
        self.center = center
    }

    @discardableResult
    public func addHandler(
        for command: NowPlayingCommand,
        handler: @escaping @Sendable (Double) -> Bool
    ) -> Any {
        let remote = remoteCommand(for: command)
        remote.isEnabled = true
        let token: Any
        if command == .seekPosition {
            // 只有 MPChangePlaybackPositionCommandEvent 带目标位置，需按事件类型取 positionTime。
            token = remote.addTarget { event in
                let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
                return Self.status(handler(position))
            }
        } else {
            token = remote.addTarget { _ in Self.status(handler(0)) }
        }
        registrations.append((remote, token))
        return token
    }

    public func removeAllHandlers() {
        for registration in registrations {
            registration.command.removeTarget(registration.token)
        }
        registrations.removeAll()
    }

    private func remoteCommand(for command: NowPlayingCommand) -> MPRemoteCommand {
        switch command {
        case .play: return center.playCommand
        case .pause: return center.pauseCommand
        case .togglePlayPause: return center.togglePlayPauseCommand
        case .nextTrack: return center.nextTrackCommand
        case .previousTrack: return center.previousTrackCommand
        case .seekPosition: return center.changePlaybackPositionCommand
        }
    }

    /// 闭包返回的 Bool 映射为系统状态：已处理 → .success，无内容可作用 → .noActionableNowPlayingItem。
    private static func status(_ handled: Bool) -> MPRemoteCommandHandlerStatus {
        handled ? .success : .noActionableNowPlayingItem
    }
}

/// MPNowPlayingInfoCenter 的生产实现。
public final class SystemNowPlayingInfoPublisher: NowPlayingInfoPublishing {

    public init() {}

    public func publish(nowPlayingInfo: [String: Any]?, playbackState: MPNowPlayingPlaybackState) {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nowPlayingInfo
        // macOS 上播放状态无法由音频会话推断，必须每次开始/暂停时显式写入。
        center.playbackState = playbackState
    }
}

// MARK: - Now Playing 信息

/// 从 PlaybackSnapshot 生成的 Now Playing 信息。除五个要回填的字段外，
/// 另存 trackID 与 isCoreIdle：前者用于节流判定「是否换曲」（相同标题/歌手的两首歌也能区分），
/// 后者用于把播放状态映射成 .stopped / .paused / .playing；两者都不进入信息字典。
public struct NowPlayingInfo: Equatable, Sendable {

    public var trackID: UUID?
    public var title: String
    public var artist: String?
    public var duration: Double
    public var elapsed: Double
    public var isPaused: Bool
    public var isCoreIdle: Bool

    /// 完整构造。生产路径用 init?(snapshot:)；本初始化器供调用方直接构造
    /// （例如只改少数字段的局部更新），并使节流逻辑可独立测试。
    public init(
        trackID: UUID?,
        title: String,
        artist: String?,
        duration: Double,
        elapsed: Double,
        isPaused: Bool,
        isCoreIdle: Bool
    ) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.duration = duration
        self.elapsed = elapsed
        self.isPaused = isPaused
        self.isCoreIdle = isCoreIdle
    }

    /// 从快照生成；队列当前曲为空（含初始态与已清空队列）时返回 nil，表示应清空 Now Playing。
    public init?(snapshot: PlaybackSnapshot) {
        guard let track = snapshot.currentTrack else { return nil }
        // 时长优先取引擎实读值（更可信），未就绪时回落到队列元数据。
        let resolvedDuration = snapshot.duration > 0 ? snapshot.duration : (track.duration ?? 0)
        self.init(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            duration: resolvedDuration,
            elapsed: snapshot.position,
            isPaused: snapshot.isPaused,
            isCoreIdle: snapshot.isCoreIdle
        )
    }

    /// 播放速率：播放中为 1，暂停或空闲为 0（系统据此冻结进度外推）。
    public var playbackRate: Double {
        isPaused || isCoreIdle ? 0 : 1
    }

    /// 系统播放状态（macOS 必须显式设置）。
    public var playbackState: MPNowPlayingPlaybackState {
        if isPaused { return .paused }
        return isCoreIdle ? .stopped : .playing
    }

    /// 回填给 MPNowPlayingInfoCenter 的字典：任务要求的五个键，歌手缺失时不写入空串。
    public var nowPlayingInfoDictionary: [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate
        ]
        if let artist, !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }
        return info
    }

    /// 节流判定用：这些字段任一变化都必须立即发布（对用户可见的状态跳变）。
    /// elapsed 刻意不在其中 —— 它由时间窗口控制发布频率。
    func hasSameThrottleKey(as other: NowPlayingInfo) -> Bool {
        trackID == other.trackID
            && title == other.title
            && artist == other.artist
            && duration == other.duration
            && isPaused == other.isPaused
            && isCoreIdle == other.isCoreIdle
    }
}

// MARK: - 节流

/// Now Playing 更新节流判定。纯值类型 + 注入时钟，行为可确定性单测。
public struct NowPlayingUpdateThrottle: Sendable {

    /// 仅进度变化时两次发布的最小间隔（秒）。
    public let minimumInterval: TimeInterval
    private var lastInfo: NowPlayingInfo?
    private var lastPublishedAt: Date?

    public init(minimumInterval: TimeInterval = 0.5) {
        self.minimumInterval = minimumInterval
    }

    /// 判定是否应发布，并在判定为「发布」时记录本次发布。
    /// - 首次发布（无历史）→ 发布；
    /// - 关键字段变化 → 立即发布（不受时间窗口限制）；
    /// - 仅进度变化 → 距上次发布满 minimumInterval 才发布；
    /// - 完全无变化 → 跳过。
    public mutating func shouldPublish(_ info: NowPlayingInfo, at now: Date) -> Bool {
        let decision: Bool
        if let lastInfo, let lastAt = lastPublishedAt {
            if !info.hasSameThrottleKey(as: lastInfo) {
                decision = true
            } else if info.elapsed == lastInfo.elapsed {
                decision = false
            } else {
                decision = now.timeIntervalSince(lastAt) >= minimumInterval
            }
        } else {
            decision = true
        }
        if decision {
            lastInfo = info
            lastPublishedAt = now
        }
        return decision
    }
}

// MARK: - 控制器

/// 媒体键与 Now Playing 控制器。
///
/// 典型用法（应用启动时，主线程）：
///   let controller = NowPlayingController()
///   controller.attach(to: playbackStore)     // 注册六类命令 + 订阅快照流
///   ... 退出时 controller.stop()              // 注销命令并清空 Now Playing
public final class NowPlayingController: @unchecked Sendable {

    /// 保护 commandsValue / throttle / subscription / isActiveValue。
    private let lock = NSLock()
    private var commandsValue: NowPlayingCommands?
    private var throttle: NowPlayingUpdateThrottle
    private var subscription: Task<Void, Never>?
    private var isActiveValue = false

    private let registrar: any NowPlayingCommandRegistering
    private let publisher: any NowPlayingInfoPublishing
    private let minimumUpdateInterval: TimeInterval
    private let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - registrar: 命令注册后端；默认接 MPRemoteCommandCenter。
    ///   - publisher: Now Playing 信息后端；默认接 MPNowPlayingInfoCenter。
    ///   - minimumUpdateInterval: 仅进度变化时的最小发布间隔（秒），默认 0.5。
    ///   - clock: 取当前时间；注入假时钟即可在测试中确定性验证节流窗口。
    public init(
        registrar: any NowPlayingCommandRegistering = SystemNowPlayingCommandRegistrar(),
        publisher: any NowPlayingInfoPublishing = SystemNowPlayingInfoPublisher(),
        minimumUpdateInterval: TimeInterval = 0.5,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registrar = registrar
        self.publisher = publisher
        self.minimumUpdateInterval = minimumUpdateInterval
        self.clock = clock
        throttle = NowPlayingUpdateThrottle(minimumInterval: minimumUpdateInterval)
    }

    deinit {
        subscription?.cancel()
        registrar.removeAllHandlers()
        publisher.publish(nowPlayingInfo: nil, playbackState: .stopped)
    }

    /// 是否已注册命令（attach/setup 之后为 true，stop 之后为 false）。
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActiveValue
    }

    // MARK: 命令注册

    /// 注册六类远程命令。重复调用会先注销上一批 handler，避免重复触发。
    /// 约定由主线程调用（MediaPlayer 全局对象的配置惯例）。
    public func setup(commands: NowPlayingCommands) {
        lock.lock()
        commandsValue = commands
        lock.unlock()

        registrar.removeAllHandlers()
        for command in NowPlayingCommand.allCases {
            registrar.addHandler(for: command) { [weak self] position in
                self?.handle(command, position: position) ?? false
            }
        }

        lock.lock()
        isActiveValue = true
        lock.unlock()
    }

    // MARK: 信息更新

    /// 发布一次 Now Playing 信息（受节流约束）。传 nil 表示清空（不受节流限制，
    /// 因为「没有当前曲」是必须立刻反映的可见变化）。
    public func update(info: NowPlayingInfo?) {
        guard let info else {
            publishCleared()
            return
        }
        let now = clock()
        lock.lock()
        let shouldPublish = throttle.shouldPublish(info, at: now)
        lock.unlock()
        guard shouldPublish else { return }
        publisher.publish(nowPlayingInfo: info.nowPlayingInfoDictionary, playbackState: info.playbackState)
    }

    /// 从播放快照生成信息并发布（订阅路径的入口）。
    public func update(from snapshot: PlaybackSnapshot) {
        update(info: NowPlayingInfo(snapshot: snapshot))
    }

    // MARK: 接入与清理

    /// 接入播放内存态：注册命令并订阅快照流持续回填。
    /// 订阅任务弱引用本类，随本类释放自动停止。
    @discardableResult
    public func attach(to store: PlaybackStateStore) -> NowPlayingController {
        setup(commands: .playbackStore(store))

        let stream = store.observeState()
        let task = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                self.update(from: snapshot)
            }
        }
        lock.lock()
        subscription?.cancel()
        subscription = task
        lock.unlock()
        return self
    }

    /// 停止：注销命令、取消订阅、清空 Now Playing，并复位节流（下次接入立即发布首帧）。
    /// 幂等；可与 attach 交替调用。
    public func stop() {
        lock.lock()
        isActiveValue = false
        subscription?.cancel()
        subscription = nil
        commandsValue = nil
        throttle = NowPlayingUpdateThrottle(minimumInterval: minimumUpdateInterval)
        lock.unlock()

        registrar.removeAllHandlers()
        publishCleared()
    }

    // MARK: 内部

    /// 转发一次远程命令到当前闭包集。锁内只取出闭包，调用在锁外。
    private func handle(_ command: NowPlayingCommand, position: Double) -> Bool {
        lock.lock()
        let commands = commandsValue
        lock.unlock()
        guard let commands else { return false }
        switch command {
        case .play: return commands.play()
        case .pause: return commands.pause()
        case .togglePlayPause: return commands.togglePlayPause()
        case .nextTrack: return commands.nextTrack()
        case .previousTrack: return commands.previousTrack()
        case .seekPosition: return commands.seekPosition(position)
        }
    }

    private func publishCleared() {
        publisher.publish(nowPlayingInfo: nil, playbackState: .stopped)
    }
}
