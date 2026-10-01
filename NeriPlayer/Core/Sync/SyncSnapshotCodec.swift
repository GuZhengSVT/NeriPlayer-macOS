// SyncSnapshotCodec.swift
// M7: bounded JSON and Android GZIP/ProtoBuf read compatibility; uploads use JSON.

import Foundation
import zlib

public enum SyncSnapshotCodec {
    public static let jsonLimit = 8 * 1_024 * 1_024
    public static let compressedLimit = 12 * 1_024 * 1_024
    public static let decompressedLimit = 16 * 1_024 * 1_024

    public static func encode(_ snapshot: SyncSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try AndroidSyncProto.validate(snapshot.record)
        let data = try encoder.encode(snapshot.sanitized())
        guard data.count <= jsonLimit else { throw SyncError.tooLarge }
        return data
    }

    public static func decode(_ input: Data) throws -> SyncSnapshot {
        guard !input.isEmpty, input.count <= compressedLimit else { throw SyncError.tooLarge }
        var bytes = input
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes = Data(bytes.dropFirst(3)) }
        let snapshot: SyncSnapshot
        if bytes.first(where: { ![9, 10, 13, 32].contains($0) }) == 123 {
            guard bytes.count <= jsonLimit else { throw SyncError.tooLarge }
            do { snapshot = try JSONDecoder().decode(SyncSnapshot.self, from: bytes) } catch { throw SyncError.invalidSnapshot }
        } else {
            if !bytes.starts(with: [0x1f, 0x8b]) {
                guard let text = String(data: bytes, encoding: .utf8),
                      let decoded = Data(base64Encoded: text.filter { !$0.isWhitespace }) else { throw SyncError.invalidSnapshot }
                bytes = decoded
            }
            let proto = try gunzip(bytes)
            var decoded = SyncSnapshot()
            do {
                decoded.record = try AndroidSyncProto.decode(proto, message: "snapshot")
            } catch {
                decoded.record = try AndroidSyncProto.decode(proto, message: "snapshot", legacy: true)
            }
            snapshot = decoded
        }
        let version = snapshot.record.text("version", default: "2.0")
        guard ["1.0", "2.0"].contains(version) else { throw SyncError.unsupportedVersion(version) }
        try AndroidSyncProto.validate(snapshot.record)
        return snapshot.sanitized()
    }

    private static func gunzip(_ input: Data) throws -> Data {
        guard input.starts(with: [0x1f, 0x8b]), input.count <= compressedLimit else { throw SyncError.invalidSnapshot }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw SyncError.invalidSnapshot
        }
        defer { inflateEnd(&stream) }
        return try input.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 32_768)
            while true {
                let status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = chunk.count - Int(stream.avail_out)
                guard output.count + count <= decompressedLimit else { throw SyncError.tooLarge }
                output.append(contentsOf: chunk.prefix(count))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw SyncError.invalidSnapshot }
                    return output
                }
                guard status == Z_OK, count > 0 || stream.avail_in > 0 else { throw SyncError.invalidSnapshot }
            }
        }
    }
}

