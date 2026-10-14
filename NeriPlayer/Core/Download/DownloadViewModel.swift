// DownloadViewModel.swift
// M6: main-actor projection of the durable download actor for the Downloads tab.
import Combine
import Foundation

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published private(set) var items: [AudioDownload] = []
    @Published private(set) var storageBytes: Int64 = 0
    @Published private(set) var cacheBytes: Int64 = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var usage = StorageUsage()
    private let manager: DownloadManager
    private let cache: PlaybackAudioCache?
    private let storage: DownloadStorage
    private var observation: Task<Void, Never>?
    private var storageRefresh: Task<Void, Never>?
    private var storageDirty = false

    init(manager: DownloadManager, storage: DownloadStorage, cache: PlaybackAudioCache? = nil) {
        self.manager = manager
        self.storage = storage
        self.cache = cache
        observation = Task { [weak self] in
            for await items in await manager.observe() {
                guard !Task.isCancelled, let self else { return }
                self.items = items
                self.refreshStorage(storage)
            }
        }
        Task { await manager.start() }
    }

    deinit { observation?.cancel(); storageRefresh?.cancel() }

    func enqueue(_ song: SongData) { enqueue([song]) }
    func enqueue(_ songs: [SongData]) {
        Task { [weak self] in
            guard let self else { return }
            do { try await manager.enqueue(songs) } catch { errorMessage = error.localizedDescription }
        }
    }
    func pause(_ item: AudioDownload) { mutate { [manager] in try await manager.pause(item.id) } }
    func resume(_ item: AudioDownload) { mutate { [manager] in try await manager.resume(item.id) } }
    func cancel(_ item: AudioDownload) { mutate { [manager] in try await manager.cancel(item.id) } }
    func delete(_ item: AudioDownload) { mutate { [manager] in try await manager.delete(item.id) } }
    func clearHistory() { mutate { [manager] in try await manager.clearFinishedHistory() } }
    func clearCache() {
        let storage = self.storage
        Task { [weak self, cache] in
            do {
                try await cache?.clear()
                self?.refreshStorage(storage)
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }
    func clearError() { errorMessage = nil }

    /// 下载 actor 检查文件归属、长度和摘要，界面不自行拼接或信任外来路径。
    func completedFile(for item: AudioDownload) async -> URL? {
        do {
            guard item.status == .completed, let file = try await manager.file(for: item.id) else {
                errorMessage = "下载文件尚未完成或已不存在。"; return nil
            }
            return file
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func refreshStorage() { refreshStorage(storage) }

    func clearArtworkCache() {
        Task { [weak self] in
            do {
                try await ArtworkImageLoader.shared.clearDiskCache()
                if let self {
                    try StorageAnalyzer.clearArtwork(caches: storage.cacheRoot)
                    refreshStorage()
                }
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    private func mutate(_ operation: @escaping () async throws -> Void) {
        Task { [weak self] in
            do { try await operation() } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    private func refreshStorage(_ storage: DownloadStorage) {
        storageDirty = true
        guard storageRefresh == nil else { return }
        // 至多一个目录遍历在途；进度高频更新合并为每秒一次，完成事件仍有最终更新。
        storageRefresh = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                storageDirty = false
                let values = await Task.detached(priority: .utility) {
                    StorageAnalyzer.measure(downloads: storage.root, caches: storage.cacheRoot)
                }.value
                guard !Task.isCancelled else { return }
                usage = values
                storageBytes = values.downloads + values.working
                cacheBytes = values.playbackCache + values.artworkCache
                if !storageDirty { storageRefresh = nil; return }
            }
        }
    }
}
