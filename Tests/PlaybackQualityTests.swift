// PlaybackQualityTests.swift
// NeriPlayer macOS —— 各平台音质偏好与 B 站选轨的纯逻辑测试。
//
// 这一层刻意不碰网络、不碰 UI、不碰 libmpv：三件事必须能被确定性地断言 ——
//   1) 降级链的顺序与完备性（用户点的那一档拿不到时必须退到下一档，而不是报「没有音源」）；
//   2) B 站「本地选轨」的档位边界（上界必须存在，否则选「高」会拿到无损）；
//   3) 设置读写：坏值/缺值回落到默认，且写入侧夹取后读回一致。
//
// 之所以把选轨从 BilibiliClient 里抽出来单测：它曾经是「取带宽最大的一条」，
// 在用户显式选了低档时会给出一条近无损的流 —— 这类错误只有对着候选集断言才看得见。

import XCTest
@testable import NeriPlayer

final class PlaybackQualityTests: XCTestCase {

    // MARK: - 默认值与解析

    /// 三个平台的默认档位必须与 Android AutoSettingsSchema 的 defaultString 一致。
    func testPlatformDefaultsMatchAndroid() {
        XCTAssertEqual(NeteaseQuality.default, .exhigh, "网易云默认应为 exhigh")
        XCTAssertEqual(YouTubeQuality.default, .high, "YouTube Music 默认应为 high")
        XCTAssertEqual(BilibiliQuality.default, .high, "Bilibili 默认应为 high")
    }

    /// 无法识别的存储值回落到默认，而不是抛错 —— 手改坏的 UserDefaults 不该让播放失败。
    func testUnknownStoredValueFallsBackToDefault() {
        XCTAssertEqual(NeteaseQuality(stored: "bogus"), .exhigh)
        XCTAssertEqual(NeteaseQuality(stored: ""), .exhigh)
        XCTAssertEqual(YouTubeQuality(stored: "very-high"), .high, "连字符不是合法 rawValue")
        XCTAssertEqual(BilibiliQuality(stored: "128k"), .high)
    }

    /// 合法存储值原样解析（含 YouTube 的下划线形式）。
    func testKnownStoredValuesRoundTrip() {
        XCTAssertEqual(NeteaseQuality(stored: "jymaster"), .jymaster)
        XCTAssertEqual(YouTubeQuality(stored: "very_high"), .veryHigh)
        XCTAssertEqual(YouTubeQuality(stored: "very_high").rawValue, "very_high", "rawValue 必须是平台/存储用的下划线形式")
        XCTAssertEqual(BilibiliQuality(stored: "dolby"), .dolby)
    }

    /// 每个档位的 rawValue 都能被自己的 init(stored:) 解析回来。
    func testAllCasesRoundTripThroughRawValue() {
        for quality in NeteaseQuality.allCases {
            XCTAssertEqual(NeteaseQuality(stored: quality.rawValue), quality)
        }
        for quality in YouTubeQuality.allCases {
            XCTAssertEqual(YouTubeQuality(stored: quality.rawValue), quality)
        }
        for quality in BilibiliQuality.allCases {
            XCTAssertEqual(BilibiliQuality(stored: quality.rawValue), quality)
        }
    }

    // MARK: - 网易云降级链

    /// 档位顺序与 Android 的 NETEASE_QUALITY_FALLBACK_ORDER 一致。
    func testNeteaseFallbackOrderMatchesAndroid() {
        XCTAssertEqual(
            NeteaseQuality.fallbackOrder,
            [.jymaster, .sky, .jyeffect, .hires, .lossless, .exhigh, .higher, .standard]
        )
    }

    /// 从任意档位出发的降级链：以自身开头，且严格单调向下直到 standard。
    func testNeteaseDegradeChainIsMonotonicToStandard() {
        for quality in NeteaseQuality.allCases {
            let chain = quality.degradeChain
            XCTAssertEqual(chain.first, quality, "降级链必须从自身开始")
            XCTAssertEqual(chain.last, .standard, "降级链必须走到底档")
            // 链上每一项都是完整的 fallbackOrder 后缀。
            XCTAssertEqual(chain, Array(NeteaseQuality.fallbackOrder.suffix(chain.count)))
        }
        XCTAssertEqual(NeteaseQuality.standard.degradeChain, [.standard])
        XCTAssertEqual(NeteaseQuality.jymaster.degradeChain, NeteaseQuality.fallbackOrder)
    }

