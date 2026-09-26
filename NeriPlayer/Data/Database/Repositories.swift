// Repositories.swift
// NeriPlayer macOS —— 库/歌单/收藏的读写入口（移植规划 M2-T3，接口按 M2-T4 提前定稿）。
//
// 分层：DatabaseProvider 管连接与迁移，本文件管「怎么读写」。Repository 是无状态的值类型，
// 每次调用直接走 dbQueue 的短事务——歌单的增删改（改 position、更新 updatedAt、写 entries）
// 都在同一个 write 事务里完成，外部看不到中间态。
//
// 对外返回 Core 的 Track / PlaylistInfo（值类型），不把 GRDB 的 Record 类型漏出去：
// UI 与队列层因此完全不依赖 GRDB，M3 之后换存储实现也不影响调用方。
//
// 为什么 Track 的 Replace 语义要连删：`replaceLibrary` 面对的是「扫描完整目录后得到的一份
// 权威清单」，清单里没有的曲目就是已从盘上消失的曲目。删 Track 会经外键级联清掉它的
// 收藏与歌单条目——这是有意的（歌单不该留下指向不存在文件的行），文档里写明以免被当成 bug。

import Foundation
import GRDB

// MARK: - 对外值类型

/// 歌单的对外表示。只含列表页需要的字段，曲目内容用 `entries(playlistId:)` 单独取。
public struct PlaylistInfo: Identifiable, Equatable, Sendable {

    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, name: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - 错误

/// 仓库层的可归因错误。数据库约束类的失败（外键、UNIQUE）直接透传 GRDB 的 `DatabaseError`，
/// 这里只包住「调用方给了不存在的 id」这类语义错误。
public enum RepositoryError: Error, LocalizedError, Equatable {
    /// 目标歌单不存在。
    case playlistNotFound(UUID)
    /// 目标曲目不存在。
    case trackNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .playlistNotFound(let id):
            return "歌单不存在：\(id.uuidString)"
        case .trackNotFound(let id):
            return "曲目不存在：\(id.uuidString)"
        }
    }
}

// MARK: - 媒体库

/// Track 表的读写。
public struct LibraryRepository: Sendable {

    private let database: DatabaseProvider

    public init(_ database: DatabaseProvider) {
        self.database = database
    }

    /// 批量 upsert（新增或按 url 覆盖）。
    ///
    /// 冲突判定交给表上的 UNIQUE(url)：同一文件重复入库不会产生第二行；
    /// 已在库的曲目保留其原始 id（GRDB 的 upsert 不改主键列），因此队列里
    /// 正在引用的 id 不会因为一次重扫描而失效。
    /// - Returns: 本次写入的曲目数。
    @discardableResult
    public func upsertTracks(_ tracks: [Track]) throws -> Int {
        guard !tracks.isEmpty else { return 0 }
        try database.dbQueue.write { db in
            for track in tracks {
                try TrackRecord(track: track).upsert(db)
            }
        }
        Log.db.debug("媒体库 upsert \(tracks.count) 首")
        return tracks.count
    }

    /// 用给定清单整体替换媒体库内容。
    ///
    /// 语义：清单里的曲目按 url upsert；库里存在但清单里没有的曲目被删除。
    /// 删除会经外键级联清掉这些曲目的收藏与歌单条目（见文件头说明）。
    /// 传空数组等于清空媒体库（连带收藏与歌单条目）。
    /// - Returns: 删除的曲目数。
    @discardableResult
    public func replaceLibrary(_ tracks: [Track]) throws -> Int {
        let urls = tracks.map { TrackRecord.urlString(for: $0.url) }
        var deleted = 0
        try database.dbQueue.write { db in
            for track in tracks {
                try TrackRecord(track: track).upsert(db)
            }
            // 保持清单的曲目：NOT IN 的占位符按清单长度生成，空清单时直接清空全表。
            if urls.isEmpty {
                deleted = try TrackRecord.deleteAll(db)
            } else {
                let placeholders = databaseQuestionMarks(count: urls.count)
                deleted = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM \(DatabaseSchema.track) WHERE url NOT IN (\(placeholders))",
                    arguments: StatementArguments(urls)
                ) ?? 0
                try db.execute(
                    sql: "DELETE FROM \(DatabaseSchema.track) WHERE url NOT IN (\(placeholders))",
                    arguments: StatementArguments(urls)
                )
            }
            // 被删曲目在歌单里的条目已由外键级联移除，位置随之出现空洞，压实。
            if deleted > 0 {
                try PlaylistRepository.compactPositions(db: db)
            }
        }
        Log.db.info("媒体库替换完成：写入 \(tracks.count) 首，删除 \(deleted) 首")
        return deleted
    }

    /// 全库曲目。顺序稳定（createdAt + url），便于测试与 UI 分页。
    public func allTracks() throws -> [Track] {
        try database.dbQueue.read { db in
            try TrackRecord
                .order(Column("createdAt"), Column("url"))
                .fetchAll(db)
                .map { $0.toTrack() }
        }
    }

    /// 按 URL 查单曲。URL 经 `TrackRecord.urlString(for:)` 归一化后比对，与 upsert 的键一致。
    public func trackByUrl(_ url: URL) throws -> Track? {
        let key = TrackRecord.urlString(for: url)
        return try database.dbQueue.read { db in
            try TrackRecord.filter(Column("url") == key).fetchOne(db)?.toTrack()
        }
    }

    /// 按 id 查单曲。M2-T8 的播放入口（队列里只有 id 时需要拿回完整曲目）会用。
    public func track(id: UUID) throws -> Track? {
        try database.dbQueue.read { db in
            try TrackRecord.filter(key: id).fetchOne(db)?.toTrack()
        }
    }

    /// 删除单曲；返回是否真的删了。收藏与歌单条目随之级联删除。
    ///
    /// 级联删除发生在 SQLite 内部，仓库层拿不到「哪些歌单被动了」的通知，所以删除后统一
    /// 压实一遍受影响歌单的 position，维持 0..n-1 连续的不变式。
    @discardableResult
    public func deleteTrack(id: UUID) throws -> Bool {
        try database.dbQueue.write { db in
            let removed = try TrackRecord.deleteOne(db, key: id)
            if removed {
                try PlaylistRepository.compactPositions(db: db)
            }
            return removed
        }
    }
}

