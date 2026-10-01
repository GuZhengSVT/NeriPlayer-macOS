// AudioOutputRecovery.swift
// M8-T6: pure watchdog policy for recovering a failed exclusive output.
import Foundation

public enum AudioOutputRecoveryAction: Equatable, Sendable {
    case none
    case retryExclusive
    case fallbackToShared
}

public struct AudioOutputWatchdog: Sendable {
    public private(set) var consecutiveFailures = 0
    public let retryLimit: Int

    public init(retryLimit: Int = 2) {
        self.retryLimit = max(0, retryLimit)
    }

    public mutating func recordSuccess() -> AudioOutputRecoveryAction {
        consecutiveFailures = 0
        return .none
    }

    public mutating func recordFailure(exclusive: Bool) -> AudioOutputRecoveryAction {
        guard exclusive else { return .none }
        consecutiveFailures += 1
        return consecutiveFailures > retryLimit ? .fallbackToShared : .retryExclusive
    }
}
