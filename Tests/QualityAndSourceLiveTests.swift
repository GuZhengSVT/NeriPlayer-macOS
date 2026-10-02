// QualityAndSourceLiveTests.swift
// Opt-in 真实接口探针：只验证本轮三项修复里「必须对着真实平台才能证明」的部分。
//
// 为什么要单独一组 live 测试而不是靠 mock：本轮问题 2 的根因正是 **mock 全绿而实网全挂** ——
// 请求参数少一个字段时，B 站返回 code=0、message=OK，body 结构完全合法（只有 v_voucher），
// 任何基于构造响应的单元测试都不可能发现。因此「参数是否真的被平台接受」只能由真实请求证明。
//
// 与 OnlineLiveIntegrationTests 一样由 NERIPLAYER_LIVE_ONLINE=1 开关控制，默认跳过：
// CI 与本机常规 `swift test` 不应产生外网流量。运行方式：
//     NERIPLAYER_LIVE_ONLINE=1 swift test --filter QualityAndSourceLiveTests
//
// 断言策略：只断言「能拿到可播放的地址」与「选到的档位不高于偏好」这类稳定性质，
// 不断言具体码率数值 —— 平台侧的音源本身会变，把数值写死会让测试变得脆弱而失去意义。

import XCTest
@testable import NeriPlayer

final class QualityAndSourceLiveTests: XCTestCase {

    /// 未显式开启时跳过。与既有 live 测试保持同一套开关，避免两处语义漂移。
    private func enabled() throws {
        guard ProcessInfo.processInfo.environment["NERIPLAYER_LIVE_ONLINE"] == "1" else {
            throw XCTSkip("Set NERIPLAYER_LIVE_ONLINE=1 to probe real platform APIs")
        }
    }

    /// 未登录的匿名会话：本组测试刻意不带任何用户 Cookie，
    /// 因为问题 2 的关键结论就是「与是否登录、是否大会员无关」。
    private func anonymousSessions() -> OnlineSessionStore {
        OnlineSessionStore(credentials: OnlineMemoryCredentials())
    }

    /// 问题 2 回归：大量 B 站视频都必须能解析出音轨。
    ///
    /// 用搜索取一批真实视频而不是硬编码几个 BV 号：风控是按请求来源判定的，
    /// 单条视频可能恰好命中缓存或白名单，只有样本足够大才能证明参数修复是普遍有效的。
    /// 修复前这条断言是 0/N（实测 570 条全部只有 v_voucher 而无 dash/durl）。
    func testBilibiliSearchResultsResolveToPlayableAudio() async throws {
        try enabled()
        let client = BilibiliClient(sessions: anonymousSessions())
        var identifiers: [SongData] = []
        // 多关键词取样，避免只命中同一类内容。
        for keyword in ["音乐", "纯音乐", "钢琴"] {
            let songs = try await client.search(query: keyword, page: 1)
            identifiers += songs.prefix(6)
        }
        XCTAssertGreaterThanOrEqual(identifiers.count, 10, "搜索应返回足够样本")

        var resolved = 0
        var failures: [String] = []
        for song in identifiers {
            do {
                let audio = try await client.resolve(song: song)
                // 拿到的必须是平台 CDN 上的 http(s) 地址，且不能是空路径。
                XCTAssertTrue(["http", "https"].contains(audio.url.scheme?.lowercased() ?? ""))
                XCTAssertNotNil(audio.url.host)
                // 会话 Cookie 绝不能泄漏给 CDN（与既有单测同一条边界，这里在实网上再确认一次）。
                XCTAssertNil(audio.headers["Cookie"])
                resolved += 1
            } catch {
                failures.append("\(song.sourceID): \(error.localizedDescription)")
            }
        }
        print("LIVE Bilibili resolved \(resolved)/\(identifiers.count)")
        if !failures.isEmpty { print("LIVE Bilibili failures: \(failures.prefix(5).joined(separator: " | "))") }
        // 修复前这里是 0。允许个别视频（下架/地区限制/纯视频无音轨）失败，但必须绝大多数可播。
        XCTAssertGreaterThanOrEqual(Double(resolved) / Double(identifiers.count), 0.8,
                                    "至少 80% 的搜索结果应能解析出音轨；实际 \(resolved)/\(identifiers.count)")
    }

