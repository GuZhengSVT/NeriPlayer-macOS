// PlaybackQuality.swift
// 各平台音质偏好与选轨规则（对齐 Android 的 AutoSettingsSchema.audioQuality /
// PlayerUrlResolver / BiliAudioSelector）。
//
// 定位：把「用户要哪一档音质」与「怎么在平台返回的多条音轨里挑出这一档」分成两块纯逻辑：
//   - 三个枚举各自表达一个平台的档位、展示名与降级链，不含任何网络或 UI 依赖；
//   - AudioQualityPreferences 是三个档位的聚合，供设置页一次读写；
//   - BilibiliAudioSelection 把 playurl 响应解析成候选音轨并按偏好挑选。
// 采集与下发在各自的 client（NeteaseClient / YouTubeMusicClient / BilibiliClient），
// 界面只负责把偏好写成设置项。
//
// 「降级而不是硬失败」是本文件的硬约束：平台经常拿不到用户点的那一档（未登录、无会员、
// 视频没有 Hi-Res 轨）。此时必须按各平台自己的顺序退到下一档，而不是报「没有可用音源」。
// 顺序与 Android 完全一致，见各个 `degradeChain`。

import Foundation

// MARK: - 偏好聚合

/// 三个平台的音质偏好快照。值类型，便于跨 actor 传递与在设置页整体读写。
public struct AudioQualityPreferences: Equatable, Sendable {

    /// 网易云档位。
    public var netease: NeteaseQuality
    /// YouTube Music 档位。
    public var youtubeMusic: YouTubeQuality
    /// Bilibili 档位。
    public var bilibili: BilibiliQuality

    public init(
        netease: NeteaseQuality = .default,
        youtubeMusic: YouTubeQuality = .default,
        bilibili: BilibiliQuality = .default
    ) {
        self.netease = netease
        self.youtubeMusic = youtubeMusic
        self.bilibili = bilibili
    }

    /// 从设置存储读取。未设置或值无法识别时回落到各平台的默认档位 ——
    /// 这里刻意不抛错：一个被手改坏的 UserDefaults 值不该让整个播放链路失败。
    public init(settings: SettingsStore) {
        self.init(
            netease: NeteaseQuality(stored: settings.value(for: SettingsKeys.neteaseAudioQuality)),
            youtubeMusic: YouTubeQuality(stored: settings.value(for: SettingsKeys.youtubeMusicAudioQuality)),
            bilibili: BilibiliQuality(stored: settings.value(for: SettingsKeys.bilibiliAudioQuality))
        )
    }

    /// 把三个档位写回设置存储。写入侧负责夹取，读取侧因此不必再防御。
    public func write(to settings: SettingsStore) {
        settings.set(netease.rawValue, for: SettingsKeys.neteaseAudioQuality)
        settings.set(youtubeMusic.rawValue, for: SettingsKeys.youtubeMusicAudioQuality)
        settings.set(bilibili.rawValue, for: SettingsKeys.bilibiliAudioQuality)
    }
}

/// 音质偏好的读取入口。
///
/// 为什么是「可注入的读取闭包」而不是让每个 client 直接读 SettingsStore：
///   - client 是 actor，在解析时（可能已经被切歌打断）才需要这个值，不能把偏好缓存在构造时；
///   - 测试需要在不碰真实 UserDefaults 的前提下注入一组偏好。
/// 生产路径用 `.settings`（每次解析都读最新的设置值），测试用显式构造。
public struct AudioQualityProvider: Sendable {

    private let read: @Sendable () -> AudioQualityPreferences

    public init(read: @escaping @Sendable () -> AudioQualityPreferences) {
        self.read = read
    }

    /// 当前偏好快照。
    public func preferences() -> AudioQualityPreferences { read() }

    /// 生产默认：读全局设置。每次调用都重新读，用户在设置页改完立即对下一次解析生效。
    public static let settings = AudioQualityProvider { AudioQualityPreferences(settings: .shared) }

