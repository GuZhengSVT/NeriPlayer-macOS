// LibrarySearchEngineTests.swift
// NeriPlayer macOS —— M2-T6：库内搜索（子串 + 拼音首字母）测试。
//
// 分两层：
//   1) LibrarySearchEngine / LibrarySearchIndex 纯逻辑：不碰数据库，直接造 LibraryTrack 断言命中集合；
//   2) LibraryViewModel：临时库 + 视图模型，验证防抖、三个维度共用过滤结果、清空恢复全量、
//      以及在 refresh 后索引作废重建。
//
// 拼音用例的来源：下面的期望值不是照抄某张手写表，而是 CFStringTransform(kCFStringTransformMandarinLatin
// + StripDiacritics) 在本机的实测输出（见 PinyinConverter 注释）。测试把实测值写成断言，等于把
// 系统 ICU 的行为钉成回归基线；哪天系统改了读音，这里会先红。

import XCTest
@testable import NeriPlayer

// MARK: - 纯逻辑

final class LibrarySearchEngineTests: XCTestCase {

    /// 造一条只关心搜索字段的曲目。
    private func makeTrack(
        _ title: String,
        artist: String? = nil,
        album: String? = nil
    ) -> LibraryTrack {
        LibraryTrack(
            id: UUID(),
            url: URL(fileURLWithPath: "/music/" + UUID().uuidString + "/" + title + ".mp3"),
            title: title,
            artist: artist,
            album: album
        )
    }

    /// 三个字段都可命中，中英混合互不干扰。
    func testSubstringMatchesTitleArtistAndAlbum() {
        let tracks = [
            makeTrack("七里香", artist: "周杰伦", album: "七里香"),
            makeTrack("Hey Jude", artist: "The Beatles", album: "Hey Jude"),
            makeTrack("红玫瑰", artist: "陈奕迅", album: "认了吧")
        ]
        let engine = LibrarySearchEngine.self

        XCTAssertEqual(engine.search(tracks: tracks, query: "七里").count, 1, "标题子串")
        XCTAssertEqual(engine.search(tracks: tracks, query: "杰伦").count, 1, "歌手子串")
        XCTAssertEqual(engine.search(tracks: tracks, query: "认了吧").count, 1, "专辑子串")
        XCTAssertEqual(engine.search(tracks: tracks, query: "beatles").count, 1, "英文歌手")
        XCTAssertTrue(engine.search(tracks: tracks, query: "不存在的内容").isEmpty)
    }

    /// 大小写、首尾空白、全半角都不影响匹配；结果保持输入顺序。
    func testCaseInsensitiveAndWhitespaceInsensitive() {
        let tracks = [
            makeTrack("Alpha", artist: "Kiseki"),
            makeTrack("alphabet", artist: "ＫＩＳＥＫＩ"),
            makeTrack("Beta", artist: "Other")
        ]

        XCTAssertEqual(
            LibrarySearchEngine.search(tracks: tracks, query: "  ALPHA  ").map(\.title),
            ["Alpha", "alphabet"],
            "去首尾空白 + 大小写不敏感，且保持输入顺序"
        )
        XCTAssertEqual(
            LibrarySearchEngine.search(tracks: tracks, query: "kiseki").map(\.title),
            ["Alpha", "alphabet"],
            "全角歌手名折叠后与半角查询同键"
        )
    }

