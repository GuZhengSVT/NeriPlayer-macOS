// LyricsShareView.swift
// M4-T6: select lyric lines, preview a 1080px card and save or copy PNG.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LyricsShareView: View {
    @ObservedObject var model: LyricsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<Int>()
    @State private var preview: NSImage?
    @State private var png: Data?
    @State private var status: String?

    private var lines: [LyricsLine] {
        guard let document = model.document else { return [] }
        if !document.lyrics.lines.isEmpty { return document.lyrics.lines }
        return document.plainLines.map { .synced(SyncedLine(content: $0, start: 0, end: 0)) }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("歌词卡片").font(.headline)
                Spacer()
                Text("\(selected.count) / 6").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 20) {
                List {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        if !line.trimmedContent.isEmpty {
                            Toggle(isOn: Binding(get: { selected.contains(index) }, set: { toggle(index, enabled: $0) })) {
                                Text(line.content).lineLimit(3)
                            }
                            .disabled(!selected.contains(index) && selected.count >= 6)
                        }
                    }
                }.frame(width: 270, height: 320)
                Group {
                    if let preview { Image(nsImage: preview).resizable().scaledToFit() } else { ProgressView() }
                }.frame(width: 270, height: 320)
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button { save() } label: { Label("保存 PNG", systemImage: "square.and.arrow.down") }.disabled(png == nil)
                Button { copy() } label: { Label("复制图片", systemImage: "doc.on.doc") }.disabled(png == nil)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 610)
        .onAppear {
            let focus = model.timeline.state(at: model.playbackSeconds(), offsetMilliseconds: model.totalOffset).scrollLineIndex
            let valid = lines.indices.filter { !lines[$0].trimmedContent.isEmpty }
            if let focus, valid.contains(focus) { selected = [focus] } else if let first = valid.first { selected = [first] }
            updatePreview()
        }
        .onChange(of: model.snapshot?.currentTrack?.id) { _ in dismiss() }
    }

    private func toggle(_ index: Int, enabled: Bool) {
        if enabled, selected.count < 6 { selected.insert(index) } else if !enabled, selected.count > 1 { selected.remove(index) }
        updatePreview()
    }

    private func updatePreview() {
        do {
            let chosen = selected.sorted().compactMap { lines.indices.contains($0) ? lines[$0] : nil }
            let data = try LyricsCardExporter.pngData(title: model.snapshot?.currentTrack?.title ?? "歌词",
                                                      artist: model.snapshot?.currentTrack?.artist, lines: chosen,
                                                      showTranslation: model.showTranslation)
            png = data
            preview = NSImage(data: data)
            status = nil
        } catch {
            png = nil
            preview = nil
            status = error.localizedDescription
        }
    }

    private func save() {
        guard let png else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "歌词卡片.png"
        panel.allowedContentTypes = [.png]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url, options: .atomic)
            Log.ui.info("歌词卡片已保存：\(url.lastPathComponent, privacy: .public)")
            status = "已保存：\(url.lastPathComponent)"
        } catch { status = error.localizedDescription }
    }

    private func copy() {
        guard let png else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setData(png, forType: .png) { status = "已复制到剪贴板" } else { status = "复制失败" }
    }
}
