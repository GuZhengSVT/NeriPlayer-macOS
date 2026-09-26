// LibraryScannerTests.swift
// NeriPlayer macOS —— M2-T2：媒体库扫描测试。
//
// 素材策略：根目录建在临时目录（setUp 创建、tearDown 删除），其中
//   - 音频样本从 Tests/Fixtures/Audio/（M2-T1 提交入库的小样本）复制而来；
//   - 中文/日文文件名用「无标签样本改名」制造，从而能确定性地断言文件名兜底；
//   - 嵌套目录做到深度 3，覆盖「深层递归」；
//   - 非音频扩展名与符号链接（指向上级与自引用）用于覆盖忽略与防环。
// 具体目录树见 setUp 注释。
//
// 增量语义的验证靠 LibraryScanResult.scannedCount / skippedCount：
//   - 首次扫描：scannedCount == 音频总数、skippedCount == 0；
//   - 第二次未改动：skippedCount == 音频总数、scannedCount == 0，且 Track.id 与首轮一致，
//     证明是「复用上次结果」而非重新构造；
//   - 改动一个文件：只有它被重读（scannedCount == 1）；
//   - 删除一个文件：removedCount == 1，缓存被剔除。

import XCTest
@testable import NeriPlayer

final class LibraryScannerTests: XCTestCase {

    // MARK: - 固定素材与期望值

    /// 目录树中的音频文件总数（与 setUp 保持一致）。
    private static let expectedAudioCount = 13
    /// 目录树中被扩展名白名单挡掉的普通文件数（与 setUp 保持一致）。
    private static let expectedIgnoredFileCount = 6

    private var tempDir: URL!
    /// 库根目录：tempDir/library。
    private var libraryDir: URL!
    /// 从测试 bundle 取出的音频素材目录。
    private var fixtureDir: URL!

    // MARK: - setUp / tearDown

    override func setUpWithError() throws {
        try super.setUpWithError()
        let fileManager = FileManager.default
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("NeriPlayerLibraryScannerTests-\(UUID().uuidString)", isDirectory: true)
        libraryDir = tempDir.appendingPathComponent("library", isDirectory: true)
        fixtureDir = try Self.locateFixtureDirectory()
        try fileManager.createDirectory(at: libraryDir, withIntermediateDirectories: true)

        // 根目录：9 个音频 + 5 个非音频。
        try copyFixture("tagged.mp3", to: "tagged.mp3")
        try copyFixture("tagged.flac", to: "tagged.flac")
        try copyFixture("tagged.m4a", to: "tagged.m4a")
        try copyFixture("tagged.ogg", to: "tagged.ogg")
        try copyFixture("tagged.wav", to: "tagged.wav")
        try copyFixture("untagged.wav", to: "untagged.wav")
        try copyFixture("Fallback Artist - Fallback Title.wav", to: "Fallback Artist - Fallback Title.wav")
        // 中文名 + 真实标签：验证非 ASCII 路径能被遍历与读取（此时标签优先于文件名）。
        try copyFixture("tagged.mp3", to: "周杰伦 - 七里香.mp3")
        // 大写扩展名：验证扩展名比对大小写不敏感。
        try copyFixture("tagged.mp3", to: "UPPERCASE.MP3")

        try writeIgnoredFile("notes.txt")
        try writeIgnoredFile("cover.png")
        try writeIgnoredFile("artwork.jpg")
        try writeIgnoredFile("sheet.pdf")
        try writeIgnoredFile("bonus.m4b")

        // 嵌套：Album A/track1.mp3（深度 1），Album A/Disc 1/track2.flac（深度 2），
        // Album A/Disc 1/Extras/{中文,日文}.wav（深度 3，覆盖规划要求的「嵌套深度 ≥3」）。
        let albumA = libraryDir.appendingPathComponent("Album A", isDirectory: true)
        let discOne = albumA.appendingPathComponent("Disc 1", isDirectory: true)
        let extras = discOne.appendingPathComponent("Extras", isDirectory: true)
        try fileManager.createDirectory(at: extras, withIntermediateDirectories: true)
        try copyFixture("tagged.mp3", toRelativePath: "Album A/track1.mp3")
        try copyFixture("tagged.flac", toRelativePath: "Album A/Disc 1/track2.flac")
        // 中文/日文文件名兜底：用「无标签」样本改名，标签缺失才会落到文件名解析。
        try copyFixture("untagged.wav", toRelativePath: "Album A/Disc 1/Extras/邓紫棋 - 光年之外.wav")
        try copyFixture("untagged.wav", toRelativePath: "Album A/Disc 1/Extras/あいみょん - マリーゴールド.wav")
        try writeIgnoredFile("Album A/readme.txt")
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        libraryDir = nil
        fixtureDir = nil
        try super.tearDownWithError()
    }

