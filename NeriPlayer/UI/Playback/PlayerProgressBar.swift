// PlayerProgressBar.swift
// NeriPlayer macOS —— 播放器栏的进度条（点击/拖动跳转）与时间文本。
//
// 为什么自绘而不是用 SwiftUI 的 Slider：Slider 在 macOS 上是较粗的旋钮样式，放进底部栏会挤占
// 高度；而这里要的是一条紧凑的进度条。自绘同时带来三个必要能力：
//   1) 拖动时用本地 scrub 值显示，不因引擎每次 time-pos 回流而把滑块弹回去；
//   2) 松手提交 seek 后保留目标位置，直到引擎报告目标附近的位置 —— 否则 mpv 的旧 position
//      会先回流一帧，进度条会短暂回退再跳过去（用户反馈的「点击进度条闪烁」）；
//   3) 时长未知（换歌 / 尚未加载出）时切到「加载中」态而不是消失 —— 控件始终在，只是显示不确定进度；
//      完全无曲时保持空轨道（不闪跑马灯），两种情况高度都不变，窗口不会跳一下。
//
// 「保留目标值」的判定抽成了 PlayerProgressSeekResolution（纯函数）：这段逻辑最容易出错，
// 又完全不需要界面，独立出来可以脱离 SwiftUI 直接断言。
//
// 时间文本只显示真实值：时长未知时显示 --:--（与媒体库列表同一约定），不显示 0:00 冒充零秒。

import Foundation
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

// MARK: - 待确认的 seek（纯逻辑，可单测）

/// 提交 seek 后「显示哪个位置」的判定结果。
struct PlayerProgressSeekResolution: Equatable {

    /// 本次应显示的播放位置（秒），已钳到 0...duration。
    var displayPosition: Double
    /// 待确认的 seek 是否已被引擎确认（确认为真时调用方应清空 pending 状态）。
    var isConfirmed: Bool

    /// 引擎位置是否已落到目标附近。
    ///
    /// 只看绝对值差：mpv 的 seek 可能先跳到大致位置再精确靠拢，差在容差内即认为到位。
    /// 非有限值（待确认值或引擎位置有一个是 NaN/∞）按「已确认」处理 —— 拿不到可信数字时
    /// 宁可交回引擎，也不要让进度条永久停在一个算不出来的目标上。
    static func isConfirmed(pending: Double, position: Double, tolerance: Double) -> Bool {
        guard pending.isFinite, position.isFinite else { return true }
        return Swift.abs(position - pending) <= max(0, tolerance)
    }

    /// 计算显示位置与确认状态。
    ///
    /// 优先级：拖动值 → 未确认的 seek 目标 → 引擎位置。拖动值永远最高，因为那是用户此刻
    /// 手指的位置；seek 目标只在引擎还没走到附近时接管，一旦确认就交回引擎，避免进度条
    /// 停在旧目标上不动。
    static func resolve(scrub: Double?, pending: Double?, position: Double, duration: Double,
                        tolerance: Double) -> PlayerProgressSeekResolution {
        let confirmed = pending.map { isConfirmed(pending: $0, position: position, tolerance: tolerance) } ?? true
        let raw: Double
        if let scrub {
            raw = scrub
        } else if let pending, !confirmed {
            raw = pending
        } else {
            raw = position
        }
        let safeRaw = raw.isFinite ? max(0, raw) : 0
        // 时长未出（≤0 或非有限）时不设上界，只保证不为负。
        let upper = duration.isFinite && duration > 0 ? duration : safeRaw
        return PlayerProgressSeekResolution(displayPosition: min(safeRaw, max(0, upper)), isConfirmed: confirmed)
    }
}

// MARK: - 进度条

/// 播放器栏进度条。轨道始终渲染；有曲但时长未出时显示不确定进度，无曲时只留空轨道。
///
/// 点击与拖动走同一个手势（minimumDistance: 0），因此「点一下跳到某处」与「按住拖到某处」
/// 行为一致；命中区域是整个总高度（见 totalHeight），而不是那条细轨道。
struct PlayerProgressBar: View {

    /// 引擎报告的当前位置（秒）。
    let position: Double
    /// 引擎报告的时长（秒）；≤0 或非有限表示尚未加载出。
    let duration: Double
    /// 是否有当前曲目。无曲时只画空轨道（不显示加载态的跑马灯）。
    let hasTrack: Bool
    /// 当前曲目 id。切歌时清空拖动与待确认状态，避免把上一首的目标值带到新曲。
    let trackID: UUID?
    /// 跳转回调，参数为目标秒数。
    let onSeek: (Double) -> Void

    /// 拖动中的临时位置（秒）；nil 表示未在拖动、显示引擎位置。
    @State private var scrubValue: Double?
    /// 已提交、等引擎确认的 seek 目标（秒）。
    @State private var pendingSeek: Double?
    /// 待确认状态的过期时刻：引擎长时间没给出目标附近的报告（seek 被拒 / 文件已换）时放弃目标值，
    /// 否则进度条会一直卡在一个到不了的位置。
    @State private var pendingDeadline: Date?
    /// 过期看门狗的重启标识（task(id:) 靠它重新计时）。
    @State private var pendingToken = 0

    /// 时长是否可用（可用才允许拖动跳转）。
    private var hasDuration: Bool { duration.isFinite && duration > 0 }

