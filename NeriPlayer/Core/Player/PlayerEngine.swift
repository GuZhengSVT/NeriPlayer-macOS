// PlayerEngine.swift
// NeriPlayer macOS —— 播放引擎抽象与状态类型（移植规划 M1-T3）。
//
// 本文件只声明接口与状态值类型，不含任何 libmpv 细节；libmpv 实现见 MPVEngine.swift。
// 上层依赖：M1-T4 播放队列、M1-T5 内存态 PlaybackStateStore、M1-T6 媒体键都只依赖本协议，
// 使播放内核可替换（例如后续用 AVFoundation 兜底实现同一协议）。
//
// 状态发布为什么选 AsyncStream 而不是 @Published：
//   1) 对齐既有约定：M1-T2 的 MPVController 已经用 AsyncStream 暴露属性变更，
//      引擎沿用同一范式，订阅侧只维护一套消费写法；
//   2) 隔离 UI 依赖：@Published 需要 Combine 且通常绑定 ObservableObject，
//      而引擎属于 Core 层，要被无 UI 的测试与后台逻辑复用；把「面向 UI 的发布」
//      留给 M1-T5 的 PlaybackStateStore（该任务本身就是 @Published/AsyncStream 二选一）；
//   3) 无 Actor 约束：AsyncStream 可在任意执行上下文消费，不必把 Core 层钉在 MainActor 上。
//   发布粒度是「全量状态快照」而非字段增量：快照是小值类型（4 个标量 + 2 个 Bool/URL），
//   订阅者无需自行按字段累积，避免顺序相关的拼接错误。
//
// 边界（M1-T3 不做，由后续任务承担）：
//   - 不做播放队列、上一首/下一首（M1-T4）；
//   - 不做持久化与播放进度落库（M1-T4/M3）；
//   - 不做媒体键（M1-T6）、音频输出设备选择（M1-T7）、音效链路（M1-T8）。

import Foundation

// MARK: - 状态

/// 播放引擎的一次状态快照。字段之间相互独立，因此以整体发布而非字段增量。
public struct PlayerEngineState: Equatable, Sendable {

    /// 当前加载的本地文件；未加载时为 nil。
    public var currentURL: URL?
    /// 是否处于暂停。停止后复位为 false。
    public var isPaused: Bool
    /// 当前播放位置（秒）。未加载或已停止时为 0。
    public var position: Double
    /// 当前文件总时长（秒）。未加载或已停止时为 0。
    public var duration: Double
    /// 解码核心是否空闲。语义为「底层没有正在播放/加载的活动文件」，
    /// libmpv 实现直接映射 core-idle；换后端时映射为「无活动播放会话」即可。
    /// 之所以纳入协议：M1-T2 的 core-idle 是本任务要求桥接的属性之一，
    /// 且上层需要区分「已停止」（idle）与「加载中/播放中」，仅凭 position 无法判断。
    public var isCoreIdle: Bool

    public init(currentURL: URL?, isPaused: Bool, position: Double, duration: Double, isCoreIdle: Bool) {
        self.currentURL = currentURL
        self.isPaused = isPaused
        self.position = position
        self.duration = duration
        self.isCoreIdle = isCoreIdle
    }

    /// 未加载任何内容的初始状态。
    public static let idle = PlayerEngineState(
        currentURL: nil,
        isPaused: false,
        position: 0,
        duration: 0,
        isCoreIdle: true
    )
}

// MARK: - 错误

/// 播放引擎的统一错误类型。刻意与 MPVError 分离：协议层不应暴露 libmpv 的错误码，
/// 换后端时上层代码无需改动；具体后端错误一律通过 `.backend` 透传。
public enum PlayerEngineError: Error {
    /// 传入的不是本地文件 URL（M1 只支持本地文件播放）。
    case unsupportedURL(URL)
    /// 当前没有已加载的项，无法执行播放/跳转。
    case noCurrentItem
    /// 底层引擎（如 libmpv）返回的错误。
    case backend(any Error)
}

extension PlayerEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedURL(let url):
            return "不支持的 URL（M1 仅支持本地文件）：\(url.absoluteString)"
        case .noCurrentItem:
            return "当前没有已加载的播放项"
        case .backend(let error):
            return "底层播放引擎错误：\(error.localizedDescription)"
        }
    }
}

// MARK: - 协议

/// 单文件播放控制接口。
///
/// 约定：
///   - 所有命令方法同步抛出；命令是「下发」语义，不代表文件已可用 ——
///     `load(url:)` 返回时只保证命令已受理，加载完成需借助 `isCoreIdle` 观察；
///   - `currentURL` 在 `load(url:)` 成功后写入，`stop()` 后清空；
///   - 只读属性在任意线程可安全读取，返回最后一次已知的真值快照。
public protocol PlayerEngine: AnyObject, Sendable {

    /// 当前加载的文件；未加载时为 nil。
    var currentURL: URL? { get }
    /// 是否暂停。
    var isPaused: Bool { get }
    /// 当前播放位置（秒）。
    var position: Double { get }
    /// 当前文件总时长（秒）。
    var duration: Double { get }
    /// 解码核心是否空闲（未加载/已停止/已播放到末尾）。
    var isCoreIdle: Bool { get }

    /// 加载并替换当前文件（单文件播放，无队列）。
    func load(url: URL) throws
    /// 开始/继续播放。
    func play() throws
    /// 暂停播放。
    func pause() throws
    /// 停止播放并卸载当前文件，清空 `currentURL`。
    func stop() throws
    /// 跳转到指定位置（绝对秒数）。
    func seek(to seconds: Double) throws
    /// 设置音量（mpv 量程 0–100，可超过 100）。
    func setVolume(_ volume: Double) throws

    /// 订阅状态变更。每次订阅返回一条独立的新流；消费端取消任务时流终止。
    /// 流内容为全量快照，且只在快照真正发生变化时产出。
    func observeState() -> AsyncStream<PlayerEngineState>
}

public extension PlayerEngine {

    /// 由五个只读属性组合出的当前快照，便于上层一次性读取。
    var state: PlayerEngineState {
        PlayerEngineState(
            currentURL: currentURL,
            isPaused: isPaused,
            position: position,
            duration: duration,
            isCoreIdle: isCoreIdle
        )
    }
}
