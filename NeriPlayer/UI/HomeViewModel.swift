// HomeViewModel.swift
// 首页分区数据：推荐歌单 / 榜单与雷达歌曲 / 私人 FM / YouTube Music shelf。
//
// 设计要点（与 Android `ui/viewmodel/tab/HomeViewModel.kt` 对齐）：
//   - 每个分区各自持有 loading/error/items，互不影响；一个分区失败不清空其余分区。
//   - 请求带「代次 + 账号上下文」双重校验，过期结果不写回界面。
//   - 缓存按会话上下文隔离（登录/退出/切号后互不复用私密内容）。
//   - 失败保留上一次成功内容：只有成功才覆盖，失败只更新错误文案。
import Combine
import Foundation

/// 单个分区状态。items 为空且 error 非空代表这一分区本轮失败。
struct HomeSectionState<Item: Equatable & Sendable>: Equatable, Sendable {
    var items: [Item] = []
    var isLoading = false
    var error: String?

    var isEmpty: Bool { items.isEmpty }
    /// 已有内容时刷新失败，界面应保留内容并把错误降级为提示。
    var hasStaleContent: Bool { !items.isEmpty && error != nil }
    /// 「正在加载且还没有任何内容可显示」——只有这种情况才需要加载指示；
    /// 已有旧内容时的后台刷新应静默进行，否则每次进首页都会闪一下。
    var isLoadingAndEmpty: Bool { isLoading && items.isEmpty }
}

struct HomeNeteaseSongSection: Identifiable, Equatable, Sendable {
    var source: NeteaseHomeSongSource
    var section = HomeSectionState<SongData>()

    var id: String { source.rawValue }
}

struct HomeNeteasePlaylistSection: Identifiable, Equatable, Sendable {
    var source: NeteaseHomePlaylistSource
    var section = HomeSectionState<OnlineCollection>()

    var id: String { source.rawValue }
}

/// 首页整体快照。字段全部是可渲染状态，视图只读。
struct HomeSnapshot: Equatable, Sendable {
    var playlistSections: [HomeNeteasePlaylistSection] = []
    var trendingSongSections: [HomeNeteaseSongSection] = []
    var radarSongSections: [HomeNeteaseSongSection] = []
    var radarPlaylists = HomeSectionState<OnlineCollection>()
    var youtubeShelves = HomeSectionState<YouTubeMusicHomeShelf>()
    var hasLogin = false
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var snapshot = HomeSnapshot()
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdatedAt: Date?

    /// 首页网易云分区始终以网易云为源，不受探索页当前平台选择影响。
    let source: MusicSource = .netease
    let content: OnlineContentRepository
    /// 是否加载 YouTube Music 首页栏。默认开启；主智能体可按需关闭。
    var loadsYouTubeMusic = true