    /// 引擎位置与目标的容差（秒）。太小会被 mpv 的量化误差卡住（目标迟迟不确认，进度条停在旧值），
    /// 太大则「回退感」重新出现；1.5s 小于用户能感知到的一次跳转，又大于 mpv 常见的一次 seek 误差。
    static let confirmationTolerance: Double = 1.5
    /// 待确认状态的最长保留时间（秒）。超过就认为这次 seek 不会到位，交回引擎值。
    static let pendingLifetime: TimeInterval = 6

    /// 当前解析结果：显示位置 + 待确认是否已被引擎确认。
    private var resolution: PlayerProgressSeekResolution {
        PlayerProgressSeekResolution.resolve(scrub: scrubValue, pending: pendingSeek, position: position,
                                             duration: duration, tolerance: Self.confirmationTolerance)
    }

    private var displayPosition: Double { resolution.displayPosition }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            ZStack(alignment: .leading) {
                // 轨道恒在，作为「控件始终存在」的视觉底座。播放中的 seek 不改变它 ——
                // 只有「有曲但时长未知」才切加载态，点击本身不会让整条轨道变成加载占位。
                Capsule().fill(Color.secondary.opacity(0.18))
                if hasDuration {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: width * fraction)
                } else if hasTrack {
                    // 有曲但时长未出：不确定进度表示「正在加载/未知时长」。
                    IndeterminateStripe(width: width)
                }
                // 滑块：只在时长可用时出现，跟随显示位置（拖动 / 待确认目标 / 引擎值）。
                if hasDuration {
                    // 前端点做成一根竖向小胶囊，与进度条前端相接，比圆点在小尺寸下更清晰。
                    Capsule()
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                        .overlay(Capsule().fill(.ultraThinMaterial))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .frame(width: Self.knobWidth, height: Self.knobHeight)
                        .offset(x: knobOffset(width: width))
                }
            }
            .frame(height: Self.trackHeight)
            .frame(maxHeight: .infinity)
            // 命中区域是整块高度（而不是细轨道本身）：点击更容易命中，与拖动手势共用。
            .contentShape(Rectangle())
            .gesture(seekGesture(width: width))
            .accessibilityElement()
            .accessibilityLabel("播放进度")
            .accessibilityValue(accessibilityValue)
        }
        .frame(height: Self.totalHeight)
        // 引擎走到目标附近即交回引擎值；否则进度条会一直显示旧目标。
        .onChange(of: position) { _ in confirmPendingIfReached() }
        // 切歌：拖动状态与待确认目标都属于上一首，必须清空。
        .onChange(of: trackID) { _ in resetPendingState() }
        // 过期看门狗：等待超过 pendingLifetime 仍未确认时放弃目标值。
        .task(id: pendingToken) { await expirePendingWhenDue() }
    }

    /// 已播放比例，钳到 0...1。
    private var fraction: CGFloat {
        guard hasDuration else { return 0 }
        let value = displayPosition / duration
        guard value.isFinite else { return 0 }
        return CGFloat(min(max(value, 0), 1))
    }

    /// 滑块的水平偏移：竖条的右缘贴住进度前端。
    private func knobOffset(width: CGFloat) -> CGFloat {
        let usable = max(0, width - Self.knobWidth)
        return usable * fraction
    }

    /// 位置 → 秒数 ↔ 手势。只有时长可用时才接受交互（否则拖动没有意义、会得到 NaN）。
    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard hasDuration else { return }
                scrubValue = seconds(atX: value.location.x, width: width)
            }
            .onEnded { value in
                guard hasDuration else { return }
                let target = seconds(atX: value.location.x, width: width)
                // 目标立刻接管显示并保留到引擎确认，中间不会闪回旧 position —— 这是「点击闪烁」的根因修复。
                scrubValue = nil
                pendingSeek = target
                pendingDeadline = Date().addingTimeInterval(Self.pendingLifetime)
                pendingToken &+= 1
                onSeek(target)
            }
    }

    private func seconds(atX x: CGFloat, width: CGFloat) -> Double {
        let clamped = min(max(0, x), width)
        return Double(clamped / width) * duration
    }

    /// 引擎位置已到目标附近时清掉待确认状态，之后的显示完全交给引擎。
    private func confirmPendingIfReached() {
        guard pendingSeek != nil, resolution.isConfirmed else { return }
        pendingSeek = nil
        pendingDeadline = nil
    }

    /// 等待到截止时刻后放弃未确认的目标。task(id:) 在 token 变化时自动取消旧任务。
    private func expirePendingWhenDue() async {
        guard let deadline = pendingDeadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        guard !Task.isCancelled else { return }
        pendingSeek = nil
        pendingDeadline = nil
    }

    private func resetPendingState() {
        scrubValue = nil
        pendingSeek = nil
        pendingDeadline = nil
        pendingToken &+= 1
    }

    private var accessibilityValue: String {
        let elapsed = PlaybackTimeText.text(displayPosition)
        let total = PlaybackTimeText.durationText(duration)
        return "\(elapsed) / \(total)"
    }

    /// 轨道高度、前端点尺寸与含命中区域的总高度。
    ///
    /// 轨道从 4pt 加到 5pt、总高从 16 加到 18：拖动时要看得见位置，同时让整块命中区域
    /// （总高 18pt）明显大于细轨道，点击不必瞄准。
    static let trackHeight: CGFloat = 5
    static let knobWidth: CGFloat = 4
    static let knobHeight: CGFloat = 13
    static let totalHeight: CGFloat = 18
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
