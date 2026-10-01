import SwiftUI

enum MediaLibraryPage: String, CaseIterable, Identifiable {
    case local, favorites, netease, bilibili, youtube
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: return "本地"
        case .favorites: return "收藏"
        case .netease: return "网易云"
        case .bilibili: return "Bilibili"
        case .youtube: return "YouTube"
        }
    }
    var source: MusicSource? {
        switch self {
        case .netease: return .netease
        case .bilibili: return .bilibili
        case .youtube: return .youtubeMusic
        default: return nil
        }
    }
    init(source: MusicSource) {
        switch source {
        case .netease: self = .netease
        case .bilibili: self = .bilibili
        case .youtubeMusic: self = .youtube
        }
    }
}

struct MediaLibraryView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var viewModel: LibraryViewModel
    @Binding var selection: MediaLibraryPage
    @ObservedObject private var collectionFavorites = CollectionFavoritesStore.shared
    @State private var favoriteSection = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MediaLibraryPage.allCases) { page in
                        Button { selection = page } label: {
                            Text(page.title).font(.callout.weight(selection == page ? .semibold : .regular))
                                .padding(.horizontal, 18).padding(.vertical, 9)
                                .background(selection == page ? Color.accentColor.opacity(0.17) : Color.clear, in: Capsule())
                                .foregroundStyle(selection == page ? Color.accentColor : Color.primary)
                        }.buttonStyle(.plain).accessibilityAddTraits(selection == page ? [.isSelected] : [])
                    }
                }.padding(12)
            }
            Divider()
            if selection == .favorites {
                Picker("收藏内容", selection: $favoriteSection) { Text("歌曲").tag(0); Text("歌单与专辑").tag(1) }
                    .pickerStyle(.segmented).frame(maxWidth: 260).padding(12)
            }
            if let source = selection.source, let online = appState.libraryOnlineModels[source] {
                OnlineExploreView(viewModel: online, enqueueDownload: appState.downloadViewModel?.enqueue,
                                  addToLocalLibrary: appState.syncViewModel.map { model in
                                      { song, playlist, favorite in model.addToLibrary(song, playlistID: playlist, favorite: favorite) }
                                  }, localPlaylists: viewModel.playlists, showsSearch: false)
            } else if selection == .favorites && favoriteSection == 1 { favoriteCollections } else {
                LibraryView(viewModel: viewModel, favoritesPage: selection == .favorites)
                    .id(selection)
            }
        }
        .navigationTitle("媒体库")
        .onAppear(perform: configureLocalPage)
        .onChange(of: selection) { _ in configureLocalPage() }
    }

    private var favoriteCollections: some View {
        ScrollView {
            if collectionFavorites.collections.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "heart").font(.largeTitle).foregroundStyle(.secondary)
                    Text("还没有收藏的歌单或专辑").font(.headline)
                    Text("在平台媒体库或搜索结果中，右键歌单即可加入收藏。").foregroundStyle(.secondary)
                }.padding(40).frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220))], alignment: .leading, spacing: 16) {
                    ForEach(collectionFavorites.collections) { collection in
                        Button {
                            selection = MediaLibraryPage(source: collection.source)
                            appState.libraryOnlineModels[collection.source]?.selectCollection(collection)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                OnlineArtwork(url: collection.artworkURL).aspectRatio(1, contentMode: .fit)
                                Text(collection.title).lineLimit(2)
                                Text(collection.source.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain).contextMenu {
                            Button("取消收藏") { collectionFavorites.toggle(collection) }
                        }
                    }
                }.padding(20)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func configureLocalPage() {
        guard selection.source == nil else { return }
        viewModel.onlyFavorites = selection == .favorites
        viewModel.localFilesOnly = selection == .local
        viewModel.selectedArtist = nil; viewModel.selectedAlbum = nil
    }
}
