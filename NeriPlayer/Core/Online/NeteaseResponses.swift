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
/// 同一个计数在不同端点上可能是数字或字符串；缺失/空串/无法解析都视为未知，
/// 避免一个可选字段的类型差异让整个列表解码失败。
struct NeteaseFlexibleInt: Decodable {
    let value: Int?
    init(from decoder: Decoder) throws {
        // 非标量（对象/数组）或缺失都按「未知」处理，不让一个计数毁掉整段响应。
        guard let container = try? decoder.singleValueContainer() else { value = nil; return }
        if let number = try? container.decode(Int64.self) { value = Int(clamping: number) } else if let double = try? container.decode(Double.self) {
            value = double.isFinite && double >= Double(Int.min) && double < Double(Int.max) ? Int(double) : nil
        } else if let text = try? container.decode(String.self) { value = Int(text.trimmingCharacters(in: .whitespaces)) } else { value = nil }
    }
}
struct NeteaseStatusResponse: Decodable { let code: Int?; let message: String? }
struct NeteaseArtistResponse: Decodable { let name: String? }
struct NeteaseAlbumMetadata: Decodable {
    let name: String?
    let picUrl: String?
    // Field naming differs between app endpoints; keep every cover candidate the API publishes.
    let picUrlStr: String?
    let coverUrl: String?
    private enum CodingKeys: String, CodingKey { case name, picUrl, picUrlStr = "picUrl_str", coverUrl }
    var artworkURL: URL? {
        ArtworkURLNormalizer.normalized(picUrl) ?? ArtworkURLNormalizer.normalized(picUrlStr)
            ?? ArtworkURLNormalizer.normalized(coverUrl)
    }
}
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
                        artworkURL: (al ?? album)?.artworkURL,
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
    let picUrl: String?
    let coverUrl: String?
    let playCount: NeteaseFlexibleInt?
    /// 部分端点（如每日推荐歌单）用小写 playcount，与 Android 的读取顺序一致。
    let playcount: NeteaseFlexibleInt?
    let trackCount: NeteaseFlexibleInt?
    let songCount: NeteaseFlexibleInt?
    let creator: Creator?
    let tracks: [NeteaseSongResponse]?
    let trackIds: [TrackIdentifier]?
    var normalizedCollection: OnlineCollection? {
        guard let id = id?.value, let title = name else { return nil }
        return OnlineCollection(source: .netease, sourceID: id, title: title,
                                subtitle: creator?.nickname ?? "",
                                artworkURL: Self.artwork(coverImgUrl: coverImgUrl, picUrl: picUrl, coverUrl: coverUrl),
                                trackCount: trackCount?.value ?? songCount?.value,
                                playCount: playCount?.value ?? playcount?.value)
    }
    static func artwork(coverImgUrl: String?, picUrl: String?, coverUrl: String?) -> URL? {
        ArtworkURLNormalizer.normalized(coverImgUrl) ?? ArtworkURLNormalizer.normalized(picUrl)
            ?? ArtworkURLNormalizer.normalized(coverUrl)
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
