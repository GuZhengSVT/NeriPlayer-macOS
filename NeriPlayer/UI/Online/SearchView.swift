import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var viewModel: OnlineViewModel
    @ObservedObject var pageModel: SearchPageModel
    @ObservedObject private var collectionFavorites = CollectionFavoritesStore.shared
    var onOpenCollection: (OnlineCollection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: pageModel.linkMode ? "link" : "magnifyingglass").foregroundStyle(.secondary)
                    if pageModel.linkMode {
                        TextField("粘贴歌曲、歌单或视频链接", text: $pageModel.linkText).onSubmit(recognize)
                    } else {
                        TextField("搜索歌曲、歌手、歌单或专辑", text: Binding(get: { viewModel.query }, set: updateQuery))
                            .onSubmit(submit)
                    }
                    if pageModel.isLoading || viewModel.isSearching { ProgressView().controlSize(.small) }
                    Button(pageModel.linkMode ? "识别" : "搜索", action: pageModel.linkMode ? recognize : submit)
                        .buttonStyle(.borderedProminent)
                }.textFieldStyle(.plain).padding(12)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 8) {
                    ForEach(MusicSource.allCases) { source in
                        sourceButton(source.title, selected: !pageModel.linkMode && viewModel.source == source) {
                            pageModel.linkMode = false; pageModel.category = .songs; viewModel.songsSearchEnabled = true; viewModel.setSource(source)
                        }
                    }
                    sourceButton("链接识别", selected: pageModel.linkMode) { pageModel.linkMode = true }
                    Spacer(minLength: 0)
                }
                if !pageModel.linkMode {
                    HStack(spacing: 12) {
                        ForEach(categories) { category in
                            Button {
                                pageModel.category = category
                                viewModel.songsSearchEnabled = category == .songs
                                viewModel.search()
                                if category != .songs { pageModel.search(using: viewModel) }
                            } label: {
                                Text(category.title).font(.callout.weight(pageModel.category == category ? .semibold : .regular))
                                    .foregroundStyle(pageModel.category == category ? Color.accentColor : Color.secondary)
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                        if pageModel.category == .songs {
                            Toggle("全部平台", isOn: Binding(get: { viewModel.searchesAllSources }, set: viewModel.setSearchesAllSources))
                                .toggleStyle(.checkbox)
                        }
                    }
                }
            }.padding(20)
            Divider()
            if pageModel.linkMode { linkContent } else if let artist = pageModel.selectedArtist {
                HStack {
                    Button { pageModel.closeArtist() } label: { Label("返回", systemImage: "chevron.left") }
                    Text(artist.title).font(.headline); Spacer()
                }.padding(12)
                if let error = pageModel.error {
                    HStack { Text(error).font(.caption); Spacer(); Button("重试") { pageModel.openArtist(artist, using: viewModel) } }.padding(12)
                }
                songList(pageModel.artistTracks)
            } else if !viewModel.isSearchMode { historyContent } else if pageModel.category == .songs {
                if !viewModel.partialErrors.isEmpty {
                    errorLine(viewModel.partialErrors.map { "\($0.key.title)：\($0.value)" }.sorted().joined(separator: "；"))
                }
                songList(viewModel.results)
                if viewModel.hasMoreResults { Button("加载更多") { viewModel.loadMore() }.disabled(viewModel.isSearching).padding(8) }
            } else { catalogContent }
        }.navigationTitle("搜索")
        .onChange(of: viewModel.source) { _ in
            pageModel.category = .songs; viewModel.songsSearchEnabled = true; pageModel.closeArtist(); viewModel.search()
        }
    }

    private var categories: [CatalogCategory] {
        switch viewModel.source {
        case .bilibili: return [.songs]
        case .youtubeMusic: return [.songs, .artists]
        case .netease: return CatalogCategory.allCases
        }
    }
    private func sourceButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout).padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Color.accentColor.opacity(0.17) : Color.secondary.opacity(0.06), in: Capsule())
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }.buttonStyle(.plain)
    }
    private var historyContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("搜索历史").font(.headline); Spacer(); if !pageModel.history.isEmpty { Button("清空") { pageModel.clearHistory() } } }
                if pageModel.history.isEmpty { Text("搜索过的关键词会显示在这里。").foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 220))], alignment: .leading, spacing: 10) {
                    ForEach(pageModel.history, id: \.self) { keyword in
                        Button { updateQuery(keyword); submit() } label: {
                            HStack { Image(systemName: "clock"); Text(keyword).lineLimit(1); Spacer(minLength: 0) }
                                .padding(10).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).contextMenu { Button("移除") { pageModel.removeHistory(keyword) } }
                    }
                }
            }.padding(24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var catalogContent: some View {
        VStack(spacing: 0) {
            if let error = pageModel.error { errorLine(error) }
            List(pageModel.items) { item in
                Button {
                    if let collection = item.collection { onOpenCollection(collection) } else { pageModel.openArtist(item, using: viewModel) }
                } label: {
                    HStack(spacing: 12) {
                        OnlineArtwork(url: item.artworkURL).frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).lineLimit(1)
                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain).contextMenu {
                    if let collection = item.collection {
                        Button(collectionFavorites.contains(collection) ? "取消收藏" : "收藏歌单或专辑") { collectionFavorites.toggle(collection) }
                    }
                }
            }.listStyle(.plain)
            if pageModel.items.isEmpty && !pageModel.isLoading && pageModel.error == nil { Text("没有找到相关内容").foregroundStyle(.secondary).padding() }
            if pageModel.hasMore { Button("加载更多") { pageModel.search(using: viewModel, append: true) }.disabled(pageModel.isLoading).padding(8) }
        }
    }
    private var linkContent: some View {
        VStack(spacing: 0) {
            Text("支持网易云歌曲、歌单与专辑，Bilibili 视频与收藏夹，以及 YouTube 链接。视频分 P 会单独列出。")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            if let error = pageModel.error { errorLine(error) }
            songList(pageModel.linkedSongs)
        }
    }
    private func songList(_ songs: [SongData]) -> some View {
        List {
            ForEach(songs) { song in
                HStack(spacing: 12) {
                    // 需求 10：Bilibili 视频封面走 16:9 横向容器并完整显示原图；其余平台保持方形。
                    OnlineArtworkThumbnail(url: song.artworkURL, platform: song.source, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title).lineLimit(1)
                        Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(song.source.title).font(.caption).foregroundStyle(.secondary)
                    if let duration = song.duration { Text(Self.duration(duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                    Button { play(song, songs: songs) } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless).help("播放")
                }.padding(.vertical, 4).contentShape(Rectangle()).onTapGesture(count: 2) { play(song, songs: songs) }
                    .contextMenu {
                        Button("播放") { play(song, songs: songs) }
                        Button("下一首播放") { viewModel.enqueueNext(song) }
                        Button("收藏到媒体库") { appState.syncViewModel?.addToLibrary(song, favorite: true) }
                        Menu("加入歌单") {
                            ForEach(appState.libraryViewModel?.playlists ?? []) { playlist in
                                Button(playlist.name) { appState.syncViewModel?.addToLibrary(song, playlistID: playlist.id) }
                            }
                        }
                        Button("下载") { appState.enqueueDownload(song) }
                    }
            }
            if songs.isEmpty && viewModel.isSearchMode && !viewModel.isSearching && !pageModel.isLoading && !pageModel.linkMode {
                Text("没有找到相关歌曲").foregroundStyle(.secondary)
            }
        }.listStyle(.plain)
    }
    private func errorLine(_ message: String) -> some View {
        HStack { Text(message).font(.caption).foregroundStyle(.secondary); Spacer(); Button("重试", action: pageModel.linkMode ? recognize : submit) }.padding(12)
    }
    private func updateQuery(_ value: String) {
        viewModel.setQuery(value)
        if pageModel.category != .songs { pageModel.search(using: viewModel, debounce: true) }
    }
    private func submit() {
        pageModel.remember(viewModel.query)
        if pageModel.category == .songs { viewModel.search() } else { pageModel.search(using: viewModel) }
    }
    private func recognize() { pageModel.recognize(using: viewModel, openCollection: onOpenCollection) }
    private func play(_ song: SongData, songs: [SongData]) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        appState.playbackStore?.setQueue(songs.map { $0.track() }, startIndex: index)
    }
    private static func duration(_ seconds: Double) -> String {
        let value = Int(max(0, min(604_800, seconds)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
