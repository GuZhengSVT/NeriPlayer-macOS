// ListenTogether.swift
// M8-T7: interoperable HTTP/WebSocket client for the official ListenTogether Worker.
import Foundation

public struct ListenTogetherSettings: Codable, Equatable, Sendable {
    public var allowMemberControl = true
    public var autoPauseOnMemberChange = true
    public var shareAudioLinks = true
}

public struct ListenTogetherTrack: Codable, Equatable, Sendable {
    public var stableKey: String
    public var channelId: String
    public var audioId: String
    public var subAudioId: String?
    public var playlistContextId: String?
    public var mediaUri: String?
    public var streamUrl: String?
    public var streamUrls: [String]
    public var name: String
    public var artist: String
    public var album: String?
    public var durationMs: Int64
    public var coverUrl: String?

    public init(stableKey: String, channelId: String, audioId: String, name: String,
                artist: String, album: String? = nil, durationMs: Int64 = 0,
                coverUrl: String? = nil, mediaUri: String? = nil) {
        self.stableKey = stableKey; self.channelId = channelId; self.audioId = audioId
        self.subAudioId = nil; self.playlistContextId = nil; self.mediaUri = mediaUri
        self.streamUrl = nil; self.streamUrls = []; self.name = name; self.artist = artist
        self.album = album; self.durationMs = max(0, durationMs); self.coverUrl = coverUrl
    }

    public init?(song: SongData) {
        guard !song.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.init(stableKey: "\(song.source.rawValue):\(song.sourceID)", channelId: song.source.rawValue,
                  audioId: song.sourceID, name: song.title, artist: song.artist, album: song.album,
                  durationMs: Int64(max(0, (song.duration ?? 0) * 1000)), coverUrl: song.artworkURL?.absoluteString,
                  mediaUri: song.pageURL?.absoluteString)
    }
}

public struct ListenTogetherPlayback: Codable, Equatable, Sendable {
    public var state: String = "paused"
    public var basePositionMs: Int64 = 0
    public var baseTimestampMs: Int64 = 0
    public var playbackRate: Double = 1
    public var repeatMode: Int?
    public var shuffleEnabled: Bool?
}

public struct ListenTogetherMember: Codable, Equatable, Sendable {
    public var userUuid: String
    public var nickname: String
    public var userId: String?
    public var role: String
    public var joinedAt: Int64
}

public struct ListenTogetherRoomState: Codable, Equatable, Sendable {
    public var roomId: String
    public var version: Int64
    public var schemaVersion: Int = 1
    public var controllerUserUuid: String?
    public var controllerUserId: String?
    public var controllerHeartbeatAt: Int64?
    public var settings: ListenTogetherSettings = .init()
    public var members: [ListenTogetherMember] = []
    public var queue: [ListenTogetherTrack] = []
    public var currentIndex = 0
    public var track: ListenTogetherTrack?
    public var playback: ListenTogetherPlayback = .init()
    public var controllerOfflineSince: Int64?
    public var roomStatus = "active"
    public var closedReason: String?
    public var updatedAt: Int64 = 0
}

extension ListenTogetherSettings {
    private enum CodingKeys: String, CodingKey { case allowMemberControl, autoPauseOnMemberChange, shareAudioLinks }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowMemberControl = try c.decodeIfPresent(Bool.self, forKey: .allowMemberControl) ?? true
        autoPauseOnMemberChange = try c.decodeIfPresent(Bool.self, forKey: .autoPauseOnMemberChange) ?? true
        shareAudioLinks = try c.decodeIfPresent(Bool.self, forKey: .shareAudioLinks) ?? true
    }
}

