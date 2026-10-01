// PlaybackRepositories.swift
// NeriPlayer macOS —— M3-T1 的持久化读写入口：播放历史 / 播放统计 / 播放器现场。
//
// 分层约定与 M2 的 Repositories.swift 一致：Repository 是无状态值类型，每次调用走 dbQueue 的
// 短事务，对外只返回 Core 值类型（PlayHistoryEntry / PlaybackStats / PlayerState），
// 不把 GRDB 的 Record 类型漏出去。
//
// 本任务边界：这里只做「表怎么读写」。
//   - 统计的累加口径与批量 flush 时机属 M3-T2（写入管道），本层只提供逐行的 upsert / 查询；
//   - 现场的「退出保存 / 启动恢复」编排属 M3-T3，本层只提供保存与读取接口。
//
// 外键与级联：PlayHistory / PlaybackStats / PlaybackStatsDailyBucket 三张表的 trackId 都对
// Track 有外键。删除 Track（或整库替换移除曲目）时，SQLite 的 ON DELETE CASCADE 会一并清掉
// 这些行，不留指向不存在文件的孤儿数据 —— 与 M2 对收藏/歌单条目的处理同源。

import Foundation
import GRDB

// MARK: - 统计写入管道落库（M3-T2）

/// 把 Core 层统计管道（PlaybackStatsRecorder）交来的增量批量落库。
///
/// 为什么落库要单独做一个入口，而不是让管道直接调 Repository 的两个 upsert：
///   1) 增量是「加数」而不是「绝对值」，而 M3-T1 的 upsert 是整行覆盖（注释里写明
///      「本层不做累加」）。累加必须发生在这里 —— 先读既有行、加上增量、再写回；
///   2) 一次 flush 的整批增量必须一起成功或一起失败：recorder 的幂等与重试建立在
///      「抛出 = 整批未落库」之上，若某一条写了一半，并回内存重试就会把已落库的那条双计。
///      因此整批放在同一个写事务里，任意一条失败即整事务回滚；
///   3) 每日桶与累计行要一起更新，放同一事务也保证「累计次数」与「当日次数」不会各写一半。
///
/// 时间语义：firstPlayedAt 取最小、lastPlayedAt 取最大（对齐原库 minPositiveTimestamp /
/// maxOf），因此无论增量以什么顺序到达，结果都与合并顺序无关。
public struct PlaybackStatsFlushHandler {

    private let database: DatabaseProvider

    public init(_ database: DatabaseProvider) {
        self.database = database
    }

    /// 批量落库。空数组直接返回。抛出即整批未落库（事务回滚）。
    public func callAsFunction(_ deltas: [PlaybackStatsDelta]) throws {
        guard !deltas.isEmpty else { return }
        try database.dbQueue.write { db in
            for delta in deltas where !delta.isEmpty {
                try Self.apply(delta, in: db)
            }
        }
        Log.db.debug("统计落库：\(deltas.count) 条增量")
    }

    /// 把一条增量并进累计行与每日桶。同一事务内执行。
    private static func apply(_ delta: PlaybackStatsDelta, in db: Database) throws {
        // 累计行（一首歌一行）。
        let existingStats = try PlaybackStatsRecord.fetchOne(db, key: delta.trackId)
        let stats = PlaybackStats(
            trackId: delta.trackId,
            totalListenSeconds: (existingStats?.totalListenSeconds ?? 0) + delta.listenSeconds,
            playCount: (existingStats?.playCount ?? 0) + delta.playCount,
            firstPlayedAt: minDate(existingStats?.firstPlayedAt, delta.firstPlayedAt),
            lastPlayedAt: maxDate(existingStats?.lastPlayedAt, delta.lastPlayedAt)
        )
        try PlaybackStatsRecord(stats: stats).save(db)

        // 每日桶（(dayStart, trackId) 复合主键）。
        let existingBucket = try PlaybackStatsDailyBucketRecord.fetchOne(
            db,
            key: ["dayStart": delta.dayStart, "trackId": delta.trackId]
        )
        let bucket = PlaybackStatsDailyBucket(
            dayStart: delta.dayStart,
            trackId: delta.trackId,
            totalListenSeconds: (existingBucket?.totalListenSeconds ?? 0) + delta.listenSeconds,
            playCount: (existingBucket?.playCount ?? 0) + delta.playCount,
            firstPlayedAt: minDate(existingBucket?.firstPlayedAt, delta.firstPlayedAt),
            lastPlayedAt: maxDate(existingBucket?.lastPlayedAt, delta.lastPlayedAt)
        )
        try PlaybackStatsDailyBucketRecord(bucket: bucket).save(db)
    }

    /// 取两个可空时间里较早的一个；都为 nil 时保持 nil。
    private static func minDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): return min(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    /// 取两个可空时间里较晚的一个；都为 nil 时保持 nil。
    private static func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }
}

// MARK: - 播放历史

/// PlayHistory 表的读写。
///
/// 语义：一首歌一行（trackId 主键）。重复记录只刷新 playedAt（与可选记忆位置），
/// 对齐 Android 原库「同一首歌在历史里只有一条」的行为；「最近播放」列表因此天然不重复。
public struct PlayHistoryRepository: Sendable {

