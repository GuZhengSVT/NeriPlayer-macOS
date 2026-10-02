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
    /// 歌词字体家族标识（需求 5）。与外观页的「歌词字体」是同一个设置值。
    @Published private(set) var fontFamily: String
    /// 底部歌词字号（需求 5）。悬浮歌词这类单行紧凑展示用它。
    @Published private(set) var compactFontSize: Double
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
    /// 设置变更订阅（需求 5）：外观页改歌词字号 / 字体时，歌词窗口不必重开就能跟上。
    private var preferencesObservation: Task<Void, Never>?
    private var loading: Task<Void, Never>?
    private var generation = UUID()
    private var receivedAt = Date()

    init(provider: any LyricsProvider = CompositeLyricsProvider(), settings: SettingsStore = .shared) {
        self.provider = provider
        self.settings = settings
        fontSize = Self.clampedFont(settings.value(for: SettingsKeys.lyricsFontSize))
        fontFamily = settings.value(for: SettingsKeys.lyricsFontFamily)
        compactFontSize = Self.clampedCompactFont(settings.value(for: SettingsKeys.compactLyricsFontSize))
        blur = settings.value(for: SettingsKeys.lyricsBlur)
        showTranslation = settings.value(for: SettingsKeys.lyricsTranslation)
        showPhonetic = settings.value(for: SettingsKeys.lyricsPhonetic)
        observeSharedPreferences()
    }

    deinit {
        observation?.cancel()
        preferencesObservation?.cancel()
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

    var currentLyricText: String {
        guard let document, !document.lyrics.lines.isEmpty else { return "暂无歌词" }
        let state = timeline.state(at: playbackSeconds(), offsetMilliseconds: totalOffset)
        if let index = state.focusedLineIndices.first, document.lyrics.lines.indices.contains(index) {
            return document.lyrics.lines[index].content
        }
        return document.lyrics.lines.first(where: { $0.start >= state.timeMilliseconds })?.content
            ?? document.lyrics.lines.last?.content ?? "暂无歌词"
    }

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
        let clamped = Self.clampedFont(value)
        guard clamped != fontSize else { return }
        fontSize = clamped
        settings.set(fontSize, for: SettingsKeys.lyricsFontSize)
    }

    /// 设置歌词字体。未知家族夹回系统字体后再落盘，与外观页的写入路径同一套规则。
    func setFontFamily(_ value: String) {
        let resolved = TypographyFontFamily.resolved(value, available: Set(TypographyFontFamily.availableFamilies()))
        guard resolved != fontFamily else { return }
        fontFamily = resolved
        settings.set(resolved, for: SettingsKeys.lyricsFontFamily)
    }

    /// 订阅本类也持有的两个设置键，处理「别处改、本对象不知道」的情况。
    ///
    /// 为什么需要：设置页的「外观与个性化 → 歌词字号」直接写 SettingsStore，
    /// 不经过本对象；若这里不订阅，歌词窗口会继续用旧字号，直到重开窗口。
    /// 只在值真的不同时写入属性，避免把「自己刚写出去的值」再回灌成一次多余的重绘。
    private func observeSharedPreferences() {
        let stream = settings.changes()
        preferencesObservation = Task { [weak self] in
            for await change in stream {
                guard !Task.isCancelled, let self else { return }
                switch change.key {
                case SettingsKeys.lyricsFontSize.name:
                    let value = Self.clampedFont(self.settings.value(for: SettingsKeys.lyricsFontSize))
                    if value != self.fontSize { self.fontSize = value }
                case SettingsKeys.lyricsFontFamily.name:
                    let value = self.settings.value(for: SettingsKeys.lyricsFontFamily)
                    if value != self.fontFamily { self.fontFamily = value }
                case SettingsKeys.compactLyricsFontSize.name:
                    let value = Self.clampedCompactFont(self.settings.value(for: SettingsKeys.compactLyricsFontSize))
                    if value != self.compactFontSize { self.compactFontSize = value }
                default:
                    break
                }
            }
        }
    }

    func setBlur(_ value: Bool) { blur = value; settings.set(value, for: SettingsKeys.lyricsBlur) }
    func setTranslation(_ value: Bool) { showTranslation = value; settings.set(value, for: SettingsKeys.lyricsTranslation) }
    func setPhonetic(_ value: Bool) { showPhonetic = value; settings.set(value, for: SettingsKeys.lyricsPhonetic) }

    private static func clampedFont(_ value: Double) -> Double { value.isFinite ? min(44, max(16, value)) : 28 }

    /// 底部歌词字号的夹取范围与默认值。与 `AppTypographyDefaults` 一致，
    /// 这里再夹一次是为了让「直接读 UserDefaults 的异常值」也不会把 NaN 传进字体构造。
    private static func clampedCompactFont(_ value: Double) -> Double {
        AppTypographyDefaults.clamped(value, in: AppTypographyDefaults.compactLyricsSizeRange,
                                      fallback: AppTypographyDefaults.compactLyricsSize)
    }

    private func readMap<T: Decodable>(_ type: T.Type, key: SettingsKey<Data>) -> [String: T] {
        (try? JSONDecoder().decode([String: T].self, from: settings.value(for: key))) ?? [:]
    }

    private func saveMap<T: Encodable>(_ map: [String: T], key: SettingsKey<Data>) {
        if let data = try? JSONEncoder().encode(map) { settings.set(data, for: key) }
    }
}
