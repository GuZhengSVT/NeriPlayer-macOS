// LogTests.swift
// M0-T3 日志测试：确认各 category 的 debug/info/error 与按级别分发入口可正常调用、不崩溃。

import XCTest
@testable import NeriPlayer

final class LogTests: XCTestCase {

    /// subsystem 固定为约定的反向域名。
    func testSubsystemIsFixed() {
        XCTAssertEqual(Log.subsystem, "moe.ouom.NeriPlayer")
    }

    /// 五个 category 的各自三级方法均可调用（无抛出即通过）。
    func testAllCategoriesAllLevelsDoNotCrash() {
        let categories = [Log.player, Log.db, Log.net, Log.ui, Log.usb]
        for logger in categories {
            logger.debug("debug message")
            logger.info("info message")
            logger.error("error message")
        }
    }

    /// 按级别分发的便捷入口对每个 category 均可用。
    func testLevelHelpersForwardToCategory() {
        let categories = [Log.player, Log.db, Log.net, Log.ui, Log.usb]
        for logger in categories {
            Log.debug("debug via helper", to: logger)
            Log.info("info via helper", to: logger)
            Log.error("error via helper", to: logger)
        }
    }
}
