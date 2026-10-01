// OnlineContentCache.swift
// Disposable platform metadata, isolated by session context and resource identity.
import Foundation
import GRDB

struct CachedOnlineValue<Value: Codable & Sendable>: Sendable {
    var value: Value
    var updatedAt: Date

    func isFresh(at now: Date, lifetime: TimeInterval) -> Bool {
        now.timeIntervalSince(updatedAt) >= 0 && now.timeIntervalSince(updatedAt) < lifetime
    }
}

final class OnlineContentCache: @unchecked Sendable {
    private let database: DatabaseProvider
    init(database: DatabaseProvider) { self.database = database }

    static let migrate: @Sendable (Database) throws -> Void = { db in
        try db.create(table: "OnlineContentCache") { table in
            table.primaryKey("cacheKey", .text)
            table.column("payload", .blob).notNull()
            table.column("updatedAt", .datetime).notNull()
        }
    }

    func read<Value: Codable & Sendable>(_ type: Value.Type, key: String) throws -> CachedOnlineValue<Value>? {
        let record: (Data, Date)? = try database.dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT payload, updatedAt FROM OnlineContentCache WHERE cacheKey = ?",
                                            arguments: [key]) else { return nil }
            return (row["payload"], row["updatedAt"])
        }
        guard let (payload, updatedAt) = record else { return nil }
        do { return CachedOnlineValue(value: try JSONDecoder().decode(type, from: payload), updatedAt: updatedAt) } catch {
            try? database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM OnlineContentCache WHERE cacheKey = ?", arguments: [key])
            }
            throw error
        }
    }

    func write<Value: Codable & Sendable>(_ value: CachedOnlineValue<Value>, key: String) throws {
        let payload = try JSONEncoder().encode(value.value)
        try database.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO OnlineContentCache (cacheKey, payload, updatedAt) VALUES (?, ?, ?)
                ON CONFLICT(cacheKey) DO UPDATE SET payload = excluded.payload, updatedAt = excluded.updatedAt
                """, arguments: [key, payload, value.updatedAt])
            try db.execute(sql: """
                DELETE FROM OnlineContentCache WHERE cacheKey NOT IN
                    (SELECT cacheKey FROM OnlineContentCache ORDER BY updatedAt DESC LIMIT 500)
                """)
        }
    }
}
