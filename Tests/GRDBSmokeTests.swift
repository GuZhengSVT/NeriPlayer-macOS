// GRDBSmokeTests.swift
// M0-T2 冒烟测试：验证 GRDB 依赖已正确接入——内存库建表、插入、读回。

import XCTest
import GRDB

final class GRDBSmokeTests: XCTestCase {

    /// 用内存数据库验证 GRDB 基本读写链路可用。
    func testInMemoryDatabaseInsertAndReadBack() throws {
        let dbQueue = try DatabaseQueue() // 内存数据库

        try dbQueue.write { db in
            try db.create(table: "smoke") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
            }
            try db.execute(sql: "INSERT INTO smoke (name) VALUES (?)", arguments: ["NeriPlayer"])
        }

        let names = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM smoke ORDER BY id")
        }

        XCTAssertEqual(names, ["NeriPlayer"])
    }

    /// 验证行数统计与参数绑定在 GRDB 下工作正常。
    func testRowCountingAndArgumentBinding() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try db.create(table: "tracks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("duration", .integer).notNull()
            }
            for (title, duration) in [("A", 100), ("B", 200), ("C", 300)] {
                try db.execute(
                    sql: "INSERT INTO tracks (title, duration) VALUES (?, ?)",
                    arguments: [title, duration]
                )
            }
        }

        let count = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? -1
        }
        XCTAssertEqual(count, 3)

        let longTitles = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT title FROM tracks WHERE duration >= ? ORDER BY title",
                                arguments: [200])
        }
        XCTAssertEqual(longTitles, ["B", "C"])
    }
}
