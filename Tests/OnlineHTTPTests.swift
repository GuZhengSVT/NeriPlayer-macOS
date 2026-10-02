// OnlineHTTPTests.swift
// M5: deterministic HTTP envelopes, entitlement failures, loopback Range forwarding and token isolation.
import Foundation
import XCTest
@testable import NeriPlayer

private final class OnlineMockRouter: URLProtocol {
    struct Reply { var json: String; var headers: [String: String] = [:]; var status = 200 }
    private static let lock = NSLock()
    private static var handlers: [String: @Sendable (URLRequest) throws -> Reply] = [:]
    static func set(_ host: String, handler: @escaping @Sendable (URLRequest) throws -> Reply) {
        lock.lock(); defer { lock.unlock() }; handlers[host] = handler
    }
    static func remove(_ host: String) { lock.lock(); defer { lock.unlock() }; handlers[host] = nil }
    override static func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock(); let handler = Self.handlers[request.url?.host ?? ""]; Self.lock.unlock()
            let reply = try XCTUnwrap(handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: reply.status,
                                                         httpVersion: "HTTP/1.1", headerFields: reply.headers))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

private struct FixtureNeteaseDeviceProvider: NeteaseDeviceContextProviding {
    var token = "official-sdk-test-token"
    func snapshot() async throws -> NeteaseDeviceSnapshot {
        NeteaseDeviceSnapshot(token: token, deviceID: "test-device", cookies: ["sDeviceId": "test-device"])
    }
}

/// 线程安全的回调收集器：URLProtocol 的 handler 在别的线程跑，测试断言在测试线程读。
private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    func append(_ value: Value) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return storage }
}

