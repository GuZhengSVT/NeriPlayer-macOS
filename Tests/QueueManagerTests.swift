// QueueManagerTests.swift
// NeriPlayer macOS —— M1-T4：播放队列测试。
//
// 覆盖：空队列、单首队列各模式、顺序停止 vs 列表循环回卷、单曲循环、随机的
// 「当前曲在首位」与序列推进、插到下一首后的顺序、移除当前曲的索引语义、清空状态，
// 以及入队/setQueue/跳转/模式切换/状态订阅等常规行为。
// 全部为纯内存逻辑，不加载 libmpv，也不依赖真实音频文件。
//
// 随机相关的可复现做法：QueueManager 允许注入 QueueShuffler。测试用一个「反转」洗牌器
// （把待洗列表原地反转）代替真随机，从而能对 next()/previous() 的走位做确定性断言；
// 另有一组测试用默认随机源，只断言可观测的结构性质（是排列、含全部曲目、当前曲在首位）。

import XCTest
@testable import NeriPlayer

final class QueueManagerTests: XCTestCase {

    // MARK: - 构造工具

    /// 造一个以标题命名的本地轨道（不落盘，不实际播放）。
    private func track(_ title: String) -> Track {
        Track(url: URL(fileURLWithPath: "/tmp/NeriPlayerQueue/\(title).mp3"), title: title)
    }

    /// 把标题列表变成轨道列表，便于按顺序断言。
    private func tracks(_ titles: [String]) -> [Track] {
        titles.map(track)
    }

    /// 断言队列当前曲目标题。
    private func assertCurrent(_ queue: QueueManager, _ title: String?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(queue.currentTrack?.title, title, "当前曲目不符", file: file, line: line)
    }

    /// 反转洗牌器：确定性地制造一个与输入相反的顺序。
    private let reversingShuffler: QueueShuffler = { ids in ids.reverse() }

    // MARK: - 空队列

    /// 空队列：无当前曲、无索引、next/previous/jump 都无果。
    func testEmptyQueueHasNoCurrentTrackAndNoNavigation() {
        let queue = QueueManager()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
        XCTAssertNil(queue.currentIndex)
        XCTAssertNil(queue.currentTrack)
        XCTAssertNil(queue.next())
        XCTAssertNil(queue.previous())
        XCTAssertNil(queue.jump(to: 0))
        XCTAssertNil(queue.remove(at: 0), "空队列移除任意索引应返回 nil")
        XCTAssertEqual(queue.state, .empty)
    }

    /// 空队列切模式不应产生崩溃，也不改变「无当前曲」的事实。
    func testEmptyQueueModeSwitchIsHarmless() {
        let queue = QueueManager()
        for mode in PlaybackMode.allCases {
            queue.setMode(mode)
            XCTAssertEqual(queue.mode, mode)
            XCTAssertNil(queue.currentTrack)
            XCTAssertNil(queue.next())
            XCTAssertNil(queue.previous())
            XCTAssertTrue(queue.shuffleOrder.isEmpty, "空队列不应有洗牌序列")
        }
    }

    // MARK: - 入队 / setQueue

    /// 空队列入队第一首时，它直接成为当前曲（而不是「入队了但没得播」）。
    func testEnqueueIntoEmptyQueueBecomesCurrent() {
        let queue = QueueManager()
        let a = track("A")
        queue.enqueue(a)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(queue.currentTrack, a)
    }

    /// 非空队列追加：当前曲不变，只增长队尾。
    func testEnqueueAppendsWithoutMovingCurrent() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B"]))
        queue.next() // 当前 B
        queue.enqueue(track("C"))
        XCTAssertEqual(queue.tracks.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(queue.currentIndex, 1)
        assertCurrent(queue, "B")
    }

