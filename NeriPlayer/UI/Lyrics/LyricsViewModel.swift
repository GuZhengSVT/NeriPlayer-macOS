// LyricsViewModel.swift
// M4: playback adapter, cancellable lyric loading and persistent preferences.
import Combine
import Foundation

@MainActor
final class LyricsViewModel: ObservableObject {
    @Published private(set) var snapshot: PlaybackSnapshot?
    @Published private(set) var document: LyricsDocument?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var fontSize: Double
    @Published private(set) var blur: Bool
    @Published private(set) var showTranslation: Bool
    @Published private(set) var showPhonetic: Bool
    @Published private(set) var offsetMilliseconds = 0
    @Published private(set) var neteaseSongID = ""
    private(set) var timeline = LyricsTimeline(lyrics: SyncedLyrics())
    private let provider: any LyricsProvider
    private let settings: SettingsStore
    private var store: PlaybackStateStore?
    private var observation: Task<Void, Never>?
    private var loading: Task<Void, Never>?
    private var generation = UUID()
    private var receivedAt = Date()

    init(provider: any LyricsProvider = CompositeLyricsProvider(), settings: SettingsStore = .shared) {
        self.provider = provider
        self.settings = settings
        fontSize = Self.clampedFont(settings.value(for: SettingsKeys.lyricsFontSize))
        blur = settings.value(for: SettingsKeys.lyricsBlur)
        showTranslation = settings.value(for: SettingsKeys.lyricsTranslation)
        showPhonetic = settings.value(for: SettingsKeys.lyricsPhonetic)
    }

    deinit {
        observation?.cancel()
        loading?.cancel()
    }

    func attach(to store: PlaybackStateStore) {
        guard self.store !== store else { return }
        observation?.cancel()
        self.store = store
        accept(store.snapshot)
        let stream = store.observeState()
        observation = Task { [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                self?.accept(snapshot)
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        loading?.cancel()
        loading = nil
        generation = UUID()
        store = nil
        snapshot = nil
        document = nil
        timeline = LyricsTimeline(lyrics: SyncedLyrics())
        isLoading = false
    }

    func accept(_ next: PlaybackSnapshot) {
        let changed = snapshot?.currentTrack?.url != next.currentTrack?.url
            || snapshot?.currentTrack?.id != next.currentTrack?.id
        snapshot = next
        receivedAt = Date()
        if changed {
            let key = next.currentTrack?.url.absoluteString ?? ""
            offsetMilliseconds = min(60_000, max(-60_000, readMap(Int.self, key: SettingsKeys.lyricsOffsets)[key] ?? 0))
            let song = next.currentTrack?.onlineSong
            let sourceID = song?.source == .netease ? song?.sourceID : nil
            neteaseSongID = readMap(String.self, key: SettingsKeys.lyricsAssociations)[key] ?? sourceID ?? ""
            reload()
        }
    }

    func reload() {
        loading?.cancel()
        let token = UUID()
        generation = token
        document = nil
        timeline = LyricsTimeline(lyrics: SyncedLyrics())
        errorMessage = nil
        guard let track = snapshot?.currentTrack else { isLoading = false; return }
        isLoading = true
        let request = LyricsRequest(track: track, neteaseSongID: neteaseSongID.isEmpty ? nil : neteaseSongID)
        let provider = self.provider
        loading = Task { [weak self] in
            do {
                let document = try await provider.lyrics(for: request)
                guard !Task.isCancelled, let self, generation == token else { return }
                self.document = document
                timeline = LyricsTimeline(lyrics: document?.lyrics ?? SyncedLyrics())
                if let document { Log.ui.info("歌词已加载：来源=\(document.source, privacy: .public)，行数=\(document.lyrics.lines.count)") }
                isLoading = false
            } catch {
                guard !Task.isCancelled, let self, generation == token else { return }
                errorMessage = error.localizedDescription
                Log.ui.error("歌词加载失败：\(error.localizedDescription, privacy: .public)")
                isLoading = false
            }
        }
    }

    var totalOffset: Int { LyricsTime.adding(offsetMilliseconds, document?.offsetMilliseconds ?? 0) }

    func playbackSeconds(at date: Date? = nil) -> Double {
        guard let snapshot else { return 0 }
        let elapsed = date.map { min(0.3, max(0, $0.timeIntervalSince(receivedAt))) } ?? 0
        let position = snapshot.position.isFinite ? max(0, snapshot.position) : 0
        return position + (snapshot.isPaused || snapshot.isCoreIdle ? 0 : elapsed)
    }

    func seek(to line: LyricsLine) {
        seek(to: LyricsTimeline.seekSeconds(for: line, offsetMilliseconds: totalOffset))
    }

    func seek(to seconds: Double) {
        guard let store, store.hasLoadedFile, seconds.isFinite else { return }
        store.seek(to: min(max(0, seconds), max(0, store.duration)))
        accept(store.snapshot)
    }
    func togglePlayback() { store?.togglePlayPause() }
    func next() { store?.next(force: true) }
    func previous() { store?.previous() }

    @discardableResult
    func associate(songID: String) -> Bool {
        let value = songID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || (value.allSatisfy { $0.isASCII && $0.isNumber } && Int64(value).map { $0 > 0 } == true) else {
            errorMessage = "请输入有效的网易云歌曲 ID"
            return false
        }
        guard let track = snapshot?.currentTrack else { return false }
        var map = readMap(String.self, key: SettingsKeys.lyricsAssociations)
        map[track.url.absoluteString] = value.isEmpty ? nil : value
        saveMap(map, key: SettingsKeys.lyricsAssociations)
        neteaseSongID = value
        reload()
        return true
    }

    func setOffset(_ value: Int) {
        offsetMilliseconds = min(60_000, max(-60_000, value))
        guard let track = snapshot?.currentTrack else { return }
        var map = readMap(Int.self, key: SettingsKeys.lyricsOffsets)
        map[track.url.absoluteString] = offsetMilliseconds
        saveMap(map, key: SettingsKeys.lyricsOffsets)
    }

    func setFontSize(_ value: Double) {
        fontSize = Self.clampedFont(value)
        settings.set(fontSize, for: SettingsKeys.lyricsFontSize)
    }

    func setBlur(_ value: Bool) { blur = value; settings.set(value, for: SettingsKeys.lyricsBlur) }
    func setTranslation(_ value: Bool) { showTranslation = value; settings.set(value, for: SettingsKeys.lyricsTranslation) }
    func setPhonetic(_ value: Bool) { showPhonetic = value; settings.set(value, for: SettingsKeys.lyricsPhonetic) }

    private static func clampedFont(_ value: Double) -> Double { value.isFinite ? min(44, max(16, value)) : 28 }

    private func readMap<T: Decodable>(_ type: T.Type, key: SettingsKey<Data>) -> [String: T] {
        (try? JSONDecoder().decode([String: T].self, from: settings.value(for: key))) ?? [:]
    }

    private func saveMap<T: Encodable>(_ map: [String: T], key: SettingsKey<Data>) {
        if let data = try? JSONEncoder().encode(map) { settings.set(data, for: key) }
    }
}
