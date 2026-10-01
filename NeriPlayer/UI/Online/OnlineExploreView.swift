// OnlineExploreView.swift
// M5: native source browsing, normalized search, collection detail and account actions.
import AppKit
import SwiftUI

struct OnlineExploreView: View {
    @ObservedObject var viewModel: OnlineViewModel
    @ObservedObject private var favorites = CollectionFavoritesStore.shared
    var enqueueDownload: ((SongData) -> Void)?
    var addToLocalLibrary: ((SongData, UUID?, Bool) -> Void)?
    var localPlaylists: [PlaylistInfo] = []
    var showsSearch = true
    @State private var loginPresented = false
    @State private var collectionPresented = false
    @State private var collectionID = ""
    @State private var collectionKind: OnlineCollection.Kind = .playlist
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if showsSearch {
                    Picker("平台", selection: Binding(get: { viewModel.source }, set: viewModel.setSource)) {
                        ForEach(MusicSource.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 420)
                } else { Text(viewModel.source.title + "媒体库").font(.headline) }
                Spacer(minLength: 0)
                Button { collectionPresented = true } label: { Image(systemName: "music.note.list") }.help("打开歌单或专辑")
                Button { viewModel.refreshCurrentPage() } label: { Image(systemName: "arrow.clockwise") }.help("刷新")
                if viewModel.isLoadingAccount && viewModel.account == nil { ProgressView().controlSize(.small) }
                Button { loginPresented = true } label: { Label(viewModel.account?.name ?? "登录", systemImage: "person.crop.circle") }
            }.padding(12)
            Divider()
            if showsSearch {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索歌曲、歌手", text: Binding(get: { viewModel.query }, set: viewModel.setQuery)).textFieldStyle(.plain).onSubmit(viewModel.search)
                if viewModel.isSearching { ProgressView().controlSize(.small) }
                if viewModel.isSearchMode {
                    Button { viewModel.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("清除搜索")
                }
                Toggle("全部平台", isOn: Binding(get: { viewModel.searchesAllSources }, set: viewModel.setSearchesAllSources)).toggleStyle(.checkbox)
            }.padding(12)
            Divider()
            }
            if let collection = viewModel.selectedCollection { detail(collection) } else if viewModel.isSearchMode { searchContent } else { browseContent }
        }
        .navigationTitle(showsSearch ? "搜索" : "媒体库")
        .task { viewModel.loadBrowseContent() }
        .sheet(isPresented: $loginPresented) { OnlineLoginView(viewModel: viewModel) }
        .sheet(isPresented: $collectionPresented) {
            VStack(alignment: .leading, spacing: 16) {
                Text("打开收藏").font(.headline)
                Picker("类型", selection: $collectionKind) {
                    Text("歌单").tag(OnlineCollection.Kind.playlist)
                    if viewModel.source != .bilibili { Text("专辑").tag(OnlineCollection.Kind.album) }
                }.pickerStyle(.segmented)
                TextField("ID", text: $collectionID).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("取消") { collectionPresented = false }
                    Button("打开") {
                        viewModel.openCollection(id: collectionID, kind: collectionKind)
                        collectionPresented = false
                    }.disabled(collectionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20).frame(width: 360)
        }
        .alert("在线音乐", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.clearError() } })) {
            Button("好", role: .cancel) { viewModel.clearError() }
        } message: { Text(viewModel.errorMessage ?? "") }
    }
    private var searchContent: some View {
        VStack(spacing: 0) {
            if !viewModel.partialErrors.isEmpty {
                messages(viewModel.partialErrors.map { "\($0.key.title)：\($0.value)" }.sorted())
            }
            songList(viewModel.results)
            if viewModel.hasMoreResults {
                Button("加载更多") { viewModel.loadMore() }.disabled(viewModel.isSearching).padding(8)
            }
        }
    }
    private var browseContent: some View {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !viewModel.browseErrors.isEmpty {
                    HStack {
                        messages(viewModel.browseErrors.map { "\($0.key)：\($0.value)" }.sorted())
                        Button("重试") { viewModel.loadBrowseContent(force: true) }
                    }
                }
                HStack {
                    Text("歌单与收藏夹").font(.headline)
                    if viewModel.isLoadingCollections { ProgressView().controlSize(.small) }
                }
                if viewModel.collections.isEmpty, !viewModel.isLoadingCollections {
                    if viewModel.browseErrors["歌单"] == nil {
                        Text(viewModel.account == nil ? "登录后查看歌单" : "暂无歌单").foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220))], alignment: .leading, spacing: 12) {
                    ForEach(viewModel.collections) { collection in
                        Button { viewModel.rememberBrowseAnchor(collection.id); viewModel.selectCollection(collection) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                OnlineArtwork(url: collection.artworkURL).aspectRatio(1, contentMode: .fit)
                                Text(collection.title).font(.callout).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                Text(collection.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.buttonStyle(.plain).id(collection.id)
                        .task(id: collection.id) { viewModel.loadCollectionArtwork(collection) }
                        .contextMenu {
                            Button(favorites.contains(collection) ? "取消收藏歌单" : "收藏歌单") { favorites.toggle(collection) }
                        }
                    }
                }
                if let updated = viewModel.collectionsUpdatedAt {
                    Text("歌单更新于 \(updated.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                if showsSearch {
                    HStack { Text("推荐").font(.headline); if viewModel.isLoadingRecommendations { ProgressView().controlSize(.small) } }
                    ForEach(viewModel.recommendations) { song in songRow(song) }
                }
            }.padding(16)
          }
          .onAppear { if let id = viewModel.browseScrollAnchor { proxy.scrollTo(id, anchor: .top) } }
          .onChange(of: viewModel.source) { _ in if let id = viewModel.browseScrollAnchor { proxy.scrollTo(id, anchor: .top) } }
        }
    }
    private func detail(_ collection: OnlineCollection) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { viewModel.clearDetail() } label: { Image(systemName: "chevron.left") }.help("返回")
                OnlineArtwork(url: collection.artworkURL).frame(width: 64, height: 64)
                VStack(alignment: .leading) {
                    Text(collection.title).font(.headline).lineLimit(2)
                    Text(collection.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { favorites.toggle(collection) } label: { Image(systemName: favorites.contains(collection) ? "heart.fill" : "heart") }
                    .help(favorites.contains(collection) ? "取消收藏歌单" : "收藏歌单")
                Button { viewModel.playCollection() } label: { Label("播放全部", systemImage: "play.fill") }
                    .disabled(!viewModel.canPlay || !viewModel.isDetailComplete || viewModel.collectionSongs.isEmpty)
            }.padding(12)
            if viewModel.isLoadingDetail && !viewModel.isDetailComplete {
                ProgressView("正在加载歌单…已读取 \(viewModel.collectionSongs.count) 首").padding()
            } else if viewModel.isLoadingDetail {
                HStack { ProgressView().controlSize(.small); Text("正在后台更新") }.font(.caption).foregroundStyle(.secondary).padding(6)
            }
            if let updated = viewModel.detailUpdatedAt {
                Text("缓存更新于 \(updated.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            if let error = viewModel.detailError {
                HStack { messages([error]); Button("重试") { viewModel.selectCollection(collection, force: true) } }.padding(.horizontal)
            }
            songList(viewModel.collectionSongs)
        }
    }
    private func songList(_ songs: [SongData]) -> some View {
        List {
            ForEach(songs) { song in songRow(song).listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)) }
            if songs.isEmpty, !viewModel.isSearching, !viewModel.isLoadingDetail { Text("暂无歌曲").foregroundStyle(.secondary) }
        }.listStyle(.plain)
    }
    private func songRow(_ song: SongData) -> some View {
        HStack(spacing: 10) {
            OnlineArtwork(url: song.artworkURL).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).lineLimit(1)
                Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(song.source.title).font(.caption2).foregroundStyle(.secondary)
            if let duration = song.duration { Text(durationLabel(duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
            Button { viewModel.play(song) } label: { Image(systemName: "play.fill") }.help("播放").disabled(!viewModel.canPlay)
        }
        .contentShape(Rectangle()).onTapGesture(count: 2) { viewModel.play(song) }
        .contextMenu {
            Button("播放", systemImage: "play.fill") { viewModel.play(song) }
            Button("下一首播放", systemImage: "text.insert") { viewModel.enqueueNext(song) }
            if let enqueueDownload {
                Button("下载", systemImage: "arrow.down.circle") { enqueueDownload(song) }
            }
            if let addToLocalLibrary {
                Button("加入本地收藏", systemImage: "heart") { addToLocalLibrary(song, nil, true) }
                Menu("加入本地歌单") {
                    ForEach(localPlaylists) { playlist in
                        Button(playlist.name) { addToLocalLibrary(song, playlist.id, false) }
                    }
                }.disabled(localPlaylists.isEmpty)
            }
            if song.source != .youtubeMusic {
                Button("收藏", systemImage: "star") { viewModel.setFavorite(song, favorite: true) }
                Button("取消收藏", systemImage: "star.slash") { viewModel.setFavorite(song, favorite: false) }
            }
            if let url = song.pageURL { Button("在浏览器中打开", systemImage: "safari") { NSWorkspace.shared.open(url) } }
        }
    }
    private func messages(_ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) { ForEach(values, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) } }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
    private func durationLabel(_ value: Double) -> String {
        let seconds = Int(min(604_800, max(0, value)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