    /// 拼音首字母：实测 七里香 -> qlx、周杰伦 -> zjl、赵雷 -> zl。
    /// 「zl」命中的是赵雷这类首字母组合，七里香的首字母是 qlx（不是 zl）。
    func testPinyinInitialsMatchChinese() {
        XCTAssertEqual(LibrarySearchEngine.initials(of: "七里香"), "qlx")
        XCTAssertEqual(LibrarySearchEngine.initials(of: "周杰伦"), "zjl")
        XCTAssertEqual(LibrarySearchEngine.initials(of: "赵雷"), "zl")
        XCTAssertEqual(LibrarySearchEngine.latin(of: "七里香"), "qilixiang")

        let tracks = [
            makeTrack("七里香", artist: "周杰伦", album: "七里香"),
            makeTrack("成都", artist: "赵雷", album: "无法长大")
        ]

        XCTAssertEqual(LibrarySearchEngine.search(tracks: tracks, query: "qlx").map(\.title), ["七里香"])
        XCTAssertEqual(LibrarySearchEngine.search(tracks: tracks, query: "qilixiang").map(\.title), ["七里香"])
        XCTAssertEqual(LibrarySearchEngine.search(tracks: tracks, query: "QLX").map(\.title), ["七里香"], "首字母查询同样大小写不敏感")
        XCTAssertEqual(LibrarySearchEngine.search(tracks: tracks, query: "zjl").map(\.title), ["七里香"], "按歌手拼音首字母命中")
        XCTAssertEqual(LibrarySearchEngine.search(tracks: tracks, query: "zl").map(\.title), ["成都"], "zl 是赵雷")
        XCTAssertTrue(
            LibrarySearchEngine.search(tracks: tracks, query: "zl").map(\.title).contains("七里香") == false,
            "七里香的首字母是 qlx，zl 不应命中它"
        )
    }

    /// 英文歌手的拼音维度：实测 周杰伦 -> zhoujielun，因此「jay」不会经由拼音命中它；
    /// 「jay」命中的是本来就是 ASCII 的歌手名（Jay 开头的写法）。
    func testLatinPinyinMatchesAndDocumentsJayCase() {
        XCTAssertEqual(LibrarySearchEngine.latin(of: "周杰伦"), "zhoujielun")
        XCTAssertFalse(
            LibrarySearchEngine.latin(of: "周杰伦").contains("jay"),
            "实测周杰伦的拼音是 zhou jie lun，不含 jay —— 用真实转换结果写死这个前提"
        )

        let tracks = [
            makeTrack("七里香", artist: "周杰伦"),
            makeTrack("晴天", artist: "Jay Chou")
        ]

        XCTAssertEqual(
            LibrarySearchEngine.search(tracks: tracks, query: "jay").map(\.title),
            ["晴天"],
            "jay 命中 ASCII 歌手名 Jay Chou"
        )
        XCTAssertEqual(LibrarySearchEngine.search(tracks: tracks, query: "jie").map(\.title), ["七里香"], "声母段子串同样可查")
        XCTAssertEqual(LibrarySearchEngine.search(tracks: tracks, query: "jay chou").map(\.title), ["晴天"], "带空格的多词查询会去掉空格再比")
    }

    /// 中文歌名里夹英文、括号与标点：首字母只取字母/数字音节的首字符，标点不参与。
    func testPinyinInitialsIgnorePunctuation() {
        XCTAssertEqual(LibrarySearchEngine.initials(of: "七里香 (Live)"), "qlx")
        XCTAssertEqual(LibrarySearchEngine.initials(of: "Love 七里香"), "lqlx")
        XCTAssertEqual(LibrarySearchEngine.initials(of: "Greatest Hits"), "gh")

        let tracks = [makeTrack("七里香 (Live)", artist: "周杰伦")]
        XCTAssertEqual(LibrarySearchEngine.search(tracks: tracks, query: "qlx").count, 1)
        XCTAssertEqual(LibrarySearchEngine.search(tracks: tracks, query: "(live").count, 1, "标点仍走子串匹配")
    }

    /// 空查询（含纯空白）原样返回全部曲目。
    func testEmptyQueryReturnsAllTracksInOrder() {
        let tracks = [
            makeTrack("A", artist: "X"),
            makeTrack("B", artist: "Y"),
            makeTrack("C", artist: "Z")
        ]

        XCTAssertEqual(LibrarySearchEngine.search(tracks: tracks, query: "").map(\.title), ["A", "B", "C"])
        XCTAssertEqual(LibrarySearchEngine.search(tracks: tracks, query: "   \n ").map(\.title), ["A", "B", "C"])
        XCTAssertEqual(LibrarySearchEngine.search(tracks: [], query: "anything").count, 0)
    }