    /// 固定一组偏好（测试与需要显式指定的调用方）。
    public static func fixed(_ preferences: AudioQualityPreferences) -> AudioQualityProvider {
        AudioQualityProvider { preferences }
    }
}

// MARK: - 网易云

/// 网易云音质档位。rawValue 即 `/eapi/song/enhance/player/url/v1` 的 `level` 参数。
///
/// 档位顺序（由高到低）与 Android 的 `NETEASE_QUALITY_FALLBACK_ORDER` 一致：
/// jymaster > sky > jyeffect > hires > lossless > exhigh > higher > standard。
public enum NeteaseQuality: String, CaseIterable, Sendable, Identifiable {
    /// 标准，约 128 kbps。
    case standard
    /// 较高，约 192 kbps。
    case higher
    /// 极高，约 320 kbps。
    case exhigh
    /// 无损。
    case lossless
    /// Hi-Res。
    case hires
    /// 高清环绕声。
    case jyeffect
    /// 沉浸环绕声。
    case sky
    /// 超清母带。
    case jymaster

    public var id: String { rawValue }

    /// 设置页展示名。
    public var title: String {
        switch self {
        case .standard: return "标准"
        case .higher: return "较高"
        case .exhigh: return "极高"
        case .lossless: return "无损"
        case .hires: return "Hi-Res"
        case .jyeffect: return "高清环绕声"
        case .sky: return "沉浸环绕声"
        case .jymaster: return "超清母带"
        }
    }

    /// 展示名附带说明，用在下拉项里（例如「无损（需会员）」）。
    public var menuTitle: String {
        requiresMembership ? "\(title)（需会员）" : title
    }

    /// 默认档位。与 Android 的 `defaultString = "exhigh"` 一致。
    public static let `default`: NeteaseQuality = .exhigh

    /// 是否需要会员权益。用于在设置页给出提示，不参与选轨。
    public var requiresMembership: Bool {
        switch self {
        case .standard, .higher, .exhigh: return false
        case .lossless, .hires, .jyeffect, .sky, .jymaster: return true
        }
    }

    /// 由高到低的完整降级链。
    public static let fallbackOrder: [NeteaseQuality] = [
        .jymaster, .sky, .jyeffect, .hires, .lossless, .exhigh, .higher, .standard
    ]

    /// 从本档位起、依次向下的降级链（含自身）。用于「拿不到就退一档」的请求循环。
    public var degradeChain: [NeteaseQuality] {
        guard let index = Self.fallbackOrder.firstIndex(of: self) else { return [self] }
        return Array(Self.fallbackOrder[index...])
    }

    /// 从存储值解析；无法识别时回落到默认档位。
    public init(stored: String) {
        self = NeteaseQuality(rawValue: stored) ?? .default
    }
}

// MARK: - YouTube Music

/// YouTube Music 音质档位。YouTube 的档位是按可用自适应码率区间推断的，
/// 因此这里用「最低码率阈值」表达，与 Android 的 `inferYouTubeQualityKeyFromBitrate` 一致。
public enum YouTubeQuality: String, CaseIterable, Sendable, Identifiable {
    case low
    case medium
    case high
    case veryHigh = "very_high"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .veryHigh: return "极高"
        }
    }

    /// 默认档位。与 Android 的 `defaultString = "high"` 一致。
    public static let `default`: YouTubeQuality = .high

    /// 该档位要求的最低码率（kbps）。low 没有下限。
    public var minimumBitrateKbps: Int {
        switch self {
        case .low: return 0
        case .medium: return 96
        case .high: return 128
        case .veryHigh: return 160
        }
    }

    /// 由低到高的顺序。选轨时「不超过偏好档位」即按这个顺序的下标比较。
    public static let ordered: [YouTubeQuality] = [.low, .medium, .high, .veryHigh]

    /// 由本档位起、依次向下的降级链（含自身）。
    public var degradeChain: [YouTubeQuality] {
        guard let index = Self.ordered.firstIndex(of: self) else { return [self] }
        return Array(Self.ordered[0...index].reversed())
    }

    /// 把一条自适应流的码率归到档位。未知码率按最低档处理（与 Android 一致）。
    public static func infer(bitrateKbps: Int?) -> YouTubeQuality {
        guard let bitrateKbps else { return .low }
        if bitrateKbps >= YouTubeQuality.veryHigh.minimumBitrateKbps { return .veryHigh }
        if bitrateKbps >= YouTubeQuality.high.minimumBitrateKbps { return .high }
        if bitrateKbps >= YouTubeQuality.medium.minimumBitrateKbps { return .medium }
        return .low
    }

    /// 从存储值解析；无法识别时回落到默认档位。
    public init(stored: String) {
        self = YouTubeQuality(rawValue: stored) ?? .default
    }
}

