// LyricsProvider.swift
// NeriPlayer macOS - local sidecar and explicit NetEase lyric sources.
//
// Source semantics intentionally mirror Android: local sidecars are authoritative,
// NetEase is opt-in by song id, and a blank/untimed document is not fabricated into
// a timed timeline. Network and disk errors remain visible to the composite caller.

import Foundation

/// A lookup request for the lyric sources.
public struct LyricsRequest: Sendable {
    public let track: Track
    /// A NetEase song id is deliberately explicit. Track metadata never implies a network lookup.
    public let neteaseSongID: String?

    public init(track: Track, neteaseSongID: String? = nil) {
        self.track = track
        self.neteaseSongID = neteaseSongID
    }
}

/// The source-neutral result consumed by playback and lyric UI.
public struct LyricsDocument: Sendable, Equatable {
    public let lyrics: SyncedLyrics
    /// Text lines are populated for both timed and plain documents. They never imply timing.
    public let plainLines: [String]
    /// Source-specific LRC offset metadata, in milliseconds.
    public let offsetMilliseconds: Int
    public let source: String
    /// Line-indexed phonetic text. The index is the index in `lyrics.lines`.
    public let phoneticByLine: [Int: String]

    public init(
        lyrics: SyncedLyrics = SyncedLyrics(),
        plainLines: [String] = [],
        offsetMilliseconds: Int = 0,
        source: String = "",
        phoneticByLine: [Int: String] = [:]
    ) {
        self.lyrics = lyrics
        self.plainLines = plainLines
        self.offsetMilliseconds = offsetMilliseconds
        self.source = source
        self.phoneticByLine = phoneticByLine
    }
}

public protocol LyricsProvider: Sendable {
    func lyrics(for request: LyricsRequest) async throws -> LyricsDocument?
}

public enum LyricsProviderError: Error, Equatable, Sendable {
    case fileTooLarge(URL, Int64)
    case unreadableFile(URL)
    case unsupportedEncoding(URL)
    case malformedLyrics(URL)
    case httpStatus(Int, URL)
    case invalidResponse(URL)
}

private struct NeteaseLyricField: Decodable {
    let lyric: String?
}

private struct NeteaseLyricPayload: Decodable {
    let lrc: NeteaseLyricField?
    let yrc: NeteaseLyricField?
    let tlyric: NeteaseLyricField?
    let ytlrc: NeteaseLyricField?
    let romalrc: NeteaseLyricField?
}

/// Reads sidecar files next to the track. No network access is performed here.
public struct LocalLyricsProvider: LyricsProvider {
    public static let defaultMaximumFileBytes: Int64 = 2 * 1024 * 1024

    public let maximumFileBytes: Int64

    public init(maximumFileBytes: Int64 = LocalLyricsProvider.defaultMaximumFileBytes) {
        self.maximumFileBytes = max(1, maximumFileBytes)
    }

    public func lyrics(for request: LyricsRequest) async throws -> LyricsDocument? {
        guard request.track.url.isFileURL else { return nil }
        let url = request.track.url
        let maximum = maximumFileBytes
        return try await Task.detached(priority: .utility) {
            try LocalLyricsProvider.readDocument(trackURL: url, maximumFileBytes: maximum)
        }.value
    }

