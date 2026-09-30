// MPVController.swift
// NeriPlayer macOS —— libmpv C API 的 Swift 封装（移植规划 M1-T2）。
//
// 职责边界（本任务只做这些）：
//   - 生命周期：mpv_create / mpv_initialize / mpv_terminate_destroy；
//   - 事件循环：专用串行 DispatchQueue 上跑 mpv_wait_event 循环；
//   - 属性订阅：mpv_observe_property / mpv_unobserve_property → AsyncStream 派发；
//   - 命令与属性读写：command / get / set 的类型化封装；
//   - 错误统一为 MPVError，日志走 Log.player。
// 不做：播放队列、音源解析、音频输出设备选择、渲染（属 M1-T3 及之后）。
//
// 两层结构（为什么不是一个类）：
//   MPVController        对外类型化门面（play / seek / observe 等）；拥有 MPVEventLoop。
//   MPVEventLoop         句柄 + 事件循环的实际所有者；循环任务强引用它。
//   若把 mpv_wait_event 循环直接写在 MPVController 上，循环就会一直强引用控制器，
//   而 deinit 需要引用计数归零 —— 循环自身就是那个永远不释放的引用，于是控制器
//   永不析构、循环永不退出，释放时直接死锁（这是实测踩到的坑）。
//   拆出 MPVEventLoop 后：循环强引用引擎、控制器强引用引擎，引擎不反向引用控制器，
//   所以控制器可以正常析构，并在 deinit 里显式关闭引擎。
//
// 线程模型（依据 mpv/client.h 的 Multithreading 一节）：
//   「The client API is generally fully thread-safe, unless otherwise noted.」
//   「Only one thread is allowed to call [mpv_wait_event] on the same mpv_handle at a time.」
//   因此只把 mpv_wait_event 收在专用串行队列上独占执行，其余 API（command / get /
//   set / observe / unobserve）都在调用者线程直接调用，由 libmpv 自身的锁串行化。
//   边界很重要：不能把这些调用也 sync 到事件队列 —— 事件循环长期占用该队列，
//   sync 会永久排队，必然死锁。
//
// 事件循环线程不执行任何用户代码：属性变更只做 continuation.yield（线程安全、非阻塞、
//   缓冲满时丢最旧值），消费者在自己的执行上下文 await 取值。

import CMpv
import Foundation
import os

// MARK: - 错误

/// MPVController 抛出的统一错误类型。
public enum MPVError: Error, Equatable {
    /// mpv_create() 返回空指针（通常是内存不足）。
    case handleCreationFailed
    /// mpv_initialize() 失败。
    case initializationFailed(code: Int32, message: String)
    /// 任一 mpv C API 返回负值。
    case apiFailed(function: String, code: Int32, message: String)
    /// 属性不存在或当前不可读。
    case propertyUnavailable(name: String)
    /// 控制器已销毁，不能再发起调用。
    case destroyed
}

extension MPVError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .handleCreationFailed:
            return "libmpv 句柄创建失败（mpv_create 返回 NULL）"
        case .initializationFailed(let code, let message):
            return "libmpv 初始化失败：\(message)（code=\(code)）"
        case .apiFailed(let function, let code, let message):
            return "libmpv 调用 \(function) 失败：\(message)（code=\(code)）"
        case .propertyUnavailable(let name):
            return "libmpv 属性不可用：\(name)"
        case .destroyed:
            return "MPVController 已销毁"
        }
    }
}

// MARK: - 属性与格式

/// libmpv 属性的取值格式（对应 enum mpv_format 的子集）。
public enum MPVFormat: Sendable {
    case flag
    case double
    case string
    case int64

    var mpvFormat: mpv_format {
        switch self {
        case .flag: return MPV_FORMAT_FLAG
        case .double: return MPV_FORMAT_DOUBLE
        case .string: return MPV_FORMAT_STRING
        case .int64: return MPV_FORMAT_INT64
        }
    }
}

/// M1 阶段需要观察的属性。rawValue 即 libmpv 的属性名。
public enum MPVProperty: String, Sendable, CaseIterable {
    /// 当前播放位置（秒）。
    case timePosition = "time-pos"
    /// 当前文件总时长（秒）。
    case duration = "duration"
    /// 是否暂停。
    case paused = "pause"
    /// 是否播放到文件末尾。
    case eofReached = "eof-reached"
    /// 播放核心是否空闲（无文件加载时为 true）。
    case coreIdle = "core-idle"

