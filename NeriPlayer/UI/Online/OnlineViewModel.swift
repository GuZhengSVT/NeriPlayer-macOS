// OnlineViewModel.swift
// M5-T9: cancellable search, source browsing, collection detail and authentication state.
import Combine
import Foundation

@MainActor
public final class OnlineViewModel: ObservableObject {
    @Published public private(set) var source: MusicSource = .netease
    @Published public private(set) var query = ""
    @Published public private(set) var results: [SongData] = []
    @Published public private(set) var recommendations: [SongData] = []
    @Published public private(set) var collections: [OnlineCollection] = []
    @Published public private(set) var collectionSongs: [SongData] = []
    @Published public private(set) var selectedCollection: OnlineCollection?
    @Published public private(set) var isSearching = false
    @Published public private(set) var isLoadingRecommendations = false
    @Published public private(set) var isLoadingCollections = false
    @Published public private(set) var isLoadingDetail = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var detailError: String?
    @Published public private(set) var partialErrors: [MusicSource: String] = [:]
    @Published public private(set) var browseErrors: [String: String] = [:]
    @Published public private(set) var account: OnlineAccount?
    @Published public private(set) var loginState: QRLoginState?
    @Published public private(set) var loginTicket: QRLoginTicket?
    @Published public private(set) var isLoggingIn = false
    @Published public private(set) var isImportingCookies = false
    @Published public private(set) var loginMessage: String?
    @Published public private(set) var page = 1
    @Published public private(set) var hasMoreResults = false
    @Published public private(set) var searchesAllSources = false
    @Published public private(set) var recommendationsUpdatedAt: Date?
    @Published public private(set) var collectionsUpdatedAt: Date?
    @Published public private(set) var detailUpdatedAt: Date?
    @Published public private(set) var isLoadingAccount = false
    @Published public private(set) var isDetailComplete = false
    var songsSearchEnabled = true

    private let manager: OnlineSearchManager
    private let clients: [MusicSource: any OnlineMusicClient]
    private let sessions: OnlineSessionStore
    private var store: PlaybackStateStore?
    private var searchTask: Task<Void, Never>?
    private var browseTasks: [Task<Void, Never>] = []
    private var artworkTasks: [String: Task<Void, Never>] = [:]
    private var detailTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var browseGeneration = UUID()
    private var detailGeneration = UUID()
    private var loginGeneration = UUID()
    private var detailTaskGeneration = UUID()
    let content: OnlineContentRepository
    private var activeContext: String?
    private var activeSource: MusicSource?
    private var sessionObservation: AnyCancellable?
    private let loadsBrowseContent: Bool
    var loadsRecommendations = true
    private var scrollAnchors: [String: String] = [:]

    private var navigationKey: String { "\(source.rawValue):\(activeContext ?? "")" }
    var browseScrollAnchor: String? { scrollAnchors[navigationKey] }
    func rememberBrowseAnchor(_ id: String) { scrollAnchors[navigationKey] = id }

    public convenience init(clients: [any OnlineMusicClient], sessions: OnlineSessionStore = .shared,
                            store: PlaybackStateStore? = nil) {
        self.init(clients: clients, sessions: sessions, store: store,
                  content: OnlineContentRepository(clients: clients, sessions: sessions))
    }

