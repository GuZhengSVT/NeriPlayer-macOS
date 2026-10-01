// M7TransportTests.swift
// M7: deterministic HTTP contracts, conditional writes and credential isolation.

import Foundation
import XCTest
@testable import NeriPlayer

private final class M7HTTPRouter: URLProtocol {
    struct Reply { var data: Data; var status = 200; var headers: [String: String] = [:] }
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> Reply)?
    static func install(_ value: @escaping (URLRequest) throws -> Reply) { lock.lock(); defer { lock.unlock() }; handler = value }
    static func clear() { lock.lock(); defer { lock.unlock() }; handler = nil }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
            let reply = try XCTUnwrap(handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: reply.status,
                                                       httpVersion: "HTTP/1.1", headerFields: reply.headers))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class M7TransportTests: XCTestCase {
    override func tearDown() { M7HTTPRouter.clear() }
    private func http() -> SyncHTTP {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [M7HTTPRouter.self]
        configuration.httpShouldSetCookies = false
        return SyncHTTP(session: URLSession(configuration: configuration))
    }
    private func body(_ request: URLRequest) throws -> SyncRecord {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONDecoder().decode(SyncRecord.self, from: data)
    }
    func testWebDAVMissingThenCreateOnlyAndStrongETagOverwrite() async throws {
        let url = try XCTUnwrap(URL(string: "https://dav.invalid/NeriPlayer/backup.json"))
        let transport = try WebDAVSyncTransport(url: url, username: "user", password: "password", http: http())
        M7HTTPRouter.install { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("user:password".utf8).base64EncodedString())
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            if request.httpMethod == "GET" { return .init(data: Data(), status: 404) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
            return .init(data: Data(), status: 201, headers: ["ETag": "\"v1\""])
        }
        let missing = try await transport.fetch()
        XCTAssertNil(missing.data)
        let version = try await transport.upload(Data("{}".utf8), replacing: missing)
        XCTAssertEqual(version, "\"v1\"")
        M7HTTPRouter.install { request in
            if request.httpMethod == "GET" { return .init(data: Data("{}".utf8), headers: ["ETag": "\"v1\""]) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"v1\"")
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
            return .init(data: Data(), status: 204)
        }
        let existing = try await transport.fetch()
        _ = try await transport.upload(Data("{}".utf8), replacing: existing)
    }
    func testWebDAVRefusesUnsafeVersionAndMapsConflict() async throws {
        let transport = try WebDAVSyncTransport(url: XCTUnwrap(URL(string: "https://dav.invalid/backup.json")),
                                               username: "user", password: "password", http: http())
        M7HTTPRouter.install { _ in .init(data: Data("{}".utf8), headers: ["ETag": "W/\"weak\""]) }
        let weak = try await transport.fetch()
        do {
            _ = try await transport.upload(Data("{}".utf8), replacing: weak); XCTFail("No blind overwrite")
        } catch { XCTAssertEqual(error as? SyncError, .unsafeRemoteVersion) }
        M7HTTPRouter.install { _ in .init(data: Data(), status: 412) }
        do {
            _ = try await transport.upload(Data("{}".utf8), replacing: .init(data: nil, version: nil)); XCTFail("Must conflict")
        } catch { XCTAssertEqual(error as? SyncError, .conflict) }
    }
    func testTransportRejectsInsecureAndCredentialEmbeddedURLs() throws {
        for string in ["http://dav.invalid/backup.json", "https://user:pass@dav.invalid/backup.json"] {
            XCTAssertThrowsError(try WebDAVSyncTransport(url: XCTUnwrap(URL(string: string)), username: "user", password: "password"))
        }
        XCTAssertThrowsError(try GitHubSyncTransport(owner: "../bad", token: "token"))
    }
    func testBoundedHTTPRejectsOversizedResponse() async throws {
        M7HTTPRouter.install { _ in .init(data: Data(repeating: 32, count: 100)) }
        do {
            _ = try await http().send(URLRequest(url: XCTUnwrap(URL(string: "https://bounded.invalid"))), limit: 20)
            XCTFail("Must bound")
        } catch { XCTAssertEqual(error as? SyncError, .tooLarge) }
    }
    func testGitHubReadsAtHeadAndUsesBinaryBlobNonForceCommit() async throws {
        let transport = try GitHubSyncTransport(owner: "owner", repository: "sync", token: "token", http: http())
        M7HTTPRouter.install { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            let path = request.url?.path ?? ""
            switch path {
            case "/repos/owner/sync": return .init(data: Data(#"{"default_branch":"main"}"#.utf8))
            case "/repos/owner/sync/git/ref/heads/main": return .init(data: Data(#"{"object":{"sha":"head"}}"#.utf8))
            case "/repos/owner/sync/contents/backup.json":
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "head")
                return .init(data: Data(#"{"version":"2.0"}"#.utf8))
            case "/repos/owner/sync/contents/backup-raw.bin", "/repos/owner/sync/contents/backup.bin":
                return .init(data: Data(), status: 404)
            case "/repos/owner/sync/git/commits/head": return .init(data: Data(#"{"tree":{"sha":"tree"}}"#.utf8))
            case "/repos/owner/sync/git/blobs":
                let body = try self.body(request)
                XCTAssertEqual(body.text("encoding"), "base64")
                XCTAssertEqual(Data(base64Encoded: body.text("content")), Data("{}".utf8))
                return .init(data: Data(#"{"sha":"blob"}"#.utf8))
            case "/repos/owner/sync/git/trees":
                XCTAssertEqual(try self.body(request).text("base_tree"), "tree")
                return .init(data: Data(#"{"sha":"newtree"}"#.utf8))
            case "/repos/owner/sync/git/commits":
                XCTAssertEqual(try self.body(request).fields["parents"], .array([.string("head")]))
                return .init(data: Data(#"{"sha":"newhead"}"#.utf8))
            case "/repos/owner/sync/git/refs/heads/main":
                XCTAssertEqual(request.httpMethod, "PATCH")
                XCTAssertEqual(try self.body(request).fields["force"], .bool(false))
                return .init(data: Data(#"{"object":{"sha":"newhead"}}"#.utf8))
            default: XCTFail(path); return .init(data: Data(), status: 500)
            }
        }
        let remote = try await transport.fetch()
        XCTAssertEqual(remote.version, "head")
        let newHead = try await transport.upload(Data("{}".utf8), replacing: remote)
        XCTAssertEqual(newHead, "newhead")
    }
    func testGitHubCreatesPrivateRepositoryOnlyForAuthenticatedOwner() async throws {
        let transport = try GitHubSyncTransport(owner: "owner", token: "token", http: http())
        M7HTTPRouter.install { request in
            if request.url?.path == "/user" { return .init(data: Data(#"{"login":"owner"}"#.utf8)) }
            let body = try self.body(request)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(body.fields["private"], .bool(true))
            XCTAssertEqual(body.fields["auto_init"], .bool(true))
            return .init(data: Data(#"{"name":"NeriPlayer-Backup"}"#.utf8), status: 201)
        }
        try await transport.createPrivateRepository()
    }
    func testGitHubMigrationRemovesBinaryFilesInSameCommit() async throws {
        let transport = try GitHubSyncTransport(owner: "owner", repository: "sync", token: "token", http: http())
        M7HTTPRouter.install { request in
            switch request.url?.path {
            case "/repos/owner/sync/git/commits/head": return .init(data: Data(#"{"tree":{"sha":"tree"}}"#.utf8))
            case "/repos/owner/sync/git/blobs": return .init(data: Data(#"{"sha":"blob"}"#.utf8))
            case "/repos/owner/sync/git/trees":
                let entries = try self.body(request).records("tree")
                XCTAssertEqual(entries.map { $0.text("path") }, ["backup.json", "backup-raw.bin", "backup.bin"])
                XCTAssertEqual(entries.dropFirst().map { $0.fields["sha"] }, [.null, .null])
                return .init(data: Data(#"{"sha":"newtree"}"#.utf8))
            case "/repos/owner/sync/git/commits": return .init(data: Data(#"{"sha":"newhead"}"#.utf8))
            default: return .init(data: Data("{}".utf8))
            }
        }
        _ = try await transport.upload(Data("{}".utf8), replacing: SyncRemoteSnapshot(data: Data("{}".utf8),
            version: "head", context: "main", storagePaths: ["backup.json", "backup-raw.bin", "backup.bin"]))
    }
    func testConfigurationStoresSecretsOutsideDefaults() throws {
        let suite = "M7Credentials-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = OnlineMemoryCredentials()
        let store = SyncConfigurationStore(settings: SettingsStore(userDefaults: defaults), credentials: memory)
        var configuration = SyncConfiguration(); configuration.githubOwner = "owner"
        try store.save(configuration, secret: "token-secret")
        XCTAssertEqual(store.load(), configuration)
        XCTAssertEqual(try memory.read(account: "github"), Data("token-secret".utf8))
        XCTAssertFalse(String(data: try XCTUnwrap(defaults.data(forKey: "metadataSyncConfiguration")), encoding: .utf8)?.contains("token-secret") == true)
        XCTAssertNoThrow(try store.transport(for: configuration))
    }
}