    /// 观察该属性时使用的格式。
    public var format: MPVFormat {
        switch self {
        case .timePosition, .duration:
            return .double
        case .paused, .eofReached, .coreIdle:
            return .flag
        }
    }
}

/// 一次属性变更通知。value 为 .unavailable 表示 libmpv 当前取不到该属性
/// （例如未加载文件时的 time-pos），这不是错误。
public struct MPVPropertyChange: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case flag(Bool)
        case double(Double)
        case string(String)
        case int64(Int64)
        case unavailable
    }

    /// 属性名（与 MPVProperty.rawValue 或传入的原始属性名一致）。
    public let property: String
    public let value: Value

    public var flagValue: Bool? {
        if case .flag(let value) = value { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let value) = value { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = value { return value }
        return nil
    }

    public var int64Value: Int64? {
        if case .int64(let value) = value { return value }
        return nil
    }
}

/// loadfile 命令的加载模式。
public enum MPVLoadFileMode: String, Sendable {
    case replace
    case append
    case appendPlay = "append-play"
}

/// seek 命令的模式。
public enum MPVSeekMode: String, Sendable {
    case relative = "relative"
    case absolute = "absolute"
    case absolutePercent = "absolute-percent"
}

// MARK: - 事件循环引擎

/// libmpv 句柄与事件循环的所有者。MPVController 的私有实现细节。
///
/// 本类被 mpv_wait_event 循环强引用，因此本类不得持有 MPVController，
/// 否则又会构成「循环不释放 → 控制器不析构」的闭环。
final class MPVEventLoop: @unchecked Sendable {

    /// mpv_wait_event 的单次等待上限（秒）。被 mpv_wakeup 打断时立即返回。
    private static let waitTimeout: Double = 0.1

    private let handle: OpaquePointer
    private let queue: DispatchQueue

    /// 保护下列可变状态：事件循环线程与调用者线程会短暂交汇。
    private let lock = NSLock()
    private var stopRequested = false
    private var tornDown = false
    private var observers: [UInt64: AsyncStream<MPVPropertyChange>.Continuation] = [:]
    private var nextObserverToken: UInt64 = 1

    /// 用已初始化的句柄构造引擎；队列名与 MPVController 对外声明的一致，便于采样辨认。
    init(handle: OpaquePointer) {
        self.handle = handle
        queue = DispatchQueue(label: MPVController.eventQueueLabel)
    }

    // MARK: 事件循环

    /// 启动 mpv_wait_event 循环。刻意强引用 self：循环运行期间引擎必须存活。
    /// 这不会造成泄漏，因为引擎的生命周期由 MPVController 控制 —— 控制器析构时
    /// 会调用 shutdown() 结束循环，循环结束后引擎随之释放。
    func start() {
        queue.async { self.runLoop() }
    }

    /// 事件循环主体，独占 queue。
    private func runLoop() {
        Log.player.debug("mpv 事件循环启动：\(MPVController.eventQueueLabel)")
        while !isStopRequested() {
            guard let eventPointer = mpv_wait_event(handle, Self.waitTimeout) else { continue }
            let event = eventPointer.pointee
            if event.event_id == MPV_EVENT_NONE {
                continue
            }
            if event.event_id == MPV_EVENT_SHUTDOWN {
                Log.player.info("mpv 报告 shutdown，事件循环退出")
                break
            }
            dispatch(event: event)
        }
        Log.player.debug("mpv 事件循环结束")
    }