    /// 会员档位的标记：低三档免费，其余需要会员（设置页据此加「需会员」后缀）。
    func testNeteaseMembershipTiers() {
        XCTAssertFalse(NeteaseQuality.standard.requiresMembership)
        XCTAssertFalse(NeteaseQuality.higher.requiresMembership)
        XCTAssertFalse(NeteaseQuality.exhigh.requiresMembership)
        for quality in [NeteaseQuality.lossless, .hires, .jyeffect, .sky, .jymaster] {
            XCTAssertTrue(quality.requiresMembership, "\(quality.rawValue) 应为会员档位")
            XCTAssertTrue(quality.menuTitle.contains("需会员"))
        }
    }

    // MARK: - YouTube 档位推断

    /// 码率归档的边界必须与 Android 的 inferYouTubeQualityKeyFromBitrate 一致。
    func testYouTubeQualityInferenceBoundaries() {
        XCTAssertEqual(YouTubeQuality.infer(bitrateKbps: nil), .low, "未知码率按最低档")
        XCTAssertEqual(YouTubeQuality.infer(bitrateKbps: 0), .low)
        XCTAssertEqual(YouTubeQuality.infer(bitrateKbps: 95), .low)
        XCTAssertEqual(YouTubeQuality.infer(bitrateKbps: 96), .medium)
        XCTAssertEqual(YouTubeQuality.infer(bitrateKbps: 127), .medium)
        XCTAssertEqual(YouTubeQuality.infer(bitrateKbps: 128), .high)
        XCTAssertEqual(YouTubeQuality.infer(bitrateKbps: 159), .high)
        XCTAssertEqual(YouTubeQuality.infer(bitrateKbps: 160), .veryHigh)
        XCTAssertEqual(YouTubeQuality.infer(bitrateKbps: 320), .veryHigh)
    }

    /// YouTube 的降级链由高到低，且底档是 low。
    func testYouTubeDegradeChain() {
        XCTAssertEqual(YouTubeQuality.veryHigh.degradeChain, [.veryHigh, .high, .medium, .low])
        XCTAssertEqual(YouTubeQuality.high.degradeChain, [.high, .medium, .low])
        XCTAssertEqual(YouTubeQuality.low.degradeChain, [.low])
    }

    // MARK: - Bilibili 选轨

    /// 构造一条普通音轨（无标签）。
    private func regular(_ kbps: Int, name: String = UUID().uuidString) -> BilibiliAudioStream {
        BilibiliAudioStream(
            mimeType: "audio/mp4",
            bitrateKbps: kbps,
            url: URL(string: "https://upos-sz-mirrorcos.bilivideo.com/\(name).m4s")!
        )
    }

    /// 用户在候选集里选哪一档，就应该落在那一档的码率区间内。
    func testSelectHonoursRegularBitrateTiers() {
        let streams = [regular(64, name: "low"), regular(128, name: "mid"), regular(192, name: "high")]

        XCTAssertEqual(BilibiliAudioSelection.select(from: streams, preferred: .high)?.bitrateKbps, 192)
        XCTAssertEqual(BilibiliAudioSelection.select(from: streams, preferred: .medium)?.bitrateKbps, 128)
        XCTAssertEqual(BilibiliAudioSelection.select(from: streams, preferred: .low)?.bitrateKbps, 64)
    }

    /// 关键回归：`high` 必须有码率上界。若只判下限，候选里那条 1000 kbps 的普通音轨
    /// 会在用户选「高」时被当成 high 命中，用户拿到的是近无损。
    func testSelectHighDoesNotPickLosslessBitrate() {
        let streams = [regular(192, name: "high"), regular(1_000, name: "veryhigh")]
        let selected = BilibiliAudioSelection.select(from: streams, preferred: .high)
        XCTAssertEqual(selected?.bitrateKbps, 192, "high 不应命中 1000 kbps 的普通音轨")
    }

