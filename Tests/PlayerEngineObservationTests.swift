// PlayerEngineObservationTests.swift
// NeriPlayer macOS —— 引擎状态**同步**观察的回归守卫（M3 收尾修复）。
//
// 背景：`PlaybackStateStore` 原本靠一个非结构化 `Task` 消费 `observeState()` 的 AsyncStream
// 来折叠引擎状态。流能否被消费取决于那个任务能否被协作线程池调度，实测在调度不利时会长时间
// 不被唤醒 —— 表现为「引擎已经变了、内存态快照还停在旧值」，界面文案、媒体键、现场落库一起
// 卡住；测试侧则是一批等快照的用例超时（命中率约 1/2~1/4 轮，加压时更高）。
//
// 修法：把「状态通知」从「等消费者任务被调度」改成「状态产生方在自己的线程上直接回调」，
// 并在三层都做了替换 —— MPVController 的属性订阅、MPVEngine 的属性折叠、PlaybackStateStore
// 的引擎订阅。本文件守住这三层的「同步性」与令牌语义，避免以后有人改回异步。
//
// 为什么最关键的断言是「不 await、不轮询」：异步折叠在功能上也能最终收敛，只有把
// 「调用返回时状态是否已经更新」写死，才能真正卡住「是不是同步完成」这件事。

import XCTest
@testable import NeriPlayer

final class PlayerEngineObservationTests: XCTestCase {

    // MARK: - 广播器语义

    /// 广播是同步的：broadcast 返回时 handler 已经跑完。
    func testBroadcasterDeliversSynchronously() {
        let broadcaster = PlayerEngineStateBroadcaster()
        var received: [PlayerEngineState] = []
        _ = broadcaster.add { received.append($0) }

        broadcaster.broadcast(.idle)

        XCTAssertEqual(received, [.idle], "broadcast 返回时 handler 应已执行完")
        XCTAssertEqual(broadcaster.observerCount, 1)
    }

    /// 多个观察者都收到，且顺序与注册顺序一致。
    func testBroadcasterDeliversToAllObserversInRegistrationOrder() {
        let broadcaster = PlayerEngineStateBroadcaster()
        var order: [String] = []
        _ = broadcaster.add { _ in order.append("first") }
        _ = broadcaster.add { _ in order.append("second") }

        broadcaster.broadcast(.idle)

        XCTAssertEqual(order, ["first", "second"])
        XCTAssertEqual(broadcaster.observerCount, 2)
    }

    /// 取消后不再收到；重复取消是安全的。
    func testCancelStopsDeliveryAndIsIdempotent() {
        let broadcaster = PlayerEngineStateBroadcaster()
        var count = 0
        let token = broadcaster.add { _ in count += 1 }

        broadcaster.broadcast(.idle)
        token.cancel()
        token.cancel()
        broadcaster.broadcast(.idle)

        XCTAssertEqual(count, 1)
        XCTAssertEqual(broadcaster.observerCount, 0)
    }

    /// 令牌析构**不**自动注销：显式取消语义。
    ///
    /// 这条断言守的是一个刻意的取舍。若改成「析构即注销」，`_ = add(handler)` 这种写法就会
    /// 变成「注册完立刻静默取消」—— 回调不来，而原因离现象很远。忘记取消只是让订阅多活一会儿，
    /// 由持有者生命周期兜底，代价小得多。
    func testTokenDeallocDoesNotUnsubscribe() {
        let broadcaster = PlayerEngineStateBroadcaster()
        var received = 0
        var token: (any PlayerEngineStateObservation)? = broadcaster.add { _ in received += 1 }
        XCTAssertEqual(broadcaster.observerCount, 1)

        token = nil
        broadcaster.broadcast(.idle)

        XCTAssertEqual(broadcaster.observerCount, 1, "令牌释放不该注销订阅")
        XCTAssertEqual(received, 1, "订阅仍然有效")
    }

    /// 观察者在广播过程中注销自己（或再注册一个）不会死锁、也不影响本次广播的其他观察者。
    /// 这正是「先取快照、再在锁外遍历」这条实现约定的用途。
    func testObserverCancellingItselfDuringBroadcastIsSafe() {
        let broadcaster = PlayerEngineStateBroadcaster()
        var token: (any PlayerEngineStateObservation)?
        var others = 0
        token = broadcaster.add { _ in token?.cancel() }
        _ = broadcaster.add { _ in others += 1 }

        broadcaster.broadcast(.idle)

        XCTAssertEqual(others, 1, "另一个观察者不该被自注销影响")
        XCTAssertEqual(broadcaster.observerCount, 1)
    }

    // MARK: - 内存态同步折叠（本问题的主回归守卫）

    /// `playTrack` 返回时，内存态快照必须已经反映「引擎在播」——不允许依赖任何后台任务被调度。
    func testStoreFoldsEngineStateSynchronouslyOnPlayTrack() {
        let store = PlaybackStateStore(engine: SynchronousFakeEngine())
        let track = Track(url: URL(fileURLWithPath: "/music/sync.mp3"), title: "sync")

        store.playTrack(track)

        // 刻意不 await、不轮询：只要折叠还挂在任务调度上，这里就会看到 isCoreIdle 仍为 true。
        XCTAssertFalse(store.snapshot.isCoreIdle, "引擎状态必须在 playTrack 返回前折叠进快照")
        XCTAssertEqual(store.snapshot.currentTrack?.id, track.id)
        XCTAssertEqual(store.snapshot.position, 0)
    }

