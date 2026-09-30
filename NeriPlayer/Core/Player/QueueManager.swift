// QueueManager.swift
// NeriPlayer macOS —— 播放队列（移植规划 M1-T4）。
//
// 职责：维护「队列内容 + 当前索引 + 播放模式」，并回答两个问题：
//   1) 现在该播哪一首（currentTrack）；
//   2) 上一首/下一首是谁（previous()/next()）。
// 队列是纯内存值逻辑：不落库（M3 处理）、不触碰 MPVEngine/MPVController
// （由 M1-T5 或后续任务把「队列决定播什么」桥接到「引擎去播」）、不做 UI。
//
// 模型：
//   - Track：播放项的最小元数据（URL + 标题/歌手/时长），纯 struct，不建数据库；
//   - PlaybackMode：顺序 / 列表循环 / 单曲循环 / 随机；
//   - QueueState：一次可订阅的完整快照（tracks + currentIndex + mode + shuffleOrder）。
// 之所以发布整体快照而不是字段增量：字段都很小，订阅者不必自己按字段拼装，
// 也就不会因事件顺序产生状态错位（与 MPVEngine/MPVController 的发布范式一致）。
//
// 关键语义决策（详见各方法注释）：
//   - 不变式：currentIndex 为 nil ⟺ 队列为空。顺序模式播到末尾时索引停在最后一首，
//     只是 next() 返回 nil 表示「没有下一首，请停止」，而不是把索引清空；
//   - 移除当前曲：按「列表序号」前进 —— 当前曲被移除后，选中新队列中落到同一序号的那首
//     （即原队列里它的下一首）；若移除的是最后一首，则钳位到新的最后一首；队列清空则 currentIndex 置 nil。
//     该语义与模式无关（随机模式下也按列表序号走，不按洗牌序列走），保持可预测；
//   - 单曲循环：next()/previous() 都返回当前曲、索引不变（重播由引擎执行 load 完成）；
//   - 随机：进入随机模式时用 Fisher–Yates 洗牌，并把当前曲固定在序列首位（不打断正在播的歌，
//     下一首也不是它自己）；之后 next() 沿洗牌序列前进，走到序列末尾时重新洗牌（当前曲仍置首）
//     再继续，从而无感循环；previous() 沿序列后退，到首位则绕到序列末尾；
//   - 清空：只清内容与索引，保留播放模式（模式是用户偏好，不随队列生命周期归零）。
//
// 线程模型：沿用 MPVEngine 的做法 —— 内部状态由 NSLock 串行化，订阅者在各自任务上下文，
// 状态变更一律在锁外 yield。
//
// 边界（不做）：持久化/恢复现场（M3-T3）、与播放引擎的实际桥接（M1-T5）、媒体键（M1-T6）、UI。

import Foundation

// MARK: - 轨道

/// 队列中的一个播放项。最小元数据，既是本地文件（M1）也是后续在线音源的统一载体 ——
/// 只依赖 `url`，标题/歌手/时长缺失时由上层在展示前补全。
public struct Track: Identifiable, Equatable, Hashable, Sendable {

    /// 稳定标识。队列在增删/洗牌时按 id 追踪轨道，而不是按下标（下标会随增删漂移）。
    public let id: UUID
    /// 音源地址。M1 只播本地文件，但类型本身不限本地。
    public var url: URL
    /// 显示标题；未提供时回落到文件名（去掉扩展名）。
    public var title: String
    /// 歌手；未知为 nil。
    public var artist: String?
    /// 时长（秒）；未知为 nil（真实时长以引擎读到的为准）。
    public var duration: Double?
    /// Stable online identity; temporary signed URLs never enter the queue.
    public var onlineSong: SongData?

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String? = nil,
        artist: String? = nil,
        duration: Double? = nil,
        onlineSong: SongData? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.artist = artist
        self.duration = duration
        self.onlineSong = onlineSong
    }
}

// MARK: - 播放模式

