// SettingsViewModel.swift
// NeriPlayer macOS —— 设置页的状态与持久化（移植规划 M3-T5）。
//
// 定位：把「设置页读到什么、改了什么会写到哪里」从 SwiftUI 视图里拿出来，做成可单测的
// MainActor 对象。视图只负责渲染与把用户动作转发过来。
//
// 为什么是「写时同步持久化 + 本地副本」而不是直接读 SettingsStore：
//   1) SwiftUI 需要一个可观察对象来驱动重绘，SettingsStore 只是 UserDefaults 的封装，
//      本身不发布变更（它的 AsyncStream 是键粒度事件，用来做重绘太细）；
//   2) 读取集中在 init 一次，视图渲染路径上不再碰 UserDefaults；
//   3) 写入点收敛在本类，避免多个视图各自写同一个键。
//
// 目录列表的读写委托给 LibraryDirectoryStore：本类只负责「改完刷新本地副本」。

import Foundation

/// 设置页视图模型。钉在 MainActor 上：@Published 的写入与视图读取都只在主线程。
@MainActor
public final class SettingsViewModel: ObservableObject {

    // MARK: 可观察状态

    /// 主题外观。
    @Published public private(set) var appearance: AppearanceMode
    /// 强调色。
    @Published public private(set) var accent: AccentColorOption
    /// 启动后是否继续播放上次的现场。
    @Published public private(set) var resumePlaybackOnLaunch: Bool
    /// 启动音量（mpv 量程 0–100）。
    @Published public private(set) var defaultVolume: Double
    /// 已加入媒体库的音乐目录。
    @Published public private(set) var directories: [LibraryDirectory]
    /// 最近一次操作的反馈文案；nil 表示没有需要展示的内容。
    @Published public private(set) var statusMessage: String?

    // MARK: 依赖

    private let settings: SettingsStore
    private let directoryStore: LibraryDirectoryStore
    /// 重新扫描一个目录的动作。由持有媒体库视图模型的调用方注入 ——
    /// 设置页不该自己去拿 LibraryViewModel，否则两者会互相引用。
    ///
    /// 标 @MainActor：注入的实现要调用 LibraryViewModel（MainActor）的导入入口，
    /// 声明成主线程隔离的闭包，调用点就不需要再自己跳线程，也不会误在后台线程碰界面状态。
    private let rescanHandler: @MainActor (URL) -> Void

    public init(
        settings: SettingsStore = .shared,
        directoryStore: LibraryDirectoryStore? = nil,
        rescanHandler: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        self.settings = settings
        self.directoryStore = directoryStore ?? LibraryDirectoryStore(settings: settings)
        self.rescanHandler = rescanHandler
        self.appearance = AppearanceMode(storedValue: settings.value(for: SettingsKeys.appAppearance))
        self.accent = AccentColorOption(storedValue: settings.value(for: SettingsKeys.accentColor))
        self.resumePlaybackOnLaunch = settings.value(for: SettingsKeys.resumePlaybackOnLaunch)
        self.defaultVolume = PlaybackBehaviorDefaults.clampedVolume(
            settings.value(for: SettingsKeys.defaultVolume)
        )
        self.directories = self.directoryStore.all()
    }

    // MARK: 外观

    public func setAppearance(_ mode: AppearanceMode) {
        guard mode != appearance else { return }
        appearance = mode
        settings.set(mode.rawValue, for: SettingsKeys.appAppearance)
    }

    public func setAccent(_ option: AccentColorOption) {
        guard option != accent else { return }
        accent = option
        settings.set(option.rawValue, for: SettingsKeys.accentColor)
    }

    // MARK: 播放行为

    public func setResumePlaybackOnLaunch(_ enabled: Bool) {
        guard enabled != resumePlaybackOnLaunch else { return }
        resumePlaybackOnLaunch = enabled
        settings.set(enabled, for: SettingsKeys.resumePlaybackOnLaunch)
    }

    /// 设置启动音量。越界值与 NaN 一律夹到合法区间后再存 —— 把「夹取」放在写入侧，
    /// 读取侧就不必再防御一次，也保证存进去的一定是可用的值。
    public func setDefaultVolume(_ value: Double) {
        let clamped = PlaybackBehaviorDefaults.clampedVolume(value)
        guard clamped != defaultVolume else { return }
        defaultVolume = clamped
        settings.set(clamped, for: SettingsKeys.defaultVolume)
    }

    // MARK: 媒体库目录

    /// 加入一个目录（已存在时幂等，并给出提示）。
    public func addDirectory(_ url: URL) {
        let alreadyPresent = directoryStore.contains(url)
        let directory = directoryStore.add(url)
        directories = directoryStore.all()
        statusMessage = alreadyPresent
            ? "「\(directory.displayName)」已在媒体库目录中"
            : "已加入媒体库目录：\(directory.displayName)"
        // 加入即同步一次，用户不必再去媒体库 tab 手动导入。
        if !alreadyPresent, let resolved = directoryStore.resolve(directory) {
            rescanHandler(resolved)
        }
    }

    /// 移除一个目录。只从列表里移除，不动已经入库的曲目 ——
    /// 「不再扫描这里」与「把已导入的歌删掉」是两件事，后者属于媒体库的清理动作。
    public func removeDirectory(id: UUID) {
        let name = directories.first { $0.id == id }?.displayName
        directoryStore.remove(id: id)
        directories = directoryStore.all()
        if let name {
            statusMessage = "已移除媒体库目录：\(name)（已入库的曲目保留）"
        }
    }

    /// 重新扫描全部已配置目录。
    public func rescanAll() {
        guard !directories.isEmpty else {
            statusMessage = "还没有配置媒体库目录"
            return
        }
        var missing: [String] = []
        var scanned = 0
        for directory in directories {
            guard let url = directoryStore.resolve(directory) else {
                missing.append(directory.displayName)
                continue
            }
            rescanHandler(url)
            scanned += 1
        }
        if missing.isEmpty {
            statusMessage = "正在重新扫描 \(scanned) 个目录…"
        } else {
            statusMessage = "正在重新扫描 \(scanned) 个目录；\(missing.joined(separator: "、")) 当前不可用"
        }
    }

    /// 清空状态提示（视图在展示后调用）。
    public func clearStatusMessage() {
        statusMessage = nil
    }

    /// 重新从存储读取目录列表。
    ///
    /// 为什么需要它：媒体库 tab 的「导入文件夹」也会把目录记下来，而那条路径不经过本对象。
    /// 设置页每次出现时刷新一次，就能看到在别处加入的目录，而不必引入一套跨视图模型的
    /// 通知机制 —— 列表规模是几十条，重读的成本可以忽略。
    public func refreshDirectories() {
        directories = directoryStore.all()
    }
}
