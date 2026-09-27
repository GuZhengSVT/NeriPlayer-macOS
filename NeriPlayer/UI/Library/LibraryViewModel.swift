// LibraryViewModel.swift
// NeriPlayer macOS —— 媒体库 tab 的视图模型与聚合纯函数（移植规划 M2-T5）。
//
// 分层：本文件只活在 UI 层。它把 M2-T3/M2-T4 的仓库（读）与 M2-T4 的同步服务（写）缝在一起，
// 向上给 LibraryView 一份可观察状态；聚合（歌手/专辑分组）刻意写成不依赖数据库与视图的纯函数
// （LibraryGrouping），使分组规则可以脱离 GRDB 直接单测。
//
// 线程模型：本类钉在 MainActor 上 —— @Published 的写入必须在主线程，视图读取也只在主线程。
// 唯一的耗时动作（扫描目录 + 落库）是同步阻塞的，importDirectory 把它丢进 detached 任务，
// 只把 Sendable 的结果（LibrarySyncResult / 错误描述）带回主线程应用。
//
// 为什么同步服务长期持有：LibraryScanner 的增量缓存就在服务实例里（见 M2-T2/M2-T4 注释）。
// 每轮同步都新建服务等于每轮重读全部元数据；这里 init 时构造一次并复用。
//
// 边界（不做）：歌单详情页、收藏、编辑元数据、拖拽排序 —— 属于后续任务或更晚的里程碑。

import AppKit
import Combine
import Foundation

// MARK: - 聚合结果

/// 歌手聚合组：同一「归一化歌手」下的全部曲目。
struct ArtistGroup: Identifiable, Hashable {

    /// 归一化歌手键（大小写/变音符/全半角/空白已折叠）。分组与列表 diff 都用它。
    let id: String
    /// 展示名：组内首个曲目的原始歌手写法；歌手缺失时为「未知歌手」。
    let name: String
    /// 组内曲目，已按标题排序。
    let tracks: [LibraryTrack]

    /// 曲目数。
    var count: Int { tracks.count }
}

/// 专辑聚合组：同一 (歌手, 专辑) 下的全部曲目。
///
/// 为什么键要带上歌手：同名专辑（如各版本的 Greatest Hits）属于不同歌手时是不同条目，
/// 只按专辑名分组会把它们错误地并成一张。
struct AlbumGroup: Identifiable, Hashable {

    /// 归一化 (歌手 + 专辑) 键。
    let id: String
    /// 专辑展示名；缺失时为「未知专辑」。
    let album: String
    /// 歌手展示名；缺失时为「未知歌手」。
    let artist: String
    /// 组内曲目，已按标题排序。
    let tracks: [LibraryTrack]

    /// 曲目数。
    var count: Int { tracks.count }

    /// 组内第一张可用封面路径（同专辑各曲目通常共用一张内嵌封面）。
    var coverPath: String? { tracks.first(where: { $0.coverPath != nil })?.coverPath }
}

// MARK: - 聚合纯函数

/// 媒体库聚合的纯函数集合：输入输出都是值类型，不碰数据库、不碰视图，可直接单测。
enum LibraryGrouping {

    /// 歌手缺失时的展示名。
    static let unknownArtist = "未知歌手"
    /// 专辑缺失时的展示名。
    static let unknownAlbum = "未知专辑"

    /// 文本归一化：大小写 / 变音符 / 全半角折叠，再压缩连续空白并去首尾空白。
    ///
    /// 与 M2-T3 的 LibraryRepository 去重用的规则同源，保证「歌手聚合」与「去重判重」
    /// 对同一批数据给出一致的分组，不会出现「去重认为是一首、聚合却分成两组」的割裂。
    static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        return folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 歌手分组键：归一化后为空（nil 或纯空白）时落到「未知歌手」。
    static func artistKey(_ artist: String?) -> String {
        let normalized = normalize(artist ?? "")
        return normalized.isEmpty ? unknownArtist : normalized
    }

    /// 专辑分组键：归一化后为空时落到「未知专辑」。
    static func albumKey(_ album: String?) -> String {
        let normalized = normalize(album ?? "")
        return normalized.isEmpty ? unknownAlbum : normalized
    }

