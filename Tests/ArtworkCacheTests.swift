// ArtworkCacheTests.swift
// T04: artwork URL normalization, cache identity, coalescing, disk persistence and bounded eviction.
import XCTest
@testable import NeriPlayer

private final class ArtworkMockRouter: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: @Sendable (URLRequest) throws -> (Data, Int)] = [:]
    private static var counts: [String: Int] = [:]
    static func set(_ host: String, handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)) {
        lock.lock(); defer { lock.unlock() }; handlers[host] = handler; counts[host] = 0
    }
    static func remove(_ host: String) { lock.lock(); defer { lock.unlock() }; handlers[host] = nil; counts[host] = nil }
    static func requests(_ host: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[host] ?? 0 }
    override static func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".artwork.invalid") == true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let host = request.url?.host ?? ""
            Self.lock.lock(); let handler = Self.handlers[host]; Self.counts[host, default: 0] += 1; Self.lock.unlock()
            let reply = try XCTUnwrap(handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: reply.1,
                                                         httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.0)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

/// 1×1 red PNG; a fixed fixture avoids depending on AppKit drawing inside tests.
private let artworkPNG = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC") ?? Data()

final class ArtworkCacheTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkMockRouter.self]
        return URLSession(configuration: config)
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        // Only ever remove the per-test sandbox this class created.
        if directory.lastPathComponent.hasPrefix("artwork-") { try? FileManager.default.removeItem(at: directory) }
    }

    func testNormalizationOnlyUpgradesSupportedPlatformHosts() throws {
        XCTAssertEqual(ArtworkURLNormalizer.normalized("http://p1.music.126.net/a.jpg?param=200y200")?.scheme, "https")
        XCTAssertEqual(ArtworkURLNormalizer.normalized("http://i0.hdslb.com/bfs/archive/a.jpg")?.scheme, "https")
        XCTAssertEqual(ArtworkURLNormalizer.normalized("http://i.ytimg.com/vi/a/hq.jpg")?.scheme, "https")
        XCTAssertEqual(ArtworkURLNormalizer.normalized("//i1.hdslb.com/a.jpg")?.scheme, "https")
        // Unrelated hosts keep their scheme instead of being silently rewritten.
        XCTAssertEqual(ArtworkURLNormalizer.normalized("http://images.example.com/a.jpg")?.scheme, "http")
        XCTAssertNil(ArtworkURLNormalizer.normalized("not a url"))
        XCTAssertNil(ArtworkURLNormalizer.normalized("https://user:pass@i0.hdslb.com/a.jpg"))
    }

    func testCacheKeyIgnoresSchemeUpgrade() throws {
        let http = try XCTUnwrap(URL(string: "http://p1.music.126.net/a.jpg"))
        let https = try XCTUnwrap(URL(string: "https://p1.music.126.net/a.jpg"))
        XCTAssertEqual(ArtworkURLNormalizer.key(for: http), ArtworkURLNormalizer.key(for: https))
    }

    func testConcurrentRequestsCoalesceIntoOneFetch() async throws {
        let host = UUID().uuidString.lowercased() + ".artwork.invalid"
        defer { ArtworkMockRouter.remove(host) }
        let data = artworkPNG
        ArtworkMockRouter.set(host) { _ in (data, 200) }
        let loader = ArtworkImageLoader(directory: directory, session: session())
        let url = try XCTUnwrap(URL(string: "https://" + host + "/cover.png"))
        // Four simultaneous consumers of the same cover must share a single network fetch.
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = try? await loader.image(for: url)
                    return true
                }
            }
            for await _ in group { }
        }
        XCTAssertEqual(ArtworkMockRouter.requests(host), 1)
    }

    func testDiskCacheServesASecondLoaderWithoutNetwork() async throws {
        let host = UUID().uuidString.lowercased() + ".artwork.invalid"
        defer { ArtworkMockRouter.remove(host) }
        let data = artworkPNG
        ArtworkMockRouter.set(host) { _ in (data, 200) }
        let url = try XCTUnwrap(URL(string: "https://" + host + "/cover.png"))
        _ = try await ArtworkImageLoader(directory: directory, session: session()).image(for: url)
        XCTAssertEqual(ArtworkMockRouter.requests(host), 1)
        _ = try await ArtworkImageLoader(directory: directory, session: session()).image(for: url)
        XCTAssertEqual(ArtworkMockRouter.requests(host), 1, "disk hit must not refetch")
    }

    func testHTTPFailureIsReportedAndNotCachedAsAnImage() async throws {
        let host = UUID().uuidString.lowercased() + ".artwork.invalid"
        defer { ArtworkMockRouter.remove(host) }
        ArtworkMockRouter.set(host) { _ in (Data("nope".utf8), 404) }
        let loader = ArtworkImageLoader(directory: directory, session: session())
        let url = try XCTUnwrap(URL(string: "https://" + host + "/missing.png"))
        do { _ = try await loader.image(for: url); XCTFail("404 must surface as a failure") } catch {
            XCTAssertEqual(error as? ArtworkLoadFailure, .http(404))
        }
        XCTAssertNil(loader.cachedImage(for: url))
        let cachedFile = directory.appendingPathComponent(ArtworkURLNormalizer.key(for: url) + ".img")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedFile.path))
    }

    func testOversizedBodyIsRejectedBeforeDecoding() async throws {
        let host = UUID().uuidString.lowercased() + ".artwork.invalid"
        defer { ArtworkMockRouter.remove(host) }
        ArtworkMockRouter.set(host) { _ in (Data(repeating: 7, count: 4096), 200) }
        let loader = ArtworkImageLoader(directory: directory, session: session(),
                                        limits: ArtworkCacheLimits(maxImageBytes: 1024))
        let url = try XCTUnwrap(URL(string: "https://" + host + "/big.png"))
        do { _ = try await loader.image(for: url); XCTFail("oversized body must fail") } catch {
            XCTAssertEqual(error as? ArtworkLoadFailure, .tooLarge)
        }
    }

    func testNeteaseCoverMappingFallsBackToAlternateFieldsAndHTTPS() throws {
        let alternate = Data(#"{"id":1,"name":"S","al":{"name":"A","picUrl_str":"http://p1.music.126.net/alt.jpg"}}"#.utf8)
        let parsedAlternate = try JSONDecoder().decode(NeteaseSongResponse.self, from: alternate)
        XCTAssertEqual(parsedAlternate.normalized?.artworkURL?.scheme, "https")
        XCTAssertEqual(parsedAlternate.normalized?.artworkURL?.lastPathComponent, "alt.jpg")

        let coverOnly = Data(#"{"id":2,"name":"S","album":{"name":"A","coverUrl":"https://p2.music.126.net/cover.jpg"}}"#.utf8)
        let parsedCover = try JSONDecoder().decode(NeteaseSongResponse.self, from: coverOnly)
        XCTAssertEqual(parsedCover.normalized?.artworkURL?.lastPathComponent, "cover.jpg")

        let playlist = Data(#"{"id":9,"name":"P","picUrl":"http://p1.music.126.net/p.jpg"}"#.utf8)
        let parsedPlaylist = try JSONDecoder().decode(NeteasePlaylistResponse.self, from: playlist)
        XCTAssertEqual(parsedPlaylist.normalizedCollection?.artworkURL?.scheme, "https")
    }
}
