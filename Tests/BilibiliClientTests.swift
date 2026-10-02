// BilibiliClientTests.swift
// M5-T3: mocked WBI search, multipart playback, favorite folders and QR sessions.
// Compact JSON fixtures mirror remote payloads verbatim.
// swiftlint:disable line_length
import Foundation
import XCTest
@testable import NeriPlayer

final class BilibiliClientTests: XCTestCase {
    private let bvid = "BV1xx411c7mD"
    private let nav = #"{"code":-101,"data":{"wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"}}}"#

    func testKnownWBIKeyAndSignatureVector() throws {
        let key = try BilibiliSigning.mixinKey(
            imageURL: "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
            subURL: "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png")
        XCTAssertEqual(key, "ea1db124af3c7062474693fa704f4ff8")
        let query = try BilibiliSigning.signedQuery(parameters: ["foo": "114", "bar": "514", "baz": "1919810"],
                                                    mixinKey: key, timestamp: 1_702_204_169)
        XCTAssertEqual(query, "bar=514&baz=1919810&foo=114&wts=1702204169&w_rid=6149fdadf571698ca7e6a567265cd0ee")
    }

    func testSigningEscapesAndFiltersWithoutDoubleEncoding() throws {
        let query = try BilibiliSigning.signedQuery(parameters: ["keyword": "a b+中文!'()*", "w_rid": "discard"],
                                                    mixinKey: String(repeating: "a", count: 32), timestamp: 1)
        XCTAssertTrue(query.hasPrefix("keyword=a%20b%2B%E4%B8%AD%E6%96%87&wts=1&w_rid="))
        XCTAssertFalse(query.contains("discard"))
    }

    func testIdentityDefaultsAndRejectsMissingOrMalformedPage() throws {
        XCTAssertEqual(try BilibiliVideoIdentity(sourceID: bvid).sourceID, bvid + ":1")
        XCTAssertEqual(try BilibiliVideoIdentity(sourceID: bvid + ":2").page, 2)
        for value in ["invalid", bvid + ":0", bvid + ":-1", bvid + ":", bvid + ":2:3", bvid + ":99999999999999999999"] {
            XCTAssertThrowsError(try BilibiliVideoIdentity(sourceID: value))
        }
    }

    func testAnonymousSearchUsesFingerprintAndLoggedOutNavKeys() async throws {
        let fixture = try BiliHTTPFixture()
        let anonymousNav = nav
        fixture.handler = { request in
            switch request.url?.path {
            case "/x/frontend/finger/spi": return .json(#"{"code":0,"data":{"b_3":"anonymous","b_4":"fingerprint"}}"#)
            case "/x/web-interface/nav": return .json(anonymousNav)
            case "/x/web-interface/wbi/search/type":
                XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("buvid3=anonymous") == true)
                let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(items.first { $0.name == "keyword" }?.value, "音乐 + test")
                XCTAssertEqual(items.first { $0.name == "page" }?.value, "2")
                XCTAssertEqual(items.first { $0.name == "w_rid" }?.value?.count, 32)
                return .json(#"{"code":0,"data":{"result":[{"type":"video","bvid":"BV1xx411c7mD","title":"<em class=\"keyword\">Music</em> &amp; Test","author":"Uploader","duration":"01:02:03","pic":"//img.example/cover.png"},{"type":"bangumi","title":"skip"}]}}"#)
            default: throw OnlineError.invalidResponse
            }
        }
        let client = fixture.client()
        let songs = try await client.search(query: "音乐 + test", page: 2)
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs.first?.sourceID, bvid + ":1")
        XCTAssertEqual(songs.first?.title, "Music & Test")
        XCTAssertEqual(songs.first?.duration, 3723)
        XCTAssertEqual(songs.first?.artworkURL?.scheme, "https")
        _ = try await client.search(query: "音乐 + test", page: 2)
        XCTAssertEqual(fixture.requests.filter { $0.url?.path == "/x/web-interface/nav" }.count, 1)
    }