/// 队列前进策略。四个 case 覆盖 M1 要求的顺序/列表循环/单曲循环/随机。
public enum PlaybackMode: String, CaseIterable, Equatable, Sendable {

    /// 顺序：next() 走到末尾后返回 nil（停止），不回卷。
    case sequential
    /// 列表循环：next()/previous() 在首尾之间回卷。
    case repeatAll
    /// 单曲循环：next()/previous() 都停在当前曲。
    case repeatOne
    /// 随机：按 Fisher–Yates 洗牌序列前进，序列走完自动重新洗牌。
    case shuffle
}

// MARK: - 状态快照

/// 队列的一次完整快照，用于发布与订阅。
public struct QueueState: Equatable, Sendable {

    /// 队列内容，顺序即「列表顺序」。
    public var tracks: [Track]
    /// 当前索引；nil 当且仅当队列为空。
    public var currentIndex: Int?
    /// 当前播放模式。
    public var mode: PlaybackMode
    /// 随机模式下的播放序列（轨道 id 的排列）；非随机模式为空。
    /// 对外暴露是为了让上层（与测试）能观察「下一首会是谁」；不代表持久化结构。
    public var shuffleOrder: [UUID]

    public init(tracks: [Track], currentIndex: Int?, mode: PlaybackMode, shuffleOrder: [UUID]) {
        self.tracks = tracks
        self.currentIndex = currentIndex
        self.mode = mode
        self.shuffleOrder = shuffleOrder
    }

    /// 当前曲目；空队列为 nil。
    public var currentTrack: Track? {
        guard let index = currentIndex, tracks.indices.contains(index) else { return nil }
        return tracks[index]
    }

    /// 队列是否为空。
    public var isEmpty: Bool { tracks.isEmpty }
    /// 队列长度。
    public var count: Int { tracks.count }

    /// 空队列的初始快照。
    public static let empty = QueueState(tracks: [], currentIndex: nil, mode: .sequential, shuffleOrder: [])
}

// MARK: - 洗牌器

/// 洗牌函数签名：原地重排一组轨道 id。抽成注入点是为了让「随机」在测试里可复现，
/// 同时默认行为仍是真正的随机。
public typealias QueueShuffler = @Sendable (inout [UUID]) -> Void

// MARK: - 队列

/// 播放队列。纯内存、线程安全、可订阅。
public final class QueueManager: @unchecked Sendable {

    /// 保护 stateValue 与 continuations。
    private let lock = NSLock()
    private var stateValue: QueueState = .empty
    private var continuations: [UUID: AsyncStream<QueueState>.Continuation] = [:]
    /// 洗牌实现，默认 Fisher–Yates + 系统随机源。
    private let shuffler: QueueShuffler

    /// - Parameter shuffler: 洗牌实现；传 nil 使用默认的 Fisher–Yates。
    public init(shuffler: QueueShuffler? = nil) {
        self.shuffler = shuffler ?? { ids in QueueManager.shuffleInPlace(&ids) }
    }

    /// Fisher–Yates（Knuth）洗牌：从尾到头，每轮把当前位置与 `[0, i]` 内随机位置交换。
    /// 复杂度 O(n)，每个排列等概率。
    private static func shuffleInPlace(_ ids: inout [UUID]) {
        guard ids.count > 1 else { return }
        var generator = SystemRandomNumberGenerator()
        for index in stride(from: ids.count - 1, through: 1, by: -1) {
            let swapIndex = Int.random(in: 0...index, using: &generator)
            if swapIndex != index {
                ids.swapAt(index, swapIndex)
            }
        }
    }

    // MARK: - 只读状态

    /// 当前完整快照。
    public var state: QueueState {
        lock.lock()
        defer { lock.unlock() }
        return stateValue
    }

    /// 队列内容（列表顺序）。
    public var tracks: [Track] { state.tracks }
    /// 当前索引；空队列为 nil。
    public var currentIndex: Int? { state.currentIndex }
    /// 当前曲目；空队列为 nil。
    public var currentTrack: Track? { state.currentTrack }
    /// 当前播放模式。
    public var mode: PlaybackMode { state.mode }
    /// 队列长度。
    public var count: Int { state.count }
    /// 队列是否为空。
    public var isEmpty: Bool { state.isEmpty }
    /// 随机模式的播放序列；非随机模式为空数组。
    public var shuffleOrder: [UUID] { state.shuffleOrder }

