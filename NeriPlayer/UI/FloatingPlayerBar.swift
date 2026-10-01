// FloatingPlayerBar.swift
// Persistent bottom player controls for the macOS window.
import SwiftUI

struct FloatingPlayerBar: View {
    @EnvironmentObject private var appState: AppState
    var onLyrics: () -> Void
    var onOpenQueue: () -> Void
    @State private var snapshot: PlaybackSnapshot?

    var body: some View {
        Group {
            if let store = appState.playbackStore, let snapshot, snapshot.currentTrack != nil {
                bar(store: store, snapshot: snapshot)
            }
        }
        .onReceive(appState.$playbackStore) { store in
            if store == nil { snapshot = nil }
        }
        .task(id: appState.playbackStore.map(ObjectIdentifier.init)) {
            guard let store = appState.playbackStore else { snapshot = nil; return }
            for await value in store.observeState() {
                guard !Task.isCancelled else { return }
                snapshot = value
            }
        }
    }

    private func bar(store: PlaybackStateStore, snapshot: PlaybackSnapshot) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                PlayerBarArtwork(track: snapshot.currentTrack)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.currentTrack?.title ?? "未播放").font(.callout.weight(.semibold)).lineLimit(1)
                    Text(snapshot.currentTrack?.artist ?? "未知歌手").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 190, alignment: .leading)
                Spacer(minLength: 8)
                Button { store.previous() } label: { Image(systemName: "backward.end.fill") }.help("上一首")
                Button { store.togglePlayPause() } label: {
                    Image(systemName: snapshot.isPaused == false && snapshot.isCoreIdle == false ? "pause.fill" : "play.fill")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderedProminent)
                .help("播放或暂停")
                Button { store.next(force: true) } label: { Image(systemName: "forward.end.fill") }.help("下一首")
                Spacer(minLength: 8)
                Button(action: onLyrics) { Image(systemName: "text.alignleft") }.help("打开歌词")
                Button(action: onOpenQueue) { Image(systemName: "music.note.list") }.help("打开播放列表")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if snapshot.duration > 0 {
                ProgressView(value: min(max(snapshot.position / snapshot.duration, 0), 1))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
        }
        .background(.regularMaterial)
        .contentShape(Rectangle())
    }
}

private struct PlayerBarArtwork: View {
    let track: Track?
    var body: some View {
        if let url = track?.onlineSong?.artworkURL {
            OnlineArtwork(url: url)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
    }
}
