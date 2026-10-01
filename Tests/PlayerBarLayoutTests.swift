// PlayerBarLayoutTests.swift
// NeriPlayer macOS —— 底部播放器栏的纯逻辑测试：宽度分档、时间/音频规格文本、当前曲目落点。
//
// 这三块都是纯函数/纯规则，不依赖 SwiftUI、不驱动 libmpv，因此可直接断言：
//   1) PlayerBarLayout.plan 在四个宽度档位下的内联/收起集合与文字行数策略；
//   2) PlaybackTimeText / AudioInfoText 的格式化与「缺值不编造」；
//   3) CurrentTrackLibraryActions 把当前 Track 正确归到本地库项或在线歌。

import XCTest
@testable import NeriPlayer

final class PlayerBarLayoutTests: XCTestCase {

    // MARK: - 宽度分档

    /// 宽窗：所有可选控件内联，三行文字全开，更多菜单为空。
    func testWideWindowInlinesEverything() {
        let plan = PlayerBarLayout.plan(forWidth: 1200)
        XCTAssertEqual(Set(plan.inline), Set(PlayerBarOptionalControl.allCases))
        XCTAssertTrue(plan.collapsed.isEmpty, "宽窗不应有收起的控件")
        XCTAssertTrue(plan.showsArtistLine)
        XCTAssertTrue(plan.showsLyricLine)
    }

    /// 中档：先收音量，其余内联。
    func testRegularWindowCollapsesVolumeFirst() {
        let plan = PlayerBarLayout.plan(forWidth: PlayerBarLayout.regularThreshold)
        XCTAssertFalse(plan.isInline(.volume), "中档应先收起音量")
        XCTAssertTrue(plan.isInline(.mode))
        XCTAssertTrue(plan.isInline(.lyrics))
        XCTAssertTrue(plan.isInline(.floatingLyrics))
        XCTAssertEqual(plan.collapsed, [.volume])
        XCTAssertTrue(plan.showsLyricLine, "中档仍保留歌词行")
    }

    /// 紧凑档：音量 + 两条歌词入口都收进更多，且不再显示第二行。
    func testCompactWindowCollapsesDisplayGroup() {
        let plan = PlayerBarLayout.plan(forWidth: PlayerBarLayout.compactThreshold)
        XCTAssertFalse(plan.isInline(.lyrics))
        XCTAssertFalse(plan.isInline(.floatingLyrics))
        XCTAssertTrue(plan.isInline(.mode), "模式仍内联")
        XCTAssertTrue(plan.isInline(.favorite))
        XCTAssertFalse(plan.showsLyricLine, "紧凑档应去掉歌词行")
        XCTAssertTrue(plan.showsArtistLine)
    }

    /// 最窄档：模式/收藏/歌单也收进更多，栏上只留传输 + 队列。
    func testNarrowWindowLeavesOnlyTransportAndQueue() {
        let plan = PlayerBarLayout.plan(forWidth: 600)
        XCTAssertTrue(plan.inline.isEmpty, "最窄档不应内联任何可选控件")
        XCTAssertEqual(Set(plan.collapsed), Set(PlayerBarOptionalControl.allCases))
        XCTAssertFalse(plan.showsArtistLine)
        XCTAssertFalse(plan.showsLyricLine)
    }

    /// 收起顺序固定：从宽到窄始终按同一优先级削减，不会在不同宽度下出现不同的收起组合顺序。
    func testCollapsedOrderIsStableAcrossWidths() {
        let widths: [CGFloat] = [1200, 900, 800, 600]
        let orders = widths.map { PlayerBarLayout.plan(forWidth: $0).collapsed }
        // 每个较窄档的收起集合都应是较宽档的超集（单调递增）。
        for index in 1..<orders.count {
            XCTAssertTrue(Set(orders[index - 1]).isSubset(of: Set(orders[index])),
                          "更窄的窗口应收起不少于更宽窗口的控件")
        }
        XCTAssertEqual(orders.last, PlayerBarOptionalControl.allCases, "最窄档收起全部可选控件")
    }

    /// 非有限宽度（首帧尚未测到）回落到中档，不产生空/异常布局。
    func testNonFiniteWidthFallsBackToRegular() {
        let plan = PlayerBarLayout.plan(forWidth: .infinity)
        XCTAssertEqual(plan, PlayerBarLayout.plan(forWidth: PlayerBarLayout.regularThreshold))
    }

    // MARK: - 时间文本

    func testTimeTextFormatting() {
        XCTAssertEqual(PlaybackTimeText.text(0), "0:00")
        XCTAssertEqual(PlaybackTimeText.text(65), "1:05")
        XCTAssertEqual(PlaybackTimeText.text(3725), "1:02:05")
        XCTAssertEqual(PlaybackTimeText.text(-5), "0:00", "负值按 0 处理")
        XCTAssertEqual(PlaybackTimeText.text(.nan), "0:00", "非有限值按 0 处理")
    }

    /// 时长未知显示 --:--（不显示 0:00 冒充零秒）。
    func testDurationTextShowsPlaceholderWhenUnknown() {
        XCTAssertEqual(PlaybackTimeText.durationText(0), "--:--")
        XCTAssertEqual(PlaybackTimeText.durationText(-1), "--:--")
        XCTAssertEqual(PlaybackTimeText.durationText(.infinity), "--:--")
        XCTAssertEqual(PlaybackTimeText.durationText(180), "3:00")
    }

    // MARK: - 音频规格文本