    // MARK: - 素材工具

    /// 定位 bundle 里的素材目录（.copy("Fixtures/Audio") 会以 Audio 为名落在资源根）。
    private static func locateFixtureDirectory() throws -> URL {
        if let url = Bundle.module.url(forResource: "Audio", withExtension: nil) {
            return url
        }
        if let resources = Bundle.module.resourceURL {
            let candidate = resources.appendingPathComponent("Audio", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw XCTSkip("缺少测试素材目录（Tests/Fixtures/Audio）")
    }

    /// 把素材文件复制到库根目录下的相对路径。
    private func copyFixture(_ fixtureName: String, toRelativePath relativePath: String) throws {
        try copyFixture(fixtureName, toRelativePath: relativePath, root: libraryDir)
    }

    private func copyFixture(_ fixtureName: String, to destinationName: String) throws {
        try copyFixture(fixtureName, toRelativePath: destinationName, root: libraryDir)
    }

    private func copyFixture(_ fixtureName: String, toRelativePath relativePath: String, root: URL) throws {
        let source = fixtureDir.appendingPathComponent(fixtureName)
        let destination = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// 写一个非音频文件（内容无关，只验证扩展名过滤）。
    private func writeIgnoredFile(_ relativePath: String) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not audio".utf8).write(to: url)
    }

    // MARK: - 基本扫描

    /// 基本扫描：数量正确、非音频被忽略、嵌套与大小写扩展名都覆盖到。
    func testScanCollectsAudioFilesAndIgnoresOthers() throws {
        let result = LibraryScanner().scan(directory: libraryDir)

        XCTAssertEqual(result.tracks.count, Self.expectedAudioCount, "音频文件数")
        XCTAssertEqual(result.discoveredCount, Self.expectedAudioCount)
        XCTAssertEqual(result.ignoredFileCount, Self.expectedIgnoredFileCount, "非音频文件数")
        XCTAssertEqual(result.scannedCount, Self.expectedAudioCount, "首轮应全部重读")
        XCTAssertEqual(result.skippedCount, 0, "首轮无缓存可复用")
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(result.directory, libraryDir.standardizedFileURL)

        // 每个 Track 的 URL 都指向真实存在的文件。
        for track in result.tracks {
            XCTAssertTrue(FileManager.default.fileExists(atPath: track.url.path), "\(track.url.path) 应存在")
        }
        // 非音频扩展名不出现在结果里。
        let names = result.tracks.map { $0.url.lastPathComponent }
        XCTAssertFalse(names.contains("notes.txt"))
        XCTAssertFalse(names.contains("cover.png"))
        XCTAssertFalse(names.contains("bonus.m4b"), "m4b 不在白名单内")
        XCTAssertFalse(names.contains("readme.txt"))
        // 大写扩展名被当作音频纳入。
        XCTAssertTrue(names.contains("UPPERCASE.MP3"), "扩展名比对应大小写不敏感")
    }

    /// 空目录：返回空结果，不崩溃。
    func testScanEmptyDirectoryReturnsEmptyResult() throws {
        let emptyDir = tempDir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let result = LibraryScanner().scan(directory: emptyDir)
        XCTAssertTrue(result.tracks.isEmpty)
        XCTAssertEqual(result.discoveredCount, 0)
        XCTAssertEqual(result.scannedCount, 0)
        XCTAssertEqual(result.skippedCount, 0)
    }

    /// 目录不存在：返回空结果且不抛异常。
    func testScanMissingDirectoryReturnsEmptyResult() {
        let missing = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        let result = LibraryScanner().scan(directory: missing)
        XCTAssertTrue(result.tracks.isEmpty)
        XCTAssertEqual(result.discoveredCount, 0)
    }

    // MARK: - 嵌套与文件名

    /// 嵌套目录递归：深度 ≥3 的文件也要出现，且相对路径正确。
    func testRecursesIntoNestedDirectories() throws {
        let result = LibraryScanner().scan(directory: libraryDir)
        let relativePaths = Set(result.tracks.map { relativePath(of: $0.url) })

        XCTAssertTrue(relativePaths.contains("Album A/track1.mp3"), "深度 1")
        XCTAssertTrue(relativePaths.contains("Album A/Disc 1/track2.flac"), "深度 2")
        XCTAssertTrue(relativePaths.contains("Album A/Disc 1/Extras/邓紫棋 - 光年之外.wav"), "深度 3 中文名")
        XCTAssertTrue(
            relativePaths.contains("Album A/Disc 1/Extras/あいみょん - マリーゴールド.wav"),
            "深度 3 日文名"
        )
    }

    /// 中文名：有标签时用标签值；无标签时用文件名兜底拆出 artist/title。
    func testChineseNameMetadataForTaggedAndUntaggedFiles() throws {
        let result = LibraryScanner().scan(directory: libraryDir)
        let byName = Dictionary(uniqueKeysWithValues: result.tracks.map { ($0.url.lastPathComponent, $0) })

        // 有标签的中文名文件：标签优先于文件名。
        let tagged = try XCTUnwrap(byName["周杰伦 - 七里香.mp3"])
        XCTAssertEqual(tagged.title, "Fixture Title")
        XCTAssertEqual(tagged.artist, "Fixture Artist")
        XCTAssertNotNil(tagged.duration)

        // 无标签的中文名文件：文件名兜底 artist=邓紫棋 / title=光年之外。
        let chineseFallback = try XCTUnwrap(byName["邓紫棋 - 光年之外.wav"])
        XCTAssertEqual(chineseFallback.artist, "邓紫棋")
        XCTAssertEqual(chineseFallback.title, "光年之外")

        // 无标签的日文名文件：同样走文件名兜底。
        let japaneseFallback = try XCTUnwrap(byName["あいみょん - マリーゴールド.wav"])
        XCTAssertEqual(japaneseFallback.artist, "あいみょん")
        XCTAssertEqual(japaneseFallback.title, "マリーゴールド")
    }

    // MARK: - 增量扫描

    /// 第二次扫描未改动：全部复用缓存，不重读元数据，Track.id 保持不变。
    func testSecondScanSkipsUnchangedFilesAndKeepsStableIdentity() {
        let scanner = LibraryScanner()
        let first = scanner.scan(directory: libraryDir)
        let second = scanner.scan(directory: libraryDir)

        XCTAssertEqual(second.tracks.count, Self.expectedAudioCount)
        XCTAssertEqual(second.scannedCount, 0, "指纹未变不应重读任何文件")
        XCTAssertEqual(second.skippedCount, Self.expectedAudioCount, "全部应命中缓存")
        XCTAssertEqual(second.removedCount, 0)

        // id 稳定：证明复用上次产出的 Track，而非重新构造。
        XCTAssertEqual(
            Set(first.tracks.map(\.id)),
            Set(second.tracks.map(\.id)),
            "同一文件跨扫描应得到同一 Track.id"
        )
    }

    /// 改动一个文件：只有它被重读，其余仍复用缓存。
    func testChangedFileIsReReadOthersSkipped() throws {
        let scanner = LibraryScanner()
        _ = scanner.scan(directory: libraryDir)

        let changedPath = libraryDir.appendingPathComponent("tagged.flac").path
        try Data(repeating: 0x5A, count: 4096).write(to: URL(fileURLWithPath: changedPath))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: changedPath
        )

        let second = scanner.scan(directory: libraryDir)
        XCTAssertEqual(second.scannedCount, 1, "只有被改动的文件需要重读")
        XCTAssertEqual(second.skippedCount, Self.expectedAudioCount - 1)
        XCTAssertEqual(second.removedCount, 0)
        XCTAssertEqual(second.tracks.count, Self.expectedAudioCount)
    }

    /// 仅改修改时间（内容与体积不变）：指纹变化即视为需要重读。
    func testTouchedFileIsReRead() throws {
        let scanner = LibraryScanner()
        _ = scanner.scan(directory: libraryDir)

        let touchedPath = libraryDir.appendingPathComponent("tagged.mp3").path
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(300)],
            ofItemAtPath: touchedPath
        )

