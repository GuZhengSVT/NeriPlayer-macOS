// SettingsStore.swift
// M0-T5：设置存储层。用 UserDefaults 作为底层存储，提供类型安全的键常量与键粒度变更流。
//
// 设计说明：
// - 键用「类型安全常量」（SettingsKey / OptionalSettingsKey），键名集中声明在 SettingsKeys，
//   避免各处硬编码字符串、避免把 Bool 写成 String 之类的类型错配。
// - 变更流为「键粒度」：订阅者可以只关心某个键（changes(for:)），也可以订阅全部变更（changes()）。
//   选择键粒度是因为设置项之间相互独立，全局流会让订阅者被迫自行过滤；底层是同一个广播，
//   过滤只是封装，成本可忽略。
// - 存储实例可注入（init(userDefaults:)），测试用 UserDefaults(suiteName:) 隔离，不污染真实 defaults。
//
// 用法：
//   SettingsStore.shared.value(for: SettingsKeys.appAppearance)        // -> "system"
//   SettingsStore.shared.set("dark", for: SettingsKeys.appAppearance)
//   for await change in SettingsStore.shared.changes(for: SettingsKeys.appAppearance) { ... }

import Foundation

// MARK: - 值类型

/// 可作为设置项存储的基础值类型。
/// 覆盖 Bool / String / Int / Double / Data，以及 Date（以 Unix 时间戳 Double 落盘）。
public protocol SettingsValue: Equatable {
    /// 从 UserDefaults 读取；键不存在时返回 nil（用于区分「未设置」与「已设置为默认值」）。
    static func read(from defaults: UserDefaults, forKey key: String) -> Self?
    /// 写入 UserDefaults。
    func write(to defaults: UserDefaults, forKey key: String)
}

extension Bool: SettingsValue {
    public static func read(from defaults: UserDefaults, forKey key: String) -> Bool? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }
    public func write(to defaults: UserDefaults, forKey key: String) {
        defaults.set(self, forKey: key)
    }
}

extension String: SettingsValue {
    public static func read(from defaults: UserDefaults, forKey key: String) -> String? {
        defaults.string(forKey: key)
    }
    public func write(to defaults: UserDefaults, forKey key: String) {
        defaults.set(self, forKey: key)
    }
}

extension Int: SettingsValue {
    public static func read(from defaults: UserDefaults, forKey key: String) -> Int? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.integer(forKey: key)
    }
    public func write(to defaults: UserDefaults, forKey key: String) {
        defaults.set(self, forKey: key)
    }
}

extension Double: SettingsValue {
    public static func read(from defaults: UserDefaults, forKey key: String) -> Double? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }
    public func write(to defaults: UserDefaults, forKey key: String) {
        defaults.set(self, forKey: key)
    }
}

extension Data: SettingsValue {
    public static func read(from defaults: UserDefaults, forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }
    public func write(to defaults: UserDefaults, forKey key: String) {
        defaults.set(self, forKey: key)
    }
}

extension Date: SettingsValue {
    public static func read(from defaults: UserDefaults, forKey key: String) -> Date? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: key))
    }
    public func write(to defaults: UserDefaults, forKey key: String) {
        defaults.set(timeIntervalSince1970, forKey: key)
    }
}

// MARK: - 键

/// 键的公共面：变更流按 key.name 过滤，不关心值类型。
public protocol SettingsKeyType {
    /// UserDefaults 中使用的原始键名。
    var name: String { get }
}

/// 带默认值的类型安全键。读取时若未设置则回落到 default。
public struct SettingsKey<Value: SettingsValue>: SettingsKeyType {
    public let name: String
    /// 未设置时的回落默认值。
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// 可选类型安全键。未设置时读取为 nil（例如「上次处理崩溃的时间」）。
public struct OptionalSettingsKey<Value: SettingsValue>: SettingsKeyType {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }
}

