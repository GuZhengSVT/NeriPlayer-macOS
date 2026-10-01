// SyncService.swift
// M7: serialized sync with conflict refetch and preservation of in-flight local mutations.

import Foundation

public actor SyncService {
    private let repository: SyncRepository
    private var running = false
    public init(repository: SyncRepository) { self.repository = repository }
    public func synchronize(using transport: any SyncTransport) async throws -> SyncMergeResult {
        guard !running else { throw SyncError.busy }
        running = true
        defer { running = false }
        let local = try repository.capture()
        let lastSync = try repository.lastSyncTime(target: transport.targetID)
        var remote = try await transport.fetch()
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let remoteData = try remote.data.map(SyncSnapshotCodec.decode) ?? SyncSnapshot()
            let merged = SyncMergeEngine.merge(local: local.snapshot, remote: remoteData, lastSyncTime: lastSync)
            guard try repository.capture().revision == local.revision else { throw SyncError.localChanged }
            do {
                let content = try SyncSnapshotCodec.encode(merged.snapshot)
                if remote.data == nil || remote.storagePaths.contains(where: { $0 != "backup.json" }) ||
                    !meaningfullyEqual(merged.snapshot, remoteData) {
                    _ = try await transport.upload(content, replacing: remote)
                }
                guard try repository.apply(merged.snapshot, expectedRevision: local.revision, target: transport.targetID) else {
                    throw SyncError.localChanged
                }
                Log.net.info("元数据同步完成")
                return merged
            } catch SyncError.conflict where attempt < 2 {
                remote = try await transport.fetch()
            }
        }
        throw SyncError.conflict
    }
    private func meaningfullyEqual(_ left: SyncSnapshot, _ right: SyncSnapshot) -> Bool {
        var left = left.record, right = right.record
        for key in ["deviceId", "deviceName", "lastModified", "syncLog"] {
            left.fields.removeValue(forKey: key); right.fields.removeValue(forKey: key)
        }
        return left == right
    }
}
