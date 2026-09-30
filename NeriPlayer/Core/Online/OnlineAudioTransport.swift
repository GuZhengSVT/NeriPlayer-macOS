// OnlineAudioTransport.swift
// M5: loopback-only, capability-token audio transport through macOS URLSession.
// Chunked Range forwarding avoids downloading a whole song or exposing cookies to libmpv.
import Foundation
import Network

public final class OnlineAudioTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "moe.ouom.NeriPlayer.audio-transport")
    private let lock = NSLock()
    private let listener: NWListener
    private let session: URLSession
    private let cache: PlaybackAudioCache?
    private var audio: ResolvedAudio?
    private var token = UUID().uuidString
    private var active: [UUID: (NWConnection, Task<Void, Never>?)] = [:]
    private var port: UInt16?
    private var stopped = false
    private static let chunkBytes = 512 * 1024

    public convenience init(session: URLSession = .shared) throws {
        try self.init(session: session, cache: nil)
    }
    init(session: URLSession = .shared, cache: PlaybackAudioCache?) throws {
        self.session = session
        self.cache = cache
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: lock.lock(); port = listener.port?.rawValue; lock.unlock(); ready.signal()
            case .failed: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        let started = ready.wait(timeout: .now() + 3) == .success
        lock.lock(); let bound = port != nil; lock.unlock()
        guard started, bound else {
            listener.cancel()
            throw OnlineError.unavailable("无法启动本机音频传输")
        }
    }
    deinit { listener.cancel() }
    public func register(_ audio: ResolvedAudio) throws -> URL {
        lock.lock()
        guard !stopped, let port else { lock.unlock(); throw OnlineError.unavailable("音频传输已关闭") }
        guard audio.url.scheme == "https", audio.url.host != nil else { lock.unlock(); throw OnlineError.invalidResponse }
        var sanitized = audio
        sanitized.headers = sanitized.headers.filter { $0.key.caseInsensitiveCompare("Cookie") != .orderedSame }
        self.audio = sanitized
        token = UUID().uuidString
        let token = self.token
        let obsolete = Array(active.values)
        active = [:]
        lock.unlock()
        obsolete.forEach { $0.1?.cancel(); $0.0.cancel() }
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(token)") else { throw OnlineError.invalidResponse }
        return url
    }
    public func stop() {
        lock.lock(); stopped = true; audio = nil
        let obsolete = Array(active.values); active = [:]; lock.unlock()
        listener.cancel()
        obsolete.forEach { $0.1?.cancel(); $0.0.cancel() }
    }
    private func accept(_ connection: NWConnection) {
        let id = UUID()
        lock.lock()
        guard !stopped, active.count < 4 else { lock.unlock(); connection.cancel(); return }
        active[id] = (connection, nil)
        lock.unlock()
        connection.start(queue: queue)
        receive(connection, id: id, accumulated: Data())
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            lock.lock(); let incomplete = active[id]?.1 == nil; lock.unlock()
            if incomplete { finish(id) }
        }
    }
    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, ended, error in
            guard let self else { connection.cancel(); return }
            var received = accumulated
            if let data { received.append(data) }
            guard received.count <= 16_384, error == nil else { finish(id); return }
            if let header = String(data: received, encoding: .utf8), header.contains("\r\n\r\n") {
                let task = Task { [weak self] in
                    guard let self else { return }
                    await serve(header, connection: connection, id: id)
                }
                lock.lock(); if active[id] != nil { active[id]?.1 = task } else { task.cancel() }; lock.unlock()
            } else if ended { finish(id) } else { receive(connection, id: id, accumulated: received) }
        }
    }
    private func configuration(_ path: String) -> ResolvedAudio? {
        lock.lock(); defer { lock.unlock() }
        return path == "/" + token && !stopped ? audio : nil
    }
    // Validate both client ranges and upstream Content-Range before forwarding bytes.
    // swiftlint:disable:next cyclomatic_complexity
    private func serve(_ header: String, connection: NWConnection, id: UUID) async {
        defer { finish(id) }
        let lines = header.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])),
              let audio = configuration(String(first[1])) else { return }
        let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }?.dropFirst(6).trimmingCharacters(in: .whitespaces)
        var start: Int64 = 0
        var requestedEnd: Int64?
        if let rangeHeader {
            guard rangeHeader.hasPrefix("bytes="), !rangeHeader.contains(",") else { return }
            let values = rangeHeader.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard values.count == 2, let parsed = Int64(values[0]), parsed >= 0 else { return }
            start = parsed
            if !values[1].isEmpty { requestedEnd = Int64(values[1]); guard requestedEnd.map({ $0 >= start }) == true else { return } }
        }
        do {
            var position = start
            var total: Int64?
            var limit = requestedEnd
            var sentHeader = false
            while !Task.isCancelled {
                let upper = min(limit ?? Int64.max, position.addingReportingOverflow(Int64(Self.chunkBytes - 1)).partialValue)
                guard upper >= position else { return }
                var request = URLRequest(url: audio.url)
                request.httpShouldHandleCookies = false
                request.timeoutInterval = 30
                audio.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                request.setValue("bytes=\(position)-\(upper)", forHTTPHeaderField: "Range")
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 206,
                      let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
                      let parsed = Self.contentRange(contentRange), parsed.start == position,
                      parsed.end - parsed.start + 1 <= Int64(Self.chunkBytes) else { throw OnlineError.invalidResponse }
                var data = Data()
                data.reserveCapacity(Self.chunkBytes)
                for try await byte in bytes {
                    guard data.count < Self.chunkBytes else { throw OnlineError.invalidResponse }
                    data.append(byte)
                }
                guard !data.isEmpty, parsed.end - parsed.start + 1 == Int64(data.count) else { throw OnlineError.invalidResponse }
                if let total, total != parsed.total { throw OnlineError.invalidResponse }
                total = parsed.total
                limit = min(requestedEnd ?? (parsed.total - 1), parsed.total - 1)
                if !sentHeader {
                    let status = rangeHeader == nil ? "200 OK" : "206 Partial Content"
                    let mime = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
                    guard !mime.contains("\r"), !mime.contains("\n"), let limit else { return }
                    var responseHeader = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(limit - start + 1)\r\n"
                    responseHeader += "Accept-Ranges: bytes\r\nConnection: close\r\n"
                    if rangeHeader != nil { responseHeader += "Content-Range: bytes \(start)-\(limit)/\(parsed.total)\r\n" }
                    try await send(Data((responseHeader + "\r\n").utf8), connection: connection)
                    sentHeader = true
                    if first[0] == "HEAD" { return }
                }
                if first[0] != "HEAD", let cache {
                    do {
                        try await cache.record(audio, start: parsed.start, total: parsed.total, data: data,
                                               mime: response.value(forHTTPHeaderField: "Content-Type"))
                    } catch { Log.net.warning("播放缓存写入失败，继续在线播放") }
                }
                try await send(data, connection: connection)
                position = parsed.end + 1
                if position > (limit ?? 0) { return }
            }
        } catch {
            if !Task.isCancelled { Log.net.error("本机音频传输失败：\(audio.song.source.rawValue, privacy: .public)") }
        }
    }
    private struct ContentRange { let start: Int64; let end: Int64; let total: Int64 }
    private static func contentRange(_ value: String) -> ContentRange? {
        guard value.hasPrefix("bytes ") else { return nil }
        let fields = value.dropFirst(6).split(separator: "/")
        guard fields.count == 2, let total = Int64(fields[1]), total > 0 else { return nil }
        let span = fields[0].split(separator: "-")
        guard span.count == 2, let start = Int64(span[0]), let end = Int64(span[1]), start >= 0, end >= start, end < total else { return nil }
        return ContentRange(start: start, end: end, total: total)
    }
    private func send(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func finish(_ id: UUID) {
        lock.lock(); let current = active.removeValue(forKey: id); lock.unlock()
        current?.0.cancel()
    }
}
