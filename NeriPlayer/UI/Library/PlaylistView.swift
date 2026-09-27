// PlaylistView.swift
// NeriPlayer macOS —— 歌单管理（移植规划 M2-T7）。
//
// 结构：一个 sheet 里两个状态，由 LibraryViewModel.openPlaylistId 决定 ——
//   - nil：歌单列表页（新建 / 重命名 / 删除，删除带确认弹窗）；
//   - 非 nil：歌单详情页（曲目列表、右键移除、拖拽排序、双击从该行开始播整单）。
//
// 为什么用「视图模型持有 openPlaylistId + 手动切换」而不是 NavigationStack 的 path：
// 与媒体库的歌手/专辑详情（LibraryView.artistsArea）保持同一种写法 —— 详情页的进出是视图模型的
// 状态变更，视图只读。NavigationStack 在这儿要额外维护一份 path 与视图模型同步，收益不大。
//
// 拖拽排序：SwiftUI 的 onMove 只给 IndexSet + 目标下标，仓库要的是完整新顺序；
// 转换放在 LibraryViewModel.moveInOpenPlaylist（内存顺序 → 仓库 reorder），视图不碰数组搬移。
// 双击播放整单走 PlaybackStateStore.setQueue(tracks, startIndex:)，startIndex 即被点行下标，
// 于是进队列后「上一首/下一首」的行为与队列语义一致，而不是只播一首。
//
// M2-T8：右键菜单与歌手/专辑详情对齐 —— 单曲项是「播放 / 下一首播放」，整单项是
// 「播放全部 / 随机播放」。随机起点仍走 PlaybackEntry.shuffle（整单入队 + 随机跳转），
// 与详情页同一条路径，因此「随机出来的那首一定属于这个歌单」这条不变量三处一致。

import AppKit
import SwiftUI

// MARK: - 歌单管理面板

/// 歌单管理 sheet：列表页与详情页共用。
struct PlaylistListView: View {

    @ObservedObject var viewModel: LibraryViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// 正在重命名的歌单；非 nil 即弹出命名框。
    @State private var renamingPlaylist: PlaylistInfo?
    @State private var renameText = ""
    /// 待确认删除的歌单；非 nil 即弹出确认框。
    @State private var pendingDelete: PlaylistInfo?
    /// 新建歌单的命名框是否打开。
    @State private var isCreating = false
    @State private var createText = ""

