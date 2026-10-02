// AppTypography.swift
// 需求 5：统一字体接口（外观与个性化 → 实际字体）。
//
// 这份文件是「设置项」与「真实字体」之间唯一的转换点：
//   - AppearanceSettings / SettingsStore 只存字符串与数字，不认识 SwiftUI；
//   - AppTypography 把家族标识与字号解析成 Font，并通过 EnvironmentValues 下发；
//   - A / C 在自己的视图里用 @Environment(\.appTypography) 取字体，不再各自读 SettingsStore 拼字体。
//
// 为什么字体家族用一个哨兵字符串而不是空串：「系统字体」是一个真实可选值，
// 用 "__neri_system__" 表达它，就与「从未设置过」（空串）区分得开；未知家族
// （用户装了又卸载字体、或设置来自更早/更晚版本）一律回落到系统字体，界面始终能渲染。
//
// 为什么 root 字体在这里应用（AppTypographyModifier）：SwiftUI 的 .font 是环境修饰符，
// 一处设在根上，全部未显式指定字体的文本都会跟随；显式 .font(.caption) 的子视图仍然优先。

import AppKit
import SwiftUI

// MARK: - 本机可用字体家族

/// `TypographyFontFamily` 的 AppKit 扩展：枚举本机字体需要 `NSFontManager`，
/// 因此放在 UI 层，Core 侧的设置层只依赖 Foundation。
public extension TypographyFontFamily {

    /// 本机可用字体家族，按名称排序。
    /// 只在设置页打开时调用（`NSFontManager` 是 AppKit 主线程 API）。
    @MainActor
    static func availableFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 把持久化的家族标识夹到本机可用集合：空值或未知家族回落到系统字体。
    @MainActor
    static func resolved(_ stored: String) -> String {
        resolved(stored, available: Set(availableFamilies()))
    }
}

// MARK: - 排版值

/// 一次字体设置的快照。视图通过 `@Environment(\.appTypography)` 读取。
///
/// `uiScale` / `playerTextSize` / `compactLyricsSize` 是文档约定的接口字段，A / C 直接使用；
/// 其余字段供歌词侧（字号 + 字体家族）使用。
public struct AppTypography: Equatable {

    /// UI 基础字号相对默认 14pt 的缩放比例。
    public var uiScale: CGFloat
    /// 播放器字号（已换算成点值，不再是缩放比例）。
    public var playerTextSize: CGFloat
    /// 底部歌词字号（已换算成点值）。
    public var compactLyricsSize: CGFloat
    /// UI 字体家族标识（``TypographyFontFamily/systemID`` 表示系统字体）。
    public var uiFontFamily: String
    /// 歌词字体家族标识。
    public var lyricsFontFamily: String
    /// 歌词基础字号（点值）。
    public var lyricsBaseSize: CGFloat

    /// UI 缩放的基准字号（默认 14pt）。
    public static let baseFontSize: CGFloat = CGFloat(AppTypographyDefaults.uiBaseSize)

    public init(
        uiScale: CGFloat = 1,
        playerTextSize: CGFloat = CGFloat(AppTypographyDefaults.playerTextSize),
        compactLyricsSize: CGFloat = CGFloat(AppTypographyDefaults.compactLyricsSize),
        uiFontFamily: String = TypographyFontFamily.systemID,
        lyricsFontFamily: String = TypographyFontFamily.systemID,
        lyricsBaseSize: CGFloat = CGFloat(AppTypographyDefaults.lyricsBaseSize)
    ) {
        self.uiScale = uiScale.isFinite ? uiScale : 1
        self.playerTextSize = playerTextSize
        self.compactLyricsSize = compactLyricsSize
        self.uiFontFamily = uiFontFamily
        self.lyricsFontFamily = lyricsFontFamily
        self.lyricsBaseSize = lyricsBaseSize
    }

    /// 从设置页视图模型构造：字号夹取后换算，家族标识解析到本机可用集合。
    ///
    /// 家族可用性直接用视图模型启动时取好的那份列表，不在 body 里再枚举一次字体目录 ——
    /// 拖字号滑杆时 body 会高频重算，反复走 NSFontManager 会造成可见卡顿。
    @MainActor
    public init(model: SettingsViewModel?) {
        guard let model else { self = AppTypography(); return }
        let available = Set(model.availableFontFamilies + [TypographyFontFamily.systemID])
        let base = AppTypographyDefaults.clamped(
            model.uiBaseFontSize, in: AppTypographyDefaults.uiBaseSizeRange, fallback: AppTypographyDefaults.uiBaseSize)
        self.init(
            uiScale: CGFloat(base / AppTypographyDefaults.uiBaseSize),
            playerTextSize: CGFloat(AppTypographyDefaults.clamped(
                model.playerFontSize, in: AppTypographyDefaults.playerTextSizeRange,
                fallback: AppTypographyDefaults.playerTextSize)),
            compactLyricsSize: CGFloat(AppTypographyDefaults.clamped(
                model.compactLyricsFontSize, in: AppTypographyDefaults.compactLyricsSizeRange,
                fallback: AppTypographyDefaults.compactLyricsSize)),
            uiFontFamily: TypographyFontFamily.resolved(model.uiFontFamily, available: available),
            lyricsFontFamily: TypographyFontFamily.resolved(model.lyricsFontFamily, available: available),
            lyricsBaseSize: CGFloat(AppTypographyDefaults.clamped(
                model.lyricsFontSize, in: AppTypographyDefaults.lyricsBaseSizeRange,
                fallback: AppTypographyDefaults.lyricsBaseSize))
        )
    }

