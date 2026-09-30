// LibraryScanner.swift
// NeriPlayer macOS —— 本地媒体库目录扫描（移植规划 M2-T2）。
//
// 职责：给定一个用户指定的目录，递归找出其中的音频文件，逐个用 M2-T1 的
// AudioMetadataReader 读元数据，产出 M1-T4 的 Track 模型数组（URL/title/artist/duration）。
// 本任务只出内存数组：不写数据库（M2-T3 建表 + M2-T4 写 Repository）、不做文件监听
// （规划明确后续任务）、不做 UI。
//
// 增量语义（对齐 Android 版 data/local/audioimport/LocalAudioImportManagerScan）：
//   - 每个音频文件记录指纹 (path, fileSize, modificationDate)；
//   - 再次扫描时指纹未变的文件直接复用上次产出的 Track，跳过元数据重读（skip）；
//     指纹变化的文件才重新调 AudioMetadataReader（read）；
//   - 指纹以绝对路径（standardizedFileURL.path）为键，因此同一目录重复扫描、
//     多目录共用同一个 scanner 实例都能各自命中；
//   - 本轮未再出现的文件（删除/改名）从缓存中剔除，只在被扫描目录子树内剪枝，
//     不会误删其他已扫描目录的缓存。
//
// 为什么缓存 Track 而不是每轮重新构造：Track.id 是 UUID，重新构造会导致同一文件
// 跨扫描拿到不同 id，而队列（M1-T4）与后续落库（M2-T3）都依赖稳定标识。缓存里同时
// 保留 AudioMetadata（Track 的超集：含 album/封面/格式），使 M2-T3 落库时无需二次读盘。
//
// 目录遍历决策：
//   - 扩展名白名单（大小写不敏感）：mp3/flac/m4a/aac/ogg/opus/wav/aiff/aif/wma/ape；
//   - 符号链接一律不跟随（文件与目录都跳过），从根上避免「链接指向上级」造成的环；
//   - 用显式栈做深度优先遍历而非递归，目录深度不受调用栈限制；
//   - 每层目录项按路径排序，保证同一目录树两次扫描的产出顺序稳定（便于后续 diff 与测试）；
//   - 普通文件系统权限直读路径，不涉及 sandbox 安全作用域书签（规划 M2-T2 原文提到书签，
//     但本任务边界要求走普通权限；书签属于后续打包/授权任务）。
//
// 线程模型（沿用本层做法）：内部缓存与订阅者表由 NSLock 串行化，yield 一律在锁外。
// scan(directory:) 是同步阻塞方法，调用方（后续 M2-T5 UI）应放到后台执行；
// 进度通过 observeProgress() 的 AsyncStream 旁路发布，不阻塞扫描本身。

import Foundation

// MARK: - 文件指纹

/// 单个音频文件的增量指纹：路径 + 体积 + 修改时间，三者全同即视为「未变化」。
///
/// 用「体积 + 修改时间」而非内容哈希：与 Android 版按 lastModified 判定的语义一致，
/// 大目录下无需把每个文件读一遍就能判定是否需要重读元数据；体积是廉价的二次校验，
/// 能挡住「替换成同名同大小但内容不同」之外的绝大多数改动。
public struct AudioFileFingerprint: Equatable, Hashable, Sendable {

    /// 绝对路径（standardizedFileURL.path），作为缓存键与外层 diff 依据。
    public var path: String
    /// 文件字节数；取不到时为 0。
    public var fileSize: Int64
    /// 内容修改时间；取不到时为 nil。
    public var modificationDate: Date?

    public init(path: String, fileSize: Int64, modificationDate: Date?) {
        self.path = path
        self.fileSize = fileSize
        self.modificationDate = modificationDate
    }

    /// 由 URL 构造，path 取标准化绝对路径。
    public init(url: URL, fileSize: Int64, modificationDate: Date?) {
        self.init(
            path: url.standardizedFileURL.path,
            fileSize: fileSize,
            modificationDate: modificationDate
        )
    }
}

// MARK: - 进度

/// 一次扫描的进度事件。
///
/// 阶段划分对齐 Android 版的「先枚举、再逐个处理」两段式：
///   - discovering：正在枚举目录树（total 尚未确定，为 0）；
///   - reading：枚举完成，按发现的音频文件逐个处理（读取或复用），total 固定；
///   - finished：本轮结束（processed == total）。
/// discovered 为已发现的音频文件数，processed 为已处理数（含复用与读取）。
public struct LibraryScanProgress: Equatable, Sendable {

