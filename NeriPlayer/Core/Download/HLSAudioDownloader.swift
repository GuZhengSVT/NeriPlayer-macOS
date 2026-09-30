// HLSAudioDownloader.swift
// M6: final unencrypted playlists, timed ID3 stripping and per-segment durable SHA256 resume.
import CryptoKit
import Foundation

struct HLSPlaylist: Sendable {
    let segments: [URL]
    let fingerprint: String
    let mediaSequence: Int64?

    init(url: URL, text: String) throws {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard lines.contains("#EXTM3U"), lines.contains(where: { $0.uppercased() == "#EXT-X-ENDLIST" }) else {
            throw DownloadFailure.unsupported("只支持已结束的 HLS 点播清单")
        }
        for line in lines {
            let upper = line.uppercased()
            if ["#EXT-X-MAP", "#EXT-X-BYTERANGE", "#EXT-X-I-FRAMES-ONLY", "#EXT-X-STREAM-INF"].contains(where: { upper.hasPrefix($0) }) {
                throw DownloadFailure.unsupported("不支持该 HLS 标签：\(line.components(separatedBy: ":")[0])")
            }
            if upper.hasPrefix("#EXT-X-KEY") {
                let attributes = upper.components(separatedBy: ":").dropFirst().joined(separator: ":").components(separatedBy: ",")
                guard attributes.contains(where: { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "") == "METHOD=NONE" }) else {
                    throw DownloadFailure.unsupported("不支持加密 HLS")
                }
            }
        }
        segments = try lines.filter { !$0.hasPrefix("#") }.map {
            guard let resolved = URL(string: $0, relativeTo: url)?.absoluteURL,
                  ["https", "http"].contains(resolved.scheme), resolved.user == nil, resolved.password == nil else { throw DownloadFailure.invalidResponse }
            return resolved
        }
        guard !segments.isEmpty, segments.count <= 100_000 else { throw DownloadFailure.invalidResponse }
        mediaSequence = lines.first(where: { $0.uppercased().hasPrefix("#EXT-X-MEDIA-SEQUENCE:") })
            .flatMap { Int64($0.components(separatedBy: ":").last ?? "") }.flatMap { $0 >= 0 ? $0 : nil }
        let metadata = lines.filter { line in
            ["#EXT-X-MEDIA-SEQUENCE", "#EXTINF:", "#EXT-X-TARGETDURATION"].contains { line.uppercased().hasPrefix($0) }
        }
        // Volatile signature changes must not invalidate an otherwise identical playlist.
        fingerprint = DownloadStorage.key((["neriplayer-hls-playlist-v2"] + segments.map(DownloadStorage.resourceKey) + metadata).joined(separator: "\u{0}"))
    }
}

struct HLSAudioDownloader: AudioDownloading {
    private struct Resume {
        var position: Int64
        var next: Int
        var fileExtension: String
    }

    // Playlist validation stays separate from transfer state to match the Android helper boundary.
    private func resumeState(_ sidecar: URL, file: URL, playlist: HLSPlaylist) throws -> Resume {
        guard let saved = try? JSONDecoder().decode(TransferCheckpoint.self, from: Data(contentsOf: sidecar)),
              saved.operationID == file.lastPathComponent, saved.hlsFingerprint == playlist.fingerprint,
              let index = saved.nextSegment, (0...playlist.segments.count).contains(index),
              saved.durableBytes >= 0, index > 0 || saved.durableBytes == 0,
              try DownloadStorage.size(file) >= saved.durableBytes,
              try DownloadStorage.digest(file, count: saved.durableBytes) == saved.prefixDigest else {
            return Resume(position: 0, next: 0, fileExtension: "ts")
        }
        return Resume(position: saved.durableBytes, next: index, fileExtension: saved.fileExtension)
    }
    let session: URLSession
    var maximumPlaylistBytes = 2 * 1024 * 1024
    var maximumSegmentBytes: Int64 = 64 * 1024 * 1024