    /// 无损档位优先命中带 hires 标签的轨；没有标签轨时退到 flac MIME。
    func testSelectLosslessPrefersTaggedThenFlacMIME() {
        let flac = BilibiliAudioStream(
            mimeType: "audio/flac", bitrateKbps: 900, qualityTag: "hires",
            url: URL(string: "https://upos-sz-mirrorcos.bilivideo.com/flac.m4s")!
        )
        let selection = BilibiliAudioSelection.select(from: [regular(192), flac], preferred: .lossless)
        XCTAssertEqual(selection?.mimeType, "audio/flac")

        // 没有标签、只有 flac MIME 的情况。
        let untaggedFLAC = BilibiliAudioStream(
            mimeType: "audio/flac; codecs=\"flac\"", bitrateKbps: 800,
            url: URL(string: "https://upos-sz-mirrorcos.bilivideo.com/untagged.m4s")!
        )
        let second = BilibiliAudioSelection.select(from: [regular(192), untaggedFLAC], preferred: .lossless)
        XCTAssertTrue(second?.mimeType.hasPrefix("audio/flac") == true, "flac MIME 应被认成无损")
    }

    /// 干净命中：选 dolby 时拿到带 dolby 标签的轨，即使普通轨码率更高。
    func testSelectDolbyPrefersTaggedTrack() {
        let dolby = BilibiliAudioStream(
            mimeType: "audio/eac3", bitrateKbps: 448, qualityTag: "dolby",
            url: URL(string: "https://upos-sz-mirrorcos.bilivideo.com/dolby.m4s")!
        )
        let selection = BilibiliAudioSelection.select(from: [regular(192), dolby], preferred: .dolby)
        XCTAssertEqual(selection?.qualityTag, "dolby")
    }

    /// 没有对应标签时降级：要 hires 但只有普通轨，应退到链上第一个够得着的档位，而不是失败。
    func testSelectDegradesWhenTaggedTierMissing() {
        let streams = [regular(64, name: "a"), regular(192, name: "b")]
        let selection = BilibiliAudioSelection.select(from: streams, preferred: .hires)
        XCTAssertNotNil(selection, "缺少 Hi-Res 轨时应降级而不是返回 nil")
        XCTAssertEqual(selection?.bitrateKbps, 192)
    }

    /// 一条音轨都不剩时返回 nil（调用方据此报「未返回可播放音轨」）。
    func testSelectReturnsNilForEmptyCandidates() {
        XCTAssertNil(BilibiliAudioSelection.select(from: [], preferred: .high))
    }

    /// 兜底：候选集与任何档位都不匹配（例如一条 44 kbps 的 HE-AAC）时，
    /// 必须给出一条能播的流，绝不返回 nil。低档不设码率下限正是为了这条。
    func testSelectAlwaysFallsBackToAPlayableStream() {
        let streams = [regular(44, name: "heaac")]
        XCTAssertEqual(BilibiliAudioSelection.select(from: streams, preferred: .low)?.bitrateKbps, 44)
        // 即使偏好高于候选集里的一切，也应有兜底。
        XCTAssertNotNil(BilibiliAudioSelection.select(from: streams, preferred: .high))
    }

    /// 渐进式回退流不参与普通档位匹配（它是 video/mp4，不是 DASH 音轨）。
    func testProgressiveFallbackExcludedFromRegularTiers() {
        let progressive = BilibiliAudioStream(
            mimeType: "video/mp4", bitrateKbps: 500,
            url: URL(string: "https://upos-sz-mirrorcos.bilivideo.com/durl.mp4")!,
            isProgressiveFallback: true
        )
        XCTAssertFalse(BilibiliAudioSelection.matchesRegular(progressive, quality: .high))
        // 但作为唯一候选时仍要能选出来。
        XCTAssertEqual(BilibiliAudioSelection.select(from: [progressive], preferred: .high)?.bitrateKbps, 500)
    }

    // MARK: - Bilibili 候选解析

