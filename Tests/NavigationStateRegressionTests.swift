import XCTest
import SwiftUI
@testable import NeriPlayer

@MainActor
final class NavigationStateRegressionTests: XCTestCase {
    func testLibraryBrowserStateKeepsLocalAndFavoriteContextsIndependent() {
        let browser = MediaLibraryBrowserState()
        browser.local.section = .artists
        browser.local.artistID = "artist-1"
        browser.local.query = "local query"
        browser.local.scrollPositions["artists"] = NSPoint(x: 0, y: 240)

        browser.favorites.section = .albums
        browser.favorites.albumID = "album-1"
        browser.favorites.query = "favorite query"
        browser.favorites.scrollPositions["albums"] = NSPoint(x: 0, y: 80)

        XCTAssertEqual(browser.local.section, .artists)
        XCTAssertEqual(browser.local.artistID, "artist-1")
        XCTAssertEqual(browser.local.query, "local query")
        XCTAssertEqual(browser.local.scrollPositions["artists"]?.y, 240)
        XCTAssertEqual(browser.favorites.section, .albums)
        XCTAssertEqual(browser.favorites.albumID, "album-1")
        XCTAssertEqual(browser.favorites.query, "favorite query")
        XCTAssertEqual(browser.favorites.scrollPositions["albums"]?.y, 80)

        browser.local.changeSection(.artists)
        browser.local.artistID = "removed-artist"
        browser.local.albumID = "removed-album"
        browser.local.reconcile(artistIDs: [], albumIDs: [])
        XCTAssertNil(browser.local.artistID, "库更新后失效的详情应返回聚合列表")
        XCTAssertNil(browser.local.albumID)
        XCTAssertEqual(LibraryScrollPosition.Coordinator.clamped(NSPoint(x: 0, y: 500),
                                                                  document: NSSize(width: 300, height: 800),
                                                                  viewport: NSSize(width: 300, height: 400)).y, 400)

        browser.local.changeSection(.songs)
        XCTAssertNil(browser.local.artistID)
        XCTAssertNil(browser.local.albumID)
        XCTAssertEqual(browser.favorites.albumID, "album-1")
    }

    func testScrollPositionSurvivesRealScrollViewMountAndRemount() {
        let browser = LibraryBrowserState()
        browser.scrollPositions["songs"] = NSPoint(x: 0, y: 190)

        let first = makeScrollHierarchy()
        let firstCoordinator = LibraryScrollPosition.Coordinator()
        firstCoordinator.attach(from: first.marker, browser: browser, key: "songs")
        drainMainQueue()
        XCTAssertEqual(first.list.contentView.bounds.origin.y, 190, accuracy: 0.5,
                       "偏移应恢复到 List 对应的纵向 NSScrollView")
        XCTAssertEqual(first.horizontal.contentView.bounds.origin.y, 0, accuracy: 0.5,
                       "同级横向导航滚动容器不应被选中")

        let clip = first.list.contentView
        clip.scroll(to: NSPoint(x: 0, y: 275))
        first.list.reflectScrolledClipView(clip)
        drainMainQueue()
        XCTAssertEqual(browser.scrollPositions["songs"]?.y ?? -1, 275, accuracy: 0.5,
                       "真实 clip view 偏移应写回浏览状态")
        firstCoordinator.detach()

        let second = makeScrollHierarchy()
        let secondCoordinator = LibraryScrollPosition.Coordinator()
        secondCoordinator.attach(from: second.marker, browser: browser, key: "songs")
        drainMainQueue()
        XCTAssertEqual(second.list.contentView.bounds.origin.y, 275, accuracy: 0.5,
                       "新建的 List 滚动容器应恢复刚保存的偏移")
        secondCoordinator.detach()
    }

