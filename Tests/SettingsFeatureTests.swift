// SettingsFeatureTests.swift
// NeriPlayer macOS —— M3-T5：设置页（外观 / 播放行为 / 媒体库目录）的确定性单测。
//
// 覆盖面（与任务书验收「手动验收 + 设置值持久化单测」一一对应）：
//   1) 外观：主题与强调色写入后可被新实例读回；未知取值回落到默认项而不是崩掉；
//      主题到 ColorScheme 的映射（跟随系统 = 不覆盖系统选择）；
//   2) 播放行为：启动续播开关；启动音量的越界/NaN 归一化；
//   3) 媒体库目录：加入/去重/移除/清空、顺序稳定、跨实例持久化、坏数据不炸、
//      路径标准化（同一目录的两种写法视为同一条）、解析不可用目录返回 nil；
//   4) 设置页与媒体库的联动：加入新目录会触发一次重扫；重复加入不触发；
//      移除只从列表里去掉，不动已入库曲目（本用例只能断言列表这一层）。
//
// 为什么全部用隔离的 UserDefaults suite：设置是全局单例的存储，用例之间必须互不影响；
// 每个用例用独立 suiteName，跑完即清（与 SettingsStoreTests 同一取舍）。

import XCTest
import SwiftUI
@testable import NeriPlayer

