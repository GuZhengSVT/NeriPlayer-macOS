// PlaybackAudioCache.swift
// Player-read Range chunks, quality-aware local hits and bounded disposable storage.
import Foundation

actor PlaybackAudioCache {
    private struct Entry: Codable {
        var songID: String
        var resourceKey: String
        var fileName: String
        var bytes: Int64
        var digest: String
        var requestedQuality: String?
        var actualQuality: String?
    }
    private struct Pending {
        var resourceKey: String
        var bytes: Int64
        var spans: [ClosedRange<Int64>] = []
        var file: URL
    }
    static let defaultCapacity: Int64 = 2 * 1024 * 1024 * 1024
    let root: URL
    let capacityBytes: Int64
    private let work: URL
    private var pending: [String: Pending] = [:]
    private var pinned = Set<String>()
    private var leases: [UUID: String] = [:]

    init(root: URL, capacityBytes: Int64 = PlaybackAudioCache.defaultCapacity) throws {
        self.root = root; work = root.appendingPathComponent("Working", isDirectory: true)
        self.capacityBytes = max(0, capacityBytes)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard root.standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL,
              work.standardizedFileURL == work.resolvingSymlinksInPath().standardizedFileURL else { throw DownloadFailure.invalidPath }
        // Includes unknown historical manifests and orphan/partial files without reusing them as known quality.
        try Self.trim(root: root, work: work, capacity: self.capacityBytes, protected: [])
    }

    /// Compatibility entry point for callers without a quality claim. Production uses lookupAudio.
    func lookup(_ song: SongData) throws -> URL? {
        try lookupEntry(song, quality: nil)?.url
    }

    func lookup(_ song: SongData, quality: String) throws -> URL? {
        try lookupAudio(song, quality: quality)?.url
    }

    func lookupAudio(_ song: SongData, quality: String) throws -> ResolvedAudio? {
        try lookupEntry(song, quality: quality)
    }

    private func lookupEntry(_ song: SongData, quality: String?) throws -> ResolvedAudio? {
        let key = Self.key(song, quality: quality)
        let metadata = try DownloadStorage.checked(root.appendingPathComponent(key + ".json"), under: root)
        guard FileManager.default.fileExists(atPath: metadata.path) else { return nil }
        do {
            let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: metadata))
            let file = try DownloadStorage.checked(root.appendingPathComponent(entry.fileName), under: root)
            guard entry.songID == song.id, entry.requestedQuality == quality,
                  entry.fileName.hasPrefix(key + "."),
                  try DownloadStorage.size(file) == entry.bytes, try DownloadStorage.digest(file) == entry.digest else { throw DownloadFailure.integrity }
            // Modification time acts as an LRU timestamp without rewriting credentials or signed URLs.
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: metadata.path)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return ResolvedAudio(song: song, url: file, requestedQuality: entry.requestedQuality, actualQuality: entry.actualQuality)
        } catch {
            try DownloadStorage.remove(metadata, under: root)
            return nil
        }
    }

    func pin(_ song: SongData) { pinned.insert(DownloadStorage.key(song.id)) }
    func unpin(_ song: SongData) {
        pinned.remove(DownloadStorage.key(song.id))
        try? trimToCapacity()
    }

    /// Independent leases prevent a cancelled old request from unpinning a newer play of the same song.
    func acquirePin(_ song: SongData) -> UUID {
        let lease = UUID(); leases[lease] = DownloadStorage.key(song.id); return lease
    }
    func releasePin(_ lease: UUID) {
        leases[lease] = nil
        try? trimToCapacity()
    }

    private static func key(_ song: SongData, quality: String?) -> String {
        let base = DownloadStorage.key(song.id)
        return quality.map { base + "-" + DownloadStorage.key($0) } ?? base
    }
    private var protectedKeys: Set<String> { pinned.union(leases.values) }

    func record(_ audio: ResolvedAudio, start: Int64, total: Int64, data: Data, mime: String?) throws {
        try Task.checkCancellation()
        guard start >= 0, total > 0, total <= Self.defaultCapacity, !data.isEmpty,
              start < total, Int64(data.count) <= total - start else { throw DownloadFailure.integrity }
        let key = Self.key(audio.song, quality: audio.requestedQuality)
        // A refreshed signed URL must not combine old partial bytes with a different upstream response.
        // Persist only a digest of the complete URL, never the signed URL or headers themselves.
        let resource = DownloadStorage.key(audio.url.absoluteString)
        let file = try DownloadStorage.checked(work.appendingPathComponent(key + ".part"), under: work)
        var item = pending[key] ?? Pending(resourceKey: resource, bytes: total, file: file)
        if item.resourceKey != resource || item.bytes != total {
            try DownloadStorage.remove(file, under: work)
            item = Pending(resourceKey: resource, bytes: total, file: file)
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw DownloadFailure.invalidPath }
            item.spans = []
        }
        try HTTPAudioDownloader.checkSpace(work, needed: Int64(data.count))
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start)); try handle.write(contentsOf: data)
        item.spans = Self.merged(item.spans + [start...(start + Int64(data.count) - 1)])
        pending[key] = item
        guard item.spans == [0...(total - 1)] else {
            try trimToCapacity(protecting: DownloadStorage.key(audio.song.id))
            return
        }
        try Task.checkCancellation()
        try handle.synchronize(); try handle.close()
        let ext = HTTPAudioDownloader.fileExtension(url: audio.url, mime: mime)
        let target = try DownloadStorage.checked(root.appendingPathComponent(key + "." + ext), under: root)
        let metadata = try DownloadStorage.checked(root.appendingPathComponent(key + ".json"), under: root)
        let digest = try DownloadStorage.digest(file)
        guard rename(file.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let entry = Entry(songID: audio.song.id, resourceKey: resource, fileName: target.lastPathComponent,
                          bytes: total, digest: digest, requestedQuality: audio.requestedQuality, actualQuality: audio.actualQuality)
        try JSONEncoder().encode(entry).write(to: metadata, options: .atomic)
        pending[key] = nil
        try trimToCapacity()
    }

    func clear() throws {
        try Self.trim(root: root, work: work, capacity: 0, protected: protectedKeys)
        discardRemovedPending()
    }

    func trimToCapacity() throws { try trimToCapacity(protecting: nil) }
    private func trimToCapacity(protecting key: String?) throws {
        var protected = protectedKeys
        if let key { protected.insert(key) }
        try Self.trim(root: root, work: work, capacity: capacityBytes, protected: protected)
        discardRemovedPending()
    }
    private func discardRemovedPending() {
        pending = pending.filter { FileManager.default.fileExists(atPath: $0.value.file.path) }
    }

    /// Group payloads, metadata and temporary files so eviction never leaves half of an owned entry.
    private static func trim(root: URL, work: URL, capacity: Int64, protected: Set<String>) throws {
        var groups: [String: [(URL, Int64, Date)]] = [:]
        var total: Int64 = 0
        for directory in [root, work] {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
                guard let bytes = try? DownloadStorage.size(url) else { continue }
                let key = url.deletingPathExtension().lastPathComponent
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                groups[key, default: []].append((url, bytes, date)); total += bytes
            }
        }
        let ordered = groups.sorted {
            let left = $0.value.map { $0.2 }.max() ?? .distantPast
            let right = $1.value.map { $0.2 }.max() ?? .distantPast
            return left == right ? $0.key < $1.key : left < right
        }
        for (key, files) in ordered where total > capacity {
            let songKey = key.split(separator: "-", maxSplits: 1).first.map(String.init) ?? key
            guard !protected.contains(songKey) else { continue }
            for (url, bytes, _) in files {
                try DownloadStorage.remove(url, under: root)
                total -= bytes
            }
        }
        // Active songs may temporarily exceed the budget; releasing their lease enforces it again.
    }

    static func merged(_ spans: [ClosedRange<Int64>]) -> [ClosedRange<Int64>] {
        var result: [ClosedRange<Int64>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, last.upperBound + 1 >= span.lowerBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else { result.append(span) }
        }
        return result
    }
}
