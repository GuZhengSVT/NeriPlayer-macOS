// CurrentTrackLibraryActions.swift
// NeriPlayer macOS —— 把「当前播放曲目」映射到收藏 / 加歌单动作，并给出该曲是否已收藏。
//
// 为什么单独一个类型而不是写在 FloatingPlayerBar 里：
//   1) 「当前 Track 是本地曲还是在线歌」决定了走哪条写入路径 —— 本地曲按库 id 走
//      LibraryViewModel（FavoriteRepository / PlaylistRepository），在线歌没有库里那一行，
//      必须先入库（AppState.syncViewModel.addToLibrary）再收藏/入单。这段分流逻辑是纯规则，
//      可脱离界面单测；
//   2) 视图只关心「有哪些歌单可选、当前是否已收藏、点下走哪条」，把判断集中在这里，
//      避免三处（栏、弹层、菜单）各写一遍并漂移。
//
// 边界：本类型不持有数据库、不查库读取歌单列表（那是 LibraryViewModel 的职责，它已经有一份
// 内存态）；它只做「当前曲目 → 动作意图」的判定与转发。

import Foundation

/// 当前曲目在库侧的落点。
enum CurrentTrackLibraryTarget: Equatable {
    /// 已在媒体库中的本地曲（或已入库的在线曲），按库 id 操作。
    case library(LibraryTrack)
    /// 尚未入库的在线曲，收藏/入单前需先入库。
    case online(SongData)
}

/// 把当前播放曲目归一到「本地库项」或「在线歌」两类之一。
enum CurrentTrackLibraryActions {

    /// 判定当前曲目的落点。
    ///
    /// - Parameters:
    ///   - track: 当前播放曲目（来自播放快照）。
    ///   - libraryTracks: 库内全部曲目；用 url 匹配是否已入库。
    /// - Returns: 落点；无法判定（既不是本地文件也没有在线身份）时为 nil。
    static func target(for track: Track?, libraryTracks: [LibraryTrack]) -> CurrentTrackLibraryTarget? {
        guard let track else { return nil }
        // 先按 URL 在库里匹配，**在线曲也走这一步**：在线曲的 Track.url 就是它的 identityURL，
        // 已入库的在线项在库里的 url 也是同一个 identityURL，因此能命中并归到 .library。
        // 这一步是「已入库在线曲可收藏/可取消收藏」的关键 —— 若不先匹配，在线曲每次都会被当成
        // 新歌走 .online，isFavorited 恒为 false，用户无法取消收藏。
        if let match = libraryTracks.first(where: { $0.url == track.url }) {
            return .library(match)
        }
        // 没命中：本地文件说明它不在库中（例如临时拖入），没有可收藏的库行。
        if track.url.isFileURL { return nil }
        // 未入库的在线曲：后续收藏/入单前需要先入库。
        if let song = track.onlineSong { return .online(song) }
        return nil
    }

    /// 当前曲目是否已收藏。仅当能定位到库项时才有确定答案；在线歌未入库时视为未收藏。
    static func isFavorited(_ track: Track?, libraryTracks: [LibraryTrack],
                            favoriteIds: Set<UUID>) -> Bool {
        guard case .library(let item) = target(for: track, libraryTracks: libraryTracks) else { return false }
        return favoriteIds.contains(item.id)
    }
}
