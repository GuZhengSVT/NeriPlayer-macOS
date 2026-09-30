// MPVControllerTests.swift
// NeriPlayer macOS —— M1-T2：MPVController 对 libmpv 的封装测试。
//
// 说明：这些用例会创建真实的 libmpv 实例（不是 mock），因此需要两件事同时成立：
//   1) Vendor/mpv/lib/libmpv.2.dylib 存在（先跑 Tools/fetch-mpv.sh）；
//   2) 测试 bundle 进程能在运行期加载到该 dylib。
// 第 2 点的做法：在 Package.swift 的 testTarget 上声明
//   .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", <Vendor/mpv/lib 绝对路径>])
// 让 NeriPlayerPackageTests.xctest 带上指向 vendor 目录的 LC_RPATH。
// 这里不能用 DYLD_LIBRARY_PATH 之类环境变量代替：swift test 默认从 .build 里直接
// 运行测试 bundle，且 SIP/测试运行器会对环境变量做处理，rpath 才是可靠做法。
//
// 边界：M1-T2 只验证控制器自身的封装（生命周期 / 属性读写 / 订阅 / 错误），
// 不验证真实音频播放（属 M1-T3）。

import XCTest
import CMpv
@testable import NeriPlayer

final class MPVControllerTests: XCTestCase {

    // MARK: - 链接与版本

    /// 头文件记录版本与运行期实际链接的 libmpv 版本一致，且为本任务预期的 2.5（0x20005）。
    func testHeaderAndLibraryAPIVersionMatch() {
        XCTAssertEqual(MPVController.headerClientAPIVersion, MPVController.linkedClientAPIVersion)
        XCTAssertEqual(MPVController.headerClientAPIVersion, 0x20005, "libmpv 客户端 API 版本应为 2.5")
    }

    // MARK: - 生命周期

    /// init/deinit 连跑 20 次：既验证不崩溃，也作为「句柄没泄漏、事件循环能干净退出」的冒烟。
    /// 若 deinit 里的 terminate_destroy 或事件循环退出有问题，这里会表现为卡死或崩溃。
    func testCreateAndDestroyTwentyTimes() throws {
        for index in 0..<20 {
            let controller = try MPVController(clientName: "smoke-\(index)")
            // 每次紧接一次属性读取，确认实例处于可用状态而非半初始化。
            XCTAssertEqual(try controller.getFlag("core-idle"), true, "第 \(index) 次实例应处于空闲态")
        }
    }

    /// 同一进程内可并存多个实例（后续可能出现「预览 + 主播放」两个核）。
    func testMultipleInstancesCoexist() throws {
        let first = try MPVController(clientName: "first")
        let second = try MPVController(clientName: "second")
        try first.setDouble("volume", 30)
        try second.setDouble("volume", 70)
        XCTAssertEqual(try first.getDouble("volume"), 30, accuracy: 0.001)
        XCTAssertEqual(try second.getDouble("volume"), 70, accuracy: 0.001)
    }

    // MARK: - 启动选项

    /// 静音启动选项真的把音频输出换成了 null 设备。
    ///
    /// 为什么要专门断言：这个选项的意义是「跑测试时不出声」，而「没听到声音」不是可靠的验收信号
    /// （机器可能整体静音、输出设备可能被占用、采样恰好很短）。直接读回 mpv 的 ao 属性才能证明
    /// 选项确实在 mpv_initialize 之前生效 —— 若设在初始化之后，mpv 会拒绝改动并保持默认输出。
    func testSilentAudioOptionSelectsNullOutput() throws {
        let silent = try MPVController(clientName: "silent", options: MPVLaunchOption.silentAudio)
        XCTAssertEqual(try silent.getString("ao"), "null", "显式传入静音选项后 AO 应为 null")

        let defaulted = try MPVController(clientName: "default-output")
        XCTAssertNotEqual(
            try defaulted.getString("ao"),
            "null",
            "未传选项的实例应使用系统默认输出，不该被静音"
        )
    }

    // MARK: - 属性读写与命令

    /// 设置 pause=true 后读回为 true（真实 libmpv 实例）。
    func testPauseRoundTrip() throws {
        let controller = try MPVController()
        XCTAssertFalse(try controller.getFlag("pause"), "初始应为非暂停")

        try controller.setFlag("pause", true)
        XCTAssertTrue(try controller.getFlag("pause"))

        try controller.play()
        XCTAssertFalse(try controller.getFlag("pause"))

        try controller.togglePause()
        XCTAssertTrue(try controller.getFlag("pause"))
    }

