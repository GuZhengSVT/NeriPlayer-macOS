// SettingsStoreTests.swift
// M0-T5 设置存储层测试：读写、默认值回落、变更流通知、不同 suite 隔离。
// 全部测试用自建 UserDefaults(suiteName:) 并在结束时清理，不污染真实 defaults。

import XCTest
@testable import NeriPlayer

final class SettingsStoreTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDownWithError() throws {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames = []
        try super.tearDownWithError()
    }

    /// 建一个隔离的 UserDefaults + SettingsStore。
    private func makeStore() throws -> (SettingsStore, UserDefaults) {
        let name = "SettingsStoreTests-\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return (SettingsStore(userDefaults: defaults), defaults)
    }

    // MARK: 读取 / 默认值

    func testReadsDefaultValueWhenUnset() throws {
        let (store, _) = try makeStore()
        XCTAssertEqual(store.value(for: SettingsKeys.appAppearance), "system")
        XCTAssertEqual(store.value(for: SettingsKeys.lastSelectedTab), "home")
        XCTAssertNil(store.value(for: SettingsKeys.crashReportHandledAt))
    }

    // MARK: 读写

    func testWriteThenReadRoundTrips() throws {
        let (store, _) = try makeStore()
        store.set("dark", for: SettingsKeys.appAppearance)
        store.set("library", for: SettingsKeys.lastSelectedTab)
        XCTAssertEqual(store.value(for: SettingsKeys.appAppearance), "dark")
        XCTAssertEqual(store.value(for: SettingsKeys.lastSelectedTab), "library")
        XCTAssertTrue(store.contains(SettingsKeys.appAppearance))
    }

    func testBoolIntDoubleDataRoundTrip() throws {
        let (store, _) = try makeStore()
        let boolKey = SettingsKey<Bool>("flag", default: false)
        let intKey = SettingsKey<Int>("count", default: 0)
        let doubleKey = SettingsKey<Double>("volume", default: 1.0)
        let dataKey = SettingsKey<Data>("blob", default: Data())

        store.set(true, for: boolKey)
        store.set(42, for: intKey)
        store.set(0.75, for: doubleKey)
        store.set(Data([0x01, 0x02]), for: dataKey)

        XCTAssertEqual(store.value(for: boolKey), true)
        XCTAssertEqual(store.value(for: intKey), 42)
        XCTAssertEqual(store.value(for: doubleKey), 0.75)
        XCTAssertEqual(store.value(for: dataKey), Data([0x01, 0x02]))
    }

    func testOptionalDateRoundTripAndReset() throws {
        let (store, _) = try makeStore()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        store.set(stamp, for: SettingsKeys.crashReportHandledAt)
        XCTAssertEqual(store.value(for: SettingsKeys.crashReportHandledAt), stamp)

        store.set(nil, for: SettingsKeys.crashReportHandledAt)
        XCTAssertNil(store.value(for: SettingsKeys.crashReportHandledAt))
    }

    func testResetFallsBackToDefault() throws {
        let (store, _) = try makeStore()
        store.set("dark", for: SettingsKeys.appAppearance)
        XCTAssertEqual(store.value(for: SettingsKeys.appAppearance), "dark")

        store.reset(SettingsKeys.appAppearance)
        XCTAssertEqual(store.value(for: SettingsKeys.appAppearance), "system")
        XCTAssertFalse(store.contains(SettingsKeys.appAppearance))
    }

    // MARK: 变更流

    func testGlobalChangeStreamReceivesNotification() async throws {
        let (store, _) = try makeStore()
        let stream = store.changes()

        store.set("dark", for: SettingsKeys.appAppearance)

        let change = await firstElement(from: stream)
        XCTAssertEqual(change?.key, "appAppearance")
    }

    func testKeyScopedChangeStreamOnlyReceivesMatchingKey() async throws {
        let (store, _) = try makeStore()
        let stream = store.changes(for: SettingsKeys.lastSelectedTab)

        // 不相关的键变更不应被键粒度流收到。
        store.set("dark", for: SettingsKeys.appAppearance)
        store.set("library", for: SettingsKeys.lastSelectedTab)

        let change = await firstElement(from: stream)
        XCTAssertEqual(change?.key, "lastSelectedTab")
    }

    // MARK: 隔离性

    func testDifferentSuitesAreIsolated() throws {
        let (storeA, _) = try makeStore()
        let (storeB, _) = try makeStore()

        storeA.set("dark", for: SettingsKeys.appAppearance)

        XCTAssertEqual(storeA.value(for: SettingsKeys.appAppearance), "dark")
        XCTAssertEqual(storeB.value(for: SettingsKeys.appAppearance), "system")
    }

    /// 等待流的下一个元素，超时返回 nil（避免测试挂起）。
    private func firstElement(from stream: AsyncStream<SettingsChange>) async -> SettingsChange? {
        let box = StreamBox(stream)
        return await withTaskGroup(of: SettingsChange?.self) { group in
            group.addTask { await box.next() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

/// 承载 AsyncIterator 的引用盒，避免在并发任务组中捕获 inout 参数。
private final class StreamBox {
    private var iterator: AsyncStream<SettingsChange>.AsyncIterator

    init(_ stream: AsyncStream<SettingsChange>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async -> SettingsChange? {
        await iterator.next()
    }
}
