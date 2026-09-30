// LyricsPreferencesView.swift
// M4: lyric typography, timing and explicit Netease association controls.
import SwiftUI

struct LyricsPreferencesView: View {
    @ObservedObject var model: LyricsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var songID = ""
    @State private var validation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("歌词设置").font(.headline)
            Form {
                LabeledContent("字号") {
                    Slider(value: Binding(get: { model.fontSize }, set: model.setFontSize), in: 16...44, step: 1)
                    Text("\(Int(model.fontSize))").monospacedDigit().frame(width: 28)
                }
                Toggle("模糊非当前行", isOn: Binding(get: { model.blur }, set: model.setBlur))
                Toggle("翻译", isOn: Binding(get: { model.showTranslation }, set: model.setTranslation))
                Toggle("音译", isOn: Binding(get: { model.showPhonetic }, set: model.setPhonetic))
                LabeledContent("偏移（毫秒）") {
                    Stepper(value: Binding(get: { model.offsetMilliseconds }, set: model.setOffset), in: -60_000...60_000, step: 100) {
                        Text("\(model.offsetMilliseconds > 0 ? "+" : "")\(model.offsetMilliseconds)").monospacedDigit()
                    }
                    Button { model.setOffset(0) } label: { Image(systemName: "arrow.uturn.backward") }.help("重置歌词偏移")
                }
                TextField("网易云歌曲 ID", text: $songID).onSubmit(associate)
                if let validation { Text(validation).foregroundStyle(.red).font(.caption) }
                HStack {
                    Button("关联", action: associate).disabled(model.snapshot?.currentTrack == nil)
                    Button("解除关联") { songID = ""; associate() }.disabled(model.neteaseSongID.isEmpty)
                    Spacer()
                    if let source = model.document?.source { Text(source).font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 420)
        .onAppear { songID = model.neteaseSongID }
    }

    private func associate() {
        validation = model.associate(songID: songID) ? nil : "请输入有效的网易云歌曲 ID"
    }
}
