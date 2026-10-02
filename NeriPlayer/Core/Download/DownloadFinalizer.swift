// DownloadFinalizer.swift
// M6: verify native audio before core commit; metadata edits run on a copy and never destroy the core.
import Foundation
import TagLibSwift

struct DownloadFinalizer: Sendable {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    static func verify(_ file: URL, expectedDuration: Double?) async throws {
        guard try DownloadStorage.size(file) > 0 else { throw DownloadFailure.integrity }
        // 用 silentAudioOnly 而不是 silentAudio：下载校验会在后台对刚下好的文件起一个 mpv，
        // 而被下载的文件通常带封面（enrich 的封面就是这一步之前写进去的）。只静音不关封面显示的话，
        // mpv 会把封面当视频轨另开一个窗口弹到用户面前 —— 下载一首歌就闪一个窗口。
        let options = MPVLaunchOption.silentAudioOnly
        let engine = try MPVController(clientName: "NeriPlayer.DownloadProbe", options: options)
        try engine.setFlag("pause", true)
        try engine.loadFile(file.path)
        defer { try? engine.stop() }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try Task.checkCancellation()
            if let codec = try? engine.getString("audio-codec-name"), !codec.isEmpty {
                let actual = (try? engine.getDouble("duration")) ?? 0
                if let expectedDuration, expectedDuration > 0, actual > 0,
                   Swift.abs(actual - expectedDuration) > max(3, expectedDuration * 0.02) { throw DownloadFailure.integrity }
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw DownloadFailure.integrity
    }

    func enrich(_ file: URL, song: SongData, ownedRoot: URL, coverRoot: URL?) async -> String? {
        let copy = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + "-metadata." + file.pathExtension)
        do {
            _ = try DownloadStorage.checked(file, under: ownedRoot)
            _ = try DownloadStorage.checked(copy, under: ownedRoot)
            try FileManager.default.copyItem(at: file, to: copy)
            defer { try? DownloadStorage.remove(copy, under: ownedRoot) }
            let cover = await downloadCover(song.artworkURL, to: coverRoot)
            try Task.checkCancellation()
            try writeAndVerifyTags(copy, song: song, cover: cover.data)
            _ = try DownloadStorage.checked(file, under: ownedRoot)
            _ = try DownloadStorage.checked(copy, under: ownedRoot)
            guard rename(copy.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            return cover.warning
        } catch { return "音频已保存，标签未完成：\(error.localizedDescription)" }
    }

    private func downloadCover(_ url: URL?, to coverRoot: URL?) async -> (data: Picture?, warning: String?) {
        guard let url else { return (nil, nil) }
        do {
            let (bytes, raw) = try await session.bytes(for: HTTPAudioDownloader.request(url, headers: [:]))
            guard let response = raw as? HTTPURLResponse, response.statusCode == 200,
                  let mime = response.mimeType, ["image/jpeg", "image/png"].contains(mime) else { throw DownloadFailure.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 10 * 1024 * 1024 else { throw DownloadFailure.invalidResponse }
                data.append(byte)
            }
            if let coverRoot {
                try FileManager.default.createDirectory(at: coverRoot, withIntermediateDirectories: true)
                let name = DownloadStorage.key(url.absoluteString) + (mime == "image/png" ? ".png" : ".jpg")
                let destination = try DownloadStorage.checked(coverRoot.appendingPathComponent(name), under: coverRoot)
                try data.write(to: destination, options: .atomic)
            }
            return (Picture(data: data, mimeType: mime), nil)
        } catch { return (nil, "封面写入失败：\(error.localizedDescription)") }
    }

    private func writeAndVerifyTags(_ file: URL, song: SongData, cover: Picture?) throws {
        guard let audio = AudioFile(path: file.path), audio.isValid else { throw DownloadFailure.unsupported("此音频容器暂不支持标签") }
        audio.tag.title = song.title
        audio.tag.artist = song.artist
        audio.tag.album = song.album
        if let cover { audio.pictures = [cover] }
        try audio.save()
        guard let reopened = AudioFile(path: file.path), reopened.isValid,
              reopened.tag.title == song.title, reopened.tag.artist == song.artist else { throw DownloadFailure.integrity }
    }
}
