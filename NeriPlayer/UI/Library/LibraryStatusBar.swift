// LibraryStatusBar.swift
// NeriPlayer macOS —— 媒体库底部状态条（移植规划 M2-T8 从 LibraryView 拆出）。
//
// 拆出的原因：LibraryView 原本自带这条状态条，M2-T8 又在它下面加了一条播放状态条
// （PlaybackStatusBar），行数顺势越过 SwiftLint 的 800 行软上限。两条状态条职责并不相同 ——
// 这条讲「库」（同步进度、当前维度的条目数、曲目与收藏计数），PlaybackStatusBar 讲「正在放什么」——
// 分开成各自的文件，后续任一条要改都不会牵动另一条。

import SwiftUI

/// 媒体库底部状态条：同步进度 + 当前维度摘要 + 曲目/收藏计数。
struct LibraryStatusBar: View {

    @ObservedObject var viewModel: LibraryViewModel
    let section: LibrarySection

    var body: some View {
        HStack(spacing: 8) {
            if viewModel.isSyncing {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("共 \(viewModel.sourceTracks.count) 首")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !viewModel.favorites.isEmpty {
                Text("收藏 \(viewModel.favorites.count) 首")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// 状态文案：同步摘要 > 收藏过滤 > 搜索命中数 > 当前维度概览。
    private var text: String {
        if let message = viewModel.statusMessage { return message }
        if viewModel.onlyFavorites {
            return "只看收藏：\(viewModel.favorites.count) 首"
        }
        if viewModel.isSearching {
            switch section {
            case .songs: return "\(viewModel.searchResults.count) 首匹配"
            case .artists: return "\(viewModel.searchArtistGroups.count) 位歌手匹配"
            case .albums: return "\(viewModel.searchAlbumGroups.count) 张专辑匹配"
            }
        }
        switch section {
        case .songs: return "双击任意一行开始播放"
        case .artists: return "\(viewModel.artistGroups.count) 位歌手"
        case .albums: return "\(viewModel.albumGroups.count) 张专辑"
        }
    }
}