    private let database: DatabaseProvider

    public init(_ database: DatabaseProvider) {
        self.database = database
    }

    /// 记录一次播放（upsert）。
    ///
    /// - Parameters:
    ///   - trackId: 曲目标识。必须是库中已存在的 Track，否则外键约束会让写入失败。
    ///   - playedAt: 播放时刻，默认当前时间。
    ///   - resumePositionSeconds: 记忆播放位置；传 nil 表示保留既有值（只刷新播放时间）。
    /// - Returns: 写入后的历史行。
    @discardableResult
    public func record(
        trackId: UUID,
        playedAt: Date = Date(),
        resumePositionSeconds: Double? = nil
    ) throws -> PlayHistoryEntry {
        try database.dbQueue.write { db in
            let existing = try PlayHistoryRecord.fetchOne(db, key: trackId)
            let record = PlayHistoryRecord(
                trackId: trackId,
                playedAt: playedAt,
                resumePositionSeconds: resumePositionSeconds ?? existing?.resumePositionSeconds ?? 0
            )
            try record.save(db)
            return record.entry
        }
    }

    /// 更新某曲的记忆播放位置；曲目不在历史中时插入一行（playedAt 取既有值或当前时间）。
    ///
    /// 与 record 分开的理由：恢复现场时只更新位置、不改变「最后一次播放」的语义，
    /// 但两者都会让这一行存在。
    @discardableResult
    public func updateResumePosition(
        trackId: UUID,
        position: Double,
        playedAt: Date = Date()
    ) throws -> PlayHistoryEntry {
        try database.dbQueue.write { db in
            let existing = try PlayHistoryRecord.fetchOne(db, key: trackId)
            let record = PlayHistoryRecord(
                trackId: trackId,
                playedAt: existing?.playedAt ?? playedAt,
                resumePositionSeconds: position
            )
            try record.save(db)
            return record.entry
        }
    }

    /// 某曲的历史行；从未播放过为 nil。
    public func entry(trackId: UUID) throws -> PlayHistoryEntry? {
        try database.dbQueue.read { db in
            try PlayHistoryRecord.fetchOne(db, key: trackId)?.entry
        }
    }

    /// 记忆播放位置（秒）；无记录为 0。
    public func rememberedPosition(trackId: UUID) throws -> Double {
        try database.dbQueue.read { db in
            try PlayHistoryRecord.fetchOne(db, key: trackId)?.resumePositionSeconds ?? 0
        }
    }

    /// 最近播放，按 playedAt 倒序。playedAt 相同时用 trackId 兜底，保证顺序跨查询稳定。
    /// - Parameter limit: 最大条数；nil 表示全部。
    public func recent(limit: Int? = nil) throws -> [PlayHistoryEntry] {
        try database.dbQueue.read { db in
            var request = PlayHistoryRecord
                .order(Column("playedAt").desc, Column("trackId").asc)
            if let limit {
                request = request.limit(limit)
            }
            return try request.fetchAll(db).map(\.entry)
        }
    }

    /// 删除单曲历史。
    public func delete(trackId: UUID) throws {
        try database.dbQueue.write { db in
            _ = try PlayHistoryRecord.deleteOne(db, key: trackId)
        }
    }

    /// 清空历史（对齐原库 deleteAll）。
    public func clear() throws {
        try database.dbQueue.write { db in
            _ = try PlayHistoryRecord.deleteAll(db)
        }
    }

    /// 历史条数。
    public func count() throws -> Int {
        try database.dbQueue.read { db in
            try PlayHistoryRecord.fetchCount(db)
        }
    }
}

// MARK: - 播放统计

/// PlaybackStats / PlaybackStatsDailyBucket 的读写。
///
/// 本层不做累加：upsert 是「整行覆盖」，把一份权威的统计值写入。累加口径（阈值计数、
/// firstPlayedAt 取最小、lastPlayedAt 取最大、按日切桶）属 M3-T2 的写入管道，管道算好之后再调用这里。
public struct PlaybackStatsRepository: Sendable {

    private let database: DatabaseProvider

    public init(_ database: DatabaseProvider) {
        self.database = database
    }

    /// 写入（覆盖）某曲的累计统计。
    @discardableResult
    public func upsert(_ stats: PlaybackStats) throws -> PlaybackStats {
        try database.dbQueue.write { db in
            let record = PlaybackStatsRecord(stats: stats)
            try record.save(db)
            return record.stats
        }
    }

    /// 某曲的累计统计；无记录为 nil。
    public func stats(trackId: UUID) throws -> PlaybackStats? {
        try database.dbQueue.read { db in
            try PlaybackStatsRecord.fetchOne(db, key: trackId)?.stats
        }
    }

    /// 全部统计，按 lastPlayedAt 倒序（最近播放在前）。
    /// lastPlayedAt 为 NULL 的排末尾；同值用 trackId 兜底保证稳定。
    public func all() throws -> [PlaybackStats] {
        try database.dbQueue.read { db in
            try PlaybackStatsRecord
                .order(Column("lastPlayedAt").desc, Column("trackId").asc)
                .fetchAll(db)
                .map(\.stats)
        }
    }

