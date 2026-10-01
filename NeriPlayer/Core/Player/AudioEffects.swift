// AudioEffects.swift
// M8-T4/T6: typed audio-effect settings and the libmpv command plan.
import Foundation

public struct EqualizerBand: Codable, Equatable, Sendable {
    public let frequency: Double
    public var gain: Double
    public let q: Double

    public init(frequency: Double, gain: Double = 0, q: Double = 1) {
        self.frequency = frequency
        self.gain = gain
        self.q = q
    }
}

public enum EqualizerPreset: String, Codable, CaseIterable, Sendable {
    case flat, acoustic, bassBoost, classical, dance, electronic, hipHop, jazz, rock, vocal

    public var title: String {
        switch self {
        case .flat: return "平直"
        case .acoustic: return "原声"
        case .bassBoost: return "低音增强"
        case .classical: return "古典"
        case .dance: return "舞曲"
        case .electronic: return "电子"
        case .hipHop: return "嘻哈"
        case .jazz: return "爵士"
        case .rock: return "摇滚"
        case .vocal: return "人声"
        }
    }

    public var gains: [Double] {
        switch self {
        case .flat: return Array(repeating: 0, count: 10)
        case .acoustic: return [4, 3, 2, 1, 0, 0, 1, 2, 3, 4]
        case .bassBoost: return [7, 6, 5, 3, 1, 0, 0, 0, 0, 0]
        case .classical: return [4, 3, 2, 0, -2, -2, 0, 2, 3, 4]
        case .dance: return [5, 4, 2, 0, 0, 1, 2, 3, 4, 5]
        case .electronic: return [4, 3, 1, 0, -2, 1, 3, 4, 3, 2]
        case .hipHop: return [5, 4, 2, 0, -1, 1, 2, 1, 3, 4]
        case .jazz: return [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]
        case .rock: return [5, 4, 3, 1, -1, -2, 1, 3, 4, 5]
        case .vocal: return [-2, -1, 0, 2, 4, 4, 3, 2, 0, -1]
        }
    }
}

public struct AudioEffectSettings: Codable, Equatable, Sendable {
    public static let frequencies = [31.5, 63.0, 125.0, 250.0, 500.0, 1_000.0, 2_000.0, 4_000.0, 8_000.0, 16_000.0]
    public static let `default` = AudioEffectSettings()

    public var enabled: Bool
    public var preset: EqualizerPreset
    public var bands: [EqualizerBand]
    public var loudnessEnabled: Bool
    public var loudnessGain: Double
    public var fadeInMilliseconds: Int
    public var fadeOutMilliseconds: Int
    public var crossfadeMilliseconds: Int
    public var exclusiveOutput: Bool
    public var outputDevice: String?

    public init(enabled: Bool = false, preset: EqualizerPreset = .flat,
                bands: [EqualizerBand] = AudioEffectSettings.frequencies.map { EqualizerBand(frequency: $0) },
                loudnessEnabled: Bool = false, loudnessGain: Double = 6,
                fadeInMilliseconds: Int = 0, fadeOutMilliseconds: Int = 0,
                crossfadeMilliseconds: Int = 0, exclusiveOutput: Bool = false,
                outputDevice: String? = nil) {
        self.enabled = enabled
        self.preset = preset
        self.bands = Self.normalizedBands(bands)
        self.loudnessEnabled = loudnessEnabled
        self.loudnessGain = Self.clampGain(loudnessGain)
        self.fadeInMilliseconds = Self.clampMilliseconds(fadeInMilliseconds)
        self.fadeOutMilliseconds = Self.clampMilliseconds(fadeOutMilliseconds)
        self.crossfadeMilliseconds = Self.clampMilliseconds(crossfadeMilliseconds)
        self.exclusiveOutput = exclusiveOutput
        self.outputDevice = outputDevice?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public mutating func applyPreset(_ preset: EqualizerPreset) {
        self.preset = preset
        let values = preset.gains
        bands = Self.frequencies.enumerated().map { index, frequency in
            EqualizerBand(frequency: frequency, gain: values[index])
        }
    }

    public static func normalizedBands(_ bands: [EqualizerBand]) -> [EqualizerBand] {
        Self.frequencies.enumerated().map { index, frequency in
            let source = bands.indices.contains(index) ? bands[index] : EqualizerBand(frequency: frequency)
            return EqualizerBand(frequency: frequency, gain: clampGain(source.gain), q: max(0.1, min(10, source.q)))
        }
    }

    public static func clampGain(_ value: Double) -> Double {
        value.isFinite ? min(15, max(-15, value)) : 0
    }

    public static func clampMilliseconds(_ value: Int) -> Int { min(30_000, max(0, value)) }
}

public enum AudioEffectCommand: Equatable, Sendable {
    case setFilter(String?)
    case setVolumeGain(Double)
    case setOutput(driver: String, device: String?)
}

public enum AudioEffectCommandPlan {
    public static func make(for settings: AudioEffectSettings) -> [AudioEffectCommand] {
        [
            .setFilter(settings.enabled ? filterString(for: settings) : nil),
            .setVolumeGain(settings.loudnessEnabled ? settings.loudnessGain : 0),
            .setOutput(driver: settings.exclusiveOutput ? "coreaudio_exclusive" : "coreaudio", device: settings.outputDevice)
        ]
    }

    public static func filterString(for settings: AudioEffectSettings) -> String {
        let maxBoost = settings.bands.map(\.gain).max() ?? 0
        let preGain = pow(10, -max(0, maxBoost) / 20)
        let bands = settings.bands.map {
            "equalizer=f=\($0.frequency):t=o:w=1:g=\($0.gain)"
        }.joined(separator: ",")
        return "@eq:lavfi=[volume=\(preGain),\(bands)]"
    }
}

public struct PlaybackFadePlan: Equatable, Sendable {
    public let fadeInMilliseconds: Int
    public let fadeOutMilliseconds: Int
    public let crossfadeMilliseconds: Int

    public init(settings: AudioEffectSettings) {
        fadeInMilliseconds = settings.fadeInMilliseconds
        fadeOutMilliseconds = settings.fadeOutMilliseconds
        crossfadeMilliseconds = settings.crossfadeMilliseconds
    }

    public func volume(at elapsedMilliseconds: Int, durationMilliseconds: Int?, base: Double = 100) -> Double {
        let safeBase = max(0, base)
        let elapsed = max(0, elapsedMilliseconds)
        var factor = 1.0
        if fadeInMilliseconds > 0 { factor = min(factor, Double(elapsed) / Double(fadeInMilliseconds)) }
        if let durationMilliseconds, fadeOutMilliseconds > 0 {
            let remaining = durationMilliseconds - elapsed
            if remaining < fadeOutMilliseconds { factor = min(factor, max(0, Double(remaining) / Double(fadeOutMilliseconds))) }
        }
        return safeBase * min(1, max(0, factor))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