extension ListenTogetherTrack {
    private enum CodingKeys: String, CodingKey {
        case stableKey, channelId, audioId, subAudioId, playlistContextId, mediaUri, streamUrl, streamUrls
        case name, artist, album, durationMs, coverUrl
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stableKey = try c.decode(String.self, forKey: .stableKey)
        channelId = try c.decode(String.self, forKey: .channelId)
        audioId = try c.decode(String.self, forKey: .audioId)
        subAudioId = try c.decodeIfPresent(String.self, forKey: .subAudioId)
        playlistContextId = try c.decodeIfPresent(String.self, forKey: .playlistContextId)
        mediaUri = try c.decodeIfPresent(String.self, forKey: .mediaUri)
        streamUrl = try c.decodeIfPresent(String.self, forKey: .streamUrl)
        streamUrls = try c.decodeIfPresent([String].self, forKey: .streamUrls) ?? []
        name = try c.decode(String.self, forKey: .name); artist = try c.decode(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        durationMs = max(0, try c.decodeIfPresent(Int64.self, forKey: .durationMs) ?? 0)
        coverUrl = try c.decodeIfPresent(String.self, forKey: .coverUrl)
    }
}

extension ListenTogetherPlayback {
    private enum CodingKeys: String, CodingKey { case state, basePositionMs, baseTimestampMs, playbackRate, repeatMode, shuffleEnabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "paused"
        basePositionMs = try c.decodeIfPresent(Int64.self, forKey: .basePositionMs) ?? 0
        baseTimestampMs = try c.decodeIfPresent(Int64.self, forKey: .baseTimestampMs) ?? 0
        playbackRate = try c.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1
        repeatMode = try c.decodeIfPresent(Int.self, forKey: .repeatMode)
        shuffleEnabled = try c.decodeIfPresent(Bool.self, forKey: .shuffleEnabled)
    }
}

extension ListenTogetherRoomState {
    private enum CodingKeys: String, CodingKey {
        case roomId, version, schemaVersion, controllerUserUuid, controllerUserId, controllerHeartbeatAt
        case settings, members, queue, currentIndex, track, playback, controllerOfflineSince, roomStatus, closedReason, updatedAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roomId = try c.decode(String.self, forKey: .roomId); version = try c.decode(Int64.self, forKey: .version)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        controllerUserUuid = try c.decodeIfPresent(String.self, forKey: .controllerUserUuid)
        controllerUserId = try c.decodeIfPresent(String.self, forKey: .controllerUserId)
        controllerHeartbeatAt = try c.decodeIfPresent(Int64.self, forKey: .controllerHeartbeatAt)
        settings = try c.decodeIfPresent(ListenTogetherSettings.self, forKey: .settings) ?? .init()
        members = try c.decodeIfPresent([ListenTogetherMember].self, forKey: .members) ?? []
        queue = try c.decodeIfPresent([ListenTogetherTrack].self, forKey: .queue) ?? []
        currentIndex = try c.decodeIfPresent(Int.self, forKey: .currentIndex) ?? 0
        track = try c.decodeIfPresent(ListenTogetherTrack.self, forKey: .track)
        playback = try c.decodeIfPresent(ListenTogetherPlayback.self, forKey: .playback) ?? .init()
        controllerOfflineSince = try c.decodeIfPresent(Int64.self, forKey: .controllerOfflineSince)
        roomStatus = try c.decodeIfPresent(String.self, forKey: .roomStatus) ?? "active"
        closedReason = try c.decodeIfPresent(String.self, forKey: .closedReason)
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
    }
}

public struct ListenTogetherInitialSnapshot: Codable, Sendable {
    public var queue: [ListenTogetherTrack]
    public var currentIndex: Int
    public var track: ListenTogetherTrack?
    public var settings: ListenTogetherSettings
    public var isPlaying: Bool
    public var positionMs: Int64
    public var repeatMode: Int
    public var shuffleEnabled: Bool
    public var shuffleRestoreQueue: [ListenTogetherTrack]?
}

public struct ListenTogetherRoomResponse: Codable, Sendable {
    public var ok: Bool
    public var roomId: String?
    public var userUuid: String?
    public var userId: String?
    public var nickname: String?
    public var role: String?
    public var memberSecret: String?
    public var joinSecret: String?
    public var autoPauseOnJoin = false
    public var token: String?
    public var state: ListenTogetherRoomState?
    public var wsUrl: String?
    public var error: String?
}

public struct ListenTogetherStateResponse: Codable, Sendable {
    public var ok: Bool
    public var state: ListenTogetherRoomState?
    public var expectedPositionMs: Int64?
    public var serverNowMs: Int64?
    public var autoPauseOnJoin = false
    public var error: String?
}

public struct ListenTogetherCause: Codable, Equatable, Sendable {
    public var userUuid: String?
    public var userId: String?
    public var nickname: String?
    public var eventId: String?
    public var type: String?
}

public struct ListenTogetherAppliedEvent: Codable, Equatable, Sendable {
    public var type: String
    public var roomId: String?
    public var version: Int64?
    public var state: ListenTogetherRoomState?
    public var expectedPositionMs: Int64?
    public var nowMs: Int64?
    public var causedBy: ListenTogetherCause?
}

public struct ListenTogetherEvent: Codable, Sendable {
    public var type: String
    public var eventId: String?
    public var clientTimeMs: Int64?
    public var clientInstanceId: String?
    public var clientSequence: Int64?
    public var positionMs: Int64?
    public var currentIndex: Int?
    public var nextIndex: Int?
    public var track: ListenTogetherTrack?
    public var queue: [ListenTogetherTrack]?
    public var roomSettings: ListenTogetherSettings?
    public var shouldPlay: Bool?
    public var state: String?
    public var repeatMode: Int?
    public var shuffleEnabled: Bool?
    public var requestTrackStableKey: String?
    public var forceRefresh: Bool?
    public var finishedTrackStableKey: String?
    public init(type: String) { self.type = type }
}

public struct ListenTogetherSocketEnvelope: Codable, Sendable {
    public var type: String
    public var sessionId: String?
    public var userUuid: String?
    public var userId: String?
    public var nickname: String?
    public var role: String?
    public var autoPauseOnJoin = false
    public var state: ListenTogetherRoomState?
    public var expectedPositionMs: Int64?
    public var nowMs: Int64?
    public var t: Int64?
    public var ok: Bool?
    public var result: ListenTogetherAppliedEvent?
    public var message: String?
    public var roomId: String?
    public var version: Int64?
    public var causedBy: ListenTogetherCause?
}

public enum ListenTogetherError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidResponse
    case server(String)
    case transport(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "一起听配置无效"
        case .invalidResponse: return "一起听服务返回了无法解析的数据"
        case .server(let message), .transport(let message): return message
        }
    }
}