    func testOverlappingScrollCandidatesPreferVerticalViewport() {
        let browser = LibraryBrowserState()
        browser.scrollPositions["overlap"] = NSPoint(x: 0, y: 110)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        let vertical = NSScrollView(frame: host.bounds)
        vertical.hasVerticalScroller = true
        vertical.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 900))
        host.addSubview(vertical)
        let horizontal = NSScrollView(frame: host.bounds)
        horizontal.hasHorizontalScroller = true
        horizontal.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 220))
        host.addSubview(horizontal)
        let marker = NSView(frame: host.bounds)
        host.addSubview(marker)

        let coordinator = LibraryScrollPosition.Coordinator()
        coordinator.attach(from: marker, browser: browser, key: "overlap")
        drainMainQueue()
        XCTAssertEqual(vertical.contentView.bounds.origin.y, 110, accuracy: 0.5,
                       "几何重叠相同时应由纵向可滚动列表优先")
        XCTAssertEqual(horizontal.contentView.bounds.origin.y, 0, accuracy: 0.5)
        coordinator.detach()
    }

    func testScrollPositionAttachesToSwiftUIListBackgroundInHostingView() {
        let browser = LibraryBrowserState()
        browser.scrollPositions["hosting-list"] = NSPoint(x: 0, y: 280)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
                              styleMask: .borderless, backing: .buffered, defer: true)
        let firstHost = NSHostingView(rootView: SwiftUIScrollFixture(browser: browser)
            .frame(width: 420, height: 420))
        window.contentView = firstHost
        window.layoutIfNeeded()
        drainMainQueue()

        guard let firstList = verticalScrollView(in: firstHost) else {
            XCTFail("SwiftUI List did not create a vertical NSScrollView")
            return
        }
        XCTAssertEqual(firstList.contentView.bounds.origin.y, 280, accuracy: 1,
                       "List 的 background representable 应在真实 hosting tree 中恢复偏移")
        let clip = firstList.contentView
        clip.scroll(to: NSPoint(x: 0, y: 345))
        firstList.reflectScrolledClipView(clip)
        drainMainQueue()
        XCTAssertEqual(browser.scrollPositions["hosting-list"]?.y ?? -1, 345, accuracy: 1,
                       "真实 SwiftUI List 的 clip bounds 应写回浏览状态")

        let secondHost = NSHostingView(rootView: SwiftUIScrollFixture(browser: browser)
            .frame(width: 420, height: 420))
        window.contentView = secondHost
        window.layoutIfNeeded()
        drainMainQueue()
        guard let secondList = verticalScrollView(in: secondHost) else {
            XCTFail("重建后的 SwiftUI List did not create a vertical NSScrollView")
            return
        }
        XCTAssertEqual(secondList.contentView.bounds.origin.y, 345, accuracy: 1,
                       "重建 hosting view 后 List 应恢复上次真实滚动位置")
    }

    func testMainNavigationConditionRemovalPreservesLibraryViewport() {
        let state = MainNavigationProbeState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: .borderless, backing: .buffered, defer: true)
        let host = NSHostingView(rootView: MainNavigationScrollFixture(state: state)
            .frame(width: 640, height: 480))
        window.contentView = host
        window.contentView?.layoutSubtreeIfNeeded()
        drainMainQueue()

        guard let firstList = verticalScrollView(in: host) else {
            XCTFail("主导航媒体库分支未创建纵向列表")
            return
        }
        let clip = firstList.contentView
        clip.scroll(to: NSPoint(x: 0, y: 360))
        firstList.reflectScrolledClipView(clip)
        drainMainQueue()
        let saved = state.browser.scrollPositions["main-library"]?.y ?? 0
        XCTAssertGreaterThan(saved, 300, "活动媒体库列表的真实滚动应已捕获")

        state.select("home") // Removes the entire media-library branch from NavigationSplitView.
        window.contentView?.layoutSubtreeIfNeeded()
        drainMainQueue()
        XCTAssertEqual(state.browser.scrollPositions["main-library"]?.y ?? -1, saved, accuracy: 1,
                       "卸载旧页面时不能用已重置的 clip bounds 覆盖保存位置")

        state.select("library")
        window.contentView?.layoutSubtreeIfNeeded()
        drainMainQueue()
        guard let restoredList = verticalScrollView(in: host) else {
            XCTFail("返回媒体库后未重建纵向列表")
            return
        }
        XCTAssertEqual(restoredList.contentView.bounds.origin.y, saved, accuracy: 1,
                       "主导航重新创建媒体库分支后应回到离开时的视口")
    }

    func testPlaybackSourceLabelDistinguishesOriginalAndResolvedSources() {
        XCTAssertEqual(PlaybackSourceText.text(original: .bilibili, resolved: .netease),
                       "原曲：Bilibili · 播放：网易云")
        XCTAssertEqual(PlaybackSourceText.text(original: .netease, resolved: .netease), "播放：网易云")
        XCTAssertEqual(PlaybackSourceText.text(original: .bilibili, resolved: nil),
                       "原曲：Bilibili · 播放来源待解析")
        XCTAssertNil(PlaybackSourceText.text(original: nil, resolved: nil),
                     "本地曲目不应产生重复的平台标签")
    }

    func testStaleCatalogAndArtistResponsesAreIgnoredAfterContextReset() async throws {
        let client = DelayedCatalogClient()
        let sessions = OnlineSessionStore(credentials: OnlineMemoryCredentials())
        let content = OnlineContentRepository(clients: [client], sessions: sessions)
        let online = OnlineViewModel(clients: [client], sessions: sessions, store: nil,
                                     content: content, loadsBrowseContent: false)
        online.setQuery("洛天依")
        let model = SearchPageModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        model.category = .artists
        model.search(using: online)
        try await waitUntil { await client.hasPendingCatalog() }
        model.category = .songs // Mirrors switching away from artist search.
        await client.finishCatalog([CatalogItem(source: .netease, sourceID: "artist-1", title: "stale",
                                                subtitle: "", artworkURL: nil, category: .artists)])
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.selectedArtist)
        XCTAssertFalse(model.isLoading)

        model.category = .artists
        let artist = CatalogItem(source: .netease, sourceID: "artist-2", title: "洛天依Official",
                                 subtitle: "", artworkURL: nil, category: .artists)
        model.openArtist(artist, using: online)
        try await waitUntil { await client.hasPendingArtist() }
        model.category = .playlists
        await client.finishArtist([SongData(source: .netease, sourceID: "song-1", title: "stale song")])
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(model.artistTracks.isEmpty)
        XCTAssertNil(model.selectedArtist)
        XCTAssertFalse(model.isLoading)
        online.stop()
    }

    private func waitUntil(_ condition: () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for test request", file: file, line: line)
    }

    private func makeScrollHierarchy() -> (horizontal: NSScrollView, list: NSScrollView, marker: NSView) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let horizontal = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 50))
        horizontal.hasVerticalScroller = true
        horizontal.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        container.addSubview(horizontal)

        let list = NSScrollView(frame: NSRect(x: 0, y: 60, width: 400, height: 240))
        list.hasVerticalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1_000))
        let marker = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        document.addSubview(marker)
        list.documentView = document
        container.addSubview(list)
        container.layoutSubtreeIfNeeded()
        list.layoutSubtreeIfNeeded()
        return (horizontal, list, marker)
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
    }

    private func verticalScrollView(in root: NSView) -> NSScrollView? {
        var candidates: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView { candidates.append(scroll) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return candidates.max {
            let lhs = ($0.documentView?.bounds.height ?? 0) - $0.contentView.bounds.height
            let rhs = ($1.documentView?.bounds.height ?? 0) - $1.contentView.bounds.height
            return lhs < rhs
        }
    }
}