    /// enqueueNext 把曲目插到「当前曲的下一首」位置。
    func testEnqueueNextInsertsRightAfterCurrent() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B", "C"])) // 当前 A
        queue.enqueueNext(track("X"))
        XCTAssertEqual(queue.tracks.map(\.title), ["A", "X", "B", "C"])
        XCTAssertEqual(queue.currentIndex, 0, "插入下一首不应移动当前索引")
    }

    /// 当前已是最后一首时，enqueueNext 退化为追加到队尾（不越界）。
    func testEnqueueNextAtLastTrackAppendsToEnd() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B"]), startAt: 1) // 当前 B（尾）
        queue.enqueueNext(track("X"))
        XCTAssertEqual(queue.tracks.map(\.title), ["A", "B", "X"])
        assertCurrent(queue, "B")
    }

    /// 空队列 enqueueNext 等价于 enqueue：直接成为当前曲。
    func testEnqueueNextIntoEmptyQueueBecomesCurrent() {
        let queue = QueueManager()
        queue.enqueueNext(track("A"))
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.currentTrack?.title, "A")
    }

    /// setQueue 整批替换并从指定索引起播，返回起播曲。
    func testSetQueueReplacesAndStartsAtGivenIndex() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B"]))
        let started = queue.setQueue(tracks(["C", "D", "E"]), startAt: 2)
        XCTAssertEqual(queue.tracks.map(\.title), ["C", "D", "E"])
        XCTAssertEqual(queue.currentIndex, 2)
        XCTAssertEqual(started?.title, "E")
        assertCurrent(queue, "E")
    }

    /// setQueue 的起始索引越界时钳位到有效范围。
    func testSetQueueClampsStartIndex() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B", "C"]), startAt: -5)
        XCTAssertEqual(queue.currentIndex, 0, "负索引应钳位到首曲")

        queue.setQueue(tracks(["A", "B", "C"]), startAt: 99)
        XCTAssertEqual(queue.currentIndex, 2, "过大索引应钳位到末曲")

        let empty = queue.setQueue([])
        XCTAssertNil(empty, "空列表 setQueue 返回 nil")
        XCTAssertNil(queue.currentIndex)
    }

    // MARK: - 顺序：到末尾停止

    /// 顺序模式 next 逐首前进，最后一首再 next 返回 nil 且索引停在末曲（而不是清空）。
    func testSequentialNextStopsAtEnd() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B"]))
        XCTAssertEqual(queue.next()?.title, "B")
        XCTAssertNil(queue.next(), "顺序模式到末尾应返回 nil 表示停止")
        XCTAssertEqual(queue.currentIndex, 1, "停止时索引停在末曲，不改写当前曲")
        assertCurrent(queue, "B")
    }

    /// 顺序模式 previous 在首曲处返回 nil 且索引停在首曲。
    func testSequentialPreviousStopsAtStart() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B", "C"]), startAt: 1)
        XCTAssertEqual(queue.previous()?.title, "A")
        XCTAssertNil(queue.previous(), "首曲再 previous 应返回 nil")
        XCTAssertEqual(queue.currentIndex, 0)
        assertCurrent(queue, "A")
    }

    // MARK: - 列表循环：首尾回卷

    /// 列表循环：末尾 next 回卷到首曲，首曲 previous 回卷到末曲。
    func testRepeatAllWrapsBothDirections() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B", "C"]), startAt: 2) // 尾曲 C
        queue.setMode(.repeatAll)
        XCTAssertEqual(queue.next()?.title, "A", "列表循环下末尾应回卷到首曲")
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(queue.previous()?.title, "C", "列表循环下首曲应回卷到末曲")
        XCTAssertEqual(queue.currentIndex, 2)
    }

    // MARK: - 单首队列（各模式）

    /// 单首 + 顺序：两个方向都无下一首可去，返回 nil。
    func testSingleTrackSequentialHasNoNeighbour() {
        let queue = QueueManager()
        queue.setQueue([track("Solo")])
        XCTAssertNil(queue.next())
        XCTAssertNil(queue.previous())
        XCTAssertEqual(queue.currentIndex, 0)
        assertCurrent(queue, "Solo")
    }

    /// 单首 + 列表循环：next/previous 都回到自身，索引不变。
    func testSingleTrackRepeatAllStaysOnTrack() {
        let queue = QueueManager()
        queue.setQueue([track("Solo")])
        queue.setMode(.repeatAll)
        XCTAssertEqual(queue.next()?.title, "Solo")
        XCTAssertEqual(queue.previous()?.title, "Solo")
        XCTAssertEqual(queue.currentIndex, 0)
    }

    /// 单首 + 随机：洗牌序列退化为只有一个 id，next 仍是自身。
    func testSingleTrackShuffleStaysOnTrack() {
        let queue = QueueManager()
        queue.setQueue([track("Solo")])
        queue.setMode(.shuffle)
        XCTAssertEqual(queue.shuffleOrder.count, 1)
        XCTAssertEqual(queue.next()?.title, "Solo")
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(queue.previous()?.title, "Solo")
    }

    // MARK: - 单曲循环

    /// 单曲循环：多首队列里 next/previous 都停在当前曲，索引不变。
    func testRepeatOneKeepsCurrentTrack() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B", "C"]), startAt: 1) // 当前 B
        queue.setMode(.repeatOne)
        XCTAssertEqual(queue.next()?.title, "B")
        XCTAssertEqual(queue.currentIndex, 1, "单曲循环不应移动索引")
        XCTAssertEqual(queue.previous()?.title, "B")
        XCTAssertEqual(queue.currentIndex, 1)
    }

    /// 单曲循环到列表循环的切换立即生效：切换后 next 走到下一首。
    func testSwitchingFromRepeatOneToRepeatAllResumesAdvancing() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B"]))
        queue.setMode(.repeatOne)
        XCTAssertEqual(queue.next()?.title, "A")
        queue.setMode(.repeatAll)
        XCTAssertEqual(queue.next()?.title, "B", "退出单曲循环后应恢复推进")
    }

    // MARK: - 插到下一首后的播放顺序

    /// 顺序模式：插到下一首后 next 先播插入曲，再按原顺序继续。
    func testEnqueueNextChangesSequentialPlaybackOrder() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B", "C"])) // 当前 A
        queue.enqueueNext(track("X"))
        XCTAssertEqual(queue.next()?.title, "X")
        XCTAssertEqual(queue.next()?.title, "B")
        XCTAssertEqual(queue.next()?.title, "C")
        XCTAssertNil(queue.next(), "插曲不应改变「到末尾停止」的边界")
    }

    /// 列表循环模式：插入下一首同样优先播放，回卷不受影响。
    func testEnqueueNextRespectedInRepeatAll() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B"]))
        queue.setMode(.repeatAll)
        queue.enqueueNext(track("X")) // [A, X, B]
        XCTAssertEqual(queue.next()?.title, "X")
        XCTAssertEqual(queue.next()?.title, "B")
        XCTAssertEqual(queue.next()?.title, "A", "列表循环仍应回卷到首")
    }

    /// 随机模式：插到下一首后，该曲插在当前曲之后，next 立即播它。
    func testEnqueueNextRespectedInShuffle() {
        let queue = QueueManager(shuffler: reversingShuffler)
        queue.setQueue(tracks(["A", "B", "C"])) // 当前 A
        queue.setMode(.shuffle)                       // 序列 [A, C, B]
        queue.enqueueNext(track("X"))
        XCTAssertEqual(queue.next()?.title, "X", "随机模式下插入的曲应紧跟当前曲")
    }

    // MARK: - 跳转

    /// jump 直接设定索引并返回目标曲。
    func testJumpSetsIndex() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B", "C"]))
        XCTAssertEqual(queue.jump(to: 2)?.title, "C")
        XCTAssertEqual(queue.currentIndex, 2)
        XCTAssertNil(queue.jump(to: 5), "越界跳转应返回 nil")
        XCTAssertEqual(queue.currentIndex, 2, "越界跳转不应改动状态")
        XCTAssertNil(queue.jump(to: -1))
    }

    // MARK: - 移除当前曲的索引语义

    /// 语义选择：移除当前曲后，按「列表序号」前进 —— 选中新队列中落到同一序号的那首，
    /// 也就是原队列里它的下一首。（若移除的是末曲，则钳位到新的末曲。）
    func testRemoveCurrentAdvancesToSuccessorByOrdinal() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B", "C"]), startAt: 1) // 当前 B
        let removed = queue.remove(at: 1)
        XCTAssertEqual(removed?.title, "B")
        XCTAssertEqual(queue.tracks.map(\.title), ["A", "C"])
        XCTAssertEqual(queue.currentIndex, 1, "当前曲被移除后索引保持原序号")
        assertCurrent(queue, "C")
    }

    /// 移除当前曲且它已是末曲：索引钳位到新的末曲。
    func testRemoveCurrentAtTailClampsToNewLast() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B", "C"]), startAt: 2) // 当前 C（末）
        queue.remove(at: 2)
        XCTAssertEqual(queue.currentIndex, 1)
        assertCurrent(queue, "B")
    }

    /// 移除当前曲之前的项：当前索引左移一位，当前曲本身不变。
    func testRemoveBeforeCurrentShiftsIndexKeepingTrack() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B", "C"]), startAt: 2) // 当前 C
        queue.remove(at: 0)
        XCTAssertEqual(queue.tracks.map(\.title), ["B", "C"])
        XCTAssertEqual(queue.currentIndex, 1)
        assertCurrent(queue, "C")
    }

    /// 移除当前曲之后的项：当前索引与当前曲都不受影响。
    func testRemoveAfterCurrentKeepsEverything() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B", "C"]), startAt: 1) // 当前 B
        queue.remove(at: 2)
        XCTAssertEqual(queue.tracks.map(\.title), ["A", "B"])
        XCTAssertEqual(queue.currentIndex, 1)
        assertCurrent(queue, "B")
    }

    /// 移除唯一一首：队列变空，currentIndex 归 nil。
    func testRemoveLastRemainingTrackClearsCurrent() {
        let queue = QueueManager()
        queue.setQueue([track("Solo")])
        queue.remove(at: 0)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.currentIndex)
        XCTAssertNil(queue.currentTrack)
    }

    /// 越界移除返回 nil 且无副作用；按 id 移除能定位到正确位置。
    func testRemoveOutOfBoundsIsNoOpAndRemoveByIDWorks() {
        let queue = QueueManager()
        let items = tracks(["A", "B", "C"])
        queue.setQueue(items, startAt: 1)
        XCTAssertNil(queue.remove(at: 9))
        XCTAssertEqual(queue.tracks.count, 3, "越界移除不应改动队列")

        XCTAssertEqual(queue.remove(id: items[2].id)?.title, "C")
        XCTAssertEqual(queue.tracks.map(\.title), ["A", "B"])
        XCTAssertNil(queue.remove(id: UUID()), "未知 id 返回 nil")
    }

    /// 随机模式下移除当前曲仍按列表序号前进（与模式无关，保证可预测）。
    func testRemoveCurrentInShuffleUsesOrdinalSemantics() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B", "C"]), startAt: 0) // 当前 A
        queue.setMode(.shuffle)
        queue.remove(at: 0)
        XCTAssertEqual(queue.currentIndex, 0)
        assertCurrent(queue, "B")
        XCTAssertEqual(queue.shuffleOrder.count, 2, "移除后洗牌序列应同步剔除该曲")
        XCTAssertTrue(queue.shuffleOrder.contains(queue.tracks[0].id), "新当前曲应仍在序列中")
    }

    // MARK: - 清空

    /// 清空：内容与索引归零，但保留播放模式（模式属于用户偏好，不随队列生命周期归零）。
    func testClearResetsContentAndIndexButKeepsMode() {
        let queue = QueueManager()
        queue.setQueue(tracks(["A", "B"]))
        queue.setMode(.repeatAll)
        queue.clear()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
        XCTAssertNil(queue.currentIndex)
        XCTAssertNil(queue.currentTrack)
        XCTAssertTrue(queue.shuffleOrder.isEmpty)
        XCTAssertEqual(queue.mode, .repeatAll, "clear 应保留播放模式")
        XCTAssertNil(queue.next())
        XCTAssertNil(queue.previous())
    }

    // MARK: - 模式切换与视图

    /// 切换到同一模式不应产生变化；切换到随机模式会立即洗牌。
    func testSetModeShuffleBuildsOrderAndSameModeIsNoOp() {
        let queue = QueueManager(shuffler: reversingShuffler)
        queue.setQueue(tracks(["A", "B", "C"]), startAt: 1) // 当前 B
        queue.setMode(.shuffle)
        XCTAssertEqual(queue.shuffleOrder, [queue.tracks[1].id, queue.tracks[2].id, queue.tracks[0].id])
        queue.setMode(.shuffle) // 重复设置：无变化
        XCTAssertEqual(queue.shuffleOrder.count, 3)

        queue.setMode(.sequential)
        XCTAssertTrue(queue.shuffleOrder.isEmpty, "退出随机模式应清空洗牌序列")
        XCTAssertEqual(queue.currentIndex, 1, "切模式不应移动当前索引")
    }

    // MARK: - 随机模式

    /// 进入随机模式：当前曲固定在序列首位，序列是全体曲目的一个排列。
    func testShufflePlacesCurrentFirstAndPermutesAll() {
        let queue = QueueManager()
        let items = tracks(["A", "B", "C", "D", "E"])
        queue.setQueue(items, startAt: 2) // 当前 C
        queue.setMode(.shuffle)
        XCTAssertEqual(queue.shuffleOrder.count, items.count)
        XCTAssertEqual(queue.shuffleOrder.first, items[2].id, "当前曲应固定在洗牌序列首位")
        XCTAssertEqual(Set(queue.shuffleOrder), Set(items.map(\.id)), "洗牌不应增删曲目")
    }

    /// 随机模式 next 沿洗牌序列前进，序列走完后重新洗牌（当前曲仍置首）并继续，不停在末尾。
    func testShuffleNextWalksOrderThenReshuffles() {
        let queue = QueueManager(shuffler: reversingShuffler)
        let items = tracks(["A", "B", "C", "D", "E"])
        queue.setQueue(items, startAt: 2) // 当前 C
        queue.setMode(.shuffle)
        // 其余 [A,B,D,E] 反转为 [E,D,B,A]，序列 = [C,E,D,B,A]
        XCTAssertEqual(queue.shuffleOrder, [items[2].id, items[4].id, items[3].id, items[1].id, items[0].id])
        XCTAssertEqual(queue.next()?.title, "E")
        XCTAssertEqual(queue.next()?.title, "D")
        XCTAssertEqual(queue.next()?.title, "B")
        XCTAssertEqual(queue.next()?.title, "A")
        XCTAssertEqual(queue.currentTrack?.title, "A")
        // 走到序列末尾后应重新洗牌再继续，而不是停止。
        XCTAssertNotNil(queue.next(), "随机模式走完一轮应继续，不停在末尾")
        XCTAssertEqual(queue.shuffleOrder.first, items[0].id, "重洗后当前曲仍固定在首位")
    }

    /// 随机模式 previous 沿序列后退，在首位绕到序列末尾。
    func testShufflePreviousWalksBackAndWraps() {
        let queue = QueueManager(shuffler: reversingShuffler)
        let items = tracks(["A", "B", "C", "D"])
        queue.setQueue(items, startAt: 0) // 当前 A
        queue.setMode(.shuffle)
        // 其余 [B,C,D] 反转为 [D,C,B]，序列 = [A,D,C,B]
        XCTAssertEqual(queue.shuffleOrder.first, items[0].id)
        XCTAssertEqual(queue.previous()?.title, "B", "序列首位 previous 应绕到末尾")
        XCTAssertEqual(queue.previous()?.title, "C")
        XCTAssertEqual(queue.currentTrack?.title, "C")
    }

    /// 随机模式下新入队的曲排在本轮序列末尾，本轮走完自然轮到它。
    func testShuffleAppendQueuesAfterCurrentRound() {
        let queue = QueueManager(shuffler: reversingShuffler)
        let items = tracks(["A", "B"])
        queue.setQueue(items, startAt: 0) // 当前 A
        queue.setMode(.shuffle)             // 其余 [B] 不变，序列 = [A, B]
        XCTAssertEqual(queue.shuffleOrder, [items[0].id, items[1].id])
        let appended = track("Z")
        queue.enqueue(appended)
        XCTAssertEqual(queue.shuffleOrder.last, appended.id, "新曲应追加到序列末尾")
    }

    // MARK: - 状态订阅

    /// 订阅先推当前快照，随后在变更时继续推送。
    func testObserveStateEmitsInitialSnapshotThenChanges() async throws {
        let queue = QueueManager()
        let reader = QueueStateReader(queue.observeState())

        let firstSnapshot = await reader.next()
        let initial = try XCTUnwrap(firstSnapshot, "订阅后应立即收到一次当前快照")
        XCTAssertTrue(initial.isEmpty)
        XCTAssertEqual(initial.mode, .sequential)

        queue.setQueue(tracks(["A", "B"]))
        let after = try await nextState(reader) { $0.count == 2 }
        XCTAssertEqual(after.currentTrack?.title, "A")
        XCTAssertEqual(after.currentIndex, 0)
    }

    /// 无实际变化时不产生新的快照（相同模式重复设置）。
    func testObserveStateSkipsNoOpMutations() async throws {
        let queue = QueueManager()
        queue.setQueue(tracks(["A"]))
        let reader = QueueStateReader(queue.observeState())
        let firstSnapshot = await reader.next()
        _ = try XCTUnwrap(firstSnapshot)

        queue.setMode(.sequential) // 已是该模式：不应产生新快照
        queue.jump(to: 0)          // 已在该索引：不应产生新快照
        queue.enqueue(track("B"))
        let after = try await nextState(reader) { $0.count == 2 }
        XCTAssertEqual(after.tracks.map(\.title), ["A", "B"])
    }

    /// 多个订阅者各自拿到独立流，取消其一不影响另一个。
    func testObserveStateSupportsMultipleSubscribers() async throws {
        let queue = QueueManager()
        let cancelled = queue.observeState()
        let cancelTask = Task { for await _ in cancelled {} }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelTask.cancel()
        _ = await cancelTask.value

        queue.setQueue(tracks(["A", "B", "C"]))
        let reader = QueueStateReader(queue.observeState())
        let snapshot = try await nextState(reader) { $0.count == 3 }
        XCTAssertEqual(snapshot.tracks.map(\.title), ["A", "B", "C"])
    }

    // MARK: - 工具

    /// 从读取器里推进到首个满足条件的快照，带超时保护。
    private func nextState(
        _ reader: QueueStateReader,
        seconds: Double = 2,
        until predicate: @escaping @Sendable (QueueState) -> Bool
    ) async throws -> QueueState {
        try await withThrowingTaskGroup(of: QueueState.self) { group in
            group.addTask {
                while let state = await reader.next() {
                    if predicate(state) { return state }
                }
                throw QueueTestError.streamEnded
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw QueueTestError.timeout
            }
            guard let result = try await group.next() else { throw QueueTestError.timeout }
            group.cancelAll()
            return result
        }
    }
}

/// 队列状态流读取器。单消费者设计：每个测试只在一条等待链里使用同一个读取器。
private final class QueueStateReader: @unchecked Sendable {
    private var iterator: AsyncStream<QueueState>.AsyncIterator

    init(_ stream: AsyncStream<QueueState>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> QueueState? {
        await iterator.next()
    }
}

/// 测试内部错误标记。
private enum QueueTestError: Error {
    case timeout
    case streamEnded
}
