// LibraryTrack.swift
// NeriPlayer macOS —— 媒体库条目的完整值类型（移植规划 M2-T4）。
//
// 为什么需要它：Core 的 `Track`（M1-T4）只有播放链路要的五个字段（id/url/title/artist/duration），
// 媒体库列表还要专辑、体积、容器格式、封面路径与扫描指纹。把这些字段直接塞进 `Track` 会污染
// 播放链路（队列、引擎、Now Playing 都不需要专辑/封面），因此在库这一侧另立一个更宽的模型。
//
// 分层：本类型是纯值类型，不 import GRDB —— 与 `Track` 一样属于 Core 词汇。GRDB 的
// `TrackRecord`（Data 层）负责把它映射到列；Core 的扫描/同步逻辑与测试只面对本类型。
//
// `track` 计算属性把共享字段投影回 `Track`：队列/播放入口需要的就是这个子集，
// 调用方不必手工拼装，也保证了「库里那一行」与「队列里那一首」用同一个 id。

import Foundation

/// 媒体库中的一条曲目：`Track` 的播放字段 + 专辑/体积/格式/封面/指纹。
public struct LibraryTrack: Identifiable, Equatable, Hashable, Sendable {

    /// 稳定标识，主键。与 `Track.id` 同源——跨扫描、跨启动、跨队列都靠它关联。
    public var id: UUID
    /// 音源地址。M2 只放本地文件，但类型本身不限本地（与 `Track.url` 同规则）。
    public var url: URL
    /// 显示标题。
    public var title: String
    /// 歌手；未知为 nil。
    public var artist: String?
    /// 专辑；未知为 nil。
    public var album: String?
    /// 时长（秒）；未知为 nil。
    public var duration: Double?
    /// 文件字节数；未知为 0。
    public var fileSize: Int64
    /// 容器格式标识（`AudioFormat.identifier`）；未知为 nil。
    public var format: String?
    /// 封面文件落盘路径；无封面为 nil。由同步服务写入后填回。
    public var coverPath: String?
    /// 文件修改时间（自 1970 的秒数），M2-T2 增量指纹的一半；文件系统不提供时为 nil。
    public var fingerprintMtime: Double?

    public init(
        id: UUID,
        url: URL,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: Double? = nil,
        fileSize: Int64 = 0,
        format: String? = nil,
        coverPath: String? = nil,
        fingerprintMtime: Double? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.fileSize = fileSize
        self.format = format
        self.coverPath = coverPath
        self.fingerprintMtime = fingerprintMtime
    }

    /// 共享字段投影回播放链路的 `Track`。id/url/title/artist/duration 一一对应。
    public var track: Track {
        Track(id: id, url: url, title: title, artist: artist, duration: duration)
    }
}
