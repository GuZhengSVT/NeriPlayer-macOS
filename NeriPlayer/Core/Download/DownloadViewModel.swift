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
    private let manager: DownloadManager
    private let cache: PlaybackAudioCache?
    private let storage: DownloadStorage
    private var observation: Task<Void, Never>?

    init(manager: DownloadManager, storage: DownloadStorage, cache: PlaybackAudioCache? = nil) {
        self.manager = manager
        self.storage = storage
        self.cache = cache
        observation = Task { [weak self] in
            guard let self else { return }
            for await items in await manager.observe() {
                guard !Task.isCancelled else { return }
                self.items = items
                self.refreshStorage(storage)
            }
        }
        Task { await manager.start() }
    }

    deinit { observation?.cancel() }

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

    private func mutate(_ operation: @escaping () async throws -> Void) {
        Task { [weak self] in
            do { try await operation() } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    private func refreshStorage(_ storage: DownloadStorage) {
        let root = storage.root
        let cache = storage.cacheRoot
        Task.detached(priority: .utility) {
            let values = Self.directorySize(root)
            let cacheValues = Self.directorySize(cache)
            await MainActor.run { [weak self] in
                self?.storageBytes = values
                self?.cacheBytes = cacheValues
            }
        }
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            return 0
        }
        return enumerator.reduce(into: Int64(0)) { result, element in
            guard let file = element as? URL,
                  let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { return }
            result += Int64(values.fileSize ?? 0)
        }
    }
}
