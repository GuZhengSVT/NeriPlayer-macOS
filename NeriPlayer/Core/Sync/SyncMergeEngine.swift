// SyncMergeEngine.swift
// M7: Android-compatible playlist, observed-remove, history and counter merge policies.

import Foundation

public struct SyncMergeResult: Sendable {
    public var snapshot: SyncSnapshot
    public var conflicts: [String]
}

public enum SyncMergeEngine {
    public static func merge(local: SyncSnapshot, remote: SyncSnapshot, lastSyncTime: Int64 = 0) -> SyncMergeResult {
        var result = local.sanitized()
        let remote = remote.sanitized()
        for (key, value) in remote.record.fields where result.record.fields[key] == nil { result.record.fields[key] = value }
        let deletions = mergeSongDeletions(local.record.records("playlistSongDeletions"), remote.record.records("playlistSongDeletions"))
        let locals = index(local.playlists, key: { String($0.number("id")) })
        let remotes = index(remote.playlists, key: { String($0.number("id")) })
        let remoteOnlyChanged = !local.playlists.contains { $0.number("modifiedAt") > lastSyncTime } &&
            remote.playlists.contains { $0.number("modifiedAt") > lastSyncTime }
        let primary = remoteOnlyChanged ? remote.playlists : local.playlists
        let secondary = remoteOnlyChanged ? local.playlists : remote.playlists
        let ids = unique((primary + secondary).map { String($0.number("id")) })
        var conflicts: [String] = []
        result.playlists = ids.compactMap { id in
            guard let left = locals[id] else { return remotes[id].map { applyDeletions(normalizeOrder($0), deletions) } }
            guard let right = remotes[id] else { return applyDeletions(normalizeOrder(left), deletions) }
            var merged = mergePlaylist(normalizeOrder(left), normalizeOrder(right), lastSyncTime, conflicts: &conflicts)
            merged = applyDeletions(merged, deletions)
            return normalizeOrder(merged)
        }
        result.record.set("playlistSongDeletions", limitSongDeletions(deletions))
        result.record.set("favoritePlaylists", mergeFavorites(local.record.records("favoritePlaylists"), remote.record.records("favoritePlaylists")))
        let recentDeletions = mergeLatest(local.record.records("recentPlayDeletions") + remote.record.records("recentPlayDeletions"),
                                          key: { $0.rawIdentityKey }, time: "deletedAt")
        let recent = mergeLatest(local.record.records("recentPlays") + remote.record.records("recentPlays"),
                                 key: { $0.songRecord.identityKey }, time: "playedAt", tie: "resumePositionMs")
        let deletedByKey = index(recentDeletions, key: { $0.rawIdentityKey })
        let history = recent.filter { play in
            let song = play.songRecord
            let deletion = deletedByKey[song.identityKey] ?? deletedByKey[song.rawIdentityKey]
            return deletion == nil || play.number("playedAt") > (deletion?.number("deletedAt") ?? 0)
        }.sorted { $0.number("playedAt") > $1.number("playedAt") }
        result.record.set("recentPlays", Array(history.prefix(500)))
        result.record.set("recentPlayDeletions", Array(recentDeletions.sorted { $0.number("deletedAt") > $1.number("deletedAt") }.prefix(500)))
        let clear = max(local.record.number("playbackStatsClearedAt"), remote.record.number("playbackStatsClearedAt"))
        result.record.set("playbackStatsClearedAt", clear)
        var stats = SyncCounterMerge.merge(local.record.records("playbackStats") + remote.record.records("playbackStats"), clear: clear)
        let buckets = SyncCounterMerge.merge(local.record.records("playbackStatBuckets") + remote.record.records("playbackStatBuckets"),
                                            clear: clear, bucket: true)
        stats = SyncCounterMerge.lift(stats, buckets: buckets)
        result.record.set("playbackStats", Array(stats.sorted {
            $0.number("lastPlayedAt") == $1.number("lastPlayedAt") ? $0.text("identityKey") < $1.text("identityKey") :
                $0.number("lastPlayedAt") > $1.number("lastPlayedAt")
        }.prefix(2_000)))
        result.record.set("playbackStatBuckets", SyncCounterMerge.trimBuckets(buckets))
        result.record.set("syncLog", Array(mergeLatest(local.record.records("syncLog") + remote.record.records("syncLog"),
            key: { String($0.number("timestamp")) }, time: "timestamp").sorted { $0.number("timestamp") > $1.number("timestamp") }.prefix(100)))
        for key in ["playlistUsageStats", "localPlaylistPlaybackStats", "localPlaylistPlaybackBuckets"] {
            result.record.set(key, SyncCounterMerge.mergeUsage(local.record.records(key) + remote.record.records(key), kind: key))
        }
        result.record.set("biliVideoSkipRules", mergeSkipRules(local.record.records("biliVideoSkipRules") + remote.record.records("biliVideoSkipRules")))
        result.record.set("lastModified", max(local.record.number("lastModified"), remote.record.number("lastModified")))
        return SyncMergeResult(snapshot: result, conflicts: conflicts)
    }

