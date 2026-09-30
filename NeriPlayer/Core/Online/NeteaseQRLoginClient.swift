// NeteaseQRLoginClient.swift
// NetEase web QR sessions: one scanlogin chain, transient cookies and verified credential commit.
// Behavioral reference: Android NeteaseQrLoginClient; no fabricated device tokens or risk-control bypass.
import Foundation

actor NeteaseQRLoginClient {
    private struct LoginContext {
        let key: String
        let chainID: String
        let deviceToken: String
        let originalCookies: String?
        let originalVersion: UUID?
    }
    private let session: URLSession
    private let sessions: OnlineSessionStore
    private let baseURL: URL
    private let deviceProvider: any NeteaseDeviceContextProviding
    private var context: LoginContext?
    private var cookies: [String: String] = [:]
    private var generation = UUID()
    private static let userAgent = NeteaseDeviceSnapshot.desktopUserAgent

    init(session: URLSession, sessions: OnlineSessionStore, baseURL: URL,
         deviceProvider: any NeteaseDeviceContextProviding = OfficialNeteaseDeviceContextProvider()) {
        self.session = session; self.sessions = sessions; self.baseURL = baseURL
        self.deviceProvider = deviceProvider
    }

    func begin() async throws -> QRLoginTicket {
        generation = UUID()
        let token = generation
        context = nil; cookies = [:]
        let original = try sessions.cookieHeader(for: .netease)
        let version = sessions.version(for: .netease)
        cookies = Self.cookiePairs(original ?? "").filter {
            !["MUSIC_U", "MUSIC_A", "__csrf"].contains($0.key)
        }
        let response = try await request("/weapi/login/qrcode/unikey", payload: ["type": 1, "noCheckToken": true], generation: token)
        guard response["code"] as? Int == 200,
              let key = response["unikey"] as? String ?? (response["data"] as? [String: Any])?["unikey"] as? String,
              !key.isEmpty, key.utf8.count <= 512 else { throw apiError(response) }
        let snapshot = try await deviceProvider.snapshot()
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard !snapshot.token.isEmpty, snapshot.token.utf8.count <= 65_536,
              !snapshot.deviceID.isEmpty, snapshot.deviceID.utf8.count <= 512 else {
            throw OnlineError.unavailable("网易云官方设备上下文不完整，无法生成登录二维码")
        }
        cookies.merge(snapshot.cookies.filter { !["MUSIC_U", "MUSIC_A"].contains($0.key) }) { _, new in new }
        let chainID = "v1_\(snapshot.deviceID)_web_login_\(Int64(Date().timeIntervalSince1970 * 1000))"
        var components = URLComponents(string: "https://music.163.com/st/platform/scanlogin")
        components?.queryItems = [URLQueryItem(name: "codekey", value: key), URLQueryItem(name: "chainId", value: chainID),
            URLQueryItem(name: "hdw_device", value: "web"), URLQueryItem(name: "hdw_appid", value: "web"), URLQueryItem(name: "hitExp", value: "1")]
        guard let url = components?.url else { throw OnlineError.invalidResponse }
        context = LoginContext(key: key, chainID: chainID, deviceToken: snapshot.token,
                               originalCookies: original, originalVersion: version)
        return QRLoginTicket(key: key, url: url)
    }

    func poll(_ ticket: QRLoginTicket) async throws -> QRLoginState {
        guard let context, context.key == ticket.key else { throw OnlineError.invalidInput("二维码已被替换，请重新生成") }
        let token = generation
        let response = try await request("/weapi/login/qrcode/client/login", payload: [
            "type": 1, "key": ticket.key, "noCheckToken": true, "ydDeviceToken": context.deviceToken
        ], headers: ["x-loginmethod": "QrCode", "x-login-chain-id": context.chainID], generation: token)
        let code = response["code"] as? Int ?? -1
        Log.net.info("网易云 QR 状态：code=\(code)")
        switch code {
        case 800: self.context = nil; cookies = [:]; return .expired
        case 801: return .waiting
        case 802: return .scanned
        case 803:
            if let header = response["cookie"] as? String, !header.isEmpty {
                cookies.merge(Self.cookiePairs(try OnlineSessionStore.normalizedCookieHeader(header, source: .netease))) { _, new in new }
            }
            var accountPayload: [String: Any] = ["noCheckToken": true]
            if let csrf = cookies["__csrf"], !csrf.isEmpty { accountPayload["csrf_token"] = csrf }
            let account = try await request("/weapi/w/nuser/account/get", payload: accountPayload, generation: token)
            guard account["code"] as? Int == 200,
                  account["account"] is [String: Any] || account["profile"] is [String: Any],
                  cookies["MUSIC_U"]?.isEmpty == false else {
                throw OnlineError.unavailable("扫码已确认，但网易云账号会话校验失败，请重新生成二维码")
            }
            try Task.checkCancellation()
            guard generation == token, sessions.version(for: .netease) == context.originalVersion,
                  try sessions.cookieHeader(for: .netease) == context.originalCookies else { throw CancellationError() }
            try sessions.saveCookieHeader(Self.cookieHeader(cookies), for: .netease)
            self.context = nil; cookies = [:]
            return .authorized
        default:
            throw apiError(response)
        }
    }

    // Keep response cookies and refresh credentials scoped to the same QR transaction.
    // swiftlint:disable:next cyclomatic_complexity
    private func request(_ path: String, payload: [String: Any], headers: [String: String] = [:],
                         generation token: UUID) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path; components?.query = nil; components?.fragment = nil
        // QR creation/polling uses no csrf query; the account check uses the acquired web session.
        if path == "/weapi/w/nuser/account/get", let csrf = payload["csrf_token"] as? String, !csrf.isEmpty {
            components?.queryItems = [URLQueryItem(name: "csrf_token", value: csrf)]
        }
        guard let url = components?.url else { throw OnlineError.invalidResponse }
        let encrypted = try NeteaseCrypto.weAPI(payload: payload)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let form = encrypted.keys.sorted().map { "\($0)=\(encrypted[$0]?.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = Data(form.utf8)
        request.httpShouldHandleCookies = false; request.timeoutInterval = 20
        let standard = ["Accept": "*/*", "Accept-Language": "zh-CN,zh-Hans;q=0.9", "Cache-Control": "no-cache", "Pragma": "no-cache",
            "Referer": "https://music.163.com/", "Origin": "https://music.163.com", "User-Agent": Self.userAgent,
            "x-os": "web", "x-channelsource": "undefined", "nm-gcore-status": "1", "Content-Type": "application/x-www-form-urlencoded"]
        standard.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if !cookies.isEmpty { request.setValue(Self.cookieHeader(cookies), forHTTPHeaderField: "Cookie") }
        Log.net.info("网易云 QR 请求：\(path, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw OnlineError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw OnlineError.http(http.statusCode) }
        guard data.count <= 4 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OnlineError.invalidResponse }
        var fields: [String: String] = [:]
        http.allHeaderFields.forEach { fields[String(describing: $0.key)] = String(describing: $0.value) }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard domain == "music.163.com" || domain.hasSuffix(".music.163.com") || domain == url.host else { continue }
            cookies[cookie.name] = cookie.expiresDate.map { $0 <= Date() } == true ? nil : cookie.value
        }
        // The confirmed web QR endpoint can deliver MUSIC_U as an x-refresh-token header.
        if path == "/weapi/login/qrcode/client/login", root["code"] as? Int == 803,
           cookies["MUSIC_U"]?.isEmpty != false, let credential = http.value(forHTTPHeaderField: "x-refresh-token"), !credential.isEmpty {
            cookies["MUSIC_U"] = credential
        }
        return root
    }
    private func apiError(_ response: [String: Any]) -> OnlineError {
        let code = response["code"] as? Int ?? -1
        let message = response["message"] as? String ?? response["msg"] as? String ?? "网易云拒绝了扫码登录"
        return .unavailable("\(message)（code=\(code)）")
    }
    private static func cookiePairs(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in header.split(separator: ";") {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pieces.count == 2 { result[pieces[0].trimmingCharacters(in: .whitespaces)] = String(pieces[1]) }
        }
        return result
    }
    private static func cookieHeader(_ values: [String: String]) -> String {
        values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "; ")
    }
}
