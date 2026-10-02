// YouTubeMusicClient.swift
// M5: WEB_REMIX Innertube search/playlists/player, account-bound bootstrap and JSC signature solver.
// Behavioral reference: NeriPlayer Android (GPL-3.0-or-later); no PoToken or WebView bypass.
import Foundation

public actor YouTubeMusicClient: OnlineMusicClient {
    public nonisolated let source: MusicSource = .youtubeMusic
    private let sessions: OnlineSessionStore
    private let session: URLSession
    private let solver: YouTubeMusicSolver?
    private let diskCache: YouTubeMusicBootstrapCache
    /// 音质偏好读取入口。默认 `.settings`：每次解析都重新读设置，用户改完立即生效。
    private let qualityProvider: AudioQualityProvider
    private var memoryBootstrap: YouTubeMusicBootstrap?
    private var playerScripts: [URL: String] = [:]
    private let origin = "https://music.youtube.com"
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36"

    public init(sessionStore: OnlineSessionStore = .shared, session: URLSession = .shared,
                cacheURL: URL? = nil, solverAssets: YouTubeMusicSolverAssets? = nil,
                quality: AudioQualityProvider = .settings) {
        sessions = sessionStore; self.session = session
        solver = (solverAssets ?? YouTubeMusicSolverAssets.bundled()).map { YouTubeMusicSolver(assets: $0) }
        diskCache = YouTubeMusicBootstrapCache(url: cacheURL)
        self.qualityProvider = quality
    }
    public func importCookieHeader(_ value: String) throws { try sessions.saveCookieHeader(value, for: .youtubeMusic); memoryBootstrap = nil }
    public func clearCookies() throws { try sessions.clear(.youtubeMusic); memoryBootstrap = nil }

    public func search(query: String, page: Int) async throws -> [SongData] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 512, (1...80).contains(page) else { throw OnlineError.invalidInput("搜索参数无效") }
        let boot = try await bootstrap()
        var root = try await post("/youtubei/v1/search", payload: ["query": query, "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"], boot: boot)
        if page > 1 {
            for _ in 1..<page {
                guard let token = YouTubeMusicParser.continuation(root) else { return [] }
                root = try await post("/youtubei/v1/search", payload: ["continuation": token], boot: boot)
            }
        }
        return YouTubeMusicParser.songs(root)
    }
    public func resolve(song: SongData) async throws -> ResolvedAudio {
        guard song.source == .youtubeMusic, YouTubeMusicParser.validVideoID(song.sourceID) else { throw OnlineError.invalidInput("YouTube ID 无效") }
        let boot = try await bootstrap()
        let timestamp = try await signatureTimestamp(boot)
        let payload: [String: Any] = ["videoId": song.sourceID, "contentCheckOk": true, "racyCheckOk": true,
            "playbackContext": ["contentPlaybackContext": ["signatureTimestamp": timestamp, "html5Preference": "HTML5_PREF_WANTS",
                "referer": "\(origin)/watch?v=\(song.sourceID)"]]]
        let root = try await post("/youtubei/v1/player", payload: payload, boot: boot)
        guard let streaming = root["streamingData"] as? [String: Any] else {
            let status = (root["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "UNKNOWN"
            throw OnlineError.unavailable("YouTube Music 未返回可播放音源（\(status)），可能需要登录或额外挑战")
        }
        let formats = (streaming["adaptiveFormats"] as? [[String: Any]] ?? []) + (streaming["formats"] as? [[String: Any]] ?? [])
        // 每次解析都重新读偏好：设置页改完立刻对下一次解析生效，且不把偏好缓存在构造时。
        // 按偏好排序后再逐个求解：旧的「全部按码率降序取第一条」在用户选「低/中」时是错的
        // （会拿到远超偏好的码率）。排序是纯函数，求解失败仍会顺延到下一条候选。
        let preferred = qualityProvider.preferences().youtubeMusic
        let ordered = Self.orderedFormats(formats, preferred: preferred)
        for format in ordered {
            try Task.checkCancellation()
            if let url = try await playableURL(format, boot: boot) {
                // 只在真正降级时记一条日志：用户选了「高」却拿到 low 时能立刻看出是候选不足，
                // 而不是去怀疑选流逻辑。（候选顺序由纯函数 orderedFormats 决定并已单测覆盖。）
                let achieved = Self.inferredQuality(for: format)
                if achieved != preferred {
                    Log.net.info("YouTube Music 已降级：\(preferred.rawValue, privacy: .public)→\(achieved.rawValue, privacy: .public)")
                }
                let expires = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "expire" }?.value.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
                return ResolvedAudio(song: song, url: url, headers: ["User-Agent": userAgent, "Range": "bytes=0-"], expiresAt: expires)
            }
        }
        throw OnlineError.unavailable("YouTube Music 音源需要尚未支持的挑战或已不可用")
    }

    /// 把自适应流按偏好排序，返回候选顺序（越靠前越优先）。
    ///
    /// 规则（对齐 Android `orderCandidatesByQualityTier`）：
    ///   1. 顺着偏好自己的 `degradeChain` 从高到低找，链上**第一个有候选的档位**胜出，
    ///      同档内取码率最高的一条。`degradeChain` 只包含偏好及更低的档位，
    ///      所以「绝不选高于用户偏好的格式」由冻结接口的定义直接保证 ——
    ///      用户选「高」时 200 kbps（very_high）不会出现在候选里；
    ///   2. 全部候选都高于偏好（极端情况：视频只有 200 kbps 的流，用户却选了 low）时，
    ///      仍按「最接近偏好」的顺序返回它们：宁可给一条能播的，也不要报「没有可用音源」。
    static func orderedFormats(_ formats: [[String: Any]], preferred: YouTubeQuality) -> [[String: Any]] {
        let audio = formats.filter { ($0["mimeType"] as? String ?? "").hasPrefix("audio/") }
        let groups = Dictionary(grouping: audio) { inferredQuality(for: $0) }
        // 档位内按码率降序：同一档里优先取码率更高的那条（可能是不同容器/采样率）。
        func best(in quality: YouTubeQuality) -> [[String: Any]] {
            (groups[quality] ?? []).sorted { bitrate(of: $0) > bitrate(of: $1) }
        }
        let chain = preferred.degradeChain.flatMap(best(in:))
        if !chain.isEmpty { return chain }
        // 由低到高的下标即档位高低，用于挑出「比偏好更高、但最接近偏好」的那几档。
        let rank = { (quality: YouTubeQuality) in YouTubeQuality.ordered.firstIndex(of: quality) ?? 0 }
        return YouTubeQuality.ordered
            .filter { rank($0) > rank(preferred) }
            .flatMap(best(in:))
    }

    /// 单条格式的推断档位。YouTube 的 `bitrate` 是 bit/s，冻结接口按 kbps 归类，需换算。
    static func inferredQuality(for format: [String: Any]) -> YouTubeQuality {
        let bits = bitrate(of: format)
        return YouTubeQuality.infer(bitrateKbps: bits > 0 ? bits / 1000 : nil)
    }

    private static func bitrate(of format: [String: Any]) -> Int {
        // JSONSerialization 解出来的 JSON 数字是 NSNumber，走 NSNumber 而不是 `as? Int`
        // 可以同时容纳整数与浮点两种落盘形态；缺失/无法转换时按 0（未知）处理。
        (format["bitrate"] as? NSNumber)?.intValue ?? 0
    }

    public func songs(in collection: OnlineCollection) async throws -> [SongData] {
        guard collection.source == .youtubeMusic else { throw OnlineError.invalidInput("来源不匹配") }
        let boot = try await bootstrap()
        var root = try await post("/youtubei/v1/browse", payload: ["browseId": collection.sourceID], boot: boot)
        var songs = YouTubeMusicParser.songs(root)
        var seen = Set(songs.map(\.id)); var tokens = Set<String>()
        for _ in 0..<80 {
            guard let token = YouTubeMusicParser.continuation(root), tokens.insert(token).inserted else { return songs }
            root = try await post("/youtubei/v1/browse", payload: ["continuation": token], boot: boot)
            songs += YouTubeMusicParser.songs(root).filter { seen.insert($0.id).inserted }
        }
        throw OnlineError.unavailable("YouTube Music 歌单超出分页限制")
    }
    public func collections() async throws -> [OnlineCollection] {
        let boot = try await authenticatedBootstrap()
        return YouTubeMusicParser.collections(try await post("/youtubei/v1/browse", payload: ["browseId": "FEmusic_liked_playlists"], boot: boot))
    }
    public func collectionArtwork(in collection: OnlineCollection) async throws -> URL? {
        let boot = try await bootstrap()
        let root = try await post("/youtubei/v1/browse", payload: ["browseId": collection.sourceID], boot: boot)
        return YouTubeMusicParser.songs(root).first(where: { $0.artworkURL != nil })?.artworkURL
    }
    public func collectionPage(in collection: OnlineCollection, cursor: String?) async throws -> OnlineCollectionPage {
        guard collection.source == .youtubeMusic else { throw OnlineError.invalidInput("来源不匹配") }
        let boot = try await bootstrap()
        let payload = cursor.map { ["continuation": $0] } ?? ["browseId": collection.sourceID]
        let root = try await post("/youtubei/v1/browse", payload: payload, boot: boot)
        return OnlineCollectionPage(songs: YouTubeMusicParser.songs(root), nextCursor: YouTubeMusicParser.continuation(root))
    }
    public func recommendations() async throws -> [SongData] {
        let boot = try await bootstrap()
        return YouTubeMusicParser.songs(try await post("/youtubei/v1/browse", payload: ["browseId": "FEmusic_home"], boot: boot))
    }
    public func account() async throws -> OnlineAccount {
        let boot = try await authenticatedBootstrap()
        let root = try await post("/youtubei/v1/account/account_menu", payload: [:], boot: boot)
        guard let account = YouTubeMusicParser.account(root) else { throw OnlineError.authenticationRequired }
        return account
    }
    private func authenticatedBootstrap() async throws -> YouTubeMusicBootstrap {
        let boot = try await bootstrap()
        guard boot.loggedIn else { throw OnlineError.authenticationRequired }
        return boot
    }
    // internal: 首页 shelf 与目录搜索扩展复用同一份 Innertube 引导与请求封装。
    func bootstrap() async throws -> YouTubeMusicBootstrap {
        let cookie = try sessions.cookieHeader(for: .youtubeMusic)
        let fingerprint = YouTubeMusicCookies.fingerprint(cookie)
        if let cached = memoryBootstrap, cached.usable(fingerprint: fingerprint, now: Date()) { return cached }
        if let cached = diskCache.load(fingerprint: fingerprint, now: Date()) { memoryBootstrap = cached; return cached }
        guard let url = URL(string: origin + "/") else { throw OnlineError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN, en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        Log.net.info("YouTube Music bootstrap 请求")
        let (data, _) = try await OnlineHTTP.request(request, session: session)
        guard data.count <= 8 * 1024 * 1024 else { throw OnlineError.invalidResponse }
        guard let html = String(bytes: data, encoding: .utf8) else { throw OnlineError.invalidResponse }
        guard YouTubeMusicCookies.fingerprint(try sessions.cookieHeader(for: .youtubeMusic)) == fingerprint else { throw CancellationError() }
        let parsed = try YouTubeMusicBootstrap.parse(html: html, fingerprint: fingerprint, now: Date())
        memoryBootstrap = parsed; diskCache.save(parsed)
        return parsed
    }
    func post(_ path: String, payload: [String: Any], boot: YouTubeMusicBootstrap) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard var components = URLComponents(string: origin + path) else { throw OnlineError.invalidResponse }
        components.queryItems = [URLQueryItem(name: "prettyPrint", value: "false"), URLQueryItem(name: "key", value: boot.apiKey)]
        guard let url = components.url else { throw OnlineError.invalidResponse }
        var body: [String: Any] = ["context": ["client": ["clientName": "WEB_REMIX", "clientVersion": boot.clientVersion,
                                                          "hl": "zh-CN", "gl": "JP", "visitorData": boot.visitorData, "platform": "DESKTOP"],
                                               "user": ["lockedSafetyMode": false], "request": ["internalExperimentFlags": []]]]
        payload.forEach { body[$0.key] = $0.value }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpShouldHandleCookies = false
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(boot.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(boot.visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        request.setValue(boot.sessionIndex, forHTTPHeaderField: "X-Goog-AuthUser")
        let cookie = try sessions.cookieHeader(for: .youtubeMusic)
        guard YouTubeMusicCookies.fingerprint(cookie) == boot.authFingerprint else { throw CancellationError() }
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(YouTubeMusicCookies.authorization(cookie: cookie, origin: origin, userSessionID: boot.userSessionID, now: Date()),
                         forHTTPHeaderField: "Authorization")
        Log.net.info("YouTube Music 请求：\(path, privacy: .public)")
        let (data, _) = try await OnlineHTTP.request(request, session: session)
        guard YouTubeMusicCookies.fingerprint(try sessions.cookieHeader(for: .youtubeMusic)) == boot.authFingerprint else { throw CancellationError() }
        guard data.count <= 16 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OnlineError.invalidResponse }
        if root["error"] != nil { throw OnlineError.unavailable("YouTube Music API 拒绝请求") }
        return root
    }
    private func signatureTimestamp(_ boot: YouTubeMusicBootstrap) async throws -> Int {
        if let timestamp = boot.signatureTimestamp { return timestamp }
        guard let url = boot.playerScriptURL, url.scheme == "https", let host = url.host,
              host == "youtube.com" || host.hasSuffix(".youtube.com") else { throw OnlineError.invalidResponse }
        var request = URLRequest(url: url); request.httpShouldHandleCookies = false
        let (data, _) = try await OnlineHTTP.request(request, session: session)
        guard data.count <= 8 * 1024 * 1024, let script = String(bytes: data, encoding: .utf8) else { throw OnlineError.invalidResponse }
        playerScripts = [url: script]
        let regex = try NSRegularExpression(pattern: #"(?:signatureTimestamp|sts)\s*:\s*(\d{5})"#)
        guard let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let range = Range(match.range(at: 1), in: script), let timestamp = Int(script[range]) else { throw OnlineError.invalidResponse }
        memoryBootstrap?.signatureTimestamp = timestamp
        return timestamp
    }

    private func playableURL(_ format: [String: Any], boot: YouTubeMusicBootstrap) async throws -> URL? {
        let cipher = format["signatureCipher"] as? String ?? format["cipher"] as? String ?? ""
        let parts = URLComponents(string: "https://invalid/?" + cipher)
        guard let base = format["url"] as? String ?? parts?.queryItems?.first(where: { $0.name == "url" })?.value,
              var output = URLComponents(string: base), output.scheme == "https", let host = output.host,
              host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") else { return nil }
        var query = output.queryItems ?? []
        let encrypted = parts?.queryItems?.first(where: { $0.name == "s" })?.value
        let throttle = query.first(where: { $0.name == "n" })?.value
        if encrypted != nil || throttle != nil {
            guard let solver, let playerURL = boot.playerScriptURL, playerURL.scheme == "https", let host = playerURL.host,
                  host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
            let script: String
            if let cached = playerScripts[playerURL] { script = cached } else {
                var request = URLRequest(url: playerURL); request.httpShouldHandleCookies = false
                let (data, _) = try await OnlineHTTP.request(request, session: session)
                guard data.count <= 8 * 1024 * 1024 else { throw OnlineError.invalidResponse }
                guard let javascript = String(bytes: data, encoding: .utf8) else { throw OnlineError.invalidResponse }
                script = javascript; playerScripts = [playerURL: script]
            }
            let solved = try solver.solve(signature: encrypted, throttling: throttle, playerJavaScript: script)
            if let signature = solved.signature {
                let name = parts?.queryItems?.first(where: { $0.name == "sp" })?.value ?? "signature"
                query.removeAll { $0.name == name }; query.append(URLQueryItem(name: name, value: signature))
            }
            if let n = solved.throttling { query.removeAll { $0.name == "n" }; query.append(URLQueryItem(name: "n", value: n)) }
        }
        output.queryItems = query
        return output.url
    }
}
