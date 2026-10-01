// HomeView.swift
// Native macOS home surface: resume playback, local library shortcuts and online recommendations.
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var onlineViewModel: OnlineViewModel
    @ObservedObject var libraryViewModel: LibraryViewModel
    var onExplore: () -> Void
    var onLibrary: () -> Void
    var onDownloads: () -> Void

    @State private var snapshot: PlaybackSnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                welcomeHeader
                quickActions
                continueSection
                recommendationSection
                libraryOverview
            }
            .padding(24)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("首页")
        .task(id: appState.playbackStore.map(ObjectIdentifier.init)) {
            guard let store = appState.playbackStore else { snapshot = nil; return }
            for await value in store.observeState() {
                guard !Task.isCancelled else { return }
                snapshot = value
            }
        }
    }

    private var welcomeHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("欢迎回来").font(.largeTitle.weight(.bold))
            Text("从最近播放、在线推荐或本地媒体库继续聆听。").foregroundStyle(.secondary)
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            HomeAction(title: "探索音乐", subtitle: "网易云 · Bilibili · YouTube", systemImage: "safari") { onExplore() }
            HomeAction(title: "打开媒体库", subtitle: "本地曲目与歌单", systemImage: "music.note.list") { onLibrary() }
            HomeAction(title: "查看下载", subtitle: "离线音频与任务", systemImage: "arrow.down.circle") { onDownloads() }
        }
    }

    @ViewBuilder
    private var continueSection: some View {
        if let track = snapshot?.currentTrack {
            HomeSection(title: "继续播放", systemImage: "play.circle.fill") {
                HStack(spacing: 16) {
                    HomeTrackArtwork(track: track).frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title).font(.title3.weight(.semibold)).lineLimit(1)
                        Text(track.artist ?? "未知歌手").foregroundStyle(.secondary).lineLimit(1)
                        Text(snapshot?.isPaused == true ? "已暂停" : (snapshot?.isCoreIdle == true ? "已停止" : "正在播放"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let store = appState.playbackStore {
                        Button { store.togglePlayPause() } label: {
                            Image(systemName: snapshot?.isPaused == false && snapshot?.isCoreIdle == false ? "pause.fill" : "play.fill")
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.borderedProminent)
                        .help("播放或暂停")
                    }
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            HomeSection(title: "开始播放", systemImage: "play.circle") {
                HStack(spacing: 12) {
                    Image(systemName: "music.note.list").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("你的播放队列还是空的")
                        Text("去探索或媒体库选择一首歌曲。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("去探索", action: onExplore).buttonStyle(.bordered)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var recommendationSection: some View {
        HomeSection(title: "在线推荐", systemImage: "sparkles") {
            if onlineViewModel.isLoadingRecommendations && onlineViewModel.recommendations.isEmpty {
                ProgressView("正在加载推荐…").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            } else if onlineViewModel.recommendations.isEmpty {
                HStack {
                    Text(onlineViewModel.account == nil ? "登录平台后可以看到每日推荐。" : "暂时没有推荐内容。").foregroundStyle(.secondary)
                    Spacer()
                    Button("打开探索", action: onExplore).buttonStyle(.bordered)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(Array(onlineViewModel.recommendations.prefix(6))) { song in
                        Button { onlineViewModel.play(song) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                OnlineArtwork(url: song.artworkURL).aspectRatio(1, contentMode: .fit)
                                Text(song.title).font(.callout.weight(.medium)).lineLimit(1)
                                Text(song.artist.isEmpty ? song.source.title : song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("播放「\(song.title)」")
                    }
                }
            }
        }
    }

    private var libraryOverview: some View {
        HomeSection(title: "本地媒体库", systemImage: "music.note.list") {
            HStack(spacing: 12) {
                HomeMetric(value: "\(libraryViewModel.tracks.count)", label: "首曲目")
                HomeMetric(value: "\(libraryViewModel.albumGroups.count)", label: "张专辑")
                HomeMetric(value: "\(libraryViewModel.playlists.count)", label: "个歌单")
                Spacer()
                Button("管理媒体库", action: onLibrary).buttonStyle(.bordered)
            }
        }
    }
}

private struct HomeAction: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct HomeSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
    }
}

private struct HomeMetric: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 86, alignment: .leading)
    }
}

private struct HomeTrackArtwork: View {
    let track: Track
    var body: some View {
        if let url = track.onlineSong?.artworkURL {
            OnlineArtwork(url: url)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
                .overlay(Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary))
        }
    }
}
