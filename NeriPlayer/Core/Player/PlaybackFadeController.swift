// PlaybackFadeController.swift
// M8-T4: cancellation-safe sequential volume ramps using the Android 40 ms step policy.
import Foundation

public protocol PlaybackVolumeSink: Sendable {
    func setPlaybackVolume(_ volume: Double)
}

public final class PlaybackFadeController: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: any PlaybackVolumeSink
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var baseVolume: Double

    public init(sink: any PlaybackVolumeSink, baseVolume: Double = 70) {
        self.sink = sink; self.baseVolume = min(100, max(0, baseVolume))
    }

    deinit { cancel(restoreBase: false) }

    public func updateBaseVolume(_ value: Double) {
        lock.lock(); baseVolume = min(100, max(0, value)); lock.unlock()
    }

    public func cancel(restoreBase: Bool = true) {
        lock.lock(); task?.cancel(); task = nil; generation = UUID(); let volume = baseVolume; lock.unlock()
        if restoreBase { sink.setPlaybackVolume(volume) }
    }

    private func isCurrent(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token
    }

    public func fade(to target: Double, durationMilliseconds: Int) {
        lock.lock()
        task?.cancel()
        generation = UUID()
        let token = generation
        let start = baseVolume
        let end = min(100, max(0, target))
        let steps = min(30, max(4, durationMilliseconds / 40))
        let delay = max(1, durationMilliseconds / steps)
        task = Task { [weak self, sink] in
            for step in 1...steps {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self else { return }
                guard self.isCurrent(token) else { return }
                let fraction = Double(step) / Double(steps)
                sink.setPlaybackVolume(start + (end - start) * fraction)
            }
        }
        lock.unlock()
    }
}

extension PlaybackStateStore: PlaybackVolumeSink {
    /// 淡入淡出走瞬时路径（setTransientVolume），不改写用户的应用音量，也不发布快照 ——
    /// 逐帧的包络值不应被界面音量条回读，更不该在用户松手后覆盖其设定。
    public func setPlaybackVolume(_ volume: Double) { setTransientVolume(volume) }
}
