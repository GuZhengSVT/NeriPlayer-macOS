// OnlinePlaybackStatusView.swift
// M5: compact source-resolution state and fallback source indication.
import SwiftUI

struct OnlinePlaybackStatusView: View {
    @ObservedObject var coordinator: OnlinePlaybackCoordinator
    var body: some View {
        if coordinator.currentSong != nil {
            HStack(spacing: 8) {
                if coordinator.phase == .resolving { ProgressView().controlSize(.small) }
                Image(systemName: "network").foregroundStyle(.secondary)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).padding(.vertical, 4)
        }
    }
    private var label: String {
        switch coordinator.phase {
        case .resolving: return "正在解析音源"
        case .playing:
            let source = coordinator.currentResolvedAudio?.song.source.title ?? ""
            return coordinator.currentResolvedAudio?.song.source == coordinator.currentSong?.source ? source : "已切换音源：\(source)"
        case .failed, .skipped: return coordinator.lastError ?? "音源不可用"
        case .idle: return ""
        }
    }
}
