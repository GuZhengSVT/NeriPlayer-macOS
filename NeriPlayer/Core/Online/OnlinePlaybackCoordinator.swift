// OnlinePlaybackCoordinator.swift
// M5: cancellable queue resolution and bounded runtime refresh -> source switch -> skip.
import Combine
import Foundation

@MainActor
public final class OnlinePlaybackCoordinator: ObservableObject {
    public enum Phase: Equatable, Sendable { case idle, resolving, playing, failed, skipped }
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var currentSong: SongData?
    @Published public private(set) var currentResolvedAudio: ResolvedAudio?
    @Published public private(set) var lastError: String?
    private let store: PlaybackStateStore
    private let resolver: PlaybackResolver
    private let searchManager: OnlineSearchManager
    private let cache: PlaybackAudioCache?
    private var task: Task<Void, Never>?
    private var token: UUID?
    private var track: Track?
    private var paused = false
    private var alternatives: [SongData] = []
    private var excluded = Set<String>()
    private var refreshed = Set<String>()
    private var failureInFlight = false
    private var observation: Task<Void, Never>?

    init(store: PlaybackStateStore, resolver: PlaybackResolver, searchManager: OnlineSearchManager,
         cache: PlaybackAudioCache? = nil) {
        self.store = store; self.resolver = resolver; self.searchManager = searchManager; self.cache = cache
        store.setOnlineHandlers(load: { [weak self] track, token, paused in
            Task { @MainActor [weak self] in self?.begin(track, token: token, paused: paused) }
        }, failure: { [weak self] track, token, message in
            Task { @MainActor [weak self] in self?.failed(track, token: token, message: message) }
        })
        let stream = store.observeState()
        observation = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                let snapshot = store.snapshot
                let stale = token.flatMap { request in self.track.map { !store.isCurrentOnlineRequest(request, trackID: $0.id) } } ?? false
                if snapshot.currentTrack?.onlineSong == nil || stale {
                    task?.cancel(); token = nil
                    if let currentSong { Task { await cache?.unpin(currentSong) } }
                    currentSong = nil; currentResolvedAudio = nil; phase = .idle
                }
            }
        }
    }
    deinit { task?.cancel(); observation?.cancel() }
    public func play(_ song: SongData) { store.playTrack(song.track()) }
    public func setQueue(_ songs: [SongData], startIndex: Int = 0) { store.setQueue(songs.map { $0.track() }, startIndex: startIndex) }
    public func enqueueNext(_ song: SongData) { store.enqueueNext(song.track()) }

    private func begin(_ track: Track, token: UUID, paused: Bool) {
        guard let song = track.onlineSong, store.isCurrentOnlineRequest(token, trackID: track.id) else { return }
        if let previous = currentSong, previous.id != song.id { Task { await cache?.unpin(previous) } }
        task?.cancel()
        self.track = track; self.token = token; self.paused = paused
        excluded = []; refreshed = []; alternatives = []; failureInFlight = false
        currentSong = song; currentResolvedAudio = nil; lastError = nil; phase = .resolving
        task = Task { [weak self] in
            guard let self else { return }
            await resolveCurrent(song, token: token)
        }
    }
    private func valid(_ token: UUID) -> Bool {
        guard let track else { return false }
        return !Task.isCancelled && self.token == token && store.isCurrentOnlineRequest(token, trackID: track.id)
    }
    private func discover(_ song: SongData, token: UUID) async {
        let sources = MusicSource.allCases.filter { $0 != song.source }
        let query = [song.title, song.artist].filter { !$0.isEmpty }.joined(separator: " ")
        let result = await searchManager.search(query: query, sources: sources)
        guard valid(token) else { return }
        alternatives = result.results.map(\.song)
        // Multi-part Bilibili videos can contain the intended song outside P1.
        if let bili = resolver.clients.first(where: { $0.source == .bilibili }) as? BilibiliClient {
            for candidate in alternatives.filter({ $0.source == .bilibili }).prefix(3) {
                if let pages = try? await bili.pages(for: candidate), valid(token) { alternatives += pages }
            }
        }
    }
    private func resolveCurrent(_ song: SongData, token: UUID) async {
        do {
            // Try the original source before making cross-platform searches.
            var outcome = try await attempt(song, token: token)
            if case .skipped = outcome, valid(token), alternatives.isEmpty {
                await discover(song, token: token)
                outcome = try await attempt(song, token: token)
            }
            guard valid(token) else { return }
            switch outcome {
            case .resolved(let audio, _): currentResolvedAudio = audio; phase = .playing; failureInFlight = false
            case .skipped: phase = .skipped; lastError = "没有可用音源，已跳过当前歌曲"; store.skipFailedOnlineTrack(track?.id ?? UUID())
            }
        } catch is CancellationError { } catch {
            guard valid(token) else { return }
            lastError = error.localizedDescription; phase = .failed
            store.skipFailedOnlineTrack(track?.id ?? UUID())
        }
    }
    private func attempt(_ song: SongData, token: UUID) async throws -> PlaybackResolutionOutcome {
        let store = self.store
        guard let track else { throw CancellationError() }
        let paused = self.paused
        if let cache, let cachedURL = try? await cache.lookup(song) {
            await cache.pin(song)
            if try store.loadCachedAudio(cachedURL, for: track, requestID: token, paused: paused) {
                return .resolved(ResolvedAudio(song: song, url: cachedURL), attempts: [])
            }
        }
        return try await resolver.resolveAndLoad(song, candidates: alternatives, excluding: excluded, alreadyRefreshed: refreshed) { audio in
            try Task.checkCancellation()
            guard try store.loadResolvedAudio(audio, for: track, requestID: token, paused: paused) else { throw CancellationError() }
        }
    }
    private func failed(_ track: Track, token: UUID, message: String) {
        guard valid(token), !failureInFlight, let audio = currentResolvedAudio, let song = track.onlineSong else { return }
        failureInFlight = true; lastError = message; phase = .resolving
        let resumePosition = store.position
        paused = store.isPaused
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            if refreshed.insert(audio.song.id).inserted {
                do {
                    if let refreshedAudio = try await resolver.refresh(audio), valid(token) {
                        if try store.loadResolvedAudio(refreshedAudio, for: track, requestID: token, paused: paused, resumePosition: resumePosition) {
                            currentResolvedAudio = refreshedAudio; phase = .playing; failureInFlight = false
                            return
                        }
                    }
                } catch { if !valid(token) { return } }
            }
            excluded.insert(audio.song.id)
            if alternatives.isEmpty { await discover(song, token: token) }
            await resolveCurrent(song, token: token)
        }
    }
    public func stop() {
        task?.cancel(); task = nil; token = nil
        observation?.cancel(); observation = nil
        store.setOnlineHandlers(load: nil, failure: nil)
        if let currentSong { Task { await cache?.unpin(currentSong) } }
        currentSong = nil; currentResolvedAudio = nil; phase = .idle
    }
}
