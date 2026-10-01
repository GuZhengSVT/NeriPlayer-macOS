// AudioEffectController.swift
// M8-T4/T6: typed settings UI bridge and application to the live libmpv engine.
import Combine
import Foundation

public protocol AudioEffectApplying: AnyObject {
    func applyAudioEffects(_ settings: AudioEffectSettings)
}

extension PlaybackStateStore: AudioEffectApplying {
    public func applyAudioEffects(_ settings: AudioEffectSettings) {
        applyAudioEffectsToEngine(settings)
    }
}

@MainActor
public final class AudioEffectsViewModel: ObservableObject {
    @Published public private(set) var settings: AudioEffectSettings
    private let store: SettingsStore
    private let apply: @MainActor (AudioEffectSettings) -> Void

    public init(settingsStore: SettingsStore = .shared,
                apply: @escaping @MainActor (AudioEffectSettings) -> Void = { _ in }) {
        self.store = settingsStore; self.apply = apply
        let data = settingsStore.value(for: SettingsKeys.audioEffects)
        self.settings = (try? JSONDecoder().decode(AudioEffectSettings.self, from: data)) ?? .default
    }

    public func setEnabled(_ value: Bool) { mutate { $0.enabled = value } }
    public func setLoudnessEnabled(_ value: Bool) { mutate { $0.loudnessEnabled = value } }
    public func setLoudnessGain(_ value: Double) { mutate { $0.loudnessGain = min(15, max(0, value)) } }
    public func setFadeIn(_ value: Double) { mutate { $0.fadeInMilliseconds = AudioEffectSettings.clampMilliseconds(Int(value)) } }
    public func setFadeOut(_ value: Double) { mutate { $0.fadeOutMilliseconds = AudioEffectSettings.clampMilliseconds(Int(value)) } }
    public func setCrossfade(_ value: Double) { mutate { $0.crossfadeMilliseconds = AudioEffectSettings.clampMilliseconds(Int(value)) } }
    public func setExclusiveOutput(_ value: Bool) { mutate { $0.exclusiveOutput = value } }

    public func setPreset(_ preset: EqualizerPreset) { mutate { $0.applyPreset(preset); $0.enabled = true } }

    public func setBand(_ index: Int, gain: Double) {
        guard settings.bands.indices.contains(index) else { return }
        mutate { $0.bands[index].gain = AudioEffectSettings.clampGain(gain); $0.preset = .flat }
    }

    private func mutate(_ body: (inout AudioEffectSettings) -> Void) {
        var next = settings; body(&next); settings = next
        if let data = try? JSONEncoder().encode(next) { store.set(data, for: SettingsKeys.audioEffects) }
        apply(next)
    }
}
