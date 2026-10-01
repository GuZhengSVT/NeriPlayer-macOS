// DatabaseProvider.swift
// NeriPlayer macOS —— 数据库连接与迁移（移植规划 M2-T3）。
//
// 职责：只做两件事 —— 1) 提供唯一的 GRDB 连接（DatabaseQueue）；2) 用 DatabaseMigrator
// 把 schema 推到最新版本。业务读写不在这里，见 Repositories.swift（M2-T4 会在此基础上扩展）。
//
// 为什么用 DatabaseQueue 而不是 DatabasePool：
//   - 本阶段只有一个进程、一个库文件、无长事务；Pool 的 WAL 快照并发收益在这里用不上；
//   - Queue 下所有读写都串行经过同一条连接，迁移与写入不存在交错，「迁移幂等」这类
//     验收点可以用最直白的方式证明；
//   - 后续 M3 若出现后台扫描 + UI 并发读的强需求，再换 Pool 只需改这一处构造，调用方不变。
//
// 外键：GRDB 的 Configuration.foreignKeysEnabled 默认为 true，这里再显式写一次 ——
// 级联删除（删 Track 连带删 Favorite/PlaylistEntry、删 Playlist 连带删 PlaylistEntry）
// 全部依赖它；显式声明可以把「默认值被人改掉」的风险挡在构造处，也让读代码的人不必
// 去 GRDB 源码里确认默认值。
//
// 迁移可重入：registerMigrations() 每次调用都从零重新登记（DatabaseMigrator 是值类型），
// 「登记」是纯内存操作，不碰库；真正落到磁盘的是 setupIfNeeded() 里的 migrate(dbQueue)。
// 迁移是否执行由 SQLite 里 grdb_migrations 表的已应用标识决定，所以：
//   - 同一实例重复 setupIfNeeded()：第二次无未应用项，直接返回；
//   - 新建一个指向同一文件的 provider 再 setupIfNeeded()：同样无未应用项。
// 两条路径都不做「重建表」动作，因此幂等。
//
// 线程模型：dbQueue 自身线程安全；migratorValue 的懒加载由 lock 串行化（迁移只跑一次）。

import Foundation
import GRDB

/// 数据库连接与迁移入口。一个库文件对应一个实例，实例内部持有唯一连接。
///
/// 典型用法：
/// ```swift
/// let database = try DatabaseProvider()          // 默认落到 Application Support
/// try database.setupIfNeeded()                   // 建连接后必须先迁移
/// let tracks = try LibraryRepository(database).allTracks()
/// ```
/// 测试/多库场景用 `init(path:)` 或 `init(url:)` 注入临时目录。
public final class DatabaseProvider: @unchecked Sendable {

    /// 本层可归因的错误。
    public enum DatabaseError: Error, LocalizedError, Equatable {
        /// 库目录无法创建（磁盘只读、权限不足、同名文件占位等）。
        case cannotCreateDirectory(URL)

        public var errorDescription: String? {
            switch self {
            case .cannotCreateDirectory(let url):
                return "无法创建数据库目录：\(url.path)"
            }
        }
    }

    /// 库文件名。放常量是为了让默认路径计算、文档、脚本引用同一处。
    public static let databaseFileName = "library.sqlite"

