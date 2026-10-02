// HTTPAudioDownloader.swift
// M6: Android-compatible strong ETag resume rules, durable checkpoints and bounded Range reads.
import Foundation

struct HTTPAudioDownloader: AudioDownloading {
    private struct CheckpointFields {
        var operationID: String
        var key: String
        var validator: String?
        var total: Int64?
        var position: Int64
        var ext: String
        var digest: String
    }
    let session: URLSession
    var chunkSize = 512 * 1024
    init(session: URLSession = .shared) { self.session = session }

    // swiftlint:disable:next cyclomatic_complexity
    func download(_ audio: ResolvedAudio, file: URL, sidecar: URL,
                  progress: @escaping @Sendable (DownloadProgress) async -> Void) async throws -> DownloadPayload {
        guard ["http", "https"].contains(audio.url.scheme), audio.url.host != nil else { throw DownloadFailure.invalidResponse }
        if audio.url.pathExtension.lowercased() == "m3u8" {
            return try await HLSAudioDownloader(session: session).download(audio, file: file, sidecar: sidecar, progress: progress)
        }
        let root = file.deletingLastPathComponent()
        _ = try DownloadStorage.checked(file, under: root)
        _ = try DownloadStorage.checked(sidecar, under: root)
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw DownloadFailure.invalidPath }
        }
        var checkpoint = try? JSONDecoder().decode(TransferCheckpoint.self, from: Data(contentsOf: sidecar))
        let key = DownloadStorage.resourceKey(audio.url)
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        var position: Int64 = 0
        if let saved = checkpoint, saved.hlsFingerprint == nil, saved.operationID == file.lastPathComponent,
           saved.resourceKey == key, saved.validator != nil, saved.durableBytes >= 0,
           try DownloadStorage.size(file) >= saved.durableBytes,
           try DownloadStorage.digest(file, count: saved.durableBytes) == saved.prefixDigest {
            position = saved.durableBytes
        } else { checkpoint = nil }
        try handle.truncate(atOffset: UInt64(position))
        try handle.seek(toOffset: UInt64(position))
        var hash = try DownloadStorage.prefixHasher(file, count: position)
        var cleanRestarts = 0
        while true {
            try Task.checkCancellation()
            var request = Self.request(audio.url, headers: audio.headers)
            request.setValue("bytes=\(position)-\(position + Int64(chunkSize) - 1)", forHTTPHeaderField: "Range")
            if position > 0, let validator = checkpoint?.validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
            let (bytes, rawResponse) = try await session.bytes(for: request)
            guard let response = rawResponse as? HTTPURLResponse else { throw DownloadFailure.invalidResponse }
            if response.statusCode == 416 {
                if position > 0, checkpoint?.total == position,
                   response.value(forHTTPHeaderField: "Content-Range") == "bytes */\(position)",
                   checkpoint?.validator != nil, checkpoint?.validator == Self.validator(response) {
                    return DownloadPayload(file: file, fileExtension: checkpoint?.fileExtension ?? "m4a", bytes: position)
                }
                guard cleanRestarts < 1 else { throw DownloadFailure.integrity }
                cleanRestarts += 1; position = 0; checkpoint = nil; hash = try DownloadStorage.prefixHasher(file, count: 0)
                try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0)
                continue
            }
            guard response.statusCode == 200 || response.statusCode == 206 else { throw DownloadFailure.http(response.statusCode) }
            let mime = response.value(forHTTPHeaderField: "Content-Type")
            if mime?.lowercased().contains("mpegurl") == true {
                try handle.close()
                return try await HLSAudioDownloader(session: session).download(audio, file: file, sidecar: sidecar, progress: progress)
            }
            if response.statusCode == 200, position > 0 {
                position = 0; checkpoint = nil; hash = try DownloadStorage.prefixHasher(file, count: 0)
                try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0)
            }
            let range = response.value(forHTTPHeaderField: "Content-Range").flatMap(Self.contentRange)
            if response.statusCode == 206 {
                guard let range, range.start == position, range.end - range.start + 1 <= Int64(chunkSize) else {
                    throw DownloadFailure.integrity
                }
                if position > 0, let saved = checkpoint,
                   saved.total != range.total || (saved.validator != nil && saved.validator != Self.validator(response)) {
                    guard cleanRestarts < 1 else { throw DownloadFailure.integrity }
                    cleanRestarts += 1; position = 0; checkpoint = nil; hash = try DownloadStorage.prefixHasher(file, count: 0)
                    try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0)
                    continue
                }
            }
            let total = range?.total ?? (response.expectedContentLength > 0 ? response.expectedContentLength : nil)
            let expectedBody = range.map { $0.end - $0.start + 1 } ?? total
            try Self.checkSpace(root, needed: total.map { max(0, $0 - position) } ?? Int64(chunkSize))
            let ext = Self.fileExtension(url: audio.url, mime: mime)
            var buffer = Data()
            var bodyBytes: Int64 = 0
            var lastCheckpoint = position
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte); bodyBytes += 1
                if let expectedBody, bodyBytes > expectedBody { throw DownloadFailure.integrity }
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer); hash.update(data: buffer)
                    position += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                    if position - lastCheckpoint >= Int64(chunkSize) {
                        checkpoint = try Self.save(sidecar: sidecar, handle: handle, fields: CheckpointFields(
                            operationID: file.lastPathComponent, key: key, validator: Self.validator(response), total: total,
                            position: position, ext: ext, digest: try DownloadStorage.digest(file, count: position)))
                        lastCheckpoint = position
                        await progress(DownloadProgress(received: position, total: total))
                    }
                }
            }
            try Task.checkCancellation()
            if !buffer.isEmpty { try handle.write(contentsOf: buffer); hash.update(data: buffer); position += Int64(buffer.count) }
            checkpoint = try Self.save(sidecar: sidecar, handle: handle, fields: CheckpointFields(
                operationID: file.lastPathComponent, key: key, validator: Self.validator(response), total: total,
                position: position, ext: ext, digest: try DownloadStorage.digest(file, count: position)))
            await progress(DownloadProgress(received: position, total: total))
            guard bodyBytes > 0, expectedBody == nil || bodyBytes == expectedBody else { throw DownloadFailure.integrity }
            if response.statusCode == 200 || position == total {
                guard position > 0 else { throw DownloadFailure.integrity }
                return DownloadPayload(file: file, fileExtension: ext, bytes: position)
            }
        }
    }

    static func checkSpace(_ root: URL, needed: Int64) throws {
        if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < min(needed, 64 * 1024 * 1024) + 8 * 1024 * 1024 { throw DownloadFailure.insufficientSpace }
    }

    static func request(_ url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        for (key, value) in headers where !["cookie", "range", "if-range", "accept-encoding"].contains(key.lowercased()) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    static func validator(_ response: HTTPURLResponse) -> String? {
        guard let etag = response.value(forHTTPHeaderField: "ETag"), etag.hasPrefix("\""), etag.hasSuffix("\""), etag.count >= 2 else { return nil }
        return etag
    }

    struct ContentRange: Equatable { var start: Int64; var end: Int64; var total: Int64 }
    static func contentRange(_ text: String) -> ContentRange? {
        guard text.hasPrefix("bytes ") else { return nil }
        let pieces = text.dropFirst(6).split(separator: "/")
        guard pieces.count == 2, let total = Int64(pieces[1]), total > 0 else { return nil }
        let offsets = pieces[0].split(separator: "-")
        guard offsets.count == 2, let start = Int64(offsets[0]), let end = Int64(offsets[1]), start >= 0, end >= start, end < total else { return nil }
        return ContentRange(start: start, end: end, total: total)
    }

    static func fileExtension(url: URL, mime: String?) -> String {
        let mime = mime?.lowercased() ?? ""
        if mime.contains("mpegurl") { return "m3u8" }
        if mime.contains("mpeg") && !mime.contains("video") { return "mp3" }
        if mime.contains("flac") { return "flac" }
        if mime.contains("webm") { return "webm" }
        if mime.contains("ogg") { return "ogg" }
        if mime.contains("mp4") { return "m4a" }
        if mime.contains("aac") { return "aac" }
        if mime.contains("mp2t") { return "ts" }
        let ext = url.pathExtension.lowercased()
        return ["mp3", "flac", "m4a", "mp4", "aac", "ogg", "opus", "webm", "wav", "ts"].contains(ext) ? ext : "m4a"
    }

    private static func save(sidecar: URL, handle: FileHandle, fields: CheckpointFields) throws -> TransferCheckpoint {
        try handle.synchronize()
        let checkpoint = TransferCheckpoint(operationID: fields.operationID, resourceKey: fields.key, validator: fields.validator,
                                            total: fields.total, durableBytes: fields.position, prefixDigest: fields.digest,
                                            fileExtension: fields.ext)
        try JSONEncoder().encode(checkpoint).write(to: sidecar, options: .atomic)
        return checkpoint
    }
}
