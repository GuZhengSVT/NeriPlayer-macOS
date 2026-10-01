// M7SyncTests.swift
// M7: Android compatibility, merge convergence, in-flight edits and complete metadata backup.

import Foundation
import GRDB
import XCTest
import zlib
@testable import NeriPlayer

final class M7SyncTests: XCTestCase {
    private var root: URL!
    private var database: DatabaseProvider!
    private var settings: SettingsStore!
    private var suite: String!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("M7-\(UUID().uuidString)")
        database = try DatabaseProvider(url: root.appendingPathComponent("library.sqlite"))
        try database.setupIfNeeded()
        suite = "M7-\(UUID().uuidString)"
        settings = SettingsStore(userDefaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    }
    override func tearDownWithError() throws {
        settings.userDefaults.removePersistentDomain(forName: suite)
        database = nil
        let target = try XCTUnwrap(root).standardizedFileURL
        XCTAssertTrue(target.lastPathComponent.hasPrefix("M7-"))
        try FileManager.default.removeItem(at: target)
    }
    private func song(_ id: Int64, added: Int64 = 10, device: String? = nil) -> SyncRecord {
        var song = SyncRecord(["id": .integer(id), "name": .string("Song \(id)"), "album": .string("netease"),
                               "addedAt": .integer(added), "channelId": .string("netease"), "audioId": .string(String(id))])
        if let device { song.set("syncMembershipTokens", [SyncRecord(["deviceId": .string(device), "counter": .integer(1)])]) }
        return song
    }
    private func playlist(_ songs: [SyncRecord], modified: Int64 = 10, name: String = "Playlist") -> SyncRecord {
        var playlist = SyncRecord(["id": .integer(1), "name": .string(name), "createdAt": .integer(1),
                                   "modifiedAt": .integer(modified), "songOrderVersion": .integer(1)])
        playlist.set("songs", songs); return playlist
    }
    private func snapshot(_ playlists: [SyncRecord]) -> SyncSnapshot {
        var snapshot = SyncSnapshot(); snapshot.playlists = playlists; return snapshot
    }