// MARK: - Bilibili

/// Bilibili 音质档位。B 站不提供「请求某一档」的参数（DASH 会一次性下发全部可用音轨），
/// 因此这里是**本地选轨偏好**：在返回的候选音轨里挑最接近的一档，挑不到就降级。
/// 档位与 Android 的 `BiliQuality` 一致，且刻意不硬编码 dash audio id，
/// 只用标签（dolby/hires）与码率判断，避免平台调整 id 后选轨失效。
public enum BilibiliQuality: String, CaseIterable, Sendable, Identifiable {
    /// 杜比全景声。
    case dolby
    /// Hi-Res（无损及以上）。
    case hires
    /// 无损。
    case lossless
    /// 高，约 192 kbps。
    case high
    /// 中，约 128 kbps。
    case medium
    /// 低，约 64 kbps。
    case low

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dolby: return "杜比全景声"
        case .hires: return "Hi-Res"
        case .lossless: return "无损"
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }

    /// 默认档位。与 Android 的 `defaultString = "high"` 一致。
    public static let `default`: BilibiliQuality = .high

    /// 该档位的码率下限（kbps）。杜比靠标签命中，码率下限为 0。
    public var minimumBitrateKbps: Int {
        switch self {
        case .dolby: return 0
        case .hires: return 1000
        case .lossless: return 500
        case .high: return 180
        case .medium: return 120
        case .low: return 60
        }
    }

    /// 由高到低的顺序。
    public static let ordered: [BilibiliQuality] = [.dolby, .hires, .lossless, .high, .medium, .low]

    /// 由本档位起、依次向下的降级链（含自身）。
    public var degradeChain: [BilibiliQuality] {
        guard let index = Self.ordered.firstIndex(of: self) else { return [self] }
        return Array(Self.ordered[index...])
    }

    /// 「普通音轨」（无 dolby/hires 标签）在挑档位时的码率上界（开区间）。
    ///
    /// 为什么需要上界：`high` 的语义是「约 192 kbps 的那一档」。若只判下限，
    /// 一条 1000 kbps 的普通音轨会被当成 high 命中，用户选「高」却拿到无损。
    /// 上界即上一档（更高档）的下限，`lossless` 起是标签档位，故上界为无穷。
    var regularUpperBoundExclusive: Int {
        switch self {
        case .dolby: return Int.max
        case .hires: return BilibiliQuality.hires.minimumBitrateKbps
        case .lossless: return BilibiliQuality.hires.minimumBitrateKbps
        case .high: return BilibiliQuality.lossless.minimumBitrateKbps
        case .medium: return BilibiliQuality.high.minimumBitrateKbps
        case .low: return BilibiliQuality.medium.minimumBitrateKbps
        }
    }

    /// 从存储值解析；无法识别时回落到默认档位。
    public init(stored: String) {
        self = BilibiliQuality(rawValue: stored) ?? .default
    }
}

/// 一条候选音轨：Bilibili playurl 响应里的 dash audio / dolby / flac 条目归一化后的形态。
public struct BilibiliAudioStream: Equatable, Sendable {

