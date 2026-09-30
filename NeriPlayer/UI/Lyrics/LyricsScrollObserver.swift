// LyricsScrollObserver.swift
// M4: mouse-wheel and trackpad scrolling suspend automatic lyric following.
import AppKit
import SwiftUI

struct LyricsScrollObserver: NSViewRepresentable {
    var onScroll: () -> Void

    func makeNSView(context: Context) -> ScrollObserverView {
        let view = ScrollObserverView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: ScrollObserverView, context: Context) { view.onScroll = onScroll }
    static func dismantleNSView(_ view: ScrollObserverView, coordinator: ()) { view.stop() }
}

final class ScrollObserverView: NSView {
    var onScroll: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  event.scrollingDeltaY != 0 else { return event }
            onScroll?()
            return event
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
