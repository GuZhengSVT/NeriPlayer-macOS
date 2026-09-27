// LibrarySyncService.swift
// NeriPlayer macOS —— 扫描结果落库（移植规划 M2-T4）。
//
// 职责：把 M2-T2 的 `LibraryScanner` 扫出来的目录清单，经 M2-T3 的 `LibraryRepository`
// 落进数据库。它是「扫描」与「存储」之间唯一的一层胶水：
//   - 扫描器只出内存数组，不认识 GRDB；
//   - 仓库只认 `LibraryTrack` / url，不认识目录；
//   - 本服务把后者的字段从扫描器缓存的 `AudioMetadata`（`Track` 的超集）补齐，
//     并把内嵌封面落成文件、路径写库。
//
// 为什么封面落文件而不是存 BLOB：封面是「一张图多个视图复用」的资源，写进文件系统后
// M2-T5 列表页可以直接交给 `NSImage(contentsOf:)`（有系统级缓存与降采样），而 BLOB 每次
// 展示都要过一次 SQLite 读取与内存拷贝；库文件也能保持小而易于备份。路径以曲目 id 命名，
// 与文件系统解耦：源文件改名/移动不影响封面寻址（url 是幂等键，id 才是主键）。
//
// 删除语义：扫描是按目录进行的，故删除范围**限定在本次扫描的根目录子树内**（仓库层的
// `mergeScanned(removingMissingUnder:)` 负责），不会因为扫了 A 目录而误删 B 目录的曲目。
// 被删曲目的封面文件随后一并清理。
//
// 线程模型：`sync` 是同步阻塞方法（与 scanner 一致），调用方（后续 M2-T5 UI）应放到后台执行。
// 本类型无内部可变状态，`Sendable`。

import Foundation

// MARK: - 同步结果

/// 一次「目录 -> 库」同步的统计结果。可直接用于 UI 的「本次导入 N 首」提示与日志。
public struct LibrarySyncResult: Equatable, Sendable {

    /// 被同步的根目录。
    public var directory: URL
    /// 本轮扫描发现的音频文件数（= 清单长度 + 读取失败数）。
    public var discovered: Int
    /// 新增入库（url 不在库中）。
    public var inserted: Int
    /// 更新（url 已在库中且内容有变化）。
    public var updated: Int
    /// 跳过（url 已在库中且内容一致）。
    public var skipped: Int
    /// 从库中移除（本轮清单里没有、且位于本次扫描目录子树内）。
    public var removed: Int
    /// 本轮写出封面文件的曲目数。
    public var coversWritten: Int
    /// 本轮随删除一并清理的封面文件数。
    public var coversRemoved: Int
    /// 同步完成后库中曲目总数。
    public var totalCount: Int

    public init(
        directory: URL,
        discovered: Int,
        inserted: Int,
        updated: Int,
        skipped: Int,
        removed: Int,
        coversWritten: Int,
        coversRemoved: Int,
        totalCount: Int
    ) {
        self.directory = directory
        self.discovered = discovered
        self.inserted = inserted
        self.updated = updated
        self.skipped = skipped
        self.removed = removed
        self.coversWritten = coversWritten
        self.coversRemoved = coversRemoved
        self.totalCount = totalCount
    }
}

// MARK: - 同步服务

/// 扫描 -> 落库。一个有状态的薄封装：持有 scanner（增量缓存跨轮保留）与仓库。
public struct LibrarySyncService: Sendable {

    private let repository: LibraryRepository
    private let scanner: LibraryScanner
    /// 封面落盘目录，默认与库文件同级的 `covers/`。
    public let coverDirectory: URL

    /// 用已有仓库与扫描器构造。
    ///
    /// - Parameters:
    ///   - repository: 落库入口。
    ///   - scanner: 扫描器。默认新建——但要保留跨轮增量缓存时应由调用方长期持有同一个实例
    ///     （缓存就在 scanner 里），生产路径建议用共享实例。
    ///   - coverDirectory: 封面目录；nil 时取 `covers/` 与库文件同级，
    ///     即生产环境的 `Application Support/NeriPlayer/covers`，测试则自动落在临时库目录旁。
    public init(
        repository: LibraryRepository,
        scanner: LibraryScanner = LibraryScanner(),
        coverDirectory: URL? = nil
    ) {
        self.repository = repository
        self.scanner = scanner
        self.coverDirectory = coverDirectory
            ?? Self.defaultCoverDirectory(for: repository)
    }

    /// 便捷构造：直接用 provider 建仓库。
    public init(
        database: DatabaseProvider,
        scanner: LibraryScanner = LibraryScanner(),
        coverDirectory: URL? = nil
    ) {
        self.init(
            repository: LibraryRepository(database),
            scanner: scanner,
            coverDirectory: coverDirectory
        )
    }

    /// 默认封面目录：与库文件同级。生产库在 `Application Support/NeriPlayer/library.sqlite`，
    /// 于是封面落在 `Application Support/NeriPlayer/covers/`（任务书指定路径）。
    /// 从 provider 反推而不是硬编码 Application Support：测试注入临时库时封面自然也在临时目录，
    /// 不会污染真实用户目录。
    private static func defaultCoverDirectory(for repository: LibraryRepository) -> URL {
        repository.databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("covers", isDirectory: true)
    }

    // MARK: 同步

