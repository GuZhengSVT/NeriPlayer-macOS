// YouTubeMusicParser.swift
// M5-T6: Innertube renderer normalization, bootstrap extraction and audio candidates.
// Behavioral reference: NeriPlayer Android YouTubeMusicClient (GPL-3.0-or-later).
import Foundation

public enum YouTubeMusicParser {
    public static func songs(from data: Data) throws -> [SongData] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OnlineError.invalidResponse }
        return songs(root)
    }

    static func songs(_ root: [String: Any]) -> [SongData] {
        var results: [SongData] = []
        var seen = Set<String>()
        for renderer in objects(named: "musicResponsiveListItemRenderer", in: root) {
            if let song = song(renderer), seen.insert(song.sourceID).inserted { results.append(song) }
        }
        for renderer in objects(named: "musicTwoRowItemRenderer", in: root) {
            if let id = videoID(renderer), let title = text(renderer["title"]), !title.isEmpty, seen.insert(id).inserted {
                let metadata = metadataRuns(renderer["subtitle"])
                results.append(SongData(source: .youtubeMusic, sourceID: id, title: title,
                                        artist: metadata.artists.joined(separator: " / "), album: metadata.album,
                                        duration: metadata.duration, artworkURL: thumbnail(renderer["thumbnailRenderer"] ?? renderer["thumbnail"]),
                                        pageURL: watchURL(id)))
            }
        }
        return results
    }

    static func song(_ renderer: [String: Any]) -> SongData? {
        guard let id = videoID(renderer) else { return nil }
        let flex = renderer["flexColumns"] as? [[String: Any]] ?? []
        let fixed = renderer["fixedColumns"] as? [[String: Any]] ?? []
        guard let first = flex.first?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let title = text(first["text"]), !title.isEmpty else { return nil }
        let second = flex.dropFirst().first?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
        let third = flex.dropFirst(2).first?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
        var metadata = metadataRuns(second?["text"])
        if metadata.album.isEmpty, let album = text(third?["text"]), duration(album) == nil { metadata.album = album }
        if metadata.duration == nil {
            let columns = fixed + flex
            for column in columns {
                let node = column["musicResponsiveListItemFixedColumnRenderer"] ?? column["musicResponsiveListItemFlexColumnRenderer"]
                if let value = text((node as? [String: Any])?["text"]), let seconds = duration(value) {
                    metadata.duration = seconds
                    break
                }
            }
        }
        return SongData(source: .youtubeMusic, sourceID: id, title: title,
                        artist: metadata.artists.joined(separator: " / "), album: metadata.album,
                        duration: metadata.duration, artworkURL: thumbnail(renderer["thumbnail"]), pageURL: watchURL(id))
    }

    static func collections(_ root: [String: Any]) -> [OnlineCollection] {
        let renderers = objects(named: "musicTwoRowItemRenderer", in: root)
            + objects(named: "musicResponsiveListItemRenderer", in: root)
        var result: [OnlineCollection] = []
        var seen = Set<String>()
        for renderer in renderers {
            guard let endpoint = objects(named: "browseEndpoint", in: renderer).first,
                  let id = endpoint["browseId"] as? String,
                  id.hasPrefix("VL") || id.hasPrefix("MPRE") else { continue }
            let flex = renderer["flexColumns"] as? [[String: Any]] ?? []
            let first = flex.first?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
            guard let title = text(renderer["title"]) ?? text(first?["text"]), !title.isEmpty,
                  seen.insert(id).inserted else { continue }
            result.append(OnlineCollection(source: .youtubeMusic, sourceID: id, title: title,
                                           subtitle: text(renderer["subtitle"]) ?? "",
                                           artworkURL: thumbnail(renderer["thumbnailRenderer"] ?? renderer["thumbnail"]),
                                           kind: id.hasPrefix("MPRE") ? .album : (id == "VLLM" ? .favorites : .playlist)))
        }
        return result
    }

    static func account(_ root: [String: Any]) -> OnlineAccount? {
        for header in objects(named: "activeAccountHeaderRenderer", in: root) {
            guard let name = text(header["accountName"]), !name.isEmpty else { continue }
            let handle = text(header["channelHandle"]) ?? text(header["email"]) ?? name
            return OnlineAccount(id: handle, name: name)
        }
        for account in objects(named: "accountItem", in: root) + objects(named: "accountItemRenderer", in: root) {
            guard (account["isSelected"] as? Bool) == true,
                  let name = text(account["accountName"]), !name.isEmpty else { continue }
            return OnlineAccount(id: text(account["channelHandle"]) ?? name, name: name)
        }
        return nil
    }

    static func continuation(_ root: [String: Any]) -> String? {
        for object in objects(named: "nextContinuationData", in: root) + objects(named: "continuationCommand", in: root) {
            if let value = object["continuation"] as? String ?? object["token"] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - 首页 shelf

    /// 首页推荐栏。每栏取标题与条目；条目既可能是歌曲，也可能是歌单/专辑卡片。
    static func homeShelves(_ root: [String: Any]) -> [YouTubeMusicHomeShelf] {
        var result: [YouTubeMusicHomeShelf] = []
        for carousel in objects(named: "musicCarouselShelfRenderer", in: root) {
            let header = (carousel["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
            guard let title = text(header?["title"])?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let contents = carousel["contents"] as? [Any] else { continue }
            let items = contents.compactMap { homeItem($0) }
            if !items.isEmpty { result.append(YouTubeMusicHomeShelf(title: title, items: items)) }
        }
        return result
    }

    static func homeShelfItems(_ root: [String: Any]) -> [YouTubeMusicHomeItem] {
        let renderer = objects(named: "musicShelfContinuation", in: root).first
            ?? objects(named: "musicPlaylistShelfRenderer", in: root).first
            ?? objects(named: "musicShelfRenderer", in: root).first
        let contents = (renderer?["contents"] as? [Any]) ?? (root["contents"] as? [Any])
        return (contents ?? []).compactMap { homeItem($0) }
    }

    private static func homeItem(_ value: Any) -> YouTubeMusicHomeItem? {
        guard let container = value as? [String: Any] else { return nil }
        if let renderer = container["musicResponsiveListItemRenderer"] as? [String: Any], let song = song(renderer) {
            let endpoint = objects(named: "browseEndpoint", in: renderer).first?["browseId"] as? String ?? ""
            return YouTubeMusicHomeItem(song: song, browseId: endpoint)
        }
        if let renderer = container["musicTwoRowItemRenderer"] as? [String: Any] {
            let endpoint = objects(named: "browseEndpoint", in: renderer).first?["browseId"] as? String ?? ""
            // A two-row item without a playlist browse ID still carries a playable video ID.
            if let id = videoID(renderer), let title = text(renderer["title"]), !title.isEmpty {
                let metadata = metadataRuns(renderer["subtitle"])
                let song = SongData(source: .youtubeMusic, sourceID: id, title: title,
                                    artist: metadata.artists.joined(separator: " / "), album: metadata.album,
                                    duration: metadata.duration,
                                    artworkURL: thumbnail(renderer["thumbnailRenderer"] ?? renderer["thumbnail"]),
                                    pageURL: watchURL(id))
                return YouTubeMusicHomeItem(song: song, browseId: endpoint)
            }
            if !endpoint.isEmpty, let title = text(renderer["title"]), !title.isEmpty {
                return YouTubeMusicHomeItem(collection: OnlineCollection(
                    source: .youtubeMusic, sourceID: endpoint, title: title,
                    subtitle: text(renderer["subtitle"]) ?? "",
                    artworkURL: thumbnail(renderer["thumbnailRenderer"] ?? renderer["thumbnail"]),
                    kind: endpoint.hasPrefix("MPRE") ? .album : .playlist))
            }
        }
        return nil
    }

    static func objects(named key: String, in value: Any, depth: Int = 0) -> [[String: Any]] {
        guard depth < 64 else { return [] }
        if let array = value as? [Any] { return array.flatMap { objects(named: key, in: $0, depth: depth + 1) } }
        guard let dictionary = value as? [String: Any] else { return [] }
        var result: [[String: Any]] = []
        if let match = dictionary[key] as? [String: Any] { result.append(match) }
        // Sorting keys stabilizes traversal without depending on NSDictionary iteration order.
        for name in dictionary.keys.sorted() { if let child = dictionary[name] { result += objects(named: key, in: child, depth: depth + 1) } }
        return result
    }

    static func text(_ value: Any?) -> String? {
        guard let node = value as? [String: Any] else { return value as? String }
        if let text = node["simpleText"] as? String { return text }
        if let runs = node["runs"] as? [[String: Any]] { return runs.compactMap { $0["text"] as? String }.joined() }
        return nil
    }

    static func thumbnail(_ value: Any?) -> URL? {
        guard let value else { return nil }
        func collect(_ node: Any, depth: Int) -> [[String: Any]] {
            guard depth < 12 else { return [] }
            if let array = node as? [Any] { return array.flatMap { collect($0, depth: depth + 1) } }
            guard let dictionary = node as? [String: Any] else { return [] }
            if dictionary["url"] is String { return [dictionary] }
            return dictionary.values.flatMap { collect($0, depth: depth + 1) }
        }
        return collect(value, depth: 0).sorted {
            ($0["width"] as? Int ?? 0) > ($1["width"] as? Int ?? 0)
        }.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }.first { $0.scheme == "https" }
    }

    static func duration(_ value: String) -> Double? {
        let pieces = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(pieces.count) else { return nil }
        let numbers = pieces.compactMap { Double($0) }
        guard numbers.count == pieces.count, numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0.rounded() == $0 }),
              numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        let seconds = numbers.reduce(0) { $0 * 60 + $1 }
        return seconds <= 604_800 ? seconds : nil
    }

    static func videoID(_ renderer: [String: Any]) -> String? {
        if let data = renderer["playlistItemData"] as? [String: Any], let id = data["videoId"] as? String, validVideoID(id) { return id }
        for endpoint in objects(named: "watchEndpoint", in: renderer) {
            if let id = endpoint["videoId"] as? String, validVideoID(id) { return id }
        }
        return nil
    }

    static func validVideoID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    static func watchURL(_ id: String) -> URL? {
        var parts = URLComponents(string: "https://music.youtube.com/watch")
        parts?.queryItems = [URLQueryItem(name: "v", value: id)]
        return parts?.url
    }

    private struct Metadata { var artists: [String] = []; var album = ""; var duration: Double? }

    private static func metadataRuns(_ value: Any?) -> Metadata {
        var result = Metadata()
        guard let node = value as? [String: Any] else { return result }
        let runs = node["runs"] as? [[String: Any]] ?? []
        var unlinked: [String] = []
        for run in runs {
            guard let value = run["text"] as? String else { continue }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || ["•", "·", "&", ",", "/", "Song", "Video", "歌曲", "视频"].contains(text) { continue }
            if let seconds = duration(text) { result.duration = seconds; continue }
            let endpoint = objects(named: "browseEndpoint", in: run).first
            let id = endpoint?["browseId"] as? String ?? ""
            if id.hasPrefix("MPRE") || id.contains("release_detail") {
                result.album = text
            } else if id.hasPrefix("UC") {
                result.artists.append(text)
            } else if id.isEmpty {
                unlinked.append(text)
            }
        }
        if result.artists.isEmpty, let artist = unlinked.first { result.artists = [artist] }
        if result.album.isEmpty, unlinked.count >= 2 { result.album = unlinked[1] }
        return result
    }
}
