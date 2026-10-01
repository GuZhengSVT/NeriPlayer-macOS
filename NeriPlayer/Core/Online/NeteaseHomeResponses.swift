// NeteaseHomeResponses.swift
// 首页分区的响应封装。网易云同一语义在不同端点上用了不同字段名，
// 这里按端点各自建模，避免一个宽松容器把类型不匹配的响应整体解码失败。
import Foundation

/// 宽容数组：字段缺失或类型不是数组时按空数组处理。
/// Android 侧逐字段 optJSONArray，缺失/类型不符都当作没有内容，不应该让整段响应失败。
struct NeteaseLenientArray<Element: Decodable>: Decodable {
    let elements: [Element]
    init(from decoder: Decoder) throws {
        guard let container = try? decoder.singleValueContainer() else { elements = []; return }
        elements = (try? container.decode([Element].self)) ?? []
    }
}

/// 推荐歌单：`result`（推荐歌单/每日推荐）与 `playlists`（精品/热门）两种包裹。
struct NeteaseHomePlaylistsResponse: Decodable {
    let result: NeteaseLenientArray<NeteasePlaylistResponse>?
    let recommend: NeteaseLenientArray<NeteasePlaylistResponse>?
    let playlists: NeteaseLenientArray<NeteasePlaylistResponse>?

    var normalized: [OnlineCollection] {
        let array = result?.elements ?? recommend?.elements ?? playlists?.elements ?? []
        return array.compactMap(\.normalizedCollection)
    }
}

/// 首页歌曲条目：`/personalized/newsong` 把歌曲包在 `song` 里，其余端点直接平铺。
struct NeteaseHomeSongEntry: Decodable {
    let nested: NeteaseSongResponse?
    let flat: NeteaseSongResponse?

    private enum CodingKeys: String, CodingKey { case song }

    init(from decoder: Decoder) throws {
        // 扁平条目（榜单/雷达）与嵌套条目（新歌/私人 FM）共用同一个容器，任何一侧失败都不影响另一侧。
        var nestedValue: NeteaseSongResponse?
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            nestedValue = try? container.decodeIfPresent(NeteaseSongResponse.self, forKey: .song)
        }
        nested = nestedValue
        flat = try? NeteaseSongResponse(from: decoder)
    }

    var normalized: SongData? { (nested ?? flat)?.normalized }
}

/// `/weapi/personalized/newsong`。
struct NeteasePersonalizedNewSongsResponse: Decodable {
    let result: NeteaseLenientArray<NeteaseHomeSongEntry>?
    var normalized: [SongData] { (result?.elements ?? []).compactMap(\.normalized) }
}

/// `/weapi/v1/radio/get`（私人 FM）。
struct NeteasePersonalFmResponse: Decodable {
    let data: NeteaseLenientArray<NeteaseHomeSongEntry>?
    var normalized: [SongData] { (data?.elements ?? []).compactMap(\.normalized) }
}
