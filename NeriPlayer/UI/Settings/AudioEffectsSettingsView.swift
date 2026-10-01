// AudioEffectsSettingsView.swift
// M8-T4/T6: equalizer, loudness, fade and output controls.
import SwiftUI

struct AudioEffectsSettingsView: View {
    @ObservedObject var model: AudioEffectsViewModel

    var body: some View {
        Section("音效") {
            Toggle("启用十段均衡器", isOn: Binding(get: { model.settings.enabled }, set: model.setEnabled))
            Picker("预设", selection: Binding(get: { model.settings.preset }, set: model.setPreset)) {
                ForEach(EqualizerPreset.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            ForEach(Array(model.settings.bands.enumerated()), id: \.offset) { index, band in
                HStack {
                    Text(String(format: "%.0f Hz", band.frequency)).frame(width: 70, alignment: .leading)
                    Slider(value: Binding(get: { band.gain }, set: { model.setBand(index, gain: $0) }), in: -15...15, step: 0.5)
                    Text(String(format: "%+.1f dB", band.gain)).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
            }
            Toggle("响度增强", isOn: Binding(get: { model.settings.loudnessEnabled }, set: model.setLoudnessEnabled))
            if model.settings.loudnessEnabled {
                HStack {
                    Text("增益"); Slider(value: Binding(get: { model.settings.loudnessGain }, set: model.setLoudnessGain), in: 0...15, step: 0.5)
                    Text(String(format: "%.1f dB", model.settings.loudnessGain)).monospacedDigit()
                }
            }
            HStack {
                Text("淡入"); Slider(value: Binding(get: { Double(model.settings.fadeInMilliseconds) }, set: model.setFadeIn), in: 0...10_000, step: 100)
                Text("\(model.settings.fadeInMilliseconds) ms").monospacedDigit()
            }
            HStack {
                Text("淡出"); Slider(value: Binding(get: { Double(model.settings.fadeOutMilliseconds) }, set: model.setFadeOut), in: 0...10_000, step: 100)
                Text("\(model.settings.fadeOutMilliseconds) ms").monospacedDigit()
            }
            HStack {
                Text("顺次交叉淡变")
                Slider(value: Binding(get: { Double(model.settings.crossfadeMilliseconds) }, set: model.setCrossfade),
                       in: 0...10_000, step: 100)
                Text("\(model.settings.crossfadeMilliseconds) ms").monospacedDigit()
            }
            Toggle("CoreAudio 独占输出", isOn: Binding(get: { model.settings.exclusiveOutput }, set: model.setExclusiveOutput))
            Text("独占输出需要在真实 DAC 上验证设备占用与采样率切换。当前实现使用 libmpv coreaudio_exclusive。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
