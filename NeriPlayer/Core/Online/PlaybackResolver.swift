// PlaybackResolver.swift
// M5-T5/T8: conservative song matching and bounded resolution/URL-refresh fallback.
import Foundation

/// Optional capability; clients without refresh support simply move to the next candidate.
public protocol OnlineURLRefreshingClient: OnlineMusicClient {
    func refresh(song: SongData, previous: ResolvedAudio?) async throws -> ResolvedAudio
}

/// Separate from the local-file API, so adding online playback does not weaken load(url:).
public protocol ResolvedAudioPlayerEngine: PlayerEngine {
    func loadResolvedAudio(_ audio: ResolvedAudio, paused: Bool) throws
}

public struct PlaybackCandidateScore: Equatable, Sendable {
    public let title: Int
    public let artist: Int
    public let duration: Int
    public var total: Int { title + artist + duration }
    public init(title: Int, artist: Int, duration: Int) {
        self.title = title
        self.artist = artist
        self.duration = duration
    }
}

public struct PlaybackCandidate: Equatable, Sendable {
    public let song: SongData
    public let score: PlaybackCandidateScore
    public init(song: SongData, score: PlaybackCandidateScore) { self.song = song; self.score = score }
}

public struct PlaybackResolutionAttempt: Equatable, Sendable {
    public enum Stage: String, Sendable { case resolve, refresh, load }
    public let songID: String
    public let stage: Stage
    public let message: String
    public init(songID: String, stage: Stage, message: String) {
        self.songID = songID; self.stage = stage; self.message = message
    }
}

public enum PlaybackResolutionOutcome: Equatable, Sendable {
    case resolved(ResolvedAudio, attempts: [PlaybackResolutionAttempt])
    case skipped(song: SongData, attempts: [PlaybackResolutionAttempt])
}

public enum OnlineResolutionError: LocalizedError, Sendable {
    case expiredURL
    case invalidURL
    public var errorDescription: String? {
        switch self {
        case .expiredURL: return "音源地址已过期"
        case .invalidURL: return "音源地址无效"
        }
    }
}

public struct PlaybackResolver: Sendable {
    public let clients: [any OnlineMusicClient]
    public let minimumFallbackScore: Int
    public let durationTolerance: Double

    public init(clients: [any OnlineMusicClient], minimumFallbackScore: Int = 70, durationTolerance: Double = 15) {
        self.clients = clients
        self.minimumFallbackScore = max(0, minimumFallbackScore)
        self.durationTolerance = durationTolerance.isFinite ? max(3, durationTolerance) : 15
    }

    /// The requested platform identity always comes first. Only plausible alternatives follow.
    public func candidates(for song: SongData, from alternatives: [SongData], excluding: Set<String> = []) -> [PlaybackCandidate] {
        var seen = excluding
        var result: [PlaybackCandidate] = []
        if seen.insert(song.id).inserted { result.append(PlaybackCandidate(song: song, score: Self.score(reference: song, candidate: song))) }
        var fallback: [PlaybackCandidate] = []
        for candidate in alternatives {
            guard seen.insert(candidate.id).inserted else { continue }
            let score = Self.score(reference: song, candidate: candidate)
            guard score.title >= 18, score.total >= minimumFallbackScore else { continue }
            if let expected = validDuration(song.duration), let actual = validDuration(candidate.duration),
               Swift.abs(expected - actual) > durationTolerance { continue }
            fallback.append(PlaybackCandidate(song: candidate, score: score))
        }
        fallback.sort {
            // 需求 6：网易云不可播放时，先在 Bilibili 找同曲，再考虑 YouTube Music ——
            // 不能只按匹配度排，否则 YouTube 的高分候选会抢在 Bilibili 前面。
            // 同平台内仍然按匹配度排序，原有评分/时长过滤不受影响。
            if song.source == .netease {
                let leftPriority = $0.song.source == .bilibili ? 0 : 1
                let rightPriority = $1.song.source == .bilibili ? 0 : 1
                if leftPriority != rightPriority { return leftPriority < rightPriority }
            }
            if $0.score.total != $1.score.total { return $0.score.total > $1.score.total }
            return $0.song.id < $1.song.id
        }
        result.append(contentsOf: fallback)
        return result
    }

    public func resolve(_ song: SongData, candidates alternatives: [SongData] = []) async throws -> PlaybackResolutionOutcome {
        try await resolveAndLoad(song, candidates: alternatives) { _ in }
    }

