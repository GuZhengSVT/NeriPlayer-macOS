import XCTest
@testable import NeriPlayer

/// Uses the actual Settings -> LibraryViewModel -> scanner -> sync service -> SQLite chain.
@MainActor
final class LibraryScanQueueRegressionTests: XCTestCase {
    private struct Context {
        let root: URL
        let first: URL
        let second: URL
        let database: DatabaseProvider
        let scanner: LibraryScanner
        let library: LibraryViewModel
        let settings: SettingsStore
    }

    private func makeContext() throws -> Context {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryScanQueue-\(UUID().uuidString)", isDirectory: true)
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Audio", withExtension: nil))
            .appendingPathComponent("untagged.wav")
        for (directory, name) in [(first, "First Song.wav"), (second, "Second Song.wav")] {
            try FileManager.default.copyItem(at: fixture, to: directory.appendingPathComponent(name))
        }
        let database = try DatabaseProvider(url: root.appendingPathComponent("library.sqlite"))
        try database.setupIfNeeded()
        let scanner = LibraryScanner()
        let repository = LibraryRepository(database)
        let library = LibraryViewModel(
            libraryRepository: repository,
            playlistRepository: PlaylistRepository(database),
            favoriteRepository: FavoriteRepository(database),
            syncService: LibrarySyncService(repository: repository, scanner: scanner)
        )
        let suite = "LibraryScanQueue-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = SettingsStore(userDefaults: defaults)
        let store = LibraryDirectoryStore(settings: settings)
        store.add(first, bookmark: nil)
        store.add(second, bookmark: nil)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return Context(root: root, first: first, second: second, database: database,
                       scanner: scanner, library: library, settings: settings)
    }

    private func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    func testSettingsRescanQueuesBothDirectoriesAndCoalescesRepeatedBatch() async throws {
        let context = try makeContext()
        let library = context.library
        let settings = SettingsViewModel(
            settings: context.settings,
            rescanWithCompletionHandler: { url, completion in
                library.importDirectory(url, completion: completion)
            }
        )
        var starts = 0
        var finishes = 0
        var concurrent = 0
        var maxConcurrent = 0
        let progress = context.scanner.observeProgress()
        let observation = Task { @MainActor in
            for await event in progress {
                if event.phase == .discovering {
                    starts += 1
                    concurrent += 1
                    maxConcurrent = max(maxConcurrent, concurrent)
                } else if event.phase == .finished {
                    finishes += 1
                    concurrent -= 1
                }
            }
        }
        defer { observation.cancel() }

        settings.rescanAll()
        settings.rescanAll() // Active and waiting requests must both coalesce.
        XCTAssertTrue(library.isSyncing)
        XCTAssertEqual(library.activeScanDirectory, canonical(context.first))
        XCTAssertEqual(library.queuedDirectoryCount, 1)
        XCTAssertTrue(settings.statusMessage?.contains("已提交重新扫描 2 个目录") == true)
        XCTAssertFalse(settings.statusMessage?.contains("扫描结束") == true)

        let finished = await waitUntil { !library.isSyncing && finishes == 2 }
        XCTAssertTrue(finished)
        XCTAssertEqual(starts, 2, "Repeated submissions must not start extra scanner passes")
        XCTAssertEqual(maxConcurrent, 1)
        XCTAssertEqual(library.completedScanCount, 2)
        XCTAssertEqual(library.failedScanCount, 0)
        XCTAssertEqual(library.queuedDirectoryCount, 0)
        XCTAssertNil(library.activeScanDirectory)
        XCTAssertEqual(try LibraryRepository(context.database).allTracks().count, 2)
        XCTAssertEqual(Set(library.tracks.map(\.title)), ["First Song", "Second Song"])
        XCTAssertEqual(settings.statusMessage, "扫描结束：完成 2 个目录，失败 0 个")
        XCTAssertNil(library.errorMessage)
    }

