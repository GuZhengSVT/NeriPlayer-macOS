// LibrarySearchEngine.swift
// NeriPlayer macOS —— 媒体库库内搜索（移植规划 M2-T6）。
//
// 职责：给定一批 LibraryTrack 与一个查询串，返回命中的曲目（保持输入顺序）。
// 两个匹配维度：
//   1) 子串：标题 / 歌手 / 专辑任一字段包含查询串 —— 大小写、变音符、全半角不敏感，去首尾空白；
//   2) 拼音：标题 / 歌手的汉字转拼音后，按「每字首字母连写」和「音节连写」两种形式匹配，
//      于是 qlx / qilixiang / QLX 都能命中「七里香」。
//
// 拼音方案选型（为什么不手写 GB2312 首字母表）：
//   规划里提到「用 Unicode 区间查 GB2312 编码推首字母」的经典算法，这里改用系统 ICU：
//   - 覆盖：CFStringTransform(kCFStringTransformMandarinLatin) 覆盖整个 CJK 区（含扩展区），
//     GB2312 查表只覆盖它收录的 6763 个字，生僻字与扩展区会漏；
//   - 维护：读音与多音字由系统 ICU 数据负责，手写表一旦落库就是长期维护成本；
//   - 代价：每次转换是一次 ICU 调用（实测 2000 首曲目的标题+歌手约 200ms），
//     所以结果必须缓存 —— 见 LibrarySearchIndex：转换只在建索引时做一次，
//     之后每次按键查询只是内存里的子串比较。
//
// 分层：纯逻辑，只依赖 Foundation；LibrarySearchIndex 是不可变值类型且 Sendable，
// 可以丢到后台线程建好再交回主线程使用（UI 侧正是这么做的）。
//
// 已知取舍：
//   - 多音字取 ICU 默认读音（如「重」在「重庆」里读 zhong），首字母匹配不是词典级精确；
//   - 拼音索引只覆盖标题与歌手，专辑不建拼音索引（与任务书一致）；
//   - 只做子串匹配，不做首字母乱序/模糊匹配：查询必须是索引串里的连续子串。

import Foundation

// MARK: - 拼音转换

/// 汉字转拼音的纯函数集合。
///
/// 单独成一层是为了让「首字母怎么取」只有一处实现：索引构建走它，测试也直接断言
/// 系统 ICU 的实测输出（例如「七里香 -> qlx」），而不是断言某张手写表的想象值。
enum PinyinConverter {

    /// 文本转不带声调的拉丁拼音，音节之间用空格分隔；非汉字字符原样保留。
    ///
    /// 两步转换：MandarinLatin 先把汉字转成带声调拼音，StripDiacritics 再去掉声调符号。
    /// 只做带声调的那一步会留下 «qī lǐ xiāng» 这类字符，无法与 ASCII 查询串比较。
    static func latin(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return mutable as String
    }

    /// 每音节取首字母后连写（小写）：七里香 -> "qlx"，周杰伦 -> "zjl"。
    /// 首字符既不是字母也不是数字的音节（标点、括号、emoji 组成的伪音节）直接跳过，
    /// 因此「七里香 (Live)」的首字母仍是 "qlx" 而不是 "qlx("。
    static func initials(_ text: String) -> String {
        var result = ""
        for syllable in latin(text).lowercased().split(whereSeparator: { $0.isWhitespace }) {
            guard let first = syllable.first, first.isLetter || first.isNumber else { continue }
            result.append(first)
        }
        return result
    }

    /// 音节连写（小写、去空格）：七里香 -> "qilixiang"。
    static func compactLatin(_ text: String) -> String {
        latin(text).lowercased().split(whereSeparator: { $0.isWhitespace }).joined()
    }
}

// MARK: - 搜索索引

/// 预计算索引：把每个字段要参与匹配的字符串一次算好，之后每次查询只做内存子串比较。
///
/// 为什么不在每次查询时现算：拼音转换是 ICU 调用（2000 首约 200ms），放在按键路径上
/// 会卡住主线程；预计算之后单次查询只是几次 `contains`。索引不可变，可安全后台构造。
public struct LibrarySearchIndex: Sendable {