    /// 分发单个事件。只在事件循环线程上执行。
    private func dispatch(event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE, MPV_EVENT_GET_PROPERTY_REPLY:
            guard let raw = event.data else { return }
            let change = Self.makeChange(
                property: raw.assumingMemoryBound(to: mpv_event_property.self).pointee
            )
            // 先取出 continuation（短暂持锁），再在锁外 yield，
            // 避免消费者侧 onTermination 回调与事件线程争同一把锁。
            observer(for: event.reply_userdata)?.yield(change)
        case MPV_EVENT_LOG_MESSAGE:
            log(event: event)
        default:
            // 其余事件（SEEK / PLAYBACK_RESTART / FILE_LOADED 等）M1-T2 不消费，
            // 需要时在 M1-T3 通过新增订阅接口暴露。
            break
        }
    }

    /// 把 libmpv 的日志事件转写到 Log.player。
    private func log(event: mpv_event) {
        guard let raw = event.data else { return }
        let message = raw.assumingMemoryBound(to: mpv_event_log_message.self).pointee
        let prefix = message.prefix.map { String(cString: $0) } ?? "mpv"
        let text = message.text.map { String(cString: $0) } ?? ""
        Log.player.debug("libmpv[\(prefix)] \(text)")
    }

    /// 关闭事件循环并销毁句柄。由 MPVController.deinit 调用，此时已无其他强引用。
    func shutdown() {
        // 1) 置停止标志并唤醒可能正在等待的 mpv_wait_event。
        lock.lock()
        stopRequested = true
        lock.unlock()
        mpv_wakeup(handle)

        // 2) 用队列自身的 FIFO 顺序作屏障，等事件循环跑完并退出。
        //    若 start() 的 block 还没被调度，本屏障先执行，随后它运行时看到的
        //    stopRequested 已是 true，会立即退出，不会再有 mpv_wait_event 在跑。
        queue.sync { }

        // 3) 结束所有订阅流（消费者看到流正常结束）。此刻句柄仍有效，
        //    因此 onTermination 触发的 unobserve 是安全的。
        finishAllObservers()

        // 4) 标记已销毁后再释放句柄，杜绝后续误用（例如迟到的一次 unobserve）。
        lock.lock()
        tornDown = true
        lock.unlock()
        mpv_terminate_destroy(handle)
        Log.player.info("MPVController 已销毁")
    }

    // MARK: 状态访问

    private func isStopRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    private func observer(for token: UInt64) -> AsyncStream<MPVPropertyChange>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return observers[token]
    }

    /// 结束所有订阅流并清空订阅表（先快照再在锁外 finish，避免重入同一把锁）。
    private func finishAllObservers() {
        lock.lock()
        let continuations = Array(observers.values)
        observers.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.finish()
        }
    }

    /// 校验引擎仍可用并返回句柄。
    /// 说明：shutdown 只在 MPVController.deinit 里发生，而 Swift 保证方法调用期间
    /// 接收者存活，故不会出现「调用中途句柄被销毁」的竞态；本检查用于拦住懒惰误用。
    private func liveHandle() throws -> OpaquePointer {
        lock.lock()
        defer { lock.unlock() }
        guard !tornDown else {
            throw MPVError.destroyed
        }
        return handle
    }

    // MARK: 命令

    /// 执行 mpv 命令（对应 mpv_command，参数数组形式）。
    func command(_ arguments: [String]) throws {
        let handle = try liveHandle()
        let cArguments: [UnsafePointer<CChar>?] = arguments.map { argument in
            guard let duplicated = strdup(argument) else { return nil }
            return UnsafePointer(duplicated)
        }
        // free(nil) 是合法的空操作，故此处无需过滤。
        defer { for pointer in cArguments { free(UnsafeMutableRawPointer(mutating: pointer)) } }
        let terminated = cArguments + [nil]
        let status = terminated.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return Int32(MPV_ERROR_INVALID_PARAMETER.rawValue) }
            return mpv_command(handle, UnsafeMutablePointer(mutating: base))
        }
        try Self.check(status, function: "mpv_command(\(arguments.joined(separator: " ")))")
    }

    /// 执行 mpv 命令（对应 mpv_command_string，字符串形式，内部按 mpv 语法分词）。
    func commandString(_ commandLine: String) throws {
        let handle = try liveHandle()
        let status = commandLine.withCString { mpv_command_string(handle, $0) }
        try Self.check(status, function: "mpv_command_string(\(commandLine))")
    }

    // MARK: 属性读写

    func getString(_ name: String) throws -> String {
        let handle = try liveHandle()
        guard let raw = mpv_get_property_string(handle, name) else {
            throw MPVError.propertyUnavailable(name: name)
        }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    func getFlag(_ name: String) throws -> Bool {
        let handle = try liveHandle()
        var value: Int32 = 0
        let status = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_FLAG, &value) }
        try Self.check(status, function: "mpv_get_property(\(name), FLAG)")
        return value != 0
    }

    func getDouble(_ name: String) throws -> Double {
        let handle = try liveHandle()
        var value: Double = 0
        let status = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_DOUBLE, &value) }
        try Self.check(status, function: "mpv_get_property(\(name), DOUBLE)")
        return value
    }

    func getInt64(_ name: String) throws -> Int64 {
        let handle = try liveHandle()
        var value: Int64 = 0
        let status = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_INT64, &value) }
        try Self.check(status, function: "mpv_get_property(\(name), INT64)")
        return value
    }

    func setString(_ name: String, _ value: String) throws {
        let handle = try liveHandle()
        let status = name.withCString { namePointer in
            value.withCString { valuePointer in
                mpv_set_property_string(handle, namePointer, valuePointer)
            }
        }
        try Self.check(status, function: "mpv_set_property_string(\(name))")
    }

    func setFlag(_ name: String, _ value: Bool) throws {
        let handle = try liveHandle()
        var flag: Int32 = value ? 1 : 0
        let status = name.withCString { mpv_set_property(handle, $0, MPV_FORMAT_FLAG, &flag) }
        try Self.check(status, function: "mpv_set_property(\(name), FLAG)")
    }

    func setDouble(_ name: String, _ value: Double) throws {
        let handle = try liveHandle()
        var number = value
        let status = name.withCString { mpv_set_property(handle, $0, MPV_FORMAT_DOUBLE, &number) }
        try Self.check(status, function: "mpv_set_property(\(name), DOUBLE)")
    }

    // MARK: 属性订阅

    /// 建立订阅，立即返回变更流。注册是同步的，故流建立后即可收到事件。
    func observe(
        _ propertyName: String,
        format: MPVFormat,
        bufferingNewest: Int
    ) -> AsyncStream<MPVPropertyChange> {
        AsyncStream(bufferingPolicy: .bufferingNewest(bufferingNewest)) { continuation in
            let token = registerObserver(name: propertyName, format: format, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                self?.unregisterObserver(token: token)
            }
        }
    }

    /// 注册一次订阅，返回事件回传用的 token。
    @discardableResult
    private func registerObserver(
        name: String,
        format: MPVFormat,
        continuation: AsyncStream<MPVPropertyChange>.Continuation
    ) -> UInt64 {
        lock.lock()
        let token = nextObserverToken
        nextObserverToken &+= 1
        let usable = !tornDown
        observers[token] = continuation
        lock.unlock()

        guard usable else {
            removeObserver(token: token)
            continuation.finish()
            return token
        }

        let status = name.withCString { mpv_observe_property(handle, token, $0, format.mpvFormat) }
        if status < 0 {
            removeObserver(token: token)
            continuation.finish()
            Log.player.error("mpv_observe_property 失败：name=\(name) code=\(status)")
        }
        return token
    }

    /// 注销一次订阅。
    private func unregisterObserver(token: UInt64) {
        let existed = removeObserver(token: token)
        guard existed, !isTornDown() else { return }
        let removed = mpv_unobserve_property(handle, token)
        if removed < 0 {
            Log.player.error("mpv_unobserve_property 失败：token=\(token) code=\(removed)")
        }
    }

    /// 从订阅表移除并返回此前是否存在。持锁操作。
    @discardableResult
    private func removeObserver(token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return observers.removeValue(forKey: token) != nil
    }

    private func isTornDown() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tornDown
    }

    // MARK: 工具

    /// 由 mpv_event_property 构造一次变更通知。
    private static func makeChange(property: mpv_event_property) -> MPVPropertyChange {
        let name = property.name.map { String(cString: $0) } ?? ""
        guard let data = property.data else {
            return MPVPropertyChange(property: name, value: .unavailable)
        }
        switch property.format {
        case MPV_FORMAT_FLAG:
            return MPVPropertyChange(
                property: name,
                value: .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0)
            )
        case MPV_FORMAT_DOUBLE:
            return MPVPropertyChange(
                property: name,
                value: .double(data.assumingMemoryBound(to: Double.self).pointee)
            )
        case MPV_FORMAT_INT64:
            return MPVPropertyChange(
                property: name,
                value: .int64(data.assumingMemoryBound(to: Int64.self).pointee)
            )
        case MPV_FORMAT_STRING:
            guard let raw = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else {
                return MPVPropertyChange(property: name, value: .unavailable)
            }
            return MPVPropertyChange(property: name, value: .string(String(cString: raw)))
        default:
            return MPVPropertyChange(property: name, value: .unavailable)
        }
    }

    /// 把负的 mpv 返回码转成 MPVError。
    static func check(_ status: Int32, function: String) throws {
        guard status < 0 else { return }
        let error = MPVError.apiFailed(function: function, code: status, message: errorMessage(for: status))
        Log.player.error("\(error.localizedDescription)")
        throw error
    }

    /// 把 mpv 错误码转成可读文本。
    static func errorMessage(for code: Int32) -> String {
        guard let raw = mpv_error_string(code) else { return "未知错误（code=\(code)）" }
        return String(cString: raw)
    }
}

