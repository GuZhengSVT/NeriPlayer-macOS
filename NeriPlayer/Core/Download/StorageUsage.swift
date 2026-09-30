// StorageUsage.swift
// M6: storage accounting and cleanup policy; user files are never treated as disposable cache.
import Foundation

struct StorageUsage: Sendable, Equatable {
    var downloads: Int64 = 0
    var working: Int64 = 0
    var playbackCache: Int64 = 0
    var artworkCache: Int64 = 0
    var total: Int64 { downloads + working + playbackCache + artworkCache }
}

struct StorageAnalyzer: Sendable {
    static func measure(downloads: URL, caches: URL) -> StorageUsage {
        let working = downloads.appendingPathComponent("Working", isDirectory: true)
        let files = downloads.appendingPathComponent("Files", isDirectory: true)
        let playback = caches.appendingPathComponent("Playback", isDirectory: true)
        let artwork = caches.appendingPathComponent("Artwork", isDirectory: true)
        return StorageUsage(downloads: size(files), working: size(working), playbackCache: size(playback), artworkCache: size(artwork))
    }

    static func clearCaches(caches: URL, keeping: Set<String> = []) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        let children = try FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        for child in children {
            guard !keeping.contains(child.lastPathComponent) else { continue }
            let safe = child.standardizedFileURL
            let inside = safe.path.hasPrefix(caches.standardizedFileURL.path + "/")
            guard inside, safe == safe.resolvingSymlinksInPath().standardizedFileURL else {
                throw DownloadFailure.invalidPath
            }
            try FileManager.default.removeItem(at: safe)
        }
    }

    private static func size(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            return 0
        }
        return enumerator.reduce(into: Int64(0)) { total, element in
            guard let file = element as? URL,
                  let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { return }
            total += Int64(values.fileSize ?? 0)
        }
    }
}
