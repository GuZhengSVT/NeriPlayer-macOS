// MiniPlayerView.swift
// M8-T1/T5: compact menu-bar player with artwork/title and swipe navigation.
import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var snapshot: PlaybackSnapshot?
    @State private var observation: Task<Void, Never>?

    var body: some View {
        Group {
            if let store = appState.playbackStore {
                content(store: store)
                    .task(id: ObjectIdentifier(store)) {
                        for await value in store.observeState() { snapshot = value }
                    }
            } else { Text("播放器尚未就绪") }
        }
        .frame(width: 280)
    }

    @ViewBuilder
    private func content(store: PlaybackStateStore) -> some View {
        let track = snapshot?.currentTrack
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .frame(width: 38, height: 38).background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? "未播放").lineLimit(1)
                    Text(track?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack {
                Button { store.previous() } label: { Image(systemName: "backward.end.fill") }.help("上一首")
                Spacer()
                Button { store.togglePlayPause() } label: { Image(systemName: snapshot?.isPaused == false ? "pause.fill" : "play.fill") }.help("播放或暂停")
                Spacer()
                Button { store.next(force: true) } label: { Image(systemName: "forward.end.fill") }.help("下一首")
            }
            .buttonStyle(.borderless)
            HStack {
                Button { appState.toggleFloatingLyrics() } label: { Label("悬浮歌词", systemImage: "text.aligncenter") }
                    .disabled(appState.lyricsViewModel == nil)
                Spacer()
                Button("打开主窗口") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
            }
                .buttonStyle(.plain)
        }
        .padding(12)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.width < 0 { store.next(force: true) }
            if value.translation.width > 0 { store.previous() }
        })
    }
}
