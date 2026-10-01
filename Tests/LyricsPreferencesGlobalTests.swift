// LyricsPreferencesGlobalTests.swift
// T06: 歌词偏好「未播放也可调」与「单曲操作依赖当前曲目」的契约。
//
// 背景：设置页的「歌词」分类需要直接打开 LyricsPreferencesView；该视图把控件分成两段 ——
//   1) 全局显示偏好（字号 / 模糊 / 翻译 / 音译）：不依赖播放状态，可随时调整并即时持久化；
//   2) 当前歌曲（单曲偏移 / 网易云匹配）：必须有一首正在播放或已选中的曲目才有意义。
// 本用例只断言视图模型这一层的行为；视图本身按仓库惯例由真实应用人工验收。

import XCTest
@testable import NeriPlayer

@MainActor
final class LyricsPreferencesGlobalTests: XCTestCase {
    private func settings() throws -> SettingsStore {
        let suite = "LyricsPreferencesGlobalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SettingsStore(userDefaults: defaults)
    }

    /// 未播放时全局显示偏好仍可写入，并被新实例读回 —— 这是设置页在无曲目时也能用的前提。
    func testGlobalDisplayPreferencesApplyWithoutTrack() throws {
        let store = try settings()
        let model = LyricsViewModel(provider: FixedLyricsProvider(document: nil), settings: store)
        XCTAssertNil(model.snapshot?.currentTrack)

        model.setFontSize(34)
        model.setBlur(true)
        model.setTranslation(false)
        model.setPhonetic(false)

        // 写入立即反映在当前实例上。
        XCTAssertEqual(model.fontSize, 34)
        XCTAssertTrue(model.blur)
        XCTAssertFalse(model.showTranslation)
        XCTAssertFalse(model.showPhonetic)

        // 跨实例持久化：设置页与歌词窗口共用同一份偏好。
        let reloaded = LyricsViewModel(provider: FixedLyricsProvider(document: nil), settings: store)
        XCTAssertEqual(reloaded.fontSize, 34)
        XCTAssertTrue(reloaded.blur)
        XCTAssertFalse(reloaded.showTranslation)
        XCTAssertFalse(reloaded.showPhonetic)
        model.stop()
        reloaded.stop()
    }

    /// 没有当前曲目时，网易云关联必须失败且不留状态 —— 对应视图中被禁用的「关联」按钮。
    /// 视图会在 hasTrack 为 false 时自行给出提示，这一层只保证不会写入错误的关联。
    func testAssociationIsRejectedWithoutTrack() throws {
        let model = LyricsViewModel(provider: FixedLyricsProvider(document: nil), settings: try settings())

        XCTAssertFalse(model.associate(songID: "123"))
        XCTAssertEqual(model.neteaseSongID, "")
        model.stop()
    }

    /// 单曲偏移只在有曲目时落到存储；无曲目时只更新内存值，不写库。
    func testTrackOffsetIsNotPersistedWithoutTrack() throws {
        let store = try settings()
        let model = LyricsViewModel(provider: FixedLyricsProvider(document: nil), settings: store)

        model.setOffset(-500)
        XCTAssertEqual(model.offsetMilliseconds, -500)

        // 换一个新实例不应带回任何单曲偏移（存储里没有条目）。
        let reloaded = LyricsViewModel(provider: FixedLyricsProvider(document: nil), settings: store)
        XCTAssertEqual(reloaded.offsetMilliseconds, 0)
        model.stop()
        reloaded.stop()
    }
}

private actor FixedLyricsProvider: LyricsProvider {
    let document: LyricsDocument?
    init(document: LyricsDocument?) { self.document = document }
    func lyrics(for request: LyricsRequest) async throws -> LyricsDocument? { document }
}