    /// 解析真实形态的 playurl data：普通轨 + 杜比 + flac 全部收进来。
    func testStreamsParsesDashDolbyAndFlac() {
        let data: [String: Any] = [
            "dash": [
                "audio": [
                    ["id": 30216, "bandwidth": 43_962, "baseUrl": "https://upos-sz-mirrorcos.bilivideo.com/a.m4s"],
                    ["id": 30280, "bandwidth": 203_786, "baseUrl": "https://upos-sz-mirrorcos.bilivideo.com/b.m4s"]
                ],
                "dolby": ["audio": [["id": 30250, "bandwidth": 448_000, "baseUrl": "https://upos-sz-mirrorcos.bilivideo.com/d.m4s"]]],
                "flac": ["audio": ["id": 30251, "bandwidth": 1_411_000, "baseUrl": "https://upos-sz-mirrorcos.bilivideo.com/f.m4s"]]
            ]
        ]
        let streams = BilibiliAudioSelection.streams(in: data)
        XCTAssertEqual(streams.count, 4)
        XCTAssertEqual(streams.filter { $0.qualityTag == "dolby" }.count, 1)
        XCTAssertEqual(streams.filter { $0.qualityTag == "hires" }.count, 1)
        XCTAssertEqual(streams.first { $0.id == 30280 }?.bitrateKbps, 203, "bandwidth 应按 /1000 换算成 kbps")
    }

    /// flac 在 JSON 里是对象而不是数组；这条断言固化解析不会把它当成数组丢掉。
    func testStreamsReadsFlacObjectNotArray() {
        let data: [String: Any] = [
            "dash": ["flac": ["audio": ["bandwidth": 1_000_000, "baseUrl": "https://upos-sz-mirrorcos.bilivideo.com/f.m4s"]]]
        ]
        let streams = BilibiliAudioSelection.streams(in: data)
        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(streams.first?.qualityTag, "hires")
    }

    /// DASH 没有音轨时才使用 durl；多条分片无法用一个 URL 表达，直接放弃。
    func testProgressiveFallbackOnlyWhenDASHHasNoAudio() {
        let single: [String: Any] = [
            "durl": [["url": "https://upos-sz-mirrorcos.bilivideo.com/one.mp4", "size": 1_000_000, "length": 16_000]]
        ]
        let one = BilibiliAudioSelection.streams(in: single)
        XCTAssertEqual(one.count, 1)
        XCTAssertTrue(one[0].isProgressiveFallback)
        XCTAssertEqual(one[0].bitrateKbps, 500, "码率应由 size*8/length 估算")

        let multiple: [String: Any] = [
            "durl": [["url": "https://upos-sz-mirrorcos.bilivideo.com/one.mp4"],
                     ["url": "https://upos-sz-mirrorcos.bilivideo.com/two.mp4"]]
        ]
        XCTAssertTrue(BilibiliAudioSelection.streams(in: multiple).isEmpty, "多分片应放弃")

        // DASH 有音轨时完全不看 durl。
        let both: [String: Any] = [
            "dash": ["audio": [["bandwidth": 200_000, "baseUrl": "https://upos-sz-mirrorcos.bilivideo.com/a.m4s"]]],
            "durl": [["url": "https://upos-sz-mirrorcos.bilivideo.com/one.mp4"]]
        ]
        let combined = BilibiliAudioSelection.streams(in: both)
        XCTAssertEqual(combined.count, 1)
        XCTAssertFalse(combined[0].isProgressiveFallback)
    }

    /// 风控响应（只有 v_voucher）必须解析成「零候选」，让客户端走重试而不是当成功。
    func testStreamsReturnsEmptyForRiskControlResponse() {
        XCTAssertTrue(BilibiliAudioSelection.streams(in: ["v_voucher": "abc"]).isEmpty)
        XCTAssertTrue(BilibiliAudioSelection.streams(in: [:]).isEmpty)
    }

    /// CDN 优先级：upos 优先于普通 bilivideo，mountaintoys 最后；备用地址保持顺序。
    func testCandidateURLOrderingPrefersUPOS() {
        let data: [String: Any] = [
            "dash": ["audio": [[
                "bandwidth": 200_000,
                "baseUrl": "https://cn-hbyc-cu-01.mountaintoys.cn/a.m4s",
                "backupUrl": ["https://upos-sz-mirrorcos.bilivideo.com/backup.m4s",
                              "https://cn-jsnj.bilivideo.com/second.m4s"]
            ]]]
        ]
        let stream = BilibiliAudioSelection.streams(in: data).first
        XCTAssertEqual(stream?.url.host, "upos-sz-mirrorcos.bilivideo.com", "upos 应排到最前")
        XCTAssertEqual(stream?.backupURLs.map(\.host), ["cn-jsnj.bilivideo.com", "cn-hbyc-cu-01.mountaintoys.cn"])
    }

