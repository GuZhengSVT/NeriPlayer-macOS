// TrafficStats.swift
// NeriPlayer macOS —— 流量统计的值类型与聚合（移植规划 M3-T4）。
//
// 定位：原库 data/traffic（TrafficStatsModels / TrafficStatsRepository / NetworkStatusMonitor）在
// macOS 侧的对应物。本文件只放纯值逻辑：网络类型、用途来源、按自然日的桶、以及把若干桶折叠成
// 汇总。落库在 Data 层的 TrafficStatsRepository，网络状态探测在本文件末尾的分类器里。
//
// 统计口径（与原库一致，也是本任务「做什么 / 不做什么」的核心）：
//   - 本地播放不计流量。读本地文件不经过网络，把它算进「播放流量」会让统计页出现
//     一段永远不该有的数字；记录入口只接受真正的网络字节数（由 M5 的在线播放链路喂入）。
//   - 网络字节按「接入方式」分列（Wi-Fi / 有线 / 蜂窝 / 其他）：原库分 Wi-Fi/移动/漫游，
//     macOS 桌面侧的对应划分是 Wi-Fi 与有线以太网 —— 这是本任务要求「按 Wi-Fi/有线区分」的落点。
//     蜂窝保留下来是因为 iPhone 网络共享在 macOS 上会被识别成 cellular，不该被算作 Wi-Fi。
//   - 再按「用途」分列（播放 / 下载）与「缓存命中」分列：缓存命中的字节没有走网络，
//     单独记才能在统计页算出缓存命中率，而不是把它混进网络流量里。
//
// 为什么入站/出站不分开：播放与下载都是「拉取媒体」，出站字节相对入站可忽略，原库也没有分；
// 多两列只会让统计页多两个常年接近 0 的数字。
//
// 边界（不做）：上报/联网回传（原库也只做本地统计）；实时网速曲线；按 App 维度统计。

import Foundation
import Network

// MARK: - 网络类型

/// 一次网络流量所走的接入方式。
public enum TrafficNetworkType: String, CaseIterable, Sendable {

    /// Wi-Fi。
    case wifi
    /// 有线以太网。macOS 桌面侧的主要接入方式之一，原库没有对应 case。
    case wired
    /// 蜂窝（含 iPhone 网络共享）。
    case cellular
    /// 未识别或当前无网络。
    case other

    /// 统计页展示用的名称。
    public var displayName: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .wired: return "有线网络"
        case .cellular: return "蜂窝网络"
        case .other: return "其他"
        }
    }
}

// MARK: - 用途来源

/// 这次网络流量是为什么产生的。
public enum TrafficUsageSource: String, CaseIterable, Sendable {

    /// 在线播放（边播边下）。
    case playback
    /// 主动下载（含缓存填充）。
    case download
}

// MARK: - 每日桶

/// 按自然日聚合的流量桶。一天一行，字段是当天的累计值。
public struct TrafficStatsBucket: Equatable, Sendable {

    /// 该桶所属自然日的本地零点。主键。
    public var dayStart: Date
    /// 走 Wi-Fi 的网络字节数。
    public var wifiBytes: Int64
    /// 走有线以太网的网络字节数。
    public var wiredBytes: Int64
    /// 走蜂窝的网络字节数。
    public var cellularBytes: Int64
    /// 接入方式未识别的网络字节数。
    public var otherBytes: Int64
    /// 其中属于在线播放的字节数。
    public var playbackNetworkBytes: Int64
    /// 其中属于主动下载的字节数。
    public var downloadNetworkBytes: Int64
    /// 缓存命中的字节数（没有走网络）。
    public var cacheHitBytes: Int64
    /// 发起过的网络请求次数（播放与下载合计）。
    public var requestCount: Int
    /// 缓存命中次数。
    public var cacheHitCount: Int

    public init(
        dayStart: Date,
        wifiBytes: Int64 = 0,
        wiredBytes: Int64 = 0,
        cellularBytes: Int64 = 0,
        otherBytes: Int64 = 0,
        playbackNetworkBytes: Int64 = 0,
        downloadNetworkBytes: Int64 = 0,
        cacheHitBytes: Int64 = 0,
        requestCount: Int = 0,
        cacheHitCount: Int = 0
    ) {
        self.dayStart = dayStart
        self.wifiBytes = wifiBytes
        self.wiredBytes = wiredBytes
        self.cellularBytes = cellularBytes
        self.otherBytes = otherBytes
        self.playbackNetworkBytes = playbackNetworkBytes
        self.downloadNetworkBytes = downloadNetworkBytes
        self.cacheHitBytes = cacheHitBytes
        self.requestCount = requestCount
        self.cacheHitCount = cacheHitCount
    }

    /// 当天的网络字节合计（不含缓存命中）。
    public var networkBytes: Int64 {
        wifiBytes + wiredBytes + cellularBytes + otherBytes
    }

    /// 取指定接入方式的字节数。
    public func bytes(on type: TrafficNetworkType) -> Int64 {
        switch type {
        case .wifi: return wifiBytes
        case .wired: return wiredBytes
        case .cellular: return cellularBytes
        case .other: return otherBytes
        }
    }

    /// 把网络字节累加到指定接入方式上。
    public mutating func addNetworkBytes(_ bytes: Int64, on type: TrafficNetworkType) {
        switch type {
        case .wifi: wifiBytes += bytes
        case .wired: wiredBytes += bytes
        case .cellular: cellularBytes += bytes
        case .other: otherBytes += bytes
        }
    }

