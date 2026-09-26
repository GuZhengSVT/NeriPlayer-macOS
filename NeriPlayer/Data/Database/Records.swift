// Records.swift
// NeriPlayer macOS —— GRDB 记录类型与 Core 模型互转（移植规划 M2-T3）。
//
// 边界：Core 层（NeriPlayer/Core）不 import GRDB —— Track/QueueManager 是纯内存模型，
// 与存储解耦后才能在测试与将来的在线音源里不依赖数据库依赖。GRDB 的 Record 类型只活在
// 本文件（以及 Data/Database 下的仓库层），Core 模型经由这里的两个转换函数进出数据库。
//
// 为什么用 `Record` 子类而不是 `Codable` + FetchableRecord：M2-T3 任务书指定用 Record；
// 且 Record 自带 encode(to:) 的显式列映射，列名与 Swift 属性名解耦后不需要 CodingKeys 样板，
// 也避免 `Encodable` 默认实现把 Optional 的 nil 写成 NULL 之外的意外语义。
//
// UUID 编码：GRDB 的 UUID: DatabaseValueConvertible 默认把 UUID 写成 16 字节 BLOB，
// 读写都不经过字符串解析。表结构里列声明为 TEXT 只是给 sqlite3 CLI 看的语义标注，
// 实际存储仍是 BLOB —— SQLite 是动态类型，声明类型仅决定亲和性，BLOB 值可原样落进 TEXT 列。
// 同一规则适用于 trackId/playlistId 这些外键列。
//
// url 归一化：落库统一用 `URL.absoluteString`（见 urlString(for:)）。选它而不是
// `standardizedFileURL.path` 的理由：Track.url 的类型本身不限本地文件（M1 起就为在线音源
// 预留），absoluteString 对 file:// 与 http(s):// 都能原样表达；同一 URL 构造路径产出的
// 字符串稳定，因此 UNIQUE(url) 足以承担去重。
//
// 时间列：GRDB 的 Date 默认编码为 "YYYY-MM-DD HH:MM:SS.SSS" 字符串，
// 与时区无关地按 UTC 存取，跨进程重启后读回一致。

import Foundation
import GRDB

/// Track 表的 GRDB 记录。字段与 DatabaseProvider 里 v1 迁移建出的列一一对应。
///
/// 用 `final class` 的理由：`Record` 是 open class，子类化是 GRDB 为这类
/// 「一行一条记录」场景提供的既有路径；`final` 是为了不让这层再被继承出分支。
public final class TrackRecord: Record {

    /// 稳定标识，主键。与 Core `Track.id` 相同——跨扫描、跨启动都靠它关联。
    public var id: UUID
    /// 音源地址字符串，UNIQUE。由 `URL.absoluteString` 归一化得到。
    public var url: String
    /// 曲名。非空：Core 侧有文件名兜底，落库时必有值。
    public var title: String
    /// 歌手；未知为 nil。
    public var artist: String?
    /// 专辑；未知为 nil。
    public var album: String?
    /// 时长（秒）；未知为 nil。
    public var durationSeconds: Double?
    /// 文件字节数；未知为 0。
    public var fileSize: Double
    /// 容器格式标识（AudioFormat.identifier 的字符串形态）；未知为 nil。
    public var format: String?
    /// 文件修改时间（自 1970 的秒数），M2-T2 增量指纹的一半；文件系统不提供时为 nil。
    public var fingerprintMtime: Double?
    /// 封面文件落盘路径；无封面为 nil。
    public var coverPath: String?
    /// 首次入库时间。
    public var createdAt: Date

    /// 表名。集中取自 DatabaseSchema，避免字符串字面量散落。
    /// 子类是 final，故用 `override static`（Swift 允许用 static 覆盖 open class 属性）。
    public override static var databaseTableName: String { DatabaseSchema.track }

    /// 由 Core `Track` + 扫描器补充字段构造。
    ///
    /// Core `Track` 只有 id/url/title/artist/duration；album/fileSize/format/封面/指纹
    /// 来自 M2-T2 扫描器持有的 `AudioMetadata`（Track 的超集），M2-T4 会把这些一并传进来。
    /// 这里给出默认值，让「只有 Core Track」的调用方（例如播放入口顺手入库）也能直接用。
    public init(
        track: Track,
        album: String? = nil,
        fileSize: Double = 0,
        format: String? = nil,
        fingerprintMtime: Double? = nil,
        coverPath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = track.id
        self.url = TrackRecord.urlString(for: track.url)
        self.title = track.title
        self.artist = track.artist
        self.album = album
        self.durationSeconds = track.duration
        self.fileSize = fileSize
        self.format = format
        self.fingerprintMtime = fingerprintMtime
        self.coverPath = coverPath
        self.createdAt = createdAt
        super.init()
    }