    // MARK: 字号换算
    //
    // 这里刻意区分「真实点值」与「相对基准的点值」两类接口：
    //   - 调用点已经持有真实点值时（例如 LyricsView 传入的 `model.fontSize` 本身就是设置后的 pt），
    //     用 size 系列，绝不再次缩放 —— 否则会双重缩放；
    //   - 调用点持有的是「28pt 基准下的设计值」时（例如播放器默认标题 17pt、底部歌词默认 18pt），
    //     用 scaledFromBase 系列，让设置在此处生效。

    /// 歌词字号相对默认 28pt 的缩放比例。
    public var lyricsScale: CGFloat {
        lyricsBaseSize.isFinite && lyricsBaseSize > 0 ? lyricsBaseSize / CGFloat(AppTypographyDefaults.lyricsBaseSize) : 1
    }

    /// 播放器字号相对默认 17pt 的缩放比例。
    public var playerScale: CGFloat {
        playerTextSize.isFinite && playerTextSize > 0 ? playerTextSize / CGFloat(AppTypographyDefaults.playerTextSize) : 1
    }

    /// 把「28pt 基准下的设计点值」换算成实际点值。
    public func scaledLyricSize(_ base: CGFloat) -> CGFloat { sanitize(base) * lyricsScale }

    /// 把「17pt 基准下的设计点值」换算成实际点值。
    public func scaledPlayerSize(_ base: CGFloat) -> CGFloat { sanitize(base) * playerScale }

    // MARK: 字体构造