// Field numbers follow Android @ProtoNumber declarations; unknown wire fields are skipped.
enum AndroidSyncProto {
    struct Field {
        var name: String
        var kind: String
        var repeated: Bool = false
    }
    private static let layouts: [String: String] = [
        "snapshot": "version:s deviceId:s deviceName:s lastModified:n playlists:[playlist favoritePlaylists:[favorite " +
            "recentPlays:[recent syncLog:[log recentPlayDeletions:[recentDeletion playbackStats:[stat playbackStatsClearedAt:n " +
            "playbackStatBuckets:[bucket playlistSongDeletions:[songDeletion playlistUsageStats:[usage " +
            "localPlaylistPlaybackStats:[playlistStat localPlaylistPlaybackBuckets:[playlistBucket biliVideoSkipRules:[skip",
        "playlist": "id:n name:s songs:[song createdAt:n modifiedAt:n isDeleted:b songOrderVersion:n",
        "song": "id:n name:s artist:s album:s albumId:n durationMs:n coverUrl:s mediaUri:s addedAt:n matchedLyric:s " +
            "matchedTranslatedLyric:s matchedLyricSource:s matchedSongId:s userLyricOffsetMs:n customCoverUrl:s customName:s " +
            "customArtist:s originalName:s originalArtist:s originalCoverUrl:s originalLyric:s originalTranslatedLyric:s " +
            "channelId:s audioId:s subAudioId:s playlistContextId:s syncMembershipTokens:[token syncMetadataVersion:n legacyAddedAt:n",
        "favorite": "id:n name:s coverUrl:s trackCount:n source:s songs:[song addedTime:n modifiedAt:n isDeleted:b " +
            "sortOrder:n browseId:s playlistId:s subtitle:s",
        "recent": "songId:n song:song playedAt:n deviceId:s resumePositionMs:n",
        "recentDeletion": "songId:n album:s mediaUri:s deletedAt:n deviceId:s",
        "songDeletion": "playlistId:n songId:n album:s mediaUri:s deletedAt:n deviceId:s removedMembershipTokens:[token",
        "token": "deviceId:s counter:n",
        "log": "timestamp:n deviceId:s action:e playlistId:n songId:n details:s",
        "shard": "deviceId:s epochStartedAt:n totalListenMs:n playCount:n firstPlayedAt:n lastPlayedAt:n",
        "stat": "identityKey:s name:s artist:s album:s totalListenMs:n playCount:n lastPlayedAt:n firstPlayedAt:n coverUrl:s " +
            "durationMs:n mediaUri:s id:n albumId:n counterBaseListenMs:n counterBasePlayCount:n counterShards:[shard",
        "bucket": "dayStartAt:n identityKey:s name:s artist:s album:s totalListenMs:n playCount:n lastPlayedAt:n firstPlayedAt:n " +
            "coverUrl:s durationMs:n mediaUri:s id:n albumId:n counterBaseListenMs:n counterBasePlayCount:n counterShards:[shard",
        "usage": "playlistKey:s source:s id:n subtype:s name:s coverUrl:s trackCount:n lastOpenedAt:n firstOpenedAt:n " +
            "openCount:n counterBaseOpenCount:n counterShards:[shard fid:n mid:n browseId:s playlistId:s subtitle:s",
        "playlistStat": "playlistId:n totalPlayCount:n lastPlayedAt:n firstPlayedAt:n counterBasePlayCount:n counterShards:[shard",
        "playlistBucket": "dayStartAt:n playlistId:n playCount:n lastPlayedAt:n firstPlayedAt:n counterBasePlayCount:n counterShards:[shard",
        "skip": "bvid:s cid:n intervals:[interval modifiedAt:n isDeleted:b",
        "interval": "startMs:n endMs:n"
    ]
    private static let actions = ["CREATE_PLAYLIST", "DELETE_PLAYLIST", "RENAME_PLAYLIST", "ADD_SONG",
                                  "REMOVE_SONG", "REORDER_SONGS", "PLAY_SONG"]

    static func jsonSchema() throws -> SyncRecord {
        var definitions: [String: SyncValue] = [:]
        for message in layouts.keys.sorted() {
            var properties: [String: SyncValue] = [:]
            for field in try fields(for: message) {
                let schema: SyncRecord
                switch field.kind {
                case "n": schema = SyncRecord(["type": .array([.string("integer"), .string("null")])])
                case "s", "e": schema = SyncRecord(["type": .array([.string("string"), .string("null")])])
                case "b": schema = SyncRecord(["type": .array([.string("boolean"), .string("null")])])
                default: schema = SyncRecord(["$ref": .string("#/$defs/" + field.kind)])
                }
                properties[field.name] = field.repeated ? .object([
                    "type": .array([.string("array"), .string("null")]), "items": .object(schema.fields)]) : .object(schema.fields)
            }
            definitions[message] = .object(["type": .string("object"), "properties": .object(properties),
                                            "additionalProperties": .bool(true)])
        }
        return SyncRecord(["$schema": .string("https://json-schema.org/draft/2020-12/schema"),
                           "title": .string("NeriPlayer Android-compatible SyncData 2.0"),
                           "$ref": .string("#/$defs/snapshot"), "$defs": .object(definitions)])
    }

    static func fields(for message: String, legacy: Bool = false) throws -> [Field] {
        guard let layout = layouts[message] else { throw SyncError.invalidSnapshot }
        var fields = layout.split(separator: " ").map { part -> Field in
            let pair = part.split(separator: ":", maxSplits: 1).map(String.init)
            return Field(name: pair[0], kind: pair[1].hasPrefix("[") ? String(pair[1].dropFirst()) : pair[1],
                         repeated: pair[1].hasPrefix("["))
        }
        if legacy && message == "song" { fields.remove(at: 7); fields = Array(fields.prefix(21)) }
        return fields
    }

