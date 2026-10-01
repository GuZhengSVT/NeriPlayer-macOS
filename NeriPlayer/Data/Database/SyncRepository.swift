// SyncRepository.swift
// M7: database projection, persistent identities and atomic revision-guarded sync application.

import Foundation
import GRDB

public struct SyncCapture: Sendable {
    public var snapshot: SyncSnapshot
    public var revision: Int64
}

struct SyncJournalState: Codable {
    var deviceID = UUID().uuidString
    var counter: Int64 = 0
    var snapshot = SyncSnapshot()
    var playlistIDs: [String: Int64] = [:]
    var observedStats: [String: SyncRecord] = [:]
}

public struct SyncRepository: Sendable {
    let database: DatabaseProvider
    public init(_ database: DatabaseProvider) { self.database = database }

    public func capture() throws -> SyncCapture {
        try database.dbQueue.write { db in
            var state = try loadState(db)
            try project(db, state: &state)
            try saveState(state, db)
            return SyncCapture(snapshot: state.snapshot, revision: try revision(db))
        }
    }

    public func apply(_ snapshot: SyncSnapshot, expectedRevision: Int64, target: String,
                      syncedAt: Int64 = SyncSnapshot.milliseconds()) throws -> Bool {
        try database.dbQueue.write { db in
            guard try revision(db) == expectedRevision else { return false }
            var state = try loadState(db)
            try applyPlaylists(snapshot, state: &state, db: db)
            try applyHistoryAndStats(snapshot, state: &state, db: db)
            state.snapshot = snapshot
            state.snapshot.record.set("deviceId", state.deviceID)
            state.observedStats = try observedStats(db)
            try saveValue(try JSONEncoder().encode(snapshot.record.number("playbackStatsClearedAt")), key: "statsClearedAt", db: db)
            try saveState(state, db)
            try saveValue(try JSONEncoder().encode(syncedAt), key: "lastSync:" + target, db: db)
            return true
        }
    }

    public func lastSyncTime(target: String) throws -> Int64 {
        try database.dbQueue.read { db in
            guard let data = try value("lastSync:" + target, db) else { return 0 }
            return try JSONDecoder().decode(Int64.self, from: data)
        }
    }

    public func addOnlineSong(_ song: SongData, playlistID: UUID? = nil, favorite: Bool = false) throws {
        try database.dbQueue.write { db in
            let existing = try TrackRecord.filter(Column("url") == song.identityURL.absoluteString).fetchOne(db)
            let track = existing ?? TrackRecord(track: song.track(), album: song.album)
            if existing == nil { try track.insert(db) }
            if favorite { try FavoriteRecord(trackId: track.id).save(db) }
            if let playlistID {
                guard try PlaylistRecord.exists(db, key: playlistID) else { throw RepositoryError.playlistNotFound(playlistID) }
                let entries = try PlaylistEntryRecord.filter(Column("playlistId") == playlistID).fetchAll(db)
                if !entries.contains(where: { $0.trackId == track.id }) {
                    try PlaylistEntryRecord(playlistId: playlistID, trackId: track.id, position: entries.count).insert(db)
                    try db.execute(sql: "UPDATE Playlist SET updatedAt = ? WHERE id = ?", arguments: [Date(), playlistID])
                }
            }
        }
    }

    public func registerPlaybackTrack(_ track: Track) throws -> Track {
        try database.dbQueue.write { db in
            let existing = try TrackRecord.filter(Column("url") == track.url.absoluteString).fetchOne(db)
            let record = existing ?? TrackRecord(track: track, album: track.onlineSong?.album)
            if existing == nil { try record.insert(db) }
            try PlayHistoryRecord(trackId: record.id).save(db)
            return record.toTrack()
        }
    }

