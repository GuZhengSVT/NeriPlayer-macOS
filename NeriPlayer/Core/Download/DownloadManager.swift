// DownloadManager.swift
// M6: durable FIFO scheduler, generation-fenced cancellation and recoverable core commits.
import Foundation
import Network

actor DownloadManager {
    typealias Resolve = @Sendable (SongData) async throws -> ResolvedAudio
    typealias Verify = @Sendable (URL, Double?) async throws -> Void
    private(set) var items: [AudioDownload]
    let storage: DownloadStorage
    private let resolve: Resolve
    private let downloader: any AudioDownloading
    private let verify: Verify
    private let finalizer: DownloadFinalizer
    private var parallelism: Int
    private var active: [UUID: (UUID, Task<Void, Never>)] = [:]
    private var observers: [UUID: AsyncStream<[AudioDownload]>.Continuation] = [:]
    private var wake: Task<Void, Never>?
    private var isRunning = false
    private var online = true
    private var persistenceFailed = false

    init(storage: DownloadStorage, parallelism: Int = 6, downloader: any AudioDownloading = HTTPAudioDownloader(),
         finalizer: DownloadFinalizer = DownloadFinalizer(), verify: Verify? = nil,
         resolve: @escaping Resolve) throws {
        try storage.prepare()
        var recovered: [AudioDownload]
        if FileManager.default.fileExists(atPath: storage.queueURL.path) {
            _ = try DownloadStorage.checked(storage.queueURL, under: storage.root)
            recovered = try JSONDecoder().decode([AudioDownload].self, from: Data(contentsOf: storage.queueURL))
        } else { recovered = [] }
        guard Set(recovered.map(\.id)).count == recovered.count else { throw DownloadFailure.integrity }
        for index in recovered.indices {
            if let name = recovered[index].fileName {
                guard name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("/"), !name.contains("\\") else { throw DownloadFailure.invalidPath }
                let file = try DownloadStorage.checked(storage.completed.appendingPathComponent(name), under: storage.completed)
                if recovered[index].status == .committing || recovered[index].status.isPostCore {
                    if FileManager.default.fileExists(atPath: file.path), (try? DownloadStorage.size(file)) ?? 0 > 0 {
                        if recovered[index].status == .committing { recovered[index].status = .coreCommitted }
                    } else { recovered[index].status = .failed; recovered[index].message = "已保存的音频丢失，请重新下载" }
                }
            }
            if [.resolving, .downloading, .committing].contains(recovered[index].status) {
                recovered[index].status = .queued
            }
            if recovered[index].status == .enriching { recovered[index].status = .coreCommitted }
        }
        try JSONEncoder().encode(recovered).write(to: storage.queueURL, options: .atomic)
        self.storage = storage
        self.parallelism = min(8, max(1, parallelism))
        self.downloader = downloader
        self.resolve = resolve
        self.verify = verify ?? { url, duration in try await DownloadFinalizer.verify(url, expectedDuration: duration) }
        self.finalizer = finalizer
        self.items = recovered
    }

    deinit { wake?.cancel(); active.values.forEach { $0.1.cancel() } }

    func observe() -> AsyncStream<[AudioDownload]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID(); observers[id] = continuation; continuation.yield(items)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    func snapshot() -> [AudioDownload] { items }
    func start() { isRunning = true; pump() }
    func setOnline(_ value: Bool) { online = value; if value { pump() } }
    func setParallelism(_ value: Int) { parallelism = min(8, max(1, value)); pump() }

    func enqueue(_ songs: [SongData]) throws {
        let previous = items
        for song in songs {
            guard !song.sourceID.isEmpty else { continue }
            if let index = items.firstIndex(where: { $0.song.id == song.id && $0.status != .cancelled }) {
                if items[index].status == .failed || items[index].status == .paused {
                    items[index].status = .queued; items[index].attempts = 0; items[index].nextRetryAt = nil
                }
            } else { items.append(AudioDownload(song: song)) }
        }
        do { try persist() } catch { items = previous; throw error }
        publish(); pump()
    }

    func pause(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].status.isPostCore,
              items[index].status != .committing, items[index].status != .cancelled else { return }
        items[index].status = .paused; items[index].nextRetryAt = nil
        active[id]?.1.cancel(); try persist(); publish(); pump()
    }
    func resume(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }), [.paused, .waiting, .failed].contains(items[index].status) else { return }
        items[index].status = .queued; items[index].attempts = 0; items[index].nextRetryAt = nil; items[index].message = nil
        try persist(); publish(); pump()
    }
    func cancel(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].status.isPostCore,
              items[index].status != .committing else { return }
        items[index].status = .cancelled; items[index].nextRetryAt = nil
        active[id]?.1.cancel(); try persist(); publish()
        if active[id] == nil { try cleanWorking(id) }
        pump()
    }

    func delete(_ id: UUID) throws {
        guard active[id] == nil, let index = items.firstIndex(where: { $0.id == id }),
              [.completed, .cancelled, .failed, .paused].contains(items[index].status) else { return }
        if let name = items[index].fileName { try DownloadStorage.remove(storage.completed.appendingPathComponent(name), under: storage.completed) }
        try cleanWorking(id)
        items.remove(at: index); try persist(); publish()
    }
    func clearFinishedHistory() throws {
        // Clearing history must never remove or orphan ownership records for completed user files.
        let cancelled = items.filter { $0.status == .cancelled && active[$0.id] == nil }.map(\.id)
        for id in cancelled { try cleanWorking(id) }
        items.removeAll { cancelled.contains($0.id) }; try persist(); publish()
    }

    func file(for id: UUID) throws -> URL? {
        guard let item = items.first(where: { $0.id == id }), item.status.isPostCore, let name = item.fileName else { return nil }
        let url = try DownloadStorage.checked(storage.completed.appendingPathComponent(name), under: storage.completed)
        guard let bytes = item.fileBytes, let digest = item.fileDigest,
              try DownloadStorage.size(url) == bytes, try DownloadStorage.digest(url) == digest else { throw DownloadFailure.integrity }
        return url
    }
    func file(for song: SongData) throws -> URL? {
        guard let item = items.first(where: { $0.song.id == song.id && $0.status == .completed }) else { return nil }
        return try file(for: item.id)
    }

    func stop() throws {
        isRunning = false; wake?.cancel(); wake = nil
        for id in active.keys {
            if let index = items.firstIndex(where: { $0.id == id }), !items[index].status.isPostCore {
                items[index].status = .paused; active[id]?.1.cancel()
            }
        }
        try persist(); publish()
    }

    private func pump() {
        wake?.cancel(); wake = nil
        guard isRunning, !persistenceFailed else { return }
        for item in items where active.count < parallelism {
            guard active[item.id] == nil else { continue }
            let ready = item.status == .queued || (item.status == .waiting && (item.nextRetryAt ?? .distantPast) <= Date())
            guard item.status == .coreCommitted || (online && ready) else { continue }
            let token = UUID()
            let itemID = item.id
            let task: Task<Void, Never> = Task { [weak self] in
                guard let self else { return }
                await self.run(itemID, token: token)
            }
            active[itemID] = (token, task)
        }
        if online, let deadline = items.filter({ $0.status == .waiting && active[$0.id] == nil }).compactMap(\.nextRetryAt).min() {
            let delay = max(0.1, deadline.timeIntervalSinceNow)
            wake = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                await self?.pump()
            }
        }
    }

    private func current(_ id: UUID, token: UUID) throws -> Int {
        try Task.checkCancellation()
        guard active[id]?.0 == token, let index = items.firstIndex(where: { $0.id == id }),
              ![.paused, .cancelled].contains(items[index].status) else { throw CancellationError() }
        return index
    }

    private func run(_ id: UUID, token: UUID) async {
        defer { active[id] = nil; publish(); pump() }
        do {
            var index = try current(id, token: token)
            if items[index].status != .coreCommitted {
                items[index].status = .resolving; try persist(); publish()
                let audio = try await resolve(items[index].song)
                index = try current(id, token: token)
                guard audio.song.id == items[index].song.id else { throw DownloadFailure.integrity }
                items[index].status = .downloading; try persist(); publish()
                Log.net.info("下载开始：\(audio.song.source.rawValue, privacy: .public)")
                let payload = try await downloader.download(audio, file: storage.workingFile(id), sidecar: storage.sidecar(id)) { [weak self] progress in
                    await self?.progress(id, token: token, value: progress)
                }
                index = try current(id, token: token)
                guard payload.bytes > 0, try DownloadStorage.size(payload.file) == payload.bytes else { throw DownloadFailure.integrity }
                try await verify(payload.file, audio.song.duration)
                index = try current(id, token: token)
                let destination = storage.finalFile(id, song: items[index].song, extension: payload.fileExtension)
                // Journal destination and digest before the atomic core rename; restart repairs either side.
                items[index].fileName = destination.lastPathComponent
                items[index].fileBytes = payload.bytes
                items[index].fileDigest = try DownloadStorage.digest(payload.file)
                items[index].status = .committing; try persist(); publish()
                try DownloadStorage.move(payload.file, to: destination, under: storage.root)
                items[index].status = .coreCommitted; try persist(); publish()
                try cleanWorking(id)
            }
            index = try current(id, token: token)
            guard let name = items[index].fileName else { throw DownloadFailure.integrity }
            let file = try DownloadStorage.checked(storage.completed.appendingPathComponent(name), under: storage.completed)
            items[index].status = .enriching; try persist(); publish()
            let warning = await finalizer.enrich(file, song: items[index].song, ownedRoot: storage.completed,
                                                 coverRoot: storage.cacheRoot.appendingPathComponent("Artwork", isDirectory: true))
            index = try current(id, token: token)
            items[index].fileBytes = try DownloadStorage.size(file)
            items[index].fileDigest = try DownloadStorage.digest(file)
            items[index].status = .completed; items[index].message = warning; items[index].nextRetryAt = nil
            try persist(); publish()
            Log.net.info("下载完成：\(self.items[index].song.source.rawValue, privacy: .public)")
        } catch {
            settleFailure(id, error: error)
        }
    }

    private func settleFailure(_ id: UUID, error: Error) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].status == .cancelled { try? cleanWorking(id); return }
        guard items[index].status != .paused, !(error is CancellationError), !Task.isCancelled else { return }
        if items[index].status.isPostCore {
            items[index].status = .completed
            items[index].message = "音频已保存，收尾失败：\(error.localizedDescription)"
        } else {
            applyRetry(error, to: index)
        }
        do { try persist() } catch {
            persistenceFailed = true
            Log.net.error("下载状态保存失败：\(error.localizedDescription)")
        }
    }

    private func applyRetry(_ error: Error, to index: Int) {
        let offline = DownloadRetryPolicy.isOffline(error)
        if !offline { items[index].attempts += 1 }
        let retry = DownloadRetryPolicy.limit(error).map { items[index].attempts < $0 } ?? false
        items[index].status = retry ? .waiting : .failed
        if retry {
            items[index].nextRetryAt = Date().addingTimeInterval(DownloadRetryPolicy.delay(retryCount: items[index].retryCount))
            if !offline { items[index].retryCount = min(31, items[index].retryCount + 1) }
        }
        items[index].message = error.localizedDescription
    }

    private func progress(_ id: UUID, token: UUID, value: DownloadProgress) {
        guard let index = try? current(id, token: token) else { return }
        items[index].received = value.received; items[index].total = value.total
        publish()
    }
    private func cleanWorking(_ id: UUID) throws {
        try DownloadStorage.remove(storage.workingFile(id), under: storage.working)
        try DownloadStorage.remove(storage.sidecar(id), under: storage.working)
    }
    private func persist() throws {
        _ = try DownloadStorage.checked(storage.queueURL, under: storage.root)
        try JSONEncoder().encode(items).write(to: storage.queueURL, options: .atomic)
    }
    private func publish() { observers.values.forEach { $0.yield(items) } }
}