    // Keep size, decoding, and format guards together to preserve sidecar precedence.
    // swiftlint:disable cyclomatic_complexity
    private static func readDocument(
        trackURL: URL,
        maximumFileBytes: Int64
    ) throws -> LyricsDocument? {
        let fileManager = FileManager.default
        let directory = trackURL.deletingLastPathComponent()
        let base = trackURL.deletingPathExtension().lastPathComponent
        // Keep this order in sync with AutoParser: richer formats win over plain LRC.
        let extensions = ["ttml", "yrc", "lrc", "txt"]
        var existing: [(URL, String)] = []
        for ext in extensions {
            let candidate = directory.appendingPathComponent(base).appendingPathExtension(ext)
            if fileManager.fileExists(atPath: candidate.path) {
                existing.append((candidate, ext))
            }
        }
        guard let (candidate, ext) = existing.first else {
            Log.db.debug("歌词 sidecar 不存在：\(trackURL.lastPathComponent, privacy: .public)")
            return nil
        }
        Log.db.info("读取歌词 sidecar：\(candidate.lastPathComponent, privacy: .public)")

        let attributes = try fileManager.attributesOfItem(atPath: candidate.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size >= 0 else { throw LyricsProviderError.unreadableFile(candidate) }
        guard size <= maximumFileBytes else {
            throw LyricsProviderError.fileTooLarge(candidate, size)
        }
        guard let data = try? Data(contentsOf: candidate, options: [.mappedIfSafe]) else {
            throw LyricsProviderError.unreadableFile(candidate)
        }
        guard Int64(data.count) <= maximumFileBytes else {
            throw LyricsProviderError.fileTooLarge(candidate, Int64(data.count))
        }
        guard let text = decode(data) else {
            throw LyricsProviderError.unsupportedEncoding(candidate)
        }

        if ext == "txt", LocalLyricsProvider.parseLyricsContent(text) == nil {
            let lines = nonEmptyLines(text)
            guard !lines.isEmpty else { return nil }
            return LyricsDocument(lyrics: SyncedLyrics(), plainLines: lines, source: "local")
        }

        guard let parsed = LocalLyricsProvider.parseLyricsContent(text) else {
            throw LyricsProviderError.malformedLyrics(candidate)
        }
        let offset = LrcMetadataHelper.parse(text.components(separatedBy: .newlines)).offset ?? 0
        let plainLines = parsed.lines.map(\.content).filter { !$0.isEmpty }
        let phonetics = LocalLyricsProvider.phoneticsByLine(parsed)
        return LyricsDocument(
            lyrics: parsed,
            plainLines: plainLines,
            offsetMilliseconds: offset,
            source: "local",
            phoneticByLine: phonetics
        )
    }

    // swiftlint:enable cyclomatic_complexity
    fileprivate static func parseLyricsContent(_ text: String) -> SyncedLyrics? {
        let parser = AutoParser()
        let parsed = parser.parse(text)
        if !parsed.lines.isEmpty { return parsed }
        let fallback = EnhancedLrcParser().parse(text)
        return fallback.lines.isEmpty ? nil : fallback
    }

    private static func nonEmptyLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func phoneticsByLine(_ lyrics: SyncedLyrics) -> [Int: String] {
        var result: [Int: String] = [:]
        for (index, line) in lyrics.lines.enumerated() {
            guard let phonetic = line.karaokeLine?.phonetic?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !phonetic.isEmpty else { continue }
            result[index] = phonetic
        }
        return result
    }

    private static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4))
        let encoding: String.Encoding?
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8
        } else if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            encoding = .utf32LittleEndian
        } else if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            encoding = .utf32BigEndian
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
        } else if data.contains(0) {
            // BOM-less UTF-16/32 is only attempted when NUL bytes make it plausible.
            encoding = data.count.isMultiple(of: 4) ? .utf16LittleEndian : .utf16LittleEndian
        } else {
            encoding = .utf8
        }
        if let encoding, let value = String(data: data, encoding: encoding) {
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        }
        return String(data: data, encoding: String.Encoding(rawValue: 2147483673))
    }
}

/// NetEase's public lyric endpoint. The song id must be explicitly supplied by the caller.
public struct NeteaseLyricsProvider: LyricsProvider {
    public let session: URLSession
    public let endpoint: URL