    var body: some View {
        VStack(spacing: 0) {
            if let playlist = viewModel.openPlaylist {
                PlaylistDetailView(playlist: playlist, viewModel: viewModel)
            } else {
                listPage
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420)
        .alert("新建歌单", isPresented: $isCreating) {
            TextField("歌单名称", text: $createText)
            Button("取消", role: .cancel) { }
            Button("新建") { viewModel.createPlaylist(named: createText, adding: nil) }
        } message: {
            Text("输入新歌单的名称")
        }
        .alert("重命名歌单", isPresented: renamePresented) {
            TextField("歌单名称", text: $renameText)
            Button("取消", role: .cancel) { renamingPlaylist = nil }
            Button("重命名") {
                if let playlist = renamingPlaylist {
                    viewModel.renamePlaylist(playlist, to: renameText)
                }
                renamingPlaylist = nil
            }
        } message: {
            Text("为「\(renamingPlaylist?.name ?? "")」输入新名称")
        }
        .alert("删除歌单？", isPresented: deletePresented) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let playlist = pendingDelete { viewModel.deletePlaylist(playlist) }
                pendingDelete = nil
            }
        } message: {
            Text("「\(pendingDelete?.name ?? "")」将被删除，其中的曲目不会从媒体库移除。")
        }
        // 关闭面板即退回列表页：下次打开从歌单目录开始，而不是停在某个歌单详情。
        .onDisappear { viewModel.closePlaylist() }
    }

    // MARK: 列表页

    private var listPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("歌单")
                    .font(.headline)
                Spacer(minLength: 8)
                Button {
                    createText = ""
                    isCreating = true
                } label: {
                    Label("新建歌单", systemImage: "plus")
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if viewModel.playlists.isEmpty {
                emptyState
            } else {
                List(viewModel.playlists) { playlist in
                    PlaylistRow(playlist: playlist, count: viewModel.playlistCounts[playlist.id] ?? 0)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { viewModel.openPlaylist(playlist) }
                        .contextMenu {
                            Button("打开") { viewModel.openPlaylist(playlist) }
                            Button("重命名…") { beginRename(playlist) }
                            Divider()
                            Button("删除…", role: .destructive) { pendingDelete = playlist }
                        }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("还没有歌单")
                .font(.title3)
            Text("在媒体库里右键任意歌曲，选「加入歌单 → 新建歌单…」即可开始。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("新建歌单") {
                createText = ""
                isCreating = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 辅助

    private func beginRename(_ playlist: PlaylistInfo) {
        renameText = playlist.name
        renamingPlaylist = playlist
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renamingPlaylist != nil }, set: { if !$0 { renamingPlaylist = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

// MARK: - 歌单行

/// 歌单列表中的一行：图标 + 名称 + 曲目数（曲目数未知时只显示名称）。
struct PlaylistRow: View {

    let playlist: PlaylistInfo
    /// 歌单曲目数（来自视图模型的批量计数）。
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 36)
            Text(playlist.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(count) 首")
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 歌单详情

/// 歌单详情：曲目列表（右键移除）、拖拽排序、双击从该行开始播整单。
struct PlaylistDetailView: View {

    let playlist: PlaylistInfo
    @ObservedObject var viewModel: LibraryViewModel
    @EnvironmentObject private var appState: AppState

    @State private var selectedTrackID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.playlistEntries.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.closePlaylist()
            } label: {
                Label("返回", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .help("返回歌单列表")

            Image(systemName: "music.note.list")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(viewModel.playlistEntries.count) 首")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("随机播放") { shuffleAll() }
                .disabled(appState.playbackStore == nil || viewModel.playlistEntries.isEmpty)

            Button("播放全部") { playAll() }
                .disabled(appState.playbackStore == nil || viewModel.playlistEntries.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        List(selection: $selectedTrackID) {
            ForEach(Array(viewModel.playlistEntries.enumerated()), id: \.element.id) { index, track in
                LibraryTrackRow(
                    track: track,
                    isFavorited: viewModel.isFavorited(track),
                    onToggleFavorite: { viewModel.toggleFavorite(track) }
                )
                .tag(Optional(track.id))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { play(from: index) }
                .contextMenu {
                    Button("播放") { play(from: index) }
                        .disabled(appState.playbackStore == nil)
                    Button("下一首播放") { appState.playbackStore?.enqueueNext(track.track) }
                        .disabled(appState.playbackStore == nil)
                    Divider()
                    // 整单入口：与头部按钮同语义，方便在任意一行就地换整单。
                    Button("播放全部") { playAll() }
                        .disabled(appState.playbackStore == nil)
                    Button("随机播放") { shuffleAll() }
                        .disabled(appState.playbackStore == nil)
                    Divider()
                    Button("从歌单移除") { viewModel.removeFromOpenPlaylist(track) }
                }
            }
            .onMove { source, destination in
                viewModel.moveInOpenPlaylist(fromOffsets: source, toOffset: destination)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("这个歌单还没有曲目")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("在媒体库里右键歌曲，选「加入歌单」即可把歌放进来。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 从 index 开始播整张歌单：队列替换为整单，起点为被双击的那一行。
    private func play(from index: Int) {
        let tracks = viewModel.playlistEntries.map(\.track)
        selectedTrackID = tracks[safe: index]?.id
        appState.playbackStore?.setQueue(tracks, startIndex: index)
    }

    private func playAll() {
        play(from: 0)
    }

    /// 随机播放整单：整单先入队，再随机取一个起点跳过去。
    private func shuffleAll() {
        guard let store = appState.playbackStore else { return }
        PlaybackEntry.shuffle(viewModel.playlistEntries.map(\.track), store: store)
    }
}

// MARK: - 小工具

extension Array {

    /// 下标越界安全取数。用于「双击行 → 取该行 id 作选中项」，越界时返回 nil 而非崩溃。
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
