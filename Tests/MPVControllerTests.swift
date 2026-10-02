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

    // MARK: - 音频专用启动选项合并（问题 1）

    /// 空列表也要拿到完整的音频专用基线：调用方漏传时「不建窗」的保证不能丢。
    func testMergedLaunchOptionsKeepsAudioOnlyBaselineForEmptyInput() {
        XCTAssertEqual(MPVEngine.mergedLaunchOptions([]), MPVLaunchOption.audioOnly)
    }

    /// 只传 `.silentAudio` 时，基线一项不少，并追加 `ao=null`；同名项只保留一条。
    func testMergedLaunchOptionsAppendsSilentAudioToBaseline() {
        let merged = MPVEngine.mergedLaunchOptions(MPVLaunchOption.silentAudio)

        XCTAssertEqual(
            Array(merged.prefix(MPVLaunchOption.audioOnly.count)),
            MPVLaunchOption.audioOnly,
            "基线应完整保留在前"
        )
        XCTAssertEqual(merged.last, MPVLaunchOption(name: "ao", value: "null"))
        XCTAssertEqual(merged.count, MPVLaunchOption.audioOnly.count + 1)
        XCTAssertEqual(Set(merged.map(\.name)).count, merged.count, "不应出现同名选项（mpv 只认最后一条）")
    }

    /// 同名冲突时调用方赢：否则调用方无法覆盖基线里的某一项。
    func testMergedLaunchOptionsLetsCallerOverrideBaselineValue() {
        let override = MPVLaunchOption(name: "vid", value: "auto")
        let merged = MPVEngine.mergedLaunchOptions([override])

        XCTAssertEqual(merged.filter { $0.name == "vid" }, [override], "调用方给的值应覆盖基线")
        XCTAssertEqual(merged.count, MPVLaunchOption.audioOnly.count, "覆盖不应新增条目")
        XCTAssertEqual(merged.map(\.name), MPVLaunchOption.audioOnly.map(\.name), "覆盖不应改变顺序")
    }

    // MARK: - 音频专用启动选项真的生效（问题 1）

    /// 默认构造的引擎（`PlaybackStateStore` 的生产路径）必须拿到音频专用配置。
    ///
    /// 为什么断言这三个属性：
    ///   - `audio-display` 是封面窗口的**根治**手段（默认 embedded-first 会把内嵌封面当视频轨渲染）；
    ///   - `vid` 保证即使流里真有视频轨也不选它（B 站渐进式回退流就是 video/mp4）；
    ///   - `vo` 是最后一道兜底：任何情况下都不配置视频输出。
    /// 三条都是「初始化之后再设就改不动」的启动选项，只能在 mpv_initialize 之前下发，
    /// 因此读回它们就等于证明启动选项链路是通的（与静音选项的验证方式一致）。
    ///
    /// 读法说明（实测）：`vo` 是对象型选项，读字符串得到 "null"；`vid` / `audio-display` 是
    /// choice 选项，读字符串得到取值名。三者都不支持 getFlag（会返回「unsupported format」），
    /// 所以一律用字符串读回。
    func testEngineDefaultOptionsAreAudioOnly() throws {
        // 默认构造：PlaybackStateStore.init(clientName:) 走的就是这条路径。
        let engine = try MPVEngine(clientName: "engine-default-options")
        XCTAssertEqual(try engine.readBackProperty("audio-display"), "no")
        XCTAssertEqual(try engine.readBackProperty("vid"), "no")
        XCTAssertEqual(try engine.readBackProperty("vo"), "null")

        // 只传静音选项的测试夹具同样继承基线：合并语义在真实初始化路径上的落点。
        let silent = try MPVEngine(clientName: "engine-silent-options", options: MPVLaunchOption.silentAudio)
        XCTAssertEqual(try silent.readBackProperty("audio-display"), "no")
        XCTAssertEqual(try silent.readBackProperty("vid"), "no")
        XCTAssertEqual(try silent.readBackProperty("vo"), "null")
        XCTAssertEqual(try silent.readBackProperty("ao"), "null", "显式传入的静音选项仍应生效")

        // 负对照：不带任何选项的裸 controller 仍是 mpv 默认值。没有这条对照，
        // 上面的 no/null 有可能只是这台机器上 mpv 的默认值，测试就失去了判别力。
        let bare = try MPVController(clientName: "bare-options")
        XCTAssertEqual(try bare.getString("audio-display"), "embedded-first", "mpv 默认应显示内嵌封面")
        XCTAssertNotEqual(try bare.getString("vid"), "no", "mpv 默认允许视频轨")
    }

    /// 带内嵌封面的素材在音频专用配置下不会产生活动的视频轨，也没有选中任何视频输出。
    ///
    /// 诚实说明本用例的边界（实测结论，用 vendored libmpv + ctypes 探针得到）：
    ///   1) `Tests/Fixtures/Audio/tagged.mp3` 确实内嵌一张 PNG（ffprobe 报 `1,png,video`），
    ///      mpv 也把它列成 track-list/1（type=video），这一点可以稳定断言；
    ///   2) 但「封面被当成活动视频轨」只在**真有窗口服务器**时才会走到（用户看到的是一个
    ///      gpu-next 顶层窗口）。测试进程没有窗口服务器，mpv 即便用默认配置也会退回 `vid=no`、
    ///      `current-vo` 为空，因此**无法**在这里复现「开窗 / 关窗 → QUIT」那条现场路径。
    ///   3) 所以本用例的判别力来自「配置读回」：`audio-display=no` 与 `vid=no` 正是让封面
    ///      不进入视频轨的原因（负对照见上一条用例），而不是来自运行期有没有真的开窗。
    func testCoverArtFixtureDoesNotBecomeAnActiveVideoTrack() throws {
        let fixture = try fixtureURL(named: "tagged.mp3")
        // 用 .silentAudio 构造：它会在合并后得到「基线 + ao=null」，既不出声也保持无窗口。
        let engine = try MPVEngine(clientName: "cover-art-audio-only", options: MPVLaunchOption.silentAudio)
        // 暂停加载：keep 住已打开的文件与轨道列表，避免 0.56s 素材在断言前就播完卸载。
        try engine.load(url: fixture, paused: true)

        // 等封面轨出现在 track list 上：它证明这个素材确实是「带内嵌封面」的那一类。
        // mpv 的属性可用性在加载过程中会短暂抖动（同一属性时而可读时而不存在），所以这里轮询
        // 到「读到 type=video」为止而不是读一次就断言，避免把时序抖动误判成回归。
        let deadline = Date().addingTimeInterval(5)
        var coverType: String?
        var coverSelected: String?
        while Date() < deadline, coverSelected == nil {
            if let type = try? engine.readBackProperty("track-list/1/type"), type == "video" {
                coverType = type
                coverSelected = try? engine.readBackProperty("track-list/1/selected")
            }
            if coverSelected == nil { Thread.sleep(forTimeInterval: 0.02) }
        }
        XCTAssertEqual(coverType, "video", "素材应内嵌一条封面视频轨（否则本用例验证不到点子上）")

        // 封面轨没有被选中 —— 它没有被当成活动视频轨。
        XCTAssertNotEqual(coverSelected, "yes", "封面轨不应被选中（实际读到 \(coverSelected ?? "nil")）")

        // 音频专用配置仍在（这三条才是让封面不进入视频链路的原因）。
        XCTAssertEqual(try engine.readBackProperty("audio-display"), "no")
        XCTAssertEqual(try engine.readBackProperty("vid"), "no")
        XCTAssertEqual(try engine.readBackProperty("vo"), "null")

        // 没有任何视频输出产生帧：没有视频输出时 video-format 属性不可读（或为空）。
        // 注意这条在无窗口服务器的测试进程里即便用默认配置也成立（见上面的边界说明），
        // 它的作用是「不出现反例」，判别力不及上面三条配置读回。
        let videoFormat = try? engine.readBackProperty("video-format")
        XCTAssertTrue(videoFormat?.isEmpty ?? true, "不应有视频输出格式，实际为 \(videoFormat ?? "nil")")
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

    /// 定位 `Tests/Fixtures/Audio` 下的素材（`.copy("Fixtures/Audio")` 会以 Audio 为名落在资源根）。
    /// 与 LibraryScannerTests 同一取舍：素材缺失时跳过而不是失败，避免把环境问题当成回归。
    private func fixtureURL(named name: String) throws -> URL {
        if let directory = Bundle.module.url(forResource: "Audio", withExtension: nil) {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        if let resources = Bundle.module.resourceURL {
            let candidate = resources.appendingPathComponent("Audio", isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw XCTSkip("缺少测试素材 \(name)（Tests/Fixtures/Audio）")
    }

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
