// LyricsPreferencesView.swift
// M4: lyric typography, timing and explicit Netease association controls.
// T06: 拆成「全局显示偏好」与「当前歌曲」两段 —— 前者未播放也能调整并即时生效，
// 后者（单曲偏移、网易云匹配）依赖当前曲目，没有曲目时整段禁用并说明原因。
//
// 需求 5：这里的「字体 / 字号」与「外观与个性化 → 字体与字号」是**同一份设置**
// （`SettingsKeys.lyricsFontFamily` / `lyricsFontSize`），两处改一处另一处跟着变。
// sheet 继承呈现方的环境，因此直接读根视图注入的 `appTypography` 即可。
import SwiftUI

struct LyricsPreferencesView: View {
    @ObservedObject var model: LyricsViewModel
    @Environment(\.dismiss) private var dismiss
    /// 当前字体设置（由根视图注入；sheet 会继承呈现方的环境）。
    @Environment(\.appTypography) private var typography
    @State private var songID = ""
    @State private var validation: String?
    /// 本机可用字体家族（需求 5）。打开设置时取一次。
    @State private var fontFamilies: [String] = []

    /// 是否有当前曲目。决定「当前歌曲」整段的可用性。
    private var hasTrack: Bool { model.snapshot?.currentTrack != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("歌词设置").font(typography.uiFont(size: 15, weight: .semibold))
            Form {
                Section("显示") {
                    Picker("字体", selection: Binding(get: { model.fontFamily }, set: model.setFontFamily)) {
                        Text(TypographyFontFamily.systemDisplayName).tag(TypographyFontFamily.systemID)
                        ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                        if model.fontFamily != TypographyFontFamily.systemID,
                           !fontFamilies.contains(model.fontFamily) {
                            Text("\(model.fontFamily)（本机不可用）").tag(model.fontFamily)
                        }
                    }
                    LabeledContent("字号") {
                        Slider(value: Binding(get: { model.fontSize }, set: model.setFontSize),
                               in: AppTypographyDefaults.lyricsBaseSizeRange, step: 1)
                        Text("\(Int(model.fontSize))").monospacedDigit().frame(width: 28)
                    }
                    Text("歌词字体与字号和「外观与个性化」里的设置是同一个值，两边修改都会同步；底部歌词字号也在那里设置。")
                        .font(typography.uiFont(size: 11)).foregroundStyle(.secondary)
                    Toggle("模糊非当前行", isOn: Binding(get: { model.blur }, set: model.setBlur))
                    Toggle("翻译", isOn: Binding(get: { model.showTranslation }, set: model.setTranslation))
                    Toggle("音译", isOn: Binding(get: { model.showPhonetic }, set: model.setPhonetic))
                }
                Section("当前歌曲") {
                    if !hasTrack {
                        Text("播放一首歌后可设置单曲歌词偏移，并手动关联网易云歌曲 ID。")
                            .font(typography.uiFont(size: 11)).foregroundStyle(.secondary)
                    }
                    LabeledContent("偏移（毫秒）") {
                        Stepper(value: Binding(get: { model.offsetMilliseconds }, set: model.setOffset), in: -60_000...60_000, step: 100) {
                            Text("\(model.offsetMilliseconds > 0 ? "+" : "")\(model.offsetMilliseconds)").monospacedDigit()
                        }
                        Button { model.setOffset(0) } label: { Image(systemName: "arrow.uturn.backward") }.help("重置歌词偏移")
                    }
                    .disabled(!hasTrack)
                    TextField("网易云歌曲 ID", text: $songID).onSubmit(associate).disabled(!hasTrack)
                    if let validation {
                        Text(validation).foregroundStyle(.red)
                            .font(typography.uiFont(size: 11))
                    }
                    HStack {
                        Button("关联", action: associate).disabled(!hasTrack)
                        Button("解除关联") { songID = ""; associate() }.disabled(!hasTrack || model.neteaseSongID.isEmpty)
                        Spacer()
                        if let source = model.document?.source {
                            Text(source).font(typography.uiFont(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 420)
        .onAppear {
            songID = model.neteaseSongID
            fontFamilies = TypographyFontFamily.availableFamilies()
        }
    }

    private func associate() {
        guard hasTrack else { validation = "请先播放一首歌再关联网易云歌曲 ID"; return }
        validation = model.associate(songID: songID) ? nil : "请输入有效的网易云歌曲 ID"
    }
}
