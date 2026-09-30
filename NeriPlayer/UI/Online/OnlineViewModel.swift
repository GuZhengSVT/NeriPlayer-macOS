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

    private let manager: OnlineSearchManager
    private let clients: [MusicSource: any OnlineMusicClient]
    private let sessions: OnlineSessionStore
    private var store: PlaybackStateStore?
    private var searchTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var browseGeneration = UUID()
    private var detailGeneration = UUID()
    private var loginGeneration = UUID()
    private var loadedSources = Set<MusicSource>()

    public init(clients: [any OnlineMusicClient], sessions: OnlineSessionStore = .shared, store: PlaybackStateStore? = nil) {
        var indexed: [MusicSource: any OnlineMusicClient] = [:]
        for client in clients { indexed[client.source] = client }
        self.clients = indexed
        manager = OnlineSearchManager(clients: clients)
        self.sessions = sessions
        self.store = store
    }

    deinit {
        searchTask?.cancel()
        browseTask?.cancel()
        detailTask?.cancel()
        loginTask?.cancel()
    }

    public var isSearchMode: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var canPlay: Bool { store != nil }
    public var supportsQR: Bool { source != .youtubeMusic }
    public var supportsCookieImport: Bool { source == .youtubeMusic || source == .bilibili }

    public func attachPlaybackStore(_ store: PlaybackStateStore?) { self.store = store }

    public func setSource(_ value: MusicSource) {
        guard source != value else { return }
        stopLogin()
        source = value
        results = []
        partialErrors = [:]
        errorMessage = nil
        clearDetail()
        loadBrowseContent(force: true)
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

    public func loadBrowseContent(force: Bool = false) {
        guard force || !loadedSources.contains(source) else { return }
        browseTask?.cancel()
        browseGeneration = UUID()
        let token = browseGeneration
        let selected = source
        recommendations = []
        collections = []
        browseErrors = [:]
        account = nil
        guard let client = clients[selected] else {
            browseErrors["平台"] = "\(selected.title)暂不可用"
            return
        }
        isLoadingRecommendations = true
        isLoadingCollections = true
        browseTask = Task { [weak self] in
            async let recommendationResult = Self.capture { try await client.recommendations() }
            async let collectionResult = Self.capture { try await client.collections() }
            async let accountResult = Self.capture { try await client.account() }
            let values = await (recommendationResult, collectionResult, accountResult)
            guard !Task.isCancelled, let self, browseGeneration == token, source == selected else { return }
            isLoadingRecommendations = false
            isLoadingCollections = false
            loadedSources.insert(selected)
            switch values.0 {
            case .success(let songs): recommendations = songs
            case .failure(let error): browseErrors["推荐"] = error.localizedDescription
            }
            switch values.1 {
            case .success(let lists): collections = lists
            case .failure(let error): browseErrors["歌单"] = error.localizedDescription
            }
            if case .success(let value) = values.2 { account = value }
        }
    }

    public func openCollection(id: String, kind: OnlineCollection.Kind) {
        let value = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 512 else { errorMessage = "请输入有效的歌单或专辑 ID"; return }
        selectCollection(OnlineCollection(source: source, sourceID: value, title: kind == .album ? "专辑" : "歌单", kind: kind))
    }

    public func selectCollection(_ collection: OnlineCollection) {
        detailTask?.cancel()
        detailGeneration = UUID()
        let token = detailGeneration
        selectedCollection = collection
        collectionSongs = []
        detailError = nil
        guard let client = clients[collection.source] else { detailError = "平台暂不可用"; return }
        isLoadingDetail = true
        detailTask = Task { [weak self] in
            do {
                let songs = try await client.songs(in: collection)
                guard !Task.isCancelled, let self, detailGeneration == token else { return }
                collectionSongs = songs
                isLoadingDetail = false
            } catch {
                guard !Task.isCancelled, let self, detailGeneration == token else { return }
                detailError = error.localizedDescription
                isLoadingDetail = false
            }
        }
    }

    public func clearDetail() {
        detailTask?.cancel()
        detailGeneration = UUID()
        selectedCollection = nil
        collectionSongs = []
        detailError = nil
        isLoadingDetail = false
    }

    public func play(_ song: SongData) {
        guard let store else { errorMessage = "播放器尚未就绪"; return }
        store.playTrack(song.track())
    }

    public func playCollection() {
        guard let store, !collectionSongs.isEmpty else { return }
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
            loadedSources.remove(source)
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
        searchTask?.cancel(); browseTask?.cancel(); detailTask?.cancel(); stopLogin()
        searchGeneration = UUID(); browseGeneration = UUID(); detailGeneration = UUID()
    }

    public func clearError() { errorMessage = nil }

    private static func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
}