    public init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://music.163.com/api/song/lyric") ?? URL(fileURLWithPath: "/")
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    public func lyrics(for request: LyricsRequest) async throws -> LyricsDocument? {
        guard let rawID = request.neteaseSongID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawID.isEmpty,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "id", value: rawID),
            URLQueryItem(name: "lv", value: "-1"),
            URLQueryItem(name: "tv", value: "-1"),
            URLQueryItem(name: "rv", value: "-1"),
            URLQueryItem(name: "yv", value: "-1"),
            URLQueryItem(name: "ytv", value: "-1"),
            URLQueryItem(name: "yrv", value: "-1")
        ]
        guard let url = components.url else { return nil }
        Log.net.info("请求网易云歌词：songID=\(rawID, privacy: .private(mask: .hash))")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("NeriPlayer/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LyricsProviderError.invalidResponse(url)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LyricsProviderError.httpStatus(http.statusCode, url)
        }
        guard let payload = try? JSONDecoder().decode(NeteaseLyricPayload.self, from: data) else {
            throw LyricsProviderError.invalidResponse(url)
        }

        let candidates = [payload.yrc?.lyric, payload.lrc?.lyric]
            .compactMap(Self.firstNonBlank)
            .compactMap { raw in Self.parse(raw).map { (raw: raw, lyrics: $0) } }
        guard let selected = candidates.first else { return nil }
        let selectedOriginal = selected.raw
        let original = selected.lyrics
        let translated = Self.firstNonBlank(payload.ytlrc?.lyric).flatMap(Self.parse)
            ?? Self.firstNonBlank(payload.tlyric?.lyric).flatMap(Self.parse)
        let romanized = Self.firstNonBlank(payload.romalrc?.lyric).flatMap(Self.parse)
        let merged = Self.merge(original: original, translated: translated)
        let phonetics = Self.phoneticsByLine(original: merged, romanized: romanized)
        let offset = LrcMetadataHelper.parse(selectedOriginal.components(separatedBy: .newlines)).offset ?? 0
        return LyricsDocument(
            lyrics: merged,
            plainLines: merged.lines.map(\.content).filter { !$0.isEmpty },
            offsetMilliseconds: offset,
            source: "netease",
            phoneticByLine: phonetics
        )
    }

    private static func firstNonBlank(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
    }

    private static func parse(_ text: String) -> SyncedLyrics? {
        LocalLyricsProvider.parseLyricsContent(text)
    }

    private static func merge(original: SyncedLyrics, translated: SyncedLyrics?) -> SyncedLyrics {
        guard let translated else { return original }
        let merged = original.lines.map { line -> LyricsLine in
            guard let candidate = nearestLine(to: line, in: translated.lines),
                  safeDistance(candidate.start, line.start) <= matchTolerance(for: line) else { return line }
            return line.withTranslation(candidate.content)
        }
        return SyncedLyrics(lines: merged, title: original.title, id: original.id, artists: original.artists)
    }

    private static func phoneticsByLine(original: SyncedLyrics, romanized: SyncedLyrics?) -> [Int: String] {
        guard let romanized else { return [:] }
        var result: [Int: String] = [:]
        for (index, line) in original.lines.enumerated() {
            guard let candidate = nearestLine(to: line, in: romanized.lines),
                  safeDistance(candidate.start, line.start) <= matchTolerance(for: line),
                  !candidate.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result[index] = candidate.content
        }
        return result
    }

    private static func nearestLine(to line: LyricsLine, in candidates: [LyricsLine]) -> LyricsLine? {
        candidates.min { lhs, rhs in
            safeDistance(lhs.start, line.start) < safeDistance(rhs.start, line.start)
        }
    }

    private static func safeDistance(_ lhs: Int, _ rhs: Int) -> Int {
        LyricsTime.subtracting(max(lhs, rhs), min(lhs, rhs))
    }

    private static func matchTolerance(for line: LyricsLine) -> Int {
        max(3_000, line.duration / 2)
    }
}

/// Local sidecars take precedence. Remote lookup is attempted only with an explicit id.
public struct CompositeLyricsProvider: LyricsProvider {
    public let local: any LyricsProvider
    public let remote: any LyricsProvider

    public init(
        local: any LyricsProvider = LocalLyricsProvider(),
        remote: any LyricsProvider = NeteaseLyricsProvider()
    ) {
        self.local = local
        self.remote = remote
    }

    public func lyrics(for request: LyricsRequest) async throws -> LyricsDocument? {
        var localError: Error?
        do {
            if let document = try await local.lyrics(for: request) { return document }
        } catch {
            localError = error
        }
        guard request.neteaseSongID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            if let localError { throw localError }
            return nil
        }
        do {
            if let document = try await remote.lyrics(for: request) { return document }
        } catch {
            if let localError { throw localError }
            throw error
        }
        if let localError { throw localError }
        return nil
    }
}
