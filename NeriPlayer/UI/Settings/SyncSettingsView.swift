// SyncSettingsView.swift
// M7: compact native sync configuration and explicit backup restore confirmation.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SyncSettingsSections: View {
    @ObservedObject var viewModel: SyncViewModel
    var body: some View {
        Section("元数据同步") {
            Picker("服务", selection: $viewModel.configuration.provider) {
                Text("GitHub").tag(SyncConfiguration.Provider.github)
                Text("WebDAV").tag(SyncConfiguration.Provider.webdav)
            }.pickerStyle(.segmented)
            if viewModel.configuration.provider == .github {
                TextField("GitHub 用户名", text: $viewModel.configuration.githubOwner)
                TextField("仓库", text: $viewModel.configuration.githubRepository)
                SecureField("PAT / OAuth 访问令牌", text: $viewModel.secret)
            } else {
                TextField("快照文件 HTTPS 地址", text: $viewModel.configuration.webDAVURL)
                TextField("用户名", text: $viewModel.configuration.webDAVUsername)
                SecureField("密码", text: $viewModel.secret)
            }
            HStack {
                Button { viewModel.saveConfiguration() } label: { Label("保存配置", systemImage: "checkmark") }
                if viewModel.configuration.provider == .github {
                    Button { viewModel.createRepository() } label: { Label("创建私有仓库", systemImage: "lock.badge.plus") }
                }
                Spacer()
                if viewModel.isBusy { ProgressView().controlSize(.small) }
                Button { viewModel.synchronize() } label: { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
            }
        }.disabled(viewModel.isBusy)
        Section("本地备份") {
            HStack {
                Button { exportBackup() } label: { Label("导出备份", systemImage: "square.and.arrow.up") }
                Button { restoreBackup() } label: { Label("恢复备份", systemImage: "square.and.arrow.down") }
            }.disabled(viewModel.isBusy)
        }
        if let message = viewModel.statusMessage {
            Section {
                Text(message).textSelection(.enabled)
                ForEach(viewModel.conflicts, id: \.self) { Text($0).foregroundStyle(.secondary) }
            }
        }
    }
    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "NeriPlayer-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.exportBackup(to: url)
    }
    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let confirmation = NSAlert()
        confirmation.messageText = "恢复本地备份？"
        confirmation.informativeText = "当前设置、媒体库、歌单和播放统计将被备份替换。音频文件和登录凭据不会改变。"
        confirmation.alertStyle = .warning
        confirmation.addButton(withTitle: "恢复")
        confirmation.addButton(withTitle: "取消")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        viewModel.restoreBackup(from: url)
    }
}
