// AudioMetadataReader.swift
// NeriPlayer macOS —— 本地音频文件元数据读取（移植规划 M2-T1）。
//
// 职责：给定本地文件 URL，读出一个与 UI/DB 无关的元数据模型 AudioMetadata。
// 本任务只出模型，不落库（M2-T3 建表、M2-T4 写 Repository）。
//
// 行为对齐 Android 版 data/local/audioimport/LocalAudioImportManager*：
//   - 标签缺失时用文件名兜底：去扩展名，按 " - " 拆分尝试 artist - title
//     （parseFileNameMetadata / repairQuickIdentityFromFileName 语义的精简版：
//     本任务只处理「artist - title」这一最常见形态，不复制 Android 的
//     managed-download 多模板解析，那些属于下载命名规则，M6 再按需补）。
//
// 为什么读元数据不抛异常：扫描器（M2-T2）会对整目录批量调用，单个损坏文件
// 或未知容器不应中断整轮扫描。约定：
//   - 文件不存在 / 不是普通文件 → 返回 nil（调用方据此跳过）；
//   - 文件存在但标签读不出来 → 仍返回模型，title 走文件名兜底，
//     duration 可能为 nil，fileSize 总是尽力填充。
//
// 支持的容器（对齐 M2-T1 验收）：mp3 / flac / m4a / ogg / wav。
// 底层用 TagLibSwift（TagLib 2.3.1，MIT）——它只负责「解析容器与标签」，
// 上面这层负责 Android 语义的兜底与归一化。

import Foundation
import TagLibSwift

// MARK: - 格式标识

/// 音频容器格式标识。已知格式用具名 case，其余保留原始扩展名。
///
/// 用枚举而非裸 String 的理由：M2-T5 媒体库要给不同格式加角标、
/// M9 打包要按格式决定解码后端；具名 case 让这些判断在编译期可穷举，
/// 而不是散落一堆字符串比较。
public enum AudioFormat: Equatable, Sendable, CustomStringConvertible {

    case mp3
    case flac
    case m4a
    case ogg
    case wav
    /// 未识别的扩展名（小写、去点）。保留原值以便日志与后续扩展。
    case other(String)

    /// 由文件扩展名推断格式。大小写不敏感。
    ///
    /// 别名归并理由：m4a 容器在苹果生态里也常写作 mp4/aac/m4b，ogg 家族含
    /// ogv/oga/opus；把它们折叠到同一个 case，避免媒体库把它们当成不同格式。
    public init(fileExtension ext: String) {
        switch ext.lowercased() {
        case "mp3":
            self = .mp3
        case "flac":
            self = .flac
        case "m4a", "mp4", "aac", "m4b", "alac":
            self = .m4a
        case "ogg", "oga", "opus", "ogv":
            self = .ogg
        case "wav", "wave":
            self = .wav
        default:
            self = .other(ext.lowercased())
        }
    }

    /// 规范化的字符串标识（落库/日志用）。other 回退为原始扩展名。
    public var identifier: String {
        switch self {
        case .mp3: return "mp3"
        case .flac: return "flac"
        case .m4a: return "m4a"
        case .ogg: return "ogg"
        case .wav: return "wav"
        case .other(let ext): return ext
        }
    }

    public var description: String { identifier }
}

// MARK: - 元数据模型

/// 一次元数据读取的结果。纯值类型，可跨线程传递（Sendable）。
///
/// title 非可选：文件名兜底保证它总有值（至少是去扩展名的文件基名）。
/// artist/album 可选：文件名兜底只可能补出 artist，album 无来源时保持 nil。
/// duration 可选：容器未声明时长（少见）或标签解析失败时为 nil；
/// 此时 fileSize 至少反映真实体积，供上层决定是否还纳入库。
public struct AudioMetadata: Equatable, Sendable {

    /// 曲名。标签缺失时回落为文件名基名。
    public var title: String
    /// 歌手。标签与文件名都无信息时为 nil。
    public var artist: String?
    /// 专辑。当前无文件名兜底来源，标签缺失即 nil。
    public var album: String?
    /// 时长（秒）。容器未提供时为 nil。
    public var duration: TimeInterval?
    /// 内嵌封面原始字节（PNG/JPEG 等）。无封面时为 nil。
    public var coverImage: Data?
    /// 文件字节数。stat 失败时为 0。
    public var fileSize: Int64
    /// 容器格式标识。
    public var format: AudioFormat
    /// 来源文件 URL，便于下游（扫描器/播放器）回指，不必再去反查目录。
    public var url: URL

    public init(
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?,
        coverImage: Data?,
        fileSize: Int64,
        format: AudioFormat,
        url: URL
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.coverImage = coverImage
        self.fileSize = fileSize
        self.format = format
        self.url = url
    }
}