    /// 字符串与浮点属性的读写链路。
    func testStringAndDoublePropertyRoundTrip() throws {
        let controller = try MPVController()

        try controller.setString("audio-device", "auto")
        XCTAssertEqual(try controller.getString("audio-device"), "auto")

        try controller.setDouble("volume", 42.5)
        XCTAssertEqual(try controller.getDouble("volume"), 42.5, accuracy: 0.001)
        XCTAssertEqual(try controller.getString("volume"), "42.500000", "字符串读取走的是 mpv 的格式化输出")
    }

    /// 命令封装：数组形式与字符串形式都应被受理。
    func testCommandForms() throws {
        let controller = try MPVController()
        try controller.command(["set", "volume", "10"])
        XCTAssertEqual(try controller.getDouble("volume"), 10, accuracy: 0.001)

        try controller.commandString("set volume 20")
        XCTAssertEqual(try controller.getDouble("volume"), 20, accuracy: 0.001)

        try controller.setVolume(35)
        XCTAssertEqual(try controller.getDouble("volume"), 35, accuracy: 0.001)
    }

    /// 非法属性读取映射为 MPVError，而不是崩溃或静默返回。
    func testReadingUnknownPropertyThrows() throws {
        let controller = try MPVController()
        XCTAssertThrowsError(try controller.getDouble("definitely-not-a-real-property")) { error in
            guard case MPVError.apiFailed(let function, let code, _) = error else {
                return XCTFail("期望 MPVError.apiFailed，实际为 \(error)")
            }
            XCTAssertTrue(function.contains("definitely-not-a-real-property"))
            XCTAssertEqual(code, Int32(MPV_ERROR_PROPERTY_NOT_FOUND.rawValue))
        }

        XCTAssertThrowsError(try controller.getString("definitely-not-a-real-property")) { error in
            XCTAssertEqual(error as? MPVError, .propertyUnavailable(name: "definitely-not-a-real-property"))
        }
    }

    /// 非法命令同样映射为 MPVError。
    func testInvalidCommandThrows() throws {
        let controller = try MPVController()
        XCTAssertThrowsError(try controller.command(["this-command-does-not-exist"])) { error in
            guard case MPVError.apiFailed = error else {
                return XCTFail("期望 MPVError.apiFailed，实际为 \(error)")
            }
        }
    }

    // MARK: - 属性订阅

    /// observe time-pos 的注册/注销循环不应崩溃，且注销后控制器仍可用。
    func testObserveTimePositionRepeatedRegisterUnregister() async throws {
        let controller = try MPVController()

        for _ in 0..<10 {
            let stream = controller.observe(.timePosition)
            let consumer = Task { for await _ in stream {} }
            // 让事件循环完成一次 mpv_observe_property 回执后再注销。
            try await Task.sleep(nanoseconds: 30_000_000)
            consumer.cancel()
            _ = await consumer.value
        }

        // 反复订阅/注销后实例应仍然健康。
        XCTAssertEqual(try controller.getFlag("core-idle"), true)
    }

    /// 订阅 pause 能真实收到变更（订阅成功后 libmpv 会先推一次当前值，改值后再推一次）。
    func testObservePauseDeliversChange() async throws {
        let controller = try MPVController()
        let stream = controller.observe(.paused)

        let collector = Task { () -> [MPVPropertyChange] in
            var received: [MPVPropertyChange] = []
            for await change in stream {
                received.append(change)
                if received.contains(where: { $0.flagValue == true }) { break }
            }
            return received
        }

        // 留出初始事件派发时间，再翻转为暂停。
        try await Task.sleep(nanoseconds: 200_000_000)
        try controller.setFlag("pause", true)

        let changes = try await withTimeout(seconds: 5) { await collector.value }
        XCTAssertFalse(changes.isEmpty, "订阅 pause 后应至少收到一次变更")
        XCTAssertTrue(changes.contains { $0.property == "pause" && $0.flagValue == true })
    }

    /// 订阅 destroy（控制器 deinit）时，未消费完的流应正常结束而不是悬挂。
    func testObserverStreamFinishesWhenControllerDeallocated() async throws {
        var controller: MPVController? = try MPVController()
        let stream = try XCTUnwrap(controller).observe(.duration)

        let finished = Task { () -> Bool in
            for await _ in stream {}
            return true
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        controller = nil

        let didFinish = try await withTimeout(seconds: 5) { await finished.value }
        XCTAssertTrue(didFinish, "控制器销毁后订阅流应结束")
    }

    // MARK: - 工具

    /// 带超时地等待一个异步结果，避免测试因实现缺陷而无限挂起。
    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MPVTestTimeout()
            }
            guard let result = try await group.next() else { throw MPVTestTimeout() }
            group.cancelAll()
            return result
        }
    }
}

/// 测试内部超时标记。
private struct MPVTestTimeout: Error {}
