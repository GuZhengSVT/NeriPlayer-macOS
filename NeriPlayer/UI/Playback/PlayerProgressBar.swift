// PlayerProgressBar.swift
// NeriPlayer macOS —— 播放器栏顶部的固定进度条（可拖动跳转）与时间文本。
//
// 为什么自绘而不是用 SwiftUI 的 Slider：Slider 在 macOS 上是较粗的旋钮样式，放进底部栏会挤占
// 高度；而这里要的是一条贴近顶边的细进度条。自绘同时带来两个必要能力：
//   1) 拖动时用本地 scrub 值显示，不因引擎每次 time-pos 回流而把滑块弹回去；
//   2) 时长未知（换歌 / 尚未加载出）时切到「加载中」态而不是消失 —— 这是「防闪」的关键：
//      控件始终在，只是「有曲但时长未出」时切到不确定进度；完全无曲时保持空轨道（不闪跑马灯），
//      两种情况高度都不变，窗口不会跳一下。
//
// 时间文本只显示真实值：时长未知时显示 --:--（与媒体库列表同一约定），不显示 0:00 冒充零秒。

import SwiftUI

// MARK: - 时间文本（纯函数，可单测）

/// 播放器栏的时间文本格式化。
enum PlaybackTimeText {

    /// 把秒格式化成 m:ss / h:mm:ss；非有限或负值按 0 处理。
    static func text(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// 总时长文本；未知（非有限或 ≤0）时显示 --:--，不显示 0:00。
    static func durationText(_ duration: Double) -> String {
        guard duration.isFinite, duration > 0 else { return "--:--" }
        return text(duration)
    }
}

// MARK: - 进度条

/// 顶部固定进度条。轨道始终渲染；有曲但时长未出时显示不确定进度，无曲时只留空轨道。
struct PlayerProgressBar: View {

    /// 引擎报告的当前位置（秒）。
    let position: Double
    /// 引擎报告的时长（秒）；≤0 或非有限表示尚未加载出。
    let duration: Double
    /// 是否有当前曲目。无曲时只画空轨道（不显示加载态的跑马灯）。
    let hasTrack: Bool
    /// 跳转回调，参数为目标秒数。
    let onSeek: (Double) -> Void

    /// 拖动中的临时位置（秒）；nil 表示未在拖动、显示引擎位置。
    @State private var scrubValue: Double?

    /// 时长是否可用（可用才允许拖动跳转）。
    private var hasDuration: Bool { duration.isFinite && duration > 0 }

    /// 当前应显示的播放位置：拖动中优先用拖动值。
    private var displayPosition: Double {
        let raw = scrubValue ?? position
        guard raw.isFinite else { return 0 }
        return min(max(0, raw), hasDuration ? duration : max(0, raw))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            ZStack(alignment: .leading) {
                // 轨道恒在，作为「控件始终存在」的视觉底座。
                Capsule().fill(Color.secondary.opacity(0.18))
                if hasDuration {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: width * fraction(width: width))
                } else if hasTrack {
                    // 有曲但时长未出：不确定进度表示「正在加载/未知时长」。
                    IndeterminateStripe(width: width)
                }
            }
            .frame(height: Self.trackHeight)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(seekGesture(width: width))
            .accessibilityElement()
            .accessibilityLabel("播放进度")
            .accessibilityValue(accessibilityValue)
        }
        .frame(height: Self.totalHeight)
    }

    /// 已播放比例，钳到 0...1。
    private func fraction(width: CGFloat) -> CGFloat {
        guard hasDuration else { return 0 }
        let value = displayPosition / duration
        guard value.isFinite else { return 0 }
        return CGFloat(min(max(value, 0), 1))
    }

    /// 位置 → 秒数 ↔ 手势。只有时长可用时才接受交互（否则拖动没有意义、会得到 NaN）。
    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard hasDuration else { return }
                let x = min(max(0, value.location.x), width)
                scrubValue = Double(x / width) * duration
            }
            .onEnded { value in
                guard hasDuration else { return }
                let x = min(max(0, value.location.x), width)
                let target = Double(x / width) * duration
                scrubValue = nil
                onSeek(target)
            }
    }

    private var accessibilityValue: String {
        let elapsed = PlaybackTimeText.text(displayPosition)
        let total = PlaybackTimeText.durationText(duration)
        return "\(elapsed) / \(total)"
    }

    /// 轨道高度与含命中区域的总高度。
    static let trackHeight: CGFloat = 4
    static let totalHeight: CGFloat = 16
}

// MARK: - 不确定进度（加载态）

/// 时长未知时显示的一段来回移动的高光，表示「正在加载/未知时长」。
///
/// 用 TimelineView 驱动是为了让它在等待期间持续可见（防闪），而不是静止不动被误认为卡死。
/// 只在时长未知时构造，因此不会给正常播放增加逐帧绘制。
private struct IndeterminateStripe: View {
    let width: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let period = 1.4
            let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            let stripeWidth = max(60, width * 0.28)
            let travel = width + stripeWidth
            let offset = CGFloat(progress) * travel - stripeWidth
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: stripeWidth)
                .offset(x: offset)
                .frame(width: width, alignment: .leading)
                .clipped()
        }
    }
}
