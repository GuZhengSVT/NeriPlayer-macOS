// NeteaseHomeClient.swift
// 网易云首页分区数据：推荐歌单、榜单/雷达歌曲、私人 FM 与雷达歌单元数据。
// 行为参考：NeriPlayer Android `core/api/netease/NeteaseClient.kt` 与
// `ui/viewmodel/tab/NeteaseHomeRecommendations.kt`（GPL-3.0-or-later）。
import Foundation

extension NeteaseClient: NeteaseHomeProviding {

    /// 首页推荐歌单分区。各来源对应 Android 端同名接口。
    public func homePlaylists(_ source: NeteaseHomePlaylistSource, limit: Int) async throws -> [OnlineCollection] {
        let limit = min(max(limit, 1), 200)
        let response: NeteaseHomePlaylistsResponse
        switch source {
        case .personalized:
            response = try await personalizedPlaylists(limit: limit)
        case .dailyResource:
            response = try await post("/weapi/v1/discovery/recommend/resource", payload: [:])
        case .highQuality:
            response = try await post("/weapi/playlist/highquality/list", payload: [
                "cat": "全部", "limit": String(limit), "lasttime": "0", "total": "true"
            ])
        case .hotPlaylists:
            response = try await post("/weapi/playlist/list", payload: [
                "cat": "全部", "order": "hot", "limit": String(limit), "offset": "0", "total": "true"
            ])
        case .acgPlaylists:
            response = try await post("/weapi/playlist/list", payload: [
                "cat": "ACG", "order": "hot", "limit": String(limit), "offset": "0", "total": "true"
            ])
        }
        return Array(deduplicatedPlaylists(response.normalized).prefix(limit))
    }

    /// 登录态下「推荐歌单」可能被账号风控拒绝（Android 对 301/50000005 做同样回退），
    /// 此时改用匿名请求重试一次；其余错误照常抛出。
    private func personalizedPlaylists(limit: Int) async throws -> NeteaseHomePlaylistsResponse {
        do {
            return try await post("/weapi/personalized/playlist", payload: ["limit": String(limit)])
        } catch let error as OnlineError {
            guard hasSessionCookie(), Self.shouldFallbackRecommend(error) else { throw error }
            Log.net.info("网易云推荐歌单回退到匿名请求")
            return try await post("/weapi/personalized/playlist", payload: ["limit": String(limit)], useSession: false)
        }
    }

    private func hasSessionCookie() -> Bool {
        guard let cookies = try? sessions.cookieHeader(for: .netease) else { return false }
        return cookies.contains("MUSIC_U=")
    }

    /// Android 的回退判据：API 状态码 301 / 50000005。本地把 50000005 映射为不可用错误。
    static func shouldFallbackRecommend(_ error: OnlineError) -> Bool {
        switch error {
        case .authenticationRequired: return true
        case .unavailable(let message): return message.contains("50000005")
        default: return false
        }
    }

    /// 首页歌曲分区。榜单类走歌单详情，其余走各自推荐接口。
    public func homeSongs(_ source: NeteaseHomeSongSource, limit: Int) async throws -> [SongData] {
        let limit = min(max(limit, 1), 1000)
        switch source {
        case .topSoaring:
            return try await toplistSongs(id: neteaseToplistSoaringID, limit: limit)
        case .topHot:
            return try await toplistSongs(id: neteaseToplistHotID, limit: limit)
        case .topNew:
            return try await toplistSongs(id: neteaseToplistNewID, limit: limit)
        case .personalRadar:
            return try await toplistSongs(id: neteasePrivateRadarPlaylistID, limit: limit)
        case .dailyRecommend:
            let response: NeteaseRecommendationResponse = try await post(
                "/weapi/v3/discovery/recommend/songs", payload: ["afresh": "true"]
            )
            let songs = (response.data?.dailySongs ?? response.recommend ?? []).compactMap(\.normalized)
            return Array(songs.prefix(limit))
        case .personalizedNewSongs:
            let response: NeteasePersonalizedNewSongsResponse = try await post("/weapi/personalized/newsong", payload: [
                "type": "recommend", "limit": String(limit), "areaId": "0"
            ])
            return Array(deduplicatedSongs(response.normalized).prefix(limit))
        case .privateFM:
            return try await privateFMSongs(limit: limit)
        }
    }

    /// 雷达歌单元数据。单个歌单失败只回落该条的默认名称，不影响其余歌单。
    ///
    /// 说明：Android 使用未加密的 `/api/playlist/detail`（`uiPlaylistType=MGC`）取账号维度标题；
    /// 本实现复用加密的 v6 歌单详情，标题是否为账号定制文案未验证。
    public func homeRadarPlaylists() async throws -> [OnlineCollection] {
        var result: [OnlineCollection] = []
        for definition in neteaseRadarPlaylistDefinitions {
            try Task.checkCancellation()
            let fallback = definition.fallbackCollection
            guard let id = try? Self.validID(definition.id) else {
                result.append(fallback)
                continue
            }
            do {
                let response: NeteasePlaylistDetailResponse = try await post(
                    "/weapi/v6/playlist/detail", payload: ["id": id, "n": 1, "s": 0]
                )
                result.append(response.playlist?.normalizedCollection ?? fallback)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.net.error("雷达歌单元数据获取失败：\(definition.id, privacy: .public)")
                result.append(fallback)
            }
        }
        return result
    }

    // MARK: - 内部实现

    /// 榜单/雷达歌单的前 N 首。只取首页需要的数量，避免一次性拉取整张榜单。
    private func toplistSongs(id: String, limit: Int) async throws -> [SongData] {
        let playlistID = try Self.validID(id)
        let response: NeteasePlaylistDetailResponse = try await post(
            "/weapi/v6/playlist/detail", payload: ["id": playlistID, "n": limit, "s": 0]
        )
        guard let playlist = response.playlist else { throw OnlineError.invalidResponse }
        let songs = playlist.tracks?.compactMap(\.normalized) ?? []
        if songs.isEmpty, playlist.trackIds?.isEmpty == false {
            // Some playlists omit inline tracks and publish only IDs; fall back to detail.
            let ids = (playlist.trackIds ?? []).compactMap { $0.id?.value }
            return Array(try await songDetails(ids: Array(ids.prefix(limit))).prefix(limit))
        }
        return Array(songs.prefix(limit))
    }

    /// 私人 FM 每次只返回一小批，按 Android 的批次上限合并去重。
    private func privateFMSongs(limit: Int) async throws -> [SongData] {
        var songs: [SongData] = []
        for _ in 0..<neteaseHomePrivateFmMaxBatches {
            try Task.checkCancellation()
            let response: NeteasePersonalFmResponse = try await post("/weapi/v1/radio/get", payload: [:])
            let batch = response.normalized
            if batch.isEmpty { break }
            let merged = appendUniqueNeteaseHomeSongs(current: songs, next: batch, limit: limit)
            if merged.count == songs.count { break }
            songs = merged
            if songs.count >= limit { break }
        }
        return Array(songs.prefix(limit))
    }

    private func deduplicatedPlaylists(_ collections: [OnlineCollection]) -> [OnlineCollection] {
        var seen = Set<String>()
        return collections.filter { seen.insert($0.id).inserted }
    }

    private func deduplicatedSongs(_ songs: [SongData]) -> [SongData] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.id).inserted }
    }
}