    /// 求某时刻所属自然日的本地零点。
    ///
    /// 与播放统计（PlaybackStatsDailyBucket.dayStart）用同一套口径：本地零点而不是 UTC 零点，
    /// 否则「今天用了多少流量」会在时区偏移下算错一天。
    public static func dayStart(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }
}

// MARK: - 汇总

/// 若干桶折叠出的汇总值。字段与桶一致，只是去掉了「哪一天」。
public struct TrafficStatsSummary: Equatable, Sendable {

    public var wifiBytes: Int64
    public var wiredBytes: Int64
    public var cellularBytes: Int64
    public var otherBytes: Int64
    public var playbackNetworkBytes: Int64
    public var downloadNetworkBytes: Int64
    public var cacheHitBytes: Int64
    public var requestCount: Int
    public var cacheHitCount: Int

    public init(
        wifiBytes: Int64 = 0,
        wiredBytes: Int64 = 0,
        cellularBytes: Int64 = 0,
        otherBytes: Int64 = 0,
        playbackNetworkBytes: Int64 = 0,
        downloadNetworkBytes: Int64 = 0,
        cacheHitBytes: Int64 = 0,
        requestCount: Int = 0,
        cacheHitCount: Int = 0
    ) {
        self.wifiBytes = wifiBytes
        self.wiredBytes = wiredBytes
        self.cellularBytes = cellularBytes
        self.otherBytes = otherBytes
        self.playbackNetworkBytes = playbackNetworkBytes
        self.downloadNetworkBytes = downloadNetworkBytes
        self.cacheHitBytes = cacheHitBytes
        self.requestCount = requestCount
        self.cacheHitCount = cacheHitCount
    }

    /// 网络字节合计（不含缓存命中）。
    public var networkBytes: Int64 {
        wifiBytes + wiredBytes + cellularBytes + otherBytes
    }

    /// 取指定接入方式的字节数。
    public func bytes(on type: TrafficNetworkType) -> Int64 {
        switch type {
        case .wifi: return wifiBytes
        case .wired: return wiredBytes
        case .cellular: return cellularBytes
        case .other: return otherBytes
        }
    }

    /// 「播放实际消耗」= 网络播放字节 + 缓存命中字节。缓存命中率的分母。
    public var measuredPlaybackBytes: Int64 {
        playbackNetworkBytes + cacheHitBytes
    }

    /// 缓存命中率（0…1）。没有任何可测播放流量时为 0。
    public var cacheHitRate: Double {
        let denominator = measuredPlaybackBytes
        guard denominator > 0 else { return 0 }
        return Double(cacheHitBytes) / Double(denominator)
    }

    /// 是否有任何可展示的流量数据（统计页据此决定是否显示空态）。
    public var hasTrafficData: Bool {
        networkBytes > 0 || cacheHitBytes > 0
    }

    /// 把一组桶折叠成汇总。调用方负责先按时间范围筛好桶。
    public static func aggregate(_ buckets: [TrafficStatsBucket]) -> TrafficStatsSummary {
        buckets.reduce(into: TrafficStatsSummary()) { summary, bucket in
            summary.wifiBytes += bucket.wifiBytes
            summary.wiredBytes += bucket.wiredBytes
            summary.cellularBytes += bucket.cellularBytes
            summary.otherBytes += bucket.otherBytes
            summary.playbackNetworkBytes += bucket.playbackNetworkBytes
            summary.downloadNetworkBytes += bucket.downloadNetworkBytes
            summary.cacheHitBytes += bucket.cacheHitBytes
            summary.requestCount += bucket.requestCount
            summary.cacheHitCount += bucket.cacheHitCount
        }
    }
}

// MARK: - 网络类型探测

/// 当前接入方式的查询口。抽成协议是为了让「记录时按什么类型归类」可以确定性单测，
/// 不必依赖测试机器当时真的插着网线还是连着 Wi-Fi。
public protocol TrafficNetworkClassifying: AnyObject, Sendable {

    /// 当前接入方式；无法判断时返回 .other。
    func currentNetworkType() -> TrafficNetworkType
}

/// 生产实现：NWPathMonitor 持续跟踪网络路径，查询时返回最近一次已知的接入方式。
///
/// 为什么要持续跟踪而不是每次现查：`NWPathMonitor` 的 `currentPath` 只有把 monitor 启动之后
/// 才有意义（启动前是未初始化的默认值）。记录流量是低频动作（播放/下载结算时），
/// 为此起一次同步探测既慢又可能阻塞；常驻一个小监视器、把结果缓存下来更合适。
///
/// 启动失败或路径未就绪时返回 .other —— 统计少归类一档，好过记错一档。
public final class PathMonitorNetworkClassifier: TrafficNetworkClassifying, @unchecked Sendable {

    private let lock = NSLock()
    private var latest: TrafficNetworkType = .other
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "moe.ouom.NeriPlayer.traffic.networkMonitor")

    public init() {
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let type = Self.classify(path)
            self.lock.lock()
            self.latest = type
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    public func currentNetworkType() -> TrafficNetworkType {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// 把一条网络路径归类。顺序即优先级：多接口同时可用时（例如插着网线又连着 Wi-Fi），
    /// 系统按服务顺序选用其中一个，这里按「有线优先于 Wi-Fi」的常见服务顺序判定。
    private static func classify(_ path: NWPath) -> TrafficNetworkType {
        guard path.status == .satisfied else { return .other }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        return .other
    }
}
