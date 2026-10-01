// ListenTogetherViewModel.swift
// M8-T7: small room UI adapter around the actor-based protocol client.
import Combine
import Foundation

@MainActor
final class ListenTogetherViewModel: ObservableObject {
    @Published var baseURL = "https://listen-together.neriplayer.app"
    @Published var nickname = "NeriPlayer"
    @Published var roomID = ""
    @Published var joinSecret = ""
    @Published private(set) var room: ListenTogetherRoomState?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isBusy = false

    private let client = ListenTogetherClient()
    private weak var store: PlaybackStateStore?
    private var updatesTask: Task<Void, Never>?
    private let userUUID: String

    init(store: PlaybackStateStore) {
        self.store = store; userUUID = UUID().uuidString
        updatesTask = Task { [weak self, client] in
            let updates = await client.updates()
            for await update in updates {
                guard !Task.isCancelled else { return }
                self?.accept(update)
            }
        }
    }

    deinit { updatesTask?.cancel() }

    func createRoom() {
        guard let baseURL = URL(string: baseURL), let store, let track = store.currentTrack,
              let onlineSong = track.onlineSong, let sharedTrack = ListenTogetherTrack(song: onlineSong) else {
            statusMessage = "一起听需要当前正在播放可分享的在线曲目"
            return
        }
        let queue = store.queueState.tracks.compactMap { track in
            track.onlineSong.flatMap(ListenTogetherTrack.init(song:))
        }
        guard !queue.isEmpty else {
            statusMessage = "当前队列没有可分享的在线曲目"
            return
        }
        let snapshot = ListenTogetherInitialSnapshot(queue: queue, currentIndex: store.queueState.currentIndex ?? 0,
            track: sharedTrack, settings: ListenTogetherSettings(), isPlaying: !store.isPaused,
            positionMs: Int64(max(0, store.position) * 1000), repeatMode: 0, shuffleEnabled: store.queueState.mode == .shuffle, shuffleRestoreQueue: nil)
        let userUUID = self.userUUID
        let nickname = self.nickname
        run { [client] in
            let response = try await client.create(baseURL: baseURL, userUUID: userUUID, nickname: nickname, snapshot: snapshot)
            try await client.adopt(response); return response.roomId ?? ""
        }
    }

    func joinRoom() {
        guard let baseURL = URL(string: baseURL), !roomID.isEmpty else { statusMessage = "请输入房间号"; return }
        let roomID = self.roomID
        let userUUID = self.userUUID
        let nickname = self.nickname
        let joinSecret = self.joinSecret.isEmpty ? nil : self.joinSecret
        run { [client] in
            let response = try await client.join(baseURL: baseURL, roomID: roomID, userUUID: userUUID,
                                                 nickname: nickname, joinSecret: joinSecret)
            try await client.adopt(response); return response.roomId ?? roomID
        }
    }

    func leaveRoom() {
        guard let url = URL(string: baseURL) else { return }
        run { [client] in try await client.leave(baseURL: url); return "" }
    }

    private func run(_ operation: @escaping @Sendable () async throws -> String) {
        isBusy = true; statusMessage = nil
        Task { [weak self] in
            do {
                let value = try await operation()
                await MainActor.run { self?.roomID = value; self?.isBusy = false; self?.statusMessage = value.isEmpty ? "已离开房间" : "已连接到房间 \(value)" }
            } catch {
                await MainActor.run { self?.isBusy = false; self?.statusMessage = error.localizedDescription }
            }
        }
    }

    private func accept(_ update: ListenTogetherStateUpdate) {
        switch update {
        case .welcome(let envelope), .room(let envelope): room = envelope.state
        case .control(let envelope): room = envelope.result?.state ?? room
        case .closed(let message): statusMessage = "连接已断开：\(message)"
        }
    }
}