    /// dash 的 audio id（例如 30280）。平台未给出时为 nil。
    public var id: Int?
    /// MIME 类型（例如 audio/mp4、audio/flac、audio/eac3）。
    public var mimeType: String
    /// 估算码率（kbps，由 bandwidth 换算）。
    public var bitrateKbps: Int
    /// 质量标签：`"dolby"` / `"hires"`，普通音轨为 nil。
    public var qualityTag: String?
    /// 首选地址（已按 CDN 优先级挑过）。
    public var url: URL
    /// 备用地址，保持优先级顺序。
    public var backupURLs: [URL]
    /// 原始 bandwidth（bit/s）。
    public var bandwidth: Int
    /// 单条渐进式 MP4（durl）回退流；此类流含视频轨，播放侧必须只取音频。
    public var isProgressiveFallback: Bool

    public init(
        id: Int? = nil,
        mimeType: String,
        bitrateKbps: Int,
        qualityTag: String? = nil,
        url: URL,
        backupURLs: [URL] = [],
        bandwidth: Int = 0,
        isProgressiveFallback: Bool = false
    ) {
        self.id = id
        self.mimeType = mimeType
        self.bitrateKbps = max(0, bitrateKbps)
        // 标签统一小写并去空白；空标签归一成 nil —— 选轨逻辑靠 `qualityTag == nil` 判断
        // 「这是一条普通音轨」，留一个空串会让它被误判成标签音轨而从普通档位里消失。
        let trimmedTag = qualityTag?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.qualityTag = (trimmedTag?.isEmpty ?? true) ? nil : trimmedTag
        self.url = url
        self.backupURLs = backupURLs
        self.bandwidth = max(0, bandwidth)
        self.isProgressiveFallback = isProgressiveFallback
    }

    /// 归一到该音轨对应的档位（用于在设置页展示「实际拿到的是哪一档」）。
    ///
    /// 与 Android 的 `inferBiliQualityKey` 一致：标签优先，其次看 flac MIME，最后按码率归档。
    /// 刻意不按 dash 的 audio id 判断 —— 平台调整 id 后这里不会失效。
    public var quality: BilibiliQuality {
        switch qualityTag {
        case "dolby": return .dolby
        case "hires": return .hires
        case "lossless": return .lossless
        default: break
        }
        if Self.isLosslessMIME(mimeType) { return .lossless }
        if bitrateKbps >= BilibiliQuality.high.minimumBitrateKbps { return .high }
        if bitrateKbps >= BilibiliQuality.medium.minimumBitrateKbps { return .medium }
        return .low
    }

    /// MIME 是否为无损容器（flac）。
    static func isLosslessMIME(_ mimeType: String) -> Bool {
        let mime = mimeType.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return ["audio/flac", "audio/x-flac"].contains(mime)
    }
}

/// Bilibili 选轨纯逻辑：把 playurl 的 `data` 解析成候选音轨，并按偏好挑选。
public enum BilibiliAudioSelection {

