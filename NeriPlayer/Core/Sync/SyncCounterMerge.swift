// SyncCounterMerge.swift
// M7: per-device monotone counters, clear epochs and pre-trim bucket-total lifting.

import Foundation

enum SyncCounterMerge {
    static func sum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { total, value in
            let value = max(0, value)
            return Int64.max - total < value ? Int64.max : total + value
        }
    }

    static func shards(_ records: [SyncRecord]) -> [SyncRecord] {
        let grouped = Dictionary(grouping: records.filter { !$0.text("deviceId").isEmpty }) {
            "\($0.text("deviceId"))|\($0.number("epochStartedAt"))"
        }
        return grouped.values.compactMap { candidates in
            guard var result = candidates.first else { return nil }
            for candidate in candidates {
                for key in ["totalListenMs", "playCount", "lastPlayedAt"] {
                    result.set(key, max(0, result.number(key), candidate.number(key)))
                }
                result.set("firstPlayedAt", SyncMergeEngine.minPositive(result.number("firstPlayedAt"), candidate.number("firstPlayedAt")))
            }
            return result
        }.sorted { ($0.text("deviceId"), $0.number("epochStartedAt")) < ($1.text("deviceId"), $1.number("epochStartedAt")) }
    }

    static func merge(_ records: [SyncRecord], clear: Int64 = 0, bucket: Bool = false) -> [SyncRecord] {
        let normalized = records.compactMap { record -> SyncRecord? in
            guard clear <= 0 || record.number("lastPlayedAt") >= clear else { return nil }
            var result = record
            let existing = shards(record.records("counterShards"))
            result.set("counterShards", clear <= 0 ? existing : existing.filter { $0.number("lastPlayedAt") >= clear })
            if clear > 0 {
                if !existing.isEmpty {
                    result.set("counterBaseListenMs", Int64(0)); result.set("counterBasePlayCount", Int64(0))
                }
                let first = result.number("firstPlayedAt")
                if first < clear || first > result.number("lastPlayedAt") { result.set("firstPlayedAt", result.number("lastPlayedAt")) }
            }
            return result
        }
        let grouped = Dictionary(grouping: normalized) {
            (bucket ? "\($0.number("dayStartAt"))|" : "") + $0.text("identityKey", default: $0.identityKey)
        }
        return grouped.values.compactMap { candidates in
            guard var latest = candidates.max(by: { $0.number("lastPlayedAt") < $1.number("lastPlayedAt") }) else { return nil }
            let merged = shards(candidates.flatMap { $0.records("counterShards") })
            let baseListen = candidates.map { base($0, key: "counterBaseListenMs", total: "totalListenMs") }.max() ?? 0
            let baseCount = candidates.map { base($0, key: "counterBasePlayCount", total: "playCount") }.max() ?? 0
            let totalListen = max(candidates.map { $0.number("totalListenMs") }.max() ?? 0,
                                  merged.isEmpty ? 0 : sum([baseListen] + merged.map { $0.number("totalListenMs") }))
            let totalCount = max(candidates.map { $0.number("playCount") }.max() ?? 0,
                                 merged.isEmpty ? 0 : sum([baseCount] + merged.map { $0.number("playCount") }))
            latest.set("totalListenMs", max(0, totalListen)); latest.set("playCount", min(Int64(Int32.max), max(0, totalCount)))
            latest.set("counterBaseListenMs", merged.isEmpty ? 0 : baseListen)
            latest.set("counterBasePlayCount", merged.isEmpty ? 0 : baseCount)
            latest.set("counterShards", merged)
            latest.set("firstPlayedAt", (candidates + merged).map { $0.number("firstPlayedAt") }.filter { $0 > 0 }.min() ?? 0)
            latest.set("lastPlayedAt", (candidates + merged).map { $0.number("lastPlayedAt") }.max() ?? 0)
            return latest
        }
    }

    private static func base(_ record: SyncRecord, key: String, total: String) -> Int64 {
        record.records("counterShards").isEmpty && record.number(key) == 0 ? max(0, record.number(total)) : max(0, record.number(key))
    }

    static func lift(_ stats: [SyncRecord], buckets: [SyncRecord]) -> [SyncRecord] {
        var byKey: [String: SyncRecord] = [:]
        for stat in stats { byKey[stat.text("identityKey")] = stat }
        for (key, values) in Dictionary(grouping: buckets, by: { $0.text("identityKey") }) {
            guard let newest = values.max(by: { $0.number("lastPlayedAt") < $1.number("lastPlayedAt") }) else { continue }
            var result = byKey[key] ?? newest
            result.fields.removeValue(forKey: "dayStartAt")
            result.set("totalListenMs", max(result.number("totalListenMs"), sum(values.map { $0.number("totalListenMs") })))
            result.set("playCount", min(Int64(Int32.max), max(result.number("playCount"), sum(values.map { $0.number("playCount") }))))
            byKey[key] = result
        }
        return Array(byKey.values)
    }

    static func trimBuckets(_ records: [SyncRecord]) -> [SyncRecord] {
        let anchor = records.map { $0.number("dayStartAt") }.max() ?? 0
        return Array(records.filter { $0.number("dayStartAt") >= anchor - 400 * 86_400_000 }.sorted {
            if $0.number("dayStartAt") != $1.number("dayStartAt") { return $0.number("dayStartAt") > $1.number("dayStartAt") }
            if $0.number("playCount") != $1.number("playCount") { return $0.number("playCount") > $1.number("playCount") }
            return $0.text("identityKey") < $1.text("identityKey")
        }.prefix(8_000))
    }

    static func mergeUsage(_ records: [SyncRecord], kind: String) -> [SyncRecord] {
        let usage = kind == "playlistUsageStats"
        let bucket = kind == "localPlaylistPlaybackBuckets"
        let countKey = usage ? "openCount" : (bucket ? "playCount" : "totalPlayCount")
        let baseKey = usage ? "counterBaseOpenCount" : "counterBasePlayCount"
        let firstKey = usage ? "firstOpenedAt" : "firstPlayedAt"
        let lastKey = usage ? "lastOpenedAt" : "lastPlayedAt"
        let grouped = Dictionary(grouping: records) {
            usage ? $0.text("playlistKey") : "\($0.number("playlistId"))" + (bucket ? "|\($0.number("dayStartAt"))" : "")
        }
        var merged = grouped.keys.sorted().compactMap { key -> SyncRecord? in
            let candidates = grouped[key] ?? []
            guard var latest = candidates.max(by: { $0.number(lastKey) < $1.number(lastKey) }) else { return nil }
            let counters = shards(candidates.flatMap { $0.records("counterShards") })
            let baseCount = candidates.map { base($0, key: baseKey, total: countKey) }.max() ?? 0
            let total = max(candidates.map { $0.number(countKey) }.max() ?? 0,
                            counters.isEmpty ? 0 : sum([baseCount] + counters.map { $0.number("playCount") }))
            latest.set(countKey, usage ? min(Int64(Int32.max), total) : total)
            latest.set(baseKey, counters.isEmpty ? 0 : baseCount)
            latest.set("counterShards", counters)
            latest.set(firstKey, candidates.map { $0.number(firstKey) }.filter { $0 > 0 }.min() ?? 0)
            latest.set(lastKey, candidates.map { $0.number(lastKey) }.max() ?? 0)
            return latest
        }
        if bucket { merged = trimBuckets(merged) }
        return merged
    }
}
