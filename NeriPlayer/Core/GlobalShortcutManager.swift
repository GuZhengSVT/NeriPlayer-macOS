// GlobalShortcutManager.swift
// M8-T8: application-level media shortcuts. Global registration is intentionally opt-in
// through NSEvent so the app can run without an accessibility entitlement.
import AppKit
import Foundation

public final class GlobalShortcutManager: @unchecked Sendable {
    public typealias Action = @Sendable () -> Void
    private var monitor: Any?
    private let play: Action
    private let pause: Action
    private let next: Action
    private let previous: Action

    public init(play: @escaping Action, pause: @escaping Action, next: @escaping Action, previous: @escaping Action) {
        self.play = play; self.pause = pause; self.next = next; self.previous = previous
    }

    deinit { stop() }

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self, event.subtype.rawValue == 8 else { return }
            let key = (event.data1 >> 16) & 0xF
            switch key {
            case 16: self.play()
            case 17: self.pause()
            case 18: self.next()
            case 19: self.previous()
            default: break
            }
        }
    }

    public func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