    func testResolveUsesExactSecondPageAndNeverSendsCookiesToCDN() async throws {
        let fixture = try BiliHTTPFixture()
        try fixture.sessions.saveCookieHeader("SESSDATA=secret; bili_jct=csrf; DedeUserID=123", for: .bilibili)
        let anonymousNav = nav
        fixture.handler = { request in
            switch request.url?.path {
            case "/x/web-interface/nav": return .json(anonymousNav)
            case "/x/web-interface/wbi/view": return .json(Self.video)
            case "/x/player/wbi/playurl":
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(query.first { $0.name == "cid" }?.value, "222")
                return .json(#"{"code":0,"data":{"dash":{"audio":[{"bandwidth":64000,"base_url":"https://cdn.example/low.m4a"},{"bandwidth":192000,"baseUrl":"https://cdn.example/high.m4a?deadline=2000000000"}]}}}"#)
            default: throw OnlineError.invalidResponse
            }
        }
        let song = SongData(source: .bilibili, sourceID: bvid + ":2", title: "Second")
        let resolved = try await fixture.client().resolve(song: song)
        XCTAssertEqual(resolved.url.lastPathComponent, "high.m4a")
        XCTAssertEqual(resolved.song.sourceID, bvid + ":2")
        XCTAssertEqual(resolved.song.duration, 42)
        XCTAssertTrue(resolved.headers["Referer"]?.contains("p=2") == true)
        XCTAssertNil(resolved.headers["Cookie"])
        XCTAssertEqual(resolved.expiresAt?.timeIntervalSince1970, 2_000_000_000)
    }

    /// 问题 2 的关键：playurl 必须带 gaia_source=view-card 与 otype=json，否则 B 站风控只回 v_voucher。
    func testResolveSendsGaiaSourceAndJsonTypeOnFirstPlayurlRequest() async throws {
        let fixture = try BiliHTTPFixture()
        try fixture.sessions.saveCookieHeader("SESSDATA=test", for: .bilibili)
        let anonymousNav = nav
        fixture.handler = { request in
            switch request.url?.path {
            case "/x/web-interface/nav": return .json(anonymousNav)
            case "/x/web-interface/wbi/view": return .json(Self.video)
            case "/x/player/wbi/playurl":
                return .json(#"{"code":0,"data":{"dash":{"audio":[{"bandwidth":192000,"baseUrl":"https://cdn.example/high.m4a"}]}}}"#)
            default: throw OnlineError.invalidResponse
            }
        }
        _ = try await fixture.client().resolve(song: SongData(source: .bilibili, sourceID: bvid + ":2", title: "Second"))
        let playurl = fixture.requests.filter { $0.url?.path == "/x/player/wbi/playurl" }
        XCTAssertEqual(playurl.count, 1, "有音轨时不应重试")
        let items = try Self.query(of: try XCTUnwrap(playurl.first))
        XCTAssertEqual(items.first { $0.name == "gaia_source" }?.value, "view-card")
        XCTAssertEqual(items.first { $0.name == "otype" }?.value, "json")
        XCTAssertEqual(items.first { $0.name == "platform" }?.value, "pc")
        XCTAssertEqual(items.first { $0.name == "fnval" }?.value, "272")
        XCTAssertEqual(items.first { $0.name == "cid" }?.value, "222")
    }

    /// 只有 v_voucher 的风控响应：DASH 重试 3 次后必须再走 html5 渐进式回退拿到 durl。
    func testRiskControlResponseRetriesThenFallsBackToHtml5Progressive() async throws {
        let fixture = try BiliHTTPFixture()
        try fixture.sessions.saveCookieHeader("SESSDATA=test", for: .bilibili)
        let anonymousNav = nav
        fixture.handler = { request in
            switch request.url?.path {
            case "/x/web-interface/nav": return .json(anonymousNav)
            case "/x/web-interface/wbi/view": return .json(Self.video)
            case "/x/player/wbi/playurl":
                let items = try URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard items.first { $0.name == "platform" }?.value == "html5" else {
                    return .json(#"{"code":0,"message":"OK","data":{"v_voucher":"risk-control-ticket"}}"#)
                }
                return .json(#"{"code":0,"data":{"durl":[{"url":"https://cdn.example/progressive.mp4?deadline=2000000000"}]}}"#)
            default: throw OnlineError.invalidResponse
            }
        }
        let resolved = try await fixture.client().resolve(song: SongData(source: .bilibili, sourceID: bvid + ":2", title: "Second"))
        XCTAssertEqual(resolved.url.lastPathComponent, "progressive.mp4")
        XCTAssertNil(resolved.headers["Cookie"], "会话 Cookie 不能泄漏给 CDN")
        XCTAssertEqual(resolved.expiresAt?.timeIntervalSince1970, 2_000_000_000)
        let playurl = fixture.requests.filter { $0.url?.path == "/x/player/wbi/playurl" }
        XCTAssertEqual(playurl.count, 4, "3 次 DASH 重试 + 1 次 html5 回退")
        // 每一次都重新签名并带上 gaia_source；复用缓存的签名串会让重试失去意义。
        for request in playurl {
            let items = try Self.query(of: request)
            XCTAssertEqual(items.first { $0.name == "gaia_source" }?.value, "view-card")
            XCTAssertEqual(items.first { $0.name == "w_rid" }?.value?.count, 32)
        }
        let fallback = try Self.query(of: try XCTUnwrap(playurl.last))
        XCTAssertEqual(fallback.first { $0.name == "fnval" }?.value, "0")
        XCTAssertEqual(fallback.first { $0.name == "fnver" }?.value, "0")
        XCTAssertEqual(fallback.first { $0.name == "platform" }?.value, "html5")
        XCTAssertEqual(fallback.first { $0.name == "high_quality" }?.value, "1")
    }

    /// 问题 3：同一份 DASH 候选按用户偏好选轨，没有该档位时降级而不是报错。
    func testSelectionHonorsPreferenceAcrossBitrates() async throws {
        let fixture = try BiliHTTPFixture()
        try fixture.sessions.saveCookieHeader("SESSDATA=test", for: .bilibili)
        let anonymousNav = nav
        fixture.handler = { request in
            switch request.url?.path {
            case "/x/web-interface/nav": return .json(anonymousNav)
            case "/x/web-interface/wbi/view": return .json(Self.video)
            case "/x/player/wbi/playurl": return .json(Self.bitrateTracks)
            default: throw OnlineError.invalidResponse
            }
        }
        let song = SongData(source: .bilibili, sourceID: bvid + ":2", title: "Second")
        let low = try await fixture.client(bilibiliQuality: .low).resolve(song: song)
        XCTAssertEqual(low.url.lastPathComponent, "low64.m4a")
        let high = try await fixture.client(bilibiliQuality: .high).resolve(song: song)
        XCTAssertEqual(high.url.lastPathComponent, "high192.m4a")
        // 没有 flac 时 hires 退到最高可用，而不是失败。
        let hires = try await fixture.client(bilibiliQuality: .hires).resolve(song: song)
        XCTAssertEqual(hires.url.lastPathComponent, "high192.m4a")
    }

    /// 偏好 dolby 时命中带 dolby 标签的音轨，即使它旁边有码率更高的普通轨。
    func testDolbyPreferenceSelectsDolbyTrack() async throws {
        let fixture = try BiliHTTPFixture()
        try fixture.sessions.saveCookieHeader("SESSDATA=test", for: .bilibili)
        let anonymousNav = nav
        fixture.handler = { request in
            switch request.url?.path {
            case "/x/web-interface/nav": return .json(anonymousNav)
            case "/x/web-interface/wbi/view": return .json(Self.video)
            case "/x/player/wbi/playurl": return .json(Self.dolbyTracks)
            default: throw OnlineError.invalidResponse
            }
        }
        let resolved = try await fixture.client(bilibiliQuality: .dolby)
            .resolve(song: SongData(source: .bilibili, sourceID: bvid + ":2", title: "Second"))
        XCTAssertEqual(resolved.url.lastPathComponent, "dolby.m4s")
    }

    func testUnknownPageDoesNotFallBackToPageOne() async throws {
        let fixture = try BiliHTTPFixture()
        try fixture.sessions.saveCookieHeader("SESSDATA=test", for: .bilibili)
        let anonymousNav = nav
        fixture.handler = { request in
            if request.url?.path == "/x/web-interface/nav" { return .json(anonymousNav) }
            return .json(Self.video)
        }
        do {
            _ = try await fixture.client().resolve(song: SongData(source: .bilibili, sourceID: bvid + ":3", title: "Missing"))
            XCTFail("Missing P3 must fail")
        } catch { XCTAssertTrue(error is OnlineError) }
        XCTAssertFalse(fixture.requests.contains { $0.url?.path == "/x/player/wbi/playurl" })
    }

    func testFavoritesReadEveryPageAndFilterNonVideoMedia() async throws {
        let fixture = try BiliHTTPFixture()
        fixture.handler = { request in
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.first(where: { $0.name == "pn" })?.value == "1" {
                return .json(#"{"code":0,"data":{"has_more":true,"medias":[{"type":2,"bvid":"BV1xx411c7mD","title":"First","duration":30,"upper":{"name":"UP"}},{"type":12,"title":"audio"}]}}"#)
            }
            return .json(#"{"code":0,"data":{"has_more":false,"medias":[{"type":2,"bv_id":"BV1Q541167Qg","title":"Second","duration":40}]}}"#)
        }
        let songs = try await fixture.client().songs(in: OnlineCollection(source: .bilibili, sourceID: "55", title: "Favorites", kind: .favorites))
        XCTAssertEqual(songs.map(\.title), ["First", "Second"])
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testCollectionsMergeCreatedAndSubscribedWithoutSeasons() async throws {
        let fixture = try BiliHTTPFixture()
        try fixture.sessions.saveCookieHeader("SESSDATA=secret", for: .bilibili)
        fixture.handler = { request in
            switch request.url?.path {
            case "/x/web-interface/nav": return .json(#"{"code":0,"data":{"isLogin":true,"mid":123,"uname":"User"}}"#)
            case "/x/v3/fav/folder/created/list-all": return .json(#"{"code":0,"data":{"count":1,"list":[{"id":1,"title":"Mine"}]}}"#)
            case "/x/v3/fav/folder/collected/list": return .json(#"{"code":0,"data":{"count":2,"list":[{"id":2,"type":11,"title":"Subscribed"},{"id":3,"type":21,"title":"Season"}]}}"#)
            default: throw OnlineError.invalidResponse
            }
        }
        let collections = try await fixture.client().collections()
        XCTAssertEqual(collections.map(\.title), ["Mine", "Subscribed"])
        XCTAssertEqual(collections.first?.kind, .favorites)
    }

    func testFolderArtworkUsesMetadataEndpointWhenListOmitsCover() async throws {
        let fixture = try BiliHTTPFixture()
        fixture.handler = { request in
            XCTAssertEqual(request.url?.path, "/x/v3/fav/folder/info")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "media_id" }?.value, "55")
            return .json(#"{"code":0,"data":{"cover":"http://i0.hdslb.com/bfs/archive/cover.jpg"}}"#)
        }
        let cover = try await fixture.client().collectionArtwork(in: OnlineCollection(source: .bilibili, sourceID: "55", title: "Favorites", kind: .favorites))
        XCTAssertEqual(cover?.absoluteString, "https://i0.hdslb.com/bfs/archive/cover.jpg")
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testQRMapsStatesAndCommitsCookiesOnlyWhenAuthorized() async throws {
        let fixture = try BiliHTTPFixture()
        let codes = BiliTestQueue([86101, 86090, 0])
        fixture.handler = { request in
            if request.url?.path.hasSuffix("generate") == true {
                return .json(#"{"code":0,"data":{"qrcode_key":"ticket-secret","url":"https://passport.bilibili.com/qrcode/h5/login?key=ticket-secret"}}"#)
            }
            let code = codes.next()
            let redirect = code == 0 ? ",\"url\":\"https://passport.bilibili.com/login?SESSDATA=session%3Dtoken&bili_jct=csrf-token&DedeUserID=123\"" : ""
            return .json("{\"code\":0,\"data\":{\"code\":\(code)\(redirect)}}")
        }
        let client = fixture.client()
        let ticket = try await client.beginQRLogin()
        let waiting = try await client.pollQRLogin(ticket)
        XCTAssertEqual(waiting, .waiting)
        XCTAssertNil(try fixture.sessions.cookieHeader(for: .bilibili))
        let scanned = try await client.pollQRLogin(ticket)
        XCTAssertEqual(scanned, .scanned)
        let authorized = try await client.pollQRLogin(ticket)
        XCTAssertEqual(authorized, .authorized)
        let cookies = BilibiliParsing.cookies(try XCTUnwrap(fixture.sessions.cookieHeader(for: .bilibili)))
        XCTAssertEqual(cookies["SESSDATA"], "session=token")
        XCTAssertEqual(cookies["bili_jct"], "csrf-token")
    }

    func testMalformedHTTPAndAPIErrorsAreVisible() async throws {
        let fixture = try BiliHTTPFixture()
        fixture.handler = { _ in .json("{}", status: 503) }
        do {
            _ = try await fixture.client().beginQRLogin()
            XCTFail("HTTP failure must surface")
        } catch { XCTAssertEqual(error as? OnlineError, .http(503)) }
        fixture.handler = { _ in .json(#"{"code":0,"data":{}}"#) }
        do {
            _ = try await fixture.client().beginQRLogin()
            XCTFail("Malformed QR response must surface")
        } catch { XCTAssertEqual(error as? OnlineError, .invalidResponse) }
    }

    func testMediaParserSupportsBackupsAndRejectsMultiFragmentProgressive() {
        let audio: [String: Any] = ["dash": ["audio": [["base_url": "javascript:bad", "backup_url": ["https://cdn.example/backup.m4a"]]]]]
        XCTAssertEqual(BilibiliParsing.audioURL(audio)?.lastPathComponent, "backup.m4a")
        XCTAssertNil(BilibiliParsing.audioURL(["durl": [["url": "https://cdn.example/one"], ["url": "https://cdn.example/two"]]]))
        XCTAssertNil(BilibiliParsing.duration("x:03"))
        XCTAssertEqual(BilibiliParsing.plainText("&amp;lt; &#x97F3;"), "&lt; 音")
        XCTAssertEqual(BilibiliParsing.partMetadata("02. Song - Artist", fallbackArtist: "UP").artist, "Artist")
    }

    /// 解析请求 URL 的查询项；断言风控参数是否真的发出去了。
    /// 刻意做成 static：handler 是 @Sendable 闭包，实例方法会让闭包隐式捕获非 Sendable 的 XCTestCase。
    private static func query(of request: URLRequest) throws -> [URLQueryItem] {
        URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    private static let video = #"{"code":0,"data":{"aid":123,"bvid":"BV1xx411c7mD","title":"Video","owner":{"name":"UP"},"pages":[{"page":1,"cid":111,"part":"First","duration":20},{"page":2,"cid":222,"part":"Second","duration":42}]}}"#
    /// 64/128/192 kbps 三条普通音轨，用于验证选轨偏好与降级。
    private static let bitrateTracks = #"{"code":0,"data":{"dash":{"audio":[{"bandwidth":64000,"baseUrl":"https://cdn.example/low64.m4a"},{"bandwidth":128000,"baseUrl":"https://cdn.example/medium128.m4a"},{"bandwidth":192000,"baseUrl":"https://cdn.example/high192.m4a"}]}}}"#
    /// 杜比轨旁边有一条码率更高的普通轨时，只有标签语义能把它挑出来。
    private static let dolbyTracks = #"{"code":0,"data":{"dash":{"audio":[{"bandwidth":800000,"baseUrl":"https://cdn.example/normal.m4a"}],"dolby":{"audio":[{"bandwidth":448000,"baseUrl":"https://cdn.example/dolby.m4s"}]}}}}"#
}

private final class BiliMemoryCredentials: OnlineCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func write(_ data: Data, account: String) throws { lock.lock(); defer { lock.unlock() }; values[account] = data }
    func remove(account: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
}

private final class BiliTestQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int]
    init(_ values: [Int]) { self.values = values }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; return values.isEmpty ? 86101 : values.removeFirst() }
}

private final class BiliHTTPFixture: @unchecked Sendable {
    struct Response {
        let body: Data
        let status: Int
        static func json(_ value: String, status: Int = 200) -> Response { Response(body: Data(value.utf8), status: status) }
    }
    typealias Handler = @Sendable (URLRequest) throws -> Response
    let base: URL
    let sessions = OnlineSessionStore(credentials: BiliMemoryCredentials())
    let session: URLSession
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var handlerValue: Handler?
    var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return handlerValue }
        set { lock.lock(); defer { lock.unlock() }; handlerValue = newValue }
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    init() throws {
        base = try XCTUnwrap(URL(string: "https://bili-\(UUID().uuidString.lowercased()).invalid"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BiliMockProtocol.self]
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
        BiliMockProtocol.register(self)
    }
    deinit { session.invalidateAndCancel(); BiliMockProtocol.unregister(base.host ?? "") }
    func client() -> BilibiliClient {
        client(bilibiliQuality: .high)
    }
    /// 注入固定音质偏好：测试不该读写真实 UserDefaults，也不该受开发者本机设置影响。
    func client(bilibiliQuality: BilibiliQuality) -> BilibiliClient {
        BilibiliClient(session: session, sessions: sessions, apiBase: base, passportBase: base,
                       quality: .fixed(AudioQualityPreferences(bilibili: bilibiliQuality)),
                       now: { Date(timeIntervalSince1970: 1_702_204_169) })
    }
    func handle(_ request: URLRequest) throws -> Response {
        lock.lock(); recorded.append(request); let handler = handlerValue; lock.unlock()
        guard let handler else { throw OnlineError.invalidResponse }
        return try handler(request)
    }
}

private final class BiliMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fixtures: [String: BiliHTTPFixture] = [:]
    static func register(_ fixture: BiliHTTPFixture) { lock.lock(); defer { lock.unlock() }; fixtures[fixture.base.host ?? ""] = fixture }
    static func unregister(_ host: String) { lock.lock(); defer { lock.unlock() }; fixtures.removeValue(forKey: host) }
    override static func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock(); let fixture = Self.fixtures[request.url?.host ?? ""]; Self.lock.unlock()
            guard let fixture, let url = request.url else { throw OnlineError.invalidResponse }
            let result = try fixture.handle(request)
            guard let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"]) else { throw OnlineError.invalidResponse }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
// swiftlint:enable line_length
