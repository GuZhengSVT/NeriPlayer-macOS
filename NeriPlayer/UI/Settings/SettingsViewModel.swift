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
import SwiftUI

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
    // MARK: 字体设置（需求 5）
    /// UI 字体家族标识。
    @Published public private(set) var uiFontFamily: String
    /// UI 基础字号。
    @Published public private(set) var uiBaseFontSize: Double
    /// 播放器字号。
    @Published public private(set) var playerFontSize: Double
    /// 歌词字体家族标识。
    @Published public private(set) var lyricsFontFamily: String
    /// 歌词字号。与歌词窗口的滑杆共用 `lyricsFontSize` 这个键，两处永远一致。
    @Published public private(set) var lyricsFontSize: Double
    /// 底部播放栏歌词行字号。
    @Published public private(set) var compactLyricsFontSize: Double
    /// 本机可用字体家族（含「系统字体」以外的真实家族），仅在设置页出现时取一次。
    @Published public private(set) var availableFontFamilies: [String] = []

    // MARK: 依赖

    private let settings: SettingsStore
    private let directoryStore: LibraryDirectoryStore
    /// 字体设置的变更订阅（需求 5）。歌词窗口也有一个字号滑杆，它直接写 SettingsStore、
    /// 不经过本对象；不订阅的话，外观页会一直显示打开设置页那一刻的旧值。
    private var fontObservation: Task<Void, Never>?
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
        self.uiFontFamily = settings.value(for: SettingsKeys.uiFontFamily)
        self.uiBaseFontSize = AppTypographyDefaults.clamped(
            settings.value(for: SettingsKeys.uiBaseFontSize), in: AppTypographyDefaults.uiBaseSizeRange,
            fallback: AppTypographyDefaults.uiBaseSize)
        self.playerFontSize = AppTypographyDefaults.clamped(
            settings.value(for: SettingsKeys.playerFontSize), in: AppTypographyDefaults.playerTextSizeRange,
            fallback: AppTypographyDefaults.playerTextSize)
        self.lyricsFontFamily = settings.value(for: SettingsKeys.lyricsFontFamily)
        self.lyricsFontSize = AppTypographyDefaults.clamped(
            settings.value(for: SettingsKeys.lyricsFontSize), in: AppTypographyDefaults.lyricsBaseSizeRange,
            fallback: AppTypographyDefaults.lyricsBaseSize)
        self.compactLyricsFontSize = AppTypographyDefaults.clamped(
            settings.value(for: SettingsKeys.compactLyricsFontSize),
            in: AppTypographyDefaults.compactLyricsSizeRange, fallback: AppTypographyDefaults.compactLyricsSize)
        loadAvailableFonts()
        observeFontSettings()
    }

    deinit {
        fontObservation?.cancel()
    }

    /// 订阅字体相关的设置键，把「别处写入」的值同步到本地副本。
    ///
    /// 为什么需要：歌词设置窗口的字体 / 字号滑杆直接调 LyricsViewModel，落盘时不经过
    /// 本对象；若这里不订阅，外观页会停留在打开那一刻的旧值。只在值真的不同时写入属性，
    /// 避免把「自己刚写出去的值」再回灌成一次多余的重绘。
    private func observeFontSettings() {
        let stream = settings.changes()
        fontObservation = Task { [weak self] in
            for await change in stream {
                guard !Task.isCancelled, let self else { return }
                switch change.key {
                case SettingsKeys.lyricsFontSize.name:
                    let value = AppTypographyDefaults.clamped(
                        self.settings.value(for: SettingsKeys.lyricsFontSize),
                        in: AppTypographyDefaults.lyricsBaseSizeRange, fallback: AppTypographyDefaults.lyricsBaseSize)
                    if value != self.lyricsFontSize { self.lyricsFontSize = value }
                case SettingsKeys.lyricsFontFamily.name:
                    let value = self.settings.value(for: SettingsKeys.lyricsFontFamily)
                    if value != self.lyricsFontFamily { self.lyricsFontFamily = value }
                case SettingsKeys.uiFontFamily.name:
                    let value = self.settings.value(for: SettingsKeys.uiFontFamily)
                    if value != self.uiFontFamily { self.uiFontFamily = value }
                case SettingsKeys.uiBaseFontSize.name:
                    let value = AppTypographyDefaults.clamped(
                        self.settings.value(for: SettingsKeys.uiBaseFontSize),
                        in: AppTypographyDefaults.uiBaseSizeRange, fallback: AppTypographyDefaults.uiBaseSize)
                    if value != self.uiBaseFontSize { self.uiBaseFontSize = value }
                case SettingsKeys.playerFontSize.name:
                    let value = AppTypographyDefaults.clamped(
                        self.settings.value(for: SettingsKeys.playerFontSize),
                        in: AppTypographyDefaults.playerTextSizeRange, fallback: AppTypographyDefaults.playerTextSize)
                    if value != self.playerFontSize { self.playerFontSize = value }
                case SettingsKeys.compactLyricsFontSize.name:
                    let value = AppTypographyDefaults.clamped(
                        self.settings.value(for: SettingsKeys.compactLyricsFontSize),
                        in: AppTypographyDefaults.compactLyricsSizeRange, fallback: AppTypographyDefaults.compactLyricsSize)
                    if value != self.compactLyricsFontSize { self.compactLyricsFontSize = value }
                default:
                    break
                }
            }
        }
    }

    func reloadSettings() {
        appearance = AppearanceMode(storedValue: settings.value(for: SettingsKeys.appAppearance))
        accent = AccentColorOption(storedValue: settings.value(for: SettingsKeys.accentColor))
        resumePlaybackOnLaunch = settings.value(for: SettingsKeys.resumePlaybackOnLaunch)
        defaultVolume = PlaybackBehaviorDefaults.clampedVolume(settings.value(for: SettingsKeys.defaultVolume))
        uiFontFamily = settings.value(for: SettingsKeys.uiFontFamily)
        uiBaseFontSize = AppTypographyDefaults.clamped(
            settings.value(for: SettingsKeys.uiBaseFontSize), in: AppTypographyDefaults.uiBaseSizeRange,
            fallback: AppTypographyDefaults.uiBaseSize)
        playerFontSize = AppTypographyDefaults.clamped(
            settings.value(for: SettingsKeys.playerFontSize), in: AppTypographyDefaults.playerTextSizeRange,
            fallback: AppTypographyDefaults.playerTextSize)
        lyricsFontFamily = settings.value(for: SettingsKeys.lyricsFontFamily)
        lyricsFontSize = AppTypographyDefaults.clamped(
            settings.value(for: SettingsKeys.lyricsFontSize), in: AppTypographyDefaults.lyricsBaseSizeRange,
            fallback: AppTypographyDefaults.lyricsBaseSize)
        compactLyricsFontSize = AppTypographyDefaults.clamped(
            settings.value(for: SettingsKeys.compactLyricsFontSize),
            in: AppTypographyDefaults.compactLyricsSizeRange, fallback: AppTypographyDefaults.compactLyricsSize)
        refreshDirectories()
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

    // MARK: 字体（需求 5）

    /// UI 字体家族。未知家族由 `TypographyFontFamily.resolved` 夹回系统字体后再落盘 ——
    /// 存进去的一定是本机可渲染的值，读取侧不必再防御一次。
    public func setUIFontFamily(_ family: String) {
        let resolved = TypographyFontFamily.resolved(family, available: availableFontSet)
        guard resolved != uiFontFamily else { return }
        uiFontFamily = resolved
        settings.set(resolved, for: SettingsKeys.uiFontFamily)
    }

    public func setUIBaseFontSize(_ value: Double) {
        let clamped = AppTypographyDefaults.clamped(
            value, in: AppTypographyDefaults.uiBaseSizeRange, fallback: AppTypographyDefaults.uiBaseSize)
        guard clamped != uiBaseFontSize else { return }
        uiBaseFontSize = clamped
        settings.set(clamped, for: SettingsKeys.uiBaseFontSize)
    }

    public func setPlayerFontSize(_ value: Double) {
        let clamped = AppTypographyDefaults.clamped(
            value, in: AppTypographyDefaults.playerTextSizeRange, fallback: AppTypographyDefaults.playerTextSize)
        guard clamped != playerFontSize else { return }
        playerFontSize = clamped
        settings.set(clamped, for: SettingsKeys.playerFontSize)
    }

    public func setLyricsFontFamily(_ family: String) {
        let resolved = TypographyFontFamily.resolved(family, available: availableFontSet)
        guard resolved != lyricsFontFamily else { return }
        lyricsFontFamily = resolved
        settings.set(resolved, for: SettingsKeys.lyricsFontFamily)
    }

    /// 歌词字号。与歌词窗口滑杆共用同一个键，因此两边都会立刻看到对方的变化。
    public func setLyricsFontSize(_ value: Double) {
        let clamped = AppTypographyDefaults.clamped(
            value, in: AppTypographyDefaults.lyricsBaseSizeRange, fallback: AppTypographyDefaults.lyricsBaseSize)
        guard clamped != lyricsFontSize else { return }
        lyricsFontSize = clamped
        settings.set(clamped, for: SettingsKeys.lyricsFontSize)
    }

    public func setCompactLyricsFontSize(_ value: Double) {
        let clamped = AppTypographyDefaults.clamped(
            value, in: AppTypographyDefaults.compactLyricsSizeRange, fallback: AppTypographyDefaults.compactLyricsSize)
        guard clamped != compactLyricsFontSize else { return }
        compactLyricsFontSize = clamped
        settings.set(clamped, for: SettingsKeys.compactLyricsFontSize)
    }

    /// 把字体设置恢复到默认值。逐键 reset 会各自广播一次变更，根视图因此逐项刷新；
    /// 不一次性清空所有键，避免把主题、目录等无关设置也一起重置。
    public func restoreTypographyDefaults() {
        settings.reset(SettingsKeys.uiFontFamily)
        settings.reset(SettingsKeys.uiBaseFontSize)
        settings.reset(SettingsKeys.playerFontSize)
        settings.reset(SettingsKeys.lyricsFontFamily)
        settings.reset(SettingsKeys.lyricsFontSize)
        settings.reset(SettingsKeys.compactLyricsFontSize)
        uiFontFamily = TypographyFontFamily.systemID
        uiBaseFontSize = AppTypographyDefaults.uiBaseSize
        playerFontSize = AppTypographyDefaults.playerTextSize
        lyricsFontFamily = TypographyFontFamily.systemID
        lyricsFontSize = AppTypographyDefaults.lyricsBaseSize
        compactLyricsFontSize = AppTypographyDefaults.compactLyricsSize
        statusMessage = "字体设置已恢复默认"
    }

    /// 本机可用字体家族集合（含系统字体哨兵），供字体选择器与写入侧夹取共用。
    private var availableFontSet: Set<String> {
        Set(availableFontFamilies + [TypographyFontFamily.systemID])
    }

    /// 枚举本机字体家族。列表在设置页打开时取一次：`NSFontManager.availableFontFamilies`
    /// 会读取字体目录，放在渲染路径上反复调用没有必要。
    private func loadAvailableFonts() {
        let families = TypographyFontFamily.availableFamilies()
        availableFontFamilies = families.isEmpty ? [TypographyFontFamily.systemID] : families
    }

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
