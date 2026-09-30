// PlayerEngineObservation.swift
// NeriPlayer macOS —— 引擎状态变更的**同步**观察者（移植规划 M3 收尾修复）。
//
// 解决什么问题：`PlaybackStateStore` 原本靠一个非结构化 `Task` 消费 `observeState()` 的
// AsyncStream 来折叠引擎状态。流能不能被消费取决于那个任务能否被协作线程池调度 ——
// 实测在调度不利时它会长时间不被唤醒，表现为「引擎已经变了、内存态快照还停在旧值」，
// 界面文案、媒体键、现场落库一起卡住；测试里则是一批等快照的用例超时。
//
// 为什么改成回调：状态的产生者（MPVEngine 的属性事件线程、测试替身的 mutate）本来就知道
// 状态什么时候变。让它在**自己的执行上下文中直接调用**订阅者，就把「内存态能否反映引擎」
// 从「调度器是否赏脸」变回了一件确定的事。流（observeState）保留，供需要拉取/多订阅者的
// 场景使用，但不再承担「必须及时送达」的责任。
//
// 为什么把注册表抽成共享类型而不是每个实现各写一份：注册/注销/遍历这套样板在 6 个
// PlayerEngine 实现里都要有，而测试替身与生产实现必须语义一致 —— 各写一份迟早会漂移成
// 「测试替身同步、真机异步」（或反之），那类不一致最能在交付前夜咬人。
//
// 线程模型：内部由 lock 串行化注册表；广播在调用者线程上**同步**执行各 handler。
// 调用方必须保证「不持有自己的锁时再广播」，否则会把锁顺序问题引入到订阅者里。

import Foundation

// MARK: - 订阅令牌

/// 一次状态观察的取消令牌。取消即不再接收变更。
///
/// 语义是**显式取消**：订阅一直有效，直到调用 `cancel()`（或产生它的控制器/引擎被销毁）。
/// 刻意不做「令牌析构即自动注销」——那会让 `_ = add(handler)` 这种写法变成「注册完立刻静默
/// 取消」，是一个很容易踩、且症状（回调不来）离原因很远的坑。忘记取消的代价是订阅多活一会儿，
/// 由持有者的生命周期兜底；误取消的代价是功能静默失效。两害相权取前者。
public protocol PlayerEngineStateObservation: AnyObject, Sendable {

    /// 停止接收变更。可重复调用。
    func cancel()
}

// MARK: - 同步广播器

/// 引擎状态观察者的注册表：注册 / 注销 / 在调用线程上同步广播。
///
/// 投递顺序是**注册顺序**：用有序数组而不是字典，避免「多订阅者时谁先谁后不确定」——
/// 这类不确定性在只有一个订阅者时看不出来，等加到第二个才变成偶发问题。
public final class PlayerEngineStateBroadcaster: @unchecked Sendable {

    private let lock = NSLock()
    private var handlers: [(id: UUID, handler: @Sendable (PlayerEngineState) -> Void)] = []

    public init() {}

    /// 注册一个观察者。
    /// - Parameter handler: 状态变化时在广播线程上同步调用；实现须自行保证线程安全。
    /// - Returns: 取消令牌；调用 `cancel()` 即注销。
    public func add(_ handler: @escaping @Sendable (PlayerEngineState) -> Void) -> any PlayerEngineStateObservation {
        let id = UUID()
        lock.lock()
        handlers.append((id: id, handler: handler))
        lock.unlock()
        return Token { [weak self] in
            self?.remove(id)
        }
    }

    /// 同步广播一次状态。
    ///
    /// 刻意在锁外遍历（先取出快照再调用）：handler 里可能注销自己或再注册，
    /// 持锁调用会把这些回调路径变成同一把锁上的重入。
    public func broadcast(_ state: PlayerEngineState) {
        lock.lock()
        let listeners = handlers.map(\.handler)
        lock.unlock()
        for listener in listeners {
            listener(state)
        }
    }

    /// 当前观察者数量（供测试断言「注册与注销对称」）。
    public var observerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return handlers.count
    }

    private func remove(_ id: UUID) {
        lock.lock()
        handlers.removeAll { $0.id == id }
        lock.unlock()
    }

    /// 取消令牌实现。
    private final class Token: PlayerEngineStateObservation, @unchecked Sendable {

        private let lock = NSLock()
        private var onCancel: (@Sendable () -> Void)?

        init(onCancel: @escaping @Sendable () -> Void) {
            self.onCancel = onCancel
        }

        func cancel() {
            lock.lock()
            let action = onCancel
            onCancel = nil
            lock.unlock()
            // 幂等：第二次调用时 action 已是 nil。
            action?()
        }
    }
}

// MARK: - mpv 属性订阅令牌

/// 一次 mpv 属性**同步**订阅的取消令牌（对应 MPVController.addPropertyObserver）。
///
/// 与 PlayerEngineStateObservation 分开定义而不是共用一个泛型令牌：两者属于不同抽象层
/// （libmpv 属性 vs 播放引擎状态），层级混用会让「取消的是哪一层」在调用点看不出来。
public protocol MPVPropertyObservation: AnyObject, Sendable {

    /// 停止接收变更。可重复调用。
    func cancel()
}

/// MPVPropertyObservation 的实现：把取消动作收敛成一次性的闭包。
///
/// 同 PlayerEngineStateObservation：显式取消语义，令牌析构不自动注销（理由见上）。
final class MPVPropertyToken: MPVPropertyObservation, @unchecked Sendable {

    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        lock.lock()
        let action = onCancel
        onCancel = nil
        lock.unlock()
        action?()
    }
}