        let second = scanner.scan(directory: libraryDir)
        XCTAssertEqual(second.scannedCount, 1)
        XCTAssertEqual(second.skippedCount, Self.expectedAudioCount - 1)
    }

    /// 删除文件：缓存条目被剔除，removedCount 反映出来。
    func testDeletedFileIsPrunedFromCache() throws {
        let scanner = LibraryScanner()
        let first = scanner.scan(directory: libraryDir)

        try FileManager.default.removeItem(at: libraryDir.appendingPathComponent("untagged.wav"))

        let second = scanner.scan(directory: libraryDir)
        XCTAssertEqual(second.tracks.count, first.tracks.count - 1)
        XCTAssertEqual(second.removedCount, 1, "被删文件应从缓存剔除")
        XCTAssertEqual(second.skippedCount, Self.expectedAudioCount - 1)
        XCTAssertEqual(second.scannedCount, 0)

        // 再扫一次：缓存已收敛，不再有剔除。
        let third = scanner.scan(directory: libraryDir)
        XCTAssertEqual(third.removedCount, 0)
        XCTAssertEqual(third.skippedCount, Self.expectedAudioCount - 1)
    }

    /// 多目录共用同一 scanner：各自维护缓存，互不剪枝。
    func testMultipleDirectoriesShareScannerWithoutCrossPruning() throws {
        let otherRoot = tempDir.appendingPathComponent("other-library", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try copyFixture("tagged.mp3", toRelativePath: "only.mp3", root: otherRoot)

        let scanner = LibraryScanner()
        let libraryFirst = scanner.scan(directory: libraryDir)
        let otherFirst = scanner.scan(directory: otherRoot)
        XCTAssertEqual(otherFirst.tracks.count, 1)
        XCTAssertEqual(otherFirst.scannedCount, 1)

        // 重扫 library：仍应全部命中缓存，且不影响 other-library 的缓存。
        let librarySecond = scanner.scan(directory: libraryDir)
        XCTAssertEqual(librarySecond.skippedCount, libraryFirst.tracks.count)
        XCTAssertEqual(librarySecond.scannedCount, 0)

        let otherSecond = scanner.scan(directory: otherRoot)
        XCTAssertEqual(otherSecond.scannedCount, 0, "重扫 library 不应剪掉 other-library 的缓存")
        XCTAssertEqual(otherSecond.skippedCount, 1)
    }

    // MARK: - 符号链接

    /// 指向库根自身的目录符号链接不被跟随：不重复计数、不无限递归。
    func testSelfReferencingDirectorySymlinkIsNotFollowed() throws {
        let loop = libraryDir.appendingPathComponent("loop", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: libraryDir)

        let result = LibraryScanner().scan(directory: libraryDir)
        XCTAssertEqual(result.tracks.count, Self.expectedAudioCount, "符号链接目录不应产生重复条目")
        XCTAssertFalse(result.tracks.contains { $0.url.path.contains("/loop/") })
    }

    /// 指向上级目录的符号链接不被跟随：既不会二次扫到 library，也不会串到临时目录其它内容。
    func testUpwardDirectorySymlinkIsNotFollowed() throws {
        let up = libraryDir.appendingPathComponent("up", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: up, withDestinationURL: tempDir)

        let result = LibraryScanner().scan(directory: libraryDir)
        XCTAssertEqual(result.tracks.count, Self.expectedAudioCount)
        XCTAssertFalse(result.tracks.contains { $0.url.path.contains("/up/") })
    }

    /// 指向音频文件的符号链接不被当作文件纳入。
    func testFileSymlinkIsNotFollowed() throws {
        let link = libraryDir.appendingPathComponent("link-to-tagged.mp3")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: libraryDir.appendingPathComponent("tagged.mp3")
        )

        let result = LibraryScanner().scan(directory: libraryDir)
        XCTAssertEqual(result.tracks.count, Self.expectedAudioCount)
        XCTAssertFalse(result.tracks.contains { $0.url.lastPathComponent == "link-to-tagged.mp3" })
    }

    // MARK: - 进度

    /// 进度流覆盖 discovering → reading → finished，且 processed 单调递增到总数。
    func testProgressStreamCoversAllPhases() async {
        let scanner = LibraryScanner()
        let stream = scanner.observeProgress()
        let result = scanner.scan(directory: libraryDir)
        let events = await collectProgress(stream)

        XCTAssertFalse(events.isEmpty, "应至少产出进度事件")
        XCTAssertEqual(events.first?.phase, .discovering)
        XCTAssertEqual(events.last?.phase, .finished)
        XCTAssertTrue(events.contains { $0.phase == .reading })

        // reading 阶段的 processed 应单调不减，且最终等于总数。
        let processedInReading = events.filter { $0.phase == .reading }.map(\.processed)
        XCTAssertEqual(processedInReading, processedInReading.sorted(), "processed 应单调不减")
        XCTAssertEqual(processedInReading.last, result.discoveredCount)

        let finished = try? XCTUnwrap(events.last)
        XCTAssertEqual(finished?.total, result.discoveredCount)
        XCTAssertEqual(finished?.processed, result.discoveredCount)
    }

    // MARK: - 辅助

    /// Track 的 URL 相对库根目录的路径（用 "/" 分隔，便于断言）。
    private func relativePath(of url: URL) -> String {
        let rootPath = libraryDir.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        guard fullPath.hasPrefix(rootPath + "/") else { return fullPath }
        return String(fullPath.dropFirst(rootPath.count + 1))
    }

    /// 收集进度事件直到 finished（带超时，避免流不结束时挂住测试）。
    private func collectProgress(
        _ stream: AsyncStream<LibraryScanProgress>,
        timeout: Double = 5
    ) async -> [LibraryScanProgress] {
        await withTaskGroup(of: [LibraryScanProgress].self) { group in
            group.addTask {
                var events: [LibraryScanProgress] = []
                for await event in stream {
                    events.append(event)
                    if event.phase == .finished { break }
                }
                return events
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }
}