    static func normalizeOrder(_ playlist: SyncRecord) -> SyncRecord {
        var result = playlist
        if playlist.flag("isDeleted") { result.set("songs", []); return result }
        var songs = playlist.records("songs")
        if playlist.number("songOrderVersion") < 1 {
            let anchor = max(1, playlist.number("modifiedAt"), songs.map { $0.number("addedAt") }.max() ?? 0)
            songs = songs.reversed().enumerated().map { index, song in
                var result = song
                result.set("legacyAddedAt", song.number("legacyAddedAt", default: song.number("addedAt")))
                result.set("addedAt", max(1, anchor - Int64(index)))
                return result
            }
        } else {
            songs = songs.enumerated().sorted {
                let left = $0.element.number("addedAt"), right = $1.element.number("addedAt")
                return left == right ? $0.offset < $1.offset : left > right
            }.map(\.element)
        }
        result.set("songs", songs); result.set("songOrderVersion", Int64(1)); return result
    }

    private static func mergePlaylist(_ left: SyncRecord, _ right: SyncRecord, _ lastSync: Int64,
                                      conflicts: inout [String]) -> SyncRecord {
        let localChanged = left.number("modifiedAt") > lastSync
        let remoteChanged = right.number("modifiedAt") > lastSync
        var result = left
        if left.flag("isDeleted") || right.flag("isDeleted") {
            let deleted = left.flag("isDeleted") ? left : right
            let active = left.flag("isDeleted") ? right : left
            result = deleted.number("modifiedAt") >= active.number("modifiedAt") || active.flag("isDeleted") ? deleted : active
            if result.flag("isDeleted") { result.set("songs", []) }
            return result
        }
        if left.text("name") != right.text("name") {
            if remoteChanged && !localChanged {
                result.set("name", right.text("name"))
            } else if localChanged && remoteChanged {
                conflicts.append("歌单“\(left.text("name"))”两端改名，保留本地名称")
            }
        }
        let localSongs = left.records("songs"), remoteSongs = right.records("songs")
        let localTokens = localSongs.contains { !$0.records("syncMembershipTokens").isEmpty }
        let remoteTokens = remoteSongs.contains { !$0.records("syncMembershipTokens").isEmpty }
        let primary: [SyncRecord]
        let secondary: [SyncRecord]
        let matchingOnly: Bool
        if localSongs.isEmpty && !remoteSongs.isEmpty {
            let favoritesFirst = left.number("id") == -1_001 && lastSync <= 0
            primary = favoritesFirst || remoteTokens || !(localChanged && left.number("modifiedAt") >= right.number("modifiedAt")) ? remoteSongs : []
            secondary = []; matchingOnly = false
        } else if remoteSongs.isEmpty && !localSongs.isEmpty {
            primary = localTokens || !(remoteChanged && right.number("modifiedAt") > left.number("modifiedAt")) ? localSongs : []
            secondary = []; matchingOnly = false
        } else if remoteChanged && !localChanged {
            primary = remoteSongs; secondary = localSongs; matchingOnly = true
        } else if localChanged && !remoteChanged {
            primary = localSongs; secondary = remoteSongs; matchingOnly = true
        } else {
            let remoteNewer = localChanged && right.number("modifiedAt") > left.number("modifiedAt")
            primary = remoteNewer ? remoteSongs : localSongs
            secondary = remoteNewer ? localSongs : remoteSongs
            matchingOnly = false
        }
        result.set("songs", mergeSongs(primary, secondary, matchingOnly: matchingOnly,
                                        deterministic: left.number("modifiedAt") == right.number("modifiedAt")))
        result.set("createdAt", minPositive(left.number("createdAt"), right.number("createdAt")))
        result.set("modifiedAt", max(left.number("modifiedAt"), right.number("modifiedAt")))
        result.set("songOrderVersion", Int64(1))
        return result
    }