    func testAudioInfoSummaryOnlyIncludesKnownFields() {
        let full = AudioTrackInfo(codec: "mp3", container: "mp3", bitrate: 128_000, sampleRate: 48_000, channels: 2)
        XCTAssertEqual(AudioInfoText.summary(full), "MP3 · 128 kbps · 48 kHz · 2ch")

        // 缺比特率时该段整段消失，而不是补一个默认码率。
        let noBitrate = AudioTrackInfo(codec: "flac", sampleRate: 44_100, channels: 2)
        XCTAssertEqual(AudioInfoText.summary(noBitrate), "FLAC · 44.1 kHz · 2ch")

        XCTAssertNil(AudioInfoText.summary(AudioTrackInfo()), "全空不产生任何摘要")
        XCTAssertNil(AudioInfoText.summary(nil))
        XCTAssertTrue(AudioTrackInfo().isEmpty)
    }

    /// 0/负数与空白字符串都按「没有」处理，且不显示 0 kbps 这类假值。
    func testAudioInfoRejectsMeaninglessValues() {
        let info = AudioTrackInfo(codec: "   ", container: "", bitrate: 0, sampleRate: -1, channels: 0)
        XCTAssertTrue(info.isEmpty, "空白与 0/负数都应视为没有")
        XCTAssertNil(AudioInfoText.bitrateLabel(0))
        XCTAssertNil(AudioInfoText.bitrateLabel(nil))
        XCTAssertNil(AudioInfoText.sampleRateLabel(0))
        XCTAssertNil(AudioInfoText.channelsLabel(0))
    }

    /// 比特率/采样率的单位换算。
    func testAudioInfoUnitConversion() {
        XCTAssertEqual(AudioInfoText.bitrateLabel(128_000), "128 kbps")
        XCTAssertEqual(AudioInfoText.bitrateLabel(320_000), "320 kbps")
        XCTAssertEqual(AudioInfoText.bitrateLabel(900), "900 bps")
        XCTAssertEqual(AudioInfoText.sampleRateLabel(48_000), "48 kHz")
        XCTAssertEqual(AudioInfoText.sampleRateLabel(44_100), "44.1 kHz")
    }

    /// 增量 setter 与 init 使用同一套合法性规则。
    func testAudioInfoIncrementalSetters() {
        var info = AudioTrackInfo()
        info.setCodec(" flac ")
        info.setBitrate(0)
        info.setSampleRate(96_000)
        info.setChannels(2)
        XCTAssertEqual(info.codec, "flac", "首尾空白应被去掉")
        XCTAssertNil(info.bitrate, "0 比特率按没有处理")
        XCTAssertEqual(info.sampleRate, 96_000)
        XCTAssertEqual(info.channels, 2)
        XCTAssertFalse(info.isEmpty)
    }

    // MARK: - 当前曲目落点

    private func libraryTrack(_ title: String) -> LibraryTrack {
        LibraryTrack(id: UUID(), url: URL(fileURLWithPath: "/music/\(title).mp3"), title: title)
    }

    /// 本地曲且已在库中 → 归到库项（按 url 匹配）。
    func testLocalLibraryTrackResolvesToLibraryItem() {
        let item = libraryTrack("本地歌")
        let track = Track(id: item.id, url: item.url, title: item.title)
        let target = CurrentTrackLibraryActions.target(for: track, libraryTracks: [item])
        XCTAssertEqual(target, .library(item))
    }

    /// 未入库的在线歌 → 归到在线（需要先入库）。
    func testOnlineTrackResolvesToOnline() {
        let song = SongData(source: .netease, sourceID: "123", title: "在线歌")
        let track = song.track()
        let target = CurrentTrackLibraryActions.target(for: track, libraryTracks: [])
        XCTAssertEqual(target, .online(song))
    }

    /// **已入库的在线歌** → 归到库项（按 identityURL 匹配）。
    ///
    /// 这是防回归的关键用例：若只按 isFileURL 分流，在线曲会永远落到 .online，
    /// 界面的 isFavorited 恒为 false，用户无法取消收藏。
    func testOnlineTrackInLibraryResolvesToLibraryItem() {
        let song = SongData(source: .netease, sourceID: "123", title: "在线歌")
        // 库内该在线曲的 url 就是它的 identityURL（入库时按此写入）。
        let item = LibraryTrack(id: UUID(), url: song.identityURL, title: "在线歌")
        let track = song.track()
        XCTAssertEqual(CurrentTrackLibraryActions.target(for: track, libraryTracks: [item]), .library(item))
        // 已入库且已收藏 → isFavorited 必须为 true（在线曲也能取消收藏）。
        XCTAssertTrue(CurrentTrackLibraryActions.isFavorited(track, libraryTracks: [item], favoriteIds: [item.id]))
    }

    /// 本地文件但不在库中（临时文件）→ 无可收藏落点。
    func testUnregisteredLocalFileHasNoTarget() {
        let track = Track(url: URL(fileURLWithPath: "/tmp/临时.mp3"), title: "临时")
        XCTAssertNil(CurrentTrackLibraryActions.target(for: track, libraryTracks: []))
    }

    func testNilTrackHasNoTarget() {
        XCTAssertNil(CurrentTrackLibraryActions.target(for: nil, libraryTracks: []))
    }

    /// 已收藏判定：只有能定位到库项且 id 在收藏集合里才为真。
    func testFavoritedLookup() {
        let item = libraryTrack("已收藏")
        let track = Track(id: item.id, url: item.url, title: item.title)
        XCTAssertTrue(CurrentTrackLibraryActions.isFavorited(track, libraryTracks: [item], favoriteIds: [item.id]))
        XCTAssertFalse(CurrentTrackLibraryActions.isFavorited(track, libraryTracks: [item], favoriteIds: []))

        let song = SongData(source: .netease, sourceID: "1", title: "在线")
        XCTAssertFalse(CurrentTrackLibraryActions.isFavorited(song.track(), libraryTracks: [], favoriteIds: []),
                       "未入库的在线歌视为未收藏")
    }
}
