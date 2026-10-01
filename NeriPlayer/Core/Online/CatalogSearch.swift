import Foundation

enum CatalogCategory: String, CaseIterable, Identifiable, Sendable {
    case songs, playlists, albums, artists
    var id: String { rawValue }
    var title: String {
        switch self {
        case .songs: return "歌曲"
        case .playlists: return "歌单"
        case .albums: return "专辑"
        case .artists: return "歌手"
        }
    }
}

struct CatalogItem: Identifiable, Sendable, Equatable {
    var source: MusicSource
    var sourceID: String
    var title: String
    var subtitle: String
    var artworkURL: URL?
    var category: CatalogCategory
    var id: String { "\(source.rawValue):\(category.rawValue):\(sourceID)" }
    var collection: OnlineCollection? {
        guard category == .playlists || category == .albums else { return nil }
        return OnlineCollection(source: source, sourceID: sourceID, title: title, subtitle: subtitle,
                                artworkURL: artworkURL, kind: category == .albums ? .album : .playlist)
    }
}

protocol OnlineCatalogClient: OnlineMusicClient {
    func searchCatalog(query: String, category: CatalogCategory, page: Int) async throws -> [CatalogItem]
    func artistSongs(id: String) async throws -> [SongData]
    func linkedSong(id: String) async throws -> [SongData]
}

extension NeteaseClient: OnlineCatalogClient {
    func searchCatalog(query: String, category: CatalogCategory, page: Int) async throws -> [CatalogItem] {
        let type: Int
        switch category {
        case .songs: return []
        case .playlists: type = 1000
        case .albums: type = 10
        case .artists: type = 100
        }
        let response: CatalogResponse = try await post("/eapi/cloudsearch/pc", payload: [
            "s": query, "type": String(type), "offset": String((max(1, page) - 1) * 30), "limit": "30", "total": "true"
        ], eapi: true)
        let items: [CatalogResponse.Entry]
        switch category {
        case .playlists: items = response.result?.playlists ?? []
        case .albums: items = response.result?.albums ?? []
        case .artists: items = response.result?.artists ?? []
        case .songs: items = []
        }
        return items.compactMap { entry in
            guard let id = entry.id?.value, let title = entry.name else { return nil }
            let subtitle = entry.creator?.nickname ?? entry.artist?.name ?? entry.artists?.compactMap(\.name).joined(separator: " / ") ?? ""
            let cover = entry.coverImgUrl ?? entry.picUrl ?? entry.img1v1Url
            return CatalogItem(source: .netease, sourceID: id, title: title, subtitle: subtitle,
                               artworkURL: ArtworkURLNormalizer.normalized(cover), category: category)
        }
    }
    func artistSongs(id: String) async throws -> [SongData] {
        guard let numeric = Int64(id), numeric > 0 else { throw OnlineError.invalidInput("歌手 ID 无效") }
        let result: ArtistSongsResponse = try await post("/weapi/v1/artist/\(numeric)", payload: [:])
        return result.hotSongs?.compactMap(\.normalized) ?? []
    }
    func linkedSong(id: String) async throws -> [SongData] { try await songDetails(ids: [id]) }
}

private struct CatalogResponse: Decodable {
    struct Person: Decodable { var name: String?; var nickname: String? }
    struct Entry: Decodable {
        var id: NeteaseIdentifier?
        var name: String?
        var coverImgUrl: String?
        var picUrl: String?
        var img1v1Url: String?
        var creator: Person?
        var artist: Person?
        var artists: [Person]?
    }
    struct Result: Decodable { var playlists: [Entry]?; var albums: [Entry]?; var artists: [Entry]? }
    var code: Int?
    var result: Result?
}
private struct ArtistSongsResponse: Decodable { var code: Int?; var hotSongs: [NeteaseSongResponse]? }

