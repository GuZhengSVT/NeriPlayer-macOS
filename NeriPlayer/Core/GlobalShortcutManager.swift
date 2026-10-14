// GlobalShortcutManager.swift
// A standalone NSEvent media-key receiver. In the application, NowPlayingController
// owns media keys through MPRemoteCommandCenter; choose one source to avoid double actions.
import AppKit
import Foundation

/// NX_SYSDEFINED / subtype 8 carries a 16-bit key code and 16-bit flags.
/// Values follow IOKit/hidsystem/ev_keymap.h and IOLLEvent.h.
struct MediaKeyEvent: Equatable {
    enum Action: Equatable { case togglePlayPause, next, previous }
    enum State: Equatable { case down, up }

    let keyCode: Int
    let action: Action
    let state: State
    let isRepeat: Bool

    static func decode(subtype: Int, data1: Int) -> MediaKeyEvent? {
        guard subtype == 8 else { return nil }
        let bits = UInt32(truncatingIfNeeded: data1)
        let keyCode = Int((bits >> 16) & 0xFFFF)
        let action: Action
        switch keyCode {
        case 16: action = .togglePlayPause // NX_KEYTYPE_PLAY
        case 17, 19: action = .next        // NX_KEYTYPE_NEXT / FAST
        case 18, 20: action = .previous    // NX_KEYTYPE_PREVIOUS / REWIND
        default: return nil
        }
        let state: State
        switch (bits >> 8) & 0xFF {
        case 10: state = .down // NX_KEYDOWN
        case 11: state = .up   // NX_KEYUP
        default: return nil
        }
        return MediaKeyEvent(keyCode: keyCode, action: action, state: state, isRepeat: bits & 1 != 0)
    }
}

/// Release clears the held key; repeats and duplicate down events do not execute again.
struct MediaKeyPressFilter {
    private var heldKeys: Set<Int> = []

    mutating func consume(_ event: MediaKeyEvent) -> MediaKeyEvent.Action? {
        if event.state == .up {
            heldKeys.remove(event.keyCode)
            return nil
        }
        guard !event.isRepeat, heldKeys.insert(event.keyCode).inserted else { return nil }
        return event.action
    }
}

public final class GlobalShortcutManager: @unchecked Sendable {
    public typealias Action = @Sendable () -> Void
    public enum MediaKeySource {
        case eventMonitor
        case remoteCommandCenter
    }

    private var monitor: Any?
    private let lock = NSLock()
    private var pressFilter = MediaKeyPressFilter()
    private let play: Action
    private let next: Action
    private let previous: Action
    private let mediaKeySource: MediaKeySource

    /// `play` is the physical Play/Pause key's toggle action. `pause` is retained for
    /// source compatibility; macOS has no separate pause key in this event family.
    public init(
        play: @escaping Action,
        pause: @escaping Action,
        next: @escaping Action,
        previous: @escaping Action,
        mediaKeySource: MediaKeySource = .eventMonitor
    ) {
        self.play = play
        self.next = next
        self.previous = previous
        self.mediaKeySource = mediaKeySource
    }

    deinit { stop() }

    public func start() {
        guard mediaKeySource == .eventMonitor, monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleSystemDefinedEvent(subtype: Int(event.subtype.rawValue), data1: event.data1)
        }
    }

    /// Same receiving path as the monitor, separable from hardware delivery in tests.
    @discardableResult
    func handleSystemDefinedEvent(subtype: Int, data1: Int) -> Bool {
        guard mediaKeySource == .eventMonitor,
              let event = MediaKeyEvent.decode(subtype: subtype, data1: data1) else { return false }
        lock.lock()
        let action = pressFilter.consume(event)
        lock.unlock()
        guard let action else { return false }
        switch action {
        case .togglePlayPause: play()
        case .next: next()
        case .previous: previous()
        }
        return true
    }

    public func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        lock.lock()
        pressFilter = MediaKeyPressFilter()
        lock.unlock()
    }
}
