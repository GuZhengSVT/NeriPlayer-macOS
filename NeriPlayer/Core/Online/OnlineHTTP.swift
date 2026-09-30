// OnlineHTTP.swift
// M5: bounded URLSession helpers shared by online clients.

import Foundation

public enum OnlineHTTP {
    public static let defaultTimeout: TimeInterval = 20
    public static func request(_ request: URLRequest, session: URLSession = .shared,
                               timeout: TimeInterval = defaultTimeout) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = min(max(timeout, 1), 120)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OnlineError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            Log.net.error("在线请求失败：HTTP \(http.statusCode)，host=\(request.url?.host ?? "unknown", privacy: .public)")
            throw OnlineError.http(http.statusCode)
        }
        return (data, http)
    }
    public static func jsonRequest(_ url: URL, method: String = "GET", body: Data? = nil,
                                   headers: [String: String] = [:], session: URLSession = .shared) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try await self.request(request, session: session).0
    }
    public static func makeURL(base: URL, path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        return components?.url
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw OnlineError.invalidResponse }
    }
}

public struct OnlineSearchResult: Identifiable, Hashable, Sendable {
    public var song: SongData
    public var source: MusicSource { song.source }
    public var id: String { song.id }
    public init(song: SongData) { self.song = song }
}

public struct OnlineSearchPage: Sendable {
    public var query: String
    public var results: [OnlineSearchResult]
    public var failedSources: [MusicSource: String]
    public var page: Int
    public init(query: String, results: [OnlineSearchResult], failedSources: [MusicSource: String] = [:], page: Int = 1) {
        self.query = query; self.results = results; self.failedSources = failedSources; self.page = page
    }
}