private actor DelayedCatalogClient: OnlineCatalogClient {
    nonisolated let source = MusicSource.netease
    private var catalogContinuation: CheckedContinuation<[CatalogItem], Error>?
    private var artistContinuation: CheckedContinuation<[SongData], Error>?

    func search(query: String, page: Int) async throws -> [SongData] { [] }
    func resolve(song: SongData) async throws -> ResolvedAudio { throw OnlineError.invalidResponse }
    func songs(in collection: OnlineCollection) async throws -> [SongData] { [] }
    func searchCatalog(query: String, category: CatalogCategory, page: Int) async throws -> [CatalogItem] {
        try await withCheckedThrowingContinuation { catalogContinuation = $0 }
    }
    func artistSongs(id: String) async throws -> [SongData] {
        try await withCheckedThrowingContinuation { artistContinuation = $0 }
    }
    func linkedSong(id: String) async throws -> [SongData] { [] }

    func hasPendingCatalog() -> Bool { catalogContinuation != nil }
    func hasPendingArtist() -> Bool { artistContinuation != nil }
    func finishCatalog(_ values: [CatalogItem]) { catalogContinuation?.resume(returning: values); catalogContinuation = nil }
    func finishArtist(_ values: [SongData]) { artistContinuation?.resume(returning: values); artistContinuation = nil }
}

@MainActor
private struct SwiftUIScrollFixture: View {
    let browser: LibraryBrowserState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack { ForEach(0..<24, id: \.self) { Text("Tab \($0)").frame(width: 90) } }
            }
            .frame(height: 42)
            List(0..<100, id: \.self) { index in
                Text("Row \(index)").frame(height: 32)
            }
            .background(LibraryScrollPosition(browser: browser, key: "hosting-list"))
        }
    }
}

@MainActor
private final class MainNavigationProbeState: ObservableObject {
    @Published var selection = "library"
    let browser = LibraryBrowserState()

    func select(_ value: String) {
        if selection == "library", value != "library" { browser.deactivateScrollCapture() }
        selection = value
    }
}

@MainActor
private struct MainNavigationScrollFixture: View {
    @ObservedObject var state: MainNavigationProbeState

    var body: some View {
        NavigationSplitView {
            VStack {
                Button("首页") { state.select("home") }
                Button("媒体库") { state.select("library") }
            }
        } detail: {
            Group {
                if state.selection == "library" {
                    MainNavigationLibraryPage(browser: state.browser)
                } else {
                    Text("首页")
                }
            }
            .navigationTitle(state.selection == "library" ? "媒体库" : "首页")
        }
    }
}

@MainActor
private struct MainNavigationLibraryPage: View {
    let browser: LibraryBrowserState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack { ForEach(0..<24, id: \.self) { Text("分类 \($0)").frame(width: 90) } }
            }
            .frame(height: 42)
            List(0..<120, id: \.self) { index in
                Text("Track \(index)").frame(height: 32)
            }
            .background(LibraryScrollPosition(browser: browser, key: "main-library"))
        }
        .onAppear { browser.activateScrollCapture() }
        .onDisappear { browser.deactivateScrollCapture() }
    }
}