// MARK: - 启动选项

/// 一条 mpv 启动选项（等价于命令行的 `--name=value`）。
///
/// 与运行期属性的区别：启动选项只在 `mpv_initialize` 之前有效，用来决定内核**以什么形态**
/// 起来（音频输出、解码器、配置来源等）；初始化之后同名项属于运行期属性，语义与可写性都不同。
public struct MPVLaunchOption: Equatable, Sendable {

    /// 选项名（不含前导 `--`）。
    public let name: String
    /// 选项值；会被 mpv 按该选项自身的语法解析。
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    /// 把音频输出接到 null 设备：音频照常解码、照常推进时钟，只是最后的输出环节把采样丢弃。
    ///
    /// 用途是测试：本仓库的播放素材是系统提示音（/System/Library/Sounds/*.aiff），
    /// 真机跑测试会持续出声。刻意不用 `audio=no` —— 那会整个关掉音频轨，文件在 mpv 眼里
    /// 变成「没有音轨」，测到的就不是真实的解码与时钟，而是一个被削掉一半的播放链路。
    /// `ao=null` 保留完整链路，只换掉输出设备。
    ///
    /// 为什么不是默认全局静音：音频输出设备枚举（M1-T7 的 AudioDeviceManager）测的正是
    /// 「当前 AO 下有哪些设备」，全局换成 null 会让那份设备列表退化成只有 null 一项。
    /// 因此由需要出声的测试夹具显式传入，而不是塞进所有实例的默认值。
    public static let silentAudio: [MPVLaunchOption] = [
        MPVLaunchOption(name: "ao", value: "null")
    ]
}

