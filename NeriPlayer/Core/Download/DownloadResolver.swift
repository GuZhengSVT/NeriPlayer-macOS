// DownloadResolver.swift
// M6: resolve stable online identities just before transfer so signed URLs are never persisted.
import Foundation

struct DownloadResolver: Sendable {
    let clients: [any OnlineMusicClient]
    func resolve(_ song: SongData) async throws -> ResolvedAudio {
        guard let client = clients.first(where: { $0.source == song.source }) else { throw OnlineError.unavailable("音源未配置") }
        return try await client.resolve(song: song)
    }
}
