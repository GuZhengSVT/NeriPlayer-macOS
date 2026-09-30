// LibraryViewModel.swift
// NeriPlayer macOS —— 媒体库 tab 的视图模型与聚合纯函数（移植规划 M2-T5、M2-T6）。
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
// 收藏与歌单（M2-T7）：为什么不新开一个 PlaylistListViewModel —— 歌单列表本来就由本类持有
// （右键「加入歌单」子菜单的数据源就是它）。若歌单管理页另起一个视图模型，同一个歌单集合会有
// 两份内存态：在管理页新建的歌单不会出现在右键菜单里，反之亦然，除非再补一层跨模型同步。
// 让两者共用 LibraryViewModel 是本任务的选择：一份 playlists、一条 refresh 路径、
// 一个错处可查。收藏同理（favorites / favoriteTrackIds 与曲目列表同批刷新）。
//
// 「只看收藏」过滤为什么复用搜索管线：过滤后的列表同样要驱动歌手/专辑聚合与「播放全部」，
// 若在视图里再过滤一遍，聚合就会与列表不同源。这里把 onlyFavorites 纳入取数：索引建在
// 「当前数据源」（收藏或全库）之上，搜索、聚合、过滤三者自动共享同一批曲目。
//
// 边界（不做）：编辑元数据、智能歌单、拖拽排序的动画打磨 —— 属于后续任务或更晚的里程碑。
//
// 搜索（M2-T6）：搜索框内容放这里而不是视图的 @State —— 搜索要用拼音索引，索引必须在
// 曲目集变化时作废重建，这个生命周期只有拥有曲目的视图模型看得见。防抖 200ms 后先在
// 后台线程建索引（ICU 转拼音是重活），再回主线程算结果；三个维度共用同一批命中曲目。

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
    /// 实现直接转发 M2-T6 的 LibrarySearchEngine.normalize：聚合分组与库内搜索必须用同一套
    /// 折叠规则，否则会出现「搜索认得这个歌手、聚合却分成两组」的割裂。
    static func normalize(_ text: String) -> String {
        LibrarySearchEngine.normalize(text)
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

/// 歌单内曲目的排序纯函数。
///
/// 单独成一处是为了让「拖拽落库的顺序」可以被单测直接断言：视图给的是 IndexSet + 目标下标，
/// 仓库要的是完整的新顺序（见 `PlaylistRepository.reorder`），中间的数组搬移不放视图里。
enum PlaylistOrdering {

    /// 把 `items` 中 `source` 位置上的元素整体搬到 `destination` 之前，返回新数组。
    ///
    /// 语义对齐 SwiftUI `MutableCollection.move(fromOffsets:toOffset:)`：
    /// destination 是「插入点」在**搬移前**的下标。搬移自身是稳定的——被移动的元素保持
    /// 相对顺序，其余元素也保持相对顺序。
    static func moved<T>(_ items: [T], from source: IndexSet, to destination: Int) -> [T] {
        let removed = source.sorted().map { items[$0] }
        var remaining = items
        for index in source.sorted(by: >) { remaining.remove(at: index) }
        // destination 是搬移前坐标系里的插入点：减去「位于它之前、已被移除的元素」个数。
        let insertionIndex = destination - source.filter { $0 < destination }.count
        let clamped = min(max(insertionIndex, 0), remaining.count)
        return Array(remaining[0..<clamped]) + removed + Array(remaining[clamped...])
    }
}

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
    /// 各歌单曲目数（playlistId -> count），歌单列表页的「N 首」角标用它，避免逐行查库。
    @Published private(set) var playlistCounts: [UUID: Int] = [:]
    /// 当前打开的歌单详情对应的歌单 id；nil 表示停在歌单列表页。
    @Published var openPlaylistId: UUID?
    /// 当前打开歌单的曲目（按 position 升序），驱动详情页列表与整单播放。
    @Published private(set) var playlistEntries: [LibraryTrack] = []
    /// 全部收藏曲目，按收藏时间倒序（M2-T7）。
    @Published private(set) var favorites: [LibraryTrack] = []
    /// 已收藏曲目的 id 集合，供列表行批量渲染星标（一次取全，避免逐行查库）。
    @Published private(set) var favoriteTrackIds: Set<UUID> = []
    /// 「只看收藏」开关。改为 true 时当前列表（含搜索与歌手/专辑聚合）只保留收藏曲目。
    @Published var onlyFavorites: Bool = false {
        didSet {
            guard onlyFavorites != oldValue else { return }
            // 数据源换了：聚合要按新的数据源重算，旧的拼音索引与命中结果也都不能再用。
            invalidateSearchIndex()
            recomputeAggregates()
            refreshSearchState()
        }
    }
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

    /// 搜索框内容（M2-T6）。写入后等 200ms 再重算，避免每个按键都触发一次拼音转换。
    @Published var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            scheduleSearch()
        }
    }
    /// 搜索命中的曲目（M2-T6）；查询为空时就是全部曲目，保持「清空搜索框 = 原列表」。
    @Published private(set) var searchResults: [LibraryTrack] = []
    /// 命中曲目按歌手聚合的结果。始终与 searchResults 同源，因此不搜索时等于全部歌手。
    @Published private(set) var searchArtistGroups: [ArtistGroup] = []
    /// 命中曲目按专辑聚合的结果，规则同上。
    @Published private(set) var searchAlbumGroups: [AlbumGroup] = []
    /// 是否有一次搜索尚未结算（防抖等待 + 后台建索引期间）。视图用它显示轻量进度提示，
    /// 免得让用户以为「列表没反应」。
    @Published private(set) var isSearchSettling = false

    private let libraryRepository: LibraryRepository
    private let playlistRepository: PlaylistRepository
    private let favoriteRepository: FavoriteRepository
    private let syncService: LibrarySyncService

    /// 扫描目录记忆（M3-T5）。由 AppState 注入；为 nil 时不记录（独立使用与测试场景）。
    ///
    /// 用可变属性而不是 init 参数：M2 的测试大量直接构造本类，为 M3-T5 的一个可选副作用
    /// 去改所有调用点不划算；默认 nil 也让「不记录目录」成为显式的默认行为。
    var directoryStore: LibraryDirectoryStore?

    /// 搜索防抖窗口：连续输入在 200ms 内只结算一次。
    private static let searchDebounceNanoseconds: UInt64 = 200_000_000
    /// 待结算的搜索任务；新输入到来时先取消上一次。
    private var searchTask: Task<Void, Never>?
    /// 当前曲目集的拼音索引（懒建 + 缓存）。
    private var searchIndex: LibrarySearchIndex?
    /// 正在后台构建的索引任务，避免同一时刻重复建。
    private var searchIndexTask: Task<LibrarySearchIndex, Never>?
    /// 曲目集代数：每次 refresh 递增，用来判定「回来的索引/结果是否已经过期」。
    private var libraryGeneration = 0

    /// 注入仓库构造。syncService 缺省由注入的仓库构造，并长期持有（增量缓存）。
    init(
        libraryRepository: LibraryRepository,
        playlistRepository: PlaylistRepository,
        favoriteRepository: FavoriteRepository,
        syncService: LibrarySyncService? = nil
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.favoriteRepository = favoriteRepository
        self.syncService = syncService ?? LibrarySyncService(repository: libraryRepository)
    }

    /// 便捷构造：直接用数据库建仓库（生产路径与测试都可用）。
    convenience init(database: DatabaseProvider) {
        self.init(
            libraryRepository: LibraryRepository(database),
            playlistRepository: PlaylistRepository(database),
            favoriteRepository: FavoriteRepository(database)
        )
    }

    /// 库中是否没有曲目（首次启动引导的显示条件）。
    var isEmpty: Bool { tracks.isEmpty }

    /// 当前数据源：全库，或「只看收藏」时的收藏集。搜索索引、聚合、列表都从这里取数，
    /// 因此过滤开关一开，三个维度（歌曲/歌手/专辑）一起收敛为收藏曲目。
    var sourceTracks: [LibraryTrack] { onlyFavorites ? favorites : tracks }

    /// 「只看收藏」开着但一首收藏都没有：视图用它显示「还没有收藏」而不是「库是空的」。
    var isFavoritesFilterEmpty: Bool { onlyFavorites && favorites.isEmpty }

    /// 当前打开的歌单（nil 表示停在歌单列表页）。
    var openPlaylist: PlaylistInfo? {
        guard let openPlaylistId else { return nil }
        return playlists.first { $0.id == openPlaylistId }
    }

    /// 是否处于搜索态（查询串去掉首尾空白后非空）。
    var isSearching: Bool { !LibrarySearchEngine.normalize(searchQuery).isEmpty }

    // MARK: 加载

    /// 首次进入媒体库时加载。与 refresh() 等价，保留独立名字只为让调用意图在视图侧可读。
    func load() {
        refresh()
    }

    /// 从库重读曲目、重新聚合，并刷新歌单列表。读取失败只置错误提示，保留旧数据。
    func refresh() {
        defer { hasLoaded = true }
        // 曲目集要换了：旧索引与旧结果立刻作废，避免用上一批数据答这一批查询。
        invalidateSearchIndex()
        do {
            let loaded = try libraryRepository.allTracksSorted(by: .title)
            tracks = loaded
            let loadedFavorites = try favoriteRepository.favorites()
            favorites = loadedFavorites
            favoriteTrackIds = Set(loadedFavorites.map(\.id))
            recomputeAggregates()
            try reloadPlaylistList()
            reloadOpenPlaylist()
            errorMessage = nil
            refreshSearchState()
        } catch {
            errorMessage = "媒体库加载失败：\(error.localizedDescription)"
            Log.ui.error("媒体库加载失败：\(error.localizedDescription)")
        }
    }

    /// 按当前数据源重算歌手/专辑聚合。
    private func recomputeAggregates() {
        let source = sourceTracks
        artistGroups = LibraryGrouping.artistGroups(from: source)
        albumGroups = LibraryGrouping.albumGroups(from: source)
    }

    /// 重读歌单列表与各歌单曲目数。所有会改动歌单集合的写入口都走这里，
    /// 保证「列表」与「计数」永远同批刷新（少一处，就会出现删了歌单但角标还留着的错位）。
    private func reloadPlaylistList() throws {
        playlists = try playlistRepository.list()
        playlistCounts = try playlistRepository.entryCounts()
    }

    /// 详情页回读：按歌手组 id 取最新曲目（同步刷新后详情跟随更新，而不是显示进页时的快照）。
    /// 搜索态下优先查滤镜后的聚合，否则从「某歌手（已过滤）」点进去会看到该歌手全部曲目。
    func tracks(for group: ArtistGroup) -> [LibraryTrack] {
        let source = isSearching ? searchArtistGroups : artistGroups
        return source.first { $0.id == group.id }?.tracks ?? group.tracks
    }

    /// 详情页回读：按专辑组 id 取最新曲目。
    func tracks(for group: AlbumGroup) -> [LibraryTrack] {
        let source = isSearching ? searchAlbumGroups : albumGroups
        return source.first { $0.id == group.id }?.tracks ?? group.tracks
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
        // M3-T5：把用户导入过的目录记下来（幂等），这样设置页里能看到并重新扫描它。
        // 记录放在扫描之前：即使扫描失败，用户的选择也不该被丢掉。
        directoryStore?.add(directory)
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
            try reloadPlaylistList()
            if openPlaylistId == playlist.id { reloadOpenPlaylist() }
            statusMessage = "已加入歌单「\(playlist.name)」"
        } catch {
            errorMessage = "加入歌单失败：\(error.localizedDescription)"
        }
    }

    /// 新建歌单，可选把当前右键的曲目一并加入。
    func createPlaylist(named name: String, adding track: LibraryTrack?) {
        guard let trimmed = validatedPlaylistName(name) else { return }
        do {
            let playlist = try playlistRepository.create(name: trimmed)
            if let track {
                try playlistRepository.addTrack(playlistId: playlist.id, trackId: track.id)
            }
            try reloadPlaylistList()
            statusMessage = "已新建歌单「\(trimmed)」"
        } catch {
            errorMessage = "新建歌单失败：\(error.localizedDescription)"
        }
    }

    /// 重命名歌单。名字去空白后为空即拒绝（与新建同一条校验）。
    func renamePlaylist(_ playlist: PlaylistInfo, to name: String) {
        guard let trimmed = validatedPlaylistName(name) else { return }
        guard trimmed != playlist.name else { return }
        do {
            try playlistRepository.rename(id: playlist.id, to: trimmed)
            try reloadPlaylistList()
            statusMessage = "已重命名为「\(trimmed)」"
        } catch {
            errorMessage = "重命名失败：\(error.localizedDescription)"
        }
    }

    /// 删除歌单。调用方负责先弹确认；这里只做删除与列表刷新。
    /// 若删的正是当前打开的歌单，顺手退回列表页，避免详情页停在已不存在的 id 上。
    func deletePlaylist(_ playlist: PlaylistInfo) {
        do {
            try playlistRepository.delete(id: playlist.id)
            try reloadPlaylistList()
            if openPlaylistId == playlist.id { closePlaylist() }
            statusMessage = "已删除歌单「\(playlist.name)」"
        } catch {
            errorMessage = "删除歌单失败：\(error.localizedDescription)"
        }
    }

    /// 歌单名去空白校验：为空时置错误提示并返回 nil，让新建/重命名共用同一条规则。
    /// 提示文案与 M2-T5 保持一致（既有测试断言了这条字符串）。
    private func validatedPlaylistName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        errorMessage = "歌单名不能为空"
        return nil
    }

    // MARK: 歌单详情

    /// 打开歌单详情（读该歌单的曲目）。
    func openPlaylist(_ playlist: PlaylistInfo) {
        openPlaylistId = playlist.id
        reloadOpenPlaylist()
    }

    /// 返回歌单列表页。
    func closePlaylist() {
        openPlaylistId = nil
        playlistEntries = []
    }

    /// 重读当前打开歌单的曲目。歌单被删或未打开时清空详情态。
    private func reloadOpenPlaylist() {
        guard let openPlaylistId, playlists.contains(where: { $0.id == openPlaylistId }) else {
            playlistEntries = []
            return
        }
        do {
            playlistEntries = try playlistRepository.entriesDetailed(playlistId: openPlaylistId)
        } catch {
            errorMessage = "读取歌单失败：\(error.localizedDescription)"
            playlistEntries = []
        }
    }

    /// 从打开的歌单移除一首曲目。
    func removeFromOpenPlaylist(_ track: LibraryTrack) {
        guard let openPlaylistId else { return }
        do {
            try playlistRepository.removeTrack(playlistId: openPlaylistId, trackId: track.id)
            playlistEntries = try playlistRepository.entriesDetailed(playlistId: openPlaylistId)
            try reloadPlaylistList()
        } catch {
            errorMessage = "移出歌单失败：\(error.localizedDescription)"
        }
    }

    /// 把拖拽结果落到打开的歌单：先把内存里的顺序按拖拽移动，再把完整顺序交给仓库重排。
    ///
    /// 先算内存顺序是为了给仓库一份「权威的完整顺序」——仓库的 reorder 支持只传前几首，
    /// 但拖拽的语义是「这一首插到这里」，传全量列表才与其一一对应，也不会依赖仓库的兜底顺序。
    func moveInOpenPlaylist(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let openPlaylistId else { return }
        let reordered = PlaylistOrdering.moved(playlistEntries, from: source, to: destination)
        // 乐观更新：UI 立刻按新顺序重排，失败时再落回库里的真实顺序。
        playlistEntries = reordered
        do {
            try playlistRepository.reorder(playlistId: openPlaylistId, trackIds: reordered.map(\.id))
            try reloadPlaylistList()
        } catch {
            errorMessage = "调整顺序失败：\(error.localizedDescription)"
            reloadOpenPlaylist()
        }
    }

    // MARK: 收藏

    /// 是否已收藏。列表行渲染星标时逐行查询（集合来自 favoriteTrackIds，无需查库）。
    func isFavorited(_ track: LibraryTrack) -> Bool {
        favoriteTrackIds.contains(track.id)
    }

    /// 切换一首曲目的收藏状态，并刷新收藏列表与星标集合。
    func toggleFavorite(_ track: LibraryTrack) {
        do {
            let nowFavorited = try favoriteRepository.toggle(trackId: track.id)
            let refreshed = try favoriteRepository.favorites()
            favorites = refreshed
            favoriteTrackIds = Set(refreshed.map(\.id))
            // 「只看收藏」开着时取消收藏，该曲应从当前列表消失，聚合与搜索一起重算。
            if onlyFavorites { invalidateSearchIndex() }
            recomputeAggregates()
            refreshSearchState()
            statusMessage = nowFavorited ? "已收藏「\(track.title)」" : "已取消收藏「\(track.title)」"
        } catch {
            errorMessage = "收藏操作失败：\(error.localizedDescription)"
        }
    }

    // MARK: 内部

    // MARK: 搜索（M2-T6）

    /// 计划一次搜索结算。默认走 200ms 防抖；refresh 之后需要立刻对齐结果时传 debounce: false。
    private func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel()
        guard isSearching else {
            // 查询被清空：不必等防抖，直接回到全量列表。
            isSearchSettling = false
            refreshSearchState()
            return
        }
        isSearchSettling = true
        let query = searchQuery
        let generation = libraryGeneration
        searchTask = Task { [weak self] in
            if debounce {
                do {
                    try await Task.sleep(nanoseconds: Self.searchDebounceNanoseconds)
                } catch {
                    return // 被后续输入取消，交给那一轮结算
                }
            }
            guard let self, let index = await self.librarySearchIndex(for: generation) else { return }
            self.applySearch(index.search(query), for: query)
        }
    }

    /// 取当前曲目集的搜索索引（懒建 + 缓存，构建在后台线程）。
    /// generation 与当前值不符说明曲目集已经换过，本次索引作废，直接返回 nil 让本轮放弃。
    private func librarySearchIndex(for generation: Int) async -> LibrarySearchIndex? {
        if let searchIndex { return searchIndex }
        // 建在「当前数据源」上：只看收藏时索引里只有收藏曲目，查询自然不会命中未收藏的歌。
        let source = sourceTracks
        let task = searchIndexTask ?? Task.detached(priority: .userInitiated) {
            LibrarySearchIndex(tracks: source)
        }
        searchIndexTask = task
        let index = await task.value
        searchIndexTask = nil
        guard generation == libraryGeneration else { return nil }
        searchIndex = index
        return index
    }

    /// 曲目集变化时作废索引与在途构建。
    private func invalidateSearchIndex() {
        libraryGeneration += 1
        searchIndex = nil
        searchIndexTask?.cancel()
        searchIndexTask = nil
    }

    /// 把查询结果落到界面状态；期间又输入了新内容时放弃这一轮（等新一轮）。
    private func applySearch(_ results: [LibraryTrack], for query: String) {
        guard query == searchQuery else { return }
        searchResults = results
        searchArtistGroups = LibraryGrouping.artistGroups(from: results)
        searchAlbumGroups = LibraryGrouping.albumGroups(from: results)
        isSearchSettling = false
    }

    /// 让搜索相关状态对齐当前曲目集：查询为空即全量，查询非空则重新结算一次。
    private func refreshSearchState() {
        guard isSearching else {
            searchResults = sourceTracks
            searchArtistGroups = artistGroups
            searchAlbumGroups = albumGroups
            return
        }
        scheduleSearch(debounce: false)
    }

    /// 后台同步的 Sendable 结果载体：不把 any Error 跨隔离域带回来（Error 非 Sendable）。
    private enum SyncOutcome: Sendable {
        case success(LibrarySyncResult)
        case failure(String)
    }
}