// MARK: - 对外门面

/// libmpv 实例的 Swift 封装：一个实例对应一个 mpv_handle。
///
/// 采用 @unchecked Sendable：自身无可变状态，全部状态由内部的 MPVEventLoop 持有并加锁。
public final class MPVController: @unchecked Sendable {

    /// 事件循环队列名，便于在 Instruments / 采样中辨认。
    public static let eventQueueLabel = "moe.ouom.NeriPlayer.mpv.event-loop"

    private let engine: MPVEventLoop

    /// 头文件里记录的 libmpv 客户端 API 版本（例如 0x20005 表示 2.5）。
    public static var headerClientAPIVersion: Int32 { np_mpv_shim_header_api_version() }

    /// 运行时实际加载的 libmpv 动态库报告的客户端 API 版本。
    public static var linkedClientAPIVersion: Int32 { np_mpv_shim_library_api_version() }

    /// 创建并初始化一个 libmpv 实例，随后启动事件循环。
    /// - Parameters:
    ///   - clientName: 仅用于日志标注，便于区分同进程内的多个实例。
    ///   - options: 启动选项，在 mpv_initialize 之前下发；默认无。
    public init(clientName: String = "NeriPlayer", options: [MPVLaunchOption] = []) throws {
        guard let handle = mpv_create() else {
            Log.player.error("mpv_create 返回 NULL，无法创建实例")
            throw MPVError.handleCreationFailed
        }

        // 启动选项必须在 mpv_initialize 之前设置：mpv 只在初始化时读取它们，
        // 之后再设同名项只会被当成「运行期属性」，其中一部分（如 ao）根本改不动。
        for option in options {
            let optionStatus = mpv_set_option_string(handle, option.name, option.value)
            if optionStatus < 0 {
                let message = MPVEventLoop.errorMessage(for: optionStatus)
                Log.player.error("mpv 启动选项未生效：\(option.name)=\(option.value)（\(message)）")
            }
        }

        let status = mpv_initialize(handle)
        guard status >= 0 else {
            let message = MPVEventLoop.errorMessage(for: status)
            // 初始化失败时 init 会抛出，deinit 不会被调用，必须在此手动销毁。
            mpv_terminate_destroy(handle)
            Log.player.error("mpv_initialize 失败：\(message)（code=\(status)）")
            throw MPVError.initializationFailed(code: status, message: message)
        }

        // 把 libmpv 自身日志接到 Log.player；失败只降级为「没有 mpv 内部日志」，不影响可用性。
        let logStatus = mpv_request_log_messages(handle, "warn")
        if logStatus < 0 {
            Log.player.debug("mpv_request_log_messages 未生效：code=\(logStatus)")
        }

        engine = MPVEventLoop(handle: handle)
        Log.player.info(
            "MPVController 已初始化 client=\(clientName) headerAPI=\(Self.headerClientAPIVersion) libAPI=\(Self.linkedClientAPIVersion)"
        )
        engine.start()
    }