    init(clients: [any OnlineMusicClient], sessions: OnlineSessionStore, store: PlaybackStateStore?,
         content: OnlineContentRepository, loadsBrowseContent: Bool = true) {
        var indexed: [MusicSource: any OnlineMusicClient] = [:]
        for client in clients { indexed[client.source] = client }
        self.clients = indexed
        manager = OnlineSearchManager(clients: clients)
        self.sessions = sessions
        self.store = store
        self.content = content
        self.loadsBrowseContent = loadsBrowseContent
        sessionObservation = NotificationCenter.default.publisher(for: OnlineSessionStore.didChange)
            .sink { [weak self] notification in
                guard notification.object as? OnlineSessionStore === sessions,
                      let changed = notification.userInfo?["source"] as? MusicSource else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.source == changed else { return }
                    self.clearDetail()
                    self.activeContext = nil
                    self.loadBrowseContent()
                }
            }
    }

    deinit {
        accountTask?.cancel()
        searchTask?.cancel()
        browseTasks.forEach { $0.cancel() }
        artworkTasks.values.forEach { $0.cancel() }
        detailTask?.cancel()
        loginTask?.cancel()
    }

    public var isSearchMode: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var canPlay: Bool { store != nil }
    public var supportsQR: Bool { source != .youtubeMusic }
    public var supportsCookieImport: Bool { source == .youtubeMusic || source == .bilibili }

    public func attachPlaybackStore(_ store: PlaybackStateStore?) { self.store = store }

    func configureLibrarySource(_ value: MusicSource) { source = value }

    public func setSource(_ value: MusicSource) {
        guard source != value else { return }
        stopLogin()
        source = value
        results = []
        partialErrors = [:]
        errorMessage = nil
        clearDetail()
        loadBrowseContent()
        if isSearchMode { search() }
    }

    public func setSearchesAllSources(_ enabled: Bool) {
        searchesAllSources = enabled
        if isSearchMode { search() }
    }

    public func setQuery(_ value: String) {
        query = value
        scheduleSearch(debounce: true)
    }

    public func search() { scheduleSearch(debounce: false) }
    public func clearSearch() { query = ""; scheduleSearch(debounce: false) }

    private func scheduleSearch(debounce: Bool) {
        searchTask?.cancel()
        searchGeneration = UUID()
        page = 1
        hasMoreResults = false
        partialErrors = [:]
        errorMessage = nil
        guard songsSearchEnabled else { results = []; isSearching = false; return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; isSearching = false; return }
        let token = searchGeneration
        let sources: [MusicSource] = searchesAllSources ? MusicSource.allCases : [source]
        let manager = self.manager
        isSearching = true
        searchTask = Task { [weak self] in
            if debounce {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let result = await manager.search(query: trimmed, page: 1, sources: sources)
            guard !Task.isCancelled, let self, searchGeneration == token else { return }
            applySearch(result, append: false)
        }
    }

    public func loadMore() {
        guard hasMoreResults, !isSearching, isSearchMode else { return }
        let token = searchGeneration
        let nextPage = page + 1
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sources: [MusicSource] = searchesAllSources ? MusicSource.allCases : [source]
        let manager = self.manager
        isSearching = true
        searchTask = Task { [weak self] in
            let result = await manager.search(query: trimmed, page: nextPage, sources: sources)
            guard !Task.isCancelled, let self, searchGeneration == token else { return }
            applySearch(result, append: true)
        }
    }

    private func applySearch(_ result: OnlineSearchPage, append: Bool) {
        let songs = result.results.map(\.song)
        if append {
            let existing = Set(results.map(\.id))
            results.append(contentsOf: songs.filter { !existing.contains($0.id) })
        } else { results = songs }
        partialErrors = result.failedSources
        page = result.page
        hasMoreResults = !songs.isEmpty
        isSearching = false
        if results.isEmpty, !result.failedSources.isEmpty { errorMessage = "搜索暂不可用" }
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func loadBrowseContent(force: Bool = false) {
        guard loadsBrowseContent else { loadAccountContent(force: force); return }
        let selected = source
        let context: String
        do { context = try content.context(for: selected) } catch {
            browseErrors["账号"] = error.localizedDescription
            return
        }
        guard force || activeSource != selected || context != activeContext
            || !(isLoadingRecommendations || isLoadingCollections || isLoadingAccount) else { return }
        browseTasks.forEach { $0.cancel() }
        artworkTasks.values.forEach { $0.cancel() }
        artworkTasks = [:]
        browseGeneration = UUID()
        let token = browseGeneration
        if context != activeContext || activeSource != selected {
            recommendations = []; collections = []; account = nil
            recommendationsUpdatedAt = nil; collectionsUpdatedAt = nil
        }
        activeContext = context
        activeSource = selected
        browseErrors = [:]
        if let value = content.cached([SongData].self, source: selected, context: context, resource: "recommendations") {
            recommendations = value.value; recommendationsUpdatedAt = value.updatedAt
        }
        if let value = content.cached([OnlineCollection].self, source: selected, context: context, resource: "collections") {
            collections = value.value; collectionsUpdatedAt = value.updatedAt
        }
        if let value = content.cached(OnlineAccount.self, source: selected, context: context, resource: "account") { account = value.value }
        isLoadingRecommendations = loadsRecommendations
        isLoadingCollections = true
        isLoadingAccount = true
        let content = self.content
        browseTasks = [
            Task { [weak self] in
                guard let self, self.loadsRecommendations else { return }
                do {
                    let value = try await content.recommendations(source: selected, context: context, force: force)
                    guard acceptsBrowse(token, source: selected, context: context) else { return }
                    recommendations = value.value; recommendationsUpdatedAt = value.updatedAt
                    isLoadingRecommendations = false
                } catch {
                    guard acceptsBrowse(token, source: selected, context: context) else { return }
                    browseErrors["推荐"] = error.localizedDescription; isLoadingRecommendations = false
                }
            },
            Task { [weak self] in
                do {
                    let value = try await content.collections(source: selected, context: context, force: force)
                    guard let self, acceptsBrowse(token, source: selected, context: context) else { return }
                    let covers = Dictionary(collections.compactMap { item in item.artworkURL.map { (item.id, $0) } },
                                            uniquingKeysWith: { first, _ in first })
                    collections = value.value.map { item in
                        var value = item
                        value.artworkURL = value.artworkURL ?? covers[value.id]
                        return value
                    }
                    collectionsUpdatedAt = value.updatedAt; isLoadingCollections = false
                } catch {
                    guard let self, acceptsBrowse(token, source: selected, context: context) else { return }
                    browseErrors["歌单"] = error.localizedDescription; isLoadingCollections = false
                }
            },
            Task { [weak self] in
                do {
                    let value = try await content.account(source: selected, context: context, force: force)
                    guard let self, acceptsBrowse(token, source: selected, context: context) else { return }
                    account = value.value; isLoadingAccount = false
                } catch {
                    guard let self, acceptsBrowse(token, source: selected, context: context) else { return }
                    if error as? OnlineError == .authenticationRequired { account = nil } else {
                        browseErrors["账号"] = error.localizedDescription
                    }
                    isLoadingAccount = false
                }
            }
        ]
    }

    private func acceptsBrowse(_ token: UUID, source: MusicSource, context: String) -> Bool {
        !Task.isCancelled && browseGeneration == token && self.source == source
            && activeContext == context && (try? content.context(for: source)) == context
    }

    func loadAccountContent(force: Bool = false) {
        let selected = source
        guard let context = try? content.context(for: selected) else { return }
        accountTask?.cancel()
        account = content.cached(OnlineAccount.self, source: selected, context: context, resource: "account")?.value
        browseErrors["账号"] = nil
        isLoadingAccount = true
        accountTask = Task { [weak self] in
            do {
                let value = try await self?.content.account(source: selected, context: context, force: force)
                guard !Task.isCancelled, let self, source == selected, (try? content.context(for: selected)) == context else { return }
                account = value?.value; isLoadingAccount = false
            } catch {
                guard !Task.isCancelled, let self, source == selected else { return }
                if error as? OnlineError == .authenticationRequired { account = nil } else { browseErrors["账号"] = error.localizedDescription }
                isLoadingAccount = false
            }
        }
    }

    func loadCollectionArtwork(_ collection: OnlineCollection) {
        guard collection.artworkURL == nil, artworkTasks[collection.id] == nil,
              let context = activeContext else { return }
        let token = browseGeneration
        let content = self.content
        artworkTasks[collection.id] = Task { [weak self] in
            let artwork: URL?
            do { artwork = try await content.artwork(collection, context: context) } catch {
                Log.net.error("歌单封面读取失败：\(collection.source.rawValue, privacy: .public)，\(error.localizedDescription, privacy: .public)")
                return
            }
            guard let artwork, let self, acceptsBrowse(token, source: collection.source, context: context),
                  let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
            collections[index].artworkURL = artwork
        }
    }

    func searchCatalog(query: String, category: CatalogCategory, page: Int) async throws -> [CatalogItem] {
        guard let client = clients[source] as? any OnlineCatalogClient else {
            throw OnlineError.unsupported("此平台只支持歌曲搜索")
        }
        return try await client.searchCatalog(query: query, category: category, page: page)
    }

    func artistSongs(_ item: CatalogItem) async throws -> [SongData] {
        guard let client = clients[item.source] as? any OnlineCatalogClient else { throw OnlineError.invalidResponse }
        return try await client.artistSongs(id: item.sourceID)
    }

    func songsForLink(_ link: RecognizedMusicLink) async throws -> [SongData] {
        if link.source == .bilibili, let client = clients[.bilibili] as? BilibiliClient {
            return try await client.pages(for: SongData(source: .bilibili, sourceID: link.id, title: link.id))
        }
        guard let client = clients[link.source] as? any OnlineCatalogClient else { throw OnlineError.invalidResponse }
        return try await client.linkedSong(id: link.id)
    }

    public func openCollection(id: String, kind: OnlineCollection.Kind) {
        let value = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 512 else { errorMessage = "请输入有效的歌单或专辑 ID"; return }
        selectCollection(OnlineCollection(source: source, sourceID: value, title: kind == .album ? "专辑" : "歌单", kind: kind))
    }

    public func selectCollection(_ collection: OnlineCollection, force: Bool = false) {
        detailTask?.cancel()
        detailTaskGeneration = UUID()
        let taskToken = detailTaskGeneration
        detailGeneration = UUID()
        let token = detailGeneration
        let sameCollection = selectedCollection?.id == collection.id
        selectedCollection = collection
        if !sameCollection { collectionSongs = [] }
        detailError = nil
        detailUpdatedAt = nil
        isDetailComplete = false
        let context: String
        do { context = try content.context(for: collection.source) } catch {
            detailError = error.localizedDescription
            isLoadingDetail = false
            return
        }
        if let value = content.cached(OnlineCollectionDetail.self, source: collection.source, context: context, resource: "detail:\(collection.id)") {
            selectedCollection = value.value.collection; collectionSongs = value.value.songs; detailUpdatedAt = value.updatedAt
            isDetailComplete = true
        }
        isLoadingDetail = true
        let content = self.content
        detailTask = Task { [weak self] in
            do {
                let value = try await content.detail(collection, context: context, force: force) { [weak self] songs in
                    guard let self, self.detailGeneration == token, self.detailTaskGeneration == taskToken,
                          self.detailUpdatedAt == nil,
                          (try? content.context(for: collection.source)) == context else { return }
                    self.collectionSongs = songs
                }
                guard !Task.isCancelled, let self, detailGeneration == token,
                      (try? content.context(for: collection.source)) == context else { return }
                selectedCollection = value.value.collection; collectionSongs = value.value.songs
                detailUpdatedAt = value.updatedAt
                isDetailComplete = true
                if let index = collections.firstIndex(where: { $0.id == collection.id }) {
                    collections[index] = value.value.collection
                }
                isLoadingDetail = false
            } catch {
                guard !Task.isCancelled, let self, detailGeneration == token,
                      (try? content.context(for: collection.source)) == context else { return }
                detailError = error.localizedDescription
                isLoadingDetail = false
            }
        }
    }

    public func clearDetail() {
        detailTask?.cancel()
        detailGeneration = UUID()
        detailTaskGeneration = UUID()
        selectedCollection = nil
        collectionSongs = []
        detailError = nil
        detailUpdatedAt = nil
        isDetailComplete = false
        isLoadingDetail = false
    }

    func refreshCurrentPage() {
        if let collection = selectedCollection { selectCollection(collection, force: true) } else {
            loadBrowseContent(force: true)
        }
    }

    public func play(_ song: SongData) {
        guard let store else { errorMessage = "播放器尚未就绪"; return }
        store.playTrack(song.track())
    }

    public func playCollection() {
        guard let store, isDetailComplete, !collectionSongs.isEmpty else { return }
        store.setQueue(collectionSongs.map { $0.track() })
    }

    public func enqueueNext(_ song: SongData) {
        guard let store else { errorMessage = "播放器尚未就绪"; return }
        store.enqueueNext(song.track())
    }

    public func beginQRLogin() {
        stopLogin()
        let token = loginGeneration
        let selected = source
        guard let client = clients[selected] else { loginMessage = "平台暂不可用"; return }
        isLoggingIn = true
        loginTask = Task { [weak self] in
            do {
                let ticket = try await client.beginQRLogin()
                guard !Task.isCancelled, let self, loginGeneration == token else { return }
                loginTicket = ticket
                loginState = .waiting
                for _ in 0..<90 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let state = try await client.pollQRLogin(ticket)
                    guard !Task.isCancelled, loginGeneration == token else { return }
                    loginState = state
                    if state == .authorized {
                        isLoggingIn = false
                        loadBrowseContent(force: true)
                        return
                    }
                    if state == .expired { isLoggingIn = false; return }
                }
                loginState = .expired
                isLoggingIn = false
            } catch {
                guard !Task.isCancelled, let self, loginGeneration == token else { return }
                loginMessage = error.localizedDescription
                loginState = nil
                loginTicket = nil
                isLoggingIn = false
            }
        }
    }

    public func stopLogin() {
        loginTask?.cancel()
        loginTask = nil
        loginGeneration = UUID()
        loginTicket = nil
        loginState = nil
        loginMessage = nil
        isLoggingIn = false
    }

    @discardableResult
    public func importCookies(_ text: String) -> Bool {
        guard supportsCookieImport else { return false }
        isImportingCookies = true
        defer { isImportingCookies = false }
        do {
            try sessions.saveCookieHeader(text, for: source)
            loginMessage = "Cookie 已导入"
            loadBrowseContent(force: true)
            return true
        } catch {
            loginMessage = error.localizedDescription
            return false
        }
    }

    public func signOut() {
        stopLogin()
        do {
            try sessions.clear(source)
            account = nil
            loadBrowseContent(force: true)
        } catch { errorMessage = error.localizedDescription }
    }

    public func setFavorite(_ song: SongData, favorite: Bool) {
        guard let client = clients[song.source] else { return }
        Task { [weak self] in
            do { try await client.setFavorite(song, favorite: favorite) } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    public func stop() {
        accountTask?.cancel()
        searchTask?.cancel(); browseTasks.forEach { $0.cancel() }; detailTask?.cancel(); stopLogin()
        artworkTasks.values.forEach { $0.cancel() }
        browseTasks = []; artworkTasks = [:]
        searchGeneration = UUID(); browseGeneration = UUID(); detailGeneration = UUID()
    }

    public func clearError() { errorMessage = nil }

}