    static func tokens(_ records: [SyncRecord]) -> [SyncRecord] {
        var byKey: [String: SyncRecord] = [:]
        for token in records where !token.text("deviceId").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && token.number("counter") > 0 {
            byKey["\(token.text("deviceId"))|\(token.number("counter"))"] = token
        }
        return byKey.values.sorted {
            $0.text("deviceId") == $1.text("deviceId") ? $0.number("counter") < $1.number("counter") : $0.text("deviceId") < $1.text("deviceId")
        }
    }

    static func mergeSongs(_ primary: [SyncRecord], _ secondary: [SyncRecord], matchingOnly: Bool = false,
                           deterministic: Bool = false) -> [SyncRecord] {
        var result: [SyncRecord] = []
        for (index, song) in (primary + secondary).enumerated() {
            let matching = result.indices.filter { matches(result[$0], song) }
            guard let first = matching.first else {
                if !matchingOnly || index < primary.count { result.append(song) }
                continue
            }
            let candidates = matching.map { result[$0] } + [song]
            let current = candidates.filter { $0.number("syncMetadataVersion") >= 1 }
            var selected = deterministic ? (candidates.max { payloadKey($0) < payloadKey($1) } ?? song) : result[first]
            if selected.number("syncMetadataVersion") < 1, let modern = current.max(by: { payloadKey($0) < payloadKey($1) }) {
                selected = modern
            } else if selected.number("syncMetadataVersion") < 1 {
                for candidate in candidates {
                    for (key, value) in candidate.fields where selected.fields[key] == nil || selected.fields[key] == .string("") {
                        selected.fields[key] = value
                    }
                }
            }
            selected.set("syncMembershipTokens", tokens(candidates.flatMap { $0.records("syncMembershipTokens") }))
            selected.set("syncMetadataVersion", Int64(1))
            result[first] = selected
            for index in matching.dropFirst().reversed() { result.remove(at: index) }
        }
        return result
    }

    private static func payloadKey(_ song: SyncRecord) -> String {
        let keys = ["id", "name", "artist", "album", "albumId", "durationMs", "coverUrl", "mediaUri", "addedAt",
                    "matchedLyric", "matchedTranslatedLyric", "matchedLyricSource", "matchedSongId", "userLyricOffsetMs",
                    "customCoverUrl", "customName", "customArtist", "originalName", "originalArtist", "originalCoverUrl",
                    "originalLyric", "originalTranslatedLyric", "channelId", "audioId", "subAudioId", "playlistContextId", "syncMetadataVersion"]
        let numeric = Set(["id", "albumId", "durationMs", "addedAt", "userLyricOffsetMs", "syncMetadataVersion"])
        return keys.map { key in
            let value = numeric.contains(key) ? String(song.number(key)) : song.text(key)
            return "\(value.utf16.count):\(value)"
        }.joined()
    }

