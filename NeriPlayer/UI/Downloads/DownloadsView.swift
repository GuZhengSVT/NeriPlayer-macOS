// DownloadsView.swift
// M6: dense download queue with pause/resume/retry, file deletion and storage cleanup.
import AppKit
import SwiftUI

struct DownloadsView: View {
    @ObservedObject var viewModel: DownloadViewModel
    @EnvironmentObject private var appState: AppState
    var navigationTitleOverride: String? = nil
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("下载", systemImage: "arrow.down.circle")
                    .font(.headline)
                Spacer()
                Text("文件 \(byteLabel(viewModel.storageBytes)) · 缓存 \(byteLabel(viewModel.cacheBytes))")
                    .font(.caption).foregroundStyle(.secondary)
                Button { viewModel.clearCache() } label: { Image(systemName: "eraser") }
                    .help("清理播放缓存")
                Button { viewModel.clearHistory() } label: { Image(systemName: "trash") }
                    .help("清理已取消记录和临时文件")
            }.padding(12)
            HStack(spacing: 12) {
                Text("已下载 \(byteLabel(viewModel.usage.downloads)) · 临时文件 \(byteLabel(viewModel.usage.working))")
                Text("播放缓存 \(byteLabel(viewModel.usage.playbackCache)) / 2 GiB · 封面 \(byteLabel(viewModel.usage.artworkCache))")
                Spacer(minLength: 0)
                Button("清理封面") { viewModel.clearArtworkCache() }
            }.font(.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom], 12)
            Divider()
            if viewModel.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("暂无下载").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.items) { item in row(item) }.listStyle(.plain)
            }
        }
        .navigationTitle(navigationTitleOverride ?? "下载")
        .onAppear { viewModel.refreshStorage() }
        .alert("下载", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.clearError() } })) {
            Button("好", role: .cancel) { viewModel.clearError() }
        } message: { Text(viewModel.errorMessage ?? "") }
    }

    private func row(_ item: AudioDownload) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(item.status)).foregroundStyle(item.status == .failed ? .red : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.song.title).lineLimit(1)
                Text([item.song.artist, item.song.source.title, item.status.title].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if item.status.isActive, let progress = item.progress {
                    ProgressView(value: progress)
                }
                if let message = item.message, !message.isEmpty { Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            if let total = item.total, item.received > 0 {
                Text("\(byteLabel(item.received))/\(byteLabel(total))")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            controls(item)
        }.padding(.vertical, 5)
    }

    @ViewBuilder private func controls(_ item: AudioDownload) -> some View {
        if item.status == .completed {
            Button {
                Task {
                    guard let file = await viewModel.completedFile(for: item) else { return }
                    appState.playbackStore?.playTrack(Track(url: file, title: item.song.title,
                        artist: item.song.artist, duration: item.song.duration))
                }
            } label: { Image(systemName: "play.fill") }
                .help("播放已下载文件").accessibilityLabel("播放 \(item.song.title)")
                .disabled(appState.playbackStore == nil)
            Button {
                Task {
                    guard let file = await viewModel.completedFile(for: item) else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            } label: { Image(systemName: "folder") }
                .help("在 Finder 中显示").accessibilityLabel("在 Finder 中显示 \(item.song.title)")
        }
        if item.status.isActive || item.status == .queued || item.status == .waiting {
            Button { viewModel.pause(item) } label: { Image(systemName: "pause.fill") }.help("暂停")
        } else if item.status == .paused || item.status == .failed {
            Button { viewModel.resume(item) } label: { Image(systemName: "arrow.clockwise") }.help("继续")
        }
        if [.completed, .cancelled, .failed, .paused].contains(item.status) {
            Button(role: .destructive) { viewModel.delete(item) } label: { Image(systemName: "trash") }.help("删除")
        } else {
            Button(role: .destructive) { viewModel.cancel(item) } label: { Image(systemName: "xmark") }.help("取消")
        }
    }

    private func icon(_ status: DownloadStatus) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "minus.circle"
        case .paused: return "pause.circle"
        default: return "arrow.down.circle"
        }
    }
    private func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