private func neteaseAudioFixture(id: Int, url: String?, trial: Bool = false) -> String {
    let trialField = trial ? #","freeTrialInfo":{"start":0,"end":30}"# : ""
    let urlField = url.map { #""url":"\#($0)""# } ?? #""url":null"#
    return #"{"code":200,"data":[{"id":\#(id),"code":200,\#(urlField),"expi":1800\#(trialField)}]}"#
}

final class OnlineHTTPTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OnlineMockRouter.self]
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }
    func testNeteaseSearchUsesOfficialEAPIEnvelope() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        defer { OnlineMockRouter.remove(host) }
        OnlineMockRouter.set(host) { request in
            XCTAssertEqual(request.url?.path, "/eapi/cloudsearch/pc")
            XCTAssertEqual(request.httpMethod, "POST")
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            XCTAssertTrue(String(data: body, encoding: .utf8)?.hasPrefix("params=") == true)
            return .init(json: #"{"code":200,"result":{"songs":[{"id":123,"name":"Test","ar":[{"name":"Artist"}],"dt":180000}]}}"#)
        }
        let client = NeteaseClient(session: session(), sessions: OnlineSessionStore(credentials: OnlineMemoryCredentials()),
                                   baseURL: try XCTUnwrap(URL(string: "https://" + host)), deviceProvider: FixtureNeteaseDeviceProvider())
        let songs = try await client.search(query: "Test", page: 1)
        XCTAssertEqual(songs.first?.sourceID, "123")
        XCTAssertEqual(songs.first?.duration, 180)
    }
    func testNeteaseCatalogSearchMapsCollectionsAndArtistTracks() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        defer { OnlineMockRouter.remove(host) }
        OnlineMockRouter.set(host) { request in
            if request.url?.path == "/weapi/v1/artist/7" {
                return .init(json: #"{"code":200,"hotSongs":[{"id":1,"name":"Artist song","ar":[{"name":"Artist"}]}]}"#)
            }
            XCTAssertEqual(request.url?.path, "/eapi/cloudsearch/pc")
            return .init(json: """
            {"code":200,"result":{
              "playlists":[{"id":123,"name":"Playlist","creator":{"nickname":"Creator"},"coverImgUrl":"https://img.example/cover.jpg"}],
              "albums":[{"id":"456","name":"Album","artist":{"name":"Artist"}}],
              "artists":[{"id":7,"name":"Artist"}]}}
            """)
        }
        let client = NeteaseClient(session: session(), sessions: OnlineSessionStore(credentials: OnlineMemoryCredentials()),
                                   baseURL: try XCTUnwrap(URL(string: "https://" + host)))
        let playlists = try await client.searchCatalog(query: "Test", category: .playlists, page: 1)
        XCTAssertEqual(playlists.first?.collection?.kind, .playlist)
        XCTAssertEqual(playlists.first?.subtitle, "Creator")
        let albums = try await client.searchCatalog(query: "Test", category: .albums, page: 1)
        XCTAssertEqual(albums.first?.sourceID, "456")
        XCTAssertEqual(albums.first?.collection?.kind, .album)
        let songs = try await client.artistSongs(id: "7")
        XCTAssertEqual(songs.first?.title, "Artist song")
    }

    func testNeteaseRefusesTrialAudioAndMapsQRStates() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        defer { OnlineMockRouter.remove(host) }
        OnlineMockRouter.set(host) { request in
            if request.url?.path.contains("player") == true {
                return .init(json: #"{"code":200,"data":[{"id":123,"code":200,"url":"https://cdn.example/trial","freeTrialInfo":{}}]}"#)
            }
            if request.url?.path.hasSuffix("unikey") == true { return .init(json: #"{"code":200,"unikey":"ticket"}"#) }
            return .init(json: #"{"code":802}"#)
        }
        let client = NeteaseClient(session: session(), sessions: OnlineSessionStore(credentials: OnlineMemoryCredentials()),
                                   baseURL: try XCTUnwrap(URL(string: "https://" + host)), deviceProvider: FixtureNeteaseDeviceProvider())
        do {
            _ = try await client.resolve(song: SongData(source: .netease, sourceID: "123", title: "Test"))
            XCTFail("Trial must not play as full song")
        } catch { XCTAssertTrue(error is OnlineError) }
        let ticket = try await client.beginQRLogin()
        let state = try await client.pollQRLogin(ticket)
        XCTAssertEqual(state, .scanned)
    }
    func testNeteaseQRChainAndRefreshTokenAreVerifiedBeforeCommit() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        defer { OnlineMockRouter.remove(host) }
        let sessions = OnlineSessionStore(credentials: OnlineMemoryCredentials())
        OnlineMockRouter.set(host) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://music.163.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-os"), "web")
            XCTAssertEqual(request.value(forHTTPHeaderField: "nm-gcore-status"), "1")
            switch request.url?.path {
            case "/weapi/login/qrcode/unikey":
                XCTAssertNil(request.url?.query)
                return .init(json: #"{"code":200,"unikey":"confirmed-ticket"}"#)
            case "/weapi/login/qrcode/client/login":
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-loginmethod"), "QrCode")
                XCTAssertTrue(request.value(forHTTPHeaderField: "x-login-chain-id")?.hasPrefix("v1_test-device_web_login_") == true)
                XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("sDeviceId=test-device") == true)
                XCTAssertNil(try sessions.cookieHeader(for: .netease))
                return .init(json: #"{"code":803}"#, headers: ["x-refresh-token": "qr-session-credential"])
            case "/weapi/w/nuser/account/get":
                XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("MUSIC_U=qr-session-credential") == true)
                XCTAssertNil(try sessions.cookieHeader(for: .netease))
                return .init(json: #"{"code":200,"profile":{"userId":123,"nickname":"User"}}"#)
            default: throw OnlineError.invalidResponse
            }
        }
        let client = NeteaseClient(session: session(), sessions: sessions,
                                   baseURL: try XCTUnwrap(URL(string: "https://" + host)), deviceProvider: FixtureNeteaseDeviceProvider())
        let ticket = try await client.beginQRLogin()
        let url = try XCTUnwrap(URLComponents(url: ticket.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.path, "/st/platform/scanlogin")
        XCTAssertEqual(url.queryItems?.first { $0.name == "hdw_device" }?.value, "web")
        XCTAssertNotNil(url.queryItems?.first { $0.name == "chainId" }?.value)
        let result = try await client.pollQRLogin(ticket)
        XCTAssertEqual(result, .authorized)
        XCTAssertEqual(try sessions.cookieHeader(for: .netease), "MUSIC_U=qr-session-credential; sDeviceId=test-device")
    }

    func testNeteaseQRConfirmationFailureDoesNotPersistUnverifiedCredential() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        defer { OnlineMockRouter.remove(host) }
        let sessions = OnlineSessionStore(credentials: OnlineMemoryCredentials())
        OnlineMockRouter.set(host) { request in
            if request.url?.path.hasSuffix("unikey") == true { return .init(json: #"{"code":200,"unikey":"ticket"}"#) }
            if request.url?.path.hasSuffix("client/login") == true {
                return .init(json: #"{"code":803}"#, headers: ["x-refresh-token": "unverified"])
            }
            return .init(json: #"{"code":200,"account":null,"profile":null}"#)
        }
        let client = NeteaseClient(session: session(), sessions: sessions,
                                   baseURL: try XCTUnwrap(URL(string: "https://" + host)), deviceProvider: FixtureNeteaseDeviceProvider())
        let ticket = try await client.beginQRLogin()
        do { _ = try await client.pollQRLogin(ticket); XCTFail("Unverified login must fail") } catch { XCTAssertTrue(error is OnlineError) }
        XCTAssertNil(try sessions.cookieHeader(for: .netease))
    }

    func testNeteaseQRRejectsMissingOfficialDeviceToken() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        defer { OnlineMockRouter.remove(host) }
        OnlineMockRouter.set(host) { _ in .init(json: #"{"code":200,"unikey":"ticket"}"#) }
        let client = NeteaseClient(session: session(), sessions: OnlineSessionStore(credentials: OnlineMemoryCredentials()),
            baseURL: try XCTUnwrap(URL(string: "https://" + host)), deviceProvider: FixtureNeteaseDeviceProvider(token: ""))
        do { _ = try await client.beginQRLogin(); XCTFail("Missing device token must not generate a QR ticket") } catch {
            XCTAssertTrue(error.localizedDescription.contains("设备上下文不完整"))
        }
    }

    func testNeteaseQRRejectionIncludesAPIErrorCode() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        defer { OnlineMockRouter.remove(host) }
        OnlineMockRouter.set(host) { request in
            if request.url?.path.hasSuffix("unikey") == true { return .init(json: #"{"code":200,"unikey":"ticket"}"#) }
            return .init(json: #"{"code":8821,"message":"Please retry"}"#)
        }
        let client = NeteaseClient(session: session(), sessions: OnlineSessionStore(credentials: OnlineMemoryCredentials()),
                                   baseURL: try XCTUnwrap(URL(string: "https://" + host)), deviceProvider: FixtureNeteaseDeviceProvider())
        let ticket = try await client.beginQRLogin()
        do { _ = try await client.pollQRLogin(ticket); XCTFail("Expected rejection") } catch {
            XCTAssertTrue(error.localizedDescription.contains("code=8821"))
        }
    }

    func testLoopbackForwardsExactRangeAndRotatesCapability() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        defer { OnlineMockRouter.remove(host) }
        let bytes = "abcdefghijklmnopqrstuvwxyz"
        OnlineMockRouter.set(host) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let range = try XCTUnwrap(request.value(forHTTPHeaderField: "Range"))
            let parts = range.dropFirst(6).split(separator: "-")
            let start = try XCTUnwrap(Int(parts[0])); let end = min(try XCTUnwrap(Int(parts[1])), bytes.count - 1)
            let body = String(bytes.dropFirst(start).prefix(end - start + 1))
            return .init(json: body, headers: ["Content-Range": "bytes \(start)-\(end)/\(bytes.count)", "Content-Type": "audio/test"], status: 206)
        }
        let transport = try OnlineAudioTransport(session: session())
        defer { transport.stop() }
        let song = SongData(source: .youtubeMusic, sourceID: "abcdefghijk", title: "Test")
        let upstream = try XCTUnwrap(URL(string: "https://" + host + "/audio"))
        let first = try transport.register(ResolvedAudio(song: song, url: upstream))
        var request = URLRequest(url: first); request.timeoutInterval = 3
        request.setValue("bytes=3-8", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(String(data: data, encoding: .utf8), "defghi")
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        let second = try transport.register(ResolvedAudio(song: song, url: upstream))
        XCTAssertNotEqual(first.path, second.path)
        do { _ = try await URLSession.shared.data(for: request); XCTFail("Old token should not be served") } catch { }
        let (full, fullResponse) = try await URLSession.shared.data(from: second)
        XCTAssertEqual(full.count, bytes.count)
        XCTAssertEqual((fullResponse as? HTTPURLResponse)?.statusCode, 200)
    }
    func testYTMAuthHeadersNeverReuseAnotherAccount() {
        let first = YouTubeMusicCookies.fingerprint("SAPISID=one")
        let second = YouTubeMusicCookies.fingerprint("SAPISID=two")
        XCTAssertNotEqual(first, second)
        let header = YouTubeMusicCookies.authorization(cookie: "SAPISID=one", origin: "https://music.youtube.com", userSessionID: "", now: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(header?.hasPrefix("SAPISIDHASH 100_") == true)
        XCTAssertFalse(header?.contains("one") == true)
    }
    func testKeychainRoundTripWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["NERIPLAYER_KEYCHAIN_TEST"] == "1" else { throw XCTSkip("Real Keychain probe is opt-in") }
        let store = KeychainCredentialStore(service: "moe.ouom.NeriPlayer.test." + UUID().uuidString)
        defer { try? store.remove(account: "test") }
        try store.write(Data("test-cookie".utf8), account: "test")
        XCTAssertEqual(try store.read(account: "test"), Data("test-cookie".utf8))
        try store.remove(account: "test")
        XCTAssertNil(try store.read(account: "test"))
    }

    // MARK: 音质偏好（需求 3）

    /// eAPI 请求体是加密的，URLProtocol 层读不到 `level`。这里直接验证被抽出的纯决策函数：
    /// 无损及以上必须走 flac 容器，否则用户选了无损也只会拿到 AAC。
    func testNeteaseAudioRequestPlanMapsLevelAndContainer() {
        let lossless = NeteaseClient.audioRequestPlan(for: .lossless)
        XCTAssertEqual(lossless.level, "lossless")
        XCTAssertEqual(lossless.encodeType, "flac")
        XCTAssertEqual(NeteaseClient.audioRequestPlan(for: .hires).encodeType, "flac")
        XCTAssertEqual(NeteaseClient.audioRequestPlan(for: .jyeffect).encodeType, "flac")
        XCTAssertEqual(NeteaseClient.audioRequestPlan(for: .sky).encodeType, "flac")
        XCTAssertEqual(NeteaseClient.audioRequestPlan(for: .jymaster).encodeType, "flac")
        for lower in [NeteaseQuality.standard, .higher, .exhigh] {
            let plan = NeteaseClient.audioRequestPlan(for: lower)
            XCTAssertEqual(plan.level, lower.rawValue)
            XCTAssertEqual(plan.encodeType, "aac")
        }
    }

    /// 偏好 lossless 时第一次请求就是 lossless/flac（决策回调解密了加密体里的参数）。
    func testNeteaseResolveHonoursPreferredLossless() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        defer { OnlineMockRouter.remove(host) }
        let plans = LockedValues<NeteaseClient.NeteaseAudioRequestPlan>()
        OnlineMockRouter.set(host) { _ in .init(json: neteaseAudioFixture(id: 123, url: "https://cdn.example/lossless.flac")) }
        let client = NeteaseClient(session: session(), sessions: OnlineSessionStore(credentials: OnlineMemoryCredentials()),
                                   baseURL: try XCTUnwrap(URL(string: "https://" + host)),
                                   deviceProvider: FixtureNeteaseDeviceProvider(),
                                   quality: .fixed(AudioQualityPreferences(netease: .lossless)),
                                   requestObserver: { plans.append($0) })
        let audio = try await client.resolve(song: SongData(source: .netease, sourceID: "123", title: "Test"))
        XCTAssertEqual(audio.url.absoluteString, "https://cdn.example/lossless.flac")
        XCTAssertEqual(audio.headers["Referer"], "https://music.163.com/")
        XCTAssertEqual(plans.values.count, 1)
        XCTAssertEqual(plans.values.first, NeteaseClient.NeteaseAudioRequestPlan(level: "lossless", encodeType: "flac"))
    }

    /// 首选档位没有 url 时必须顺着 degradeChain 往下退，而不是直接报「没有音源」。
    func testNeteaseResolveDegradesThroughQualityChain() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        defer { OnlineMockRouter.remove(host) }
        let plans = LockedValues<NeteaseClient.NeteaseAudioRequestPlan>()
        let requests = LockedValues<Int>()
        OnlineMockRouter.set(host) { _ in
            requests.append(1)
            // 前两次（lossless / exhigh）不给 url，第三档（higher）才给。
            let call = requests.values.count
            return .init(json: neteaseAudioFixture(id: 123, url: call >= 3 ? "https://cdn.example/higher.mp3" : nil))
        }
        let client = NeteaseClient(session: session(), sessions: OnlineSessionStore(credentials: OnlineMemoryCredentials()),
                                   baseURL: try XCTUnwrap(URL(string: "https://" + host)),
                                   deviceProvider: FixtureNeteaseDeviceProvider(),
                                   quality: .fixed(AudioQualityPreferences(netease: .lossless)),
                                   requestObserver: { plans.append($0) })
        let audio = try await client.resolve(song: SongData(source: .netease, sourceID: "123", title: "Test"))
        XCTAssertEqual(audio.url.absoluteString, "https://cdn.example/higher.mp3")
        // lossless 的降级链是 lossless → exhigh → higher → standard，前两次拿不到就继续往下。
        XCTAssertEqual(plans.values.map(\.level), ["lossless", "exhigh", "higher"])
        XCTAssertEqual(plans.values.map(\.encodeType), ["flac", "aac", "aac"])
    }

    /// 只有试听片段时仍然拒绝播放（不能悄悄播 30 秒），但错误信息要说明原因。
    func testNeteaseResolveRejectsPreviewOnlyAfterExhaustingChain() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        defer { OnlineMockRouter.remove(host) }
        let plans = LockedValues<NeteaseClient.NeteaseAudioRequestPlan>()
        OnlineMockRouter.set(host) { _ in .init(json: neteaseAudioFixture(id: 123, url: "https://cdn.example/trial", trial: true)) }
        let client = NeteaseClient(session: session(), sessions: OnlineSessionStore(credentials: OnlineMemoryCredentials()),
                                   baseURL: try XCTUnwrap(URL(string: "https://" + host)),
                                   deviceProvider: FixtureNeteaseDeviceProvider(),
                                   quality: .fixed(AudioQualityPreferences(netease: .exhigh)),
                                   requestObserver: { plans.append($0) })
        do {
            _ = try await client.resolve(song: SongData(source: .netease, sourceID: "123", title: "Test"))
            XCTFail("预览片段不应作为完整音源返回")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("试听"))
        }
        // exhigh 的链是 exhigh → higher → standard：试听也要把更低的档位试完。
        XCTAssertEqual(plans.values.map(\.level), ["exhigh", "higher", "standard"])
    }

    /// 未配置任何偏好时读取到的必须是冻结默认值 exhigh。
    ///
    /// 用隔离的 UserDefaults 而不是 `.shared`：真实机器上可能已经被设置页写过别的档位，
    /// 断言「未配置」必须建立在一个确实没有该键的存储上。
    func testNeteaseDefaultPreferenceIsExhigh() throws {
        let name = "moe.ouom.NeriPlayer.tests." + UUID().uuidString
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        XCTAssertNil(suite.object(forKey: SettingsKeys.neteaseAudioQuality.name))
        let preferences = AudioQualityPreferences(settings: SettingsStore(userDefaults: suite))
        XCTAssertEqual(NeteaseQuality.default, .exhigh)
        XCTAssertEqual(NeteaseQuality.default.rawValue, "exhigh")
        XCTAssertEqual(SettingsKeys.neteaseAudioQuality.defaultValue, "exhigh")
        XCTAssertEqual(preferences.netease, .exhigh)
    }

    // MARK: YouTube Music 选流

    private func adaptiveFormat(bitrate: Int, mime: String = "audio/webm; codecs=\"opus\"") -> [String: Any] {
        ["bitrate": bitrate, "mimeType": mime, "url": "https://googlevideo.com/x"]
    }

    /// 单条格式的码率（bit/s）。用可选读取而不是强制解包，便于 XCTUnwrap 给出清晰的失败信息。
    private func bitrate(_ format: [String: Any]) -> Int? { format["bitrate"] as? Int }

    func testYouTubeSelectsHighestWithinPreference() throws {
        let formats = [adaptiveFormat(bitrate: 64_000), adaptiveFormat(bitrate: 128_000), adaptiveFormat(bitrate: 200_000)]
        let ordered = YouTubeMusicClient.orderedFormats(formats, preferred: .high)
        let first = try XCTUnwrap(ordered.first)
        XCTAssertEqual(bitrate(first), 128_000)
        XCTAssertEqual(YouTubeMusicClient.inferredQuality(for: first), .high)
        // 200 kbps 属于 very_high（高于偏好），绝不能出现在候选里。
        XCTAssertEqual(ordered.compactMap(bitrate), [128_000, 64_000])
    }

    func testYouTubeVeryHighPreferenceSelectsTopBitrate() throws {
        let formats = [adaptiveFormat(bitrate: 64_000), adaptiveFormat(bitrate: 128_000), adaptiveFormat(bitrate: 200_000)]
        let ordered = YouTubeMusicClient.orderedFormats(formats, preferred: .veryHigh)
        let first = try XCTUnwrap(ordered.first)
        XCTAssertEqual(bitrate(first), 200_000)
        XCTAssertEqual(YouTubeMusicClient.inferredQuality(for: first), .veryHigh)
        // very_high 的链条覆盖所有档位，同档内按码率降序。
        XCTAssertEqual(ordered.compactMap(bitrate), [200_000, 128_000, 64_000])
    }

    func testYouTubeDegradesWhenPreferredTierMissing() throws {
        // 只有 64 kbps（low）时，用户选 very_high 仍必须给出这条，而不是失败。
        let ordered = YouTubeMusicClient.orderedFormats([adaptiveFormat(bitrate: 64_000)], preferred: .veryHigh)
        let first = try XCTUnwrap(ordered.first)
        XCTAssertEqual(ordered.count, 1)
        XCTAssertEqual(bitrate(first), 64_000)
        XCTAssertEqual(YouTubeMusicClient.inferredQuality(for: first), .low)
    }

    func testYouTubeSelectionNeverPicksAbovePreferenceWhenLowerExists() throws {
        // 用户选 medium：128/200 kbps 都在偏好之上，medium 档里没有候选，只能降到 low（64 kbps）。
        let formats = [adaptiveFormat(bitrate: 64_000), adaptiveFormat(bitrate: 128_000), adaptiveFormat(bitrate: 200_000)]
        let ordered = YouTubeMusicClient.orderedFormats(formats, preferred: .medium)
        let first = try XCTUnwrap(ordered.first)
        XCTAssertEqual(bitrate(first), 64_000)
        let inferred = YouTubeMusicClient.inferredQuality(for: first)
        XCTAssertEqual(inferred, .low)
        XCTAssertLessThan(YouTubeQuality.ordered.firstIndex(of: inferred) ?? 0,
                          YouTubeQuality.ordered.firstIndex(of: .medium) ?? 0)
    }

    /// 偏好高于所有候选（候选只有 low，偏好 very_high）时不能以「空链」收场：
    /// 链上确实没有候选，但客户端必须仍然返回候选里的最高档，而不是抛错。
    func testYouTubePreferenceAboveAllCandidatesStillReturnsCandidate() {
        let ordered = YouTubeMusicClient.orderedFormats([adaptiveFormat(bitrate: 64_000), adaptiveFormat(bitrate: 70_000)],
                                                        preferred: .veryHigh)
        XCTAssertEqual(ordered.compactMap(bitrate), [70_000, 64_000])
    }

    /// 偏好低于所有候选（候选只有 200 kbps，偏好 low）时的兜底：返回超规格的那条而不是失败。
    func testYouTubePreferenceBelowAllCandidatesFallsBackToHighest() throws {
        let ordered = YouTubeMusicClient.orderedFormats([adaptiveFormat(bitrate: 200_000)], preferred: .low)
        let first = try XCTUnwrap(ordered.first)
        XCTAssertEqual(ordered.count, 1)
        XCTAssertEqual(bitrate(first), 200_000)
    }

    /// 非音频流必须被过滤掉，码率字段缺失时按 low 处理而不是崩掉。
    func testYouTubeIgnoresNonAudioAndMissingBitrate() throws {
        let ordered = YouTubeMusicClient.orderedFormats([
            ["bitrate": 900_000, "mimeType": "video/mp4"],
            ["mimeType": "audio/mp4"]
        ], preferred: .high)
        let first = try XCTUnwrap(ordered.first)
        XCTAssertEqual(ordered.count, 1)
        XCTAssertEqual(first["mimeType"] as? String, "audio/mp4")
        XCTAssertEqual(YouTubeMusicClient.inferredQuality(for: first), .low)
    }
}
