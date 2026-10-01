// SyncViewModel.swift
// M7: native settings actions for configuration, sync, private repo creation and metadata backup.

import Combine
import Foundation

@MainActor
final class SyncViewModel: ObservableObject {
    @Published var configuration: SyncConfiguration
    @Published var secret = ""
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var conflicts: [String] = []
    private let configurationStore: SyncConfigurationStore
    private let service: SyncService
    private let backup: BackupManager
    private let repository: SyncRepository
    private let beforeCapture: () -> Void
    private let beforeRestore: () -> Void
    private let afterRestore: () -> Void
    private let refresh: () -> Void

    init(database: DatabaseProvider, settings: SettingsStore, configurationStore: SyncConfigurationStore? = nil,
         beforeCapture: @escaping () -> Void = {}, beforeRestore: @escaping () -> Void = {},
         afterRestore: @escaping () -> Void = {}, refresh: @escaping () -> Void = {}) {
        let configurationStore = configurationStore ?? SyncConfigurationStore(settings: settings)
        self.configurationStore = configurationStore
        configuration = configurationStore.load()
        repository = SyncRepository(database)
        service = SyncService(repository: repository)
        backup = BackupManager(database: database, settings: settings)
        self.beforeCapture = beforeCapture; self.beforeRestore = beforeRestore
        self.afterRestore = afterRestore; self.refresh = refresh
    }
    func saveConfiguration() {
        guard !isBusy else { return }
        do {
            try configurationStore.save(configuration, secret: secret)
            _ = try configurationStore.transport(for: configuration)
            secret = ""; statusMessage = "同步配置已保存"
        } catch { statusMessage = error.localizedDescription }
    }
    func synchronize() {
        perform {
            self.beforeCapture()
            let transport = try self.configurationStore.transport(for: self.configuration)
            let merged = try await self.service.synchronize(using: transport)
            self.conflicts = merged.conflicts
            self.refresh()
            self.statusMessage = "同步完成：\(merged.snapshot.playlists.filter { !$0.flag("isDeleted") }.count) 个歌单"
        }
    }
    func createRepository() {
        perform {
            guard let transport = try self.configurationStore.transport(for: self.configuration) as? GitHubSyncTransport else {
                throw SyncError.invalidConfiguration
            }
            try await transport.createPrivateRepository()
            self.statusMessage = "私有同步仓库已创建"
        }
    }
    func exportBackup(to url: URL) {
        perform {
            self.beforeCapture()
            let backup = self.backup
            try await Task.detached { try backup.export(to: url) }.value
            self.statusMessage = "备份已导出"
        }
    }
    func restoreBackup(from url: URL) {
        perform {
            self.beforeRestore()
            defer { self.afterRestore() }
            let revision = try self.repository.capture().revision
            let backup = self.backup
            try await Task.detached { try backup.restore(from: url, expectedRevision: revision) }.value
            self.refresh()
            self.statusMessage = "备份已恢复"
        }
    }
    func addToLibrary(_ song: SongData, playlistID: UUID? = nil, favorite: Bool = false) {
        perform {
            let normalized = song.source == .bilibili ? try await BilibiliClient().syncMetadata(for: song) : song
            try self.repository.addOnlineSong(normalized, playlistID: playlistID, favorite: favorite)
            self.refresh(); self.statusMessage = favorite ? "已加入本地收藏" : "已加入歌单"
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; statusMessage = nil; conflicts = []
        Task {
            defer { isBusy = false }
            do { try await operation() } catch { statusMessage = error.localizedDescription }
        }
    }
}
