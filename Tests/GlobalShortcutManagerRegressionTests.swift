import XCTest
@testable import NeriPlayer

final class GlobalShortcutManagerRegressionTests: XCTestCase {
    private final class ActionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [MediaKeyEvent.Action] = []

        func append(_ action: MediaKeyEvent.Action) {
            lock.lock()
            storage.append(action)
            lock.unlock()
        }

        var actions: [MediaKeyEvent.Action] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private func data1(key: Int, state: Int, repeat isRepeat: Bool = false) -> Int {
        (key << 16) | (state << 8) | (isRepeat ? 1 : 0)
    }

    func testActualReceiverDecodesPressesAndRunsOnceUntilRelease() {
        let recorder = ActionRecorder()
        let manager = GlobalShortcutManager(
            play: { recorder.append(.togglePlayPause) },
            pause: {},
            next: { recorder.append(.next) },
            previous: { recorder.append(.previous) }
        )

        XCTAssertTrue(manager.handleSystemDefinedEvent(subtype: 8, data1: data1(key: 16, state: 10)))
        XCTAssertFalse(manager.handleSystemDefinedEvent(subtype: 8, data1: data1(key: 16, state: 10)),
                         "duplicate down must not toggle twice")
        XCTAssertFalse(manager.handleSystemDefinedEvent(subtype: 8, data1: data1(key: 16, state: 10, repeat: true)),
                         "hardware repeat must not toggle")
        XCTAssertFalse(manager.handleSystemDefinedEvent(subtype: 8, data1: data1(key: 16, state: 11)),
                         "release clears the held key without running an action")
        XCTAssertTrue(manager.handleSystemDefinedEvent(subtype: 8, data1: data1(key: 16, state: 10)))
        XCTAssertFalse(manager.handleSystemDefinedEvent(subtype: 8, data1: data1(key: 16, state: 11)))

        XCTAssertTrue(manager.handleSystemDefinedEvent(subtype: 8, data1: data1(key: 17, state: 10)))
        XCTAssertFalse(manager.handleSystemDefinedEvent(subtype: 8, data1: data1(key: 17, state: 11)))
        XCTAssertTrue(manager.handleSystemDefinedEvent(subtype: 8, data1: data1(key: 18, state: 10)))
        XCTAssertFalse(manager.handleSystemDefinedEvent(subtype: 8, data1: data1(key: 18, state: 11)))

        XCTAssertEqual(recorder.actions, [.togglePlayPause, .togglePlayPause, .next, .previous])
    }

    func testUnknownEventsAreIgnoredByTheActualReceiver() {
        let recorder = ActionRecorder()
        let manager = GlobalShortcutManager(
            play: { recorder.append(.togglePlayPause) }, pause: {},
            next: { recorder.append(.next) }, previous: { recorder.append(.previous) }
        )

        XCTAssertFalse(manager.handleSystemDefinedEvent(subtype: 7, data1: data1(key: 16, state: 10)))
        XCTAssertFalse(manager.handleSystemDefinedEvent(subtype: 8, data1: data1(key: 42, state: 10)))
        XCTAssertFalse(manager.handleSystemDefinedEvent(subtype: 8, data1: data1(key: 16, state: 9)))
        XCTAssertTrue(recorder.actions.isEmpty)
    }

    func testRemoteCommandCenterModeDisablesEventMonitorChannel() {
        let recorder = ActionRecorder()
        let manager = GlobalShortcutManager(
            play: { recorder.append(.togglePlayPause) }, pause: {},
            next: { recorder.append(.next) }, previous: { recorder.append(.previous) },
            mediaKeySource: .remoteCommandCenter
        )

        manager.start()
        XCTAssertFalse(manager.handleSystemDefinedEvent(subtype: 8, data1: data1(key: 16, state: 10)))
        XCTAssertFalse(manager.handleSystemDefinedEvent(subtype: 8, data1: data1(key: 17, state: 10)))
        XCTAssertTrue(recorder.actions.isEmpty, "MPRemoteCommandCenter is the sole production media-key source")
    }
}
