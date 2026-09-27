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

// MARK: - 媒体库值类型

/// 媒体库列表的排序键。
public enum LibrarySortKey: String, Sendable, CaseIterable {
    /// 曲名。
    case title
    /// 歌手。
    case artist
    /// 专辑。
    case album
    /// 入库时间（Track.createdAt）。
    case addedAt
}

/// 去重时的保留策略。
public enum LibraryDedupeStrategy: String, Sendable, CaseIterable {
    /// 保留 createdAt 最新的那条（默认；对齐 Android 版「后导入的覆盖先导入的」直觉）。
    case newestCreated
    /// 保留文件体积最大的那条（通常是从低码率试听版升级到无损版后的结果）。
    case largestFile
}

/// 一次去重的结果。
public struct LibraryDedupeResult: Equatable, Sendable {

    /// 判定出重复并执行了保留/删除的「重复组」数。
    public var duplicateGroups: Int
    /// 被删除曲目的 id（保留者不在其中）。
    public var removedTrackIds: [UUID]

    /// 被删除的曲目数。
    public var removedCount: Int { removedTrackIds.count }

    public init(duplicateGroups: Int, removedTrackIds: [UUID]) {
        self.duplicateGroups = duplicateGroups
        self.removedTrackIds = removedTrackIds
    }
}

/// 一次「扫描清单合并进库」的结果。
public struct LibraryMergeResult: Equatable, Sendable {

    /// 新增（url 不在库中）。
    public var inserted: Int
    /// 更新（url 已在库中且内容有变化）。
    public var updated: Int
    /// 跳过（url 已在库中且内容完全一致）。
    public var skipped: Int
    /// 移除（库中有、清单中没有）。
    public var removed: Int
    /// 被移除曲目的 id，供调用方顺带清理这些曲目的附属资源（如封面文件）。
    public var removedTrackIds: [UUID]

