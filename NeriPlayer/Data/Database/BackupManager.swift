// BackupManager.swift
// M7: validated metadata backup with allowlisted settings and transactional relational restore.

import CryptoKit
import Foundation
import GRDB

public struct MetadataBackup: Codable, Sendable {
    public var format = "neriplayer-macos-backup"
    public var version = 1
    public var createdAt: Int64
    public var tables: [String: [SyncRecord]]
    public var settings: SyncRecord
}

public struct BackupManager: Sendable {
    public static let sizeLimit = 128 * 1_024 * 1_024
    private static let tables = ["Track", "Playlist", "PlaylistEntry", "Favorite", "PlayHistory", "PlaybackStats",
                                 "PlaybackStatsDailyBucket", "PlayerState", "TrafficStats", "SyncJournal"]
    private let database: DatabaseProvider
    private let settings: SettingsStore
    public init(database: DatabaseProvider, settings: SettingsStore) { self.database = database; self.settings = settings }

    public func export(to url: URL) throws {
        let backup = try database.dbQueue.read { db in
            var tables: [String: [SyncRecord]] = [:]
            for table in Self.tables {
                tables[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table)").map(Self.record)
            }
            return MetadataBackup(createdAt: SyncSnapshot.milliseconds(), tables: tables, settings: settings.backupSettings())
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(backup)
        guard payload.count <= Self.sizeLimit else { throw SyncError.tooLarge }
        let envelope = SyncRecord(["payload": .string(payload.base64EncodedString()),
                                   "sha256": .string(Self.digest(payload)), "format": .string("neriplayer-macos-backup-envelope")])
        try encoder.encode(envelope).write(to: url, options: .atomic)
        Log.db.info("元数据备份已导出")
    }

    public func restore(from url: URL, expectedRevision: Int64? = nil) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Self.sizeLimit * 2
        guard size <= Self.sizeLimit * 2 else { throw SyncError.tooLarge }
        let envelope = try JSONDecoder().decode(SyncRecord.self, from: Data(contentsOf: url))
        guard envelope.text("format") == "neriplayer-macos-backup-envelope",
              let payload = Data(base64Encoded: envelope.text("payload")), payload.count <= Self.sizeLimit,
              Self.digest(payload) == envelope.text("sha256") else { throw SyncError.invalidBackup }
        let backup = try JSONDecoder().decode(MetadataBackup.self, from: payload)
        guard backup.format == "neriplayer-macos-backup", backup.version == 1,
              Set(backup.tables.keys) == Set(Self.tables) else { throw SyncError.invalidBackup }
        try settings.validateBackupSettings(backup.settings)
        // Validate all tables, values, keys and foreign keys in an isolated database before touching live data.
        let validation = try DatabaseQueue()
        try database.dbQueue.backup(to: validation)
        try validation.write { db in try restoreTables(backup.tables, db: db) }
        try database.dbQueue.write { db in
            if let expectedRevision {
                let revision = try Int64.fetchOne(db, sql: "SELECT revision FROM SyncRevision WHERE id = 1") ?? 0
                guard revision == expectedRevision else { throw SyncError.localChanged }
            }
            try restoreTables(backup.tables, db: db)
        }
        settings.restoreBackupSettings(backup.settings)
        Log.db.info("元数据备份已恢复")
    }

    private func restoreTables(_ tables: [String: [SyncRecord]], db: Database) throws {
        for table in Self.tables.reversed() { try db.execute(sql: "DELETE FROM \(table)") }
        for table in Self.tables {
            let columns = try db.columns(in: table).map(\.name)
            for record in tables[table] ?? [] {
                guard Set(record.fields.keys) == Set(columns) else { throw SyncError.invalidBackup }
                let names = columns.map { "\"\($0)\"" }.joined(separator: ",")
                let placeholders = columns.map { _ in "?" }.joined(separator: ",")
                let arguments = try StatementArguments(columns.map { try Self.databaseValue(record.fields[$0] ?? .null) })
                try db.execute(sql: "INSERT INTO \(table) (\(names)) VALUES (\(placeholders))", arguments: arguments)
            }
        }
        try db.execute(sql: "DELETE FROM SyncJournal WHERE key LIKE 'lastSync:%'")
        guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else { throw SyncError.invalidBackup }
    }

    private static func record(_ row: Row) -> SyncRecord {
        var record = SyncRecord()
        for (name, value) in row {
            switch value.storage {
            case .null: record.fields[name] = .null
            case .int64(let value): record.set(name, value)
            case .double(let value): record.fields[name] = .object(["double": .string(String(value))])
            case .string(let value): record.set(name, value)
            case .blob(let value): record.fields[name] = .object(["blob": .string(value.base64EncodedString())])
            }
        }
        return record
    }
    private static func databaseValue(_ value: SyncValue) throws -> DatabaseValue {
        switch value {
        case .null: return .null
        case .integer(let value): return value.databaseValue
        case .string(let value): return value.databaseValue
        case .object(let fields):
            if case .string(let encoded) = fields["blob"], let data = Data(base64Encoded: encoded) { return data.databaseValue }
            if case .string(let encoded) = fields["double"], let number = Double(encoded), number.isFinite { return number.databaseValue }
            throw SyncError.invalidBackup
        default: throw SyncError.invalidBackup
        }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
