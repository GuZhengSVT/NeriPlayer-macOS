// LibraryTrackRow.swift
// NeriPlayer macOS —— 媒体库/歌单共用的曲目行与本地封面缩略图（2026-10-03 需求 9）。
//
// 从 LibraryView.swift 拆出：行视图要在媒体库主列表、歌手/专辑详情、歌单详情三处复用，
// 且本轮新增了「行内加入歌单」与可调的字号/封面尺寸。把两个叶子视图放在独立文件里，
// LibraryView 只保留页面级结构，单文件长度也回到 SwiftLint 阈值以内。
//
// 行本身不查库：收藏状态由调用方从视图模型的集合读出后传入（见 LibraryViewModel），
// 保证列表滚动的每一行都是纯渲染、没有逐行的仓库查询。

import AppKit
import SwiftUI

// MARK: - 曲目行

/// 单行曲目：封面缩略图 + 标题 + 歌手/专辑 + 格式角标 + 时长。
struct LibraryTrackRow: View {

    let track: LibraryTrack
    var showsAlbum: Bool = true
    /// 标题字号（相对 UI 基础字号）；需求 9 的歌单详情用 17，媒体库主列表保持默认 16。
    var titleSize: CGFloat = 16
    /// 行封面边长；需求 9 要求 48–56pt，媒体库主列表用 48，歌单详情用 56。
    var coverSize: CGFloat = 48
    /// 是否已收藏；由调用方从视图模型的收藏集合读出（行本身不查库）。
    var isFavorited: Bool = false
    /// 点星标的回调；nil 表示这一处不需要收藏交互（例如纯展示行）。
    var onToggleFavorite: (() -> Void)?
    /// 可加入的歌单（行内「加入歌单」菜单的数据源）；空数组时菜单里只有「新建歌单…」。
    var playlists: [PlaylistInfo] = []
    /// 选中某个歌单时把本行加入；nil 表示不提供「加入歌单」动作。
    var onAddToPlaylist: ((PlaylistInfo) -> Void)?
    /// 「新建歌单…」回调；nil 时菜单不显示该项。
    var onNewPlaylist: (() -> Void)?

    @Environment(\.appTypography) private var typography

    var body: some View {
        HStack(spacing: 12) {
            CoverThumbnail(path: track.coverPath, size: coverSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(typography.uiFont(size: titleSize))
                    .lineLimit(1)
                Text(subtitle)
                    .font(typography.uiFont(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            addToPlaylistButton
            favoriteStar
            if let format = track.format, !format.isEmpty {
                Text(format.uppercased())
                    .font(typography.uiFont(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            Text(LibraryTrackRow.durationText(track.duration))
                .font(typography.uiFont(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
        // 纵向留白让行与行之间有呼吸；需求 9 要求行高与间距比旧版（36pt 封面、2pt 内边距）舒展。
        .padding(.vertical, 6)
    }

    /// 行内「加入歌单」：比右键菜单更显眼，但仍是一次点击的动作。
    /// 未提供回调（纯展示行）时不渲染，避免出现点了没反应的按钮。
    @ViewBuilder
    private var addToPlaylistButton: some View {
        if let onAddToPlaylist {
            Menu {
                ForEach(playlists) { playlist in
                    Button(playlist.name) { onAddToPlaylist(playlist) }
                }
                if !playlists.isEmpty, onNewPlaylist != nil { Divider() }
                if let onNewPlaylist { Button("新建歌单…") { onNewPlaylist() } }
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("加入歌单")
        }
    }

    /// 收藏星标。已收藏为实心黄星，未收藏为空心灰星 —— 这就是「当前状态」的可见表达，
    /// 悬停提示同时说明点击后的动作。没有回调时不渲染（保持纯展示行）。
    @ViewBuilder
    private var favoriteStar: some View {
        if let onToggleFavorite {
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorited ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(isFavorited ? Color.yellow : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(isFavorited ? "取消收藏" : "添加到收藏")
        }
    }

    private var subtitle: String {
        let artist = track.artist.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? LibraryGrouping.unknownArtist
        guard showsAlbum else { return artist }
        let album = track.album.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let album else { return artist }
        return artist + " · " + album
    }

    /// 时长文本；未知或非有限值时显示 --:--（不显示 0:00，避免与真实零秒混淆）。
    static func durationText(_ duration: Double?) -> String {
        guard let duration, duration.isFinite, duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 封面

/// 封面缩略图：有落盘文件则读图，否则显示音符占位。
struct CoverThumbnail: View {

    let path: String?
    let size: CGFloat
    var cornerRadius: CGFloat = 4

    var body: some View {
        Group {
            if let image = Self.loadImage(path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }

    /// 读封面文件。路径为空或文件不可解码时返回 nil，由调用方回落占位图。
    private static func loadImage(_ path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        return NSImage(contentsOfFile: path)
    }
}