    /// 按归一化歌手分组。组内曲目按标题排序；组间按展示名做 Finder 同款自然序排序。
    static func artistGroups(from tracks: [LibraryTrack]) -> [ArtistGroup] {
        var keys: [String] = []
        var buckets: [String: [LibraryTrack]] = [:]
        for track in tracks {
            let key = artistKey(track.artist)
            if buckets[key] == nil { keys.append(key) }
            buckets[key, default: []].append(track)
        }
        let groups = keys.compactMap { key -> ArtistGroup? in
            guard let items = buckets[key] else { return nil }
            return ArtistGroup(
                id: key,
                name: display(items.first?.artist, fallback: unknownArtist),
                tracks: items.sorted(by: trackOrder)
            )
        }
        return groups.sorted { lhs, rhs in
            nameOrder(lhs.name, rhs.name, tieBreak: (lhs.id, rhs.id))
        }
    }

    /// 按归一化 (歌手, 专辑) 分组。组内曲目按标题排序；组间先歌手后专辑排序。
    static func albumGroups(from tracks: [LibraryTrack]) -> [AlbumGroup] {
        var keys: [String] = []
        var buckets: [String: [LibraryTrack]] = [:]
        for track in tracks {
            let key = artistKey(track.artist) + "\u{1F}" + albumKey(track.album)
            if buckets[key] == nil { keys.append(key) }
            buckets[key, default: []].append(track)
        }
        let groups = keys.compactMap { key -> AlbumGroup? in
            guard let items = buckets[key] else { return nil }
            return AlbumGroup(
                id: key,
                album: display(items.first?.album, fallback: unknownAlbum),
                artist: display(items.first?.artist, fallback: unknownArtist),
                tracks: items.sorted(by: trackOrder)
            )
        }
        return groups.sorted { lhs, rhs in
            let byArtist = lhs.artist.localizedStandardCompare(rhs.artist)
            if byArtist != .orderedSame { return byArtist == .orderedAscending }
            return nameOrder(lhs.album, rhs.album, tieBreak: (lhs.id, rhs.id))
        }
    }

    // MARK: 内部排序/展示

    /// 展示名：优先用原始写法（去掉首尾空白）；nil 或纯空白时回落。
    private static func display(_ value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// 组内曲目顺序：标题自然序，同标题用 url 兜底保证跨查询稳定。
    private static func trackOrder(_ lhs: LibraryTrack, _ rhs: LibraryTrack) -> Bool {
        let comparison = lhs.title.localizedStandardCompare(rhs.title)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.url.absoluteString < rhs.url.absoluteString
    }

    /// 组间顺序：展示名自然序，同名用 id 兜底（幂等，两次聚合结果一致）。
    private static func nameOrder(_ lhs: String, _ rhs: String, tieBreak: (String, String)) -> Bool {
        let comparison = lhs.localizedStandardCompare(rhs)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return tieBreak.0 < tieBreak.1
    }
}

// MARK: - 视图模型

/// 媒体库 tab 的视图模型：曲目/聚合/歌单内存态 + 目录导入 + 歌单写入口。
@MainActor
final class LibraryViewModel: ObservableObject {

    /// 全部曲目，按标题升序。
    @Published private(set) var tracks: [LibraryTrack] = []
    /// 歌手聚合页数据。
    @Published private(set) var artistGroups: [ArtistGroup] = []
    /// 专辑聚合页数据。
    @Published private(set) var albumGroups: [AlbumGroup] = []
    /// 歌单列表（右键「加入歌单」子菜单的数据源）。
    @Published private(set) var playlists: [PlaylistInfo] = []
    /// 当前选中的歌手组（供详情页回读最新数据）。
    @Published var selectedArtist: ArtistGroup?
    /// 当前选中的专辑组。
    @Published var selectedAlbum: AlbumGroup?
    /// 是否正在扫描/导入。
    @Published private(set) var isSyncing = false
    /// 是否完成过至少一次加载（避免首帧把「还没读」误显示成「库为空」）。
    @Published private(set) var hasLoaded = false
    /// 最近一次同步的结果摘要（成功时给状态条显示）。
    @Published private(set) var statusMessage: String?
    /// 可恢复的错误提示（加载/导入/歌单操作失败）。
    @Published var errorMessage: String?

    private let libraryRepository: LibraryRepository
    private let playlistRepository: PlaylistRepository
    private let syncService: LibrarySyncService

    /// 注入仓库构造。syncService 缺省由注入的仓库构造，并长期持有（增量缓存）。
    init(
        libraryRepository: LibraryRepository,
        playlistRepository: PlaylistRepository,
        syncService: LibrarySyncService? = nil
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.syncService = syncService ?? LibrarySyncService(repository: libraryRepository)
    }

    /// 便捷构造：直接用数据库建仓库（生产路径与测试都可用）。
    convenience init(database: DatabaseProvider) {
        self.init(
            libraryRepository: LibraryRepository(database),
            playlistRepository: PlaylistRepository(database)
        )
    }

