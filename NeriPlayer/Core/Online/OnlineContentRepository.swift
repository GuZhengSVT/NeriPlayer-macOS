// OnlineContentRepository.swift
// Shared browse/detail snapshots and coalesced requests for independently navigated surfaces.
import Foundation

struct OnlineCollectionDetail: Codable, Sendable {
    var collection: OnlineCollection
    var songs: [SongData]
}

@MainActor
final class OnlineContentRepository {
    private let clients: [MusicSource: any OnlineMusicClient]
    private let sessions: OnlineSessionStore
    private let disk: OnlineContentCache?
    private let now: () -> Date
    private var memory: [String: CachedOnlineValue<Data>] = [:]
    private var requests: [String: (id: UUID, task: Task<Data, Error>)] = [:]

    init(clients: [any OnlineMusicClient], sessions: OnlineSessionStore, cache: OnlineContentCache? = nil,
         now: @escaping () -> Date = { Date() }) {
        self.clients = Dictionary(clients.map { ($0.source, $0) }, uniquingKeysWith: { _, last in last })
        self.sessions = sessions; disk = cache; self.now = now
    }

    func context(for source: MusicSource) throws -> String { try sessions.cacheContext(for: source) }

    private func key(_ source: MusicSource, context: String, resource: String) -> String {
        "\(source.rawValue):\(context):\(resource)"
    }

    func cached<Value: Codable & Sendable>(
        _ type: Value.Type,
        source: MusicSource,
        context: String,
        resource: String
    ) -> CachedOnlineValue<Value>? {
        let cacheKey = key(source, context: context, resource: resource)
        do {
            if let entry = memory[cacheKey] {
                return CachedOnlineValue(value: try JSONDecoder().decode(type, from: entry.value), updatedAt: entry.updatedAt)
            }
            if let entry = try disk?.read(type, key: cacheKey) {
                remember(try JSONEncoder().encode(entry.value), updatedAt: entry.updatedAt, key: cacheKey)
                return entry
            }
        } catch { Log.db.error("读取在线页面缓存失败：\(error.localizedDescription)") }
        return nil
    }

    private func remember(_ data: Data, updatedAt: Date, key: String) {
        memory[key] = CachedOnlineValue(value: data, updatedAt: updatedAt)
        guard memory.count > 64 else { return }
        let oldest = memory.sorted { $0.value.updatedAt < $1.value.updatedAt }
        for entry in oldest.prefix(memory.count - 64) { memory[entry.key] = nil }
    }

    // swiftlint:disable:next function_parameter_count
    private func fetch<Value: Codable & Sendable>(
        _ type: Value.Type,
        source: MusicSource,
        context: String,
        resource: String,
        lifetime: TimeInterval,
        force: Bool,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> CachedOnlineValue<Value> {
        if !force, let value = cached(type, source: source, context: context, resource: resource),
           value.isFresh(at: now(), lifetime: lifetime) { return value }
        let cacheKey = key(source, context: context, resource: resource)
        // Refresh clicks and multiple windows share one in-flight operation. Failures are never cached.
        if let request = requests[cacheKey] {
            let data = try await request.task.value
            return CachedOnlineValue(value: try JSONDecoder().decode(type, from: data), updatedAt: now())
        }
        let requestID = UUID()
        let request = Task { try JSONEncoder().encode(try await operation()) }
        requests[cacheKey] = (requestID, request)
        defer { if requests[cacheKey]?.id == requestID { requests[cacheKey] = nil } }
        let data = try await request.value
        let value = CachedOnlineValue(value: try JSONDecoder().decode(type, from: data), updatedAt: now())
        guard try self.context(for: source) == context else { throw CancellationError() }
        remember(data, updatedAt: value.updatedAt, key: cacheKey)
        do { try disk?.write(value, key: cacheKey) } catch {
            Log.db.error("保存在线页面缓存失败：\(error.localizedDescription)")
        }
        return value
    }

    private func client(_ source: MusicSource) throws -> any OnlineMusicClient {
        guard let value = clients[source] else { throw OnlineError.unavailable("\(source.title)暂不可用") }
        return value
    }

    // MARK: - 首页分区

    /// 首页缓存资源键。仓库与视图模型共用同一份定义，避免字符串各写一份后漂移。
    static func homePlaylistResource(_ source: NeteaseHomePlaylistSource) -> String {
        "home:playlists:\(source.rawValue)"
    }

    static func homeSongResource(_ source: NeteaseHomeSongSource) -> String {
        "home:songs:\(source.rawValue)"
    }

    static let homeRadarResource = "home:radar-playlists"
    static let homeShelvesResource = "home:shelves"

    /// 首页分区与探索页共用同一套按会话上下文隔离的缓存；失败永不写入缓存。
    /// 每个分区单独取数据，因此一个分区失败不会清空其余分区的已有内容。
    func homePlaylistSection(
        source: NeteaseHomePlaylistSource,
        context: String,
        force: Bool
    ) async throws -> CachedOnlineValue<[OnlineCollection]> {
        let provider = try neteaseHomeProvider()
        return try await fetch([OnlineCollection].self, source: .netease, context: context,
                               resource: Self.homePlaylistResource(source), lifetime: 30 * 60, force: force) {
            try await provider.homePlaylists(source, limit: neteaseHomeSectionPlaylistLimit)
        }
    }

    func homeSongSection(
        source: NeteaseHomeSongSource,
        context: String,
        force: Bool
    ) async throws -> CachedOnlineValue<[SongData]> {
        let provider = try neteaseHomeProvider()
        var refresh = force
        if source == .dailyRecommend, let entry = cached([SongData].self, source: .netease, context: context,
                                                        resource: Self.homeSongResource(source)) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
            refresh = refresh || !calendar.isDate(entry.updatedAt, inSameDayAs: now())
        }
        return try await fetch([SongData].self, source: .netease, context: context,
                               resource: Self.homeSongResource(source), lifetime: 30 * 60, force: refresh) {
            try await provider.homeSongs(source, limit: neteaseHomeSectionSongLimit)
        }
    }

