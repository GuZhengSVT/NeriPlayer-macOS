// TrafficRecords.swift
// NeriPlayer macOS —— M3-T4 的流量统计 GRDB 记录。
//
// 分层约定（与 Records.swift / PlaybackRecords.swift 一致）：Core 层的 TrafficStatsBucket
// 不 import GRDB，本文件是它在数据库里的镜像 —— 提供「由值类型构造」与「转回值类型」两个入口，
// Repository 与 UI 只面对 Core 值类型。
//
// 时间列沿用 GRDB 的 Date 默认编码（按 UTC 存字符串）。dayStart 是「本地零点」这一时刻本身，
// 存的是绝对时间点，因此存取往返不受时区影响：写进去的是当时算出的那个瞬间，读出来还是它。

import Foundation
import GRDB

/// TrafficStats 表的 GRDB 记录。一天一行，dayStart 为主键。
public final class TrafficStatsRecord: Record {

    /// 该桶所属自然日的本地零点。主键。
    public var dayStart: Date
    public var wifiBytes: Int64
    public var wiredBytes: Int64
    public var cellularBytes: Int64
    public var otherBytes: Int64
    public var playbackNetworkBytes: Int64
    public var downloadNetworkBytes: Int64
    public var cacheHitBytes: Int64
    public var requestCount: Int
    public var cacheHitCount: Int

    public override static var databaseTableName: String { DatabaseSchema.trafficStats }

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
        super.init()
    }

    /// 由 Core 值类型构造。
    public convenience init(bucket: TrafficStatsBucket) {
        self.init(
            dayStart: bucket.dayStart,
            wifiBytes: bucket.wifiBytes,
            wiredBytes: bucket.wiredBytes,
            cellularBytes: bucket.cellularBytes,
            otherBytes: bucket.otherBytes,
            playbackNetworkBytes: bucket.playbackNetworkBytes,
            downloadNetworkBytes: bucket.downloadNetworkBytes,
            cacheHitBytes: bucket.cacheHitBytes,
            requestCount: bucket.requestCount,
            cacheHitCount: bucket.cacheHitCount
        )
    }

    public required init(row: Row) throws {
        self.dayStart = row["dayStart"]
        self.wifiBytes = row["wifiBytes"]
        self.wiredBytes = row["wiredBytes"]
        self.cellularBytes = row["cellularBytes"]
        self.otherBytes = row["otherBytes"]
        self.playbackNetworkBytes = row["playbackNetworkBytes"]
        self.downloadNetworkBytes = row["downloadNetworkBytes"]
        self.cacheHitBytes = row["cacheHitBytes"]
        self.requestCount = row["requestCount"]
        self.cacheHitCount = row["cacheHitCount"]
        try super.init(row: row)
    }

    public override func encode(to container: inout PersistenceContainer) throws {
        container["dayStart"] = dayStart
        container["wifiBytes"] = wifiBytes
        container["wiredBytes"] = wiredBytes
        container["cellularBytes"] = cellularBytes
        container["otherBytes"] = otherBytes
        container["playbackNetworkBytes"] = playbackNetworkBytes
        container["downloadNetworkBytes"] = downloadNetworkBytes
        container["cacheHitBytes"] = cacheHitBytes
        container["requestCount"] = requestCount
        container["cacheHitCount"] = cacheHitCount
    }

    /// 转回 Core 值类型。
    public var bucket: TrafficStatsBucket {
        TrafficStatsBucket(
            dayStart: dayStart,
            wifiBytes: wifiBytes,
            wiredBytes: wiredBytes,
            cellularBytes: cellularBytes,
            otherBytes: otherBytes,
            playbackNetworkBytes: playbackNetworkBytes,
            downloadNetworkBytes: downloadNetworkBytes,
            cacheHitBytes: cacheHitBytes,
            requestCount: requestCount,
            cacheHitCount: cacheHitCount
        )
    }
}
