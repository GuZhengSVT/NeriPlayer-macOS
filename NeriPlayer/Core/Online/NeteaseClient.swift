// NeteaseClient.swift
// M5-T1/T2: encrypted async NetEase HTTP, normalized songs and QR authentication.
import Foundation

public actor NeteaseClient: OnlineMusicClient {
    public nonisolated let source: MusicSource = .netease
    private let session: URLSession
    // internal: 首页分区扩展（同模块其他文件）需要读取会话判断是否已登录。
    let sessions: OnlineSessionStore
    private let baseURL: URL
    private let pageSize = 30
    private let qrLogin: NeteaseQRLoginClient
    /// 音质偏好读取入口。默认 `.settings`：每次解析都重新读设置，用户改完立即生效。
    private let qualityProvider: AudioQualityProvider
    /// 仅测试注入：记录每一次音质请求的决策（level/encodeType）。
    /// eAPI 请求体是加密的，URLProtocol 层看不到明文，所以由客户端自己回调决策结果。
    private let requestObserver: (@Sendable (NeteaseAudioRequestPlan) -> Void)?
    private var playlistTrackIDs: [String: [String]] = [:]

    public init(
        session: URLSession = .shared,
        sessions: OnlineSessionStore = .shared,
        baseURL: URL = URL(string: "https://music.163.com") ?? URL(fileURLWithPath: "/"),
        quality: AudioQualityProvider = .settings
    ) {
        self.session = session
        self.sessions = sessions
        self.baseURL = baseURL
        self.qualityProvider = quality
        requestObserver = nil
        qrLogin = NeteaseQRLoginClient(session: session, sessions: sessions, baseURL: baseURL)
    }

    init(session: URLSession, sessions: OnlineSessionStore, baseURL: URL,
         deviceProvider: any NeteaseDeviceContextProviding,
         quality: AudioQualityProvider = .settings,
         requestObserver: (@Sendable (NeteaseAudioRequestPlan) -> Void)? = nil) {
        self.session = session; self.sessions = sessions; self.baseURL = baseURL
        self.qualityProvider = quality
        self.requestObserver = requestObserver
        qrLogin = NeteaseQRLoginClient(session: session, sessions: sessions, baseURL: baseURL, deviceProvider: deviceProvider)
    }

    public func search(query: String, page: Int) async throws -> [SongData] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        guard query.utf8.count <= 4096, page <= 10_000 else { throw OnlineError.invalidInput("搜索参数过大") }
        let payload: [String: Any] = ["s": query, "type": "1", "offset": String((max(1, page) - 1) * pageSize),
                                      "limit": String(pageSize), "total": "true"]
        let response: NeteaseSearchResponse = try await post("/eapi/cloudsearch/pc", payload: payload, eapi: true)
        return response.result?.songs?.compactMap(\.normalized) ?? []
    }

    /// IDs stay platform-native and never depend on transient playback URLs.
    public func songDetails(ids: [String]) async throws -> [SongData] {
        guard ids.count <= 1000 else { throw OnlineError.invalidInput("单次歌曲详情最多 1000 首") }
        guard !ids.isEmpty else { return [] }
        let numericIDs = try ids.map(Self.validID)
        let data = try JSONSerialization.data(withJSONObject: numericIDs.map { ["id": $0] })
        let response: NeteaseSongDetailResponse = try await post("/weapi/v3/song/detail", payload: [
            "c": String(bytes: data, encoding: .utf8) ?? "[]", "ids": try Self.jsonString(numericIDs)
        ])
        let songs = response.songs?.compactMap(\.normalized) ?? []
        let byID = Dictionary(songs.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        return numericIDs.compactMap { byID[String($0)] }
    }

    public func resolve(song: SongData) async throws -> ResolvedAudio {
        guard song.source == .netease else { throw OnlineError.invalidInput("歌曲来源不匹配") }
        let id = try Self.validID(song.sourceID)
        // 每次解析都重新读偏好：设置页改完立刻对下一次解析生效，且不把偏好缓存在构造时。
        let preferred = qualityProvider.preferences().netease
        // 只记住「在哪个档位拿到过试听片段」，用于把最终错误描述得更准确。
        // 刻意不保存试听 URL：既然不返回给播放链路，留着它只会让人误以为会被用到。
        var previewLevel: NeteaseQuality?
        // 降级链由冻结接口给出（jymaster → … → standard），与 Android 的
        // NETEASE_QUALITY_FALLBACK_ORDER 完全一致，这里只负责按序请求。
        for level in preferred.degradeChain {
            // 切歌/停止会取消解析；每个候选项开始前都检查一次，避免把整条链跑完。
            try Task.checkCancellation()
            let plan = Self.audioRequestPlan(for: level)
            requestObserver?(plan)
            let response: NeteaseAudioResponse = try await post("/eapi/song/enhance/player/url/v1", payload: [
                "ids": "[\(id)]", "level": plan.level, "encodeType": plan.encodeType
            ], eapi: true)
            try Task.checkCancellation()
            guard let item = response.data?.first(where: { $0.id?.value == String(id) }),
                  let url = Self.playbackURL(item) else { continue }
            // 试听片段只作最后的兜底：Android 拿到 freeTrialInfo 后仍会把更低的档位全部试完，
            // 只有全都拿不到完整音源时才回退到试听。这里保持一致 —— 但**不**自动播放试听：
            // 需求明确要求不能悄悄播 30 秒片段，所以「全链路只有试听」时宁可报错，
            // 并把「在哪个档位只拿到试听」写进错误信息，让用户知道该去登录/开会员。
            if item.freeTrialInfo != nil {
                previewLevel = previewLevel ?? level
                Log.net.info("网易云当前音质仅返回试听片段，继续尝试更低音质")
                continue
            }
            // 服务端可能在会员/版权不足时自行降级，记录实际档位与容器便于定位「选了无损却没拿到无损」。
            if let resolved = item.level?.value, resolved != plan.level {
                Log.net.info("网易云降级：\(plan.level, privacy: .public)→\(resolved, privacy: .public) \(item.type?.value ?? "", privacy: .public)")
            }
            return ResolvedAudio(song: song, url: url, headers: Self.playbackHeaders, expiresAt: Self.expiry(for: item))
        }
        if let previewLevel {
            throw OnlineError.unavailable("网易云在 \(previewLevel.rawValue) 及以下档位仅返回试听片段，可能需要登录或会员权限")
        }
        throw OnlineError.unavailable("网易云未返回完整可播放音源，可能需要登录或会员权限")
    }

    /// 一次音质请求的决策结果。`level` 即用户偏好的原值，`encodeType` 随档位变化。
    struct NeteaseAudioRequestPlan: Sendable, Equatable {
        let level: String
        let encodeType: String
    }

    /// 提取成纯函数以便单测：eAPI 请求体是加密的，测试无法从请求里读出 `level`，
    /// 只能直接验证这段决策逻辑。
    ///
    /// 为什么无损及以上必须用 `flac`：网易云的 `encodeType` 是**容器**选择，不是音质档位。
    /// 请求 `level=lossless&encodeType=aac` 会拿到降级后的 AAC，等于用户选了无损却听不到无损；
    /// Android 的 `getSongDownloadUrl` 对无损及以上固定传 `encodeType = "flac"`，此处对齐。
    static func audioRequestPlan(for quality: NeteaseQuality) -> NeteaseAudioRequestPlan {
        NeteaseAudioRequestPlan(
            level: quality.rawValue,
            encodeType: quality.requiresMembership ? "flac" : "aac"
        )
    }

    /// 响应条目是否含有可播放的完整 URL（`code` 为 200 或缺省，且 scheme/host 合法）。
    private static func playbackURL(_ item: NeteaseAudioResponse.Item) -> URL? {
        guard item.code == nil || item.code == 200, let string = item.url,
              let url = URL(string: string),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    /// `expi` 换算成到期时间；夹取到一天以内，避免服务端给出荒唐的长有效期。
    private static func expiry(for item: NeteaseAudioResponse.Item) -> Date? {
        item.expi.flatMap { $0 > 0 ? min($0, 86_400) : nil }.map { Date().addingTimeInterval($0) }
    }

    private static let playbackHeaders = ["Referer": "https://music.163.com/"]

    public func songs(in collection: OnlineCollection) async throws -> [SongData] {
        guard collection.source == .netease else { throw OnlineError.invalidInput("歌单来源不匹配") }
        let id = try Self.validID(collection.sourceID)
        if collection.kind == .album {
            let response: NeteaseAlbumResponse = try await post("/weapi/v1/album/\(id)", payload: [:])
            return response.songs?.compactMap(\.normalized) ?? []
        }
        let response: NeteasePlaylistDetailResponse = try await post("/weapi/v6/playlist/detail", payload: [
            "id": id, "n": 1000, "s": 0
        ])
        guard let playlist = response.playlist else { throw OnlineError.invalidResponse }
        let available = playlist.tracks?.compactMap(\.normalized) ?? []
        let ids = playlist.trackIds?.compactMap { $0.id?.value } ?? []
        guard !ids.isEmpty else { return available }
        // Playlist details can contain only the first page of tracks; fetch all IDs.
        var songs: [SongData] = []
        for start in stride(from: 0, to: ids.count, by: 500) {
            try Task.checkCancellation()
            songs += try await songDetails(ids: Array(ids[start..<min(start + 500, ids.count)]))
        }
        return songs
    }

    public func collections() async throws -> [OnlineCollection] {
        let account = try await account()
        var result: [OnlineCollection] = []
        for offset in stride(from: 0, to: 10_000, by: 100) {
            let response: NeteaseUserPlaylistsResponse = try await post("/weapi/user/playlist", payload: [
                "uid": try Self.validID(account.id), "limit": 100, "offset": offset
            ])
            let page = response.playlist ?? []
            result += page.compactMap { $0.normalizedCollection }
            if response.more != true || page.isEmpty { break }
        }
        return result
    }

    public func collectionArtwork(in collection: OnlineCollection) async throws -> URL? {
        guard collection.source == .netease, collection.kind != .album else { return collection.artworkURL }
        let id = try Self.validID(collection.sourceID)
        let response: NeteasePlaylistDetailResponse = try await post("/weapi/v6/playlist/detail", payload: ["id": id, "n": 1, "s": 0])
        return response.playlist?.normalizedCollection?.artworkURL
            ?? response.playlist?.tracks?.compactMap(\.normalized).first(where: { $0.artworkURL != nil })?.artworkURL
    }

    public func collectionPage(in collection: OnlineCollection, cursor: String?) async throws -> OnlineCollectionPage {
        guard collection.source == .netease else { throw OnlineError.invalidInput("歌单来源不匹配") }
        if collection.kind == .album { return OnlineCollectionPage(songs: try await songs(in: collection)) }
        let id = try Self.validID(collection.sourceID)
        let context = try sessions.cacheContext(for: .netease)
        let cacheKey = "\(context):\(collection.id)"
        let offset = cursor.flatMap(Int.init) ?? 0
        if cursor == nil {
            let response: NeteasePlaylistDetailResponse = try await post("/weapi/v6/playlist/detail", payload: ["id": id, "n": 100, "s": 0])
            guard let playlist = response.playlist else { throw OnlineError.invalidResponse }
            let ids = playlist.trackIds?.compactMap { $0.id?.value } ?? []
            if ids.isEmpty { return OnlineCollectionPage(songs: playlist.tracks?.compactMap(\.normalized) ?? []) }
            playlistTrackIDs[cacheKey] = ids
        }
        guard offset >= 0, let ids = playlistTrackIDs[cacheKey], offset < ids.count else { throw OnlineError.invalidResponse }
        let end = min(offset + 100, ids.count)
        let page = try await songDetails(ids: Array(ids[offset..<end]))
        if end == ids.count { playlistTrackIDs[cacheKey] = nil }
        return OnlineCollectionPage(songs: page, nextCursor: end < ids.count ? String(end) : nil)
    }

    public func recommendations() async throws -> [SongData] {
        try requireSession()
        let response: NeteaseRecommendationResponse = try await post("/weapi/v3/discovery/recommend/songs", payload: [:])
        return (response.data?.dailySongs ?? response.recommend ?? []).compactMap(\.normalized)
    }

    public func account() async throws -> OnlineAccount {
        try requireSession()
        let response: NeteaseAccountResponse = try await post("/weapi/w/nuser/account/get", payload: ["noCheckToken": true])
        guard let id = response.profile?.userId?.value ?? response.account?.id?.value else {
            throw OnlineError.authenticationRequired
        }
        return OnlineAccount(id: id, name: response.profile?.nickname ?? response.account?.userName ?? "网易云用户")
    }

    public func setFavorite(_ song: SongData, favorite: Bool) async throws {
        guard song.source == .netease else { throw OnlineError.invalidInput("歌曲来源不匹配") }
        try requireSession()
        let _: NeteaseStatusResponse = try await post("/weapi/radio/like", payload: [
            "trackId": try Self.validID(song.sourceID), "like": favorite, "time": 0, "alg": "itembased"
        ])
    }

    public func favoriteSongIDs() async throws -> [String] {
        let account = try await account()
        let response: NeteaseLikeListResponse = try await post("/weapi/song/like/get", payload: ["uid": try Self.validID(account.id)])
        return response.ids?.compactMap(\.value) ?? []
    }

    public func beginQRLogin() async throws -> QRLoginTicket {
        try await qrLogin.begin()
    }

    public func pollQRLogin(_ ticket: QRLoginTicket) async throws -> QRLoginState {
        try await qrLogin.poll(ticket)
    }

    public func importCookies(_ header: String) throws {
        guard Self.cookieValue("MUSIC_U", in: header) != nil else { throw OnlineError.invalidInput("Cookie 缺少 MUSIC_U") }
        try sessions.saveCookieHeader(header, for: .netease)
    }

    public func logout() throws { try sessions.clear(.netease) }

    private func requireSession() throws {
        guard let cookies = try sessions.cookieHeader(for: .netease), Self.cookieValue("MUSIC_U", in: cookies) != nil else {
            throw OnlineError.authenticationRequired
        }
    }

    // Keep HTTP, API status and session updates in one request transaction.
    // internal: 首页分区与目录搜索扩展复用同一套加密请求与会话维护。
    // swiftlint:disable:next cyclomatic_complexity
    func post<T: Decodable>(
        _ path: String,
        payload: [String: Any],
        allowedCodes: Set<Int> = [200],
        eapi: Bool = false,
        useSession: Bool = true
    ) async throws -> T {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
            throw OnlineError.invalidInput("无效网易云 API 地址")
        }
        if eapi, components.host == "music.163.com" { components.host = "interface.music.163.com" }
        components.path = path
        components.query = nil
        components.fragment = nil
        // 匿名回退（useSession=false）不带持久化会话，也不回写响应 Cookie，避免污染登录态。
        let cookies = try useSession ? sessions.cookieHeader(for: .netease) : nil
        components.queryItems = [URLQueryItem(name: "csrf_token", value: cookies.flatMap { Self.cookieValue("__csrf", in: $0) } ?? "")]
        guard let url = components.url else { throw OnlineError.invalidInput("无效请求地址") }
        var body = payload
        body["csrf_token"] = cookies.flatMap { Self.cookieValue("__csrf", in: $0) } ?? ""
        let encrypted = try eapi ? NeteaseCrypto.eAPI(path: path.replacingOccurrences(of: "/eapi/", with: "/api/"), payload: body)
            : NeteaseCrypto.weAPI(payload: body)
        let form = encrypted.sorted { $0.key < $1.key }.map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }.joined(separator: "&")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(form.utf8)
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        if let cookies, !cookies.isEmpty { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        Log.net.info("网易云请求：POST \(path, privacy: .public)")
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw OnlineError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw OnlineError.http(http.statusCode) }
            guard data.count <= 16 * 1024 * 1024 else { throw OnlineError.invalidResponse }
            let status = try JSONDecoder().decode(NeteaseStatusResponse.self, from: data)
            guard let code = status.code else { throw OnlineError.invalidResponse }
            if code == 301 || code == 302 { throw OnlineError.authenticationRequired }
            guard allowedCodes.contains(code) else { throw OnlineError.unavailable(status.message ?? "网易云 API 错误：\(code)") }
            if useSession {
                guard try sessions.cookieHeader(for: .netease) == cookies else { throw CancellationError() }
                try persistResponseCookies(http)
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OnlineError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as DecodingError {
            Log.net.error("网易云响应解码失败：\(String(describing: error), privacy: .private)")
            throw OnlineError.invalidResponse
        }
    }

    private func persistResponseCookies(_ response: HTTPURLResponse) throws {
        guard let url = response.url, let host = url.host,
              host == "music.163.com" || host.hasSuffix(".music.163.com") else { return }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String { headers[key] = String(describing: value) }
        }
        let incoming = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard !incoming.isEmpty else { return }
        var values = Self.cookiePairs(try sessions.cookieHeader(for: .netease) ?? "")
        for cookie in incoming {
            values[cookie.name] = cookie.expiresDate.map { $0 <= Date() } == true ? nil : cookie.value
        }
        let header = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        if header.isEmpty { try sessions.clear(.netease) } else { try sessions.saveCookieHeader(header, for: .netease) }
        Log.net.info("网易云会话 Cookie 已更新")
    }

    private static func cookiePairs(_ header: String) -> [String: String] {
        var values: [String: String] = [:]
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = String(parts[1])
        }
        return values
    }

    private static func cookieValue(_ name: String, in header: String) -> String? {
        let value = cookiePairs(header)[name]
        return value?.isEmpty == false ? value : nil
    }

    static func validID(_ string: String) throws -> Int64 {
        guard string.allSatisfy({ $0.isASCII && $0.isNumber }), let id = Int64(string), id > 0 else {
            throw OnlineError.invalidInput("网易云 ID 无效")
        }
        return id
    }

    static func jsonString(_ object: Any) throws -> String {
        String(bytes: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) ?? "[]"
    }

    static func formEncode(_ string: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