    /// 暂停与恢复同样同步反映。
    func testStoreFoldsPauseAndResumeSynchronously() {
        let store = PlaybackStateStore(engine: SynchronousFakeEngine())
        store.playTrack(Track(url: URL(fileURLWithPath: "/music/sync.mp3"), title: "sync"))

        store.togglePlayPause()
        XCTAssertTrue(store.snapshot.isPaused, "暂停应同步反映到快照")

        store.togglePlayPause()
        XCTAssertFalse(store.snapshot.isPaused, "恢复应同步反映到快照")
    }

    /// 停止后同步回到空闲态。
    func testStoreFoldsStopSynchronously() {
        let store = PlaybackStateStore(engine: SynchronousFakeEngine())
        store.playTrack(Track(url: URL(fileURLWithPath: "/music/sync.mp3"), title: "sync"))

        store.stop()

        XCTAssertTrue(store.snapshot.isCoreIdle, "停止应同步反映到快照")
    }

    /// 进度推进同步反映（真实引擎里由 time-pos 属性事件驱动）。
    func testStoreFoldsPositionAdvanceSynchronously() {
        let engine = SynchronousFakeEngine()
        let store = PlaybackStateStore(engine: engine)
        store.playTrack(Track(url: URL(fileURLWithPath: "/music/sync.mp3"), title: "sync"))

        engine.advance(to: 42)

        XCTAssertEqual(store.snapshot.position, 42, "进度推进应同步折叠")
    }

    /// 释放 store 后，引擎侧的订阅必须被注销，不能再回调到已销毁的对象上。
    func testStoreCancelsEngineObservationOnDeinit() {
        let engine = SynchronousFakeEngine()
        var store: PlaybackStateStore? = PlaybackStateStore(engine: engine)
        XCTAssertEqual(engine.observerCount, 1)

        store = nil

        XCTAssertEqual(engine.observerCount, 0, "store 释放后应注销引擎订阅")
    }

    // MARK: - MPVController 属性同步订阅（真实 libmpv）

    /// 同步属性订阅：设置属性后回调立即发生，不需要等任何消费者任务。
    func testControllerPropertyObserverFiresSynchronously() throws {
        let controller = try MPVController(clientName: "property-observer-test")
        let received = LockedBox<[Bool]>([])
        let token = controller.addPropertyObserver(.paused) { change in
            if let flag = change.flagValue {
                received.mutate { $0.append(flag) }
            }
        }

        try controller.setFlag("pause", true)
        // mpv 的属性通知由事件线程发出，这里给事件循环一个很短的窗口；
        // 关键区别是：投递不再经过协作线程池，因此不需要「等一个任务被调度」。
        let delivered = waitUntil(timeout: 2) { received.value.contains(true) }
        XCTAssertTrue(delivered, "同步订阅应在事件线程上直接回调（已收到：\(received.value)）")

        token.cancel()
        let countAfterCancel = received.value.count
        try controller.setFlag("pause", false)
        _ = waitUntil(timeout: 0.3) { received.value.count > countAfterCancel }
        XCTAssertEqual(received.value.count, countAfterCancel, "取消后不该再收到回调")
    }

    // MARK: - 工具

    /// 轮询等待（只用于「真实 mpv 事件线程何时发出属性通知」这类无法完全同步的点）。
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }
}

/// 线程安全的可变盒子（测试侧收集回调结果用）。
private final class LockedBox<Value>: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

/// 可控引擎：命令同步翻转状态并**同步广播**（与 MPVEngine 现在的语义一致）。
///
/// 刻意与 MPVEngine 一样同时维护「广播器 + 流」两条通知路径，
/// 这样内存态的折叠测试覆盖的就是生产的通知形态，而不是一个更简单的替身。
private final class SynchronousFakeEngine: PlayerEngine, @unchecked Sendable {

    private let lock = NSLock()
    private var stateValue: PlayerEngineState = .idle
    private var continuations: [UUID: AsyncStream<PlayerEngineState>.Continuation] = [:]
    private let stateBroadcaster = PlayerEngineStateBroadcaster()

    var observerCount: Int { stateBroadcaster.observerCount }

    var currentURL: URL? { snapshot.currentURL }
    var isPaused: Bool { snapshot.isPaused }
    var position: Double { snapshot.position }
    var duration: Double { snapshot.duration }
    var isCoreIdle: Bool { snapshot.isCoreIdle }

    func load(url: URL) throws {
        guard url.isFileURL else { throw PlayerEngineError.unsupportedURL(url) }
        mutate { state in
            state.currentURL = url
            state.position = 0
            state.duration = 180
            state.isPaused = false
            state.isCoreIdle = false
        }
    }

    func play() throws {
        guard snapshot.currentURL != nil else { throw PlayerEngineError.noCurrentItem }
        mutate { $0.isPaused = false }
    }

    func pause() throws {
        guard snapshot.currentURL != nil else { throw PlayerEngineError.noCurrentItem }
        mutate { $0.isPaused = true }
    }

    func stop() throws {
        mutate { $0 = .idle }
    }

    func seek(to seconds: Double) throws {
        guard snapshot.currentURL != nil else { throw PlayerEngineError.noCurrentItem }
        mutate { $0.position = seconds }
    }

    func setVolume(_ volume: Double) throws {}

    /// 模拟 time-pos 推进。
    func advance(to position: Double) {
        mutate { $0.position = position }
    }

    func addStateObserver(
        _ handler: @escaping @Sendable (PlayerEngineState) -> Void
    ) -> any PlayerEngineStateObservation {
        stateBroadcaster.add(handler)
    }

    func observeState() -> AsyncStream<PlayerEngineState> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
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

    private var snapshot: PlayerEngineState {
        lock.lock()
        defer { lock.unlock() }
        return stateValue
    }

    private func mutate(_ body: (inout PlayerEngineState) -> Void) {
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
        stateBroadcaster.broadcast(next)
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
