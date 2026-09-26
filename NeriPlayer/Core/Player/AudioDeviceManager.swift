// AudioDeviceManager.swift
// NeriPlayer macOS —— 音频输出设备枚举与切换（移植规划 M1-T7）。
//
// 职责边界（本任务只做这些）：
//   - 枚举：读 mpv 的 audio-device-list 属性（JSON）得到输出设备列表；
//   - 当前设备：读 mpv 的 audio-device 属性（默认 "auto"）；
//   - 切换：写 audio-device 属性（mpv 支持运行期热切换）；
//   - 变化通知：observe audio-device-list 属性 + 手动 refresh() 兜底。
// 不做：USB/独占输出（M8-T6）、音效链路（M8-T4）；不改 MPVController / MPVEngine /
//   PlaybackStateStore（所需能力 M1-T2 已提供：getString / setString / observe）。
//
// 为什么以 mpv 的 audio-device-list 为唯一来源：
//   在 macOS 上真正决定声音走向的是播放内核（libmpv 的 AO）。若改用系统枚举
//   （AVAudioEngine / CoreAudio API），得到的是设备 UID 或名称，而 mpv 认的是形如
//   "coreaudio/BuiltInSpeakerDevice" 的取值 —— 两者不能直接互相映射。直接采用 mpv 的
//   列表可保证「列出的名字 = 可以写进 audio-device 的值」，切换不会落空。
//   代价：命名沿用 mpv 的 AO 风格（如 coreaudio/... 、avfoundation/...），与「系统设置 →
//   声音」面板里的设备名不同，属预期行为。
//
// 为什么接收外部 MPVController 而不是自建：
//   audio-device 必须在「实际出声的那个 mpv 实例」上设置。构造注入可让本类直接作用于
//   播放侧内核，避免出现「自己 new 的实例切了设备、正在播放的实例没切」这种静默失效。

import Foundation

// MARK: - 设备模型

/// 一个音频输出设备条目。
///
/// 字段来源：实测 libmpv 0.41.0 的 audio-device-list 只提供 name / description；
/// isEnabled / isDefault 是为兼容更新版 mpv（或未来自建来源）预留的可选字段，
/// JSON 缺失时分别回退为 true / false（字段集合与移植规划 M1-T7 的描述一致）。
public struct AudioOutputDevice: Sendable, Equatable, Identifiable {

    /// mpv 的 audio-device 取值，例如 "auto"、"coreaudio/BuiltInSpeakerDevice"。
    public let name: String
    /// 面向用户的描述，例如 "Autoselect device"、"Mac mini扬声器"。
    public let description: String
    /// 该设备当前是否可用（当前 libmpv 不提供该字段，缺失时为 true）。
    public let isEnabled: Bool
    /// 是否为默认设备（当前 libmpv 不提供该字段，缺失时为 false）。
    public let isDefault: Bool

    /// 以 name 作为稳定标识（mpv 中设备名唯一）。
    public var id: String { name }

    public init(name: String, description: String, isEnabled: Bool = true, isDefault: Bool = false) {
        self.name = name
        self.description = description
        self.isEnabled = isEnabled
        self.isDefault = isDefault
    }
}

// MARK: - 错误

/// 音频输出设备操作抛出的错误。
public enum AudioDeviceError: Error, Equatable {
    /// 请求切换的设备不在当前 mpv 设备列表中。
    case unknownDevice(name: String)
}

extension AudioDeviceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownDevice(let name):
            return "音频输出设备不存在：\(name)"
        }
    }
}

// MARK: - 管理器

/// 音频输出设备的枚举、当前值查询与切换。
///
/// 线程模型：全部状态（设备快照 + 订阅者表）由 lock 串行化；mpv 属性读取直接在调用者
/// 线程进行（libmpv 的 client API 线程安全，M1-T2 已确定此约定）；订阅事件在 libmpv
/// 事件线程回流，折叠进快照后在锁外 yield。
public final class AudioDeviceManager: @unchecked Sendable {

    /// 设备列表属性名（集中一处，便于排错）。
    static let deviceListProperty = "audio-device-list"
    /// 当前设备属性名。
    static let currentDeviceProperty = "audio-device"
    /// audio-device 不可读时的回退值，与 mpv 的默认取值一致。
    public static let defaultDeviceName = "auto"

    /// 播放侧内核；本类只经其公开 API 访问 mpv。
    private let controller: MPVController

    /// 保护 cachedDevices 与 continuations：事件线程与调用者线程会交汇。
    private let lock = NSLock()
    private var cachedDevices: [AudioOutputDevice] = []
    private var continuations: [UUID: AsyncStream<[AudioOutputDevice]>.Continuation] = [:]
    /// audio-device-list 的订阅任务，deinit 时取消。
    private var observerTask: Task<Void, Never>?

    /// 用一个播放侧控制器构造。构造期间同步读一次设备列表，
    /// 因此构造结束后 `devices` 立即可用（订阅派发是异步的，不能依赖它做初始填充）。
    public init(controller: MPVController) {
        self.controller = controller
        refresh()
        startObserving()
        Log.player.info(
            "AudioDeviceManager 已就绪：设备数=\(self.devices.count) 当前=\(self.currentDevice)"
        )
    }