    private let tracks: [LibraryTrack]
    /// 三个展示字段的归一化形式（大小写/变音符/全半角折叠 + 空白压缩）。
    private let titleKeys: [String]
    private let artistKeys: [String]
    private let albumKeys: [String]
    /// 标题 / 歌手的拼音首字母连写与音节连写（都已是小写 ASCII）。
    private let titleInitials: [String]
    private let artistInitials: [String]
    private let titleLatin: [String]
    private let artistLatin: [String]

    /// 建立索引。曲目顺序即结果顺序，索引本身不排序（排序是仓库与聚合的职责）。
    public init(tracks: [LibraryTrack]) {
        var titleKeys: [String] = []
        var artistKeys: [String] = []
        var albumKeys: [String] = []
        var titleInitials: [String] = []
        var artistInitials: [String] = []
        var titleLatin: [String] = []
        var artistLatin: [String] = []
        titleKeys.reserveCapacity(tracks.count)
        artistKeys.reserveCapacity(tracks.count)
        albumKeys.reserveCapacity(tracks.count)
        titleInitials.reserveCapacity(tracks.count)
        artistInitials.reserveCapacity(tracks.count)
        titleLatin.reserveCapacity(tracks.count)
        artistLatin.reserveCapacity(tracks.count)

        for track in tracks {
            let artist = track.artist ?? ""
            titleKeys.append(LibrarySearchEngine.normalize(track.title))
            artistKeys.append(LibrarySearchEngine.normalize(artist))
            albumKeys.append(LibrarySearchEngine.normalize(track.album ?? ""))
            titleInitials.append(PinyinConverter.initials(track.title))
            artistInitials.append(PinyinConverter.initials(artist))
            titleLatin.append(PinyinConverter.compactLatin(track.title))
            artistLatin.append(PinyinConverter.compactLatin(artist))
        }

        self.tracks = tracks
        self.titleKeys = titleKeys
        self.artistKeys = artistKeys
        self.albumKeys = albumKeys
        self.titleInitials = titleInitials
        self.artistInitials = artistInitials
        self.titleLatin = titleLatin
        self.artistLatin = artistLatin
    }

    /// 索引里的曲目数。
    public var count: Int { tracks.count }

    /// 查询。空查询（含纯空白）按任务书要求原样返回全部曲目。
    public func search(_ query: String) -> [LibraryTrack] {
        let normalized = LibrarySearchEngine.normalize(query)
        guard !normalized.isEmpty else { return tracks }
        // 拼音串是去空格的，查询串也去空格再比，这样「qi li xiang」才能命中「qilixiang」。
        let compact = normalized.replacingOccurrences(of: " ", with: "")
        var result: [LibraryTrack] = []
        result.reserveCapacity(tracks.count)
        for index in tracks.indices where matches(at: index, normalized: normalized, compact: compact) {
            result.append(tracks[index])
        }
        return result
    }

    /// 单条曲目的匹配判定：三个原始字段任一命中，或标题/歌手的拼音形式任一命中。
    private func matches(at index: Int, normalized: String, compact: String) -> Bool {
        if titleKeys[index].contains(normalized)
            || artistKeys[index].contains(normalized)
            || albumKeys[index].contains(normalized) {
            return true
        }
        return titleInitials[index].contains(compact)
            || artistInitials[index].contains(compact)
            || titleLatin[index].contains(compact)
            || artistLatin[index].contains(compact)
    }
}

// MARK: - 搜索入口

/// 库内搜索的纯函数入口。
public enum LibrarySearchEngine {

    /// 查询串归一化：大小写 / 变音符 / 全半角折叠，压缩连续空白并去首尾空白。
    ///
    /// M2-T5 的聚合分组用的同一套规则（LibraryGrouping.normalize 直接转发到这里），
    /// 保证「搜索」与「聚合」对同一个歌手名不会一个认、一个不认。
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        return folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 一次性搜索：内部建索引再查。适合测试与小数据量调用方。
    /// UI 侧的重复查询应复用 `LibrarySearchIndex`，避免每次按键都重做拼音转换。
    public static func search(tracks: [LibraryTrack], query: String) -> [LibraryTrack] {
        LibrarySearchIndex(tracks: tracks).search(query)
    }

    /// 文本的拼音首字母（小写）。暴露给测试与调试，UI 不使用。
    public static func initials(of text: String) -> String {
        PinyinConverter.initials(text)
    }

    /// 文本的拼音连写（小写、无空格）。暴露给测试与调试，UI 不使用。
    public static func latin(of text: String) -> String {
        PinyinConverter.compactLatin(text)
    }
}