    /// 库中是否没有曲目（首次启动引导的显示条件）。
    var isEmpty: Bool { tracks.isEmpty }

    // MARK: 加载

    /// 首次进入媒体库时加载。与 refresh() 等价，保留独立名字只为让调用意图在视图侧可读。
    func load() {
        refresh()
    }

    /// 从库重读曲目、重新聚合，并刷新歌单列表。读取失败只置错误提示，保留旧数据。
    func refresh() {
        defer { hasLoaded = true }
        do {
            let loaded = try libraryRepository.allTracksSorted(by: .title)
            tracks = loaded
            artistGroups = LibraryGrouping.artistGroups(from: loaded)
            albumGroups = LibraryGrouping.albumGroups(from: loaded)
            playlists = try playlistRepository.list()
            errorMessage = nil
        } catch {
            errorMessage = "媒体库加载失败：\(error.localizedDescription)"
            Log.ui.error("媒体库加载失败：\(error.localizedDescription)")
        }
    }

    /// 详情页回读：按歌手组 id 取最新曲目（同步刷新后详情跟随更新，而不是显示进页时的快照）。
    func tracks(for group: ArtistGroup) -> [LibraryTrack] {
        artistGroups.first { $0.id == group.id }?.tracks ?? group.tracks
    }

    /// 详情页回读：按专辑组 id 取最新曲目。
    func tracks(for group: AlbumGroup) -> [LibraryTrack] {
        albumGroups.first { $0.id == group.id }?.tracks ?? group.tracks
    }

    // MARK: 目录导入

    /// 首次启动引导 / 工具栏入口：选目录 -> 同步 -> 重新加载。
    func addDirectoryAndSync() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "导入"
        panel.message = "选择要导入媒体库的音乐文件夹"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        importDirectory(directory)
    }

    /// 同步指定目录（与面板解耦：调用方给 URL 即可，便于将来加「最近目录」与测试驱动）。
    ///
    /// 扫描与落库是同步阻塞动作，放到 detached 任务执行；主线程只负责置状态与重新加载。
    func importDirectory(_ directory: URL) {
        guard !isSyncing else { return }
        isSyncing = true
        errorMessage = nil
        statusMessage = "正在扫描「\(directory.lastPathComponent)」…"
        let service = syncService
        Task {
            let outcome: SyncOutcome = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try service.sync(directory: directory))
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value
            isSyncing = false
            apply(outcome)
        }
    }

    /// 把后台同步结果应用到界面状态（已在主线程）。
    private func apply(_ outcome: SyncOutcome) {
        switch outcome {
        case .success(let result):
            refresh()
            let message = "已导入「\(result.directory.lastPathComponent)」："
                + "新增 \(result.inserted)，更新 \(result.updated)，移除 \(result.removed)，"
                + "库共 \(result.totalCount) 首"
            statusMessage = message
            Log.ui.info("\(message, privacy: .public)")
        case .failure(let message):
            statusMessage = nil
            errorMessage = "导入失败：\(message)"
            Log.ui.error("导入失败：\(message, privacy: .public)")
        }
    }

    // MARK: 歌单

    /// 把曲目加入指定歌单（已在歌单内时仓库层幂等，不产生重复条目）。
    func add(_ track: LibraryTrack, to playlist: PlaylistInfo) {
        do {
            try playlistRepository.addTrack(playlistId: playlist.id, trackId: track.id)
            playlists = try playlistRepository.list()
            statusMessage = "已加入歌单「\(playlist.name)」"
        } catch {
            errorMessage = "加入歌单失败：\(error.localizedDescription)"
        }
    }

    /// 新建歌单，可选把当前右键的曲目一并加入。
    func createPlaylist(named name: String, adding track: LibraryTrack?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "歌单名不能为空"
            return
        }
        do {
            let playlist = try playlistRepository.create(name: trimmed)
            if let track {
                try playlistRepository.addTrack(playlistId: playlist.id, trackId: track.id)
            }
            playlists = try playlistRepository.list()
            statusMessage = "已新建歌单「\(trimmed)」"
        } catch {
            errorMessage = "新建歌单失败：\(error.localizedDescription)"
        }
    }

    // MARK: 内部

    /// 后台同步的 Sendable 结果载体：不把 any Error 跨隔离域带回来（Error 非 Sendable）。
    private enum SyncOutcome: Sendable {
        case success(LibrarySyncResult)
        case failure(String)
    }
}