    /// Loading is part of the chain: synchronous backend failures can trigger refresh/fallback too.
    public func resolveAndLoad(
        _ song: SongData, candidates alternatives: [SongData] = [], excluding: Set<String> = [],
        alreadyRefreshed: Set<String> = [], load: @escaping @Sendable (ResolvedAudio) async throws -> Void
    ) async throws -> PlaybackResolutionOutcome {
        var attempts: [PlaybackResolutionAttempt] = []
        for candidate in candidates(for: song, from: alternatives, excluding: excluding) {
            try Task.checkCancellation()
            guard let client = clients.first(where: { $0.source == candidate.song.source }) else {
                attempts.append(PlaybackResolutionAttempt(songID: candidate.song.id, stage: .resolve, message: "音源未配置"))
                continue
            }
            var previous: ResolvedAudio?
            var failure: Error?
            do {
                let audio = try await client.resolve(song: candidate.song)
                previous = audio
                try Self.validate(audio)
                try Task.checkCancellation()
                do {
                    try await load(audio)
                } catch {
                    attempts.append(Self.attempt(candidate.song, stage: .load, error: error))
                    throw error
                }
                return .resolved(audio, attempts: attempts)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                failure = error
                attempts.append(Self.attempt(candidate.song, stage: .resolve, error: error))
            }
            guard let failure, Self.canRefresh(after: failure), !alreadyRefreshed.contains(candidate.song.id),
                  let refreshing = client as? any OnlineURLRefreshingClient else { continue }
            do {
                let audio = try await refreshing.refresh(song: candidate.song, previous: previous)
                try Self.validate(audio)
                try Task.checkCancellation()
                attempts.append(PlaybackResolutionAttempt(songID: candidate.song.id, stage: .refresh, message: "已刷新"))
                try await load(audio)
                return .resolved(audio, attempts: attempts)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                attempts.append(Self.attempt(candidate.song, stage: .refresh, error: error))
            }
        }
        return .skipped(song: song, attempts: attempts)
    }

    /// A runtime mpv failure may indicate an expired URL. Caller tracks one refresh per candidate.
    public func refresh(_ audio: ResolvedAudio) async throws -> ResolvedAudio? {
        guard let client = clients.first(where: { $0.source == audio.song.source }) as? any OnlineURLRefreshingClient else { return nil }
        let refreshed = try await client.refresh(song: audio.song, previous: audio)
        try Self.validate(refreshed)
        try Task.checkCancellation()
        return refreshed
    }

    public static func score(reference: SongData, candidate: SongData) -> PlaybackCandidateScore {
        PlaybackCandidateScore(title: textScore(reference.title, candidate.title, maximum: 40),
                               artist: textScore(reference.artist, candidate.artist, maximum: 20),
                               duration: durationScore(reference.duration, candidate.duration))
    }

    /// Android-inspired duration weighting: <=3s is strongest, then increasingly weaker tolerance.
    public static func durationScore(_ lhs: Double?, _ rhs: Double?) -> Int {
        guard let lhs = validDuration(lhs), let rhs = validDuration(rhs) else { return 0 }
        let difference = Swift.abs(lhs - rhs)
        if difference <= 3 { return 40 }
        if difference <= 5 { return 30 }
        if difference <= 10 { return 20 }
        if difference <= 15 { return 10 }
        return 0
    }

    private static func validDuration(_ duration: Double?) -> Double? {
        duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private func validDuration(_ duration: Double?) -> Double? { Self.validDuration(duration) }

    private static func textScore(_ lhs: String, _ rhs: String, maximum: Int) -> Int {
        let left = normalize(lhs)
        let right = normalize(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return maximum }
        if left.contains(right) || right.contains(left) { return maximum * 3 / 4 }
        let leftTokens = Set(left.split(separator: " "))
        let rightTokens = Set(right.split(separator: " "))
        let union = leftTokens.union(rightTokens).count
        guard union > 0 else { return 0 }
        return Int(Double(leftTokens.intersection(rightTokens).count) / Double(union) * Double(maximum / 2))
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func validate(_ audio: ResolvedAudio) throws {
        guard ["https", "http"].contains(audio.url.scheme?.lowercased() ?? ""),
              audio.url.host?.isEmpty == false, audio.url.user == nil, audio.url.password == nil else {
            throw OnlineResolutionError.invalidURL
        }
        if let expiration = audio.expiresAt, expiration <= Date() { throw OnlineResolutionError.expiredURL }
    }

    private static func canRefresh(after error: Error) -> Bool {
        if case OnlineResolutionError.expiredURL = error { return true }
        if let error = error as? OnlineError, case .http(let status) = error { return [401, 403, 410].contains(status) }
        return false
    }

    private static func attempt(_ song: SongData, stage: PlaybackResolutionAttempt.Stage, error: Error) -> PlaybackResolutionAttempt {
        PlaybackResolutionAttempt(songID: song.id, stage: stage, message: error.localizedDescription)
    }
}
