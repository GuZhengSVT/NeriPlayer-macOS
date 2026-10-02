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
    /// 当前悬停的导航胶囊。悬停反馈与选中底色共用同一套视觉，只是色值更淡。
    @State private var hoveredPage: MediaLibraryPage?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MediaLibraryPage.allCases) { page in
                        navigationCapsule(page)
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

    // MARK: 导航胶囊

    /// 导航胶囊：文字 + 水平/垂直留白整体是一个命中区域。
    ///
    /// `contentShape(Capsule())` 是需求 8 的关键：只写 `padding` 时留白属于透明区域，
    /// 命中测试会落到 HStack 上而不是按钮，于是「只有文字能点」。这里把胶囊形状显式声明为
    /// 命中区域，留白与文字等价可点。留白同时纳入悬停判定，鼠标一进胶囊就有反馈。
    private func navigationCapsule(_ page: MediaLibraryPage) -> some View {
        let isSelected = selection == page
        let isHovered = hoveredPage == page
        return Button { selection = page } label: {
            Text(page.title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .frame(minHeight: 34)
                // 选中底色与悬停底色同源（同一色、不同透明度），避免两种状态看起来像两套控件。
                .background(capsuleBackground(isSelected: isSelected, isHovered: isHovered), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredPage = page } else if hoveredPage == page { hoveredPage = nil }
        }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 选中态优先于悬停态；两者都不成立时透明，保持无背景的朴素外观。
    private func capsuleBackground(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.17) }
        if isHovered { return Color.accentColor.opacity(0.09) }
        return Color.clear
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
                                // 收藏的歌单/专辑按「收藏夹语义」展示，始终方形
                                // （需求 10：不把 Bilibili 收藏夹强行改成横向 16:9）。
                                OnlineArtwork(url: collection.artworkURL, platform: collection.source)
                                    .aspectRatio(1, contentMode: .fit)
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
