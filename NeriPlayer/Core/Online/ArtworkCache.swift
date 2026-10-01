// ArtworkCache.swift
// T04: one artwork pipeline for every online surface —— supported-CDN HTTPS normalization,
// coalesced requests, and bounded memory/disk caches shared by grids, lists and the player bar.
import AppKit
import CryptoKit
import Foundation

public enum ArtworkLoadFailure: LocalizedError, Equatable {
    case invalidURL
    case http(Int)
    case tooLarge
    case undecodable

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "封面地址无效"
        case .http(let code): return "封面加载失败（HTTP \(code)）"
        case .tooLarge: return "封面文件超出缓存上限"
        case .undecodable: return "无法识别封面格式"
        }
    }

    /// A server-side miss can be a transient CDN problem; the other cases repeat identically.
    public var isTransient: Bool {
        guard case .http(let status) = self else { return false }
        return status == 408 || status == 429 || (500..<600).contains(status)
    }
}

/// Platform image CDNs that publish the same asset over TLS. Only these hosts get an
/// http→https upgrade; other URLs keep their scheme so unrelated endpoints stay untouched.
public enum ArtworkURLNormalizer {
    private static let secureHosts = ["music.126.net", "hdslb.com", "biliimg.com",
                                      "ytimg.com", "ggpht.com", "googleusercontent.com"]

    public static func normalized(_ raw: String?) -> URL? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.contains("\n"), !text.contains("\r") else { return nil }
        if text.hasPrefix("//") { text = "https:" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil else { return nil }
        guard scheme == "http", supportsTLS(host) else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? url
    }

    public static func normalized(_ url: URL?) -> URL? {
        guard let url else { return nil }
        return normalized(url.absoluteString)
    }

    /// Stable cache identity: scheme upgrades must not create a second disk entry per image.
    public static func key(for url: URL) -> String {
        let text = normalized(url)?.absoluteString ?? url.absoluteString
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func supportsTLS(_ host: String) -> Bool {
        secureHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// View identity for `.task(id:)`. A nil cover keeps one stable id so an absent cover
    /// stays in the empty state instead of re-running the loader.
    public static func taskIdentifier(for url: URL?) -> String {
        guard let url else { return "artwork-empty" }
        return key(for: url)
    }
}

public struct ArtworkCacheLimits: Sendable {
    public var memoryBytes: Int
    public var diskBytes: Int
    public var maxImageBytes: Int

    public init(memoryBytes: Int = 64 * 1024 * 1024, diskBytes: Int = 256 * 1024 * 1024,
                maxImageBytes: Int = 12 * 1024 * 1024) {
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.maxImageBytes = maxImageBytes
    }
}

/// Reference wrapper: Swift concurrency task results must be Sendable and NSImage is a mutable
/// AppKit object. The box only carries one already-decoded image back to the awaiting caller.
private final class ArtworkImageBox: @unchecked Sendable {
    let image: NSImage
    init(_ image: NSImage) { self.image = image }
}

/// Shared async artwork loader. Memory hits are synchronous so cached rows never flash a placeholder,
/// identical URLs share one request, and the disk cache evicts by least-recent use above its bound.
public final class ArtworkImageLoader: @unchecked Sendable {
    public static let shared = ArtworkImageLoader()

    private let directory: URL?
    private let session: URLSession
    private let limits: ArtworkCacheLimits
    private let diskQueue = DispatchQueue(label: "moe.ouom.NeriPlayer.artwork.disk", qos: .utility)
    private let lock = NSLock()
    private let memory = NSCache<NSString, NSImage>()
    private var inflight: [String: (id: UUID, task: Task<ArtworkImageBox, Error>)] = [:]
    private var writesSinceTrim = 0

    public init(directory: URL? = ArtworkImageLoader.defaultDirectory(), session: URLSession = .shared,
                limits: ArtworkCacheLimits = ArtworkCacheLimits()) {
        self.directory = directory
        self.session = session
        self.limits = limits
        memory.totalCostLimit = max(limits.memoryBytes, 0)
        memory.countLimit = 512
    }

    /// System caches directory already counted by StorageAnalyzer.artworkCache.
    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NeriPlayer/Artwork/Images", isDirectory: true)
    }

    public func cachedImage(for url: URL?) -> NSImage? {
        guard let normalized = ArtworkURLNormalizer.normalized(url) else { return nil }
        return memory.object(forKey: ArtworkURLNormalizer.key(for: normalized) as NSString)
    }

    public func image(for url: URL) async throws -> NSImage {
        guard let normalized = ArtworkURLNormalizer.normalized(url) else { throw ArtworkLoadFailure.invalidURL }
        let key = ArtworkURLNormalizer.key(for: normalized)
        if let cached = memory.object(forKey: key as NSString) { return cached }

        // One request per URL: concurrent grid cells and the player bar share the same task.
        let task = taskForImage(key: key, url: normalized)
        return try await task.value.image
    }

    // Lookup and registration are atomic so simultaneous first renders cannot start two downloads.
    // Locking stays in synchronous helpers: NSLock is unavailable from async contexts.
    private func taskForImage(key: String, url: URL) -> Task<ArtworkImageBox, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let running = inflight[key]?.task { return running }
        let id = UUID()
        let task = Task.detached(priority: .utility) { [self] () async throws -> ArtworkImageBox in
            defer { finishInFlight(key, id: id) }
            let image = try await fetch(url, key: key)
            memory.setObject(image, forKey: key as NSString, cost: ArtworkImageLoader.cost(of: image))
            return ArtworkImageBox(image)
        }
        inflight[key] = (id, task)
        return task
    }