    /// 扫描目录并把结果同步进库。
    ///
    /// 流程：
    ///   1. `scanner.scan` 出清单（含增量复用的 Track，id 稳定）；
    ///   2. 逐条从 scanner 缓存取 `AudioMetadata`，补 album/fileSize/format；
    ///   3. 有内嵌封面则写 `covers/<库 id>.png`，路径记进 coverPath（无新封面则沿用旧路径）；
    ///   4. `repository.mergeScanned` 按 url upsert 并移除子树内已消失的曲目；
    ///   5. 清理被移除曲目的封面文件。
    ///
    /// 封面用「库 id」命名而非扫描出来的 `Track.id`：内容变化时 scanner 会给同一文件新的 UUID，
    /// 而 `mergeScanned` 更新时保留原主键，用库 id 才能让封面路径跨轮稳定（不会每次都换个文件名）。
    /// - Returns: 新增/更新/跳过/移除等统计。
    @discardableResult
    public func sync(directory: URL) throws -> LibrarySyncResult {
        let scan = scanner.scan(directory: directory)
        let existingByURL = try repository.existingTracksByURL()

        var prepared: [LibraryTrack] = []
        prepared.reserveCapacity(scan.tracks.count)
        var coversWritten = 0

        for track in scan.tracks {
            let metadata = scanner.metadata(for: track.url)
            let urlKey = TrackRecord.urlString(for: track.url)
            // 库里已有同名 url 时以库 id 为准（主键稳定）；否则用扫描出的新 id。
            let existing = existingByURL[urlKey]
            let mtime = Self.mtime(of: track.url)

            var libraryTrack = LibraryTrack(
                id: existing?.id ?? track.id,
                url: track.url,
                title: track.title,
                artist: track.artist,
                album: metadata?.album,
                duration: track.duration,
                fileSize: metadata?.fileSize ?? 0,
                format: metadata?.format.identifier,
                coverPath: nil,
                fingerprintMtime: mtime
            )
            // 重写封面的判据：文件是新的，或内容指纹变了（换过封面），或封面文件被外部删掉了。
            let contentChanged = existing.map { $0.fingerprintMtime != mtime } ?? true
            let cover = try coverState(
                id: libraryTrack.id,
                cover: metadata?.coverImage,
                shouldRewrite: contentChanged
            )
            libraryTrack.coverPath = cover.path
            if cover.didWrite { coversWritten += 1 }
            prepared.append(libraryTrack)
        }

        let merge = try repository.mergeScanned(prepared, removingMissingUnder: scan.directory)
        let coversRemoved = removeCoverFiles(for: merge.removedTrackIds)
        let total = try repository.allTracks().count

        let result = LibrarySyncResult(
            directory: scan.directory,
            discovered: scan.discoveredCount,
            inserted: merge.inserted,
            updated: merge.updated,
            skipped: merge.skipped,
            removed: merge.removed,
            coversWritten: coversWritten,
            coversRemoved: coversRemoved,
            totalCount: total
        )
        let summary = "媒体库同步完成：\(result.directory.path) "
            + "新增 \(result.inserted)，更新 \(result.updated)，跳过 \(result.skipped)，"
            + "移除 \(result.removed)，封面写 \(result.coversWritten)，库共 \(result.totalCount) 首"
        Log.db.info("\(summary, privacy: .public)")
        return result
    }

    // MARK: 封面落盘

    /// 决定一条曲目的封面落盘状态。
    ///
    /// 写出（`didWrite = true`）只在「有新封面字节且需要落盘」时发生，需要落盘即
    /// `shouldRewrite`（文件内容是新的或指纹变了）或目标文件缺失。其余情况沿用既有路径，
    /// 既不重复写盘，也不会因为「扫描器本轮未重读文件」而把封面路径抹掉。
    /// 返回 nil 表示这条曲目确实没有封面。
    ///
    /// - Parameters:
    ///   - id: 曲目的库 id，决定文件名（跨轮稳定）。
    ///   - cover: 本轮读到的内嵌封面字节；nil 表示「本轮没读到封面」。
    ///   - shouldRewrite: 文件内容相对库中记录是否已变化。
    private func coverState(id: UUID, cover: Data?, shouldRewrite: Bool) throws -> (path: String?, didWrite: Bool) {
        let destination = coverDirectory.appendingPathComponent("\(id.uuidString).png", isDirectory: false)
        let fileExists = FileManager.default.fileExists(atPath: destination.path)

        if let cover, !cover.isEmpty, shouldRewrite || !fileExists {
            try FileManager.default.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
            // atomic 写：避免 UI 恰好在这一刻读到半张图。
            try cover.write(to: destination, options: .atomic)
            return (destination.path, true)
        }

        if fileExists {
            return (destination.path, false)
        }
        return (nil, false)
    }

    /// 删除被移除曲目的封面文件；返回实际删掉的文件数。
    /// 只动 `covers/<id>.png` 这一约定路径，绝不按目录通删，避免误伤用户文件。
    private func removeCoverFiles(for trackIds: [UUID]) -> Int {
        guard !trackIds.isEmpty else { return 0 }
        let fileManager = FileManager.default
        var removed = 0
        for id in trackIds {
            let path = coverDirectory.appendingPathComponent("\(id.uuidString).png", isDirectory: false).path
            if fileManager.fileExists(atPath: path) {
                try? fileManager.removeItem(atPath: path)
                removed += 1
            }
        }
        return removed
    }

    /// 文件修改时间（自 1970 的秒数）。取不到返回 nil——指纹的这一半允许缺失。
    private static func mtime(of url: URL) -> Double? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate?.timeIntervalSince1970
    }
}