/// 全部设置键的集中声明。后续任务新增设置项时在此追加，并给出默认值。
public enum SettingsKeys {
    /// 外观模式。取值 "system" / "light" / "dark"。
    public static let appAppearance = SettingsKey<String>("appAppearance", default: "system")
    /// 上次选中的主 tab 标识（供侧栏导航恢复到上次位置）。
    public static let lastSelectedTab = SettingsKey<String>("lastSelectedTab", default: "home")
    /// 最近一次「崩溃记录已处理」的时间；未处理过则为 nil。
    public static let crashReportHandledAt = OptionalSettingsKey<Date>("crashReportHandledAt")
    /// 启动后是否自动继续播放上次的现场（M3-T3 保存的现场 + M3-T5 设置项）。
    ///
    /// 默认 false：恢复到保存的进度但停在暂停态。一启动就出声对「打开应用看一眼」的场景
    /// 是打扰，而恢复队列与进度本身没有副作用，所以默认保留现场、不自动播。
    public static let resumePlaybackOnLaunch = SettingsKey<Bool>("resumePlaybackOnLaunch", default: false)
    /// 强调色。取值见 AccentColorOption.rawValue，未识别时回落到 blue。
    public static let accentColor = SettingsKey<String>("accentColor", default: "blue")
    /// 启动音量（mpv 量程 0–100）。到播放集成启动时下发一次。
    public static let defaultVolume = SettingsKey<Double>("defaultVolume", default: 70)
    /// 已加入媒体库的音乐目录列表（JSON 编码的 [LibraryDirectory]）。
    ///
    /// 存 Data 而不是让设置层理解目录结构：SettingsStore 只负责「存取一个可编码值」，
    /// 目录的字段演进（例如 M9 加书签字段）由 LibraryDirectoryStore 自己负责，
    /// 不需要每加一个字段就改一次设置层。空 Data 表示「没有配置过」。
    public static let libraryDirectories = SettingsKey<Data>("libraryDirectories", default: Data())
    /// M4: lyric presentation and per-file association/timing preferences.
    public static let lyricsFontSize = SettingsKey<Double>("lyricsFontSize", default: 28)
    public static let lyricsBlur = SettingsKey<Bool>("lyricsBlur", default: false)
    public static let lyricsTranslation = SettingsKey<Bool>("lyricsTranslation", default: true)
    public static let lyricsPhonetic = SettingsKey<Bool>("lyricsPhonetic", default: true)
    public static let lyricsAssociations = SettingsKey<Data>("lyricsAssociations", default: Data())
    public static let lyricsOffsets = SettingsKey<Data>("lyricsOffsets", default: Data())
    /// M8-T4/T6: persisted playback filters, fades and optional exclusive output.
    public static let audioEffects = SettingsKey<Data>("audioEffects", default: Data())
}

// MARK: - 变更事件

/// 一次设置变更事件。携带键名，订阅者据此读取新值。
public struct SettingsChange: Equatable {
    /// 发生变化的键名。
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

// MARK: - 存储

/// 设置存储层：UserDefaults 的类型安全封装 + 键粒度变更广播。
///
/// @unchecked Sendable：内部可变状态只有 continuations 字典，由 lock 串行化；
/// UserDefaults 自身线程安全。播放侧（后台队列）与设置页（主线程）会同时读写它，
/// 因此这个标注描述的是事实，而不只是为了消掉编译告警。
public final class SettingsStore: @unchecked Sendable {

    /// App 全局共享实例，作用于 UserDefaults.standard。
    public static let shared = SettingsStore()

    /// 底层 UserDefaults（可注入，测试用 suiteName 隔离）。
    public let userDefaults: UserDefaults

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SettingsChange>.Continuation] = [:]

    /// 用指定 UserDefaults 构造；默认使用 .standard。
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: 读取

    /// 读取带默认值的键；未设置时回落到键的默认值。
    public func value<Value>(for key: SettingsKey<Value>) -> Value {
        Value.read(from: userDefaults, forKey: key.name) ?? key.defaultValue
    }

    /// 读取可选键；未设置时为 nil。
    public func value<Value>(for key: OptionalSettingsKey<Value>) -> Value? {
        Value.read(from: userDefaults, forKey: key.name)
    }

    /// 键是否已有显式存储的值（与默认值无关）。
    public func contains(_ key: SettingsKeyType) -> Bool {
        userDefaults.object(forKey: key.name) != nil
    }

    // MARK: 写入

    /// 写入带默认值的键，并广播变更。
    public func set<Value>(_ value: Value, for key: SettingsKey<Value>) {
        value.write(to: userDefaults, forKey: key.name)
        broadcast(key: key.name)
    }

    /// 写入可选键；传 nil 等价于移除该键，并广播变更。
    public func set<Value>(_ value: Value?, for key: OptionalSettingsKey<Value>) {
        if let value {
            value.write(to: userDefaults, forKey: key.name)
        } else {
            removeValue(forKeyName: key.name)
        }
        broadcast(key: key.name)
    }

    /// 移除显式存储的值：带默认值的键回落到默认值，可选键变为 nil。并广播变更。
    public func reset(_ key: SettingsKeyType) {
        removeValue(forKeyName: key.name)
        broadcast(key: key.name)
    }

    // MARK: 变更流

    /// 订阅全部设置变更。
    public func changes() -> AsyncStream<SettingsChange> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }
        }
    }

    /// 订阅指定键的变更（键粒度过滤）。
    public func changes(for key: SettingsKeyType) -> AsyncStream<SettingsChange> {
        let upstream = changes()
        let keyName = key.name
        return AsyncStream { continuation in
            let task = Task {
                for await change in upstream where change.key == keyName {
                    continuation.yield(change)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: 内部

    private func removeValue(forKeyName name: String) {
        userDefaults.removeObject(forKey: name)
    }

    private func broadcast(key name: String) {
        let change = SettingsChange(key: name)
        Log.debug("settings changed: \(name)", to: Log.db)
        lock.lock()
        let current = Array(continuations.values)
        lock.unlock()
        for continuation in current {
            continuation.yield(change)
        }
    }

    private func removeContinuation(id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