    /// 由数据库行构造。GRDB 的 fetch 走这条路径。
    public required init(row: Row) throws {
        self.id = row["id"]
        self.url = row["url"]
        self.title = row["title"]
        self.artist = row["artist"]
        self.album = row["album"]
        self.durationSeconds = row["durationSeconds"]
        self.fileSize = row["fileSize"]
        self.format = row["format"]
        self.fingerprintMtime = row["fingerprintMtime"]
        self.coverPath = row["coverPath"]
        self.createdAt = row["createdAt"]
        try super.init(row: row)
    }

    /// 写库时的列映射。列名显式写出，与属性名保持同形，便于对照 v1 迁移。
    public override func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["url"] = url
        container["title"] = title
        container["artist"] = artist
        container["album"] = album
        container["durationSeconds"] = durationSeconds
        container["fileSize"] = fileSize
        container["format"] = format
        container["fingerprintMtime"] = fingerprintMtime
        container["coverPath"] = coverPath
        container["createdAt"] = createdAt
    }

    // MARK: - 与 Core 模型互转

    /// 转回 Core `Track`。album/fileSize/format/封面只活在库里，不进 Core 模型（M2-T5 直接查库）。
    public func toTrack() -> Track {
        Track(
            id: id,
            url: URL(string: url) ?? URL(fileURLWithPath: url),
            title: title,
            artist: artist,
            duration: durationSeconds
        )
    }

    /// URL 的落库归一化形式。UNIQUE(url) 去重、`trackByUrl` 查询都经这里，保证两侧一致。
    public static func urlString(for url: URL) -> String {
        url.absoluteString
    }
}

// MARK: - 歌单

/// Playlist 表的 GRDB 记录。
public final class PlaylistRecord: Record {

    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// 最后一次改名/增删曲目的时间。`addTrack`/`removeTrack`/`reorder` 都会推进它，
    /// 便于 M2-T5 的歌单列表按「最近改动」排序而不必每次去翻 entries。
    public var updatedAt: Date

    public override static var databaseTableName: String { DatabaseSchema.playlist }

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        super.init()
    }

    public required init(row: Row) throws {
        self.id = row["id"]
        self.name = row["name"]
        self.createdAt = row["createdAt"]
        self.updatedAt = row["updatedAt"]
        try super.init(row: row)
    }

    public override func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["name"] = name
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
    }

    /// 转成对外暴露的值类型。
    public var info: PlaylistInfo {
        PlaylistInfo(id: id, name: name, createdAt: createdAt, updatedAt: updatedAt)
    }
}

/// PlaylistEntry 表的 GRDB 记录：歌单内的一行「曲目位置」。
public final class PlaylistEntryRecord: Record {

    /// 行标识。用独立 UUID 而不是复合主键：GRDB 的 Record 增删改以单一主键最直接，
    /// 而 (playlistId, trackId) 的唯一性由表内 UNIQUE 约束另行保证。
    public var id: UUID
    public var playlistId: UUID
    public var trackId: UUID
    /// 列表序号，从 0 开始且在同一歌单内连续无空洞。
    public var position: Int
    public var addedAt: Date

    public override static var databaseTableName: String { DatabaseSchema.playlistEntry }

    public init(
        id: UUID = UUID(),
        playlistId: UUID,
        trackId: UUID,
        position: Int,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.playlistId = playlistId
        self.trackId = trackId
        self.position = position
        self.addedAt = addedAt
        super.init()
    }

    public required init(row: Row) throws {
        self.id = row["id"]
        self.playlistId = row["playlistId"]
        self.trackId = row["trackId"]
        self.position = row["position"]
        self.addedAt = row["addedAt"]
        try super.init(row: row)
    }

    public override func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["playlistId"] = playlistId
        container["trackId"] = trackId
        container["position"] = position
        container["addedAt"] = addedAt
    }
}

/// Favorite 表的 GRDB 记录。trackId 即主键，一首歌最多一行。
public final class FavoriteRecord: Record {

    public var trackId: UUID
    public var favoritedAt: Date

    public override static var databaseTableName: String { DatabaseSchema.favorite }

    public init(trackId: UUID, favoritedAt: Date = Date()) {
        self.trackId = trackId
        self.favoritedAt = favoritedAt
        super.init()
    }

    public required init(row: Row) throws {
        self.trackId = row["trackId"]
        self.favoritedAt = row["favoritedAt"]
        try super.init(row: row)
    }

    public override func encode(to container: inout PersistenceContainer) throws {
        container["trackId"] = trackId
        container["favoritedAt"] = favoritedAt
    }
}