    /// 从 playurl 响应的 `data` 字典解析候选音轨。
    ///
    /// 优先级与 Android 的 `PlayInfo.toAudioStreamInfos` 一致：普通音轨、杜比、Hi-Res 全部收进来，
    /// 交给选轨逻辑判断，而不是在这里就丢掉低档 —— 用户可能恰好选了低档。
    ///
    /// 单条渐进式 MP4（`durl`）作为最后一档回退保留：只有当 DASH 一条音轨都没有时才使用，
    /// 且**多条** durl 无法用一个 URL 表达，直接放弃（与 Android 的 `durl.size != 1` 判断一致）。
    public static func streams(in data: [String: Any]) -> [BilibiliAudioStream] {
        let dash = data["dash"] as? [String: Any] ?? [:]
        var result: [BilibiliAudioStream] = []

        func append(_ track: [String: Any], qualityTag: String?, fallbackMIME: String) {
            let urls = candidateURLs(track)
            guard let first = urls.first else { return }
            let bandwidth = BilibiliParsing.integer(track["bandwidth"]) ?? 0
            let declaredMIME = (track["mimeType"] as? String) ?? (track["mime_type"] as? String) ?? ""
            result.append(BilibiliAudioStream(
                id: BilibiliParsing.integer(track["id"]),
                mimeType: declaredMIME.isEmpty ? fallbackMIME : declaredMIME,
                bitrateKbps: bandwidth / 1000,
                qualityTag: qualityTag,
                url: first,
                backupURLs: Array(urls.dropFirst()),
                bandwidth: bandwidth
            ))
        }

        for track in dash["audio"] as? [[String: Any]] ?? [] {
            append(track, qualityTag: nil, fallbackMIME: "audio/mp4")
        }
        let dolbyTracks = (dash["dolby"] as? [String: Any])?["audio"] as? [[String: Any]] ?? []
        for track in dolbyTracks {
            append(track, qualityTag: "dolby", fallbackMIME: "audio/eac3")
        }
        if let flac = (dash["flac"] as? [String: Any])?["audio"] as? [String: Any] {
            append(flac, qualityTag: "hires", fallbackMIME: "audio/flac")
        }
        if !result.isEmpty { return result }

        // DASH 无音轨时才考虑的渐进式回退；多条分片无法用一个 URL 表达，直接放弃。
        let progressive = data["durl"] as? [[String: Any]] ?? []
        guard progressive.count == 1, let item = progressive.first else { return [] }
        let urls = candidateURLs(item)
        guard let first = urls.first else { return [] }
        return [BilibiliAudioStream(
            mimeType: "video/mp4",
            bitrateKbps: progressiveBitrateKbps(item),
            url: first,
            backupURLs: Array(urls.dropFirst()),
            isProgressiveFallback: true
        )]
    }

    /// 按偏好挑选一条音轨；一条可用音轨都没有时返回 nil。
    ///
    /// 规则（与 Android `selectStreamByPreference` 等价）：
    ///   1. 先按偏好档位的精确语义找：dolby 找带 dolby 标签的、hires 找带 hires 标签的、
    ///      lossless 找无损类（标签或 flac MIME）；
    ///   2. 没有就顺着降级链往下，普通音轨按「码率落在该档区间内」匹配；
    ///   3. 全都不满足时取码率最高的一条 —— 宁可给用户一条能播的，也不要报「没有可用音源」。
    public static func select(from streams: [BilibiliAudioStream], preferred: BilibiliQuality) -> BilibiliAudioStream? {
        guard !streams.isEmpty else { return nil }
        // 去重按 URL：同一条流可能在 audio 与 dolby 里各出现一次。
        var seen = Set<URL>()
        let unique = streams.filter { seen.insert($0.url).inserted }
        // 普通轨按码率降序，标签轨（dolby / hires）排在后面 —— 与 Android 的
        // `(regularSorted + taggedSorted)` 顺序一致，保证「同档位内取码率最高的一条」。
        let tagged = unique.filter { $0.qualityTag != nil }.sorted { $0.bitrateKbps > $1.bitrateKbps }
        let regular = unique.filter { $0.qualityTag == nil }.sorted { $0.bitrateKbps > $1.bitrateKbps }
        let all = regular + tagged

        switch preferred {
        case .dolby:
            if let hit = all.first(where: { $0.qualityTag == "dolby" }) { return hit }
        case .hires:
            if let hit = all.first(where: { $0.qualityTag == "hires" }) { return hit }
        case .lossless:
            if let hit = all.first(where: isLosslessLike) { return hit }
        case .high, .medium, .low:
            break
        }

        for quality in preferred.degradeChain {
            let hit: BilibiliAudioStream?
            switch quality {
            case .dolby:
                hit = all.first { $0.qualityTag == "dolby" }
            case .hires:
                hit = all.first { $0.qualityTag == "hires" }
            case .lossless:
                // 无损可以是 flac 轨，也可以是一条码率落在无损区间的普通轨。
                hit = all.first(where: isLosslessLike)
                    ?? regular.first { matchesRegular($0, quality: .lossless) }
            case .high, .medium, .low:
                hit = regular.first { matchesRegular($0, quality: quality) }
            }
            if let hit { return hit }
        }
        return all.first
    }