// MARK: - 歌单

/// Playlist / PlaylistEntry 的读写。
///
/// 位置不变式：同一歌单内 position 恒为 0..n-1 连续无空洞。
/// 增删改排序的每个入口都在同一事务里做完整重排，调用方不需要自己修补序号。
public struct PlaylistRepository: Sendable {

    private let database: DatabaseProvider

    public init(_ database: DatabaseProvider) {
        self.database = database
    }

    // MARK: 歌单本体

    /// 新建空歌单。同名允许（歌单名不是键），需要唯一性时由 UI 层决定。
    @discardableResult
    public func create(name: String) throws -> PlaylistInfo {
        let record = PlaylistRecord(name: name)
        try database.dbQueue.write { db in
            try record.insert(db)
        }
        Log.db.info("新建歌单：\(name, privacy: .public)")
        return record.info
    }

    /// 改名并推进 updatedAt。
    public func rename(id: UUID, to name: String) throws {
        try database.dbQueue.write { db in
            guard let record = try PlaylistRecord.filter(key: id).fetchOne(db) else {
                throw RepositoryError.playlistNotFound(id)
            }
            record.name = name
            record.updatedAt = Date()
            try record.update(db, columns: ["name", "updatedAt"])
        }
    }

    /// 删除歌单。PlaylistEntry 经外键级联一并删除；Track 与 Favorite 不受影响。
    /// 目标不存在时抛 `playlistNotFound`（静默成功会把调用方的 id 错误藏起来）。
    public func delete(id: UUID) throws {
        let removed = try database.dbQueue.write { db in
            try PlaylistRecord.deleteOne(db, key: id)
        }
        guard removed else { throw RepositoryError.playlistNotFound(id) }
        Log.db.info("删除歌单：\(id.uuidString, privacy: .public)")
    }

    /// 全部歌单，按创建时间升序（同名时间用 id 兜底，保证顺序确定）。
    public func list() throws -> [PlaylistInfo] {
        try database.dbQueue.read { db in
            try PlaylistRecord
                .order(Column("createdAt"), Column("id"))
                .fetchAll(db)
                .map(\.info)
        }
    }

    // MARK: 曲目

    /// 把曲目追加到歌单末尾。
    ///
    /// 已在歌单内的曲目不再插入（对齐 M2-T4 的去重语义），直接返回它当前的位置——
    /// UI 的「加入歌单」右键菜单因此不需要先查重。
    /// - Returns: 该曲目在歌单中的位置。
    @discardableResult
    public func addTrack(playlistId: UUID, trackId: UUID) throws -> Int {
        try database.dbQueue.write { db in
            guard try PlaylistRecord.exists(db, key: playlistId) else {
                throw RepositoryError.playlistNotFound(playlistId)
            }
            guard try TrackRecord.exists(db, key: trackId) else {
                throw RepositoryError.trackNotFound(trackId)
            }
            if let existing = try PlaylistEntryRecord
                .filter(Column("playlistId") == playlistId && Column("trackId") == trackId)
                .fetchOne(db) {
                return existing.position
            }
            let next = try PlaylistRepository.nextPosition(in: playlistId, db: db)
            try PlaylistEntryRecord(playlistId: playlistId, trackId: trackId, position: next).insert(db)
            try PlaylistRepository.touch(playlistId, db: db)
            return next
        }
    }