public enum ListenTogetherStateUpdate: Sendable {
    case welcome(ListenTogetherSocketEnvelope)
    case room(ListenTogetherSocketEnvelope)
    case control(ListenTogetherSocketEnvelope)
    case closed(String)
}

private struct ListenTogetherCreatePayload: Codable {
    let userUuid: String
    let nickname: String
    let initialSnapshot: ListenTogetherInitialSnapshot
}

private struct ListenTogetherJoinPayload: Codable {
    let userUuid: String
    let nickname: String
    let memberSecret: String?
    let joinSecret: String?
}

public actor ListenTogetherClient {
    public private(set) var room: ListenTogetherRoomState?
    public private(set) var role = ""
    public private(set) var roomID = ""
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var token: String?
    private var memberSecret: String?
    private var socket: URLSessionWebSocketTask?
    private var sequence: Int64 = 0
    private let clientInstanceID = UUID().uuidString
    private var stateContinuations: [UUID: AsyncStream<ListenTogetherStateUpdate>.Continuation] = [:]

    public init(session: URLSession = .shared) {
        self.session = session; encoder = JSONEncoder(); decoder = JSONDecoder()
    }

    deinit { socket?.cancel(with: .normalClosure, reason: nil) }

    public func updates() -> AsyncStream<ListenTogetherStateUpdate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let id = UUID(); stateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
        }
    }

    public func create(baseURL: URL, userUUID: String, nickname: String,
                       snapshot: ListenTogetherInitialSnapshot) async throws -> ListenTogetherRoomResponse {
        let payload = ListenTogetherCreatePayload(userUuid: userUUID, nickname: nickname, initialSnapshot: snapshot)
        return try await request(baseURL.appendingPathComponent("api/rooms"), method: "POST", body: encoder.encode(payload))
    }

    public func join(baseURL: URL, roomID: String, userUUID: String, nickname: String,
                     joinSecret: String?, memberSecret: String? = nil) async throws -> ListenTogetherRoomResponse {
        let payload = ListenTogetherJoinPayload(userUuid: userUUID, nickname: nickname,
                                                memberSecret: memberSecret, joinSecret: joinSecret)
        return try await request(baseURL.appendingPathComponent("api/rooms/\(roomID)/join"), method: "POST", body: encoder.encode(payload))
    }

    public func adopt(_ response: ListenTogetherRoomResponse) async throws {
        guard response.ok, let roomID = response.roomId, let token = response.token,
              let wsURL = response.wsUrl.flatMap(URL.init(string:)) else {
            throw ListenTogetherError.server(response.error ?? "一起听加入失败")
        }
        self.roomID = roomID; self.token = token; memberSecret = response.memberSecret
        role = response.role ?? "listener"; room = response.state
        socket?.cancel(with: .normalClosure, reason: nil)
        let task = session.webSocketTask(with: wsURL); socket = task; task.resume()
        Task { [weak self] in await self?.receiveLoop(task) }
    }

    public func leave(baseURL: URL) async throws {
        guard !roomID.isEmpty, let token else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/rooms/\(roomID)/leave"))
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: request)
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil; room = nil; self.token = nil; memberSecret = nil
    }

    public func send(type: String, positionMs: Int64? = nil, currentIndex: Int? = nil,
                     track: ListenTogetherTrack? = nil, queue: [ListenTogetherTrack]? = nil,
                     shouldPlay: Bool? = nil, state: String? = nil, requestTrackStableKey: String? = nil) async throws {
        guard let socket else { throw ListenTogetherError.transport("一起听连接尚未建立") }
        sequence += 1
        var event = ListenTogetherEvent(type: type)
        event.eventId = UUID().uuidString; event.clientTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
        event.clientInstanceId = clientInstanceID; event.clientSequence = sequence
        event.positionMs = positionMs; event.currentIndex = currentIndex; event.track = track; event.queue = queue
        event.shouldPlay = shouldPlay; event.state = state; event.requestTrackStableKey = requestTrackStableKey
        try await socket.send(.string(String(bytes: try encoder.encode(event), encoding: .utf8) ?? "{}"))
    }

    public func sendHeartbeat() async throws { try await send(type: "HEARTBEAT") }
    public func sendPing() async throws {
        guard let socket else { return }
        let value = ["type": "np_ping", "t": String(Int64(Date().timeIntervalSince1970 * 1000))]
        try await socket.send(.string(String(bytes: try encoder.encode(value), encoding: .utf8) ?? "{}"))
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                guard let envelope = try await receiveEnvelope(from: task) else { continue }
                if let candidate = envelope.state, candidate.version >= (room?.version ?? -1) { room = candidate }
                publish(envelope)
            } catch {
                publish(.closed(error.localizedDescription)); return
            }
        }
    }

    private func receiveEnvelope(from task: URLSessionWebSocketTask) async throws -> ListenTogetherSocketEnvelope? {
        let message = try await task.receive()
        let data: Data?
        switch message {
        case .string(let value): data = Data(value.utf8)
        case .data(let value): data = value
        @unknown default: data = nil
        }
        guard let data else { return nil }
        return try? decoder.decode(ListenTogetherSocketEnvelope.self, from: data)
    }

    private func publish(_ envelope: ListenTogetherSocketEnvelope) {
        switch envelope.type {
        case "welcome": publish(.welcome(envelope))
        case "room_state_updated": publish(.room(envelope))
        case "control_result": publish(.control(envelope))
        default: break
        }
    }

    private func request<T: Decodable>(_ url: URL, method: String, body: Data) async throws -> T {
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ListenTogetherError.transport("一起听请求失败")
        }
        guard let value = try? decoder.decode(T.self, from: data) else { throw ListenTogetherError.invalidResponse }
        return value
    }

    private func publish(_ update: ListenTogetherStateUpdate) {
        for continuation in stateContinuations.values { continuation.yield(update) }
    }
    private func removeContinuation(_ id: UUID) { stateContinuations.removeValue(forKey: id) }
}