    /// 默认库目录：`~/Library/Application Support/NeriPlayer`。
    /// 用 Application Support 而不是 Documents 的理由：这是应用自管的索引数据，
    /// 不该出现在用户可见的文档目录里，也便于 M9 打包与卸载时整目录清理。
    public static var defaultDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("NeriPlayer", isDirectory: true)
    }

    /// 默认库文件路径（M2-T3 任务书指定的 `Application Support/NeriPlayer/library.sqlite`）。
    public static var defaultDatabaseURL: URL {
        defaultDirectoryURL.appendingPathComponent(databaseFileName, isDirectory: false)
    }

    /// 库文件路径。测试可据此断言「建在了临时目录」。
    public let databaseURL: URL

    /// 数据库连接。对上层公开：Repository 需要它，M3 的写入也需要复用它。
    public let dbQueue: DatabaseQueue

    /// 保护 migratorValue 的懒加载。
    private let lock = NSLock()
    private var migratorValue: DatabaseMigrator?

    /// 迁移器。懒加载的理由：DatabaseMigrator 是值类型，登记迁移不产生 IO，
    /// 放在首次访问时构造可以让「只想读一下库」的调用方完全不碰迁移代码路径。
    public var migrator: DatabaseMigrator {
        lock.lock()
        defer { lock.unlock() }
        if let existing = migratorValue { return existing }
        let created = DatabaseProvider.makeMigrator()
        migratorValue = created
        return created
    }

    // MARK: - 构造

    /// 指定库文件 URL 构造（测试与多库场景）。
    ///
    /// 不自动迁移：调用方需要显式 `setupIfNeeded()`。让「建连接」和「改 schema」两件事
    /// 在调用点可区分 —— 测试第二个 provider 时要能观察到「迁移不再执行」这一步。
    public init(url: URL) throws {
        let standardized = url.standardizedFileURL
        let directory = standardized.deletingLastPathComponent()
        try DatabaseProvider.ensureDirectory(directory)

        var configuration = Configuration()
        // 外键开关：级联删除的前提。GRDB 默认已是 true，显式写明避免依赖隐式默认值。
        configuration.foreignKeysEnabled = true

        self.databaseURL = standardized
        self.dbQueue = try DatabaseQueue(path: standardized.path, configuration: configuration)
    }

    /// 指定库文件路径构造。
    public convenience init(path: String) throws {
        try self.init(url: URL(fileURLWithPath: path))
    }

    /// 默认路径构造：`Application Support/NeriPlayer/library.sqlite`。
    public convenience init() throws {
        try self.init(url: DatabaseProvider.defaultDatabaseURL)
    }

    // MARK: - 迁移

    /// 跑完所有未应用的迁移（首次调用建表，重复调用空转）。
    ///
    /// 为什么不让 init 自动调用：迁移失败时调用方需要拿到错误并决定降级策略
    /// （M0-T4 的安全模式依赖这种可观测性）；把迁移钉在显式调用点上，测试也能
    /// 精确控制「第一次 setup」与「第二次 setup」的时机。
    public func setupIfNeeded() throws {
        try migrator.migrate(dbQueue)
        Log.db.info("数据库迁移完成：\(self.databaseURL.path, privacy: .public)")
    }

    // MARK: - 迁移定义

    /// 登记全部迁移。当前有 v1（M2-T3 的四张核心表 + 索引）、v2（M3-T1 的三张持久化表 + 索引）
    /// 与 v3（M3-T3 给 PlayerState 补「退出时是否在播」一列）。
    ///
    /// 迁移标识用「v1」而非时间戳：这是从零开始的新库（无历史迁移需要区分先后），
    /// 递增版本号更好读也更好在测试里断言。后续 M3+ 依次追加「v4」…
    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: migrateV1)
        migrator.registerMigration("v2", migrate: migrateV2)
        migrator.registerMigration("v3", migrate: migrateV3)
        migrator.registerMigration("v4", migrate: migrateV4)
        migrator.registerMigration("v5", migrate: SyncDatabaseSchema.migrate)
        migrator.registerMigration("v6", migrate: OnlineContentCache.migrate)
        return migrator
    }

    /// v1：建 Track / Playlist / PlaylistEntry / Favorite 四张表与索引。
    ///
    /// 声明成 `@Sendable` 闭包而不是普通 static func：`registerMigration` 的参数类型是
    /// `@Sendable (Database) throws -> Void`，直接把函数引用传过去会触发
    /// 「converting non-Sendable function value」警告。存成 Sendable 闭包即消除该转换。
    private static let migrateV1: @Sendable (Database) throws -> Void = { db in
        try db.create(table: DatabaseSchema.track) { table in
            // UUID 以 BLOB(16) 存储：GRDB 的 UUID 编码默认走 blob，读写都不需要字符串解析。
            // 声明类型写 .text 是为了让 sqlite3 CLI / 其他工具看到的 schema 语义更直观
            // （SQLite 是动态类型，声明类型只影响亲和性，BLOB 值可原样落到 TEXT 列）。
            table.primaryKey("id", .text)
            table.column("url", .text).notNull().unique()
            table.column("title", .text)
            table.column("artist", .text)
            table.column("album", .text)
            table.column("durationSeconds", .double)
            table.column("fileSize", .double)
            table.column("format", .text)
            // 文件修改时间（自 1970 的秒数）。M2-T2 扫描器用「体积 + 修改时间」做增量指纹，
            // 落库后下次启动可以不改盘判断某文件是否变化。可空：某些文件系统不提供 mtime。
            table.column("fingerprintMtime", .double)
            table.column("coverPath", .text)
            table.column("createdAt", .datetime).notNull()
        }

        try db.create(table: DatabaseSchema.playlist) { table in
            table.primaryKey("id", .text)
            table.column("name", .text).notNull()
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull()
        }

        try db.create(table: DatabaseSchema.playlistEntry) { table in
            table.primaryKey("id", .text)
            table.column("playlistId", .text).notNull()
                .references(DatabaseSchema.playlist, onDelete: .cascade)
            table.column("trackId", .text).notNull()
                .references(DatabaseSchema.track, onDelete: .cascade)
            // 列表序号，从 0 开始。reorder 后必须保持 0..n-1 连续（见 PlaylistRepository.reorder）。
            table.column("position", .integer).notNull()
            table.column("addedAt", .datetime).notNull()
            // 同一歌单里同一首歌只能出现一次；跨歌单互不影响。
            table.uniqueKey(["playlistId", "trackId"])
        }

        try db.create(table: DatabaseSchema.favorite) { table in
            // trackId 直接做 PK：一首歌要么被收藏要么没有，不存在多条记录。
            table.primaryKey("trackId", .text)
                .references(DatabaseSchema.track, onDelete: .cascade)
            table.column("favoritedAt", .datetime).notNull()
        }

        // 索引：覆盖本阶段 Repository 的全部查询路径。
        // url 的唯一性由表内 UNIQUE 约束提供（SQLite 会自建唯一索引），不重复声明。
        try db.create(index: "index_Track_artist", on: DatabaseSchema.track, columns: ["artist"])
        try db.create(index: "index_Track_album", on: DatabaseSchema.track, columns: ["album"])
        // 歌单列表按 position 升序取，歌单内查询走 (playlistId, position)。
        try db.create(
            index: "index_PlaylistEntry_playlistId_position",
            on: DatabaseSchema.playlistEntry,
            columns: ["playlistId", "position"]
        )
        // 删 Track 的级联要从 trackId 反查 entries；(playlistId, trackId) 复合唯一约束
        // 的前缀是 playlistId，帮不上这个查询，需要单独一条 trackId 索引。
        try db.create(
            index: "index_PlaylistEntry_trackId",
            on: DatabaseSchema.playlistEntry,
            columns: ["trackId"]
        )
    }

    /// v2：建播放历史 / 播放统计 / 播放器现场三张表与索引（移植规划 M3-T1）。
    ///
    /// 与 v1 的关系：v1 的 Track/Playlist/PlaylistEntry/Favorite 一张不动，本迁移只做 CREATE，
    /// 因此 v1 → v2 升级是纯增量，既有数据不会被重建或改写（单测 testV1ToV2MigrationPreservesV1Data 断言）。
    ///
    /// 语义参考 Android 原库 data/stats 与 schemas/18.json，但按 macOS 侧的数据模型重做：
    ///   - PlayHistory：一首歌一行（trackId 主键），外键级联到 Track —— 曲目被删则历史随之消失，
    ///     不留指向不存在文件的孤儿行；按 playedAt 倒序查询即「最近播放」；
    ///   - PlaybackStats：一首歌一行累计值（次数/时长/首次与最近播放时间）；
    ///   - PlaybackStatsDailyBucket：按自然日的桶，(dayStart, trackId) 复合主键保证「同一天同一首一行」；
    ///   - PlayerState：单行现场表（id 恒为 1），队列以 JSON 列整体存取。
    ///
    /// 统计相关表为什么不去存标题/歌手/专辑快照：macOS 侧 Track 表就是权威元数据，且有外键级联
    /// 保证一致性；查询时 JOIN Track 取展示字段，避免元数据在两张表里各存一份后可能不一致。
    private static let migrateV2: @Sendable (Database) throws -> Void = { db in
        try db.create(table: DatabaseSchema.playHistory) { table in
            // trackId 直接做主键：一首歌最多一行历史（重复播放只刷新时间与记忆位置）。
            table.primaryKey("trackId", .text)
                .references(DatabaseSchema.track, onDelete: .cascade)
            table.column("playedAt", .datetime).notNull()
            // 记忆播放位置（秒）。0 表示未记录或从头播。
            table.column("resumePositionSeconds", .double).notNull().defaults(to: 0)
        }

        try db.create(table: DatabaseSchema.playbackStats) { table in
            table.primaryKey("trackId", .text)
                .references(DatabaseSchema.track, onDelete: .cascade)
            table.column("totalListenSeconds", .double).notNull().defaults(to: 0)
            table.column("playCount", .integer).notNull().defaults(to: 0)
            // 首次/最近播放时间可为 NULL：统计行可能先建立（例如刚播放尚未达到计数阈值）。
            table.column("firstPlayedAt", .datetime)
            table.column("lastPlayedAt", .datetime)
        }

        try db.create(table: DatabaseSchema.playbackStatsDailyBucket) { table in
            // 复合主键 (dayStart, trackId)：桶键 + 曲目唯一确定一行。
            table.primaryKey(["dayStart", "trackId"])
            table.column("dayStart", .datetime).notNull()
            table.column("trackId", .text).notNull()
                .references(DatabaseSchema.track, onDelete: .cascade)
            table.column("totalListenSeconds", .double).notNull().defaults(to: 0)
            table.column("playCount", .integer).notNull().defaults(to: 0)
            table.column("firstPlayedAt", .datetime)
            table.column("lastPlayedAt", .datetime)
        }

        // 单行现场表：id 恒为 1（Repository 只用这一行），删除重建时也只会有一行。
        try db.create(table: DatabaseSchema.playerState) { table in
            table.primaryKey("id", .integer)
            // 当前索引；空队列为 NULL（与 QueueState 的不变式一致）。
            table.column("currentIndex", .integer)
            table.column("position", .double).notNull().defaults(to: 0)
            table.column("mode", .text).notNull()
            // 队列与随机序列各存一列 JSON：整体读写、行级原子，不会出现写了一半的队列。
            table.column("queue", .text).notNull()
            table.column("shuffleOrder", .text).notNull().defaults(to: "[]")
            table.column("updatedAt", .datetime).notNull()
        }

        // 索引：覆盖本阶段已明确的查询路径。
        // 历史按时间倒序取整表（最近播放列表），单列索引即可让 ORDER BY 走索引扫描。
        try db.create(
            index: "index_PlayHistory_playedAt",
            on: DatabaseSchema.playHistory,
            columns: ["playedAt"]
        )
        // 统计按「最近播放」倒序取；主键 trackId 已覆盖按曲目点查。
        try db.create(
            index: "index_PlaybackStats_lastPlayedAt",
            on: DatabaseSchema.playbackStats,
            columns: ["lastPlayedAt"]
        )
        // 每日桶按曲目横跨多天查询（(dayStart, trackId) 主键前缀只有 dayStart，帮不上 trackId 反查）；
        // 复合索引把「某首歌的时间序列」变成连续区间扫描。
        try db.create(
            index: "index_PlaybackStatsDailyBucket_trackId_dayStart",
            on: DatabaseSchema.playbackStatsDailyBucket,
            columns: ["trackId", "dayStart"]
        )
    }

    /// v3：给 PlayerState 补一列 shouldResumePlayback（移植规划 M3-T3）。
    ///
    /// 为什么必须单独存一列，而不是从进度或队列推断：这是「用户退出那一刻的播放意图」。
    /// 暂停在第 90 秒退出，与播放到第 90 秒被系统杀掉，队列、索引、进度三者完全相同，
    /// 只有这一列能区分「启动后该不该自己响」。把它推断出来（例如「进度 > 0 就是在播」）
    /// 会在用户暂停后退出时错误地自动续播。
    ///
    /// 默认 false —— v2 老库升级上来的现场没有这个信息，按最保守的语义处理：恢复到暂停态。
    /// 本迁移只做 ALTER TABLE ADD COLUMN（带非空默认值），是纯增量：既有行的队列与进度原样保留。
    private static let migrateV3: @Sendable (Database) throws -> Void = { db in
        try db.alter(table: DatabaseSchema.playerState) { table in
            table.add(column: "shouldResumePlayback", .boolean).notNull().defaults(to: false)
        }
    }

    /// v4：建流量统计表（移植规划 M3-T4）。
    ///
    /// 一天一行（dayStart 主键），列分两类：按接入方式（Wi-Fi / 有线 / 蜂窝 / 其他）与
    /// 按用途（播放 / 下载），外加缓存命中两列。为什么不拆成多张表：这些维度天然正交，
    /// 且查询形态固定是「取某天/某区间的那一行」，拆表只会让每次写入变成多表事务，
    /// 在读多写少、每天最多一行的规模下没有收益。
    ///
    /// 每列都是「增量累加」语义（见 TrafficStatsRepository 的 upsert），因此全部非空且默认 0 ——
    /// 免去在 SQL 里处理 NULL 参与加法的问题。
    ///
    /// 本迁移只做 CREATE TABLE，不动既有表，v1→v4 升级是纯增量。
    private static let migrateV4: @Sendable (Database) throws -> Void = { db in
        try db.create(table: DatabaseSchema.trafficStats) { table in
            // 本地零点做主键：一天最多一行，重复写入走 ON CONFLICT 累加。
            table.primaryKey("dayStart", .datetime)
            table.column("wifiBytes", .integer).notNull().defaults(to: 0)
            table.column("wiredBytes", .integer).notNull().defaults(to: 0)
            table.column("cellularBytes", .integer).notNull().defaults(to: 0)
            table.column("otherBytes", .integer).notNull().defaults(to: 0)
            table.column("playbackNetworkBytes", .integer).notNull().defaults(to: 0)
            table.column("downloadNetworkBytes", .integer).notNull().defaults(to: 0)
            table.column("cacheHitBytes", .integer).notNull().defaults(to: 0)
            table.column("requestCount", .integer).notNull().defaults(to: 0)
            table.column("cacheHitCount", .integer).notNull().defaults(to: 0)
        }
        // 不额外建索引：本表唯一的查询形态是「按 dayStart 取一行或一个区间」，
        // 主键本身就是 dayStart 的索引，再建一条是重复。
    }

    // MARK: - 目录

    /// 确保库目录存在。
    private static func ensureDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            // 路径存在但不是目录：无法继续，交给调用方处理。
            throw DatabaseError.cannotCreateDirectory(directory)
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.db.error("创建数据库目录失败：\(directory.path, privacy: .public) \(error)")
            throw DatabaseError.cannotCreateDirectory(directory)
        }
    }
}

// MARK: - Schema 常量

/// 表名集中定义。仓库层与测试引用这里，避免表名字符串在多个文件里各写一遍。
public enum DatabaseSchema {
    public static let track = "Track"
    public static let playlist = "Playlist"
    public static let playlistEntry = "PlaylistEntry"
    public static let favorite = "Favorite"
    /// M3-T1：播放历史（一首歌一行）。
    public static let playHistory = "PlayHistory"
    /// M3-T1：播放统计累计值（一首歌一行）。
    public static let playbackStats = "PlaybackStats"
    /// M3-T1：播放统计每日桶（(dayStart, trackId) 复合主键）。
    public static let playbackStatsDailyBucket = "PlaybackStatsDailyBucket"
    /// M3-T1：播放器现场单行表（id 恒为 1）。
    public static let playerState = "PlayerState"
    /// M3-T4：流量统计每日桶（dayStart 主键）。
    public static let trafficStats = "TrafficStats"
}