    public init(inserted: Int, updated: Int, skipped: Int, removed: Int, removedTrackIds: [UUID]) {
        self.inserted = inserted
        self.updated = updated
        self.skipped = skipped
        self.removed = removed
        self.removedTrackIds = removedTrackIds
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

    /// 库文件路径。对外暴露是为了让上层（如同步服务）能在库文件旁边放置附属资源
    /// （封面目录），而不必各自重算 Application Support 路径。
    public var databaseURL: URL { database.databaseURL }

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

    // MARK: 排序

    /// 按指定字段排序返回完整库条目（含专辑/体积/格式/封面）。
    ///
    /// 为什么返回 `LibraryTrack` 而不是 `Track`：按专辑排序、列表页显示封面与音质角标
    /// （M2-T5）都需要这些字段，只返回播放子集会让调用方再查一次库。返回类型与文件头
    /// 的「不外漏 GRDB Record」约定一致——LibraryTrack 是 Core 词表里的值类型。
    ///
    /// 排序细节：文本列统一用 SQLite 的 `localizedStandardCompare` 排序（Finder 同款规则，
    /// 中英文混排与「track2 < track10」这类自然序都符合直觉），空值一律排到末尾；
    /// 末尾再按 url 兜底，保证同值行之间的顺序跨查询稳定（测试与分页都依赖这一点）。
    ///
    /// - Parameters:
    ///   - key: 排序字段。
    ///   - ascending: 是否升序；降序时空值仍排在末尾（`descNullsFirst` 的反面不提供，
    ///     列表页不需要「空值置顶」）。
    public func allTracksSorted(by key: LibrarySortKey, ascending: Bool = true) throws -> [LibraryTrack] {
        let column: Column
        switch key {
        case .title: column = Column("title")
        case .artist: column = Column("artist")
        case .album: column = Column("album")
        case .addedAt: column = Column("createdAt")
        }

        // addedAt 是数值（Date），直接 asc/desc 即可；文本列加排序规则，空值置末尾。
        let primary: any SQLOrderingTerm
        if key == .addedAt {
            primary = ascending ? column.asc : column.desc
        } else {
            let collated = column.collating(.localizedStandardCompare)
            primary = ascending ? collated.ascNullsLast : collated.desc
        }

        return try database.dbQueue.read { db in
            try TrackRecord
                .order(primary, Column("url").asc)
                .fetchAll(db)
                .map { $0.toLibraryTrack() }
        }
    }

    // MARK: 扫描清单合并

    /// 把一份「目录扫描清单」合并进库，并移除该目录下已从盘上消失的曲目。
    ///
    /// 与 `replaceLibrary` 的区别（本任务是这条路径，故说明选择）：`replaceLibrary` 的语义是
    /// 「清单即全库」，会删掉清单外的一切；但扫描是**按目录**进行的，库可以同时含多个目录
    /// （M2-T2 的 scanner 就支持多目录共用缓存），用 `replaceLibrary` 扫 A 目录会误删 B 目录。
    /// 因此这里改成：清单里的 url 按 `url`（幂等键）upsert，删除范围**限定在本次扫描的根目录子树内**
    /// （`root` 参数），子树外的曲目一律不动。传入 `root: nil` 时不删任何曲目。
    ///
    /// createdAt 保留：更新既有行时只覆盖「文件当前状态」相关列，主键与 createdAt 不动；
    /// 否则每扫一次「首次入库时间」都会刷新，按 createdAt 裁决的去重结果会随之漂移。
    ///
    /// - Returns: 新增/更新/跳过/移除的数量，以及被移除曲目的 id（供调用方清理封面等附属资源）。
    @discardableResult
    public func mergeScanned(
        _ tracks: [LibraryTrack],
        removingMissingUnder root: URL?
    ) throws -> LibraryMergeResult {
        let rootPrefix = Self.subtreePrefix(for: root)
        var inserted = 0
        var updated = 0
        var skipped = 0
        var removedIds: [UUID] = []

        try database.dbQueue.write { db in
            // 一次性把既有行读进内存：库是「数千行」量级，比逐条查询更省往返，
            // 也让「哪些 url 已存在」与「哪些行落在子树内」两个判断共用同一份快照。
            let existing = try TrackRecord.fetchAll(db)
            var byUrl: [String: TrackRecord] = [:]
            byUrl.reserveCapacity(existing.count)
            for record in existing { byUrl[record.url] = record }

            var incomingUrls: Set<String> = []
            incomingUrls.reserveCapacity(tracks.count)

            for track in tracks {
                let record = TrackRecord(libraryTrack: track)
                incomingUrls.insert(record.url)

                guard let current = byUrl[record.url] else {
                    try record.insert(db)
                    inserted += 1
                    continue
                }

                if Self.hasContentChanges(record, comparedTo: current) {
                    // 只覆盖内容列：id 是主键、createdAt 是「首次入库时间」，都不随重扫改写。
                    try db.execute(sql: """
                        UPDATE \(DatabaseSchema.track)
                        SET title = ?, artist = ?, album = ?, durationSeconds = ?, fileSize = ?,
                            format = ?, fingerprintMtime = ?, coverPath = ?
                        WHERE id = ?
                        """, arguments: [
                        record.title, record.artist, record.album, record.durationSeconds,
                        record.fileSize, record.format, record.fingerprintMtime, record.coverPath,
                        current.id
                    ])
                    updated += 1
                } else {
                    skipped += 1
                }
            }

            // 删除范围限定在本次扫描子树内：先把子树内「本轮未再出现」的行挑出来。
            if let rootPrefix {
                let stale = existing.filter { record in
                    // 路径两侧都走 standardizedFileURL：macOS 上临时目录可能是 /var/... 而目录枚举
                    // 返回 /private/var/...，只有统一标准化后前缀比较才可靠。
                    guard let recordURL = Self.url(record.url) else { return false }
                    guard Self.comparablePath(for: recordURL).hasPrefix(rootPrefix) else { return false }
                    return !incomingUrls.contains(record.url)
                }
                if !stale.isEmpty {
                    removedIds = stale.map(\.id)
                    // 级联删除（外键）负责清掉这些曲目的收藏与歌单条目；
                    // 歌单位置随之出现空洞，删完统一压实。
                    try TrackRecord.deleteAll(db, keys: removedIds)
                    try PlaylistRepository.compactPositions(db: db)
                }
            }
        }

        let result = LibraryMergeResult(
            inserted: inserted,
            updated: updated,
            skipped: skipped,
            removed: removedIds.count,
            removedTrackIds: removedIds
        )
        let summary = "媒体库合并：新增 \(result.inserted)，更新 \(result.updated)，"
            + "跳过 \(result.skipped)，移除 \(result.removed)"
        Log.db.info("\(summary, privacy: .public)")
        return result
    }

    // MARK: 去重

    /// 按「归一化标题 + 归一化歌手 + 时长」判定重复组并删除多余行。
    ///
    /// 判定规则（任务书指定）：标题与歌手各自做大小写/变音符/全半角折叠并压缩空白后相等，
    /// 且时长相差不超过 3 秒。两个时长都为 nil 视为同组；只有一个为 nil 时不视为重复
    /// （无法比较时保守放行，宁可留两条也不误删）。
    ///
    /// 为什么这条规则能覆盖真实重复：同一首歌从不同来源导入时，标题/歌手字形常有差异
    /// （大小写、全角、带不带变音符），时长也可能因为编码器填充差零点几秒；而「归一化文本
    /// 相等 + 时长近似」几乎不会把两首不同的歌判成一首。
    ///
    /// 删除在**单个事务内**完成：挑出的重复行经外键级联清掉收藏与歌单条目，删完压实歌单位置，
    /// 外部看不到「删了一半」的中间态。
    ///
    /// - Parameter strategy: 保留哪一条，见 `LibraryDedupeStrategy`。
    /// - Returns: 重复组数与实际删除的曲目 id。
    @discardableResult
    public func dedupe(strategy: LibraryDedupeStrategy = .newestCreated) throws -> LibraryDedupeResult {
        try database.dbQueue.write { db in
            let records = try TrackRecord.fetchAll(db)
            var groups: [String: [TrackRecord]] = [:]
            for record in records {
                groups[Self.dedupeKey(for: record), default: []].append(record)
            }

            var groupCount = 0
            var removedIds: [UUID] = []
            for (_, bucket) in groups {
                for cluster in Self.durationClusters(bucket) where cluster.count > 1 {
                    groupCount += 1
                    let keeper = Self.keeper(of: cluster, strategy: strategy)
                    let losers = cluster.filter { $0.id != keeper.id }.map(\.id)
                    removedIds.append(contentsOf: losers)
                }
            }

            guard !removedIds.isEmpty else {
                return LibraryDedupeResult(duplicateGroups: 0, removedTrackIds: [])
            }
            // 级联删除顺带清掉这些曲目的 PlaylistEntry 与 Favorite 引用。
            try TrackRecord.deleteAll(db, keys: removedIds)
            try PlaylistRepository.compactPositions(db: db)
            let summary = "媒体库去重：\(groupCount) 组，删除 \(removedIds.count) 首"
                + "（策略 \(strategy.rawValue)）"
            Log.db.info("\(summary, privacy: .public)")
            return LibraryDedupeResult(duplicateGroups: groupCount, removedTrackIds: removedIds)
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

    /// 库中「url 字符串 -> 既有条目」的映射，供同步服务复用库 id 与判定封面是否需要重写。
    ///
    /// 为什么要按库 id 走：扫描清单里的 `Track.id` 只在「指纹未变、复用缓存」时稳定；文件内容一变，
    /// scanner 会给出全新的 UUID，而库里的同一文件仍是旧 id（`mergeScanned` 更新时保留旧 id，
    /// 以免队列引用的 id 失效）。同步服务据此把封面文件名固定到库 id 上。
    public func existingTracksByURL() throws -> [String: LibraryTrack] {
        try database.dbQueue.read { db in
            let records = try TrackRecord.fetchAll(db)
            var map: [String: LibraryTrack] = [:]
            map.reserveCapacity(records.count)
            for record in records { map[record.url] = record.toLibraryTrack() }
            return map
        }
    }

    // MARK: 内部：合并/去重的纯函数

    /// 扫描根目录的「子树路径前缀」，用于把删除范围限定在本轮扫描的目录内。
    /// 末尾补 "/" 是为了让 `/music/a` 不会匹配到 `/music/ab`；根为 nil 时返回 nil（不删任何行）。
    private static func subtreePrefix(for root: URL?) -> String? {
        guard let root else { return nil }
        let path = comparablePath(for: root)
        return path.hasSuffix("/") ? path : path + "/"
    }

    /// 路径比较用的规范化形态：只对**父目录**解析符号链接，再拼回文件名。
    ///
    /// 为什么不动叶子：macOS 上 `/var` 与 `/private/var` 指向同一目录，目录枚举给出的路径常带
    /// `/private` 前缀而用户传入的根不带；`resolvingSymlinksInPath()`/`standardizedFileURL` 在
    /// **路径本身不存在**时不做解析，而被移除的曲目恰恰是已删文件，直接对它解析会原样返回
    /// `/private/var/...`，与根前缀对不上。父目录始终存在，对它解析稳定可靠，两侧于是都归一到
    /// `/var/...`，前缀比较才成立。
    private static func comparablePath(for url: URL) -> String {
        url.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent)
            .standardizedFileURL
            .path
    }

    /// 落库 url 字符串反解为 URL。与 `TrackRecord.urlString(for:)` 互逆。
    private static func url(_ urlString: String) -> URL? { URL(string: urlString) }

    /// 新记录相对既有记录是否有内容变化。
    ///
    /// 不比较 id 与 createdAt：前者是主键（重扫时新旧不一致属正常），后者是「首次入库时间」，
    /// 都不属于「文件当前状态」。coverPath 比较用「新的非空值优先、为空则沿用既有」的解析结果，
    /// 使「封面未变」不被误判为「封面被删除」（扫描器在未重读时不会重新产出封面字节）。
    private static func hasContentChanges(_ incoming: TrackRecord, comparedTo existing: TrackRecord) -> Bool {
        let resolvedCover = incoming.coverPath ?? existing.coverPath
        return incoming.title != existing.title
            || incoming.artist != existing.artist
            || incoming.album != existing.album
            || incoming.durationSeconds != existing.durationSeconds
            || incoming.fileSize != existing.fileSize
            || incoming.format != existing.format
            || incoming.fingerprintMtime != existing.fingerprintMtime
            || resolvedCover != existing.coverPath
    }

    /// 去重分组键：归一化标题 + 归一化歌手。
    ///
    /// 归一化把「大小写、变音符号、全半角」折叠到同一形态（`folding`），再把连续空白压成一个空格
    /// 并去首尾空白。这样 "Kiseki" / "KISEKI" / "KISEKI " / "ＫＩＳＥＫＩ" 落进同一组，
    /// 而时长比较（见 `durationClusters`）负责排除同名不同曲。
    private static func dedupeKey(for record: TrackRecord) -> String {
        normalize(record.title) + "\u{1F}" + normalize(record.artist ?? "")
    }

    /// 文本归一化：折叠大小写/变音符/全半角，压缩空白。
    private static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        return folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 时长聚类：把同一分组键下的记录按「时长 ±3 秒」切成若干簇。
    ///
    /// 非 nil 的按时长升序贪心成簇，判据是「与簇内最小时长相差不超过 3 秒」；
    /// 选「与簇首（最小值）比较」而不是「与相邻元素比较」：前者保证同簇任意两条时长都在 3 秒内
    /// （相邻比较会让 [10,12,15] 链成一簇，两端差 5 秒却也算同组），语义更严也更可预期。
    ///
    /// 时长全为 nil 的记录并入同一簇：文本归一化后相同即视为重复，没有时长可作反证；
    /// 有 nil 与有值混在一起时不并簇（无法比较时保守放行，宁可留两条也不误删）。
    private static func durationClusters(_ records: [TrackRecord]) -> [[TrackRecord]] {
        let withDuration = records.filter { $0.durationSeconds != nil }
            .sorted { ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0) }
        let withoutDuration = records.filter { $0.durationSeconds == nil }

        var clusters: [[TrackRecord]] = []
        var current: [TrackRecord] = []
        var anchor: Double?
        for record in withDuration {
            guard let duration = record.durationSeconds else { continue }
            if let currentAnchor = anchor, duration - currentAnchor <= 3 {
                current.append(record)
            } else {
                if !current.isEmpty { clusters.append(current) }
                current = [record]
                anchor = duration
            }
        }
        if !current.isEmpty { clusters.append(current) }
        // 无时长的记录合成一簇：同键下多于一条才算重复组（单独一条不成组，由调用方按 count > 1 过滤）。
        if !withoutDuration.isEmpty { clusters.append(withoutDuration) }
        return clusters
    }

    /// 在一簇重复记录里挑出保留者。
    ///
    /// 并列时统一用 url 兜底，保证同一份数据两次去重得到同一结果（幂等，测试可断言）。
    private static func keeper(of cluster: [TrackRecord], strategy: LibraryDedupeStrategy) -> TrackRecord {
        switch strategy {
        case .newestCreated:
            return cluster.max { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                if lhs.fileSize != rhs.fileSize { return lhs.fileSize < rhs.fileSize }
                return lhs.url > rhs.url
            } ?? cluster[0]
        case .largestFile:
            return cluster.max { lhs, rhs in
                if lhs.fileSize != rhs.fileSize { return lhs.fileSize < rhs.fileSize }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.url > rhs.url
            } ?? cluster[0]
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

    /// 各歌单的曲目数（playlistId -> count）。
    ///
    /// 歌单列表页要显示「N 首」：逐行调 `entries` 会发起 N 次查询且把整张曲目表读出来；
    /// 这里一条 GROUP BY 拿到全部计数，列表渲染只消费一个字典。
    /// 没有条目的歌单不出现在结果里（调用方按 `?? 0` 读）。
    public func entryCounts() throws -> [UUID: Int] {
        try database.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT playlistId, COUNT(*) AS count FROM \(DatabaseSchema.playlistEntry)
                GROUP BY playlistId
                """)
            var counts: [UUID: Int] = [:]
            counts.reserveCapacity(rows.count)
            for row in rows { counts[row["playlistId"]] = row["count"] }
            return counts
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

    /// 歌单内容的「完整条目」版本：与 `entries` 同一条 JOIN 与排序，但返回 `LibraryTrack`，
    /// 带上专辑/体积/格式/封面 —— 歌单详情页（M2-T7）要显示封面与音质角标，只投影播放字段不够。
    /// 两者分工与 `LibraryRepository` 的 `allTracks` / `allTracksSorted` 一致。
    public func entriesDetailed(playlistId: UUID) throws -> [LibraryTrack] {
        try database.dbQueue.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT Track.* FROM Track
                JOIN PlaylistEntry ON PlaylistEntry.trackId = Track.id
                WHERE PlaylistEntry.playlistId = ?
                ORDER BY PlaylistEntry.position
                """, arguments: [playlistId]).map { $0.toLibraryTrack() }
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

// MARK: - 收藏

/// Favorite 表的读写。
///
/// 幂等取向（本任务明确要求「收藏/取消收藏/幂等」三点都可断言）：
///   - `favorite` 对已收藏的曲目**保持原 favoritedAt**，不因重复点击而把它顶到收藏列表最前
///     （「按收藏时间倒序」的列表因此只在首次收藏时改变顺序，重复操作无副作用）；
///   - `unfavorite` 对未收藏的曲目静默成功（删 0 行不是错误，UI 的开关式操作不需要先查存在性）。
///
/// 曲目不存在时 `favorite` 抛 `trackNotFound` 而不是让 SQLite 的外键约束报错：
/// 与 `PlaylistRepository.addTrack` 保持一致的可归因错误，调用方不必解析 GRDB 的 DatabaseError。
public struct FavoriteRepository: Sendable {

    private let database: DatabaseProvider

    public init(_ database: DatabaseProvider) {
        self.database = database
    }

    /// 收藏一首曲目。已收藏时为幂等空操作（保留原 favoritedAt）。
    /// - Returns: true 表示本次真的新增了收藏行；false 表示此前已收藏。
    @discardableResult
    public func favorite(trackId: UUID) throws -> Bool {
        try database.dbQueue.write { db in
            guard try TrackRecord.exists(db, key: trackId) else {
                throw RepositoryError.trackNotFound(trackId)
            }
            if try FavoriteRecord.fetchOne(db, key: trackId) != nil { return false }
            // 主键即 trackId：同一首歌最多一行，重复插入由 PK 约束挡住（这里已提前判过）。
            try FavoriteRecord(trackId: trackId).insert(db)
            return true
        }
    }

    /// 取消收藏。曲目未被收藏时静默成功（删 0 行不是错误）。
    public func unfavorite(trackId: UUID) throws {
        try database.dbQueue.write { db in
            _ = try FavoriteRecord.deleteOne(db, key: trackId)
        }
    }

    /// 是否已收藏。
    public func isFavorited(trackId: UUID) throws -> Bool {
        try database.dbQueue.read { db in
            try FavoriteRecord.exists(db, key: trackId)
        }
    }

    /// 切换收藏状态，返回切换后的状态（true = 已收藏）。
    /// UI 的星标按钮只调这一个方法，不必先读再写。
    @discardableResult
    public func toggle(trackId: UUID) throws -> Bool {
        if try isFavorited(trackId: trackId) {
            try unfavorite(trackId: trackId)
            return false
        }
        try favorite(trackId: trackId)
        return true
    }

    /// 全部收藏曲目，按收藏时间倒序（最近收藏在前）。
    ///
    /// 「只看收藏」列表与「收藏」子项都用它；返回 `LibraryTrack` 的理由与
    /// `PlaylistRepository.entriesDetailed` 相同：列表页要封面与音质角标。
    /// favoritedAt 相同时用 trackId 兜底，保证顺序跨查询稳定（测试可断言）。
    public func favorites() throws -> [LibraryTrack] {
        try database.dbQueue.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT Track.* FROM Track
                JOIN Favorite ON Favorite.trackId = Track.id
                ORDER BY Favorite.favoritedAt DESC, Track.id ASC
                """).map { $0.toLibraryTrack() }
        }
    }

    /// 已收藏曲目的 id 集合。列表行渲染星标时的批量查询入口（一次取全，避免逐行查库）。
    public func favoritedTrackIds() throws -> Set<UUID> {
        try database.dbQueue.read { db in
            Set(try FavoriteRecord.fetchAll(db).map(\.trackId))
        }
    }
}
