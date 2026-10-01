// ListenTogetherSettingsView.swift
// M8-T7: room create/join controls for the official ListenTogether Worker.
import SwiftUI

struct ListenTogetherSettingsView: View {
    @ObservedObject var model: ListenTogetherViewModel

    var body: some View {
        Section("一起听") {
            TextField("Worker 地址", text: $model.baseURL)
            TextField("昵称", text: $model.nickname)
            if model.room == nil {
                HStack {
                    TextField("房间号", text: $model.roomID)
                    SecureField("加入密钥（可选）", text: $model.joinSecret)
                }
                HStack {
                    Button("创建房间") { model.createRoom() }
                    Button("加入房间") { model.joinRoom() }
                }
            } else {
                HStack {
                    Label("房间 \(model.roomID)", systemImage: "person.2")
                    Spacer()
                    Button("离开") { model.leaveRoom() }
                }
                Text("成员 \(model.room?.members.count ?? 0) · 版本 \(model.room?.version ?? 0)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.isBusy { ProgressView().controlSize(.small) }
            if let message = model.statusMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("只分享在线音源标识，不分享本地文件。真实两台设备互通和 Worker 配置需要手动验收。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