    private func revision(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT revision FROM SyncRevision WHERE id = 1") ?? 0
    }
    private func value(_ key: String, _ db: Database) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT value FROM SyncJournal WHERE key = ?", arguments: [key])
    }
    private func saveValue(_ data: Data, key: String, db: Database) throws {
        try db.execute(sql: "INSERT INTO SyncJournal (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [key, data])
    }
    private func loadState(_ db: Database) throws -> SyncJournalState {
        guard let data = try value("state", db) else { return SyncJournalState() }
        return try JSONDecoder().decode(SyncJournalState.self, from: data)
    }
    private func saveState(_ state: SyncJournalState, _ db: Database) throws {
        try saveValue(try JSONEncoder().encode(state), key: "state", db: db)
    }

    private func project(_ db: Database, state: inout SyncJournalState) throws {
        let now = SyncSnapshot.milliseconds()
        if let data = try value("statsClearedAt", db), let clear = try? JSONDecoder().decode(Int64.self, from: data),
           clear > state.snapshot.record.number("playbackStatsClearedAt") {
            state.snapshot.record.set("playbackStatsClearedAt", clear)
            state.snapshot.record.set("playbackStats", [])
            state.snapshot.record.set("playbackStatBuckets", [])
            state.observedStats = [:]
        }
        let tracks = try TrackRecord.fetchAll(db)
        let trackMap = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let previous = state.snapshot.playlists
        var playlists: [SyncRecord] = []
        for playlist in try PlaylistRecord.order(Column("createdAt")).fetchAll(db) {
            let localKey = playlist.id.uuidString
            let identifier = state.playlistIDs[localKey] ?? (SyncRecord.stableAndroidID(localKey) & Int64.max)
            state.playlistIDs[localKey] = identifier
            let old = previous.first { $0.number("id") == identifier }
            let entries = try PlaylistEntryRecord.filter(Column("playlistId") == playlist.id).order(Column("position")).fetchAll(db)
            let songs = entries.compactMap { entry -> SyncRecord? in
                guard let track = trackMap[entry.trackId], let song = song(track) else { return nil }
                return song.replacing("addedAt", with: SyncSnapshot.milliseconds(entry.addedAt))
            }
            var record = old ?? SyncRecord()
            record.set("id", identifier); record.set("name", playlist.name)
            record.set("createdAt", SyncSnapshot.milliseconds(playlist.createdAt))
            record.set("modifiedAt", SyncSnapshot.milliseconds(playlist.updatedAt)); record.set("isDeleted", false)
            record.set("songOrderVersion", Int64(1))
            record.set("songs", reconcile(songs, previous: old?.records("songs") ?? [], playlist: identifier, state: &state, now: now))
            playlists.append(record)
        }
        let favorites = try FavoriteRecord.order(Column("favoritedAt").desc).fetchAll(db).compactMap { favorite -> SyncRecord? in
            guard let track = trackMap[favorite.trackId], let song = song(track) else { return nil }
            return song.replacing("addedAt", with: SyncSnapshot.milliseconds(favorite.favoritedAt))
        }
        var favorite = previous.first { $0.number("id") == -1_001 } ?? SyncRecord(["id": .integer(-1_001), "name": .string("我喜欢的音乐")])
        let favoriteSongs = reconcile(favorites, previous: favorite.records("songs"), playlist: -1_001, state: &state, now: now)
        if favoriteSongs != favorite.records("songs") { favorite.set("modifiedAt", now) }
        favorite.set("songs", favoriteSongs); favorite.set("songOrderVersion", Int64(1)); playlists.append(favorite)
        let active = Set(playlists.map { $0.number("id") })
        for var old in previous where !active.contains(old.number("id")) {
            if !old.flag("isDeleted") { old.set("modifiedAt", now) }
            old.set("isDeleted", true); old.set("songs", []); playlists.append(old)
        }
        state.snapshot.playlists = playlists
        try projectHistory(db, state: &state, trackMap: trackMap, now: now)
        try projectStats(db, state: &state, trackMap: trackMap)
        state.snapshot.record.set("version", "2.0")
        state.snapshot.record.set("deviceId", state.deviceID)
        state.snapshot.record.set("deviceName", Host.current().localizedName ?? "macOS")
        state.snapshot.record.set("lastModified", now)
    }

    private func song(_ track: TrackRecord) -> SyncRecord? {
        guard let url = URL(string: track.url), let song = SongData.fromIdentityURL(url, title: track.title,
            artist: track.artist ?? "", album: track.album ?? "", duration: track.durationSeconds) else { return nil }
        return SyncRecord.song(song)
    }

    private func reconcile(_ songs: [SyncRecord], previous: [SyncRecord], playlist: Int64,
                           state: inout SyncJournalState, now: Int64) -> [SyncRecord] {
        var deletions = state.snapshot.record.records("playlistSongDeletions")
        let identities = Set(songs.map(\.identityKey))
        for old in previous where old.onlineSong != nil && !identities.contains(old.identityKey) {
            var deletion = old
            deletion.set("songId", old.number("id")); deletion.set("playlistId", playlist)
            deletion.set("deletedAt", now); deletion.set("deviceId", state.deviceID)
            deletion.set("removedMembershipTokens", old.records("syncMembershipTokens"))
            deletions.append(deletion)
        }
        state.snapshot.record.set("playlistSongDeletions", deletions)
        let orderChanged = songs.map(\.identityKey) != previous.filter { $0.onlineSong != nil }.map(\.identityKey)
        let projected = songs.enumerated().map { index, song in
            var result = previous.first { $0.identityKey == song.identityKey } ?? song
            if result.records("syncMembershipTokens").isEmpty {
                state.counter += 1
                result.set("syncMembershipTokens", [SyncRecord(["deviceId": .string(state.deviceID), "counter": .integer(state.counter)])])
            }
            // Android display order is addedAt descending, including explicit reorders.
            if orderChanged { result.set("addedAt", max(1, now - Int64(index))) }
            return result
        }
        return projected + previous.filter { $0.onlineSong == nil }
    }

    private func projectHistory(_ db: Database, state: inout SyncJournalState,
                                trackMap: [UUID: TrackRecord], now: Int64) throws {
        let history = try PlayHistoryRecord.fetchAll(db).compactMap { play -> SyncRecord? in
            guard let track = trackMap[play.trackId], let song = song(track) else { return nil }
            return SyncRecord(["songId": .integer(song.number("id")), "song": .object(song.fields),
                               "playedAt": .integer(SyncSnapshot.milliseconds(play.playedAt)), "deviceId": .string(state.deviceID),
                               "resumePositionMs": .integer(Int64(max(0, play.resumePositionSeconds) * 1_000))])
        }
        let keys = Set(history.map { $0.songRecord.identityKey })
        var deletions = state.snapshot.record.records("recentPlayDeletions")
        for old in state.snapshot.record.records("recentPlays") where old.songRecord.onlineSong != nil && !keys.contains(old.songRecord.identityKey) {
            var deletion = old.songRecord
            deletion.set("songId", deletion.number("id")); deletion.set("deletedAt", now); deletion.set("deviceId", state.deviceID)
            deletions.append(deletion)
        }
        state.snapshot.record.set("recentPlays", history + state.snapshot.record.records("recentPlays").filter { $0.songRecord.onlineSong == nil })
        state.snapshot.record.set("recentPlayDeletions", deletions)
    }

    private func observedStats(_ db: Database) throws -> [String: SyncRecord] {
        var result: [String: SyncRecord] = [:]
        for stat in try PlaybackStatsRecord.fetchAll(db) {
            result["total:" + stat.trackId.uuidString] = SyncRecord(["listen": .integer(Int64(max(0, stat.totalListenSeconds) * 1_000)),
                                                                   "count": .integer(Int64(stat.playCount))])
        }
        for stat in try PlaybackStatsDailyBucketRecord.fetchAll(db) {
            result["day:\(SyncSnapshot.milliseconds(stat.dayStart)):" + stat.trackId.uuidString] =
                SyncRecord(["listen": .integer(Int64(max(0, stat.totalListenSeconds) * 1_000)), "count": .integer(Int64(stat.playCount))])
        }
        return result
    }

    private func projectStats(_ db: Database, state: inout SyncJournalState, trackMap: [UUID: TrackRecord]) throws {
        var totals: [SyncRecord] = [], buckets: [SyncRecord] = []
        for stat in try PlaybackStatsRecord.fetchAll(db) {
            guard let track = trackMap[stat.trackId], let song = song(track) else { continue }
            totals.append(projectCounter(song, input: CounterInput(key: "total:" + stat.trackId.uuidString,
                day: nil, seconds: stat.totalListenSeconds, count: stat.playCount,
                first: stat.firstPlayedAt, last: stat.lastPlayedAt), state: &state))
        }
        for stat in try PlaybackStatsDailyBucketRecord.fetchAll(db) {
            guard let track = trackMap[stat.trackId], let song = song(track) else { continue }
            buckets.append(projectCounter(song, input: CounterInput(key: "day:\(SyncSnapshot.milliseconds(stat.dayStart)):" + stat.trackId.uuidString,
                day: stat.dayStart, seconds: stat.totalListenSeconds, count: stat.playCount,
                first: stat.firstPlayedAt, last: stat.lastPlayedAt), state: &state))
        }
        state.snapshot.record.set("playbackStats", totals + state.snapshot.record.records("playbackStats").filter { $0.onlineSong == nil })
        state.snapshot.record.set("playbackStatBuckets", buckets + state.snapshot.record.records("playbackStatBuckets").filter { $0.onlineSong == nil })
        state.observedStats = try observedStats(db)
    }

    private struct CounterInput {
        var key: String
        var day: Date?
        var seconds: Double
        var count: Int
        var first: Date?
        var last: Date?
    }

    private func projectCounter(_ song: SyncRecord, input: CounterInput, state: inout SyncJournalState) -> SyncRecord {
        let day = input.day, seconds = input.seconds, count = input.count
        let first = input.first, last = input.last, key = input.key
        let category = day == nil ? "playbackStats" : "playbackStatBuckets"
        var result = state.snapshot.record.records(category).first {
            $0.text("identityKey") == song.identityKey && $0.number("dayStartAt") == (day.map(SyncSnapshot.milliseconds) ?? 0)
        } ?? song
        result.set("identityKey", song.identityKey)
        let previous = state.observedStats[key] ?? SyncRecord()
        let listen = Int64(max(0, seconds) * 1_000)
        let deltaListen = max(0, listen - previous.number("listen")), deltaCount = max(0, Int64(count) - previous.number("count"))
        var shards = result.records("counterShards")
        if deltaListen > 0 || deltaCount > 0 {
            let epoch = state.snapshot.record.number("playbackStatsClearedAt")
            var shard = shards.first { $0.text("deviceId") == state.deviceID && $0.number("epochStartedAt") == epoch } ??
                SyncRecord(["deviceId": .string(state.deviceID), "epochStartedAt": .integer(epoch)])
            shard.set("totalListenMs", SyncCounterMerge.sum([shard.number("totalListenMs"), deltaListen]))
            shard.set("playCount", SyncCounterMerge.sum([shard.number("playCount"), deltaCount]))
            shard.set("firstPlayedAt", first.map(SyncSnapshot.milliseconds) ?? 0)
            shard.set("lastPlayedAt", last.map(SyncSnapshot.milliseconds) ?? 0)
            shards.removeAll { $0.text("deviceId") == state.deviceID && $0.number("epochStartedAt") == epoch }; shards.append(shard)
        }
        let normalizedShards = SyncCounterMerge.shards(shards)
        result.set("counterShards", normalizedShards)
        result.set("counterBaseListenMs", max(0, listen - SyncCounterMerge.sum(normalizedShards.map { $0.number("totalListenMs") })))
        result.set("counterBasePlayCount", max(0, Int64(count) - SyncCounterMerge.sum(normalizedShards.map { $0.number("playCount") })))
        result.set("totalListenMs", listen); result.set("playCount", Int64(count))
        result.set("firstPlayedAt", first.map(SyncSnapshot.milliseconds) ?? 0)
        result.set("lastPlayedAt", last.map(SyncSnapshot.milliseconds) ?? 0)
        if let day { result.set("dayStartAt", SyncSnapshot.milliseconds(day)) }
        return result
    }

    private func trackID(_ song: SyncRecord, db: Database) throws -> UUID? {
        guard let online = song.onlineSong else { return nil }
        if let track = try TrackRecord.filter(Column("url") == online.identityURL.absoluteString).fetchOne(db) { return track.id }
        let track = TrackRecord(track: online.track(), album: online.album)
        try track.insert(db); return track.id
    }

    private func applyPlaylists(_ snapshot: SyncSnapshot, state: inout SyncJournalState, db: Database) throws {
        for playlist in snapshot.playlists {
            let identifier = playlist.number("id")
            if identifier == -1_001 {
                try applyFavorites(playlist, db: db)
                continue
            }
            let localKey = state.playlistIDs.first { $0.value == identifier }?.key
            let id = localKey.flatMap(UUID.init(uuidString:)) ?? UUID()
            state.playlistIDs[id.uuidString] = identifier
            if playlist.flag("isDeleted") { try PlaylistRecord.deleteOne(db, key: id); continue }
            let existing = try PlaylistRecord.fetchOne(db, key: id)
            let created = Date(timeIntervalSince1970: Double(playlist.number("createdAt")) / 1_000)
            let record = existing ?? PlaylistRecord(id: id, name: playlist.text("name"), createdAt: created)
            record.name = playlist.text("name")
            record.updatedAt = Date(timeIntervalSince1970: Double(playlist.number("modifiedAt")) / 1_000)
            try record.save(db)
            let entries = try PlaylistEntryRecord.filter(Column("playlistId") == id).order(Column("position")).fetchAll(db)
            var localEntries: [PlaylistEntryRecord] = []
            for entry in entries {
                if let track = try TrackRecord.fetchOne(db, key: entry.trackId), URL(string: track.url)?.isFileURL == true { localEntries.append(entry) }
            }
            try PlaylistEntryRecord.filter(Column("playlistId") == id).deleteAll(db)
            var position = 0, seen: Set<UUID> = []
            for song in playlist.records("songs") {
                guard let track = try trackID(song, db: db), seen.insert(track).inserted else { continue }
                try PlaylistEntryRecord(playlistId: id, trackId: track, position: position,
                    addedAt: Date(timeIntervalSince1970: Double(song.number("addedAt")) / 1_000)).insert(db)
                position += 1
            }
            for entry in localEntries { entry.position = position; try entry.insert(db); position += 1 }
        }
    }

    private func applyFavorites(_ playlist: SyncRecord, db: Database) throws {
        // Local-file favorites never participate in remote deletion.
        let onlineIDs = try TrackRecord.fetchAll(db).filter { URL(string: $0.url)?.scheme == "neriplayer-online" }.map(\.id)
        for id in onlineIDs { _ = try FavoriteRecord.deleteOne(db, key: id) }
        for song in playlist.records("songs") {
            if let id = try trackID(song, db: db) {
                try FavoriteRecord(trackId: id, favoritedAt: Date(timeIntervalSince1970: Double(song.number("addedAt")) / 1_000)).save(db)
            }
        }
    }

    private func applyHistoryAndStats(_ snapshot: SyncSnapshot, state: inout SyncJournalState, db: Database) throws {
        let onlineTracks = try TrackRecord.fetchAll(db).filter { URL(string: $0.url)?.scheme == "neriplayer-online" }
        for track in onlineTracks {
            _ = try PlayHistoryRecord.deleteOne(db, key: track.id)
            _ = try PlaybackStatsRecord.deleteOne(db, key: track.id)
            try PlaybackStatsDailyBucketRecord.filter(Column("trackId") == track.id).deleteAll(db)
        }
        for play in snapshot.record.records("recentPlays") {
            guard let id = try trackID(play.songRecord, db: db) else { continue }
            try PlayHistoryRecord(trackId: id, playedAt: Date(timeIntervalSince1970: Double(play.number("playedAt")) / 1_000),
                resumePositionSeconds: Double(play.number("resumePositionMs")) / 1_000).save(db)
        }
        for stat in snapshot.record.records("playbackStats") {
            guard let id = try trackID(stat, db: db) else { continue }
            try PlaybackStatsRecord(trackId: id, totalListenSeconds: Double(stat.number("totalListenMs")) / 1_000,
                playCount: Int(stat.number("playCount")), firstPlayedAt: date(stat.number("firstPlayedAt")),
                lastPlayedAt: date(stat.number("lastPlayedAt"))).save(db)
        }
        for bucket in snapshot.record.records("playbackStatBuckets") {
            guard let id = try trackID(bucket, db: db) else { continue }
            try PlaybackStatsDailyBucketRecord(dayStart: Date(timeIntervalSince1970: Double(bucket.number("dayStartAt")) / 1_000),
                trackId: id, totalListenSeconds: Double(bucket.number("totalListenMs")) / 1_000, playCount: Int(bucket.number("playCount")),
                firstPlayedAt: date(bucket.number("firstPlayedAt")), lastPlayedAt: date(bucket.number("lastPlayedAt"))).save(db)
        }
    }
    private func date(_ milliseconds: Int64) -> Date? {
        milliseconds > 0 ? Date(timeIntervalSince1970: Double(milliseconds) / 1_000) : nil
    }
}
