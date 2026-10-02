// BilibiliClient.swift
// M5-T3: WBI search, exact video-page audio resolution, favorites and QR login.
// Endpoint semantics adapted from Android core/api/bili/BiliClient and BiliQrLoginClient.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor BilibiliClient: OnlineMusicClient {
    public nonisolated let source = MusicSource.bilibili
    private let session: URLSession
    private let sessions: OnlineSessionStore
    private let apiBase: URL
    private let passportBase: URL
    /// 音质偏好读取入口。刻意不在构造时读一次：actor 会长期存活，缓存偏好会让设置页的改动不生效。
    private let qualityProvider: AudioQualityProvider
    private let now: @Sendable () -> Date
    private var cachedMixin: (key: String, date: Date)?
    private var anonymousCookies: [String: String] = [:]
    private var anonymousCookiesDate: Date?
    private var qrCookies: [String: [String: String]] = [:]
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    /// 空音轨重试次数，与 Android `BiliClient.EMPTY_AUDIO_RETRY_COUNT` 一致。
    private static let emptyAudioRetryCount = 3
    /// 空音轨重试的基础等待（纳秒），与 Android `EMPTY_AUDIO_RETRY_DELAY_MS = 250` 一致。
    private static let emptyAudioRetryDelayNanoseconds: UInt64 = 250_000_000
    /// 来源风控参数。Android 的 `PlayOptions.gaiaSource` 由 BiliPlaybackRepository 传 "view-card"。
    private static let gaiaSource = "view-card"

    /// `quality` 默认 `.settings`（生产读实时设置），测试可注入 `.fixed(...)` 得到确定结果。
    public init(session: URLSession = .shared, sessions: OnlineSessionStore = .shared,
                apiBase: URL? = nil, passportBase: URL? = nil,
                quality: AudioQualityProvider = .settings,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.sessions = sessions
        self.apiBase = apiBase ?? BilibiliParsing.endpoint(host: "api.bilibili.com")
        self.passportBase = passportBase ?? BilibiliParsing.endpoint(host: "passport.bilibili.com")
        self.qualityProvider = quality
        self.now = now
    }

    public func search(query: String, page: Int = 1) async throws -> [SongData] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, (1...1000).contains(page) else {
            throw OnlineError.invalidInput("搜索关键词或页码无效")
        }
        let data = try await api("/x/web-interface/wbi/search/type", parameters: [
            "search_type": "video", "keyword": keyword, "order": "totalrank", "duration": "0", "tids": "0", "page": String(page)
        ], signed: true)
        guard let results = data["result"] as? [[String: Any]] else { return [] }
        return results.compactMap { item in
            guard item["type"] as? String == "video", let bvid = item["bvid"] as? String,
                  let identity = try? BilibiliVideoIdentity(sourceID: bvid) else { return nil }
            return SongData(source: .bilibili, sourceID: identity.sourceID,
                            title: BilibiliParsing.plainText(item["title"] as? String ?? ""),
                            artist: item["author"] as? String ?? "",
                            duration: BilibiliParsing.duration(item["duration"] as? String),
                            artworkURL: BilibiliParsing.httpURL(item["pic"] as? String), pageURL: identity.pageURL)
        }
    }

    /// Exposes every video part without searching titles or silently substituting P1.
    public func pages(for song: SongData) async throws -> [SongData] {
        let identity = try requireIdentity(song)
        let data = try await video(identity)
        guard let pages = data["pages"] as? [[String: Any]] else { throw OnlineError.invalidResponse }
        let owner = (data["owner"] as? [String: Any])?["name"] as? String ?? song.artist
        return pages.compactMap { page in
            guard let index = BilibiliParsing.integer(page["page"]), index > 0,
                  let part = page["part"] as? String,
                  let pageIdentity = try? BilibiliVideoIdentity(sourceID: "\(identity.bvid):\(index)") else { return nil }
            let metadata = BilibiliParsing.partMetadata(part, fallbackArtist: owner)
            return SongData(source: .bilibili, sourceID: pageIdentity.sourceID, title: metadata.title, artist: metadata.artist,
                            album: data["title"] as? String ?? song.title,
                            duration: (page["duration"] as? NSNumber)?.doubleValue,
                            artworkURL: BilibiliParsing.httpURL(data["pic"] as? String), pageURL: pageIdentity.pageURL)
        }
    }

    public func syncMetadata(for song: SongData) async throws -> SongData {
        let identity = try requireIdentity(song)
        let data = try await video(identity)
        let pages = data["pages"] as? [[String: Any]] ?? []
        guard let page = pages.first(where: {
            if let cid = identity.cid { return BilibiliParsing.positiveID($0["cid"]) == cid }
            return BilibiliParsing.integer($0["page"]) == identity.page
        }), let cid = BilibiliParsing.positiveID(page["cid"]) else {
            throw OnlineError.unavailable("指定的 Bilibili 分 P 已不存在")
        }
        var result = song
        result.sourceSubID = cid
        result.sourceAudioID = BilibiliParsing.positiveID(data["aid"])
        result.album = "Bilibili|\(cid)|\(data["bvid"] as? String ?? identity.bvid)"
        let source = result.sourceAudioID.map { "av" + $0 } ?? (data["bvid"] as? String ?? identity.bvid)
        result.sourceID = "\(source):cid:\(cid)"
        return result
    }

    public func resolve(song: SongData) async throws -> ResolvedAudio {
        let identity = try requireIdentity(song)
        let data = try await video(identity)
        let pages = data["pages"] as? [[String: Any]] ?? []
        guard let page = pages.first(where: {
            if let cid = identity.cid { return BilibiliParsing.positiveID($0["cid"]) == cid }
            return BilibiliParsing.integer($0["page"]) == identity.page
        }),
              let cid = BilibiliParsing.positiveID(page["cid"]) else {
            throw OnlineError.unavailable("指定的 Bilibili 分 P 已不存在")
        }
        let canonicalBV = data["bvid"] as? String ?? identity.bvid
        // gaia_source=view-card 是 B 站的风控来源校验：不带它时接口返回 code=0 但 data 里只有
        // v_voucher，没有 dash 也没有 durl（实测 570 条视频 0 条有音轨，补上后 569 条可播）。
        // 这与是否登录、是否大会员无关，Android 的 PlayOptions.gaiaSource 一直带着它。
        // otype=json 同样对齐 Android 的 putCommonParams（固定下发 JSON 而不是 XML）。
        let preferred = qualityProvider.preferences().bilibili
        let playData = try await audioPlayData(bvid: canonicalBV, cid: cid)
        guard let stream = BilibiliParsing.audioStream(in: playData, preferred: preferred) else {
            throw OnlineError.unavailable("Bilibili 未返回可播放音轨（可能被平台风控拦截）")
        }
        var resolvedSong = song
        resolvedSong.sourceID = identity.sourceID
        resolvedSong.sourceSubID = cid
        resolvedSong.sourceAudioID = BilibiliParsing.positiveID(data["aid"])
        let pageNumber = BilibiliParsing.integer(page["page"]) ?? identity.page
        resolvedSong.pageURL = URL(string: "https://www.bilibili.com/video/\(identity.bvid)?p=\(pageNumber)")
        resolvedSong.duration = (page["duration"] as? NSNumber)?.doubleValue ?? song.duration
        let headers = ["User-Agent": Self.userAgent, "Referer": identity.pageURL?.absoluteString ?? "https://www.bilibili.com/"]
        // Session cookies stay on API requests, never leak to CDN audio URLs.
        // 渐进式回退（durl）的容器含视频轨，但播放侧以 vid=no / vo=null 启动 mpv（MPVLaunchOption.audioOnly），
        // 只会解出音轨，因此这里直接返回它不会开窗，也不会把视频当音频播。
        return ResolvedAudio(song: resolvedSong, url: stream.url, headers: headers,
                             expiresAt: BilibiliParsing.expiry(stream.url))
    }

    /// 取回可用于选轨的 playurl `data`。把「空音轨」当成一次独立的失败来对待：
    ///
    /// 1. DASH 请求最多 3 次（对齐 Android `getAllAudioStreams` 的 `EMPTY_AUDIO_RETRY_COUNT`），
    ///    逐次退避 250/500ms。每次重试都重新走签名 —— `wts` 过期本身也可能是被拒的原因之一，
    ///    复用上一次的签名串会让重试失去意义。
    /// 2. 「空」的定义与 Android `shouldRetryEmptyAudioFetch` 一致：dash audio / dolby / flac
    ///    一条都没有；单条 durl 会被 `candidateStreams` 当成可播音轨，因此直接返回不重试。
    ///    （地址全非法的极端情况也会被判空，这与 Android 略有差异，但重试比把坏 URL 交给播放器更好。）
    /// 3. 仍然没有音轨时，用 `fnval=0&platform=html5&high_quality=1` 再请求一次拿渐进式 durl。
    ///    这条路径同样要带 gaia_source，否则回退请求自己也会被风控挡掉。
    private func audioPlayData(bvid: String, cid: String) async throws -> [String: Any] {
        var lastData: [String: Any] = [:]
        for attempt in 1...Self.emptyAudioRetryCount {
            try Task.checkCancellation()
            let data = try await api("/x/player/wbi/playurl",
                                     parameters: Self.dashParameters(bvid: bvid, cid: cid), signed: true)
            if !BilibiliParsing.candidateStreams(in: data).isEmpty { return data }
            lastData = data
            if attempt < Self.emptyAudioRetryCount {
                Log.net.warning("Bilibili playurl 未返回音轨，重试 \(attempt, privacy: .public)/\(Self.emptyAudioRetryCount, privacy: .public)")
                try await Task.sleep(nanoseconds: Self.emptyAudioRetryDelayNanoseconds * UInt64(attempt))
            }
        }
        try Task.checkCancellation()
        let fallback = try await api("/x/player/wbi/playurl",
                                     parameters: Self.html5FallbackParameters(bvid: bvid, cid: cid), signed: true)
        return BilibiliParsing.candidateStreams(in: fallback).isEmpty ? lastData : fallback
    }

    /// DASH 请求参数：fnval=272 即 DASH(16) | Dolby(256)，与 Android FNVAL_DASH|FNVAL_DOLBY 一致。
    private static func dashParameters(bvid: String, cid: String) -> [String: String] {
        ["bvid": bvid, "cid": cid, "fnval": "272", "fnver": "0", "fourk": "0",
         "otype": "json", "platform": "pc", "gaia_source": gaiaSource]
    }

    /// html5 渐进式回退参数：与 Android `buildHtml5FallbackOptions` 一致（fnval=0、high_quality=1）。
    private static func html5FallbackParameters(bvid: String, cid: String) -> [String: String] {
        ["bvid": bvid, "cid": cid, "fnval": "0", "fnver": "0", "fourk": "0",
         "otype": "json", "platform": "html5", "high_quality": "1", "gaia_source": gaiaSource]
    }

    public func account() async throws -> OnlineAccount {
        guard let cookie = try sessions.cookieHeader(for: .bilibili),
              BilibiliParsing.cookies(cookie)["SESSDATA"]?.isEmpty == false else { throw OnlineError.authenticationRequired }
        let data = try await api("/x/web-interface/nav")
        guard (data["isLogin"] as? Bool) == true, let mid = BilibiliParsing.positiveID(data["mid"]),
              let name = data["uname"] as? String else { throw OnlineError.authenticationRequired }
        return OnlineAccount(id: mid, name: name)
    }

    public func collections() async throws -> [OnlineCollection] {
        let account = try await account()
        let created = try await api("/x/v3/fav/folder/created/list-all", parameters: ["up_mid": account.id, "web_location": "333.1387"])
        var folders = created["list"] as? [[String: Any]] ?? []
        if let count = BilibiliParsing.integer(created["count"]), count > folders.count {
            folders += try await folderPages(path: "/x/v3/fav/folder/created/list", mid: account.id)
        }
        folders += try await folderPages(path: "/x/v3/fav/folder/collected/list", mid: account.id)
        var seen = Set<String>()
        return folders.compactMap { item in
            // Collected list mixes seasons (type 21) with favorite folders; do not label them as media_id folders.
            guard (BilibiliParsing.integer(item["type"]) ?? 11) == 11,
                  let id = BilibiliParsing.positiveID(item["id"]), seen.insert(id).inserted else { return nil }
            return OnlineCollection(source: .bilibili, sourceID: id, title: item["title"] as? String ?? item["name"] as? String ?? "收藏夹",
                                    subtitle: account.name, artworkURL: BilibiliParsing.httpURL(item["cover"] as? String), kind: .favorites)
        }
    }

    public func songs(in collection: OnlineCollection) async throws -> [SongData] {
        guard collection.source == .bilibili, let mediaID = BilibiliParsing.positiveID(collection.sourceID) else {
            throw OnlineError.invalidInput("无效的 Bilibili 收藏夹")
        }
        var songs: [SongData] = []
        var seen = Set<String>()
        for page in 1...1000 {
            try Task.checkCancellation()
            let data = try await api("/x/v3/fav/resource/list", parameters: [
                "media_id": mediaID, "pn": String(page), "ps": "20", "order": "mtime", "platform": "web"
            ])
            let items = data["medias"] as? [[String: Any]] ?? []
            for item in items {
                guard BilibiliParsing.integer(item["type"]) == 2,
                      let bvid = item["bvid"] as? String ?? item["bv_id"] as? String,
                      let identity = try? BilibiliVideoIdentity(sourceID: bvid), seen.insert(identity.sourceID).inserted else { continue }
                let upper = item["upper"] as? [String: Any]
                songs.append(SongData(source: .bilibili, sourceID: identity.sourceID,
                                      title: BilibiliParsing.plainText(item["title"] as? String ?? ""),
                                      artist: upper?["name"] as? String ?? "", album: collection.title,
                                      duration: (item["duration"] as? NSNumber)?.doubleValue,
                                      artworkURL: BilibiliParsing.httpURL(item["cover"] as? String), pageURL: identity.pageURL))
            }
            if (data["has_more"] as? Bool) != true { return songs }
            guard !items.isEmpty else { throw OnlineError.invalidResponse }
        }
        throw OnlineError.unavailable("收藏夹分页超出限制")
    }

    public func collectionArtwork(in collection: OnlineCollection) async throws -> URL? {
        guard collection.source == .bilibili, let id = BilibiliParsing.positiveID(collection.sourceID) else {
            throw OnlineError.invalidInput("无效的 Bilibili 收藏夹")
        }
        // Android obtains folder metadata separately: list-all often omits the cover.
        let folder = try await api("/x/v3/fav/folder/info", parameters: ["media_id": id])
        if let cover = ArtworkURLNormalizer.normalized(folder["cover"] as? String) { return cover }
        let data = try await api("/x/v3/fav/resource/list", parameters: [
            "media_id": id, "pn": "1", "ps": "20", "order": "mtime", "platform": "web"
        ])
        let info = data["info"] as? [String: Any]
        let first = (data["medias"] as? [[String: Any]])?.first
        return ArtworkURLNormalizer.normalized(info?["cover"] as? String)
            ?? ArtworkURLNormalizer.normalized(first?["cover"] as? String)
    }

    public func collectionPage(in collection: OnlineCollection, cursor: String?) async throws -> OnlineCollectionPage {
        guard collection.source == .bilibili, let id = BilibiliParsing.positiveID(collection.sourceID),
              let page = Int(cursor ?? "1"), (1...1000).contains(page) else { throw OnlineError.invalidInput("无效的收藏夹页码") }
        let data = try await api("/x/v3/fav/resource/list", parameters: ["media_id": id, "pn": String(page), "ps": "20", "order": "mtime", "platform": "web"])
        let items = data["medias"] as? [[String: Any]] ?? []
        let songs = items.compactMap { item -> SongData? in
            guard BilibiliParsing.integer(item["type"]) == 2,
                  let bvid = item["bvid"] as? String ?? item["bv_id"] as? String,
                  let identity = try? BilibiliVideoIdentity(sourceID: bvid) else { return nil }
            let upper = item["upper"] as? [String: Any]
            return SongData(source: .bilibili, sourceID: identity.sourceID, title: BilibiliParsing.plainText(item["title"] as? String ?? ""),
                            artist: upper?["name"] as? String ?? "", album: collection.title,
                            duration: (item["duration"] as? NSNumber)?.doubleValue,
                            artworkURL: BilibiliParsing.httpURL(item["cover"] as? String), pageURL: identity.pageURL)
        }
        let more = data["has_more"] as? Bool == true
        if more && items.isEmpty { throw OnlineError.invalidResponse }
        return OnlineCollectionPage(songs: songs, nextCursor: more ? String(page + 1) : nil)
    }

    /// The protocol has no folder argument, so additions target the first user-created folder.
    /// Removal uses only folders returned by favoured=true, leaving unrelated subscriptions intact.
    public func setFavorite(_ song: SongData, favorite: Bool) async throws {
        let identity = try requireIdentity(song)
        let cookie = BilibiliParsing.cookies(try sessions.cookieHeader(for: .bilibili) ?? "")
        guard cookie["SESSDATA"]?.isEmpty == false, let csrf = cookie["bili_jct"], !csrf.isEmpty,
              let mid = BilibiliParsing.positiveID(cookie["DedeUserID"]) else { throw OnlineError.authenticationRequired }
        let data = try await video(identity)
        guard let aid = BilibiliParsing.positiveID(data["aid"]) else { throw OnlineError.invalidResponse }
        let folders = try await api("/x/v3/fav/folder/created/list-all", parameters: ["up_mid": mid, "rid": aid, "type": "2"])
        let list = folders["list"] as? [[String: Any]] ?? []
        let identifiers: [String]
        if favorite {
            guard let first = list.first, let id = BilibiliParsing.positiveID(first["id"]) else {
                throw OnlineError.unavailable("请先在 Bilibili 创建收藏夹")
            }
            identifiers = [id]
        } else {
            identifiers = list.filter { ($0["fav_state"] as? NSNumber)?.intValue == 1 }
                .compactMap { BilibiliParsing.positiveID($0["id"]) }
            if identifiers.isEmpty { return }
        }
        _ = try await api("/x/v3/fav/resource/deal", parameters: [
            "rid": aid, "type": "2", "add_media_ids": favorite ? identifiers.joined(separator: ",") : "",
            "del_media_ids": favorite ? "" : identifiers.joined(separator: ","), "csrf": csrf
        ], method: "POST")
    }

    public func beginQRLogin() async throws -> QRLoginTicket {
        let reply = try await request(path: "/x/passport-login/web/qrcode/generate", base: passportBase)
        let data = try validatedData(reply.root)
        guard let key = data["qrcode_key"] as? String, !key.isEmpty,
              let url = BilibiliParsing.httpURL(data["url"] as? String) else { throw OnlineError.invalidResponse }
        // Keep pre-login cookies transient and scoped to a single QR ticket.
        qrCookies = [key: reply.cookies]
        return QRLoginTicket(key: key, url: url)
    }

    public func pollQRLogin(_ ticket: QRLoginTicket) async throws -> QRLoginState {
        guard !ticket.key.isEmpty else { throw OnlineError.invalidInput("无效的二维码") }
        let reply = try await request(path: "/x/passport-login/web/qrcode/poll", base: passportBase,
                                      parameters: ["qrcode_key": ticket.key], extraCookies: qrCookies[ticket.key] ?? [:])
        let data = try validatedData(reply.root)
        guard let code = BilibiliParsing.integer(data["code"]) else { throw OnlineError.invalidResponse }
        var cookies = qrCookies[ticket.key] ?? [:]
        cookies.merge(reply.cookies) { _, new in new }
        qrCookies[ticket.key] = cookies
        switch code {
        case 86101: return .waiting
        case 86090: return .scanned
        case 86038:
            qrCookies.removeValue(forKey: ticket.key)
            return .expired
        case 0:
            // Auth response normally sets these cookies; its redirect URL is a documented fallback.
            cookies.merge(BilibiliParsing.loginURLCookies(data["url"] as? String)) { _, new in new }
            guard cookies["SESSDATA"]?.isEmpty == false, cookies["bili_jct"]?.isEmpty == false else {
                throw OnlineError.invalidResponse
            }
            try sessions.saveCookieHeader(BilibiliParsing.cookieHeader(cookies), for: .bilibili)
            qrCookies.removeValue(forKey: ticket.key)
            cachedMixin = nil
            Log.net.info("Bilibili QR login authorized")
            return .authorized
        default: throw OnlineError.unavailable("Bilibili 二维码状态异常（\(code)）")
        }
    }

    private func requireIdentity(_ song: SongData) throws -> BilibiliVideoIdentity {
        guard song.source == .bilibili else { throw OnlineError.invalidInput("歌曲不是 Bilibili 来源") }
        return try BilibiliVideoIdentity(sourceID: song.sourceID)
    }

    private func video(_ identity: BilibiliVideoIdentity) async throws -> [String: Any] {
        let parameters = identity.bvid.hasPrefix("av") ? ["aid": String(identity.bvid.dropFirst(2))] : ["bvid": identity.bvid]
        return try await api("/x/web-interface/wbi/view", parameters: parameters, signed: true)
    }

    private func folderPages(path: String, mid: String) async throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for page in 1...1000 {
            let data = try await api(path, parameters: ["up_mid": mid, "pn": String(page), "ps": "20", "platform": "web"])
            let list = data["list"] as? [[String: Any]] ?? []
            result += list
            let count = BilibiliParsing.integer(data["count"]) ?? result.count
            if result.count >= count || list.isEmpty { return result }
        }
        throw OnlineError.unavailable("收藏夹分页超出限制")
    }

    private func api(_ path: String, parameters: [String: String] = [:], signed: Bool = false,
                     method: String = "GET") async throws -> [String: Any] {
        let query = signed ? try await signedQuery(parameters) : BilibiliSigning.queryString(parameters)
        let reply = try await request(path: path, base: apiBase, query: query, method: method)
        return try validatedData(reply.root)
    }

    private func signedQuery(_ parameters: [String: String]) async throws -> String {
        let date = now()
        let key: String
        if let cachedMixin, (0..<600).contains(date.timeIntervalSince(cachedMixin.date)) {
            key = cachedMixin.key
        } else {
            try await ensureAnonymousCookies()
            let reply = try await request(path: "/x/web-interface/nav", base: apiBase)
            // Anonymous nav is code -101 but still contains valid wbi_img keys.
            let rootCode = BilibiliParsing.integer(reply.root["code"])
            guard rootCode == 0 || rootCode == -101,
                  let data = reply.root["data"] as? [String: Any], let image = data["wbi_img"] as? [String: Any],
                  let imageURL = image["img_url"] as? String, let subURL = image["sub_url"] as? String else {
                throw OnlineError.invalidResponse
            }
            key = try BilibiliSigning.mixinKey(imageURL: imageURL, subURL: subURL)
            cachedMixin = (key, date)
        }
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) else { throw OnlineError.invalidInput("Invalid clock") }
        return try BilibiliSigning.signedQuery(parameters: parameters, mixinKey: key, timestamp: Int64(seconds))
    }

    private func ensureAnonymousCookies() async throws {
        if try sessions.cookieHeader(for: .bilibili)?.isEmpty == false { return }
        if let anonymousCookiesDate, (0..<3600).contains(now().timeIntervalSince(anonymousCookiesDate)) { return }
        let reply = try await request(path: "/x/frontend/finger/spi", base: apiBase)
        let data = try validatedData(reply.root)
        var cookies = reply.cookies
        for (field, name) in [("b_3", "buvid3"), ("b_4", "buvid4"), ("buvid_fp", "buvid_fp")] {
            if let value = data[field] as? String, !value.isEmpty { cookies[name] = value }
        }
        anonymousCookies = cookies
        anonymousCookiesDate = now()
    }

    private struct Reply {
        let root: [String: Any]
        let cookies: [String: String]
    }

    private func request(path: String, base: URL, parameters: [String: String] = [:], query: String? = nil,
                         method: String = "GET", extraCookies: [String: String] = [:]) async throws -> Reply {
        try Task.checkCancellation()
        var components = URLComponents(url: base.appendingPathComponent(String(path.dropFirst())), resolvingAgainstBaseURL: false)
        let encoded = query ?? BilibiliSigning.queryString(parameters)
        if method == "GET", !encoded.isEmpty { components?.percentEncodedQuery = encoded }
        guard let url = components?.url else { throw OnlineError.invalidInput("Invalid Bilibili endpoint") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        let sessionCookies = try sessions.cookieHeader(for: .bilibili)
        var cookies = anonymousCookies
        cookies.merge(BilibiliParsing.cookies(sessionCookies ?? "")) { _, new in new }
        cookies.merge(extraCookies) { _, new in new }
        let header = BilibiliParsing.cookieHeader(cookies)
        if !header.isEmpty { request.setValue(header, forHTTPHeaderField: "Cookie") }
        if method == "POST" {
            request.httpBody = Data(encoded.utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        // Deliberately log only endpoint paths and status, never keys, queries or response bodies.
        Log.net.debug("Bilibili request: \(path, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard try sessions.cookieHeader(for: .bilibili) == sessionCookies else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw OnlineError.invalidResponse }
        Log.net.debug("Bilibili response: \(path, privacy: .public) status=\(http.statusCode)")
        guard (200..<300).contains(http.statusCode) else { throw OnlineError.http(http.statusCode) }
        guard data.count <= 16 * 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OnlineError.invalidResponse }
        return Reply(root: root, cookies: BilibiliParsing.responseCookies(http))
    }

    private func validatedData(_ root: [String: Any]) throws -> [String: Any] {
        guard let code = BilibiliParsing.integer(root["code"]) else { throw OnlineError.invalidResponse }
        guard code == 0 else {
            if code == -101 || code == -111 { throw OnlineError.authenticationRequired }
            // Avoid forwarding arbitrary server messages which may echo cookies or parameters.
            throw OnlineError.unavailable("Bilibili API 返回错误（\(code)）")
        }
        if root["data"] is NSNull || root["data"] == nil { return [:] }
        guard let data = root["data"] as? [String: Any] else { throw OnlineError.invalidResponse }
        return data
    }
}