    // MARK: - 入队 / 整批替换

    /// 追加到队尾。空队列时该曲直接成为当前曲（而不是「入队了但没得播」）。
    public func enqueue(_ track: Track) {
        mutate { state in
            state.tracks.append(track)
            if state.currentIndex == nil {
                state.currentIndex = 0
            }
            if state.mode == .shuffle {
                // 随机模式下新曲排到本轮序列末尾，本轮走完自然轮到它。
                state.shuffleOrder.append(track.id)
            }
        }
    }

    /// 插到「当前曲的下一首」位置。空队列时该曲直接成为当前曲。
    public func enqueueNext(_ track: Track) {
        mutate { state in
            guard let current = state.currentIndex else {
                // 空队列：与 enqueue 一致，直接设为当前曲。
                state.tracks = [track]
                state.currentIndex = 0
                state.shuffleOrder = state.mode == .shuffle ? [track.id] : []
                return
            }
            let insertAt = min(current + 1, state.tracks.count)
            state.tracks.insert(track, at: insertAt)
            if state.mode == .shuffle {
                insertIntoShuffleOrder(&state, id: track.id)
            }
        }
    }

    /// 整批替换队列并从 `startAt` 开始播。
    /// - Parameter index: 起始索引；越界会被钳位到有效范围（负数→0，过大→末位）。
    /// - Returns: 即将播放的曲目；空队列为 nil。
    @discardableResult
    public func setQueue(_ tracks: [Track], startAt index: Int = 0) -> Track? {
        var result: Track?
        mutate { state in
            state.tracks = tracks
            if tracks.isEmpty {
                state.currentIndex = nil
            } else {
                state.currentIndex = min(max(index, 0), tracks.count - 1)
            }
            state.shuffleOrder = state.mode == .shuffle ? makeShuffleOrder(state) : []
            result = state.currentTrack
        }
        return result
    }

    /// 恢复现场：整体采纳一个队列快照（移植规划 M3-T3）。
    ///
    /// 与 `setQueue` 的关键区别：`setQueue` 是「用户选了一组歌要开始播」，会按当前模式重新
    /// 生成随机序列；本方法是「把退出时的现场原样搬回来」，必须保留当时已经走过的随机序列 ——
    /// 否则恢复后按「下一首」得到的不是退出前的那一首，用户会感到随机播放被重置了。
    ///
    /// 为什么要做不变式修正：现场来自持久化存储，可能被外部改坏（手工编辑、旧版本写入、
    /// JSON 截断）。这里按 QueueState 的约定把非法输入钳回合法状态，而不是信任它：
    ///   - 空队列 → 索引置 nil（currentIndex 为 nil ⟺ 队列为空）；
    ///   - 非空但索引为 nil 或越界 → 钳位到有效范围；
    ///   - 随机序列与队列不匹配（长度不符或含未知 id）→ 按当前模式重建，保证后续切歌不越界。
    public func restore(_ state: QueueState) {
        mutate { current in
            current.tracks = state.tracks
            if state.tracks.isEmpty {
                current.currentIndex = nil
            } else if let index = state.currentIndex {
                current.currentIndex = min(max(index, 0), state.tracks.count - 1)
            } else {
                current.currentIndex = 0
            }
            current.mode = state.mode

            guard state.mode == .shuffle else {
                current.shuffleOrder = []
                return
            }
            let validOrder = state.shuffleOrder.count == state.tracks.count
                && Set(state.shuffleOrder) == Set(state.tracks.map(\.id))
            current.shuffleOrder = validOrder ? state.shuffleOrder : makeShuffleOrder(current)
        }
    }

    // MARK: - 移除 / 清空