    deinit {
        observerTask?.cancel()
        lock.lock()
        let listeners = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for listener in listeners {
            listener.finish()
        }
    }

    // MARK: - 查询

    /// 最近一次读到的设备列表快照（首次为空时可能尚未成功读取，可调用 refresh()）。
    public var devices: [AudioOutputDevice] {
        lock.lock()
        defer { lock.unlock() }
        return cachedDevices
    }

    /// 当前音频输出设备（mpv 的 audio-device）。属性不可读时回退为 "auto"。
    public var currentDevice: String {
        do {
            return try controller.getString(Self.currentDeviceProperty)
        } catch {
            Log.player.debug(
                "读取 audio-device 失败，回退为 \(Self.defaultDeviceName)：\(error.localizedDescription)"
            )
            return Self.defaultDeviceName
        }
    }

    // MARK: - 切换

    /// 切换音频输出设备（写 mpv 的 audio-device，运行期立即生效）。
    ///
    /// 只接受当前设备列表中存在的名字；列表尚未读出（为空）时不做校验，交由内核判定，
    /// 以免因 AO 初始化瞬间导致合法名字被误拒。
    /// - Parameter name: 列表中的设备 name，例如 "auto"。
    /// - Throws: `AudioDeviceError.unknownDevice`（名字不在列表中）或 `MPVError`（内核拒绝）。
    public func selectDevice(name: String) throws {
        let known = devices
        if !known.isEmpty, !known.contains(where: { $0.name == name }) {
            Log.player.error("拒绝切换：设备不在列表中 name=\(name)")
            throw AudioDeviceError.unknownDevice(name: name)
        }
        try controller.setString(Self.currentDeviceProperty, name)
        Log.player.info("音频输出设备已切换为：\(name)")
    }

    // MARK: - 刷新与订阅

    /// 主动重读一次设备列表并广播变化。
    ///
    /// 说明：libmpv 支持观察 audio-device-list，实例化后只读该属性也会推一次当前值
    /// （本任务的实机探针已确认）。但设备热插拔时 libmpv 是否再次推送取决于 AO 实现，
    /// 未用真机外设验证，故同时保留本手动入口作为兜底（UI 可在窗口获得焦点时调用）。
    public func refresh() {
        do {
            let json = try controller.getString(Self.deviceListProperty)
            publish(decodedFrom: json)
        } catch {
            Log.player.error("读取 \(Self.deviceListProperty) 失败：\(error.localizedDescription)")
        }
    }

    /// 订阅设备列表变化：立即推一次当前快照，之后每次列表变化再推。
    /// 与 MPVEngine.observeState() 同构（每订阅者独立流、termination 时清理）。
    public func observeDevices() -> AsyncStream<[AudioOutputDevice]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.lock()
            let current = cachedDevices
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
            continuation.yield(current)
        }
    }

    // MARK: - 解析

    /// libmpv audio-device-list 的原始条目。description 之外的可选字段用于向前兼容。
    private struct RawDevice: Decodable {
        let name: String
        let description: String?
        let isEnabled: Bool?
        let isDefault: Bool?
    }

    /// 解析 audio-device-list 的 JSON 字符串。解析失败返回 nil（已记日志），
    /// 供测试直接覆盖 JSON 契约（含 isEnabled / isDefault 缺省回退）。
    static func decodeDeviceList(_ json: String) -> [AudioOutputDevice]? {
        guard let data = json.data(using: .utf8) else {
            Log.player.error("\(deviceListProperty) 内容非 UTF-8，无法解析")
            return nil
        }
        do {
            let raw = try JSONDecoder().decode([RawDevice].self, from: data)
            return raw.map { item in
                AudioOutputDevice(
                    name: item.name,
                    description: item.description ?? "",
                    isEnabled: item.isEnabled ?? true,
                    isDefault: item.isDefault ?? false
                )
            }
        } catch {
            Log.player.error("\(deviceListProperty) JSON 解析失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 内部

    /// 解析并广播；解析失败时保留旧快照，避免把 UI 上的列表清空。
    private func publish(decodedFrom json: String) {
        guard let decoded = Self.decodeDeviceList(json) else { return }
        lock.lock()
        let changed = decoded != cachedDevices
        cachedDevices = decoded
        let listeners = changed ? Array(continuations.values) : []
        lock.unlock()
        guard changed else { return }
        for listener in listeners {
            listener.yield(decoded)
        }
    }

    /// 订阅 mpv 的 audio-device-list，把 JSON 折进快照。
    /// 属性转为不可用（stringValue 为 nil）时改为主动重读一次。
    private func startObserving() {
        let stream = controller.observe(Self.deviceListProperty, format: .string, bufferingNewest: 4)
        observerTask = Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                guard let json = change.stringValue else {
                    self.refresh()
                    continue
                }
                self.publish(decodedFrom: json)
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