    /// 特殊字符 / 正则元字符 / emoji 只当普通文本，不抛错也不误命中。
    func testSpecialCharacterQueriesDoNotCrash() {
        let tracks = [
            makeTrack("七里香 (Live)", artist: "周杰伦"),
            makeTrack("A+B", artist: nil),
            makeTrack("emoji🎵song", artist: nil)
        ]

        for query in ["(", ")", "[", ".*", "\\d+", "^$", "🎵", "％", "\u{0}", "🀄️", "+"] {
            let results = LibrarySearchEngine.search(tracks: tracks, query: query)
            switch query {
            case "(": XCTAssertEqual(results.count, 1, "左括号是普通字符")
            case ".*": XCTAssertTrue(results.isEmpty, "正则语法不生效")
            case "🎵": XCTAssertEqual(results.count, 1, "emoji 可按原样子串匹配")
            case "+": XCTAssertEqual(results.count, 1)
            default: break
            }
        }
        XCTAssertTrue(LibrarySearchEngine.search(tracks: tracks, query: "\\d+").isEmpty)
    }

    /// 重复查询复用同一个索引对象，结果稳定且不依赖调用次数。
    func testIndexIsReusableAndStable() {
        let tracks = [makeTrack("七里香", artist: "周杰伦"), makeTrack("晴天", artist: "Jay Chou")]
        let index = LibrarySearchIndex(tracks: tracks)

        XCTAssertEqual(index.count, tracks.count)
        for _ in 0..<3 {
            XCTAssertEqual(index.search("qlx").map(\.title), ["七里香"])
            XCTAssertEqual(index.search("").count, 2)
        }
    }
}

// MARK: - 视图模型接入

@MainActor
final class LibraryViewModelSearchTests: XCTestCase {