extension YouTubeMusicClient: OnlineCatalogClient {
    func searchCatalog(query: String, category: CatalogCategory, page: Int) async throws -> [CatalogItem] {
        let boot = try await bootstrap()
        var payload: [String: Any] = ["query": query]
        if category == .artists { payload["params"] = "EgWKAQIgAWoKEAkQChAFEAMQBA%3D%3D" }
        var root = try await post("/youtubei/v1/search", payload: payload, boot: boot)
        if page > 1 {
            for _ in 1..<min(page, 100) {
                guard let token = YouTubeMusicParser.continuation(root) else { return [] }
                root = try await post("/youtubei/v1/search", payload: ["continuation": token], boot: boot)
            }
        }
        if category == .artists {
            let renderers = YouTubeMusicParser.objects(named: "musicResponsiveListItemRenderer", in: root)
            var seen = Set<String>()
            return renderers.compactMap { renderer in
                guard let endpoint = YouTubeMusicParser.objects(named: "browseEndpoint", in: renderer).first,
                      let id = endpoint["browseId"] as? String, id.hasPrefix("UC"), seen.insert(id).inserted,
                      let column = (renderer["flexColumns"] as? [[String: Any]])?.first?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                      let title = YouTubeMusicParser.text(column["text"]) else { return nil }
                return CatalogItem(source: .youtubeMusic, sourceID: id, title: title, subtitle: "YouTube Music",
                                   artworkURL: YouTubeMusicParser.thumbnail(renderer["thumbnail"]), category: .artists)
            }
        }
        return YouTubeMusicParser.collections(root).filter {
            category == .albums ? $0.kind == .album : $0.kind == .playlist
        }.map { CatalogItem(source: $0.source, sourceID: $0.sourceID, title: $0.title, subtitle: $0.subtitle,
                            artworkURL: $0.artworkURL, category: category) }
    }
    func artistSongs(id: String) async throws -> [SongData] {
        let boot = try await bootstrap()
        return YouTubeMusicParser.songs(try await post("/youtubei/v1/browse", payload: ["browseId": id], boot: boot))
    }
    func linkedSong(id: String) async throws -> [SongData] {
        guard YouTubeMusicParser.validVideoID(id) else { throw OnlineError.invalidInput("视频 ID 无效") }
        let boot = try await bootstrap()
        let root = try await post("/youtubei/v1/player", payload: ["videoId": id], boot: boot)
        guard let detail = root["videoDetails"] as? [String: Any], let title = detail["title"] as? String else {
            throw OnlineError.unavailable("无法读取该视频信息")
        }
        return [SongData(source: .youtubeMusic, sourceID: id, title: title, artist: detail["author"] as? String ?? "",
                         duration: (detail["lengthSeconds"] as? String).flatMap(Double.init),
                         artworkURL: YouTubeMusicParser.thumbnail(detail["thumbnail"]), pageURL: YouTubeMusicParser.watchURL(id))]
    }
}

struct RecognizedMusicLink: Equatable, Sendable {
    var source: MusicSource
    var id: String
    var kind: OnlineCollection.Kind?

    // swiftlint:disable:next cyclomatic_complexity
    static func parse(_ text: String) -> RecognizedMusicLink? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let identity = try? BilibiliVideoIdentity(sourceID: value) {
            return Self(source: .bilibili, id: identity.sourceID, kind: nil)
        }
        guard let url = URL(string: value), let host = url.host?.lowercased(),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func query(_ key: String) -> String? { components?.queryItems?.first { $0.name == key }?.value }
        if ["music.163.com", "y.music.163.com"].contains(host) {
            let fragment = url.fragment.flatMap { URLComponents(string: "https://music.163.com" + ($0.hasPrefix("/") ? $0 : "/" + $0)) }
            let id = query("id") ?? fragment?.queryItems?.first { $0.name == "id" }?.value
            guard let id, Int64(id).map({ $0 > 0 }) == true else { return nil }
            let path = fragment?.path ?? url.path
            let kind: OnlineCollection.Kind? = path.contains("playlist") ? .playlist : (path.contains("album") ? .album : nil)
            guard kind != nil || path.contains("song") else { return nil }
            return Self(source: .netease, id: id, kind: kind)
        }
        if ["www.bilibili.com", "bilibili.com", "m.bilibili.com"].contains(host) {
            if let id = query("fid"), Int64(id).map({ $0 > 0 }) == true { return Self(source: .bilibili, id: id, kind: .favorites) }
            guard let id = url.path.split(separator: "/").first(where: { $0.hasPrefix("BV") || $0.hasPrefix("av") }) else { return nil }
            let sourceID = String(id) + ":" + (query("p") ?? "1")
            guard let identity = try? BilibiliVideoIdentity(sourceID: sourceID) else { return nil }
            return Self(source: .bilibili, id: identity.sourceID, kind: nil)
        }
        if ["music.youtube.com", "www.youtube.com", "youtube.com", "youtu.be"].contains(host) {
            if let id = query("list"), !id.isEmpty { return Self(source: .youtubeMusic, id: id.hasPrefix("VL") ? id : "VL" + id, kind: .playlist) }
            let id = query("v") ?? (host == "youtu.be" ? String(url.path.dropFirst()) : nil)
            guard let id, YouTubeMusicParser.validVideoID(id) else { return nil }
            return Self(source: .youtubeMusic, id: id, kind: nil)
        }
        return nil
    }
}
