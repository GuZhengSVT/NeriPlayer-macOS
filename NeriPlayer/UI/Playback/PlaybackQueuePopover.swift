// PlaybackQueuePopover.swift
// NeriPlayer macOS —— 队列按钮打开的真实「当前播放列表」弹层。
//
// 目标（对应用户要求「队列按钮打开真正当前歌曲列表，可跳播/移除，而不是跳媒体库」）：
//   - 数据源是播放队列本身（PlaybackSnapshot.queue），不是媒体库；
//   - 点某一首 = 跳播（store.jump(toQueueIndex:)），不产生入队/追加之类的副作用；
//   - 每行可移除（store.removeFromQueue(at:)），移除当前曲由内核负责接着播下一首；
//   - 当前曲有明确标记，打开时滚动到当前曲。
//
// 订阅模型与 FloatingPlayerBar 一致：快照由外部传入，本视图不持有 store 的实时属性，
// 因此队列内容变化（跳播/移除/自动推进）都会经由同一份快照重新渲染。

import SwiftUI

struct PlaybackQueuePopover: View {

    /// 队列快照（含内容、当前索引、模式、随机序列）。
    let queue: QueueState
    /// 跳到某下标并播放。
    let onJump: (Int) -> Void
    /// 移除某下标的曲目。
    let onRemove: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if queue.tracks.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Text("播放队列").font(.headline)
            Text("\(queue.tracks.count) 首").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(modeLabel).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// 当前播放模式的中文名；随机模式额外显示「（随机）」以区别于列表顺序。
    private var modeLabel: String {
        switch queue.mode {
        case .sequential: return "顺序播放"
        case .repeatAll: return "列表循环"
        case .repeatOne: return "单曲循环"
        case .shuffle: return "随机播放"
        }
    }

    // MARK: - 列表

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // 身份用下标而不是 track.id：同一首歌可能被入队两次（重复 id），
                    // 用 id 做 diff 会产生未定义行为；队列顺序本身稳定，下标是可靠身份。
                    ForEach(Array(queue.tracks.enumerated()), id: \.offset) { index, track in
                        row(index: index, track: track)
                            .id(index)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 320)
            .onAppear { scrollToCurrent(proxy, animated: false) }
            // 当前曲变化（换歌/点播）时把选中行带回可见区。
            .onChange(of: queue.currentIndex) { _ in scrollToCurrent(proxy, animated: true) }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let index = queue.currentIndex else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
        } else {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    /// 渲染队列中的一行。当前曲有高亮条与强调色底，双击/单击都跳播。
    private func row(index: Int, track: Track) -> some View {
        let isCurrent = queue.currentIndex == index
        return HStack(spacing: 8) {
            // 当前曲左侧高亮条；非当前曲留同宽占位保持对齐。
            RoundedRectangle(cornerRadius: 1)
                .fill(isCurrent ? Color.accentColor : Color.clear)
                .frame(width: 3, height: 22)
            // 需求 10：有平台身份的曲目显示封面缩略图，Bilibili 走 16:9 横向容器并完整显示原图。
            // 本地曲没有在线身份，保持原来的纯文字行，不给每一首都塞一个占位方块。
            if let song = track.onlineSong {
                OnlineArtworkThumbnail(url: song.artworkURL, platform: song.source, height: 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).lineLimit(1)
                    .font(isCurrent ? .callout.weight(.semibold) : .callout)
                Text(artistText(track))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(PlaybackTimeText.durationText(track.duration ?? .nan))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button {
                onRemove(index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("从队列移除")
            .accessibilityLabel("从队列移除 \(track.title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // 双击/单击都跳播：弹层里点一行就是「播这首」，与列表页的双击习惯不冲突。
        .onTapGesture { onJump(index) }
        .background(isCurrent ? Color.accentColor.opacity(0.10) : Color.clear)
    }

    private func artistText(_ track: Track) -> String {
        guard let artist = track.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty else {
            return "未知歌手"
        }
        return artist
    }

    // MARK: - 空态与底部

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note.list").font(.system(size: 22)).foregroundStyle(.secondary)
            Text("队列为空").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack {
            Text("点条目播放 · 点移除从队列删除")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
