// PlaybackStatusBar.swift
// NeriPlayer macOS —— 播放状态条与随机播放选择（移植规划 M2-T8）。
//
// 为什么单独成文件而不是塞进 LibraryView：这条状态条不依赖媒体库的任何数据，只订阅
// PlaybackStateStore 的快照。后续「首页/下载/设置」tab 也可能挂同一条，独立成视图比
// 复制一遍 LibraryView.statusBar 更省事，也让「快照 → 文案」这段映射能脱离 SwiftUI 单测。
//
// 订阅模型（M2-T8 的显式要求）：@MainActor 的 @State 只保存「快照结构体」与「文案」，
// 由 .task 起一条 AsyncStream 消费循环订阅 observeState()。每次收到快照就整块替换文字，
// 不在 body 里读 playbackStore 的可变属性，也不按进度/位置重算 —— 位置与时长不参与文案，
// 于是引擎每帧报进度时 publish() 因快照未变而不广播（见 PlaybackStateStore.publish 的
// 相等短路），状态条自然不会被播放进度带着刷新。
//
// 播放入口与状态显示用的是同一个 currentTrack：队列是「该播什么」的真源，状态条显示的
// 就是队列当前曲，因此「入队即播」「下一首播放」这些动作不需要视图另外同步一次。

import SwiftUI

// MARK: - 文案映射（可脱离 SwiftUI 单测）

/// 把播放快照映射成状态条文案。纯函数，输入输出都是值类型。
enum PlaybackStatusText {

    /// 队列为空或无当前曲：不显示任何文字（整条状态条对用户不可见）。
    static func text(for snapshot: PlaybackSnapshot) -> String? {
        guard let track = snapshot.currentTrack else { return nil }
        let artist = displayArtist(track.artist)
        let state = stateLabel(isPaused: snapshot.isPaused, isCoreIdle: snapshot.isCoreIdle)
        return "\(state) · \(track.title) — \(artist)"
    }

    /// 播放状态的短标签。空闲态优先于暂停态判断：自然播完/已停止时 engine 会把暂停复位为
    /// false，若先看 isPaused 就会把「已停止」显示成「播放中」。
    static func stateLabel(isPaused: Bool, isCoreIdle: Bool) -> String {
        if isCoreIdle { return "已停止" }
        return isPaused ? "已暂停" : "正在播放"
    }

    /// 歌手缺失时回落「未知歌手」；与媒体库列表的占位写法保持一致。
    static func displayArtist(_ artist: String?) -> String {
        guard let artist else { return "未知歌手" }
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未知歌手" : trimmed
    }
}

// MARK: - 状态条

/// 底部播放状态条：订阅 PlaybackStateStore 快照，显示「状态 · 曲名 — 歌手」，点击切到媒体库 tab。
struct PlaybackStatusBar: View {

    /// 点击状态条的动作（通常是把主窗口切到媒体库 tab）。为 nil 时整条不可点。
    var onActivate: (() -> Void)?

    @EnvironmentObject private var appState: AppState
    /// 当前订阅的播放内存态。为什么不直接读 appState.playbackStore：播放集成可能晚于本视图出现
    /// （启动顺序是「探测崩溃 → 播放集成 → 媒体库」），而 @EnvironmentObject 只在对象本身变化时
    /// 通知视图，store 字段被填充不会触发重算。这里用 onReceive 盯住这个 @Published 字段，
    /// 落到本地 @State 上，再把订阅键交给 .task —— 两个时刻谁先谁后都能接上。
    @State private var playbackStore: PlaybackStateStore?
    /// 最近一次收到的快照。仅作为「文案映射」的输入，视图不从这里回读实时属性。
    @State private var snapshot: PlaybackSnapshot?

    var body: some View {
        Group {
            if let text = snapshot.flatMap(PlaybackStatusText.text) {
                bar(text: text)
            }
        }
        .onReceive(appState.$playbackStore) { playbackStore = $0 }
        .task(id: playbackStore.map(ObjectIdentifier.init)) {
            // id 用 store 的对象标识：播放集成未就绪（nil）时这条 task 立刻结束；
            // store 出现或换成另一个实例时 id 变化，task 重跑并接到新的快照流上。
            guard let store = playbackStore else { return }
            for await next in store.observeState() {
                snapshot = next
            }
        }
    }

    private func bar(text: String) -> some View {
        VStack(spacing: 0) {
            // 分隔线放在状态条内部：没有当前曲时整条不渲染，也就不会在窗口底部留一条孤线。
            Divider()
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { onActivate?() }
            .help(onActivate == nil ? text : "查看当前播放")
        }
    }

    /// 暂停/停止/播放三种图标；空闲优先于暂停，理由同 PlaybackStatusText.stateLabel。
    private var iconName: String {
        guard let snapshot, !snapshot.isCoreIdle else { return "stop.circle" }
        return snapshot.isPaused ? "pause.circle" : "play.circle"
    }
}