    /// 非法地址（javascript: / 空串）不进入候选，避免把坏 URL 交给播放器。
    func testCandidateURLsRejectInvalidSchemes() {
        let data: [String: Any] = [
            "dash": ["audio": [[
                "bandwidth": 200_000, "baseUrl": "javascript:bad",
                "backupUrl": ["https://upos-sz-mirrorcos.bilivideo.com/ok.m4s", ""]
            ]]]
        ]
        let streams = BilibiliAudioSelection.streams(in: data)
        XCTAssertEqual(streams.count, 1, "只剩一条合法地址")
        XCTAssertEqual(streams.first?.url.host, "upos-sz-mirrorcos.bilivideo.com")
    }

    /// 可用档位的枚举按由高到低返回，供界面/调试展示。
    func testAvailableQualitiesAreOrderedHighToLow() {
        let streams = [regular(64), regular(192), BilibiliAudioStream(
            mimeType: "audio/flac", bitrateKbps: 900, qualityTag: "hires",
            url: URL(string: "https://upos-sz-mirrorcos.bilivideo.com/f.m4s")!
        )]
        XCTAssertEqual(BilibiliAudioSelection.availableQualities(in: streams), [.hires, .high, .low])
    }

    // MARK: - 设置读写

    /// 用隔离的 UserDefaults 验证「读默认 → 写 → 读回」闭环，不污染真实 defaults。
    func testPreferencesPersistThroughSettingsStore() throws {
        let suite = "PlaybackQualityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(userDefaults: defaults)

        // 未设置时全部落默认。
        let initial = AudioQualityPreferences(settings: settings)
        XCTAssertEqual(initial.netease, .exhigh)
        XCTAssertEqual(initial.youtubeMusic, .high)
        XCTAssertEqual(initial.bilibili, .high)

        var updated = initial
        updated.netease = .jymaster
        updated.youtubeMusic = .veryHigh
        updated.bilibili = .dolby
        updated.write(to: settings)

        let reloaded = AudioQualityPreferences(settings: settings)
        XCTAssertEqual(reloaded, updated, "写回后应完整读回")
        XCTAssertEqual(settings.value(for: SettingsKeys.youtubeMusicAudioQuality), "very_high")
    }

    /// 存储里是坏值时读取回落默认，不抛错。
    func testPreferencesFallBackWhenStoredValueIsGarbage() throws {
        let suite = "PlaybackQualityTests.garbage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("not-a-quality", forKey: SettingsKeys.neteaseAudioQuality.name)
        defaults.set(42, forKey: SettingsKeys.youtubeMusicAudioQuality.name)
        let settings = SettingsStore(userDefaults: defaults)

        let preferences = AudioQualityPreferences(settings: settings)
        XCTAssertEqual(preferences.netease, .exhigh)
        XCTAssertEqual(preferences.youtubeMusic, .high, "非字符串值应回落默认")
        XCTAssertEqual(preferences.bilibili, .high)
    }

    /// 提供者每次调用都重新读，保证用户在设置页改完对下一次解析立即生效。
    func testProviderReadsLatestValueOnEachCall() throws {
        let suite = "PlaybackQualityTests.live.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(userDefaults: defaults)
        let provider = AudioQualityProvider { AudioQualityPreferences(settings: settings) }

        XCTAssertEqual(provider.preferences().bilibili, .high)
        settings.set(BilibiliQuality.low.rawValue, for: SettingsKeys.bilibiliAudioQuality)
        XCTAssertEqual(provider.preferences().bilibili, .low, "提供者必须读到最新值")
    }

    /// 固定提供者不受设置变更影响（测试注入用）。
    func testFixedProviderIgnoresSettings() {
        let provider = AudioQualityProvider.fixed(AudioQualityPreferences(netease: .standard, youtubeMusic: .low, bilibili: .medium))
        XCTAssertEqual(provider.preferences().netease, .standard)
        XCTAssertEqual(provider.preferences().youtubeMusic, .low)
        XCTAssertEqual(provider.preferences().bilibili, .medium)
    }
}