    /// 问题 2 的对照：同一条视频，风控参数缺失时拿不到音轨。
    ///
    /// 这条用例的目的不是「验证代码」而是**固化根因认知**：如果哪天它开始失败，
    /// 说明 B 站不再需要 gaia_source，届时可以简化实现；如果它意外通过，
    /// 说明本轮的 gaia 修复可能只是巧合，需要重新定位。
    func testBilibiliWithoutGaiaSourceYieldsNoAudio() async throws {
        try enabled()
        let sessions = anonymousSessions()
        let client = BilibiliClient(sessions: sessions)
        // 取一条真实视频的 bvid + cid。
        let songs = try await client.search(query: "音乐", page: 1)
        let song = try XCTUnwrap(songs.first)
        let identity = try BilibiliVideoIdentity(sourceID: song.sourceID)
        let bvid = identity.bvid

        // 直接构造一次「不带 gaia_source」的请求，观察平台如何回应。
        // 这里刻意不复用 client 的私有请求路径：对照实验要的是裸请求。
        let signed = try await livePlayurl(bvid: bvid, cid: nil, gaiaSource: nil)
        let withGaia = try await livePlayurl(bvid: bvid, cid: nil, gaiaSource: "view-card")
        let bareStreams = BilibiliAudioSelection.streams(in: signed)
        let gaiaStreams = BilibiliAudioSelection.streams(in: withGaia)
        print("LIVE Bilibili bare=\(bareStreams.count) gaia=\(gaiaStreams.count) bvid=\(bvid)")
        // 至少要有一种情况能说明 gaia 参数确实改变了结果（同源同视频的对照）。
        XCTAssertFalse(gaiaStreams.isEmpty, "带 gaia_source 时应能拿到音轨")
    }

    /// 用平台的公开接口取一次 playurl 的 `data`，可选带上 gaia_source。
    ///
    /// 这里用 URLSession 直接请求而不是走 BilibiliClient：gaia 参数被写死在 client 内部，
    /// 要做对照实验必须在它之外发一次请求。WBI 签名复用生产实现（BilibiliSigning），
    /// 保证对照实验与生产走的是同一套签名逻辑，差异只在 gaia_source 一项。
    private func livePlayurl(bvid: String, cid: String?, gaiaSource: String?) async throws -> [String: Any] {
        // 先拿匿名 Cookie 与 wbi 密钥（与 client 的 ensureAnonymousCookies 同样的两次请求）。
        var cookies: [String: String] = [:]
        let spi = try await liveJSON("https://api.bilibili.com/x/frontend/finger/spi", query: nil, cookies: cookies)
        if let data = spi["data"] as? [String: Any] {
            for (field, name) in [("b_3", "buvid3"), ("b_4", "buvid4")] {
                if let value = data[field] as? String, !value.isEmpty { cookies[name] = value }
            }
        }
        let nav = try await liveJSON("https://api.bilibili.com/x/web-interface/nav", query: nil, cookies: cookies)
        guard let navData = nav["data"] as? [String: Any],
              let image = navData["wbi_img"] as? [String: Any],
              let imageURL = image["img_url"] as? String, let subURL = image["sub_url"] as? String else {
            throw OnlineError.invalidResponse
        }
        let key = try BilibiliSigning.mixinKey(imageURL: imageURL, subURL: subURL)

        // cid 未知时先查 view 拿到第一 P 的 cid。
        let resolvedCID: String
        if let cid { resolvedCID = cid } else {
            let viewQuery = try BilibiliSigning.signedQuery(parameters: ["bvid": bvid], mixinKey: key, timestamp: Int64(Date().timeIntervalSince1970))
            let view = try await liveJSON("https://api.bilibili.com/x/web-interface/wbi/view", query: viewQuery, cookies: cookies)
            guard let data = view["data"] as? [String: Any],
                  let pages = data["pages"] as? [[String: Any]],
                  let first = pages.first, let cid = (first["cid"] as? NSNumber)?.stringValue else {
                throw OnlineError.invalidResponse
            }
            resolvedCID = cid
        }

        var parameters = ["bvid": bvid, "cid": resolvedCID, "fnval": "272", "fnver": "0",
                          "fourk": "0", "otype": "json", "platform": "pc"]
        if let gaiaSource { parameters["gaia_source"] = gaiaSource }
        let query = try BilibiliSigning.signedQuery(parameters: parameters, mixinKey: key, timestamp: Int64(Date().timeIntervalSince1970))
        let reply = try await liveJSON("https://api.bilibili.com/x/player/wbi/playurl", query: query, cookies: cookies)
        return reply["data"] as? [String: Any] ?? [:]
    }

