// TrafficStatsRepository.swift
// NeriPlayer macOS —— 流量统计的读写（移植规划 M3-T4）。
//
// 语义参考原库 data/traffic/TrafficStatsRepository：按自然日的桶增量累加，读侧提供
// 「某天」「最近若干天」「区间汇总」三种查询。与 M3-T1/T2 的 Repository 同一约定：
// 短事务，对外只返回 Core 值类型。
//
// 为什么写入走原始 SQL 的 upsert 而不是「先读一次、改内存、再写回」：
//   1) 累加语义（+bytes）在 SQL 里完成，是单条语句的原子操作，不需要事务包住读—改—写；
//   2) 读改写会在并发写入时丢增量（后写的覆盖先写的），而统计天然会被播放与下载两条链路同时喂；
//   3) 列名来自编译期白名单（枚举 → 列名映射），不存在把外部输入拼进 SQL 的路径。
//
// 边界（不做）：上报/联网回传；流量来源的抓取（那是 M5 在线播放与 M6 下载器的事，
// 本任务只提供「记一笔」的接口与正确的计数语义）。

import Foundation
import GRDB

/// 流量统计表的读写。
public struct TrafficStatsRepository: Sendable {

    private let database: DatabaseProvider

    public init(_ database: DatabaseProvider) {
        self.database = database
    }

    // MARK: - 写入

    /// 记一笔网络流量。
    ///
    /// - Parameters:
    ///   - bytes: 实际走网络的字节数；非正数直接忽略（原库同样是 `if (bytes <= 0L) return`）。
    ///   - networkType: 当时的接入方式，决定落到哪一列。
    ///   - source: 这笔流量是播放还是下载产生的。
    ///   - date: 归属时刻；决定落到哪一天的桶。默认现在。
    ///
    /// 调用方约定（重要）：只有真正走网络的字节才该进来。本地文件播放不产生网络流量，
    /// 不得调用本方法 —— 否则统计页会出现永远不该有的「播放流量」。
    public func record(
        bytes: Int64,
        networkType: TrafficNetworkType,
        source: TrafficUsageSource,
        at date: Date = Date()
    ) throws {
        guard bytes > 0 else { return }
        let dayStart = TrafficStatsBucket.dayStart(for: date)
        let typeColumn = Self.column(for: networkType)
        let sourceColumn = Self.column(for: source)

        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO \(DatabaseSchema.trafficStats)
                        (dayStart, \(typeColumn), \(sourceColumn), requestCount)
                    VALUES (?, ?, ?, 1)
                    ON CONFLICT(dayStart) DO UPDATE SET
                        \(typeColumn) = \(typeColumn) + excluded.\(typeColumn),
                        \(sourceColumn) = \(sourceColumn) + excluded.\(sourceColumn),
                        requestCount = requestCount + 1
                    """,
                arguments: [dayStart, bytes, bytes]
            )
        }
        Log.db.debug("记录网络流量：\(bytes) 字节 / \(networkType.rawValue) / \(source.rawValue)")
    }

    /// 记一笔缓存命中。缓存命中没有走网络，因此不计入任何网络字节列，只累加命中量与命中次数。
    public func recordCacheHit(bytes: Int64, at date: Date = Date()) throws {
        guard bytes > 0 else { return }
        let dayStart = TrafficStatsBucket.dayStart(for: date)

        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO \(DatabaseSchema.trafficStats)
                        (dayStart, cacheHitBytes, cacheHitCount)
                    VALUES (?, ?, 1)
                    ON CONFLICT(dayStart) DO UPDATE SET
                        cacheHitBytes = cacheHitBytes + excluded.cacheHitBytes,
                        cacheHitCount = cacheHitCount + 1
                    """,
                arguments: [dayStart, bytes]
            )
        }
        Log.db.debug("记录缓存命中：\(bytes) 字节")
    }

    // MARK: - 读取

    /// 取包含指定时刻的那一天的桶；没有记录时为 nil。
    public func bucket(forDayContaining date: Date) throws -> TrafficStatsBucket? {
        let dayStart = TrafficStatsBucket.dayStart(for: date)
        return try database.dbQueue.read { db in
            try TrafficStatsRecord.fetchOne(db, key: dayStart)?.bucket
        }
    }

    /// 取最近若干天的桶，按日期倒序（最新在前）。没有记录的日期不会出现在结果里。
    public func recentBuckets(limit: Int = 30) throws -> [TrafficStatsBucket] {
        guard limit > 0 else { return [] }
        return try database.dbQueue.read { db in
            try TrafficStatsRecord
                .order(Column("dayStart").desc)
                .limit(limit)
                .fetchAll(db)
                .map(\.bucket)
        }
    }

    /// 取某区间内的桶，按日期升序。
    /// - Parameters:
    ///   - start: 区间起点（含）；nil 表示不限起点。
    ///   - end: 区间终点（不含）；默认现在。
    public func buckets(from start: Date? = nil, to end: Date = Date()) throws -> [TrafficStatsBucket] {
        try database.dbQueue.read { db in
            var request = TrafficStatsRecord.filter(Column("dayStart") < end)
            if let start {
                request = request.filter(Column("dayStart") >= start)
            }
            return try request.order(Column("dayStart").asc).fetchAll(db).map(\.bucket)
        }
    }

    /// 汇总某区间的流量。参数语义同 `buckets(from:to:)`。
    public func summary(from start: Date? = nil, to end: Date = Date()) throws -> TrafficStatsSummary {
        TrafficStatsSummary.aggregate(try buckets(from: start, to: end))
    }

    /// 清空全部流量统计。
    public func clearAll() throws {
        try database.dbQueue.write { db in
            _ = try TrafficStatsRecord.deleteAll(db)
        }
    }

    // MARK: - 列名白名单

    /// 接入方式 → 列名。刻意用 switch 而不是 `networkType.rawValue + "Bytes"`：
    /// 列名一旦由运行时字符串拼出来，SQL 里就出现了一条「外部输入 → 语句」的路径；
    /// switch 让合法列名在编译期固定，改名时也不会漏掉这里。
    private static func column(for type: TrafficNetworkType) -> String {
        switch type {
        case .wifi: return "wifiBytes"
        case .wired: return "wiredBytes"
        case .cellular: return "cellularBytes"
        case .other: return "otherBytes"
        }
    }

    /// 用途 → 列名。
    private static func column(for source: TrafficUsageSource) -> String {
        switch source {
        case .playback: return "playbackNetworkBytes"
        case .download: return "downloadNetworkBytes"
        }
    }
}
