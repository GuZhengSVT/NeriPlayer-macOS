// LyricsProviderTests.swift - source selection, encoding, and network privacy coverage.

import XCTest
@testable import NeriPlayer
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class LyricsProviderTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricsProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let directory = temporaryDirectory.standardizedFileURL
        let root = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard directory.path.hasPrefix(root + "/"),
              directory.lastPathComponent.hasPrefix("LyricsProviderTests-") else {
            XCTFail("Refusing to delete unexpected temporary path: \(directory.path)")
            try super.tearDownWithError()
            return
        }
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testLocalUsesRichExtensionPriorityAndReadsUTF16BOM() async throws {
        let trackURL = temporaryDirectory.appendingPathComponent("song.mp3")
        FileManager.default.createFile(atPath: trackURL.path, contents: Data())
        let lrc = "[00:01.00]LRC fallback"
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><p begin="1s" end="2s">TTML preferred</p></body></tt>
        """
        let lrcData = Data(lrc.utf8)
        try lrcData.write(to: temporaryDirectory.appendingPathComponent("song.lrc"))
        let utf16Body = try XCTUnwrap(ttml.data(using: .utf16LittleEndian))
        let utf16Data = Data([0xFF, 0xFE]) + utf16Body
        try utf16Data.write(to: temporaryDirectory.appendingPathComponent("song.ttml"))

        let document = try await LocalLyricsProvider().lyrics(for: LyricsRequest(track: Track(url: trackURL)))
        XCTAssertEqual(document?.source, "local")
        XCTAssertEqual(document?.lyrics.lines.first?.content, "TTML preferred")
    }

    func testStandardLRCAndTimedTxtUseExistingEnhancedParser() async throws {
        let trackURL = temporaryDirectory.appendingPathComponent("timed.mp3")
        FileManager.default.createFile(atPath: trackURL.path, contents: Data())
        let data = Data("[00:01]one\n[00:02.5]two".utf8)
        try data.write(to: temporaryDirectory.appendingPathComponent("timed.txt"))
        let document = try await LocalLyricsProvider().lyrics(
            for: LyricsRequest(track: Track(url: trackURL))
        )
        let first = try XCTUnwrap(document?.lyrics.lines.first)
        XCTAssertEqual(first.content, "one")
        XCTAssertEqual(first.start, 1_000)
    }

    func testLocalIgnoresRemoteTrackURL() async throws {
        let track = Track(url: try XCTUnwrap(URL(string: "https://example.invalid/song.mp3")))
        let document = try await LocalLyricsProvider().lyrics(for: LyricsRequest(track: track))
        XCTAssertNil(document)
    }

    func testPlainTextDoesNotInventTiming() async throws {
        let trackURL = temporaryDirectory.appendingPathComponent("song.m4a")
        FileManager.default.createFile(atPath: trackURL.path, contents: Data())
        let plainData = Data("first\nsecond\n".utf8)
        try plainData.write(to: temporaryDirectory.appendingPathComponent("song.txt"))

        let document = try await LocalLyricsProvider().lyrics(for: LyricsRequest(track: Track(url: trackURL)))
        XCTAssertEqual(document?.plainLines, ["first", "second"])
        XCTAssertTrue(document?.lyrics.lines.isEmpty == true)
    }

    func testLocalRejectsOversizedSidecar() async throws {
        let trackURL = temporaryDirectory.appendingPathComponent("song.mp3")
        FileManager.default.createFile(atPath: trackURL.path, contents: Data())
        try Data(repeating: 65, count: 32).write(to: temporaryDirectory.appendingPathComponent("song.lrc"))

        do {
            _ = try await LocalLyricsProvider(maximumFileBytes: 8).lyrics(
                for: LyricsRequest(track: Track(url: trackURL))
            )
            XCTFail("Expected file size rejection")
        } catch let error as LyricsProviderError {
            guard case .fileTooLarge = error else { XCTFail("Unexpected error: \(error)"); return }
        }
    }

    func testNeteaseRequiresExplicitSongID() async throws {
        let mock = MockURLProtocol.install(body: Data("{}".utf8), statusCode: 200)
        let provider = NeteaseLyricsProvider(session: mock.session, endpoint: mock.endpoint)
        let track = Track(url: temporaryDirectory.appendingPathComponent("song.mp3"))
        let document = try await provider.lyrics(for: LyricsRequest(track: track))
        XCTAssertNil(document)
        XCTAssertEqual(mock.requestCount, 0)
    }

    func testNeteasePrefersYRCAndMergesNearestTranslationAndRomanization() async throws {
        let body = """
        {
          "yrc": { "lyric": "[1000,2000](1000,1000,0)Hello" },
          "lrc": { "lyric": "[00:01.00]LRC" },
          "ytlrc": { "lyric": "[00:01.20]你好" },
          "romalrc": { "lyric": "[00:01.10]Ni hao" }
        }
        """
        let mock = MockURLProtocol.install(body: Data(body.utf8), statusCode: 200)
        let provider = NeteaseLyricsProvider(session: mock.session, endpoint: mock.endpoint)
        let track = Track(url: temporaryDirectory.appendingPathComponent("song.mp3"))
        let document = try await provider.lyrics(
            for: LyricsRequest(track: track, neteaseSongID: "123")
        )

        XCTAssertEqual(document?.source, "netease")
        XCTAssertEqual(document?.lyrics.lines.first?.content, "Hello")
        XCTAssertEqual(document?.lyrics.lines.first?.translation, "你好")
        XCTAssertEqual(document?.phoneticByLine[0], "Ni hao")
        XCTAssertEqual(mock.lastRequest?.url?.query?.contains("id=123"), true)
    }

    func testNeteaseBadJSONAndHTTPStatusAreErrors() async throws {
        let track = Track(url: temporaryDirectory.appendingPathComponent("song.mp3"))
        do {
            let mock = MockURLProtocol.install(body: Data("not-json".utf8), statusCode: 200)
            _ = try await NeteaseLyricsProvider(session: mock.session, endpoint: mock.endpoint).lyrics(
                for: LyricsRequest(track: track, neteaseSongID: "1")
            )
            XCTFail("Expected invalid JSON")
        } catch let error as LyricsProviderError {
            guard case .invalidResponse = error else { XCTFail("Unexpected error: \(error)"); return }
        }

        do {
            let mock = MockURLProtocol.install(body: Data(), statusCode: 503)
            _ = try await NeteaseLyricsProvider(session: mock.session, endpoint: mock.endpoint).lyrics(
                for: LyricsRequest(track: track, neteaseSongID: "1")
            )
            XCTFail("Expected HTTP status error")
        } catch let error as LyricsProviderError {
            guard case .httpStatus(503, _) = error else { XCTFail("Unexpected error: \(error)"); return }
        }
    }

    func testCompositeDoesNotNetworkWithoutIDAndFallsBackAfterLocalError() async throws {
        let trackURL = temporaryDirectory.appendingPathComponent("song.mp3")
        FileManager.default.createFile(atPath: trackURL.path, contents: Data())
        try Data(repeating: 1, count: 16).write(to: temporaryDirectory.appendingPathComponent("song.lrc"))
        let mock = MockURLProtocol.install(body: Data("{}".utf8), statusCode: 200)
        let remote = NeteaseLyricsProvider(session: mock.session, endpoint: mock.endpoint)
        let composite = CompositeLyricsProvider(
            local: LocalLyricsProvider(maximumFileBytes: 4),
            remote: remote
        )

        do {
            _ = try await composite.lyrics(for: LyricsRequest(track: Track(url: trackURL)))
            XCTFail("Expected local error")
        } catch {
            XCTAssertTrue(error is LyricsProviderError)
        }
        XCTAssertEqual(mock.requestCount, 0)

        let body = "{\"lrc\":{\"lyric\":\"[00:01.00]remote\"}}"
        mock.set(body: Data(body.utf8), statusCode: 200)
        let document = try await composite.lyrics(
            for: LyricsRequest(track: Track(url: trackURL), neteaseSongID: "9")
        )
        XCTAssertEqual(document?.lyrics.lines.first?.content, "remote")
    }
}

private final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var control: MockURLProtocolControl?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    static func install(body: Data, statusCode: Int) -> MockURLProtocolControl {
        let control = MockURLProtocolControl(body: body, statusCode: statusCode)
        lock.lock(); self.control = control; lock.unlock()
        return control
    }

    override func startLoading() {
        Self.lock.lock()
        let control = Self.control
        Self.lock.unlock()
        guard let control, let requestURL = request.url else { return }
        control.record(request)
        guard let response = HTTPURLResponse(
            url: requestURL, statusCode: control.statusCode,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: control.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MockURLProtocolControl {
    let session: URLSession
    let endpoint = URL(string: "https://mock.invalid/lyric") ?? URL(fileURLWithPath: "/")
    fileprivate(set) var body: Data
    fileprivate(set) var statusCode: Int
    private(set) var requestCount = 0
    private(set) var lastRequest: URLRequest?

    init(body: Data, statusCode: Int) {
        self.body = body
        self.statusCode = statusCode
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func set(body: Data, statusCode: Int) {
        self.body = body
        self.statusCode = statusCode
    }

    func record(_ request: URLRequest) {
        requestCount += 1
        lastRequest = request
    }
}
