// SyncTransport.swift
// M7: bounded authenticated transport, safe redirect handling and optimistic remote versions.

import Foundation

public struct SyncRemoteSnapshot: Sendable {
    public var data: Data?
    public var version: String?
    public var context: String?
    public var storagePaths: [String]
    public init(data: Data?, version: String?, context: String? = nil, storagePaths: [String] = []) {
        self.data = data; self.version = version; self.context = context; self.storagePaths = storagePaths
    }
}

public protocol SyncTransport: Sendable {
    var targetID: String { get }
    func fetch() async throws -> SyncRemoteSnapshot
    func upload(_ data: Data, replacing remote: SyncRemoteSnapshot) async throws -> String?
}

final class SyncRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never replay credentials or conditional writes to another endpoint.
        completionHandler(nil)
    }
}

public struct SyncHTTP: Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 90
            self.session = URLSession(configuration: configuration, delegate: SyncRedirectGuard(), delegateQueue: nil)
        }
    }
    public func send(_ request: URLRequest, limit: Int = SyncSnapshotCodec.compressedLimit) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw SyncError.invalidSnapshot }
        if response.expectedContentLength > Int64(limit) { throw SyncError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw SyncError.tooLarge }
            data.append(byte)
        }
        Log.net.debug("同步请求完成：\(request.httpMethod ?? "GET", privacy: .public)，HTTP \(response.statusCode)")
        return (data, response)
    }
    static func check(_ response: HTTPURLResponse) throws {
        if [409, 412, 422].contains(response.statusCode) { throw SyncError.conflict }
        guard (200..<300).contains(response.statusCode) else { throw SyncError.http(response.statusCode) }
    }
}

public struct WebDAVSyncTransport: SyncTransport {
    public let url: URL
    private let authorization: String
    private let http: SyncHTTP
    public var targetID: String { "webdav:" + url.absoluteString }
    public init(url: URL, username: String, password: String, http: SyncHTTP = SyncHTTP()) throws {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.fragment == nil, !username.contains(":"), !username.contains("\n"), !password.isEmpty else {
            throw SyncError.invalidConfiguration
        }
        self.url = url; self.http = http
        authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
    public func fetch() async throws -> SyncRemoteSnapshot {
        let (data, response) = try await http.send(request(method: "GET"))
        if response.statusCode == 404 { return SyncRemoteSnapshot(data: nil, version: nil) }
        try SyncHTTP.check(response)
        let etag = response.value(forHTTPHeaderField: "ETag")
        // Weak validators are not legal If-Match validators.
        let strong = etag.flatMap { $0.hasPrefix("\"") && $0.hasSuffix("\"") ? $0 : nil }
        return SyncRemoteSnapshot(data: data, version: strong)
    }
    public func upload(_ data: Data, replacing remote: SyncRemoteSnapshot) async throws -> String? {
        guard !data.isEmpty, data.count <= SyncSnapshotCodec.jsonLimit else { throw SyncError.tooLarge }
        var request = request(method: "PUT")
        if remote.data == nil {
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        } else if let version = remote.version {
            request.setValue(version, forHTTPHeaderField: "If-Match")
        } else {
            throw SyncError.unsafeRemoteVersion
        }
        request.httpBody = data
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await http.send(request)
        try SyncHTTP.check(response)
        return response.value(forHTTPHeaderField: "ETag")
    }
    private func request(method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }
}
