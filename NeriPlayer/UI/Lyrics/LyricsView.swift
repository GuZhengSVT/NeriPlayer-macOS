// LyricsView.swift
// M4-T4/T5: scrolling lyrics, syllable highlighting and playback controls.
import AppKit
import SwiftUI

struct LyricsView: View {
    @ObservedObject var model: LyricsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settingsPresented = false
    @State private var sharePresented = false
    @State private var followPlayback = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            playbackControls
        }
        .frame(minWidth: 560, idealWidth: 700, minHeight: 460, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $settingsPresented) { LyricsPreferencesView(model: model) }
        .sheet(isPresented: $sharePresented) { LyricsShareView(model: model) }
        .onChange(of: model.snapshot?.currentTrack?.id) { _ in followPlayback = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Image(systemName: "chevron.down") }
                .help("关闭歌词")
            VStack(alignment: .leading, spacing: 3) {
                Text(model.snapshot?.currentTrack?.title ?? "歌词").font(.headline).lineLimit(1)
                Text(model.snapshot?.currentTrack?.artist ?? "未知歌手").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !followPlayback {
                Button { followPlayback = true } label: { Image(systemName: "scope") }.help("跟随播放")
            }
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }.help("重新加载歌词")
            Button { sharePresented = true } label: { Image(systemName: "square.and.arrow.up") }
                .help("导出歌词卡片")
                .disabled(model.document == nil)
            Button { settingsPresented = true } label: { Image(systemName: "slider.horizontal.3") }.help("歌词设置与来源")
        }
        .buttonStyle(.borderless)
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let document = model.document, !document.lyrics.lines.isEmpty {
            ScrollViewReader { proxy in
                TimelineView(.animation(minimumInterval: 1 / 60, paused: model.snapshot?.isPaused != false)) { context in
                    let state = model.timeline.state(at: model.playbackSeconds(at: context.date), offsetMilliseconds: model.totalOffset)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            ForEach(Array(document.lyrics.lines.enumerated()), id: \.offset) { index, line in
                                Button { model.seek(to: line); followPlayback = true } label: {
                                    LyricsLineView(line: line, time: state.timeMilliseconds,
                                                   focused: state.focusedLineIndices.contains(index), fontSize: model.fontSize,
                                                   showTranslation: model.showTranslation, showPhonetic: model.showPhonetic,
                                                   phonetic: document.phoneticByLine[index])
                                        .blur(radius: model.blur && !state.focusedLineIndices.contains(index) ? 1.3 : 0)
                                        .frame(maxWidth: .infinity, alignment: line.alignment == .end ? .trailing : .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("跳转到 \(LyricsTime.formatted(line.start))")
                                .id(index)
                            }
                        }
                        .padding(.horizontal, 40)
                        .padding(.vertical, 150)
                    }
                    .background(LyricsScrollObserver { followPlayback = false })
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in followPlayback = false })
                    .mask(edgeFade)
                    .onChange(of: state.scrollLineIndex) { index in scroll(proxy, to: index) }
                    .onChange(of: followPlayback) { follows in if follows { scroll(proxy, to: state.scrollLineIndex) } }
                    .onAppear { scroll(proxy, to: state.scrollLineIndex) }
                }
            }
        } else if let document = model.document, !document.plainLines.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(document.plainLines.enumerated()), id: \.offset) { _, text in
                        Text(text).font(.system(size: model.fontSize)).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(40)
            }.mask(edgeFade)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "text.alignleft").font(.system(size: 32)).foregroundStyle(.secondary)
                Text(model.errorMessage ?? "暂无歌词").foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("歌词来源") { settingsPresented = true }
            }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var edgeFade: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                               .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    private func scroll(_ proxy: ScrollViewProxy, to index: Int?) {
        guard followPlayback, let index else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(index, anchor: .center) }
    }

    private var playbackControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(timeText(model.snapshot?.position ?? 0)).monospacedDigit().font(.caption)
                Slider(value: Binding(get: { model.snapshot?.position ?? 0 }, set: { model.seek(to: $0) }),
                       in: 0...max(1, model.snapshot?.duration ?? 1))
                    .disabled(model.snapshot?.currentTrack == nil).accessibilityLabel("播放进度")
                Text(timeText(model.snapshot?.duration ?? 0)).monospacedDigit().font(.caption)
            }
            HStack(spacing: 28) {
                Button { model.previous() } label: { Image(systemName: "backward.end.fill") }.help("上一首")
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.snapshot?.isPaused == false && model.snapshot?.isCoreIdle == false ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 30, height: 30)
                }.help("播放或暂停")
                Button { model.next() } label: { Image(systemName: "forward.end.fill") }.help("下一首")
            }.buttonStyle(.borderless)
        }.padding(16)
    }

    private func timeText(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? min(86_400, max(0, seconds)) : 0
        return String(format: "%d:%02d", Int(safe) / 60, Int(safe) % 60)
    }
}

private struct LyricsLineView: View {
    let line: LyricsLine
    let time: Int
    let focused: Bool
    let fontSize: Double
    let showTranslation: Bool
    let showPhonetic: Bool
    var phonetic: String?

    var body: some View {
        VStack(alignment: line.alignment == .end ? .trailing : .leading, spacing: 8) {
            if let karaoke = line.karaokeLine {
                KaraokeText(syllables: karaoke.syllables, time: time, focused: focused, fontSize: fontSize,
                            alignment: karaoke.alignment)
                if showPhonetic, let text = phonetic ?? karaoke.phonetic ?? syllablePhonetic(karaoke.syllables), !text.isEmpty {
                    Text(text).font(.system(size: fontSize * 0.5)).foregroundStyle(.secondary)
                }
            } else {
                Text(line.content).font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(focused ? Color.accentColor : Color.primary.opacity(0.45))
                if showPhonetic, let phonetic, !phonetic.isEmpty {
                    Text(phonetic).font(.system(size: fontSize * 0.5)).foregroundStyle(.secondary)
                }
            }
            if showTranslation, let translation = line.translation, !translation.isEmpty {
                Text(translation).font(.system(size: fontSize * 0.6)).foregroundStyle(focused ? .primary : .secondary)
            }
            if case .main(let main) = line, let accompaniment = main.accompanimentLines {
                ForEach(Array(accompaniment.enumerated()), id: \.offset) { _, background in
                    KaraokeText(syllables: background.syllables, time: time, focused: background.isFocused(current: time),
                                fontSize: fontSize * 0.65, alignment: background.alignment)
                    if showPhonetic, let text = background.phonetic ?? syllablePhonetic(background.syllables), !text.isEmpty {
                        Text(text).font(.system(size: fontSize * 0.45)).foregroundStyle(.secondary)
                    }
                    if showTranslation, let translation = background.translation {
                        Text(translation).font(.system(size: fontSize * 0.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(line.alignment == .end ? .trailing : .leading)
    }

    private func syllablePhonetic(_ syllables: [KaraokeSyllable]) -> String? {
        let text = syllables.joinedPhonetic.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
