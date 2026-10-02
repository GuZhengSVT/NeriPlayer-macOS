// PlayerBarLayout.swift
// NeriPlayer macOS —— 底部播放器栏的档位、按钮排序与「窄窗收进更多菜单」的纯逻辑。
//
// 为什么把布局决策从视图里拿出来：SwiftUI 的 body 一旦掺进「窗口多窄就隐藏哪个按钮」这类判断，
// 就只能靠人眼看真实窗口来验证，改一个阈值要重跑一遍应用。这里把宽度映射成一份
// PlayerBarLayoutPlan（哪些控件内联、哪些收进「更多」菜单、文字行数），是纯函数，可脱离界面直接单测。
//
// 本轮（2026-10-03）排版规格：左信息 / 中控制 / 右动作三区，左右等宽使中区落在整窗水平中心。
// 因此档位关心的不再是「信息列多宽」，而是「右侧动作区还剩几个按钮位」：
//   * 传输组与队列入口**任何宽度都内联**（核心操作 + 打开真实队列列表的唯一入口）；
//   * 右侧其余按钮共 8 个（模式、播完暂停、收藏、加入歌单、桌面歌词、音量、更多，加上恒在的队列），
//     按同一优先级从窄到宽依次回归，窗口变窄时用户不会看到「这次收的是模式、下次收的是音量」。
//   * 曲名下方还有一行「歌手 + 来源 + 规格」和一行当前歌词，最窄档只留标题，保证骨架不挤。
//
// 选单按钮顺序（也是「更多」菜单里的顺序）：
//   音量为先 → 桌面歌词 → 加入歌单 → 收藏 → 播完暂停 → 模式。
// 理由：音量有「更多」里的独立弹层可替代，最该先让位；模式与播完暂停是低频开关，最该留在栏上占位。
//
// 2026-10-03 歌曲播放页整改：删除「打开歌词页」按钮（旧 sheet 导航入口与主窗口 sheet 一并去掉），
// 只保留桌面悬浮歌词入口；歌词改由播放页承载，因此本枚举不再有 .lyrics。

import CoreGraphics

/// 播放器栏里可被「收进更多菜单」的可选控件。cases 顺序即菜单内的展示顺序。
enum PlayerBarOptionalControl: String, CaseIterable {
    case mode
    case pauseAfterCurrent
    case favorite
    case addToPlaylist
    case floatingLyrics
    case volume

    /// 菜单/提示用的中文名。
    var title: String {
        switch self {
        case .mode: return "播放模式"
        case .pauseAfterCurrent: return "播完当前曲暂停"
        case .favorite: return "收藏"
        case .addToPlaylist: return "加入歌单"
        case .floatingLyrics: return "桌面悬浮歌词"
        case .volume: return "音量"
        }
    }
}

/// 一次布局决策的结果。
///
/// 传输组与队列按钮恒为内联，因此不在此结构中；这里只描述「可选项有没有内联」以及内联的次序，
/// 视图按它决定把哪些控件放进 HStack、哪些放进更多菜单。
struct PlayerBarLayoutPlan: Equatable {

    /// 内联展示的可选控件，按上面的顺序排列。
    var inline: [PlayerBarOptionalControl]
    /// 收进「更多」菜单的可选控件，按同一顺序排列。
    var collapsed: [PlayerBarOptionalControl]
    /// 曲目文字区是否展示「歌手 + 来源 + 音频规格」这一行（很窄时只留标题，省一行高度）。
    var showsArtistLine: Bool
    /// 曲目文字区是否再展示一行「当前歌词」。窄档没有多余宽度时收起，避免与曲名抢位置。
    var showsLyricLine: Bool

    /// 某个可选控件是否内联。
    func isInline(_ control: PlayerBarOptionalControl) -> Bool { inline.contains(control) }
}

/// 播放器栏布局的纯函数集合。
enum PlayerBarLayout {

    /// 中间控制区的固定宽度（点）。固定值（而不是 flexible）才能保证：
    /// 左侧信息区与右侧动作区**等宽**时，中区的中心正好落在整窗水平中心，不随左右内容漂移。
    /// 取值 320：进度行「44 + 320 中的进度条 + 44」在 320 内仍有约 220pt 的进度条长度，长度适中。
    static let centerWidth: CGFloat = 320

    /// 宽度档位阈值（点）。主窗口最小宽度 720，常用 1024–1440。
    /// 阈值之间留出余量，避免在临界点来回抖动；档位抬高后不易触发，同时保留窄窗收起的兜底。
    ///
    /// `wideThreshold` 为什么是 1200：宽档右侧要放下 7 个图标按钮 + 音量控件（≈416pt），
    /// 而左右两区各只有「(窗口宽 − 中区 320 − 内边距 28) / 2」。要让右区真装得下，
    /// 窗口至少需要 2×416 + 348 ≈ 1180；取 1200 留出余量。阈值偏低就会重演
    /// 「右区内容超出自己的半区、被裁掉或压到中间」（用户反馈的第 5 点）。
    static let wideThreshold: CGFloat = 1200
    static let regularThreshold: CGFloat = 980
    static let compactThreshold: CGFloat = 840

    /// 由可用宽度给出布局方案。
    static func plan(forWidth width: CGFloat) -> PlayerBarLayoutPlan {
        let safeWidth = width.isFinite ? width : regularThreshold

        // 从宽到窄的四档内联集合。集合本身始终按档位单调收窄（窄档是宽档的子集），
        // 保证 collapsed 单调递增（测试也断言了这一点）。
        let wide: [PlayerBarOptionalControl] = [
            .mode, .pauseAfterCurrent, .favorite, .addToPlaylist, .floatingLyrics, .volume
        ]
        let regular = wide.filter { $0 != .volume }
        let compact = regular.filter { $0 != .floatingLyrics && $0 != .addToPlaylist }
        // 最窄档：模式/收藏/播完暂停也收进更多，栏上只留传输 + 队列 + 更多。
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