    deinit {
        engine.shutdown()
    }

    // MARK: 命令

    /// 执行 mpv 命令（对应 mpv_command，参数数组形式）。
    public func command(_ arguments: [String]) throws {
        try engine.command(arguments)
    }

    /// 执行 mpv 命令（对应 mpv_command_string，字符串形式，内部按 mpv 语法分词）。
    public func commandString(_ commandLine: String) throws {
        try engine.commandString(commandLine)
    }

    /// 加载文件。
    public func loadFile(_ path: String, mode: MPVLoadFileMode = .replace) throws {
        if mode == .replace {
            try command(["loadfile", path])
        } else {
            try command(["loadfile", path, mode.rawValue])
        }
    }

    /// 开始/继续播放（清空 pause）。
    public func play() throws {
        try setFlag("pause", false)
    }

    /// 暂停。
    public func pause() throws {
        try setFlag("pause", true)
    }

    /// 在播放/暂停间切换。
    public func togglePause() throws {
        try command(["cycle", "pause"])
    }

    /// 停止播放并卸载当前文件。
    public func stop() throws {
        try command(["stop"])
    }

    /// 跳转到指定时间（默认绝对秒数）。
    public func seek(to seconds: Double, mode: MPVSeekMode = .absolute) throws {
        try command(["seek", String(seconds), mode.rawValue])
    }

    /// 设置音量（mpv 音量范围 0–100，可超过 100）。
    public func setVolume(_ volume: Double) throws {
        try setDouble("volume", volume)
    }

    /// 把布尔属性取反（对应 mpv 的 cycle 命令）。
    public func toggleFlag(_ name: String) throws {
        try command(["cycle", name])
    }

    // MARK: 属性读写

    /// 读取字符串属性。
    public func getString(_ name: String) throws -> String {
        try engine.getString(name)
    }

    /// 读取布尔（flag）属性。
    public func getFlag(_ name: String) throws -> Bool {
        try engine.getFlag(name)
    }

    /// 读取浮点属性。
    public func getDouble(_ name: String) throws -> Double {
        try engine.getDouble(name)
    }

    /// 读取 64 位整数属性。
    public func getInt64(_ name: String) throws -> Int64 {
        try engine.getInt64(name)
    }

    /// 写入字符串属性。
    public func setString(_ name: String, _ value: String) throws {
        try engine.setString(name, value)
    }

    /// 写入布尔（flag）属性。
    public func setFlag(_ name: String, _ value: Bool) throws {
        try engine.setFlag(name, value)
    }

    /// 写入浮点属性。
    public func setDouble(_ name: String, _ value: Double) throws {
        try engine.setDouble(name, value)
    }

    // MARK: 属性订阅

    /// 订阅一个已知属性，返回变更流。
    ///
    /// 订阅在返回前同步完成注册；流的消费者在 mpv 事件线程之外执行；
    /// 流终止（消费者取消或控制器销毁）时自动 mpv_unobserve_property。
    public func observe(_ property: MPVProperty, bufferingNewest: Int = 64) -> AsyncStream<MPVPropertyChange> {
        observe(property.rawValue, format: property.format, bufferingNewest: bufferingNewest)
    }

    /// 订阅任意属性名（原始字符串），用于 MPVProperty 未列出的属性。
    public func observe(
        _ propertyName: String,
        format: MPVFormat,
        bufferingNewest: Int = 64
    ) -> AsyncStream<MPVPropertyChange> {
        engine.observe(propertyName, format: format, bufferingNewest: bufferingNewest)
    }
}