    public enum Phase: String, Equatable, Sendable {
        /// 目录枚举阶段。
        case discovering
        /// 元数据读取/复用阶段。
        case reading
        /// 本轮扫描结束。
        case finished
    }

    /// 当前阶段。
    public var phase: Phase
    /// 已发现的音频文件数。
    public var discovered: Int
    /// 已处理（读取或跳过）的音频文件数。
    public var processed: Int
    /// 本轮需要处理的音频文件总数；discovering 阶段为 0（尚未统计完）。
    public var total: Int

    public init(phase: Phase, discovered: Int, processed: Int, total: Int) {
        self.phase = phase
        self.discovered = discovered
        self.processed = processed
        self.total = total
    }
}

// MARK: - 扫描结果

/// 一次扫描的产物。
///
/// scannedCount / skippedCount 是增量语义的可观测出口（也是测试用来验证
/// 「第二次扫描未重读」的依据）：skippedCount 直接对应「指纹未变、复用上次结果」的文件数。
public struct LibraryScanResult: Equatable, Sendable {

    /// 被扫描的根目录（标准化后的绝对 URL）。
    public var directory: URL
    /// 本轮库内容，顺序稳定（每层按路径排序的深度优先）。
    public var tracks: [Track]
    /// 发现的音频文件总数（= 正常情况下的 tracks.count + 读取失败数）。
    public var discoveredCount: Int
    /// 被扩展名白名单挡掉的普通文件数（不含目录与符号链接）。
    public var ignoredFileCount: Int
    /// 本轮真正调用 AudioMetadataReader 的文件数。
    public var scannedCount: Int
    /// 本轮复用缓存、未重读元数据的文件数。
    public var skippedCount: Int
    /// 从缓存中剔除的「本轮已不存在」文件数。
    public var removedCount: Int
    /// Only complete scans are authoritative for deleting missing library entries.
    /// An unavailable root, enumeration failure, or unreadable audio file makes this false.
    public var isComplete: Bool

    public init(
        directory: URL,
        tracks: [Track],
        discoveredCount: Int,
        ignoredFileCount: Int,
        scannedCount: Int,
        skippedCount: Int,
        removedCount: Int,
        isComplete: Bool = true
    ) {
        self.directory = directory
        self.tracks = tracks
        self.discoveredCount = discoveredCount
        self.ignoredFileCount = ignoredFileCount
        self.scannedCount = scannedCount
        self.skippedCount = skippedCount
        self.removedCount = removedCount
        self.isComplete = isComplete
    }
}

// MARK: - 扫描器

/// 媒体库目录扫描器。持有增量缓存，可对同一实例重复调用 scan(directory:) 做增量扫描。
///
/// 采用 @unchecked Sendable：内部可变状态（缓存、订阅者表）全部由 lock 串行化。
/// 允许「先扫描 A 目录、再扫描 B 目录」共用缓存；同一实例并发扫描不做保证（调用方串行化），
/// 但即便误并发也不会数据竞争（缓存读写都在锁内）。
public final class LibraryScanner: @unchecked Sendable {

    /// 音频扩展名白名单。小写存储，比对时对文件扩展名做 lowercased()。
    /// 列表对齐 M2-T2 任务书，比 AudioFormat 的具名 case 更宽（aac/opus/aiff/aif/wma/ape
    /// 在 reader 侧会归并到最接近的容器或落到 .other）。
    public static let supportedExtensions: Set<String> = [
        "mp3", "flac", "m4a", "aac", "ogg", "opus",
        "wav", "aiff", "aif", "wma", "ape"
    ]

    /// 缓存条目：指纹 + 上次读出的元数据 + 上次产出的 Track。
    /// track 一并缓存是为了保持 Track.id 跨扫描稳定（见文件头说明）。
    private struct CacheEntry {
        var fingerprint: AudioFileFingerprint
        var metadata: AudioMetadata
        var track: Track
    }

    /// 枚举阶段的中间产物。
    private struct DiscoveredFile {
        var url: URL
        var fingerprint: AudioFileFingerprint
    }

    /// 保护 cache 与 continuations。
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var continuations: [UUID: AsyncStream<LibraryScanProgress>.Continuation] = [:]

    public init() {}

    // MARK: 进度订阅