    /// UI 字体。`size` 按惯例是相对 14pt 基准的点值，`uiScale` 在此处生效（文档约定）。
    public func uiFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(family: uiFontFamily, points: sanitize(size) * (uiScale.isFinite ? uiScale : 1), weight: weight)
    }

    /// 歌词字体。`size` 是**真实点值**，不再应用歌词字号设置。
    /// 调用点已持有设置后的 pt 时用这个（例如 `model.fontSize`）。
    public func lyricFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(family: lyricsFontFamily, points: sanitize(size), weight: weight)
    }

    /// 歌词字体。`base` 是 28pt 基准下的设计点值，歌词字号设置在此处生效。
    public func lyricFont(scaledFromBase base: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(family: lyricsFontFamily, points: scaledLyricSize(base), weight: weight)
    }

    /// 播放器字体。`size` 是**真实点值**，不再应用播放器字号设置。
    public func playerFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(family: uiFontFamily, points: sanitize(size), weight: weight)
    }

    /// 播放器字体。`base` 是 17pt 基准下的设计点值，播放器字号设置在此处生效。
    public func playerFont(scaledFromBase base: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(family: uiFontFamily, points: scaledPlayerSize(base), weight: weight)
    }

    /// AppKit 侧（KaraokeText / 歌词卡片导出）用的真实 NSFont。`size` 是**真实点值**。
    public func lyricNSFont(size: CGFloat) -> NSFont {
        nsFont(family: lyricsFontFamily, points: sanitize(size))
    }

    /// AppKit 侧真实 NSFont。`base` 是 28pt 基准下的设计点值，歌词字号设置在此处生效。
    public func lyricNSFont(scaledFromBase base: CGFloat) -> NSFont {
        nsFont(family: lyricsFontFamily, points: scaledLyricSize(base))
    }

    /// 解析到真实 Font：系统字体走 .system，其余先找家族里最接近的字重，再退回家族默认。
    private func font(family: String, points: CGFloat, weight: Font.Weight) -> Font {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != TypographyFontFamily.systemID else {
            return .system(size: points, weight: weight)
        }
        if let resolved = Self.resolve(family: trimmed, points: points, weight: weight) {
            return Font(resolved)
        }
        return .custom(trimmed, size: points).weight(weight)
    }

    /// 解析到真实 NSFont。
    private func nsFont(family: String, points: CGFloat) -> NSFont {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != TypographyFontFamily.systemID else {
            return NSFont.systemFont(ofSize: points)
        }
        return Self.resolve(family: trimmed, points: points, weight: .regular) ?? NSFont.systemFont(ofSize: points)
    }

    /// 家族名不是字体（PostScript）名的场合很多（例如家族「Helvetica Neue」的字体是
    /// 「HelveticaNeue」，中文家族「苹方-简」的字体是「PingFangSC-Regular」），
    /// `.custom(家族名)` 或 `NSFont(name: 家族名)` 会直接失败，设置就形同虚设。
    /// 因此按三条路径依次尝试：
    ///   1) 家族名本身就是字体名 —— 直接命中；
    ///   2) `NSFontManager` 家族的候选成员里挑字重最接近的；
    ///   3) 用家族描述符构造（系统按家族的默认字重解析）。
    static func resolve(family: String, points: CGFloat, weight: Font.Weight) -> NSFont? {
        if let direct = NSFont(name: family, size: points) { return direct }
        if let member = closestMember(ofFamily: family, weight: weight) {
            return font(named: member, size: points)
        }
        return familyDescriptorFont(family: family, points: points, weight: weight)
    }

    /// 家族里字重最接近 `weight` 的字体名。NSFontManager 查询请在主线程调用（调用点均在视图层）。
    static func closestMember(ofFamily family: String, weight: Font.Weight) -> String? {
        guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family) else { return nil }
        let target = numericWeight(weight)
        var bestName: String?
        var bestDelta = Int.max
        for member in members {
            guard let name = member.first as? String else { continue }
            let memberWeight = member.count > 2 ? (member[2] as? NSNumber)?.intValue ?? 5 : 5
            let delta = Swift.abs(memberWeight - target)
            if delta < bestDelta { bestDelta = delta; bestName = name }
        }
        return bestName ?? (members.first?.first as? String)
    }

    /// 用家族描述符构造字体：只给家族与「是否加粗」，由系统挑出该家族的对应字重。
    private static func familyDescriptorFont(family: String, points: CGFloat, weight: Font.Weight) -> NSFont? {
        let traits: NSFontDescriptor.SymbolicTraits = numericWeight(weight) >= 6 ? .bold : []
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.symbolic: traits.rawValue]
        ])
        return NSFont(descriptor: descriptor, size: points)
    }

    private static func font(named name: String, size: CGFloat) -> NSFont? {
        NSFont(name: name, size: size) ?? NSFont(descriptor: NSFontDescriptor(name: name, size: size), size: size)
    }

    /// `Font.Weight` 没有公开的比较接口，这里映射到 NSFontManager 用的 0–9 字重序号。
    static func numericWeight(_ weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight: return 1
        case .thin: return 2
        case .light: return 3
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 7
        case .bold: return 9
        case .heavy: return 10
        case .black: return 12
        default: return 5
        }
    }

    /// 非有限、非正字号一律回落到 UI 基准字号，避免把 NaN 传进 SwiftUI / AppKit。
    private func sanitize(_ size: CGFloat) -> CGFloat {
        size.isFinite && size > 0 ? min(400, size) : AppTypography.baseFontSize
    }
}

// MARK: - 环境注入

private struct AppTypographyKey: EnvironmentKey {
    static let defaultValue = AppTypography()
}

public extension EnvironmentValues {
    /// 当前生效的字体设置。默认是「系统字体 + 各默认字号」，未注入时行为与旧版一致。
    var appTypography: AppTypography {
        get { self[AppTypographyKey.self] }
        set { self[AppTypographyKey.self] = newValue }
    }
}

/// 在根视图上应用字体设置。
///
/// 观察必须在修饰符内部完成：`AppState.settingsViewModel` 是可选对象，
/// 在根视图 body 里只读取它的属性不会建立订阅，设置变化也就不会重绘。
/// 这里把内容包进一个持有 `@ObservedObject` 的子视图，设置一变就重新构造 AppTypography 并注入。
@MainActor
public struct AppTypographyModifier: ViewModifier {

    private let model: SettingsViewModel?

    public init(model: SettingsViewModel?) { self.model = model }

    public func body(content: Content) -> some View {
        if let model {
            AppTypographyHost(model: model, content: content)
        } else {
            content.environment(\.appTypography, AppTypography())
        }
    }
}

/// 订阅设置模型并按当前值下发 typography 与根字体。
private struct AppTypographyHost<Content: View>: View {
    @ObservedObject var model: SettingsViewModel
    let content: Content

    var body: some View {
        let typography = AppTypography(model: model)
        content
            .environment(\.appTypography, typography)
            // 根字体：未显式指定 .font 的文本跟随 UI 基础字号；子视图的 .font(.caption) 等仍然优先。
            .font(typography.uiFont(size: AppTypography.baseFontSize))
    }
}