// MARK: - 文件名兜底解析

/// 从文件名推断 artist/title 的纯函数，独立出来便于单测直接覆盖边界。
enum FilenameMetadataParser {

    /// 解析结果。两个字段都可空：单段文件名只给 title。
    struct Parsed: Equatable {
        var title: String?
        var artist: String?
    }

    /// 去扩展名后按 " - " 拆分：artist - title；出现多段时首段当 artist、
    /// 其余用 " - " 重新拼回 title（标题里本身含连字符时不至于被截断）。
    ///
    /// 先拆分、再逐段 trim、再丢空段（而非先整体 trim 再拆）：这样
    /// " - Title" / "Artist - " 这类一侧为空的写法，空段被丢掉后仍能留下
    /// 有意义的一段，不会产出空字符串字段。
    static func parse(fileName: String) -> Parsed {
        let base = (fileName as NSString).deletingPathExtension
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Parsed(title: nil, artist: nil)
        }

        let fields = base
            .components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        switch fields.count {
        case 0:
            return Parsed(title: nil, artist: nil)
        case 1:
            return Parsed(title: fields[0], artist: nil)
        default:
            return Parsed(
                title: fields.dropFirst().joined(separator: " - "),
                artist: fields[0]
            )
        }
    }
}

// MARK: - 读取器

/// 本地音频元数据读取入口。
///
/// 无状态，故用 enum 作命名空间 + 静态方法，调用点写
/// AudioMetadataReader.readMetadata(at:)。
/// M2-T2 的扫描器会按文件批量调用本方法；大目录下单文件读取是纯 CPU/IO，
/// 线程安全（TagLib 每次调用自建并释放 FileRef，不共享状态）。
public enum AudioMetadataReader {

    /// 读取指定文件的元数据。
    ///
    /// - Parameter url: 本地文件 URL。
    /// - Returns: 元数据模型；仅当文件不存在或不是普通文件时返回 nil。
    ///            标签损坏、未知容器不抛异常，退化为「文件名兜底 + fileSize」。
    public static func readMetadata(at url: URL) -> AudioMetadata? {
        let fileManager = FileManager.default
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
              values.isRegularFile == true, values.isReadable == true,
              fileManager.isReadableFile(atPath: url.path) else {
            Log.db.debug("元数据读取跳过（不是可读的本地普通文件）：\(url.path, privacy: .public)")
            return nil
        }

        let fileSize = Self.fileSize(of: url, fileManager: fileManager)
        let format = AudioFormat(fileExtension: url.pathExtension)

        // TagLib 读取：任何失败都只是「没那么全」，不影响返回模型。
        var tagTitle: String?
        var tagArtist: String?
        var tagAlbum: String?
        var tagDuration: TimeInterval?
        var tagCover: Data?

        if let file = AudioFile(path: url.path), file.isValid {
            let tag = file.tag
            tagTitle = Self.normalized(tag.title)
            tagArtist = Self.normalized(tag.artist)
            tagAlbum = Self.normalized(tag.album)
            tagDuration = Self.duration(from: file.audioProperties)
            tagCover = file.pictures.first { !$0.data.isEmpty }?.data
        } else {
            Log.db.debug("TagLib 未能解析（退化为文件名兜底）：\(url.lastPathComponent, privacy: .public)")
        }

        // 文件名兜底：仅补标签缺的字段，不覆盖已读到的值。
        let fallback = FilenameMetadataParser.parse(fileName: url.lastPathComponent)
        let title = tagTitle ?? fallback.title ?? url.deletingPathExtension().lastPathComponent
        let artist = tagArtist ?? fallback.artist

        return AudioMetadata(
            title: title,
            artist: artist,
            album: tagAlbum,
            duration: tagDuration,
            coverImage: tagCover,
            fileSize: fileSize,
            format: format,
            url: url
        )
    }

    // MARK: 内部工具

    /// 文件字节数。取不到时返回 0（不影响模型可用性）。
    private static func fileSize(of url: URL, fileManager: FileManager) -> Int64 {
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber {
            return size.int64Value
        }
        return 0
    }

    /// 去掉首尾空白并把空串视作「无值」，与 Android 的
    /// normalizeQuickImportedMetadata（空白 → null）语义一致。
    private static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 从 TagLib 音频属性取时长（秒）。优先毫秒精度，其次整秒；
    /// 全为零（部分容器不写时长）时返回 nil，让上层用 fileSize 兜底。
    private static func duration(from properties: AudioProperties?) -> TimeInterval? {
        guard let properties else { return nil }
        if properties.lengthInMilliseconds > 0 {
            return TimeInterval(properties.lengthInMilliseconds) / 1000.0
        }
        if properties.lengthInSeconds > 0 {
            return TimeInterval(properties.lengthInSeconds)
        }
        return nil
    }
}
