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
    private let qualityProvider: AudioQualityProvider
    private var cachePin: UUID?
    private var task: Task<Void, Never>?
    private var token: UUID?
    private var track: Track?
    private var paused = false
    private var alternatives: [SongData] = []
    private var discoveredSources = Set<MusicSource>()
    private var excluded = Set<String>()
    private var refreshed = Set<String>()
    private var failureInFlight = false
    private var observation: Task<Void, Never>?

    init(store: PlaybackStateStore, resolver: PlaybackResolver, searchManager: OnlineSearchManager,
         cache: PlaybackAudioCache? = nil, quality: AudioQualityProvider = .settings) {
        self.store = store; self.resolver = resolver; self.searchManager = searchManager; self.cache = cache
        self.qualityProvider = quality
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
                    releaseCachePin()
                    currentSong = nil; currentResolvedAudio = nil; phase = .idle
                }
            }
        }
    }
    deinit {
        task?.cancel(); observation?.cancel()
        if let cachePin, let cache { Task { await cache.releasePin(cachePin) } }
    }
    public func play(_ song: SongData) { store.playTrack(song.track()) }
    public func setQueue(_ songs: [SongData], startIndex: Int = 0) { store.setQueue(songs.map { $0.track() }, startIndex: startIndex) }
    public func enqueueNext(_ song: SongData) { store.enqueueNext(song.track()) }

    private func begin(_ track: Track, token: UUID, paused: Bool) {
        guard let song = track.onlineSong, store.isCurrentOnlineRequest(token, trackID: track.id) else { return }
        releaseCachePin()
        task?.cancel()
        self.track = track; self.token = token; self.paused = paused
        excluded = []; refreshed = []; alternatives = []; failureInFlight = false
        discoveredSources = []
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
    @discardableResult
    private func discover(_ song: SongData, token: UUID) async -> Bool {
        let remaining = MusicSource.allCases.filter { $0 != song.source && !discoveredSources.contains($0) }
        let sources: [MusicSource]
        if song.source == .netease {
            // 分阶段搜索：Bilibili 不可用后才发起 YouTube 请求，避免慢源阻塞首选源。
            sources = [.bilibili, .youtubeMusic].filter { remaining.contains($0) }.prefix(1).map { $0 }
        } else {
            sources = remaining
        }
        guard !sources.isEmpty, valid(token) else { return false }
        discoveredSources.formUnion(sources)
        let query = [song.title, song.artist].filter { !$0.isEmpty }.joined(separator: " ")
        let result = await searchManager.search(query: query, sources: sources)
        guard valid(token) else { return false }
        let discovered = result.results.map(\.song)
        alternatives += discovered
        // Multi-part Bilibili videos can contain the intended song outside P1.
        if let bili = resolver.clients.first(where: { $0.source == .bilibili }) as? BilibiliClient {
            for candidate in discovered.filter({ $0.source == .bilibili }).prefix(3) {
                if let pages = try? await bili.pages(for: candidate), valid(token) { alternatives += pages }
            }
        }
        return valid(token)
    }
    private func resolveCurrent(_ song: SongData, token: UUID, resumePosition: Double? = nil) async {
        do {
            // Try the original source before making cross-platform searches.
            var outcome = try await attempt(song, token: token, resumePosition: resumePosition)
            while case .skipped(_, let attempts) = outcome, valid(token) {
                excluded.formUnion(attempts.map(\.songID))
                guard await discover(song, token: token) else { break }
                outcome = try await attempt(song, token: token, resumePosition: resumePosition)
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
    private func attempt(_ song: SongData, token: UUID, resumePosition: Double?) async throws -> PlaybackResolutionOutcome {
        guard let track else { throw CancellationError() }
        var attempts: [PlaybackResolutionAttempt] = []
        // Preserve resolver order: the original source gets its cache/resolve attempt before alternatives.
        for candidate in resolver.candidates(for: song, from: alternatives, excluding: excluded) {
            guard valid(token) else { throw CancellationError() }
            if let cache {
                let pin = await cache.acquirePin(candidate.song)
                do {
                    let quality = qualityProvider.preferences().cacheQuality(for: candidate.song.source)
                    if let cached = try await cache.lookupAudio(candidate.song, quality: quality) {
                        guard valid(token) else { throw CancellationError() }
                        let loadPaused = resumePosition == nil ? paused : store.isPaused
                        if try store.loadCachedAudio(cached.url, for: track, requestID: token, paused: loadPaused,
                                                     resumePosition: resumePosition) {
                            replaceCachePin(pin)
                            return .resolved(cached, attempts: attempts)
                        }
                        throw CancellationError()
                    }
                } catch {
                    await cache.releasePin(pin)
                    if error is CancellationError || !valid(token) { throw CancellationError() }
                    // A corrupt/unreadable cache falls through to the network candidate.
                }
                await cache.releasePin(pin)
            }
            let outcome = try await resolver.resolveAndLoad(candidate.song, alreadyRefreshed: refreshed) { [weak self] audio in
                guard let self else { throw CancellationError() }
                try await self.loadAudio(audio, for: track, token: token, resumePosition: resumePosition)
            }
            switch outcome {
            case .resolved(let audio, let candidateAttempts): return .resolved(audio, attempts: attempts + candidateAttempts)
            case .skipped(_, let candidateAttempts): attempts += candidateAttempts
            }
        }
        return .skipped(song: song, attempts: attempts)
    }
    private func loadAudio(_ audio: ResolvedAudio, for track: Track, token: UUID, resumePosition: Double?) async throws {
        let pin = await cache?.acquirePin(audio.song)
        do {
            guard valid(token) else { throw CancellationError() }
            let loadPaused = resumePosition == nil ? paused : store.isPaused
            guard try store.loadResolvedAudio(audio, for: track, requestID: token, paused: loadPaused,
                                              resumePosition: resumePosition) else { throw CancellationError() }
            replaceCachePin(pin)
        } catch {
            if let pin { await cache?.releasePin(pin) }
            throw error
        }
    }
    private func replaceCachePin(_ pin: UUID?) {
        releaseCachePin(); cachePin = pin
    }
    private func releaseCachePin() {
        if let pin = cachePin { Task { await cache?.releasePin(pin) } }
        cachePin = nil
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
                        try await loadAudio(refreshedAudio, for: track, token: token, resumePosition: resumePosition)
                        guard valid(token) else { return }
                        currentResolvedAudio = refreshedAudio; phase = .playing; failureInFlight = false
                        return
                    }
                } catch { if !valid(token) { return } }
            }
            excluded.insert(audio.song.id)
            guard valid(token) else { return }
            await resolveCurrent(song, token: token, resumePosition: resumePosition)
        }
    }
    public func stop() {
        task?.cancel(); task = nil; token = nil
        observation?.cancel(); observation = nil
        store.setOnlineHandlers(load: nil, failure: nil)
        releaseCachePin()
        currentSong = nil; currentResolvedAudio = nil; phase = .idle
    }
}
