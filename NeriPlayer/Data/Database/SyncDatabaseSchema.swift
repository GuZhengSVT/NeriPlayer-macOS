// SyncDatabaseSchema.swift
// M7: transactional sync journal and mutation revision shared by all database connections.

import Foundation
import GRDB

enum SyncDatabaseSchema {
    static let migrate: @Sendable (Database) throws -> Void = { db in
        try db.create(table: "SyncJournal") { table in
            table.primaryKey("key", .text)
            table.column("value", .blob).notNull()
        }
        try db.create(table: "SyncRevision") { table in
            table.primaryKey("id", .integer)
            table.column("revision", .integer).notNull().defaults(to: 0)
        }
        try db.execute(sql: "INSERT INTO SyncRevision (id, revision) VALUES (1, 0)")
        for table in ["Track", "Playlist", "PlaylistEntry", "Favorite", "PlayHistory", "PlaybackStats", "PlaybackStatsDailyBucket"] {
            for operation in ["INSERT", "UPDATE", "DELETE"] {
                try db.execute(sql: """
                    CREATE TRIGGER sync_\(table)_\(operation) AFTER \(operation) ON \(table)
                    BEGIN UPDATE SyncRevision SET revision = revision + 1 WHERE id = 1; END
                    """)
            }
        }
    }
}