    func testFirstResolvedDirectoryFailureDoesNotDiscardSecondOrHideFailure() async throws {
        let context = try makeContext()
        let library = context.library
        var results: [DirectoryScanResult] = []
        var syncingAfterFirstCompletion = false
        var removedFirstDirectory = false
        let settings = SettingsViewModel(
            settings: context.settings,
            rescanWithCompletionHandler: { url, completion in
                // The configured directory resolved, then disappears before the real scan.
                if self.canonical(url) == self.canonical(context.first) {
                    do {
                        try FileManager.default.removeItem(at: url)
                        removedFirstDirectory = true
                    } catch {
                        XCTFail("Could not remove the first directory before its real scan: \(error)")
                    }
                }
                library.importDirectory(url) { result in
                    results.append(result)
                    if results.count == 1 {
                        syncingAfterFirstCompletion = library.isSyncing
                        XCTAssertEqual(library.activeScanDirectory, self.canonical(context.second))
                    }
                    completion(result)
                }
            }
        )
        settings.rescanAll()
        XCTAssertTrue(library.isSyncing)
        XCTAssertEqual(library.queuedDirectoryCount, 1)
        let finished = await waitUntil { !library.isSyncing && results.count == 2 }
        XCTAssertTrue(finished)
        XCTAssertTrue(removedFirstDirectory, "The resolved first directory must be removed to exercise a real scan failure")
        XCTAssertTrue(syncingAfterFirstCompletion, "No false idle state between queued scans")
        guard case .failure = results.first, case .success = results.last else {
            return XCTFail("The actual sync service must fail first and import second")
        }
        XCTAssertEqual(library.completedScanCount, 1)
        XCTAssertEqual(library.failedScanCount, 1)
        XCTAssertEqual(try LibraryRepository(context.database).allTracks().map(\.title), ["Second Song"])
        XCTAssertTrue(library.errorMessage?.contains("First") == true)
        XCTAssertTrue(settings.statusMessage?.contains("扫描结束：完成 1 个目录，失败 1 个") == true)
        XCTAssertTrue(settings.statusMessage?.contains("First") == true)
    }

    func testActiveAndQueuedAliasesShareOneScanAndNotifyEachCallerOnce() async throws {
        let context = try makeContext()
        let library = context.library
        let alias = context.root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: context.first)
        var completions = [Int: Int]()
        for (index, directory) in [context.first, alias, context.second,
                                   context.second.appendingPathComponent(".")].enumerated() {
            library.importDirectory(directory) { _ in completions[index, default: 0] += 1 }
        }
        XCTAssertTrue(library.isSyncing)
        XCTAssertEqual(library.queuedDirectoryCount, 1)
        let finished = await waitUntil { !library.isSyncing && completions.count == 4 }
        XCTAssertTrue(finished)
        XCTAssertEqual(completions, [0: 1, 1: 1, 2: 1, 3: 1])
        XCTAssertEqual(library.completedScanCount, 2, "Count actual scans, not subscribers")
        XCTAssertEqual(library.tracks.count, 2)
    }

    func testFeedbackIgnoresDuplicateAndPreviousGenerationCallbacks() throws {
        let context = try makeContext()
        var callbacks: [@MainActor (DirectoryScanResult) -> Void] = []
        let settings = SettingsViewModel(
            settings: context.settings,
            rescanWithCompletionHandler: { _, completion in callbacks.append(completion) }
        )
        settings.rescanAll()
        let firstBatch = callbacks
        settings.rescanAll()
        firstBatch.forEach { $0(.failure("旧批次")) }
        XCTAssertFalse(settings.statusMessage?.contains("旧批次") == true)
        callbacks[2](.success("完成"))
        callbacks[2](.failure("重复回调"))
        callbacks[3](.success("完成"))
        XCTAssertEqual(settings.statusMessage, "扫描结束：完成 2 个目录，失败 0 个")
    }

    func testAllUnavailableDirectoriesAreNotReportedAsScanning() throws {
        let context = try makeContext()
        try FileManager.default.removeItem(at: context.first)
        try FileManager.default.removeItem(at: context.second)
        let settings = SettingsViewModel(
            settings: context.settings,
            rescanWithCompletionHandler: { _, _ in XCTFail("Unavailable paths must not be submitted") }
        )
        settings.rescanAll()
        XCTAssertEqual(settings.statusMessage, "未提交扫描请求；First、Second 当前不可用")
        XCTAssertFalse(context.library.isSyncing)
    }
}
