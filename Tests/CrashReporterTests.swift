// CrashReporterTests.swift
// M0-T4 崩溃捕获测试：用临时目录验证记录写入 / 待处理探测 / 消费与清除。
// 直接调用处理函数，不需要真的崩溃进程。

import XCTest
@testable import NeriPlayer

final class CrashReporterTests: XCTestCase {

    private var tempDir: URL!
    private var reporter: CrashReporter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeriPlayerCrashTests-\(UUID().uuidString)", isDirectory: true)
        reporter = CrashReporter(directory: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        reporter = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    /// 无记录时不进入安全模式。
    func testNoPendingReportInitially() {
        XCTAssertFalse(reporter.hasPendingCrashReport())
        XCTAssertNil(reporter.loadReport())
    }

    /// 处理未捕获异常会把记录写入文件，且文件可被解析回同一内容。
    func testHandleUncaughtWritesReportFile() throws {
        let exception = NSException(
            name: .genericException,
            reason: "boom",
            userInfo: nil
        )

        let written = reporter.handleUncaught(exception: exception)

        XCTAssertEqual(written.name, NSExceptionName.genericException.rawValue)
        XCTAssertEqual(written.reason, "boom")
        XCTAssertNil(written.handledAt)

        // 目录由 store 自动创建。
        XCTAssertTrue(FileManager.default.fileExists(atPath: reporter.reportURL.path))

        let reloaded = try XCTUnwrap(reporter.loadReport())
        XCTAssertEqual(reloaded.name, written.name)
        XCTAssertEqual(reloaded.reason, written.reason)
        XCTAssertEqual(reloaded.callStackSymbols, written.callStackSymbols)
        XCTAssertEqual(reloaded.appVersion, written.appVersion)
    }

    /// 写入后 hasPendingCrashReport 为真，且 CrashState 需要安全模式。
    func testPendingReportDetectedAfterHandler() {
        let exception = NSException(name: .internalInconsistencyException,
                                    reason: "state broken",
                                    userInfo: nil)
        reporter.handleUncaught(exception: exception)

        XCTAssertTrue(reporter.hasPendingCrashReport())
    }

    /// markCrashHandled 消费记录后不再视为待处理。
    func testMarkHandledClearsPendingFlag() {
        reporter.handleUncaught(exception: NSException(name: .genericException,
                                                       reason: "boom",
                                                       userInfo: nil))
        XCTAssertTrue(reporter.hasPendingCrashReport())

        reporter.markCrashHandled()

        XCTAssertFalse(reporter.hasPendingCrashReport())
        // 记录本身保留，供诊断查看。
        XCTAssertNotNil(reporter.loadReport())
        XCTAssertNotNil(reporter.loadReport()?.handledAt)
    }

    /// clearPendingCrashReport 删除记录文件。
    func testClearRemovesReport() {
        reporter.handleUncaught(exception: NSException(name: .genericException,
                                                       reason: "boom",
                                                       userInfo: nil))
        XCTAssertTrue(reporter.hasPendingCrashReport())

        reporter.clearPendingCrashReport()

        XCTAssertFalse(reporter.hasPendingCrashReport())
        XCTAssertFalse(FileManager.default.fileExists(atPath: reporter.reportURL.path))
        XCTAssertNil(reporter.loadReport())
    }

    /// 注入的临时目录被使用，不触碰真实 Application Support。
    func testUsesInjectedDirectory() {
        XCTAssertEqual(reporter.reportURL.deletingLastPathComponent(), tempDir)
        XCTAssertNotEqual(reporter.reportURL, CrashReporter.shared.reportURL)
    }

}
