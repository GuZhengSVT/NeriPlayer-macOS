// OnlineSearchManager.swift
// M5-T4: normalized multi-source search with independent source failures.
import Foundation

public struct OnlineSearchManager: Sendable {
    public let clients: [any OnlineMusicClient]

    public init(clients: [any OnlineMusicClient]) { self.clients = clients }

    // Each source is independent; preserve deterministic ordering after concurrent completion.
    // swiftlint:disable:next cyclomatic_complexity
    public func search(query: String, page: Int = 1, sources: [MusicSource] = MusicSource.allCases) async -> OnlineSearchPage {
        if Task.isCancelled { return OnlineSearchPage(query: query, results: [], page: max(1, page)) }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = max(1, page)
        guard !normalizedQuery.isEmpty else { return OnlineSearchPage(query: normalizedQuery, results: [], page: page) }
        let uniqueSources = MusicSource.allCases.filter { sources.contains($0) }
        let outcomes = await withTaskGroup(of: SourceSearch.self) { group in
            for source in uniqueSources {
                guard let client = clients.first(where: { $0.source == source }) else {
                    group.addTask { SourceSearch(source: source, songs: [], error: "该音源尚未配置") }
                    continue
                }
                group.addTask {
                    do {
                        let songs = try await client.search(query: normalizedQuery, page: page)
                        return SourceSearch(source: source, songs: songs, error: nil)
                    } catch {
                        return SourceSearch(source: source, songs: [], error: error.localizedDescription)
                    }
                }
            }
            var values: [SourceSearch] = []
            for await value in group { values.append(value) }
            return values
        }
        if Task.isCancelled { return OnlineSearchPage(query: normalizedQuery, results: [], page: page) }
        var results: [OnlineSearchResult] = []
        var failures: [MusicSource: String] = [:]
        // Completion timing never reorders tabs or same-source platform ranking.
        for source in uniqueSources {
            guard let outcome = outcomes.first(where: { $0.source == source }) else { continue }
            if let error = outcome.error {
                failures[source] = error
                Log.net.error("音源搜索失败：\(source.rawValue, privacy: .public)，\(error, privacy: .public)")
            }
            var seen = Set<String>()
            for raw in outcome.songs {
                guard let song = Self.normalized(raw, source: source), seen.insert(song.id).inserted else { continue }
                results.append(OnlineSearchResult(song: song))
            }
        }
        return OnlineSearchPage(query: normalizedQuery, results: results, failedSources: failures, page: page)
    }

    private struct SourceSearch: Sendable {
        let source: MusicSource
        let songs: [SongData]
        let error: String?
    }

    private static func normalized(_ raw: SongData, source: MusicSource) -> SongData? {
        var song = raw
        song.source = source
        song.sourceID = song.sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        song.title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        song.artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        song.album = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
        song.duration = song.duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        guard !song.sourceID.isEmpty, !song.title.isEmpty else { return nil }
        return song
    }
}

public extension OnlineSearchPage {
    var sourceTabs: [MusicSource] { MusicSource.allCases }
    var hasPartialFailure: Bool { !failedSources.isEmpty && !results.isEmpty }
    func results(for source: MusicSource) -> [OnlineSearchResult] { results.filter { $0.source == source } }
}