    /// 该候选集里实际可用的档位（由高到低），供设置页或调试展示。
    public static func availableQualities(in streams: [BilibiliAudioStream]) -> [BilibiliQuality] {
        let present = Set(streams.map(\.quality))
        return BilibiliQuality.ordered.filter { present.contains($0) }
    }

    /// 普通音轨是否落在某一档的码率区间内。
    ///
    /// 下限的特殊处理：`low` 是降级链的最后一档，若仍按 60 kbps 取下限，一条 44 kbps 的
    /// AAC-HE 音轨会落到「所有档位都不匹配」的缝里，最终被兜底逻辑返回**最高**码率的那条 ——
    /// 用户选了「低」却拿到近无损，这比降级更难接受。因此最底一档不设下限，
    /// 保证降级链对任何普通音轨都是完备的。
    static func matchesRegular(_ stream: BilibiliAudioStream, quality: BilibiliQuality) -> Bool {
        guard stream.qualityTag == nil, !stream.isProgressiveFallback else { return false }
        let lowerBound = quality == .low ? 0 : quality.minimumBitrateKbps
        return stream.bitrateKbps >= lowerBound
            && stream.bitrateKbps < quality.regularUpperBoundExclusive
    }

    /// 是否为无损类音轨：带 hires/lossless 标签，或 MIME 是 flac。
    static func isLosslessLike(_ stream: BilibiliAudioStream) -> Bool {
        if let tag = stream.qualityTag, ["hires", "lossless"].contains(tag) { return true }
        return BilibiliAudioStream.isLosslessMIME(stream.mimeType)
    }

    /// 收集一条音轨的候选地址，并按 CDN 优先级排序（upos > bilivideo > mountaintoys）。
    ///
    /// 为什么保留备用地址：B 站同一条音轨会下发多个 CDN 备份，首选地址在部分网络下会 403，
    /// 需要能按顺序回退。排序与 Android 的 `prioritizeBiliStreamUrls` 一致。
    ///
    /// 为什么要同时读 `baseUrl`/`base_url` 与 `url`：DASH 音轨用前者，而渐进式 `durl` 分片
    /// （html5 回退那条路径）用的是后者。只认 baseUrl 会让回退成功取到响应却仍然拿不到地址，
    /// 最终仍以「没有可用音源」收场 —— 那正是本轮要修的失败形态，不能在新选的路径上重演。
    static func candidateURLs(_ track: [String: Any]) -> [URL] {
        let base = track["baseUrl"] as? String ?? track["base_url"] as? String ?? track["url"] as? String
        let backups = track["backupUrl"] as? [String] ?? track["backup_url"] as? [String] ?? []
        let raw = ([base].compactMap { $0 } + backups)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<URL>()
        let parsed = raw.compactMap { BilibiliParsing.httpURL($0) }.filter { seen.insert($0).inserted }
        return parsed.enumerated().sorted { lhs, rhs in
            let left = streamHostScore(lhs.element)
            let right = streamHostScore(rhs.element)
            if left != right { return left > right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// CDN 主机打分：分数越高越优先。
    static func streamHostScore(_ url: URL) -> Int {
        let host = url.host?.lowercased() ?? ""
        if host.hasPrefix("upos-") && host.contains("bilivideo.") { return 3 }
        if host.contains("bilivideo.") { return 2 }
        if host.hasSuffix(".mountaintoys.cn") { return 1 }
        return 0
    }

    /// 渐进式回退流的码率估算：由分片字节数与时长换算 kbps。
    static func progressiveBitrateKbps(_ item: [String: Any]) -> Int {
        let size = (item["size"] as? NSNumber)?.doubleValue ?? 0
        let length = (item["length"] as? NSNumber)?.doubleValue ?? 0
        guard size > 0, length > 0 else { return 0 }
        return max(0, Int((size * 8) / length))
    }
}
