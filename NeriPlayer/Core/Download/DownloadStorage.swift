// DownloadStorage.swift
// M6: separate user downloads, working files and disposable caches with owned-path guards.
import CryptoKit
import Foundation

enum DownloadFailure: LocalizedError, Equatable {
    case invalidPath, invalidResponse, integrity, unsupported(String), http(Int), insufficientSpace
    var errorDescription: String? {
        switch self {
        case .invalidPath: return "文件不属于此下载目录"
        case .invalidResponse: return "下载服务器返回无效响应"
        case .integrity: return "下载文件完整性校验失败"
        case .unsupported(let reason): return reason
        case .http(let code): return "下载失败（HTTP \(code)）"
        case .insufficientSpace: return "磁盘剩余空间不足"
        }
    }
}

struct DownloadStorage: Sendable {
    let root: URL
    let cacheRoot: URL
    var working: URL { root.appendingPathComponent("Working", isDirectory: true) }
    var completed: URL { root.appendingPathComponent("Files", isDirectory: true) }
    var queueURL: URL { root.appendingPathComponent("queue.json") }

    static func standard() throws -> Self {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return Self(root: support.appendingPathComponent("NeriPlayer/Downloads", isDirectory: true),
                    cacheRoot: caches.appendingPathComponent("NeriPlayer", isDirectory: true))
    }

    func prepare() throws {
        for directory in [root, working, completed, cacheRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else {
                throw DownloadFailure.invalidPath
            }
        }
    }

    func workingFile(_ id: UUID) -> URL { working.appendingPathComponent(id.uuidString + ".part") }
    func sidecar(_ id: UUID) -> URL { working.appendingPathComponent(id.uuidString + ".json") }

    func finalFile(_ id: UUID, song: SongData, extension ext: String) -> URL {
        let title = String(song.title.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || "/\\:".unicodeScalars.contains(scalar) ? "_" : Character(scalar)
        }.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        return completed.appendingPathComponent("\(title.isEmpty ? "Audio" : title)-\(id.uuidString).\(ext)")
    }

    static func checked(_ url: URL, under root: URL) throws -> URL {
        let base = root.standardizedFileURL
        let target = url.standardizedFileURL
        guard base.isFileURL, target.isFileURL, target.path.hasPrefix(base.path + "/"),
              base == base.resolvingSymlinksInPath().standardizedFileURL,
              target == target.resolvingSymlinksInPath().standardizedFileURL else { throw DownloadFailure.invalidPath }
        return target
    }

    static func remove(_ url: URL, under root: URL) throws {
        let target = try checked(url, under: root)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }

    static func move(_ from: URL, to: URL, under root: URL) throws {
        let source = try checked(from, under: root)
        let destination = try checked(to, under: root)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw DownloadFailure.invalidPath }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    static func size(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DownloadFailure.invalidPath }
        return Int64(values.fileSize ?? 0)
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ url: URL, count: Int64? = nil) throws -> String {
        hex(try prefixHasher(url, count: count).finalize())
    }

    static func prefixHasher(_ url: URL, count: Int64? = nil) throws -> SHA256 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var remaining = try (count ?? size(url))
        guard remaining >= 0 else { throw DownloadFailure.integrity }
        while remaining > 0 {
            let chunk = try handle.read(upToCount: Int(min(remaining, 256 * 1024))) ?? Data()
            guard !chunk.isEmpty else { throw DownloadFailure.integrity }
            hash.update(data: chunk); remaining -= Int64(chunk.count)
        }
        return hash
    }

    static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func resourceKey(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let volatile = Set(["expire", "expires", "sig", "signature", "lsig", "n", "token", "deadline", "upsig", "wssecret", "wstime"])
        let filtered = parts?.queryItems?.filter { !volatile.contains($0.name.lowercased()) }.sorted { $0.name < $1.name }
        parts?.queryItems = filtered
        return key(parts?.string ?? url.absoluteString)
    }
}
