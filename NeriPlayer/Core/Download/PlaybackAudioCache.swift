// PlaybackAudioCache.swift
// M6: player-read Range chunks, complete coverage publication and corruption-safe local hits.
import Foundation

actor PlaybackAudioCache {
    private struct Entry: Codable {
        var songID: String
        var resourceKey: String
        var fileName: String
        var bytes: Int64
        var digest: String
    }
    private struct Pending {
        var resourceKey: String
        var bytes: Int64
        var spans: [ClosedRange<Int64>] = []
        var file: URL
    }
    let root: URL
    private let work: URL
    private var pending: [String: Pending] = [:]
    private var pinned = Set<String>()

    init(root: URL) throws {
        self.root = root; work = root.appendingPathComponent("Working", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard root.standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL else { throw DownloadFailure.invalidPath }
    }

    func lookup(_ song: SongData) throws -> URL? {
        let key = DownloadStorage.key(song.id)
        let metadata = root.appendingPathComponent(key + ".json")
        _ = try DownloadStorage.checked(metadata, under: root)
        guard FileManager.default.fileExists(atPath: metadata.path) else { return nil }
        do {
            let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: metadata))
            let file = try DownloadStorage.checked(root.appendingPathComponent(entry.fileName), under: root)
            guard entry.songID == song.id, entry.fileName.hasPrefix(key + "."),
                  try DownloadStorage.size(file) == entry.bytes, try DownloadStorage.digest(file) == entry.digest else { throw DownloadFailure.integrity }
            return file
        } catch {
            try DownloadStorage.remove(metadata, under: root)
            return nil
        }
    }

    func pin(_ song: SongData) { pinned.insert(DownloadStorage.key(song.id)) }
    func unpin(_ song: SongData) { pinned.remove(DownloadStorage.key(song.id)) }

    func record(_ audio: ResolvedAudio, start: Int64, total: Int64, data: Data, mime: String?) throws {
        guard start >= 0, total > 0, total <= 2 * 1024 * 1024 * 1024, !data.isEmpty,
              start < total, Int64(data.count) <= total - start else { throw DownloadFailure.integrity }
        let key = DownloadStorage.key(audio.song.id)
        let resource = DownloadStorage.resourceKey(audio.url)
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
        guard item.spans == [0...(total - 1)] else { return }
        try handle.synchronize(); try handle.close()
        let ext = HTTPAudioDownloader.fileExtension(url: audio.url, mime: mime)
        let target = try DownloadStorage.checked(root.appendingPathComponent(key + "." + ext), under: root)
        let metadata = try DownloadStorage.checked(root.appendingPathComponent(key + ".json"), under: root)
        let digest = try DownloadStorage.digest(file)
        guard rename(file.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let entry = Entry(songID: audio.song.id, resourceKey: resource, fileName: target.lastPathComponent, bytes: total, digest: digest)
        try JSONEncoder().encode(entry).write(to: metadata, options: .atomic)
        pending[key] = nil
    }

    func clear() throws {
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            if url.lastPathComponent == "Working" { continue }
            let key = url.deletingPathExtension().lastPathComponent
            guard !pinned.contains(key), (try? DownloadStorage.size(url)) != nil else { continue }
            try DownloadStorage.remove(url, under: root)
        }
        for url in try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: [.isRegularFileKey]) {
            let key = url.deletingPathExtension().lastPathComponent
            guard !pinned.contains(key), (try? DownloadStorage.size(url)) != nil else { continue }
            try DownloadStorage.remove(url, under: work); pending[key] = nil
        }
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