    // swiftlint:disable:next cyclomatic_complexity
    func download(_ audio: ResolvedAudio, file: URL, sidecar: URL,
                  progress: @escaping @Sendable (DownloadProgress) async -> Void) async throws -> DownloadPayload {
        let root = file.deletingLastPathComponent()
        _ = try DownloadStorage.checked(file, under: root)
        _ = try DownloadStorage.checked(sidecar, under: root)
        let (bytes, rawResponse) = try await session.bytes(for: HTTPAudioDownloader.request(audio.url, headers: audio.headers))
        guard let response = rawResponse as? HTTPURLResponse else { throw DownloadFailure.invalidResponse }
        guard response.statusCode == 200 else { throw DownloadFailure.http(response.statusCode) }
        var playlistData = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard playlistData.count < maximumPlaylistBytes else { throw DownloadFailure.invalidResponse }
            playlistData.append(byte)
        }
        guard let text = String(data: playlistData, encoding: .utf8) else { throw DownloadFailure.invalidResponse }
        let playlist = try HLSPlaylist(url: response.url ?? audio.url, text: text)
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw DownloadFailure.invalidPath }
        }
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let resume = try resumeState(sidecar, file: file, playlist: playlist)
        var position = resume.position
        let next = resume.next
        var ext = resume.fileExtension
        try handle.truncate(atOffset: UInt64(position)); try handle.seek(toOffset: UInt64(position))
        var hash = try DownloadStorage.prefixHasher(file, count: position)
        for index in next..<playlist.segments.count {
            try Task.checkCancellation()
            try HTTPAudioDownloader.checkSpace(root, needed: maximumSegmentBytes)
            let segmentURL = playlist.segments[index]
            // Referer and UA are safe on CDN requests. Credentials never cross origins.
            let (stream, raw) = try await session.bytes(for: HTTPAudioDownloader.request(segmentURL, headers: audio.headers))
            guard let reply = raw as? HTTPURLResponse else { throw DownloadFailure.invalidResponse }
            guard reply.statusCode == 200 else { throw DownloadFailure.http(reply.statusCode) }
            var iterator = stream.makeAsyncIterator()
            var header = Data()
            while header.count < 10, let byte = try await iterator.next() { header.append(byte) }
            var rawCount = Int64(header.count)
            var buffer = Data()
            if header.count == 10, header.prefix(3) == Data("ID3".utf8) {
                let size = (Int64(header[6] & 0x7f) << 21) | (Int64(header[7] & 0x7f) << 14)
                    | (Int64(header[8] & 0x7f) << 7) | Int64(header[9] & 0x7f)
                let footer: Int64 = header[3] == 4 && header[5] & 0x10 != 0 ? 10 : 0
                guard 10 + size + footer <= maximumSegmentBytes else { throw DownloadFailure.integrity }
                for _ in 0..<(size + footer) {
                    try Task.checkCancellation()
                    guard try await iterator.next() != nil else { throw DownloadFailure.integrity }
                    rawCount += 1
                }
            } else { buffer = header }
            var written: Int64 = 0
            while let byte = try await iterator.next() {
                try Task.checkCancellation()
                rawCount += 1
                guard rawCount <= maximumSegmentBytes else { throw DownloadFailure.integrity }
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    if index == 0, written == 0 { ext = Self.container(buffer) }
                    try handle.write(contentsOf: buffer); hash.update(data: buffer)
                    written += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                if index == 0, written == 0 { ext = Self.container(buffer) }
                try handle.write(contentsOf: buffer); hash.update(data: buffer); written += Int64(buffer.count)
            }
            guard written > 0, reply.expectedContentLength < 0 || rawCount == reply.expectedContentLength else { throw DownloadFailure.integrity }
            position += written
            try handle.synchronize()
            let checkpoint = TransferCheckpoint(operationID: file.lastPathComponent, resourceKey: DownloadStorage.resourceKey(audio.url),
                                                durableBytes: position, prefixDigest: try DownloadStorage.digest(file, count: position), fileExtension: ext,
                                                hlsFingerprint: playlist.fingerprint, nextSegment: index + 1)
            try JSONEncoder().encode(checkpoint).write(to: sidecar, options: .atomic)
            await progress(DownloadProgress(received: position, total: index + 1 == playlist.segments.count ? position : nil))
        }
        return DownloadPayload(file: file, fileExtension: ext, bytes: position)
    }

    static func container(_ data: Data) -> String {
        if data.first == 0x47 { return "ts" }
        if data.count >= 2, data[0] == 0xff, data[1] & 0xf6 == 0xf0 { return "aac" }
        if data.prefix(3) == Data("ID3".utf8) { return "mp3" }
        return "ts"
    }
}
