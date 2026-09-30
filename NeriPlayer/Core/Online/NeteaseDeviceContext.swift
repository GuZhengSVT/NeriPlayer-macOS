// NeteaseDeviceContext.swift
// Official web-provided QR device context, acquired in an isolated ephemeral WebKit session.
// The site's own SDK produces the token; this client never fabricates identifiers or challenge results.
import Foundation
import WebKit

struct NeteaseDeviceSnapshot: Sendable {
    var token: String
    var deviceID: String
    var cookies: [String: String]
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0"
}

protocol NeteaseDeviceContextProviding: Sendable {
    func snapshot() async throws -> NeteaseDeviceSnapshot
}

struct OfficialNeteaseDeviceContextProvider: NeteaseDeviceContextProviding {
    func snapshot() async throws -> NeteaseDeviceSnapshot {
        let loader = await NeteaseDeviceContextLoader()
        return try await loader.load()
    }
}

@MainActor
private final class NeteaseDeviceContextLoader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<NeteaseDeviceSnapshot, Error>?
    private var timeout: Task<Void, Never>?
    private var evaluation: Task<Void, Never>?
    private var started = false

    func load() async throws -> NeteaseDeviceSnapshot {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 650), configuration: configuration)
                view.customUserAgent = NeteaseDeviceSnapshot.desktopUserAgent
                view.navigationDelegate = self
                webView = view
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 35_000_000_000) } catch { return }
                    self?.finish(.failure(OnlineError.unavailable("网易云官方设备验证超时，请检查网络后重新生成二维码")))
                }
                guard let url = URL(string: "https://music.163.com/") else { finish(.failure(OnlineError.invalidResponse)); return }
                Log.net.info("加载网易云官方网页登录设备上下文")
                view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !started, continuation != nil else { return }
        started = true
        evaluation = Task { [weak self] in
            guard let self else { return }
            do {
                try validateOrigin(webView.url)
                let javascript = """
                const deadline = Date.now() + 12000;
                while (typeof window.createNEFingerprint !== "function") {
                  if (Date.now() >= deadline) throw new Error("official device SDK unavailable");
                  await new Promise(resolve => setTimeout(resolve, 400));
                }
                const sdk = window.createNEFingerprint({appId: "9d0ef7e0905d422cba1ecf7e73d77e67", timeout: 6000});
                const result = await Promise.race([
                  sdk.getToken(),
                  new Promise((_, reject) => setTimeout(() => reject(new Error("device token timeout")), 12000))
                ]);
                return {token: result && typeof result.token === "string" ? result.token : ""};
                """
                let result: Any = try await withCheckedThrowingContinuation { continuation in
                    webView.callAsyncJavaScript(javascript, arguments: [:], in: nil, in: .page) { result in
                        continuation.resume(with: result)
                    }
                }
                try Task.checkCancellation()
                try validateOrigin(webView.url)
                guard let result = result as? [String: Any], let token = result["token"] as? String,
                      !token.isEmpty, token.utf8.count <= 65_536 else {
                    throw OnlineError.unavailable("网易云官方网页未返回设备验证凭据，请稍后重试")
                }
                let allCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                var cookies: [String: String] = [:]
                for cookie in allCookies {
                    let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    guard domain == "music.163.com" || domain.hasSuffix(".music.163.com"),
                          cookie.expiresDate.map({ $0 > Date() }) ?? true else { continue }
                    cookies[cookie.name] = cookie.value
                }
                guard let deviceID = cookies["sDeviceId"], !deviceID.isEmpty, deviceID.utf8.count <= 512 else {
                    throw OnlineError.unavailable("网易云官方网页未建立设备会话，请稍后重试")
                }
                Log.net.info("网易云官方设备上下文已就绪")
                finish(.success(NeteaseDeviceSnapshot(token: token, deviceID: deviceID, cookies: cookies)))
            } catch is CancellationError { finish(.failure(CancellationError())) } catch let error as OnlineError {
                finish(.failure(error))
            } catch {
                Log.net.error("网易云官方设备 SDK 获取失败")
                finish(.failure(OnlineError.unavailable("网易云官方设备验证未完成，请检查网络后重试")))
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(OnlineError.unavailable("网易云官方设备页面加载失败")))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(OnlineError.unavailable("网易云官方设备页面连接失败，请检查网络")))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(OnlineError.unavailable("网易云设备验证页面已退出，请重新生成二维码")))
    }
    private func validateOrigin(_ url: URL?) throws {
        guard url?.scheme == "https", url?.host == "music.163.com" else { throw OnlineError.invalidResponse }
    }
    private func finish(_ result: Result<NeteaseDeviceSnapshot, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        evaluation?.cancel(); evaluation = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading(); webView = nil
        continuation.resume(with: result)
    }
}
