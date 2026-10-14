import AppKit
import ImageIO
import XCTest
@testable import NeriPlayer

final class RemediationStorageTests: XCTestCase {
    func testSharedOutputCanFallbackWithoutChangingExclusiveRequest() {
        let shared = AudioEffectCommandPlan.make(for: .default)
        XCTAssertTrue(shared.contains(.setOutput(driver: "coreaudio,", device: nil)))
        let exclusive = AudioEffectCommandPlan.make(for: AudioEffectSettings(exclusiveOutput: true))
        XCTAssertTrue(exclusive.contains(.setOutput(driver: "coreaudio_exclusive", device: nil)))
    }
    @MainActor
    func testCompletedDownloadLookupReturnsOwnedFileAndDetectsLaterCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DownloadStorage(root: root.appendingPathComponent("Downloads"), cacheRoot: root.appendingPathComponent("Caches"))
        try storage.prepare()
        let song = SongData(source: .netease, sourceID: "42", title: "已下载歌曲")
        let file = storage.completed.appendingPathComponent("owned.mp3")
        try Data("download".utf8).write(to: file)
        var item = AudioDownload(song: song, status: .completed)
        item.fileName = file.lastPathComponent
        item.fileBytes = try DownloadStorage.size(file)
        item.fileDigest = try DownloadStorage.digest(file)
        try JSONEncoder().encode([item]).write(to: storage.queueURL)
        let manager = try DownloadManager(storage: storage, resolve: { _ in throw OnlineError.unavailable("unexpected network") })
        let model = DownloadViewModel(manager: manager, storage: storage)
        let loaded = await model.completedFile(for: item)
        XCTAssertEqual(loaded, file)
        try Data("corrupt".utf8).write(to: file)
        let corrupt = await model.completedFile(for: item)
        XCTAssertNil(corrupt)
        XCTAssertNotNil(model.errorMessage)
        try await manager.stop()
    }

    func testArtworkCleanupLeavesPlaybackAndDownloadsUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")
        let caches = root.appendingPathComponent("Caches")
        for path in [downloads.appendingPathComponent("Files"), caches.appendingPathComponent("Playback"), caches.appendingPathComponent("Artwork/Images")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        try Data(repeating: 0, count: 9).write(to: downloads.appendingPathComponent("Files/a.mp3"))
        try Data(repeating: 0, count: 5).write(to: caches.appendingPathComponent("Playback/a.bin"))
        try Data(repeating: 0, count: 3).write(to: caches.appendingPathComponent("Artwork/Images/a.img"))
        XCTAssertEqual(StorageAnalyzer.measure(downloads: downloads, caches: caches).artworkCache, 3)
        try StorageAnalyzer.clearArtwork(caches: caches)
        let usage = StorageAnalyzer.measure(downloads: downloads, caches: caches)
        XCTAssertEqual(usage.downloads, 9)
        XCTAssertEqual(usage.playbackCache, 5)
        XCTAssertEqual(usage.artworkCache, 0)
    }

    func testLocalArtworkDownsamplesAndNewRevisionReplacesOldImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cover.png")
        let loader = LocalArtworkLoader()
        try writePNG(to: file, width: 1000, height: 500)
        let firstValue = await loader.image(path: file.path, revision: 1)
        let first = try XCTUnwrap(firstValue)
        XCTAssertLessThanOrEqual(first.image.size.width, 256)
        XCTAssertEqual(first.image.size.width / first.image.size.height, 2, accuracy: 0.02)
        try writePNG(to: file, width: 500, height: 1000)
        let updatedValue = await loader.image(path: file.path, revision: 2)
        let updated = try XCTUnwrap(updatedValue)
        XCTAssertEqual(updated.image.size.width / updated.image.size.height, 0.5, accuracy: 0.02)
        let missing = await loader.image(path: root.appendingPathComponent("missing.png").path, revision: nil)
        XCTAssertNil(missing)
    }

    private func writePNG(to url: URL, width: Int, height: Int) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
