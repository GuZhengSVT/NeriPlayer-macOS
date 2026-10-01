// SyncSongIdentity.swift
// M7: Android source identities and stable signed 64-bit IDs.

import CryptoKit
import Foundation

extension SyncRecord {
    var channel: String {
        let raw = text("channelId").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["youtube", "ytmusic", "youtubemusic", "youtube_music"].contains(raw) { return "youtube_music" }
        if !raw.isEmpty { return raw }
        if youtubeVideoID != nil { return "youtube_music" }
        if text("album").lowercased().hasPrefix("bilibili") { return "bilibili" }
        return text("mediaUri").isEmpty ? "netease" : text("album").lowercased()
    }
    var youtubeVideoID: String? {
        guard let components = URLComponents(string: text("mediaUri")) else { return nil }
        if components.scheme == "ytmusic", components.host == "video" { return String(components.path.dropFirst()) }
        if components.host?.contains("youtube.com") == true {
            return components.queryItems?.first { $0.name == "v" }?.value
        }
        if components.host == "youtu.be" { return components.path.split(separator: "/").first.map(String.init) }
        return nil
    }
    var audioID: String { youtubeVideoID ?? (text("audioId").isEmpty ? String(number("id")) : text("audioId")) }
    var subAudioID: String {
        if !text("subAudioId").isEmpty { return text("subAudioId") }
        return text("album").split(separator: "|", omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
    }
    var identityKey: String {
        if isLocalSong { return "\(number("id"))|\(text("album"))|\(text("mediaUri"))" }
        let source = channel
        if source == "youtube_music" {
            let audio = audioID
            return "\(Self.stableAndroidID(audio))|youtube_music|ytmusic://video/\(audio)"
        }
        let audio = audioID
        let identity = source == "netease" ? (Int64(audio) ?? Self.stableAndroidID("netease|" + audio)) :
            Self.stableAndroidID("\(source)|\(audio)|\(source == "bilibili" ? subAudioID : "")")
        return "\(identity)|\(source)|"
    }
    var rawIdentityKey: String { "\(number("id", default: number("songId")))|\(text("album"))|\(text("mediaUri"))" }
    static func stableAndroidID(_ value: String) -> Int64 {
        let bytes = SHA256.hash(data: Data(value.utf8)).prefix(8)
        let bits = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return bits == 0 ? 1 : Int64(bitPattern: bits)
    }
    var onlineSong: SongData? {
        let source: MusicSource
        let identifier: String
        switch channel {
        case "netease": source = .netease; identifier = audioID
        case "bilibili":
            source = .bilibili
            let albumBV = text("album").split(separator: "|").first { $0.hasPrefix("BV") }.map(String.init)
            let video = Int64(audioID) != nil ? "av" + audioID : (albumBV ?? audioID)
            identifier = video + (subAudioID.isEmpty ? ":1" : ":cid:" + subAudioID)
        case "youtube_music": source = .youtubeMusic; identifier = audioID
        default: return nil
        }
        guard !isLocalSong, !identifier.isEmpty, identifier != "0" else { return nil }
        return SongData(source: source, sourceID: identifier, title: text("name"), artist: text("artist"),
                        album: text("album"), duration: Double(number("durationMs")) / 1_000,
                        artworkURL: URL(string: text("coverUrl")))
    }
    static func song(_ song: SongData, addedAt: Int64 = 0) -> SyncRecord {
        let channel: String
        switch song.source {
        case .netease: channel = "netease"
        case .bilibili: channel = "bilibili"
        case .youtubeMusic: channel = "youtube_music"
        }
        let parts = song.sourceID.split(separator: ":", maxSplits: 1).map(String.init)
        let video = parts.first ?? song.sourceID
        let audio = song.sourceAudioID ?? (song.source == .bilibili && video.hasPrefix("av") ? String(video.dropFirst(2)) : video)
        var result = SyncRecord(["id": .integer(Int64(audio) ?? stableAndroidID(song.sourceID)),
                                 "name": .string(song.title), "artist": .string(song.artist), "album": .string(channel),
                                 "albumId": .integer(0), "durationMs": .integer(Int64((song.duration ?? 0) * 1_000)),
                                 "channelId": .string(channel), "audioId": .string(audio), "addedAt": .integer(addedAt),
                                 "syncMetadataVersion": .integer(1)])
        if song.source == .bilibili {
            let cid = song.sourceSubID ?? (parts.count == 2 && parts[1].hasPrefix("cid:") ? String(parts[1].dropFirst(4)) : nil)
            if let cid {
                result.set("subAudioId", cid)
                result.set("album", "Bilibili|\(cid)|\(video)")
            }
        }
        if song.source == .youtubeMusic { result.set("mediaUri", "ytmusic://video/" + song.sourceID) }
        if let artwork = song.artworkURL { result.set("coverUrl", artwork.absoluteString) }
        return result
    }
}

public extension SongData {
    static func fromIdentityURL(_ url: URL, title: String, artist: String = "", album: String = "",
                                duration: Double? = nil) -> SongData? {
        guard url.scheme == "neriplayer-online", let host = url.host, let source = MusicSource(rawValue: host) else { return nil }
        let identifier = String(url.path.dropFirst())
        guard !identifier.isEmpty else { return nil }
        return SongData(source: source, sourceID: identifier, title: title, artist: artist, album: album, duration: duration)
    }
}