    func testAndroidJSONDefaultsUnknownMetadataAndLargeSignedIDsRoundTrip() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "android-compatible", withExtension: "json", subdirectory: "Sync"))
        let decoded = try SyncSnapshotCodec.decode(Data(contentsOf: url))
        XCTAssertEqual(decoded.record.text("version"), "2.0")
        XCTAssertEqual(decoded.playlists.first?.number("id"), 1_700_000_000_001)
        let song = try XCTUnwrap(decoded.playlists.first?.records("songs").first)
        XCTAssertEqual(song.number("id"), -8_123_456_789_123_456_789)
        XCTAssertEqual(song.text("matchedLyric"), "[00:01]Golden")
        XCTAssertEqual(song.text("customName"), "Custom")
        let roundTrip = try SyncSnapshotCodec.decode(SyncSnapshotCodec.encode(decoded))
        XCTAssertEqual(roundTrip, decoded)
        XCTAssertEqual(roundTrip.record.text("futureField"), "preserved")
    }
    func testJSONBOMAndUnsupportedVersion() throws {
        XCTAssertNoThrow(try SyncSnapshotCodec.decode(Data([0xef, 0xbb, 0xbf]) + Data(" \n{}".utf8)))
        XCTAssertThrowsError(try SyncSnapshotCodec.decode(Data(#"{"version":"99.0"}"#.utf8)))
        XCTAssertThrowsError(try SyncSnapshotCodec.decode(Data(repeating: 32, count: SyncSnapshotCodec.compressedLimit + 1)))
    }
    func testAndroidRawGzipAndLegacyBase64Protobuf() throws {
        // ProtoNumber 1 version, 5 playlist; playlist 1 id, 2 name, 3 song; song 1 id, 2 name.
        let proto = Data([0x0a, 3, 50, 46, 48, 0x2a, 13, 8, 1, 18, 1, 80, 26, 6, 8, 42, 18, 2, 83, 49])
        let compressed = try gzip(proto)
        let raw = try SyncSnapshotCodec.decode(compressed)
        let legacy = try SyncSnapshotCodec.decode(Data(compressed.base64EncodedString().utf8))
        XCTAssertEqual(raw, legacy)
        XCTAssertEqual(raw.playlists.first?.records("songs").first?.number("id"), 42)
        XCTAssertThrowsError(try SyncSnapshotCodec.decode(compressed.dropLast(4)))
    }
    func testLocalPathsAndCoverReferencesAreNotSynced() throws {
        let local = SyncRecord(["id": .integer(1), "mediaUri": .string("file:///Music/secret.mp3")])
        var remote = song(2); remote.set("coverUrl", "file:///private/cover.png"); remote.set("streamUrl", "https://signed.invalid/token")
        let decoded = try SyncSnapshotCodec.decode(SyncSnapshotCodec.encode(snapshot([playlist([local, remote])])))
        XCTAssertEqual(decoded.playlists.first?.records("songs").count, 1)
        XCTAssertNil(decoded.playlists.first?.records("songs").first?.fields["coverUrl"])
        XCTAssertNil(decoded.playlists.first?.records("songs").first?.fields["streamUrl"])
    }
    func testStableAndroidYouTubeIdentityAndBiliCID() throws {
        let ytm = SyncRecord.song(SongData(source: .youtubeMusic, sourceID: "AbCdEF12345", title: "YTM"))
        XCTAssertEqual(ytm.text("mediaUri"), "ytmusic://video/AbCdEF12345")
        XCTAssertEqual(ytm.identityKey, "\(SyncRecord.stableAndroidID("AbCdEF12345"))|youtube_music|ytmusic://video/AbCdEF12345")
        let bili = SyncRecord(["channelId": .string("bilibili"), "audioId": .string("BV1xx411c7mD"), "subAudioId": .string("777777")])
        XCTAssertEqual(bili.onlineSong?.sourceID, "BV1xx411c7mD:cid:777777")
        let identity = try BilibiliVideoIdentity(sourceID: "BV1xx411c7mD:cid:777777")
        XCTAssertEqual(identity.cid, "777777")
        XCTAssertEqual(SyncRecord.song(try XCTUnwrap(bili.onlineSong)).text("subAudioId"), "777777")
    }
    func testLegacyDisplayOrderUsesSnapshotClockNotWallClock() {
        var legacy = playlist([song(1, added: 2), song(2, added: 3)], modified: 100)
        legacy.fields.removeValue(forKey: "songOrderVersion")
        let normalized = SyncMergeEngine.normalizeOrder(legacy)
        XCTAssertEqual(normalized.records("songs").map { $0.number("id") }, [2, 1])
        XCTAssertEqual(normalized.records("songs").map { $0.number("addedAt") }, [100, 99])
        XCTAssertEqual(normalized.records("songs").map { $0.number("legacyAddedAt") }, [3, 2])
    }
    func testConcurrentAdditionsUnionAndOneSidedRemoval() {
        let local = snapshot([playlist([song(1), song(2)], modified: 30)])
        let remote = snapshot([playlist([song(1), song(3)], modified: 40)])
        let merged = SyncMergeEngine.merge(local: local, remote: remote, lastSyncTime: 20).snapshot
        XCTAssertEqual(Set(merged.playlists[0].records("songs").map { $0.number("id") }), [1, 2, 3])
        let removed = SyncMergeEngine.merge(local: snapshot([playlist([song(2)], modified: 30)]),
            remote: snapshot([playlist([song(1), song(2)], modified: 10)]), lastSyncTime: 20).snapshot
        XCTAssertEqual(removed.playlists[0].records("songs").map { $0.number("id") }, [2])
    }
    func testPlaylistDeletionWinsEqualTimestampAndNewerActiveWins() {
        var deleted = playlist([], modified: 20); deleted.set("isDeleted", true)
        let equal = SyncMergeEngine.merge(local: snapshot([deleted]), remote: snapshot([playlist([song(1)], modified: 20)]))
        let newer = SyncMergeEngine.merge(local: snapshot([deleted]), remote: snapshot([playlist([song(1)], modified: 30)]))
        XCTAssertTrue(equal.snapshot.playlists[0].flag("isDeleted"))
        XCTAssertFalse(newer.snapshot.playlists[0].flag("isDeleted"))
    }
    func testObservedRemoveKeepsConcurrentReaddAndKillsObservedMembership() {
        var local = snapshot([playlist([song(1, device: "A")])])
        var deletion = song(1)
        deletion.set("playlistId", Int64(1)); deletion.set("songId", Int64(1)); deletion.set("deletedAt", Int64(20))
        deletion.set("removedMembershipTokens", song(1, device: "A").records("syncMembershipTokens"))
        local.record.set("playlistSongDeletions", [deletion])
        let concurrent = snapshot([playlist([song(1, device: "B")])])
        let merged = SyncMergeEngine.merge(local: local, remote: concurrent).snapshot.playlists[0].records("songs")
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.records("syncMembershipTokens").first?.text("deviceId"), "B")
        XCTAssertTrue(SyncMergeEngine.merge(local: local, remote: SyncSnapshot()).snapshot.playlists[0].records("songs").isEmpty)
    }
    func testLegacyDeletionUsesOriginalAddedAtAfterOrderMigration() {
        var legacy = playlist([song(1, added: 2)], modified: 100)
        legacy.set("songOrderVersion", Int64(0))
        var deletion = song(1); deletion.set("songId", Int64(1)); deletion.set("playlistId", Int64(1)); deletion.set("deletedAt", Int64(10))
        var remote = SyncSnapshot(); remote.record.set("playlistSongDeletions", [deletion])
        XCTAssertTrue(SyncMergeEngine.merge(local: snapshot([legacy]), remote: remote).snapshot.playlists[0].records("songs").isEmpty)
    }
    func testRenameConflictReportedAndLocalKept() {
        let merged = SyncMergeEngine.merge(local: snapshot([playlist([], modified: 30, name: "Local")]),
            remote: snapshot([playlist([], modified: 40, name: "Remote")]), lastSyncTime: 20)
        XCTAssertEqual(merged.snapshot.playlists[0].text("name"), "Local")
        XCTAssertEqual(merged.conflicts.count, 1)
    }
    func testCounterShardsSumDevicesAndUseMaxWithinDevice() {
        var first = song(1); first.set("identityKey", first.identityKey)
        first.set("totalListenMs", Int64(100)); first.set("playCount", Int64(1))
        first.set("counterShards", [shard("A", listen: 100, count: 1)])
        var second = first; second.set("counterShards", [shard("A", listen: 90, count: 1), shard("B", listen: 200, count: 2)])
        let merged = SyncCounterMerge.merge([first, second])[0]
        XCTAssertEqual(merged.number("totalListenMs"), 300)
        XCTAssertEqual(merged.number("playCount"), 3)
        XCTAssertEqual(SyncCounterMerge.merge([merged, merged]), [merged])
    }
    func testLegacyStatsMaxAndLiftBeforeRetentionTrim() {
        var first = song(1); first.set("identityKey", first.identityKey); first.set("totalListenMs", Int64(100))
        let second = first.replacing("totalListenMs", with: 150)
        XCTAssertEqual(SyncCounterMerge.merge([first, second])[0].number("totalListenMs"), 150)
        let old = first.replacing("dayStartAt", with: 1)
        let newest = first.replacing("dayStartAt", with: 500 * 86_400_000)
        XCTAssertEqual(SyncCounterMerge.lift([first], buckets: [old, newest])[0].number("totalListenMs"), 200)
        XCTAssertEqual(SyncCounterMerge.trimBuckets([old, newest]).count, 1)
    }
    func testClearedStatsAndInvalidTokens() {
        var old = song(1); old.set("lastPlayedAt", Int64(100))
        XCTAssertTrue(SyncCounterMerge.merge([old], clear: 101).isEmpty)
        XCTAssertEqual(SyncMergeEngine.tokens([SyncRecord(), SyncRecord(["deviceId": .string("A"), "counter": .integer(1)])]).count, 1)
    }
    func testDatabaseProjectionStableAndImportedOnlinePlaybackPreserved() throws {
        let repository = SyncRepository(database)
        let playlist = try PlaylistRepository(database).create(name: "Local")
        try repository.addOnlineSong(SongData(source: .netease, sourceID: "42", title: "Online"), playlistID: playlist.id, favorite: true)
        let first = try repository.capture(), second = try repository.capture()
        XCTAssertEqual(first.snapshot.playlists, second.snapshot.playlists)
        XCTAssertEqual(first.revision, second.revision)
        let entries = try PlaylistRepository(database).entries(playlistId: playlist.id)
        XCTAssertEqual(entries.first?.onlineSong?.sourceID, "42")
        let tracks = try LibraryRepository(database).allTracksSorted(by: .title)
        XCTAssertEqual(tracks.first?.track.onlineSong?.sourceID, "42")
    }
    func testRevisionGuardRejectsInFlightMutationAcrossConnections() throws {
        let repository = SyncRepository(database)
        let captured = try repository.capture()
        let other = try DatabaseProvider(url: database.databaseURL); try other.setupIfNeeded()
        _ = try PlaylistRepository(other).create(name: "New in-flight playlist")
        XCTAssertFalse(try repository.apply(SyncSnapshot(), expectedRevision: captured.revision, target: "test"))
        XCTAssertEqual(try PlaylistRepository(database).list().count, 1)
    }
    func testImportedMetadataAndLocalFileEntriesSurviveCapture() throws {
        let repository = SyncRepository(database)
        var remoteSong = song(42); remoteSong.set("customName", "Custom"); remoteSong.set("matchedLyric", "[00:01]Line")
        let remote = snapshot([playlist([remoteSong])])
        let capture = try repository.capture()
        XCTAssertTrue(try repository.apply(remote, expectedRevision: capture.revision, target: "test"))
        let localPlaylist = try XCTUnwrap(PlaylistRepository(database).list().first)
        let localTrack = Track(url: root.appendingPathComponent("local.mp3"), title: "Local")
        try LibraryRepository(database).upsertTracks([localTrack])
        try PlaylistRepository(database).addTrack(playlistId: localPlaylist.id, trackId: localTrack.id)
        let projected = try repository.capture()
        XCTAssertEqual(projected.snapshot.playlists[0].records("songs")[0].text("matchedLyric"), "[00:01]Line")
        XCTAssertEqual(projected.snapshot.playlists[0].records("songs").count, 1)
        XCTAssertTrue(try repository.apply(projected.snapshot, expectedRevision: projected.revision, target: "test"))
        XCTAssertEqual(try PlaylistRepository(database).entries(playlistId: localPlaylist.id).count, 2)
    }
    func testFullBackupRoundTripAndCorruptionDoesNotTouchDatabase() throws {
        settings.set("dark", for: SettingsKeys.appAppearance)
        let track = Track(url: root.appendingPathComponent("audio.flac"), title: "Metadata")
        try LibraryRepository(database).upsertTracks([track])
        let playlist = try PlaylistRepository(database).create(name: "Saved")
        try PlaylistRepository(database).addTrack(playlistId: playlist.id, trackId: track.id)
        let backup = BackupManager(database: database, settings: settings)
        let url = root.appendingPathComponent("backup.json")
        try backup.export(to: url)
        try PlaylistRepository(database).delete(id: playlist.id)
        settings.set("light", for: SettingsKeys.appAppearance)
        try backup.restore(from: url)
        XCTAssertEqual(try PlaylistRepository(database).list().first?.name, "Saved")
        XCTAssertEqual(settings.value(for: SettingsKeys.appAppearance), "dark")
        try Data(#"{"payload":"e30=","sha256":"bad","format":"neriplayer-macos-backup-envelope"}"#.utf8).write(to: url)
        XCTAssertThrowsError(try backup.restore(from: url))
        XCTAssertEqual(try PlaylistRepository(database).list().count, 1)
    }
    func testBackupExcludesSecretsAndUnknownSettingsRejected() throws {
        settings.userDefaults.set("secret", forKey: "metadataSyncConfiguration")
        let record = settings.backupSettings()
        XCTAssertNil(record.fields["metadataSyncConfiguration"])
        XCTAssertThrowsError(try settings.validateBackupSettings(SyncRecord(["token": .string("secret")])))
    }
    func testSyncRetriesRemoteConflictAndPreservesInFlightChanges() async throws {
        let repository = SyncRepository(database)
        let transport = M7MemoryTransport(data: nil, conflictOnce: true)
        let service = SyncService(repository: repository)
        _ = try await service.synchronize(using: transport)
        let attempts = await transport.uploads
        XCTAssertEqual(attempts, 2)
        let mutating = M7MutatingTransport(database: database)
        do { _ = try await service.synchronize(using: mutating); XCTFail("Must preserve edits") } catch { XCTAssertEqual(error as? SyncError, .localChanged) }
        XCTAssertTrue(try PlaylistRepository(database).list().contains { $0.name == "In-flight" })
    }
    func testAndroidBilibiliAIDMapsToPlayableStableCIDIdentity() throws {
        let android = SyncRecord(["id": .integer(123), "album": .string("Bilibili|777|BV1xx411c7mD"),
            "channelId": .string("bilibili"), "audioId": .string("123"), "subAudioId": .string("777")])
        let song = try XCTUnwrap(android.onlineSong)
        XCTAssertEqual(song.sourceID, "av123:cid:777")
        XCTAssertEqual(try BilibiliVideoIdentity(sourceID: song.sourceID).cid, "777")
        XCTAssertEqual(SyncRecord.song(song).identityKey, android.identityKey)
    }
    func testMergeDisplayOrderIsStableOnNextCapture() {
        let local = snapshot([playlist([song(1, added: 50)], modified: 100)])
        let remote = snapshot([playlist([song(2, added: 80)], modified: 90)])
        let merged = SyncMergeEngine.merge(local: local, remote: remote).snapshot
        XCTAssertEqual(merged.playlists[0].records("songs").map { $0.number("id") }, [2, 1])
        XCTAssertEqual(SyncMergeEngine.normalizeOrder(merged.playlists[0]), merged.playlists[0])
    }
    func testSchemaGeneratedFromWireDefinitions() throws {
        let schema = try AndroidSyncProto.jsonSchema()
        XCTAssertEqual(schema.text("$ref"), "#/$defs/snapshot")
        if let path = ProcessInfo.processInfo.environment["NERIPLAYER_M7_SCHEMA_PATH"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(schema).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    func testMalformedKnownFieldTypesAreRejectedBeforeMerge() {
        for json in [#"{"playlists":"bad"}"#, #"{"playlists":[{"id":"1"}]}"#,
                     #"{"playlists":[{"songs":[42]}]}"#, #"{"playbackStatsClearedAt":true}"#] {
            XCTAssertThrowsError(try SyncSnapshotCodec.decode(Data(json.utf8)))
        }
    }
    func testFavoritesOrderStableAcrossApplyAndCapture() throws {
        let repository = SyncRepository(database)
        var favorites = playlist([song(1, added: 20), song(2, added: 10)])
        favorites.set("id", Int64(-1_001))
        let remote = snapshot([favorites])
        let initial = try repository.capture()
        XCTAssertTrue(try repository.apply(remote, expectedRevision: initial.revision, target: "test"))
        let projected = try repository.capture()
        XCTAssertEqual(projected.snapshot.playlists.first?.records("songs").map { $0.number("id") }, [1, 2])
        XCTAssertEqual(projected.snapshot.playlists.first?.records("songs").map { $0.number("addedAt") }, [20, 10])
    }
    func testRemoteClearRemovesOnlineStatsButPreservesLocalStats() throws {
        let repository = SyncRepository(database)
        let online = try repository.registerPlaybackTrack(SongData(source: .netease, sourceID: "42", title: "Online").track())
        let local = try repository.registerPlaybackTrack(Track(url: root.appendingPathComponent("local.flac"), title: "Local"))
        try PlaybackStatsRepository(database).upsert(PlaybackStats(trackId: online.id, totalListenSeconds: 30, playCount: 1))
        try PlaybackStatsRepository(database).upsert(PlaybackStats(trackId: local.id, totalListenSeconds: 40, playCount: 1))
        let capture = try repository.capture()
        var clear = capture.snapshot
        clear.record.set("playbackStats", []); clear.record.set("playbackStatBuckets", [])
        clear.record.set("playbackStatsClearedAt", SyncSnapshot.milliseconds())
        XCTAssertTrue(try repository.apply(clear, expectedRevision: capture.revision, target: "test"))
        let stats = try PlaybackStatsRepository(database).all()
        XCTAssertEqual(stats.map(\.trackId), [local.id])
        XCTAssertTrue(try repository.capture().snapshot.record.records("playbackStats").isEmpty)
    }
    func testLocalStatsClearProducesPersistentRemoteMarker() throws {
        let repository = SyncRepository(database)
        let track = try repository.registerPlaybackTrack(SongData(source: .netease, sourceID: "42", title: "Online").track())
        try PlaybackStatsRepository(database).upsert(PlaybackStats(trackId: track.id, totalListenSeconds: 30, playCount: 1))
        let first = try repository.capture()
        XCTAssertEqual(first.snapshot.record.records("playbackStats").count, 1)
        try PlaybackStatsRepository(database).clear()
        let cleared = try repository.capture()
        XCTAssertGreaterThan(cleared.snapshot.record.number("playbackStatsClearedAt"), 0)
        XCTAssertTrue(cleared.snapshot.record.records("playbackStats").isEmpty)
    }
    func testImportedLegacyCounterBaseNotDoubleCountedAfterLocalListening() throws {
        let repository = SyncRepository(database)
        var stat = song(42)
        stat.set("identityKey", stat.identityKey); stat.set("totalListenMs", Int64(100_000)); stat.set("playCount", Int64(3))
        var remote = snapshot([]); remote.record.set("playbackStats", [stat])
        let first = try repository.capture()
        XCTAssertTrue(try repository.apply(remote, expectedRevision: first.revision, target: "test"))
        let track = try XCTUnwrap(try LibraryRepository(database).allTracks().first)
        try PlaybackStatsRepository(database).upsert(PlaybackStats(trackId: track.id, totalListenSeconds: 120, playCount: 4))
        let local = try repository.capture().snapshot
        let projected = try XCTUnwrap(local.record.records("playbackStats").first)
        XCTAssertEqual(projected.number("counterBaseListenMs"), 100_000)
        XCTAssertEqual(projected.records("counterShards").first?.number("totalListenMs"), 20_000)
        let merged = SyncMergeEngine.merge(local: local, remote: remote).snapshot
        XCTAssertEqual(merged.record.records("playbackStats").first?.number("totalListenMs"), 120_000)
    }

    private func shard(_ device: String, listen: Int64, count: Int64) -> SyncRecord {
        SyncRecord(["deviceId": .string(device), "totalListenMs": .integer(listen), "playCount": .integer(count)])
    }
    private func gzip(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw SyncError.invalidSnapshot }
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 1_024)
        let status = input.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            return output.withUnsafeMutableBufferPointer { buffer in
                stream.next_out = buffer.baseAddress; stream.avail_out = uInt(buffer.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        XCTAssertEqual(status, Z_STREAM_END)
        return Data(output.prefix(output.count - Int(stream.avail_out)))
    }
}

private actor M7MemoryTransport: SyncTransport {
    nonisolated var targetID: String { "memory" }
    var data: Data?
    var conflictOnce: Bool
    var uploads = 0
    init(data: Data?, conflictOnce: Bool) { self.data = data; self.conflictOnce = conflictOnce }
    func fetch() -> SyncRemoteSnapshot { SyncRemoteSnapshot(data: data, version: "v1") }
    func upload(_ data: Data, replacing remote: SyncRemoteSnapshot) throws -> String? {
        uploads += 1
        if conflictOnce { conflictOnce = false; throw SyncError.conflict }
        self.data = data; return "v2"
    }
}
private struct M7MutatingTransport: SyncTransport {
    let database: DatabaseProvider
    var targetID: String { "mutating" }
    func fetch() throws -> SyncRemoteSnapshot {
        _ = try PlaylistRepository(database).create(name: "In-flight")
        return SyncRemoteSnapshot(data: nil, version: "v1")
    }
    func upload(_ data: Data, replacing remote: SyncRemoteSnapshot) throws -> String? { XCTFail("Must not upload stale local state"); return nil }
}