    /// 订阅扫描进度。每次订阅返回独立新流，可多次订阅。
    ///
    /// 缓冲策略用 unbounded 而非项目其他状态流的 bufferingNewest(1)：进度是
    /// 「序列」而非「快照」，订阅者（尤其是测试与日志）需要看到 discovering→reading→finished
    /// 的完整阶段迁移；单次扫描的事件数与文件数同阶，内存可控。
    ///
    /// 用 AsyncStream.makeStream 而非 AsyncStream(bufferingPolicy:) 构造：前者在调用本方法时
    /// 就创建好 continuation，订阅即登记；后者要等订阅者开始迭代才执行 build 闭包。
    /// scan(directory:) 是同步方法，若用后者，调用方「先订阅、再同步扫描」会丢掉整轮事件。
    /// 登记即生效后，未及消费的事件也留在流缓冲里，行为对调用方是可预期的。
    /// 流本身不 finish（便于一次订阅跨多轮扫描），订阅者以 phase == .finished 作为一轮的结束。
    public func observeProgress() -> AsyncStream<LibraryScanProgress> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: LibraryScanProgress.self,
            bufferingPolicy: .unbounded
        )
        let id = UUID()
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            self?.removeContinuation(id)
        }
        return stream
    }

    // MARK: 扫描

    /// 递归扫描目录，返回音频文件对应的 Track 列表与增量统计。
    ///
    /// - Parameter directory: 用户指定的库根目录。
    /// - Returns: 本轮结果；目录不存在或不是目录时返回空结果（不抛异常）。
    public func scan(directory: URL) -> LibraryScanResult {
        let root = directory.standardizedFileURL
        let fileManager = FileManager.default

        publish(LibraryScanProgress(phase: .discovering, discovered: 0, processed: 0, total: 0))

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            Log.db.error("媒体库扫描失败（目录不存在或不是目录）：\(root.path, privacy: .public)")
            publish(LibraryScanProgress(phase: .finished, discovered: 0, processed: 0, total: 0))
            return LibraryScanResult(
                directory: root, tracks: [], discoveredCount: 0, ignoredFileCount: 0,
                scannedCount: 0, skippedCount: 0, removedCount: 0, isComplete: false
            )
        }

        // 第一遍：枚举目录树，只做路径与指纹，不读元数据（IO 快，进度粒度粗）。
        let discovery = discoverAudioFiles(in: root, fileManager: fileManager)
        let discoveredFiles = discovery.files
        let total = discoveredFiles.count
        publish(LibraryScanProgress(phase: .reading, discovered: total, processed: 0, total: total))
        Log.db.info(
            "媒体库扫描开始：\(root.path, privacy: .public) 音频 \(total) 个，忽略其他文件 \(discovery.ignoredCount) 个"
        )

        // 第二遍：逐个文件比对指纹，未变复用、变化重读。
        var tracks: [Track] = []
        tracks.reserveCapacity(total)
        var isComplete = discovery.isComplete
        var scannedCount = 0
        var skippedCount = 0
        var seenPaths: Set<String> = []
        seenPaths.reserveCapacity(total)

        for (index, file) in discoveredFiles.enumerated() {
            let path = file.fingerprint.path
            seenPaths.insert(path)

            if let cached = cachedEntry(for: path), cached.fingerprint == file.fingerprint {
                // 指纹未变：复用上次产出的 Track（含稳定 id），不重读元数据。
                tracks.append(cached.track)
                skippedCount += 1
            } else if let metadata = AudioMetadataReader.readMetadata(at: file.url) {
                let track = Track(
                    url: metadata.url,
                    title: metadata.title,
                    artist: metadata.artist,
                    duration: metadata.duration
                )
                store(CacheEntry(fingerprint: file.fingerprint, metadata: metadata, track: track), for: path)
                tracks.append(track)
                scannedCount += 1
            } else {
                // Keep cached identity: a read failure is not evidence of deletion.
                isComplete = false
                Log.db.debug("媒体库扫描跳过不可读文件：\(path, privacy: .public)")
            }

            publish(LibraryScanProgress(phase: .reading, discovered: total, processed: index + 1, total: total))
        }

        // 剪枝：被扫描子树内本轮未再出现的路径，从缓存移除（删除/改名）。
        let removedCount = isComplete ? pruneCache(under: root, keeping: seenPaths) : 0

        publish(LibraryScanProgress(phase: .finished, discovered: total, processed: total, total: total))
        let summary = "媒体库扫描完成：\(root.path) 入库 \(tracks.count) 首，"
            + "重读 \(scannedCount)，复用 \(skippedCount)，剔除 \(removedCount)"
        Log.db.info("\(summary, privacy: .public)")

        return LibraryScanResult(
            directory: root,
            tracks: tracks,
            discoveredCount: total,
            ignoredFileCount: discovery.ignoredCount,
            scannedCount: scannedCount,
            skippedCount: skippedCount,
            removedCount: removedCount,
            isComplete: isComplete
        )
    }

    // MARK: 目录枚举

    private struct DiscoveryResult {
        var files: [DiscoveredFile]
        var ignoredCount: Int
        var isComplete: Bool
    }

    /// 深度优先枚举 root 下的音频文件。
    ///
    /// 符号链接（文件与目录）一律跳过：Android 版 SAF/MediaStore 天然不返回链接，
    /// macOS 侧若跟随目录链接，遇到「子目录链接指向上级」会无限递归，故直接不跟随。
    /// 无法读取的子目录只记日志并跳过，不中断整轮扫描。
    private func discoverAudioFiles(
        in root: URL,
        fileManager: FileManager
    ) -> DiscoveryResult {
        let keys: Set<URLResourceKey> = [
            .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey,
            .fileSizeKey, .contentModificationDateKey
        ]
        var files: [DiscoveredFile] = []
        var ignoredCount = 0
        var isComplete = true
        var stack: [URL] = [root]

        while let directory = stack.popLast() {
            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Array(keys),
                    options: []
                )
            } catch {
                let failure = "媒体库扫描跳过无法读取的目录：\(directory.path) \(error)"
                Log.db.error("\(failure, privacy: .public)")
                isComplete = false
                continue
            }

            var subdirectories: [URL] = []
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                guard let values = try? entry.resourceValues(forKeys: keys) else {
                    isComplete = false
                    continue
                }

                // 符号链接优先判定：isDirectory 会反映链接目标，先看 isSymbolicLink 才能挡住
                // 「指向目录的链接」被当成真目录继续下探。
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    subdirectories.append(entry)
                    continue
                }
                guard values.isRegularFile == true else { continue }

                guard Self.supportedExtensions.contains(entry.pathExtension.lowercased()) else {
                    ignoredCount += 1
                    continue
                }

                files.append(
                    DiscoveredFile(
                        url: entry,
                        fingerprint: AudioFileFingerprint(
                            url: entry,
                            fileSize: Int64(values.fileSize ?? 0),
                            modificationDate: values.contentModificationDate
                        )
                    )
                )
            }

            // 反序入栈，使弹出顺序为「升序子目录」，整体呈现稳定的深度优先遍历。
            for subdirectory in subdirectories.reversed() {
                stack.append(subdirectory)
            }
        }

        return DiscoveryResult(files: files, ignoredCount: ignoredCount, isComplete: isComplete)
    }

    // MARK: 缓存访问（全部在锁内）

    private func cachedEntry(for path: String) -> CacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        return cache[path]
    }

    /// 取某文件在缓存里的完整元数据（`Track` 的超集：含 album/封面字节/格式/体积）。
    ///
    /// 只读出口，供落库层（M2-T4 的 `LibrarySyncService`）在不二次读盘的前提下拿到
    /// 封面与格式。返回 nil 的条件：该文件从未被本实例扫到，或本轮被剔除缓存。
    /// 命中缓存的「复用」文件同样能取到（缓存条目里保留着上次读出的 metadata）。
    public func metadata(for url: URL) -> AudioMetadata? {
        cachedEntry(for: url.standardizedFileURL.path)?.metadata
    }

    private func store(_ entry: CacheEntry, for path: String) {
        lock.lock()
        cache[path] = entry
        lock.unlock()
    }

    private func removeCacheEntry(for path: String) {
        lock.lock()
        cache.removeValue(forKey: path)
        lock.unlock()
    }

    /// 剔除 root 子树内、本轮未出现的缓存条目。
    /// 只剪枝本子树：多目录共用实例时，不误伤其他已扫描目录的缓存。
    private func pruneCache(under root: URL, keeping seenPaths: Set<String>) -> Int {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        lock.lock()
        let stale = cache.keys.filter { $0.hasPrefix(prefix) && !seenPaths.contains($0) }
        for path in stale {
            cache.removeValue(forKey: path)
        }
        lock.unlock()
        return stale.count
    }

    // MARK: 进度发布

    private func publish(_ progress: LibraryScanProgress) {
        lock.lock()
        let listeners = Array(continuations.values)
        lock.unlock()
        for listener in listeners {
            listener.yield(progress)
        }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
