// AppStateTests.swift — application lifecycle and nested observation regressions.
import Combine
import XCTest
@testable import NeriPlayer

@MainActor
final class AppStateTests: XCTestCase {
    private func makeState() throws -> (AppState, CrashReporter) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeriPlayerAppStateTests-\(UUID().uuidString)")
        let suite = "NeriPlayerAppStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let reporter = CrashReporter(directory: directory)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        return (AppState(settings: SettingsStore(userDefaults: defaults), crashReporter: reporter), reporter)
    }

    func testRootObservesAppearanceAndAccentChanges() throws {
        let (state, _) = try makeState()
        state.startSettings()
        let settings = try XCTUnwrap(state.settingsViewModel)
        var notifications = 0
        let observation = state.objectWillChange.sink { notifications += 1 }
        settings.setAppearance(.dark)
        settings.setAccent(.orange)
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(state.settingsViewModel?.appearance, .dark)
        withExtendedLifetime(observation) {}
    }

    func testNormalExitAcknowledgesOnlyStartupCrash() throws {
        let (state, reporter) = try makeState()
        reporter.handleUncaught(exception: NSException(name: .genericException, reason: "previous run"))
        XCTAssertTrue(state.detectSafeMode())
        state.acknowledgeStartupCrash()
        XCTAssertFalse(reporter.hasPendingCrashReport())
        XCTAssertNotNil(reporter.loadReport()?.handledAt)
        XCTAssertTrue(state.isSafeMode, "Current run must remain degraded until restart")
    }

    func testNewCrashIsNotAcknowledgedAsOldCrash() throws {
        let (state, reporter) = try makeState()
        reporter.handleUncaught(exception: NSException(name: .genericException, reason: "previous run"))
        XCTAssertTrue(state.detectSafeMode())
        reporter.handleUncaught(exception: NSException(name: .genericException, reason: "current run"))
        state.acknowledgeStartupCrash()
        XCTAssertTrue(reporter.hasPendingCrashReport())
        XCTAssertEqual(reporter.loadReport()?.reason, "current run")
    }
}