    /// 从歌单移除曲目，并压实后续位置。曲目不在歌单内时静默返回。
    public func removeTrack(playlistId: UUID, trackId: UUID) throws {
        try database.dbQueue.write { db in
            try PlaylistEntryRecord
                .filter(Column("playlistId") == playlistId && Column("trackId") == trackId)
                .deleteAll(db)
            try PlaylistRepository.renumber(playlistId, db: db)
            try PlaylistRepository.touch(playlistId, db: db)
        }
    }

    /// 按给定顺序重排歌单。
    ///
    /// `trackIds` 是要排在前面的曲目（拖拽一次通常只涉及被拖动的那几首），
    /// 未出现在列表里的 entry 保持原有相对顺序、接在其后。
    /// 列表里不属于该歌单的 id 被忽略。无论传入什么，落库后 position 恒为 0..n-1 连续。
    public func reorder(playlistId: UUID, trackIds: [UUID]) throws {
        try database.dbQueue.write { db in
            guard try PlaylistRecord.exists(db, key: playlistId) else {
                throw RepositoryError.playlistNotFound(playlistId)
            }
            let entries = try PlaylistRepository.entriesInOrder(playlistId, db: db)
            var byTrack: [UUID: PlaylistEntryRecord] = [:]
            for entry in entries { byTrack[entry.trackId] = entry }

            var ordered: [PlaylistEntryRecord] = []
            var seen: Set<UUID> = []
            for trackId in trackIds {
                guard let entry = byTrack[trackId], seen.insert(trackId).inserted else { continue }
                ordered.append(entry)
            }
            for entry in entries where !seen.contains(entry.trackId) {
                ordered.append(entry)
            }
            try PlaylistRepository.writePositions(ordered, db: db)
            try PlaylistRepository.touch(playlistId, db: db)
        }
    }

    /// 歌单内容，按 position 升序。position 的不变式保证返回顺序即用户看到的顺序。
    public func entries(playlistId: UUID) throws -> [Track] {
        try database.dbQueue.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT Track.* FROM Track
                JOIN PlaylistEntry ON PlaylistEntry.trackId = Track.id
                WHERE PlaylistEntry.playlistId = ?
                ORDER BY PlaylistEntry.position
                """, arguments: [playlistId]).map { $0.toTrack() }
        }
    }

    // MARK: 内部

    /// 追加位置：现有最大 position + 1；空歌单为 0。
    private static func nextPosition(in playlistId: UUID, db: Database) throws -> Int {
        let maxPosition = try Int.fetchOne(
            db,
            sql: "SELECT MAX(position) FROM \(DatabaseSchema.playlistEntry) WHERE playlistId = ?",
            arguments: [playlistId]
        )
        return (maxPosition ?? -1) + 1
    }

    private static func entriesInOrder(_ playlistId: UUID, db: Database) throws -> [PlaylistEntryRecord] {
        try PlaylistEntryRecord
            .filter(Column("playlistId") == playlistId)
            .order(Column("position"))
            .fetchAll(db)
    }

    /// 删除后再压实序号（0..n-1）。
    private static func renumber(_ playlistId: UUID, db: Database) throws {
        try writePositions(entriesInOrder(playlistId, db: db), db: db)
    }

    /// 压实「所有」歌单的 position。
    ///
    /// 供级联删除路径调用：SQLite 的 ON DELETE CASCADE 直接动了 PlaylistEntry 表，
    /// Repository 无从得知是哪些歌单受影响，因此整体扫一遍所有出现过的 playlistId。
    /// 级联删除的调用频率低（删曲目、整库替换），全量压实的代价可接受。
    /// 注：本方法假定调用方已持有写事务。
    static func compactPositions(db: Database) throws {
        let playlistIds = try UUID.fetchAll(
            db,
            sql: "SELECT DISTINCT playlistId FROM \(DatabaseSchema.playlistEntry)"
        )
        for playlistId in playlistIds {
            try renumber(playlistId, db: db)
        }
    }

    /// 按给定顺序写回 position。逐行 UPDATE 而不是 CASE 语句：n 是单歌单量级（数十到数百），
    /// 事务内的逐条更新更好读，也便于将来插入日志。
    private static func writePositions(_ ordered: [PlaylistEntryRecord], db: Database) throws {
        for (position, entry) in ordered.enumerated() where entry.position != position {
            entry.position = position
            try entry.update(db, columns: ["position"])
        }
    }

    /// 推进歌单的 updatedAt。
    private static func touch(_ playlistId: UUID, db: Database) throws {
        try db.execute(
            sql: "UPDATE \(DatabaseSchema.playlist) SET updatedAt = ? WHERE id = ?",
            arguments: [Date(), playlistId]
        )
    }
}
