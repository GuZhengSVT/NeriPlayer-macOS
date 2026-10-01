// SyncSnapshot.swift
// M7: lossless Android metadata records, with defaults for legacy snapshots.

import Foundation

public enum SyncValue: Codable, Equatable, Sendable {
    case string(String), integer(Int64), bool(Bool), array([SyncValue]), object([String: SyncValue]), null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SyncValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SyncValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct SyncRecord: Codable, Equatable, Sendable {
    public var fields: [String: SyncValue]
    public init(_ fields: [String: SyncValue] = [:]) { self.fields = fields }
    public init(from decoder: Decoder) throws {
        fields = try decoder.singleValueContainer().decode([String: SyncValue].self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }
    public func text(_ key: String, default fallback: String = "") -> String {
        if case .string(let value) = fields[key] { return value }
        return fallback
    }
    public func number(_ key: String, default fallback: Int64 = 0) -> Int64 {
        if case .integer(let value) = fields[key] { return value }
        return fallback
    }
    public func flag(_ key: String) -> Bool {
        if case .bool(let value) = fields[key] { return value }
        return false
    }
    public func records(_ key: String) -> [SyncRecord] {
        guard case .array(let values) = fields[key] else { return [] }
        return values.compactMap { if case .object(let fields) = $0 { return SyncRecord(fields) }; return nil }
    }
    public mutating func set(_ key: String, _ value: String) { fields[key] = .string(value) }
    public mutating func set(_ key: String, _ value: Int64) { fields[key] = .integer(value) }
    public mutating func set(_ key: String, _ value: Bool) { fields[key] = .bool(value) }
    public mutating func set(_ key: String, _ records: [SyncRecord]) {
        fields[key] = .array(records.map { .object($0.fields) })
    }
    public func replacing(_ key: String, with value: Int64) -> SyncRecord {
        var result = self; result.set(key, value); return result
    }
}

public struct SyncSnapshot: Codable, Equatable, Sendable {
    public var record: SyncRecord
    public init(deviceID: String = "", deviceName: String = "", modifiedAt: Int64 = 0) {
        record = SyncRecord(["version": .string("2.0"), "deviceId": .string(deviceID),
                             "deviceName": .string(deviceName), "lastModified": .integer(modifiedAt)])
    }
    public init(from decoder: Decoder) throws { record = try SyncRecord(from: decoder) }
    public func encode(to encoder: Encoder) throws { try record.encode(to: encoder) }
    public var playlists: [SyncRecord] {
        get { record.records("playlists") }
        set { record.set("playlists", newValue) }
    }
    public static func milliseconds(_ date: Date = Date()) -> Int64 {
        Int64(min(max(date.timeIntervalSince1970 * 1_000, 0), Double(Int64.max / 2)))
    }
    public func sanitized() -> SyncSnapshot {
        var snapshot = self
        for key in ["playlists", "favoritePlaylists"] {
            snapshot.record.set(key, record.records(key).map { playlist in
                var result = playlist
                result.set("songs", playlist.records("songs").filter { !$0.isLocalSong }.map { $0.sanitizedSong() })
                result.fields["coverUrl"] = playlist.networkCover("coverUrl")
                return result
            })
        }
        snapshot.record.set("recentPlays", record.records("recentPlays").compactMap { play in
            guard case .object(let fields) = play.fields["song"] else { return nil }
            let song = SyncRecord(fields)
            guard !song.isLocalSong else { return nil }
            var result = play; result.fields["song"] = .object(song.sanitizedSong().fields); return result
        })
        for key in ["playbackStats", "playbackStatBuckets", "playlistUsageStats"] {
            snapshot.record.set(key, record.records(key).filter { !$0.isLocalSong }.map { item in
                var result = item; result.fields["coverUrl"] = item.networkCover("coverUrl"); return result
            })
        }
        return snapshot
    }
}

extension SyncRecord {
    var isLocalSong: Bool {
        let uri = text("mediaUri").lowercased()
        return text("channelId").lowercased() == "local" || text("album").lowercased() == "local" ||
            uri.hasPrefix("file:") || uri.hasPrefix("content:") || uri.hasPrefix("/")
    }
    func networkCover(_ key: String) -> SyncValue? {
        guard let url = URL(string: text(key)), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return .string(url.absoluteString)
    }
    func sanitizedSong() -> SyncRecord {
        var result = self
        for key in ["coverUrl", "customCoverUrl", "originalCoverUrl"] { result.fields[key] = networkCover(key) }
        result.fields.removeValue(forKey: "streamUrl")
        result.fields.removeValue(forKey: "localFilePath")
        result.fields.removeValue(forKey: "localFileName")
        return result
    }
    var songRecord: SyncRecord {
        if case .object(let fields) = fields["song"] { return SyncRecord(fields) }
        return self
    }
}

public enum SyncError: LocalizedError, Equatable {
    case invalidSnapshot, unsupportedVersion(String), tooLarge, invalidConfiguration, conflict, localChanged, busy
    case unsafeRemoteVersion, http(Int), invalidBackup
    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "同步快照格式无效"
        case .unsupportedVersion(let version): return "不支持的快照版本：\(version)"
        case .tooLarge: return "同步或备份文件超过大小限制"
        case .invalidConfiguration: return "同步配置不完整或地址无效"
        case .conflict: return "远端在同步过程中发生修改，请重试"
        case .localChanged: return "本地数据已修改，本次未覆盖本地数据，请再次同步"
        case .busy: return "同步或备份正在进行"
        case .unsafeRemoteVersion: return "远端未提供可用于安全写入的版本标识"
        case .http(let status): return "同步请求失败（HTTP \(status)）"
        case .invalidBackup: return "备份文件无效，未修改本地数据"
        }
    }
}