    private func finishInFlight(_ key: String, id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if inflight[key]?.id == id { inflight[key] = nil }
    }

    private func noteWriteAndShouldTrim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        writesSinceTrim += 1
        guard writesSinceTrim >= Self.trimInterval else { return false }
        writesSinceTrim = 0
        return true
    }

    private func fetch(_ url: URL, key: String) async throws -> NSImage {
        if let cached = await loadFromDisk(key: key) { return cached }
        let data = try await download(url)
        guard let image = NSImage(data: data) else { throw ArtworkLoadFailure.undecodable }
        // Persist before returning so an immediate second load is a guaranteed disk hit.
        await store(data: data, key: key)
        return image
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let referer = Self.referer(for: url) { request.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ArtworkLoadFailure.undecodable }
        guard (200..<300).contains(http.statusCode) else {
            // Diagnostics stay at host/status level: no cookie, signature query or account data.
            Log.net.error("封面加载失败：host=\(url.host ?? "unknown", privacy: .public) status=\(http.statusCode)")
            throw ArtworkLoadFailure.http(http.statusCode)
        }
        guard data.count <= limits.maxImageBytes else { throw ArtworkLoadFailure.tooLarge }
        return data
    }

    private func loadFromDisk(key: String) async -> NSImage? {
        guard let directory else { return nil }
        let maxBytes = limits.maxImageBytes
        return await withCheckedContinuation { continuation in
            diskQueue.async {
                continuation.resume(returning: Self.readEntry(directory: directory, key: key, maxBytes: maxBytes))
            }
        }
    }

    private func store(data: Data, key: String) async {
        guard let directory else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            diskQueue.async {
                defer { continuation.resume() }
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: directory.appendingPathComponent(key + ".img", isDirectory: false), options: .atomic)
                } catch {
                    Log.net.error("封面缓存写入失败：\(error.localizedDescription)")
                }
            }
        }
        // The directory walk is amortized instead of paid on every single write.
        guard noteWriteAndShouldTrim() else { return }
        let limit = limits.diskBytes
        diskQueue.async { [self] in
            trimDisk(directory: directory, limit: limit)
        }
    }

    private static let trimInterval = 32

    private static func readEntry(directory: URL, key: String, maxBytes: Int) -> NSImage? {
        let file = directory.appendingPathComponent(key + ".img", isDirectory: false)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
              let size = values.fileSize, size > 0, size <= maxBytes,
              let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { return nil }
        guard let image = NSImage(data: data) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        // Touching the entry keeps the bound meaningful as a least-recently-used window.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return image
    }

    /// Trimmed to half the bound so the directory walk is paid rarely, not on every write.
    private func trimDisk(directory: URL, limit: Int) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        struct DiskEntry {
            var url: URL
            var size: Int
            var date: Date
        }
        var entries: [DiskEntry] = []
        var total = 0
        for child in children {
            guard let values = try? child.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            total += size
            entries.append(DiskEntry(url: child, size: size, date: values.contentModificationDate ?? .distantPast))
        }
        guard total > limit else { return }
        var remaining = total
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard remaining > limit / 2 else { break }
            try? FileManager.default.removeItem(at: entry.url)
            remaining -= entry.size
        }
    }

    private static func referer(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "music.126.net" || host.hasSuffix(".music.126.net") { return "https://music.163.com/" }
        if host.hasSuffix("hdslb.com") || host.hasSuffix("biliimg.com") { return "https://www.bilibili.com/" }
        if host.hasSuffix("ytimg.com") || host.hasSuffix("ggpht.com") || host.hasSuffix("googleusercontent.com") {
            return "https://music.youtube.com/"
        }
        return nil
    }

    private static func cost(of image: NSImage) -> Int {
        let pixels = image.representations.reduce(0) { partial, representation in
            let width = max(representation.pixelsWide, 0), height = max(representation.pixelsHigh, 0)
            return max(partial, width * height * 4)
        }
        return max(pixels, 1024)
    }
}