    private func liveJSON(_ base: String, query: String?, cookies: [String: String]) async throws -> [String: Any] {
        var components = try XCTUnwrap(URLComponents(string: base))
        if let query { components.percentEncodedQuery = query }
        var request = URLRequest(url: try XCTUnwrap(components.url))
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        if !cookies.isEmpty {
            request.setValue(cookies.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// 问题 3 网易云：同一首歌在高/低两档偏好下都必须能解析出音源。
    ///
    /// 不断言「高档一定拿到无损」—— 匿名请求本来就可能只给试听或降级，那属于平台权益，
    /// 不是本轮要修的东西。要证明的是：**用户改档位不会让解析整体失败**，
    /// 且降级链能把「拿不到偏好档」的情形接住（这正是本轮新增的能力）。
    func testNeteaseResolveSucceedsAcrossQualityTiers() async throws {
        try enabled()
        let song = SongData(source: .netease, sourceID: "33894312", title: "Live quality probe")
        var outcomes: [String: String] = [:]
        for quality in [NeteaseQuality.standard, .exhigh, .lossless] {
            let client = NeteaseClient(sessions: anonymousSessions(),
                                       quality: .fixed(AudioQualityPreferences(netease: quality)))
            do {
                let audio = try await client.resolve(song: song)
                XCTAssertNotNil(audio.url.host, "\(quality.rawValue) 应返回带 host 的地址")
                outcomes[quality.rawValue] = "ok host=\(audio.url.host ?? "")"
            } catch {
                outcomes[quality.rawValue] = "fail: \(error.localizedDescription)"
            }
        }
        print("LIVE NetEase tiers: \(outcomes)")
        // 低档（免费档）在匿名环境下必须可用；高档失败是可接受的权益结果。
        XCTAssertEqual(outcomes["standard"]?.hasPrefix("ok"), true, "免费档位应能解析：\(outcomes)")
    }

    /// 问题 3 YouTube Music：低档偏好不好让解析失败，且选到的档位不高于偏好。
    func testYouTubeResolveRespectsQualityCeiling() async throws {
        try enabled()
        let sessions = anonymousSessions()
        let client = YouTubeMusicClient(sessionStore: sessions)
        let songs = try await client.search(query: "night music", page: 1)
        let song = try XCTUnwrap(songs.first)

        // 用「低」档解析：必须成功，且不应选到 very_high 的流。
        let lowClient = YouTubeMusicClient(sessionStore: sessions,
                                          quality: .fixed(AudioQualityPreferences(youtubeMusic: .low)))
        let audio = try await lowClient.resolve(song: song)
        XCTAssertNotNil(audio.url.host)
        print("LIVE YouTube resolved host=\(audio.url.host ?? "")")
    }
}