    /// 移除指定索引的曲目。
    ///
    /// 索引语义：移除当前曲后，选中新队列中落到同一序号的那首（原队列里它的下一首）；
    /// 若移除的是最后一首，则钳位到新的最后一首；队列清空则 currentIndex 置 nil。
    /// 移除当前曲之前的项，当前索引左移一位；移除之后的项，当前索引不变。
    /// - Returns: 被移除的曲目；索引越界为 nil（且不产生任何状态变更）。
    @discardableResult
    public func remove(at index: Int) -> Track? {
        var removed: Track?
        mutate { state in
            guard state.tracks.indices.contains(index) else { return }
            removed = state.tracks[index]
            state.tracks.remove(at: index)
            if let removedID = removed?.id {
                state.shuffleOrder.removeAll { $0 == removedID }
            }
            guard let current = state.currentIndex else { return }
            if state.tracks.isEmpty {
                state.currentIndex = nil
            } else if index < current {
                state.currentIndex = current - 1
            } else if index == current {
                state.currentIndex = min(current, state.tracks.count - 1)
            }
        }
        return removed
    }

    /// 按 id 移除；等价于找到索引后调用 `remove(at:)`。
    @discardableResult
    public func remove(id: UUID) -> Track? {
        let index = state.tracks.firstIndex { $0.id == id }
        guard let index else { return nil }
        return remove(at: index)
    }

    /// 清空队列内容与当前索引，保留播放模式。
    public func clear() {
        mutate { state in
            state.tracks = []
            state.currentIndex = nil
            state.shuffleOrder = []
        }
    }

    // MARK: - 切歌

    /// 下一首，并推进索引。
    ///
    /// - 顺序：到末尾返回 nil（索引停在最后一首，表示「该停止」）；
    /// - 列表循环：回卷到首；
    /// - 单曲循环：返回当前曲，索引不变；
    /// - 随机：沿洗牌序列前进，序列走完则重新洗牌（当前曲仍置首）后继续。
    /// - 空队列：返回 nil。
    @discardableResult
    public func next() -> Track? {
        var result: Track?
        mutate { state in
            guard !state.tracks.isEmpty else { return }
            switch state.mode {
            case .sequential:
                guard let index = state.currentIndex, index + 1 < state.tracks.count else { return }
                state.currentIndex = index + 1
            case .repeatAll:
                guard let index = state.currentIndex else { return }
                state.currentIndex = (index + 1) % state.tracks.count
            case .repeatOne:
                break
            case .shuffle:
                advanceShuffle(&state)
            }
            result = state.currentTrack
        }
        return result
    }

    /// 上一首，并回退索引。
    ///
    /// - 顺序：已在首曲返回 nil（索引停在首曲）；
    /// - 列表循环：回卷到末；
    /// - 单曲循环：返回当前曲，索引不变；
    /// - 随机：沿洗牌序列后退，已在序列首位则绕到序列末尾。
    /// - 空队列：返回 nil。
    @discardableResult
    public func previous() -> Track? {
        var result: Track?
        mutate { state in
            guard !state.tracks.isEmpty else { return }
            switch state.mode {
            case .sequential:
                guard let index = state.currentIndex, index > 0 else { return }
                state.currentIndex = index - 1
            case .repeatAll:
                guard let index = state.currentIndex else { return }
                state.currentIndex = (index - 1 + state.tracks.count) % state.tracks.count
            case .repeatOne:
                break
            case .shuffle:
                retreatShuffle(&state)
            }
            result = state.currentTrack
        }
        return result
    }

    /// 跳转到任意索引。索引越界返回 nil 且不改状态。
    @discardableResult
    public func jump(to index: Int) -> Track? {
        var result: Track?
        mutate { state in
            guard state.tracks.indices.contains(index) else { return }
            state.currentIndex = index
            result = state.tracks[index]
        }
        return result
    }

