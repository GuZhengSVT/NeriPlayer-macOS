// NeteaseResponses.swift
// M5: typed response envelopes tolerate numeric/string IDs but not invalid API status.
import Foundation

struct NeteaseIdentifier: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int64.self) { value = String(number) } else { value = try container.decode(String.self) }
    }
}
struct NeteaseStatusResponse: Decodable { let code: Int?; let message: String? }
struct NeteaseArtistResponse: Decodable { let name: String? }
struct NeteaseAlbumMetadata: Decodable { let name: String?; let picUrl: String? }
struct NeteaseSongResponse: Decodable {
    let id: NeteaseIdentifier?
    let name: String?
    let ar: [NeteaseArtistResponse]?
    let artists: [NeteaseArtistResponse]?
    let al: NeteaseAlbumMetadata?
    let album: NeteaseAlbumMetadata?
    let dt: Double?
    let duration: Double?
    var normalized: SongData? {
        guard let id = id?.value, let title = name, !title.isEmpty else { return nil }
        return SongData(source: .netease, sourceID: id, title: title,
                        artist: (ar ?? artists ?? []).compactMap(\.name).joined(separator: " / "),
                        album: (al ?? album)?.name ?? "", duration: (dt ?? duration).map { $0 / 1000 },
                        artworkURL: (al ?? album)?.picUrl.flatMap(URL.init(string:)),
                        pageURL: URL(string: "https://music.163.com/song?id=\(id)"))
    }
}
struct NeteaseSearchResponse: Decodable {
    struct Result: Decodable { let songs: [NeteaseSongResponse]? }
    let result: Result?
}
struct NeteaseSongDetailResponse: Decodable { let songs: [NeteaseSongResponse]? }
struct NeteaseAlbumResponse: Decodable { let songs: [NeteaseSongResponse]? }
struct NeteaseTrialResponse: Decodable { }
struct NeteaseAudioResponse: Decodable {
    struct Item: Decodable {
        let id: NeteaseIdentifier?
        let code: Int?
        let url: String?
        let expi: Double?
        let freeTrialInfo: NeteaseTrialResponse?
    }
    let data: [Item]?
}
struct NeteasePlaylistResponse: Decodable {
    struct TrackIdentifier: Decodable { let id: NeteaseIdentifier? }
    struct Creator: Decodable { let nickname: String? }
    let id: NeteaseIdentifier?
    let name: String?
    let coverImgUrl: String?
    let creator: Creator?
    let tracks: [NeteaseSongResponse]?
    let trackIds: [TrackIdentifier]?
    var normalizedCollection: OnlineCollection? {
        guard let id = id?.value, let title = name else { return nil }
        return OnlineCollection(source: .netease, sourceID: id, title: title,
                                subtitle: creator?.nickname ?? "", artworkURL: coverImgUrl.flatMap(URL.init(string:)))
    }
}
struct NeteasePlaylistDetailResponse: Decodable { let playlist: NeteasePlaylistResponse? }
struct NeteaseUserPlaylistsResponse: Decodable { let playlist: [NeteasePlaylistResponse]?; let more: Bool? }
struct NeteaseRecommendationResponse: Decodable {
    struct RecommendationData: Decodable { let dailySongs: [NeteaseSongResponse]? }
    let data: RecommendationData?
    let recommend: [NeteaseSongResponse]?
}
struct NeteaseAccountResponse: Decodable {
    struct Profile: Decodable { let userId: NeteaseIdentifier?; let nickname: String? }
    struct Account: Decodable { let id: NeteaseIdentifier?; let userName: String? }
    let profile: Profile?
    let account: Account?
}
struct NeteaseLikeListResponse: Decodable { let ids: [NeteaseIdentifier]? }
struct NeteaseQRKeyResponse: Decodable {
    struct Key: Decodable { let unikey: String? }
    let unikey: String?
    let data: Key?
}
struct NeteaseQRStatusResponse: Decodable { let code: Int?; let cookie: String? }

extension NeteaseClient: OnlineURLRefreshingClient {
    public func refresh(song: SongData, previous: ResolvedAudio?) async throws -> ResolvedAudio { try await resolve(song: song) }
}
extension BilibiliClient: OnlineURLRefreshingClient {
    public func refresh(song: SongData, previous: ResolvedAudio?) async throws -> ResolvedAudio { try await resolve(song: song) }
}
extension YouTubeMusicClient: OnlineURLRefreshingClient {
    public func refresh(song: SongData, previous: ResolvedAudio?) async throws -> ResolvedAudio { try await resolve(song: song) }
}