    private var tempDir: URL!
    private var provider: DatabaseProvider!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeriPlayerSearchTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        provider = try DatabaseProvider(url: tempDir.appendingPathComponent("library.sqlite"))
        try provider.setupIfNeeded()
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        provider = nil
        try super.tearDownWithError()
    }

    /// 往临时库落一条曲目。
    private func insertRecord(title: String, artist: String?, album: String?) throws {
        let record = TrackRecord(
            track: Track(
                url: URL(fileURLWithPath: "/music/" + UUID().uuidString + "/" + title + ".mp3"),
                title: title,
                artist: artist,
                duration: 180
            ),
            album: album
        )
        try provider.dbQueue.write { db in try record.insert(db) }
    }

    /// 轮询等待搜索结算完成（防抖 200ms + 后台建索引），而不是固定 sleep。
    private func waitForSearchToSettle(_ viewModel: LibraryViewModel, timeout: Double = 10) async throws {
        var waited = 0.0
        while viewModel.isSearchSettling && waited < timeout {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 0.05
        }
        XCTAssertFalse(viewModel.isSearchSettling, "搜索应在超时前结算")
    }

    /// 输入后先进入防抖等待（结果还没变），结算后 searchResults 命中；清空后恢复全量。
    func testSearchDebouncesThenFiltersAndClears() async throws {
        try insertRecord(title: "七里香", artist: "周杰伦", album: "七里香")
        try insertRecord(title: "晴天", artist: "周杰伦", album: "叶惠美")
        try insertRecord(title: "成都", artist: "赵雷", album: "无法长大")

        let viewModel = LibraryViewModel(database: provider)
        viewModel.load()
        XCTAssertEqual(
            Set(viewModel.searchResults.map(\.title)),
            Set(["七里香", "成都", "晴天"]),
            "初始即全量（顺序由仓库的中文排序决定，这里只比集合）"
        )

        viewModel.searchQuery = "qlx"
        XCTAssertTrue(viewModel.isSearching)
        XCTAssertTrue(viewModel.isSearchSettling, "刚输入时应处于防抖等待")
        XCTAssertEqual(viewModel.searchResults.count, 3, "防抖窗口内结果尚未重算")

        try await waitForSearchToSettle(viewModel)
        XCTAssertEqual(viewModel.searchResults.map(\.title), ["七里香"])
        XCTAssertEqual(viewModel.searchArtistGroups.map(\.name), ["周杰伦"], "歌手维度看到过滤后的聚合")

        viewModel.searchQuery = ""
        try await waitForSearchToSettle(viewModel)
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertEqual(Set(viewModel.searchResults.map(\.title)), Set(["七里香", "成都", "晴天"]))
        XCTAssertEqual(viewModel.searchArtistGroups.count, 2)
        XCTAssertEqual(viewModel.searchAlbumGroups.count, 3)
    }

    /// 拼音命中歌手时，歌手/专辑两个维度都切到过滤态；详情回读也走过滤后的曲目。
    func testSearchFiltersArtistAndAlbumDimensions() async throws {
        try insertRecord(title: "七里香", artist: "周杰伦", album: "七里香")
        try insertRecord(title: "晴天", artist: "周杰伦", album: "叶惠美")
        try insertRecord(title: "成都", artist: "赵雷", album: "无法长大")

        let viewModel = LibraryViewModel(database: provider)
        viewModel.load()
        viewModel.searchQuery = "zjl"
        try await waitForSearchToSettle(viewModel)

        XCTAssertEqual(viewModel.searchResults.count, 2, "按歌手拼音首字母命中两首")
        let group = try XCTUnwrap(viewModel.searchArtistGroups.first)
        XCTAssertEqual(group.name, "周杰伦")
        XCTAssertEqual(group.count, 2)
        XCTAssertEqual(viewModel.tracks(for: group).count, 2, "详情回读应返回过滤后的曲目")
        XCTAssertEqual(viewModel.searchAlbumGroups.count, 2, "过滤后的两张专辑（周杰伦名下）")
    }

    /// refresh 之后索引作废重建：新加入的曲目立刻能被同一条查询命中。
    func testSearchSurvivesRefreshWithNewTracks() async throws {
        try insertRecord(title: "七里香", artist: "周杰伦", album: "七里香")
        let viewModel = LibraryViewModel(database: provider)
        viewModel.load()
        viewModel.searchQuery = "zjl"
        try await waitForSearchToSettle(viewModel)
        XCTAssertEqual(viewModel.searchResults.count, 1)

        try insertRecord(title: "夜曲", artist: "周杰伦", album: "十一月的萧邦")
        viewModel.refresh()
        try await waitForSearchToSettle(viewModel)
        XCTAssertEqual(Set(viewModel.searchResults.map(\.title)), Set(["七里香", "夜曲"]), "索引随曲目集重建")

        viewModel.searchQuery = "yq"
        try await waitForSearchToSettle(viewModel)
        XCTAssertEqual(viewModel.searchResults.map(\.title), ["夜曲"], "按标题拼音首字母命中")

        viewModel.searchQuery = "十一月的萧邦"
        try await waitForSearchToSettle(viewModel)
        XCTAssertEqual(viewModel.searchResults.map(\.title), ["夜曲"], "专辑按子串命中")

        // 边界：拼音索引只建在标题与歌手两个字段上（与任务书一致），专辑不参与拼音匹配。
        viewModel.searchQuery = "shiyiyuedexiaobang"
        try await waitForSearchToSettle(viewModel)
        XCTAssertTrue(viewModel.searchResults.isEmpty, "专辑不建拼音索引，这条查询不应命中")
    }

    /// 查询无命中：列表清空，但没有错误提示（不是失败）。
    func testSearchWithoutMatchYieldsEmptyAndNoError() async throws {
        try insertRecord(title: "七里香", artist: "周杰伦", album: "七里香")
        let viewModel = LibraryViewModel(database: provider)
        viewModel.load()

        viewModel.searchQuery = "zzzzzz"
        try await waitForSearchToSettle(viewModel)

        XCTAssertTrue(viewModel.searchResults.isEmpty)
        XCTAssertTrue(viewModel.searchArtistGroups.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }
}