    private let sessions: OnlineSessionStore
    private var neteaseTasks: [String: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var activeContext: String?
    private var sessionObservation: AnyCancellable?
    private var youtubeTask: Task<Void, Never>?
    private var youtubeGeneration = UUID()
    private var youtubeContext: String?

    init(content: OnlineContentRepository, sessions: OnlineSessionStore) {
        self.content = content
        self.sessions = sessions
        sessionObservation = NotificationCenter.default.publisher(for: OnlineSessionStore.didChange)
            .sink { [weak self] notification in
                guard notification.object as? OnlineSessionStore === sessions,
                      let changed = notification.userInfo?["source"] as? MusicSource else { return }
                Task { @MainActor [weak self] in self?.handleSessionChange(changed) }
            }
    }

    deinit {
        neteaseTasks.values.forEach { $0.cancel() }
        youtubeTask?.cancel()
    }

    var hasLogin: Bool { snapshot.hasLogin }
    var isNeteaseLoading: Bool {
        snapshot.playlistSections.contains { $0.section.isLoading }
            || snapshot.trendingSongSections.contains { $0.section.isLoading }
            || snapshot.radarSongSections.contains { $0.section.isLoading }
            || snapshot.radarPlaylists.isLoading
    }

    // MARK: - 加载

    /// 首次进入或账号上下文变化时调用。
    func load(force: Bool = false) {
        let context: String
        do { context = try content.context(for: source) } catch {
            applyContextError(error.localizedDescription)
            return
        }
        let loggedIn = Self.hasLogin(sessions: sessions)
        if context != activeContext {
            neteaseTasks.values.forEach { $0.cancel() }
            neteaseTasks = [:]
            generation = UUID()
            snapshot = emptyNeteaseSnapshot(hasLogin: loggedIn)
            lastUpdatedAt = nil
        }
        snapshot.hasLogin = loggedIn
        activeContext = context
        // 分区请求会被仓库的新鲜缓存吸收：同一上下文内重复进入首页不会重复打网络。
        // 这里不再无条件置 isRefreshing —— 有缓存内容时不该闪加载图标（用户反馈的第 6 点），
        // 由各分区按「有没有内容可显示」自行决定，最后统一结算。
        loadNeteaseSections(context: context, force: force, hasLogin: loggedIn)
        if loadsYouTubeMusic { loadYouTubeMusic(force: force) }
        updateRefreshingFlag()
    }

    /// 手动刷新：重取当前登录态下的全部网易云分区，保留已有内容直到新结果返回。
    func reloadNetease(force: Bool = true) {
        let context: String
        do { context = try content.context(for: source) } catch {
            applyContextError(error.localizedDescription)
            return
        }
        let loggedIn = Self.hasLogin(sessions: sessions)
        snapshot.hasLogin = loggedIn
        activeContext = context
        isRefreshing = true
        loadNeteaseSections(context: context, force: force, hasLogin: loggedIn)
    }

    func loadYouTubeMusic(force: Bool = false) {
        let context: String
        do { context = try content.context(for: .youtubeMusic) } catch { return }
        if !force, youtubeContext == context, !snapshot.youtubeShelves.isEmpty { return }
        youtubeTask?.cancel()
        youtubeGeneration = UUID()
        let token = youtubeGeneration
        youtubeContext = context
        if snapshot.youtubeShelves.items.isEmpty,
           let cached = content.cached([YouTubeMusicHomeShelf].self, source: .youtubeMusic,
                                       context: context, resource: OnlineContentRepository.homeShelvesResource) {
            snapshot.youtubeShelves = HomeSectionState(items: cached.value)
        }
        snapshot.youtubeShelves.isLoading = true
        snapshot.youtubeShelves.error = nil
        let content = self.content
        youtubeTask = Task { [weak self] in
            do {
                let value = try await content.youtubeHomeShelves(context: context, force: force)
                guard let self, !Task.isCancelled, youtubeGeneration == token, accepts(context: context, source: .youtubeMusic) else { return }
                snapshot.youtubeShelves = HomeSectionState(items: value.value)
                lastUpdatedAt = value.updatedAt
            } catch {
                guard let self, !Task.isCancelled, youtubeGeneration == token, accepts(context: context, source: .youtubeMusic) else { return }
                // 失败保留已有 shelf，仅更新提示。
                snapshot.youtubeShelves.error = Self.message(error)
            }
            guard let self, !Task.isCancelled, youtubeGeneration == token else { return }
            snapshot.youtubeShelves.isLoading = false
            updateRefreshingFlag()
        }
    }

    func stop() {
        neteaseTasks.values.forEach { $0.cancel() }
        neteaseTasks = [:]
        youtubeTask?.cancel()
        youtubeTask = nil
        generation = UUID()
        youtubeGeneration = UUID()
        isRefreshing = false
    }

    // MARK: - 网易云分区

    private func loadNeteaseSections(context: String, force: Bool, hasLogin: Bool) {
        let playlists = availableNeteaseHomePlaylistSources(neteaseHomePlaylistSources, hasLogin: hasLogin)
        let trending = availableNeteaseHomeSongSources(neteaseHomeTrendingSongSources, hasLogin: hasLogin)
        let radar = availableNeteaseHomeSongSources(neteaseHomeRadarSongSources, hasLogin: hasLogin)
        snapshot.playlistSections = playlists.map {
            HomeNeteasePlaylistSection(source: $0, section: existingPlaylistSection($0) ?? HomeSectionState())
        }
        snapshot.trendingSongSections = trending.map {
            HomeNeteaseSongSection(source: $0, section: existingSongSection($0, in: snapshot.trendingSongSections) ?? HomeSectionState())
        }
        snapshot.radarSongSections = radar.map {
            HomeNeteaseSongSection(source: $0, section: existingSongSection($0, in: snapshot.radarSongSections) ?? HomeSectionState())
        }
        for source in playlists { startPlaylistSection(source, context: context, force: force) }
        for source in trending + radar { startSongSection(source, context: context, force: force) }
        startRadarPlaylists(context: context, force: force)
    }

    private func startPlaylistSection(_ source: NeteaseHomePlaylistSource, context: String, force: Bool) {
        neteaseTasks["playlist:\(source.rawValue)"]?.cancel()
        let token = generation
        if existingPlaylistSection(source)?.items.isEmpty ?? true,
           let cached = content.cached([OnlineCollection].self, source: .netease, context: context,
                                       resource: OnlineContentRepository.homePlaylistResource(source)) {
            updatePlaylistSection(source) { $0 = HomeSectionState(items: cached.value) }
        }
        // 已有内容（来自内存/磁盘缓存或上次结果）时也照常标记 isLoading —— 它是「分区正在请求」
        // 的真实状态，测试与刷新按钮的禁用都依赖它。界面要不要因此显示加载图标由
        // updateRefreshingFlag() 决定：只有「还没有内容可显示」的分区才该闪图标。
        updatePlaylistSection(source) { $0.isLoading = true; $0.error = nil }
        let content = self.content
        neteaseTasks["playlist:\(source.rawValue)"] = Task { [weak self] in
            do {
                let value = try await content.homePlaylistSection(source: source, context: context, force: force)
                guard let self, !Task.isCancelled, generation == token, accepts(context: context, source: .netease) else { return }
                updatePlaylistSection(source) { $0 = HomeSectionState(items: value.value) }
                lastUpdatedAt = value.updatedAt
            } catch {
                guard let self, !Task.isCancelled, generation == token, accepts(context: context, source: .netease) else { return }
                // 失败保留旧内容：只改 error，不动 items。
                updatePlaylistSection(source) { $0.isLoading = false; $0.error = Self.message(error) }
            }
            guard let self, !Task.isCancelled, generation == token else { return }
            updateRefreshingFlag()
        }
    }

    private func startSongSection(_ source: NeteaseHomeSongSource, context: String, force: Bool) {
        neteaseTasks["song:\(source.rawValue)"]?.cancel()
        let token = generation
        if currentSongSection(source)?.items.isEmpty ?? true,
           let cached = content.cached([SongData].self, source: .netease, context: context,
                                       resource: OnlineContentRepository.homeSongResource(source)) {
            updateSongSection(source) { $0 = HomeSectionState(items: cached.value) }
        }
        updateSongSection(source) { $0.isLoading = true; $0.error = nil }
        let content = self.content
        neteaseTasks["song:\(source.rawValue)"] = Task { [weak self] in
            do {
                let value = try await content.homeSongSection(source: source, context: context, force: force)
                guard let self, !Task.isCancelled, generation == token, accepts(context: context, source: .netease) else { return }
                updateSongSection(source) { $0 = HomeSectionState(items: value.value) }
                lastUpdatedAt = value.updatedAt
            } catch {
                guard let self, !Task.isCancelled, generation == token, accepts(context: context, source: .netease) else { return }
                updateSongSection(source) { $0.isLoading = false; $0.error = Self.message(error) }
            }
            guard let self, !Task.isCancelled, generation == token else { return }
            updateRefreshingFlag()
        }
    }

    private func startRadarPlaylists(context: String, force: Bool) {
        neteaseTasks["radar"]?.cancel()
        let token = generation
        if snapshot.radarPlaylists.items.isEmpty,
           let cached = content.cached([OnlineCollection].self, source: .netease, context: context,
                                       resource: OnlineContentRepository.homeRadarResource) {
            snapshot.radarPlaylists = HomeSectionState(items: cached.value)
        }
        snapshot.radarPlaylists.isLoading = true
        snapshot.radarPlaylists.error = nil
        let content = self.content
        neteaseTasks["radar"] = Task { [weak self] in
            do {
                let value = try await content.homeRadarPlaylists(context: context, force: force)
                guard let self, !Task.isCancelled, generation == token, accepts(context: context, source: .netease) else { return }
                snapshot.radarPlaylists = HomeSectionState(items: value.value)
            } catch {
                guard let self, !Task.isCancelled, generation == token, accepts(context: context, source: .netease) else { return }
                snapshot.radarPlaylists.isLoading = false
                snapshot.radarPlaylists.error = Self.message(error)
            }
            guard let self, !Task.isCancelled, generation == token else { return }
            snapshot.radarPlaylists.isLoading = false
            updateRefreshingFlag()
        }
    }

    // MARK: - 会话与状态

    /// 登录、退出或切号：只重建受影响平台的分区，避免私密内容串号，也不波及另一平台。
    private func handleSessionChange(_ changed: MusicSource) {
        switch changed {
        case .netease:
            neteaseTasks.values.forEach { $0.cancel() }
            neteaseTasks = [:]
            generation = UUID()
            activeContext = nil
            snapshot = emptyNeteaseSnapshot(hasLogin: Self.hasLogin(sessions: sessions))
        case .youtubeMusic:
            youtubeTask?.cancel()
            youtubeTask = nil
            youtubeGeneration = UUID()
            youtubeContext = nil
            snapshot.youtubeShelves = HomeSectionState()
        case .bilibili:
            return
        }
        load()
    }

    private func accepts(context: String, source: MusicSource) -> Bool {
        (try? content.context(for: source)) == context
    }

    private func applyContextError(_ message: String) {
        snapshot.playlistSections = neteaseHomePlaylistSources.map {
            HomeNeteasePlaylistSection(source: $0, section: HomeSectionState(error: message))
        }
        snapshot.trendingSongSections = neteaseHomeTrendingSongSources.map {
            HomeNeteaseSongSection(source: $0, section: HomeSectionState(error: message))
        }
        snapshot.radarSongSections = neteaseHomeRadarSongSources.map {
            HomeNeteaseSongSection(source: $0, section: HomeSectionState(error: message))
        }
        snapshot.radarPlaylists = HomeSectionState(error: message)
        isRefreshing = false
    }

    private func emptyNeteaseSnapshot(hasLogin: Bool) -> HomeSnapshot {
        HomeSnapshot(
            playlistSections: availableNeteaseHomePlaylistSources(neteaseHomePlaylistSources, hasLogin: hasLogin)
                .map { HomeNeteasePlaylistSection(source: $0) },
            trendingSongSections: availableNeteaseHomeSongSources(neteaseHomeTrendingSongSources, hasLogin: hasLogin)
                .map { HomeNeteaseSongSection(source: $0) },
            radarSongSections: availableNeteaseHomeSongSources(neteaseHomeRadarSongSources, hasLogin: hasLogin)
                .map { HomeNeteaseSongSection(source: $0) },
            hasLogin: hasLogin
        )
    }

    private func existingPlaylistSection(_ source: NeteaseHomePlaylistSource) -> HomeSectionState<OnlineCollection>? {
        snapshot.playlistSections.first { $0.source == source }?.section
    }

    private func existingSongSection(
        _ source: NeteaseHomeSongSource,
        in sections: [HomeNeteaseSongSection]
    ) -> HomeSectionState<SongData>? {
        sections.first { $0.source == source }?.section
    }

    private func currentSongSection(_ source: NeteaseHomeSongSource) -> HomeSectionState<SongData>? {
        snapshot.trendingSongSections.first { $0.source == source }?.section
            ?? snapshot.radarSongSections.first { $0.source == source }?.section
    }

    private func updatePlaylistSection(
        _ source: NeteaseHomePlaylistSource,
        _ mutate: (inout HomeSectionState<OnlineCollection>) -> Void
    ) {
        guard let index = snapshot.playlistSections.firstIndex(where: { $0.source == source }) else { return }
        mutate(&snapshot.playlistSections[index].section)
    }

    private func updateSongSection(_ source: NeteaseHomeSongSource, _ mutate: (inout HomeSectionState<SongData>) -> Void) {
        if let index = snapshot.trendingSongSections.firstIndex(where: { $0.source == source }) {
            mutate(&snapshot.trendingSongSections[index].section)
            return
        }
        if let index = snapshot.radarSongSections.firstIndex(where: { $0.source == source }) {
            mutate(&snapshot.radarSongSections[index].section)
        }
    }

    /// 顶部「正在刷新」指示与刷新按钮的禁用状态。
    ///
    /// 只在**确实有分区还没有内容可显示**时为真：首页内容本身有缓存（内存 + 磁盘，
    /// 网易云分区 30 分钟、雷达/YouTube 15 分钟），再次进入首页时旧内容会立刻渲染，
    /// 此时后台刷新不该在标题旁闪一个加载图标（用户反馈的第 6 点）。
    /// 仍为空的分区由各分区自己的 HomeLoadingRow 占位，不依赖这个标志。
    private func updateRefreshingFlag() {
        isRefreshing = isNeteaseLoadingAndEmpty || snapshot.youtubeShelves.isLoadingAndEmpty
    }

    /// 网易云是否有「正在加载且尚无内容」的分区。
    private var isNeteaseLoadingAndEmpty: Bool {
        snapshot.playlistSections.contains { $0.section.isLoading && $0.section.items.isEmpty }
            || snapshot.trendingSongSections.contains { $0.section.isLoading && $0.section.items.isEmpty }
            || snapshot.radarSongSections.contains { $0.section.isLoading && $0.section.items.isEmpty }
            || (snapshot.radarPlaylists.isLoading && snapshot.radarPlaylists.items.isEmpty)
    }

    private static func hasLogin(sessions: OnlineSessionStore) -> Bool {
        guard let cookie = try? sessions.cookieHeader(for: .netease), !cookie.isEmpty else { return false }
        return cookie.contains("MUSIC_U=")
    }

    private static func message(_ error: Error) -> String {
        if error as? OnlineError == .authenticationRequired { return "登录后可用" }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
