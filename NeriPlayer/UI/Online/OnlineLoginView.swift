// OnlineLoginView.swift
// M5: platform QR login, explicit Cookie import and Keychain sign-out.
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct OnlineLoginView: View {
    @ObservedObject var viewModel: OnlineViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var cookie = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(viewModel.source.title).font(.title2); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.help("关闭") }
            if let account = viewModel.account {
                HStack { Label(account.name, systemImage: "person.crop.circle"); Spacer(); Button("退出登录", role: .destructive) { viewModel.signOut() } }
            }
            if viewModel.supportsQR {
                HStack(alignment: .top, spacing: 20) {
                    Group {
                        if let ticket = viewModel.loginTicket, let image = qrImage(ticket.url.absoluteString) {
                            Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                        } else {
                            Rectangle().fill(Color.secondary.opacity(0.06))
                                .overlay(Image(systemName: "qrcode").font(.system(size: 48)).foregroundStyle(.secondary))
                        }
                    }.frame(width: 180, height: 180)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(loginStatus).font(.headline)
                        Button { viewModel.beginQRLogin() } label: { Label("生成二维码", systemImage: "qrcode") }
                            .disabled(viewModel.isLoggingIn && viewModel.loginTicket == nil)
                        if viewModel.isLoggingIn { ProgressView().controlSize(.small) }
                    }
                }
            }
            if viewModel.supportsCookieImport {
                Text("Cookie").font(.headline)
                TextEditor(text: $cookie).font(.system(.caption, design: .monospaced)).frame(height: 130)
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.2)))
                HStack {
                    Button {
                        if let text = NSPasteboard.general.string(forType: .string) { cookie = text }
                    } label: { Label("粘贴", systemImage: "doc.on.clipboard") }
                    Button {
                        if viewModel.importCookies(cookie) { cookie = "" }
                    } label: { Label("导入", systemImage: "square.and.arrow.down") }.disabled(cookie.isEmpty)
                }
            }
            if let message = viewModel.loginMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(20).frame(width: 500)
        .onDisappear { cookie = ""; viewModel.stopLogin() }
    }
    private var loginStatus: String {
        switch viewModel.loginState {
        case .waiting: return "等待扫码"
        case .scanned: return "等待确认"
        case .authorized: return "登录成功"
        case .expired: return "二维码已过期"
        case nil:
            if viewModel.isLoggingIn { return "正在准备登录" }
            return viewModel.loginMessage == nil ? "扫码登录" : "登录失败"
        }
    }
    private func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let context = CIContext()
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