    static func validate(_ record: SyncRecord, message: String = "snapshot", depth: Int = 0) throws {
        guard depth <= 8 else { throw SyncError.invalidSnapshot }
        for field in try fields(for: message) {
            guard let value = record.fields[field.name], value != .null else { continue }
            if field.repeated {
                guard case .array(let values) = value else { throw SyncError.invalidSnapshot }
                for value in values {
                    guard case .object(let fields) = value else { throw SyncError.invalidSnapshot }
                    try validate(SyncRecord(fields), message: field.kind, depth: depth + 1)
                }
            } else {
                try validateScalar(value, field: field, depth: depth)
            }
        }
    }
    private static func validateScalar(_ value: SyncValue, field: Field, depth: Int) throws {
        switch (field.kind, value) {
        case ("n", .integer), ("s", .string), ("e", .string), ("b", .bool): return
        case (_, .object(let fields)):
            try validate(SyncRecord(fields), message: field.kind, depth: depth + 1)
        default: throw SyncError.invalidSnapshot
        }
    }

    static func decode(_ data: Data, message: String, legacy: Bool = false, depth: Int = 0) throws -> SyncRecord {
        guard depth <= 8 else { throw SyncError.invalidSnapshot }
        let fields = try fields(for: message, legacy: legacy)
        var result = SyncRecord()
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let tag = try varint(bytes, index: &index)
            let number = Int(tag >> 3)
            let wire = tag & 7
            guard number > 0 else { throw SyncError.invalidSnapshot }
            let field = number <= fields.count ? fields[number - 1] : nil
            let value = try readValue(bytes, index: &index, wire: wire, field: field, context: (legacy, depth))
            if let field, let value {
                if field.repeated {
                    var records = result.records(field.name)
                    if case .object(let fields) = value { records.append(SyncRecord(fields)) }
                    result.set(field.name, records)
                } else { result.fields[field.name] = value }
            }
        }
        return result
    }

    private static func readValue(_ bytes: [UInt8], index: inout Int, wire: UInt64, field: Field?,
                                  context: (legacy: Bool, depth: Int)) throws -> SyncValue? {
        switch wire {
        case 0:
            let integer = try varint(bytes, index: &index)
            guard let field else { return nil }
            return try scalar(integer, field: field)
        case 2:
            let length = try varint(bytes, index: &index)
            guard length <= UInt64(bytes.count - index) else { throw SyncError.invalidSnapshot }
            let payload = Data(bytes[index..<(index + Int(length))]); index += Int(length)
            guard let field else { return nil }
            return try decodePayload(payload, field: field, legacy: context.legacy, depth: context.depth)
        case 1, 5:
            let length = wire == 1 ? 8 : 4
            guard index + length <= bytes.count, field == nil else { throw SyncError.invalidSnapshot }
            index += length; return nil
        default: throw SyncError.invalidSnapshot
        }
    }
    private static func scalar(_ integer: UInt64, field: Field) throws -> SyncValue {
        switch field.kind {
        case "b": return .bool(integer != 0)
        case "e": return .string(integer < UInt64(actions.count) ? actions[Int(integer)] : actions[0])
        case "n": return .integer(Int64(bitPattern: integer))
        default: throw SyncError.invalidSnapshot
        }
    }
    private static func decodePayload(_ data: Data, field: Field, legacy: Bool, depth: Int) throws -> SyncValue {
        guard !["n", "b", "e"].contains(field.kind) else { throw SyncError.invalidSnapshot }
        if field.kind == "s" {
            guard let text = String(data: data, encoding: .utf8) else { throw SyncError.invalidSnapshot }
            return .string(text)
        }
        return .object(try decode(data, message: field.kind, legacy: legacy, depth: depth + 1).fields)
    }

    private static func varint(_ bytes: [UInt8], index: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < bytes.count else { throw SyncError.invalidSnapshot }
            let byte = bytes[index]; index += 1
            guard shift < 63 || byte <= 1 else { throw SyncError.invalidSnapshot }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
        }
        throw SyncError.invalidSnapshot
    }
}