    func homeRadarPlaylists(context: String, force: Bool) async throws -> CachedOnlineValue<[OnlineCollection]> {
        let provider = try neteaseHomeProvider()
        return try await fetch([OnlineCollection].self, source: .netease, context: context,
                               resource: Self.homeRadarResource, lifetime: 15 * 60, force: force) {
            try await provider.homeRadarPlaylists()
        }
    }

    func youtubeHomeShelves(context: String, force: Bool) async throws -> CachedOnlineValue<[YouTubeMusicHomeShelf]> {
        guard let provider = clients[.youtubeMusic] as? any YouTubeMusicHomeProviding else {
            throw OnlineError.unavailable("YouTube Music 暂不可用")
        }
        return try await fetch([YouTubeMusicHomeShelf].self, source: .youtubeMusic, context: context,
                               resource: Self.homeShelvesResource, lifetime: 15 * 60, force: force) {
            try await provider.homeShelves()
        }
    }

    private func neteaseHomeProvider() throws -> any NeteaseHomeProviding {
        guard let provider = clients[.netease] as? any NeteaseHomeProviding else {
            throw OnlineError.unavailable("网易云首页分区暂不可用")
        }
        return provider
    }

    func recommendations(source: MusicSource, context: String, force: Bool) async throws -> CachedOnlineValue<[SongData]> {
        let client = try client(source)
        var refresh = force
        if source == .netease, let entry = cached([SongData].self, source: source, context: context, resource: "recommendations") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
            refresh = refresh || !calendar.isDate(entry.updatedAt, inSameDayAs: now())
        }
        return try await fetch([SongData].self, source: source, context: context, resource: "recommendations",
                               lifetime: 30 * 60, force: refresh) { try await client.recommendations() }
    }

    func collections(source: MusicSource, context: String, force: Bool) async throws -> CachedOnlineValue<[OnlineCollection]> {
        let client = try client(source)
        return try await fetch([OnlineCollection].self, source: source, context: context, resource: "collections",
                               lifetime: 15 * 60, force: force) { try await client.collections() }
    }

    func account(source: MusicSource, context: String, force: Bool) async throws -> CachedOnlineValue<OnlineAccount> {
        let client = try client(source)
        return try await fetch(OnlineAccount.self, source: source, context: context, resource: "account",
                               lifetime: 15 * 60, force: force) { try await client.account() }
    }

    func detail(_ collection: OnlineCollection, context: String, force: Bool,
                onPage: @escaping @MainActor @Sendable ([SongData]) -> Void = { _ in }) async throws -> CachedOnlineValue<OnlineCollectionDetail> {
        let client = try client(collection.source)
        return try await fetch(OnlineCollectionDetail.self, source: collection.source, context: context,
                               resource: "detail:\(collection.id)", lifetime: 15 * 60, force: force) {
            var songs: [SongData] = [], seen = Set<String>(), cursors = Set<String>()
            var cursor: String?
            var completed = false
            for _ in 0..<1000 {
                let page = try await client.collectionPage(in: collection, cursor: cursor)
                songs.append(contentsOf: page.songs.filter { seen.insert($0.id).inserted })
                await onPage(songs)
                guard let next = page.nextCursor else { completed = true; break }
                guard cursors.insert(next).inserted else { throw OnlineError.invalidResponse }
                cursor = next
            }
            guard completed else { throw OnlineError.unavailable("歌单分页超出限制") }
            var value = collection
            if value.artworkURL == nil { value.artworkURL = songs.first(where: { $0.artworkURL != nil })?.artworkURL }
            return OnlineCollectionDetail(collection: value, songs: songs)
        }
    }

    func artwork(_ collection: OnlineCollection, context: String) async throws -> URL? {
        let apiClient = try client(collection.source)
        let value = try await fetch(URL?.self, source: collection.source, context: context,
                                    resource: "artwork:v2:\(collection.id)", lifetime: 15 * 60, force: false) {
            try await apiClient.collectionArtwork(in: collection)
        }
        return value.value
    }
}
