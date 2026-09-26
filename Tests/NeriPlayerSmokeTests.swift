// NeriPlayerSmokeTests.swift
// M0-T1 冒烟测试：确认测试目标可链接并调用 App 模块的纯函数。

import XCTest
@testable import NeriPlayer

final class NeriPlayerSmokeTests: XCTestCase {
    func testDisplayNameIsStable() {
        XCTAssertEqual(AppInfo.displayName, "NeriPlayer")
    }

    func testMakeTitleFallsBackWhenSuffixEmpty() {
        XCTAssertEqual(AppInfo.makeTitle(with: nil), "NeriPlayer")
        XCTAssertEqual(AppInfo.makeTitle(with: "   "), "NeriPlayer")
        XCTAssertEqual(AppInfo.makeTitle(with: "播放器"), "NeriPlayer · 播放器")
    }
}