@MainActor
final class SettingsFeatureTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDownWithError() throws {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames = []
        try super.tearDownWithError()
    }

    // MARK: - 夹具

    /// 一套隔离的设置存储。
    private func makeSettings() -> SettingsStore {
        let name = "NeriPlayerSettingsFeatureTests-\(UUID().uuidString)"
        suiteNames.append(name)
        return SettingsStore(userDefaults: UserDefaults(suiteName: name) ?? .standard)
    }

    /// 建一个真实存在的临时目录（目录解析用例需要它存在）。
    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NeriPlayerDir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// 用于断言的规范化路径。
    ///
    /// 必须再解一次符号链接：macOS 上 `/var` 是 `/private/var` 的软链，而书签解析会把软链展开，
    /// 于是「加入时记下的路径」与「解析书签后拿到的路径」字面不同、指向却是同一个位置。
    /// 断言关心的正是「指向同一个位置」，所以比较展开后的路径，而不是字面量。
    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// 收集重扫调用的盒子。
    private final class RescanRecorder {
        var urls: [URL] = []
    }

    // MARK: - 1. 外观

    /// 主题与强调色写入后，新实例能读回同样的值。
    func testAppearanceAndAccentPersistAcrossInstances() {
        let settings = makeSettings()
        let first = SettingsViewModel(settings: settings)

        first.setAppearance(.dark)
        first.setAccent(.orange)

        let second = SettingsViewModel(settings: settings)
        XCTAssertEqual(second.appearance, .dark)
        XCTAssertEqual(second.accent, .orange)
    }

    /// 默认值：未设置过时是「跟随系统 + 蓝色」。
    func testAppearanceDefaultsToSystemAndBlue() {
        let viewModel = SettingsViewModel(settings: makeSettings())

        XCTAssertEqual(viewModel.appearance, .system)
        XCTAssertEqual(viewModel.accent, .blue)
        XCTAssertFalse(viewModel.resumePlaybackOnLaunch)
        XCTAssertEqual(viewModel.defaultVolume, PlaybackBehaviorDefaults.volume)
    }

    /// 未知取值（更早或更晚版本写下的）回落到默认项，而不是让应用起不来。
    func testUnknownStoredValuesFallBackToDefaults() {
        let settings = makeSettings()
        settings.set("no-such-mode", for: SettingsKeys.appAppearance)
        settings.set("chartreuse", for: SettingsKeys.accentColor)

        XCTAssertEqual(AppearanceMode(storedValue: "no-such-mode"), .system)
        XCTAssertEqual(AccentColorOption(storedValue: "chartreuse"), .blue)

        let viewModel = SettingsViewModel(settings: settings)
        XCTAssertEqual(viewModel.appearance, .system)
        XCTAssertEqual(viewModel.accent, .blue)
    }

    /// 主题到 ColorScheme 的映射：跟随系统时不覆盖系统选择（nil）。
    func testAppearanceMapsToColorScheme() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
    }

    /// 每个外观/强调色选项都有非空且互不重复的展示名（设置页按它渲染）。
    func testDisplayNamesAreNonEmptyAndDistinct() {
        let appearanceNames = AppearanceMode.allCases.map(\.displayName)
        XCTAssertEqual(Set(appearanceNames).count, appearanceNames.count)
        XCTAssertFalse(appearanceNames.contains(where: \.isEmpty))

        let accentNames = AccentColorOption.allCases.map(\.displayName)
        XCTAssertEqual(Set(accentNames).count, accentNames.count)
        XCTAssertFalse(accentNames.contains(where: \.isEmpty))
    }

    /// 取同一个值时不做无谓写入：没有显式设置过的键应保持「未设置」。
    func testSettingSameValueDoesNotWrite() {
        let settings = makeSettings()
        let viewModel = SettingsViewModel(settings: settings)

        viewModel.setAppearance(.system)
        viewModel.setAccent(.blue)
        viewModel.setDefaultVolume(PlaybackBehaviorDefaults.volume)

        XCTAssertFalse(settings.contains(SettingsKeys.appAppearance), "值未变化时不该写设置")
        XCTAssertFalse(settings.contains(SettingsKeys.accentColor))
        XCTAssertFalse(settings.contains(SettingsKeys.defaultVolume))
    }

    // MARK: - 2. 播放行为

    /// 启动续播开关持久化。
    func testResumePlaybackTogglePersists() {
        let settings = makeSettings()
        let first = SettingsViewModel(settings: settings)

        first.setResumePlaybackOnLaunch(true)

        XCTAssertTrue(SettingsViewModel(settings: settings).resumePlaybackOnLaunch)
    }

    /// 启动音量：越界值被夹到 0…100，NaN 回落到默认音量。
    func testDefaultVolumeIsClamped() {
        let settings = makeSettings()
        let viewModel = SettingsViewModel(settings: settings)

        viewModel.setDefaultVolume(500)
        XCTAssertEqual(viewModel.defaultVolume, 100)
        XCTAssertEqual(SettingsViewModel(settings: settings).defaultVolume, 100)

        viewModel.setDefaultVolume(-20)
        XCTAssertEqual(viewModel.defaultVolume, 0)

        viewModel.setDefaultVolume(.nan)
        XCTAssertEqual(viewModel.defaultVolume, PlaybackBehaviorDefaults.volume, "NaN 应回落到默认值")

        // 非有限值（NaN / ±∞）一律回落到默认音量，而不是夹到边界：
        // 它们通常来自计算错误而不是用户的真实选择，夹到 100 会把异常悄悄当成「最大音量」。
        XCTAssertEqual(PlaybackBehaviorDefaults.clampedVolume(.infinity), PlaybackBehaviorDefaults.volume)
        XCTAssertEqual(PlaybackBehaviorDefaults.clampedVolume(-.infinity), PlaybackBehaviorDefaults.volume)
        XCTAssertEqual(PlaybackBehaviorDefaults.clampedVolume(42), 42)
    }

    /// 存量数据越界时（例如手工改过 UserDefaults）读取侧也要夹取。
    func testOutOfRangeStoredVolumeIsClampedOnRead() {
        let settings = makeSettings()
        settings.set(999.0, for: SettingsKeys.defaultVolume)

        XCTAssertEqual(SettingsViewModel(settings: settings).defaultVolume, 100)
    }

    // MARK: - 3. 媒体库目录

    /// 加入目录后可读出，且同名目录重复加入只保留一条（幂等）。
    func testAddDirectoryIsIdempotent() throws {
        let store = LibraryDirectoryStore(settings: makeSettings())
        let directory = try makeTemporaryDirectory()

        let first = store.add(directory, bookmark: Data([1, 2, 3]))
        let second = store.add(directory, bookmark: Data([9, 9, 9]))

        XCTAssertEqual(first.id, second.id, "重复加入应返回既有项")
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.bookmark, Data([1, 2, 3]), "重复加入不该覆盖既有字段")
        XCTAssertTrue(store.contains(directory))
    }

    /// 尾部斜杠 / 相对写法指向同一目录时应视为同一条。
    func testDirectoryPathsAreNormalizedForDeduplication() throws {
        let store = LibraryDirectoryStore(settings: makeSettings())
        let directory = try makeTemporaryDirectory()

        store.add(directory, bookmark: nil)
        store.add(URL(fileURLWithPath: directory.path + "/"), bookmark: nil)

        XCTAssertEqual(store.all().count, 1, "同一目录的两种写法不该产生两行")
        XCTAssertEqual(store.all().first?.path, directory.standardizedFileURL.path)
    }

    /// 列表按加入时间升序，移除与清空按预期生效。
    func testDirectoryOrderingRemovalAndClear() throws {
        let settings = makeSettings()
        let store = LibraryDirectoryStore(settings: settings)
        let a = try makeTemporaryDirectory()
        let b = try makeTemporaryDirectory()
        let c = try makeTemporaryDirectory()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // 刻意乱序加入：列表顺序应由加入时间决定，而不是调用顺序。
        store.add(b, bookmark: nil, at: base.addingTimeInterval(60))
        let first = store.add(a, bookmark: nil, at: base)
        let third = store.add(c, bookmark: nil, at: base.addingTimeInterval(120))

        let normalized = { (url: URL) in url.standardizedFileURL.path }
        XCTAssertEqual(store.all().map(\.path), [a, b, c].map(normalized))
        XCTAssertEqual(store.all().first?.id, first.id)

        store.remove(id: third.id)
        XCTAssertEqual(store.all().map(\.path), [a, b].map(normalized), "移除最后加入的一条")

        store.remove(id: UUID())
        XCTAssertEqual(store.all().count, 2, "移除不存在的 id 应是 no-op")

        store.removeAll()
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertEqual(settings.value(for: SettingsKeys.libraryDirectories), Data(), "清空后写回空值")
    }

    /// 跨实例持久化：新实例（哪怕换了 UserDefaults 句柄）能读到同样的列表。
    func testDirectoryListPersistsAcrossInstances() throws {
        let settings = makeSettings()
        let directory = try makeTemporaryDirectory()
        LibraryDirectoryStore(settings: settings).add(directory, bookmark: Data([7]))

        let reloaded = LibraryDirectoryStore(settings: settings).all()

        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.path, directory.standardizedFileURL.path)
        XCTAssertEqual(reloaded.first?.bookmark, Data([7]))
    }

    /// 坏数据（手工改坏 / 版本不兼容）按空列表处理，不让设置页打不开。
    func testCorruptDirectoryDataIsTreatedAsEmpty() {
        let settings = makeSettings()
        settings.set(Data("this is not json".utf8), for: SettingsKeys.libraryDirectories)

        XCTAssertTrue(LibraryDirectoryStore(settings: settings).all().isEmpty)
    }

    /// 解析目录：存在则给出 URL，不存在则 nil（用于「目录当前不可用」的提示）。
    func testResolveReturnsNilForMissingDirectory() throws {
        let store = LibraryDirectoryStore(settings: makeSettings())
        let existing = try makeTemporaryDirectory()

        let present = LibraryDirectory(path: existing.standardizedFileURL.path)
        XCTAssertEqual(store.resolve(present)?.path, existing.standardizedFileURL.path)

        let missing = LibraryDirectory(
            path: NSTemporaryDirectory() + "NeriPlayer-absolutely-missing-\(UUID().uuidString)"
        )
        XCTAssertNil(store.resolve(missing))
    }

    /// 书签不可解析时回落到路径（模拟应用标识变化 / 库文件被移动）。
    func testResolveFallsBackToPathWhenBookmarkIsBroken() throws {
        let store = LibraryDirectoryStore(settings: makeSettings())
        let directory = try makeTemporaryDirectory()
        let broken = LibraryDirectory(
            path: directory.standardizedFileURL.path,
            bookmark: Data([0, 1, 2, 3])
        )

        XCTAssertEqual(store.resolve(broken)?.path, directory.standardizedFileURL.path)
    }

    /// 展示名取路径最后一段；根路径这类没有段名的情况回落到完整路径。
    func testDirectoryDisplayNameFallsBackToFullPath() {
        XCTAssertEqual(LibraryDirectory(path: "/Users/someone/Music").displayName, "Music")
        XCTAssertEqual(LibraryDirectory(path: "/").displayName, "/")
    }

    // MARK: - 4. 设置页联动

    /// 加入新目录会把解析出的 URL 交给重扫动作；重复加入不再触发。
    func testAddingNewDirectoryTriggersRescanOnce() throws {
        let recorder = RescanRecorder()
        let viewModel = SettingsViewModel(
            settings: makeSettings(),
            rescanHandler: { recorder.urls.append($0) }
        )
        let directory = try makeTemporaryDirectory()

        viewModel.addDirectory(directory)
        XCTAssertEqual(recorder.urls.map(canonicalPath), [canonicalPath(directory)])
        XCTAssertEqual(viewModel.directories.count, 1)

        viewModel.addDirectory(directory)
        XCTAssertEqual(recorder.urls.count, 1, "重复加入不该再触发一次扫描")
        XCTAssertEqual(viewModel.directories.count, 1)
        XCTAssertEqual(viewModel.statusMessage, "「\(directory.lastPathComponent)」已在媒体库目录中")
    }

    /// 移除目录只改列表，并给出「已入库曲目保留」的提示。
    func testRemovingDirectoryKeepsListConsistentAndExplainsItself() throws {
        let viewModel = SettingsViewModel(settings: makeSettings(), rescanHandler: { _ in })
        let directory = try makeTemporaryDirectory()
        viewModel.addDirectory(directory)
        let id = try XCTUnwrap(viewModel.directories.first?.id)

        viewModel.removeDirectory(id: id)

        XCTAssertTrue(viewModel.directories.isEmpty)
        XCTAssertEqual(viewModel.statusMessage, "已移除媒体库目录：\(directory.lastPathComponent)（已入库的曲目保留）")
    }

    /// 重扫全部：目录不可用时把它列进提示，而不是静默跳过；没有目录时给出明确提示。
    func testRescanAllReportsUnavailableDirectories() throws {
        let recorder = RescanRecorder()
        let settings = makeSettings()
        let store = LibraryDirectoryStore(settings: settings)
        let existing = try makeTemporaryDirectory()
        let missingURL = URL(fileURLWithPath: NSTemporaryDirectory() + "NeriPlayer-missing-\(UUID().uuidString)")
        store.add(existing, bookmark: nil)
        store.add(missingURL, bookmark: nil)

        let viewModel = SettingsViewModel(
            settings: settings,
            rescanHandler: { recorder.urls.append($0) }
        )
        XCTAssertEqual(viewModel.directories.count, 2)

        viewModel.rescanAll()

        XCTAssertEqual(recorder.urls.map(canonicalPath), [canonicalPath(existing)], "只应扫描可用目录")
        XCTAssertEqual(
            viewModel.statusMessage,
            "正在重新扫描 1 个目录；\(missingURL.lastPathComponent) 当前不可用"
        )
    }

    /// 没有任何目录时重扫给出明确提示，而不是默默什么都不做。
    func testRescanAllWithoutDirectoriesExplainsItself() {
        let viewModel = SettingsViewModel(settings: makeSettings(), rescanHandler: { _ in })

        viewModel.rescanAll()

        XCTAssertEqual(viewModel.statusMessage, "还没有配置媒体库目录")
    }

    /// 媒体库 tab 导入的目录也要能在设置页看到（refreshDirectories 的作用）。
    func testRefreshDirectoriesPicksUpExternallyAddedDirectory() throws {
        let settings = makeSettings()
        let viewModel = SettingsViewModel(settings: settings, rescanHandler: { _ in })
        XCTAssertTrue(viewModel.directories.isEmpty)

        // 模拟「媒体库 tab 走自己的 LibraryDirectoryStore 加入了一个目录」。
        LibraryDirectoryStore(settings: settings).add(try makeTemporaryDirectory(), bookmark: nil)
        XCTAssertTrue(viewModel.directories.isEmpty, "未刷新前本地副本仍是旧的")

        viewModel.refreshDirectories()
        XCTAssertEqual(viewModel.directories.count, 1)
    }

    // MARK: - 5. 在线音质（问题 3）

    /// 三个平台的档位写入后都能被「重新读一遍存储」的实例读回（key 与 rawValue 都对）。
    func testAudioQualityPersistsForEachPlatform() {
        let settings = makeSettings()
        let viewModel = SettingsViewModel(settings: settings)

        viewModel.setNeteaseQuality(.lossless)
        viewModel.setYouTubeMusicQuality(.veryHigh)
        viewModel.setBilibiliQuality(.dolby)

        // 落盘的必须是 rawValue（YouTube 的 veryHigh 是 "very_high"，不是枚举名）。
        XCTAssertEqual(settings.value(for: SettingsKeys.neteaseAudioQuality), "lossless")
        XCTAssertEqual(settings.value(for: SettingsKeys.youtubeMusicAudioQuality), "very_high")
        XCTAssertEqual(settings.value(for: SettingsKeys.bilibiliAudioQuality), "dolby")

        // 重新读存储：新实例（新的 SettingsViewModel 与新的 AudioQualityPreferences）看到同样的值。
        let reloaded = SettingsViewModel(settings: settings)
        XCTAssertEqual(reloaded.neteaseQuality, .lossless)
        XCTAssertEqual(reloaded.youtubeMusicQuality, .veryHigh)
        XCTAssertEqual(reloaded.bilibiliQuality, .dolby)

        let preferences = AudioQualityPreferences(settings: settings)
        XCTAssertEqual(preferences.netease, .lossless)
        XCTAssertEqual(preferences.youtubeMusic, .veryHigh)
        XCTAssertEqual(preferences.bilibili, .dolby)
    }

    /// 未设置过时是各平台的默认档位（exhigh / high / high），不会写成空值。
    func testAudioQualityDefaultsMatchPlatformDefaults() {
        let settings = makeSettings()
        let viewModel = SettingsViewModel(settings: settings)

        XCTAssertEqual(viewModel.neteaseQuality, .exhigh)
        XCTAssertEqual(viewModel.youtubeMusicQuality, .high)
        XCTAssertEqual(viewModel.bilibiliQuality, .high)
        XCTAssertFalse(settings.contains(SettingsKeys.neteaseAudioQuality), "只读不该写设置")
    }

    /// 垃圾值（手工改坏 / 版本不兼容）读回平台默认档位，而不是抛错或让设置页打不开。
    func testGarbageAudioQualityFallsBackToPlatformDefaults() {
        let settings = makeSettings()
        settings.set("bogus", for: SettingsKeys.neteaseAudioQuality)
        settings.set("bogus", for: SettingsKeys.youtubeMusicAudioQuality)
        settings.set("bogus", for: SettingsKeys.bilibiliAudioQuality)

        XCTAssertEqual(NeteaseQuality(stored: "bogus"), .default)
        XCTAssertEqual(YouTubeQuality(stored: "bogus"), .default)
        XCTAssertEqual(BilibiliQuality(stored: "bogus"), .default)

        let viewModel = SettingsViewModel(settings: settings)
        XCTAssertEqual(viewModel.neteaseQuality, .exhigh)
        XCTAssertEqual(viewModel.youtubeMusicQuality, .high)
        XCTAssertEqual(viewModel.bilibiliQuality, .high)
    }

    /// 取同一个档位时不做无谓写入（与外观 / 强调色的取舍一致）。
    func testSettingSameAudioQualityDoesNotWrite() {
        let settings = makeSettings()
        let viewModel = SettingsViewModel(settings: settings)

        viewModel.setNeteaseQuality(NeteaseQuality.default)
        viewModel.setYouTubeMusicQuality(YouTubeQuality.default)
        viewModel.setBilibiliQuality(BilibiliQuality.default)

        XCTAssertFalse(settings.contains(SettingsKeys.neteaseAudioQuality))
        XCTAssertFalse(settings.contains(SettingsKeys.youtubeMusicAudioQuality))
        XCTAssertFalse(settings.contains(SettingsKeys.bilibiliAudioQuality))
    }

    /// 别处（备份恢复 / 其他入口）直接写存储时，视图模型通过变更流同步到本地副本。
    ///
    /// 只改一个键也只会刷新对应的那一个属性：三个键各自独立，不该互相带动。
    func testViewModelObservesExternallyWrittenAudioQuality() async {
        let settings = makeSettings()
        let viewModel = SettingsViewModel(settings: settings)
        XCTAssertEqual(viewModel.bilibiliQuality, .high)

        // 观察者任务要先真正开始消费变更流，之后的写入才会被收到。
        try? await Task.sleep(nanoseconds: 100_000_000)
        settings.set(BilibiliQuality.low.rawValue, for: SettingsKeys.bilibiliAudioQuality)

        let reflected = await waitUntil { viewModel.bilibiliQuality == .low }
        XCTAssertTrue(reflected, "直接写存储后视图模型应同步为 low，实际为 \(viewModel.bilibiliQuality)")
        XCTAssertEqual(viewModel.neteaseQuality, .exhigh, "其他平台的档位不该被带动")
    }

    /// 等待一个主线程条件成立，超时返回最后一次结果（避免用例因观察者未调度而挂起）。
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
