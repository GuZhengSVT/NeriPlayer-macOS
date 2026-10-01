// PlayerBarLayout.swift
// NeriPlayer macOS —— 底部播放器栏的分组、排序与「窄窗收进更多菜单」的纯逻辑。
//
// 为什么把布局决策从视图里拿出来：SwiftUI 的 body 一旦掺进「窗口多窄就隐藏哪个按钮」这类判断，
// 就只能靠人眼看真实窗口来验证，改一个阈值要重跑一遍应用。这里把宽度映射成一份
// PlayerBarLayoutPlan（哪些控件内联、哪些收进「更多」菜单），是纯函数，可脱离界面直接单测。
//
// 分组与排序（对应用户「先分组排序」的要求）：固定的组顺序决定视觉分区，同一组内按钮相邻且顺序稳定，
// 不因窗口变窄而互相穿插：
//   1) 传输组：上一首 / 播放暂停 / 下一首（核心操作，任何宽度都内联）；
//   2) 模式组：一个播放模式按钮（顺序/列表循环/单曲循环/随机循环切换）；
//   3) 收藏组：收藏当前曲、加入歌单；
//   4) 展示组：歌词（主窗口）、悬浮歌词（桌面浮窗）；
//   5) 队列组：队列（恒内联，它是打开真实队列列表的入口）；
//   6) 音量组：应用音量条。
// 收进更多菜单的次序固定为 音量 → 悬浮歌词 → 歌词 → 收藏/歌单 → 模式，窗口变窄时用户不会看到
// 「这次收的是模式、下次收的是音量」这类跳跃。

import CoreGraphics

/// 播放器栏里可被「收进更多菜单」的可选控件。cases 顺序即菜单内的展示顺序。
enum PlayerBarOptionalControl: String, CaseIterable {
    case mode
    case pauseAfterCurrent
    case favorite
    case addToPlaylist
    case lyrics
    case floatingLyrics
    case volume

    /// 菜单/提示用的中文名。
    var title: String {
        switch self {
        case .mode: return "播放模式"
        case .pauseAfterCurrent: return "播完当前曲暂停"
        case .favorite: return "收藏"
        case .addToPlaylist: return "加入歌单"
        case .lyrics: return "歌词"
        case .floatingLyrics: return "悬浮歌词"
        case .volume: return "音量"
        }
    }
}

/// 一次布局决策的结果。
///
/// 传输组与队列按钮恒为内联，因此不在此结构中；这里只描述「可选项有没有内联」以及内联的次序，
/// 视图按它决定把哪些控件放进 HStack、哪些放进更多菜单。
struct PlayerBarLayoutPlan: Equatable {

    /// 内联展示的可选控件，按上面的组顺序排列。
    var inline: [PlayerBarOptionalControl]
    /// 收进「更多」菜单的可选控件，按同一顺序排列。
    var collapsed: [PlayerBarOptionalControl]
    /// 曲目文字区是否展示歌手行（很窄时只留标题，省一行高度）。
    var showsArtistLine: Bool
    /// 是否在信息区与大按钮之间的空白里展示当前歌词行。
    ///
    /// 歌词占据的是「中间 flexible 区域」：宽窗时它把曲目信息与右侧按钮之间的空白填满，
    /// 窄窗没有多余空白时才收起，避免与控件抢位置。
    var showsLyricLine: Bool

    /// 某个可选控件是否内联。
    func isInline(_ control: PlayerBarOptionalControl) -> Bool { inline.contains(control) }
}

/// 播放器栏布局的纯函数集合。
enum PlayerBarLayout {

    /// 宽度档位阈值（点）。取值来自常见窗口尺寸的取舍：主窗口最小 720，常用 1024；
    /// 阈值之间留出余量，避免在临界点反复抖动。
    static let wideThreshold: CGFloat = 980
    static let regularThreshold: CGFloat = 860
    static let compactThreshold: CGFloat = 760

    /// 由可用宽度给出布局方案。
    static func plan(forWidth width: CGFloat) -> PlayerBarLayoutPlan {
        let safeWidth = width.isFinite ? width : regularThreshold

        // 从宽到窄的四档内联集合，逐级削减。
        let wide: [PlayerBarOptionalControl] = [
            .mode, .pauseAfterCurrent, .favorite, .addToPlaylist, .lyrics, .floatingLyrics, .volume
        ]
        let regular = wide.filter { $0 != .volume }
        let compact = regular.filter { $0 != .floatingLyrics && $0 != .lyrics }
        // 最窄档：模式与收藏也收进更多，栏上只留传输 + 队列 + 更多。
        let narrow: [PlayerBarOptionalControl] = []

        let inline: [PlayerBarOptionalControl]
        let showsArtistLine: Bool
        let showsLyricLine: Bool

        if safeWidth >= wideThreshold {
            inline = wide
            showsArtistLine = true
            showsLyricLine = true
        } else if safeWidth >= regularThreshold {
            inline = regular
            showsArtistLine = true
            showsLyricLine = true
        } else if safeWidth >= compactThreshold {
            inline = compact
            showsArtistLine = true
            showsLyricLine = false
        } else {
            inline = narrow
            showsArtistLine = false
            showsLyricLine = false
        }

        let collapsed = PlayerBarOptionalControl.allCases.filter { !inline.contains($0) }
        return PlayerBarLayoutPlan(
            inline: inline,
            collapsed: collapsed,
            showsArtistLine: showsArtistLine,
            showsLyricLine: showsLyricLine
        )
    }
}