    private static func matches(_ left: SyncRecord, _ right: SyncRecord) -> Bool {
        if left.identityKey == right.identityKey { return true }
        let lhsTokens = tokens(left.records("syncMembershipTokens"))
        if tokens(right.records("syncMembershipTokens")).contains(where: { lhsTokens.contains($0) }) { return true }
        if !left.audioID.isEmpty && left.channel == right.channel && left.audioID == right.audioID && left.subAudioID == right.subAudioID { return true }
        return left.number("id") != 0 && left.number("id") == right.number("id") && left.channel == right.channel &&
            left.text("name").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ==
            right.text("name").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() &&
            left.text("artist").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ==
            right.text("artist").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func mergeSongDeletions(_ local: [SyncRecord], _ remote: [SyncRecord]) -> [SyncRecord] {
        let grouped = Dictionary(grouping: local + remote) {
            "\($0.number("playlistId"))|\($0.rawIdentityKey)|\(!$0.records("removedMembershipTokens").isEmpty)"
        }
        return grouped.values.compactMap { candidates in
            guard var selected = candidates.max(by: { ($0.number("deletedAt"), $0.text("deviceId")) < ($1.number("deletedAt"), $1.text("deviceId")) }) else {
                return nil
            }
            selected.set("removedMembershipTokens", tokens(candidates.flatMap { $0.records("removedMembershipTokens") }))
            return selected
        }
    }

    private static func limitSongDeletions(_ records: [SyncRecord]) -> [SyncRecord] {
        let sorted = records.sorted { $0.number("deletedAt") > $1.number("deletedAt") }
        if sorted.count <= 5_000 { return sorted }
        let legacy = sorted.filter { $0.records("removedMembershipTokens").isEmpty }
        let causal = sorted.filter { !$0.records("removedMembershipTokens").isEmpty }
        let legacyCount = min(legacy.count, causal.isEmpty ? 5_000 : 2_500)
        let causalCount = min(causal.count, 5_000 - legacyCount)
        return Array(legacy.prefix(min(legacy.count, 5_000 - causalCount))) + Array(causal.prefix(causalCount))
    }

    private static func applyDeletions(_ playlist: SyncRecord, _ deletions: [SyncRecord]) -> SyncRecord {
        var result = playlist
        let relevant = deletions.filter { $0.number("playlistId") == playlist.number("id") }
        let removed = tokens(relevant.flatMap { $0.records("removedMembershipTokens") })
        result.set("songs", playlist.records("songs").compactMap { song in
            let membership = tokens(song.records("syncMembershipTokens"))
            if !membership.isEmpty {
                let remaining = membership.filter { !removed.contains($0) }
                guard !remaining.isEmpty else { return nil }
                var result = song; result.set("syncMembershipTokens", remaining); return result
            }
            let latest = relevant.filter { $0.rawIdentityKey == song.identityKey || $0.rawIdentityKey == song.rawIdentityKey }
                .map { $0.number("deletedAt") }.max()
            return latest == nil || song.number("legacyAddedAt", default: song.number("addedAt")) > (latest ?? 0) ? song : nil
        })
        return result
    }

    private static func mergeFavorites(_ local: [SyncRecord], _ remote: [SyncRecord]) -> [SyncRecord] {
        Dictionary(grouping: local + remote, by: { "\($0.number("id"))|\($0.text("source"))" }).values.compactMap { candidates in
            guard var latest = candidates.max(by: {
                ($0.number("modifiedAt", default: $0.number("addedTime")), $0.flag("isDeleted") ? 1 : 0) <
                ($1.number("modifiedAt", default: $1.number("addedTime")), $1.flag("isDeleted") ? 1 : 0)
            }) else { return nil }
            latest.set("songs", latest.flag("isDeleted") ? [] : mergeSongs(candidates.flatMap { $0.records("songs") }, []))
            let count = max(Int64(latest.records("songs").count), candidates.map { $0.number("trackCount") }.max() ?? 0)
            latest.set("trackCount", latest.flag("isDeleted") ? 0 : count)
            return latest
        }.sorted { $0.number("sortOrder", default: $0.number("addedTime")) > $1.number("sortOrder", default: $1.number("addedTime")) }
    }

    private static func mergeSkipRules(_ records: [SyncRecord]) -> [SyncRecord] {
        Dictionary(grouping: records, by: { "\($0.text("bvid"))|\($0.number("cid"))" }).values.compactMap { candidates in
            guard var latest = candidates.max(by: { $0.number("modifiedAt") < $1.number("modifiedAt") }) else { return nil }
            let tied = candidates.filter { $0.number("modifiedAt") == latest.number("modifiedAt") && !$0.flag("isDeleted") }
            if !tied.isEmpty {
                latest.set("isDeleted", false)
                let intervals = tied.flatMap { $0.records("intervals") }.filter { $0.number("startMs") >= 0 && $0.number("endMs") > $0.number("startMs") }
                    .sorted { $0.number("startMs") < $1.number("startMs") }
                var merged: [SyncRecord] = []
                for interval in intervals {
                    if let previous = merged.last, interval.number("startMs") <= previous.number("endMs") {
                        merged[merged.count - 1].set("endMs", max(previous.number("endMs"), interval.number("endMs")))
                    } else { merged.append(interval) }
                }
                latest.set("intervals", merged)
            } else { latest.set("intervals", []) }
            return latest
        }.sorted { ($0.text("bvid"), $0.number("cid")) < ($1.text("bvid"), $1.number("cid")) }
    }

    static func minPositive(_ left: Int64, _ right: Int64) -> Int64 {
        left <= 0 ? max(0, right) : (right <= 0 ? left : min(left, right))
    }
    private static func index(_ records: [SyncRecord], key: (SyncRecord) -> String) -> [String: SyncRecord] {
        var result: [String: SyncRecord] = [:]
        for record in records { result[key(record)] = record }
        return result
    }
    private static func unique(_ strings: [String]) -> [String] {
        var seen: Set<String> = []; return strings.filter { seen.insert($0).inserted }
    }
    private static func mergeLatest(_ records: [SyncRecord], key: (SyncRecord) -> String, time: String, tie: String = "") -> [SyncRecord] {
        Dictionary(grouping: records, by: key).values.compactMap { candidates in
            candidates.max { ($0.number(time), $0.number(tie), $0.text("deviceId")) < ($1.number(time), $1.number(tie), $1.text("deviceId")) }
        }
    }
}
