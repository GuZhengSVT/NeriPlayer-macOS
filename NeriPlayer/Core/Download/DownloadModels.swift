// DownloadModels.swift
// M6: operation stages and retry policy adapted from Android DownloadOperationState.
import Foundation

enum DownloadStatus: String, Codable, Sendable, CaseIterable {
    case queued, resolving, downloading, committing, coreCommitted, enriching, paused, waiting, failed, completed, cancelled
    var isActive: Bool { [.resolving, .downloading, .committing, .coreCommitted, .enriching].contains(self) }
    var title: String {
        switch self {
        case .queued: return "排队中"
        case .resolving: return "解析音源"
        case .downloading: return "下载中"
        case .committing: return "提交音频"
        case .coreCommitted: return "音频已保存"
        case .enriching: return "写入标签"
        case .paused: return "已暂停"
        case .waiting: return "等待重试"
        case .failed: return "失败"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        }
    }
    var isPostCore: Bool { [.coreCommitted, .enriching, .completed].contains(self) }
}

struct AudioDownload: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var song: SongData
    var status: DownloadStatus = .queued
    var received: Int64 = 0
    var total: Int64?
    var fileName: String?
    var fileBytes: Int64?
    var fileDigest: String?
    var message: String?
    var attempts = 0
    var retryCount = 0
    var nextRetryAt: Date?
    var createdAt = Date()
    var progress: Double? { total.flatMap { $0 > 0 ? min(1, Double(received) / Double($0)) : nil } }
}

struct DownloadProgress: Sendable {
    var received: Int64
    var total: Int64?
}

struct DownloadPayload: Sendable {
    var file: URL
    var fileExtension: String
    var bytes: Int64
}

struct TransferCheckpoint: Codable, Sendable {
    var operationID: String
    var resourceKey: String
    var validator: String?
    var total: Int64?
    var durableBytes: Int64
    var prefixDigest: String
    var fileExtension: String
    var hlsFingerprint: String?
    var nextSegment: Int?
}

protocol AudioDownloading: Sendable {
    func download(_ audio: ResolvedAudio, file: URL, sidecar: URL,
                  progress: @escaping @Sendable (DownloadProgress) async -> Void) async throws -> DownloadPayload
}

enum DownloadRetryPolicy {
    static func delay(retryCount: Int) -> TimeInterval { min(300, pow(2, Double(min(30, max(0, retryCount))))) }
    static func limit(_ error: Error) -> Int? {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost: return Int.max
            case .timedOut, .dnsLookupFailed, .resourceUnavailable: return 8
            default: return nil
            }
        }
        if let error = error as? DownloadFailure {
            switch error {
            case .integrity: return 3
            case .insufficientSpace: return 6
            case .http(let code): return [401, 403, 410].contains(code) ? 3 : (code == 408 || code == 429 || code >= 500 ? 8 : nil)
            default: return nil
            }
        }
        return nil
    }
    static func isOffline(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost].contains(error.code)
    }
}