    /// 删除单曲统计，连带其全部每日桶（同一事务）。
    ///
    /// 每日桶的 trackId 外键指向 Track 而不是 PlaybackStats（便于桶独立于统计行存在，
    /// 且删曲目时两表经同一条外键一并被清），因此这里显式删除桶 —— 只删统计行会把桶留成孤儿。
    public func delete(trackId: UUID) throws {
        try database.dbQueue.write { db in
            try PlaybackStatsDailyBucketRecord
                .filter(Column("trackId") == trackId)
                .deleteAll(db)
            _ = try PlaybackStatsRecord.deleteOne(db, key: trackId)
        }
    }

    /// 清空全部统计与每日桶。
    public func clear() throws {
        try database.dbQueue.write { db in
            _ = try PlaybackStatsDailyBucketRecord.deleteAll(db)
            _ = try PlaybackStatsRecord.deleteAll(db)
            let clear = try JSONEncoder().encode(SyncSnapshot.milliseconds())
            try db.execute(sql: "INSERT INTO SyncJournal (key, value) VALUES ('statsClearedAt', ?) " +
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [clear])
        }
    }

    // MARK: 每日桶

    /// 写入（覆盖）某个每日桶。
    @discardableResult
    public func upsert(bucket: PlaybackStatsDailyBucket) throws -> PlaybackStatsDailyBucket {
        try database.dbQueue.write { db in
            let record = PlaybackStatsDailyBucketRecord(bucket: bucket)
            try record.save(db)
            return record.bucket
        }
    }

    /// 某曲某天的桶；无记录为 nil。
    public func bucket(trackId: UUID, dayStart: Date) throws -> PlaybackStatsDailyBucket? {
        try database.dbQueue.read { db in
            try PlaybackStatsDailyBucketRecord.fetchOne(
                db,
                key: ["dayStart": dayStart, "trackId": trackId]
            )?.bucket
        }
    }

    /// 某曲的全部每日桶，按日期升序（时间序列）。走 (trackId, dayStart) 复合索引。
    public func buckets(trackId: UUID) throws -> [PlaybackStatsDailyBucket] {
        try database.dbQueue.read { db in
            try PlaybackStatsDailyBucketRecord
                .filter(Column("trackId") == trackId)
                .order(Column("dayStart").asc)
                .fetchAll(db)
                .map(\.bucket)
        }
    }

    /// 指定日期区间的桶（含起点、不含终点），按日期升序。用于「最近七天/本月」这类窗口聚合。
    public func buckets(from start: Date, to end: Date) throws -> [PlaybackStatsDailyBucket] {
        try database.dbQueue.read { db in
            try PlaybackStatsDailyBucketRecord
                .filter(Column("dayStart") >= start && Column("dayStart") < end)
                .order(Column("dayStart").asc, Column("trackId").asc)
                .fetchAll(db)
                .map(\.bucket)
        }
    }

    /// 删除某曲某天的桶。
    public func deleteBucket(trackId: UUID, dayStart: Date) throws {
        try database.dbQueue.write { db in
            _ = try PlaybackStatsDailyBucketRecord.deleteOne(
                db,
                key: ["dayStart": dayStart, "trackId": trackId]
            )
        }
    }

    /// 桶总数。
    public func bucketCount() throws -> Int {
        try database.dbQueue.read { db in
            try PlaybackStatsDailyBucketRecord.fetchCount(db)
        }
    }
}

// MARK: - 播放器现场

/// PlayerState 单行表的读写。只维护一行（id = PlayerStateRecord.singletonID）。
///
/// 边界：本任务只做 schema + Record + 存取接口。真正「何时保存 / 何时恢复」的编排属 M3-T3，
/// 调用方（M3-T3）拿 PlayerState.queueState 交给 QueueManager 即可。
public struct PlayerStateRepository: Sendable {

    private let database: DatabaseProvider

    public init(_ database: DatabaseProvider) {
        self.database = database
    }

    /// 保存（覆盖）现场。永远只有一行，第二次保存覆盖第一行。
    public func save(_ state: PlayerState) throws {
        try database.dbQueue.write { db in
            try PlayerStateRecord(state: state).save(db)
        }
        let indexLabel = state.currentIndex.map(String.init) ?? "nil"
        Log.db.debug("保存播放器现场：队列 \(state.tracks.count) 首，索引 \(indexLabel)")
    }

    /// 读取现场；从未保存或已被清除为 nil。
    public func load() throws -> PlayerState? {
        try database.dbQueue.read { db in
            try PlayerStateRecord.fetchOne(db, key: PlayerStateRecord.singletonID)?.state
        }
    }

    /// 清除现场（例如用户退出时选择不恢复）。
    public func clear() throws {
        try database.dbQueue.write { db in
            _ = try PlayerStateRecord.deleteOne(db, key: PlayerStateRecord.singletonID)
        }
    }
}
