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
}