    /// 切换播放模式。切换时保持当前曲不变（除非队列为空）。
    /// 进入随机模式会立即洗牌并把当前曲固定在序列首位；离开随机模式则清空洗牌序列。
    public func setMode(_ mode: PlaybackMode) {
        mutate { state in
            guard state.mode != mode else { return }
            state.mode = mode
            state.shuffleOrder = mode == .shuffle ? makeShuffleOrder(state) : []
        }
    }

    // MARK: - 状态订阅

    /// 订阅队列变更。每次订阅返回独立新流：先推一次当前快照，之后只在快照真正变化时产出。
    public func observeState() -> AsyncStream<QueueState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.lock()
            let current = stateValue
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
            continuation.yield(current)
        }
    }

    // MARK: - 内部：随机序列

    /// 生成一整轮洗牌序列：包含全部轨道 id，且当前曲固定排在首位。
    /// 做法是先摘出当前曲，对其余曲洗牌，再把当前曲拼到最前 —— 这样既不打断正在播的歌，
    /// 也保证下一首不会立刻又是它自己（除非队列只剩它一首）。
    private func makeShuffleOrder(_ state: QueueState) -> [UUID] {
        var rest = state.tracks.map(\.id)
        guard let currentID = state.currentTrack?.id else {
            shuffler(&rest)
            return rest
        }
        rest.removeAll { $0 == currentID }
        shuffler(&rest)
        return [currentID] + rest
    }

    /// 随机模式前进：沿序列走一格；走到末尾则重新洗牌（当前曲置首）再走第一格。
    private func advanceShuffle(_ state: inout QueueState) {
        guard let current = state.currentTrack else { return }
        guard let position = shufflePosition(of: current.id, in: &state) else { return }
        let targetID: UUID
        if position + 1 < state.shuffleOrder.count {
            targetID = state.shuffleOrder[position + 1]
        } else {
            state.shuffleOrder = makeShuffleOrder(state)
            // 新一轮把当前曲放在首位，所以下一首是它的后继；队列只剩一首时就是它自己。
            targetID = state.shuffleOrder.count > 1 ? state.shuffleOrder[1] : current.id
        }
        if let index = state.tracks.firstIndex(where: { $0.id == targetID }) {
            state.currentIndex = index
        }
    }

    /// 随机模式后退：沿序列退一格；已在首位则绕到序列末尾。
    private func retreatShuffle(_ state: inout QueueState) {
        guard let current = state.currentTrack else { return }
        guard let position = shufflePosition(of: current.id, in: &state) else { return }
        let targetID = position > 0 ? state.shuffleOrder[position - 1] : state.shuffleOrder[state.shuffleOrder.count - 1]
        if let index = state.tracks.firstIndex(where: { $0.id == targetID }) {
            state.currentIndex = index
        }
    }

    /// 定位当前曲在洗牌序列中的位置；序列失效（长度不符或不含当前曲）时先重建再定位。
    /// 找不到返回 nil（队列为空等），调用方据此放弃本次切歌。
    private func shufflePosition(of id: UUID, in state: inout QueueState) -> Int? {
        if state.shuffleOrder.count != state.tracks.count || !state.shuffleOrder.contains(id) {
            state.shuffleOrder = makeShuffleOrder(state)
        }
        return state.shuffleOrder.firstIndex(of: id)
    }

    /// 把新曲插到随机序列中当前曲的后一格（无当前曲则插到末尾）。
    private func insertIntoShuffleOrder(_ state: inout QueueState, id: UUID) {
        guard let currentID = state.currentTrack?.id,
              let position = state.shuffleOrder.firstIndex(of: currentID) else {
            state.shuffleOrder.append(id)
            return
        }
        state.shuffleOrder.insert(id, at: position + 1)
    }

    // MARK: - 内部：状态提交

    /// 原地修改状态；仅在快照真的变化时向订阅者广播（锁外 yield）。
    private func mutate(_ body: (inout QueueState) -> Void) {
        lock.lock()
        var next = stateValue
        body(&next)
        guard next != stateValue else {
            lock.unlock()
            return
        }
        stateValue = next
        let listeners = Array(continuations.values)
        lock.unlock()
        for listener in listeners {
            listener.yield(next)
        }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
