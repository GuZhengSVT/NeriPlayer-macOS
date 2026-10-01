// AboutView.swift
// M9-T1/T3: About window and user-visible diagnostic export.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AboutView: View {
    @State private var showingDiagnostics = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text(AppInfo.displayName)
                .font(.title)
                .fontWeight(.semibold)
            Text("版本 \(AppInfo.versionString)")
                .foregroundStyle(.secondary)
            Text("原生 macOS 音乐播放器")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("开源移植实验")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("诊断信息") { showingDiagnostics = true }
            }
        }
        .padding(28)
        .frame(width: 360)
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsView()
        }
    }
}

struct DiagnosticsView: View {
    @State private var text = CrashReporter.shared.diagnosticText()
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("诊断信息")
                .font(.title2)
                .fontWeight(.semibold)
            Text("导出内容只包含版本、系统与崩溃记录，不包含音频、账号或令牌。")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .border(.separator)
            HStack {
                Button("刷新") { text = CrashReporter.shared.diagnosticText() }
                Button("导出…") { export() }
                    .keyboardShortcut("s", modifiers: [.command])
                Spacer()
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NeriPlayer-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CrashReporter.shared.exportDiagnostics(to: url)
            status = "已导出"
        } catch {
            status = "导出失败：\(error.localizedDescription)"
        }
    }
}
