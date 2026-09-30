// LyricsKugouKrcParserTests.swift
// NeriPlayer macOS —— M4-T1 酷狗 KRC 解析器的 golden 测试。
//
// 来源：accompanist-lyrics-core/src/commonTest/kotlin/com/mocharealm/accompanist/lyrics/core/parser/KugouParserTest.kt
// （2 条 @Test，逐条对应，期望值原样保留）：
//   testParseKugouKrcWithoutTranslation → testParseKugouKrcWithoutTranslation
//   testKugouKrcSpacing                 → testKugouKrcSpacing
//
// 素材：大样例（覆灭重生 Come Alive，111 行、含 `[language:…]` base64）与 AutoParser 的用例共用，
// 落在 Tests/Fixtures/Lyrics/kugou-come-alive.krc；小样例（绝世舞姬）体量不大，内联在用例里。
//
// 原库测试喂进来的都是**已解密的明文 KRC 文本**（不是二进制），`[language:…]` 那一行本身就是
// base64(JSON) 明文，所以不需要复刻 KRC 的解密链路就能覆盖全部解析逻辑。
//
// 标「（补充）」的是原库没有的用例（约定见 docs/m4-lyrics-notes.md §4），覆盖 golden case
// 碰不到的分支：头部译文的按行对齐、注音（type == 0）、`[bg:…]` 伴奏行、时间轴回退修正、
// `canParse` 的判定边界。

import XCTest
@testable import NeriPlayer

final class KugouKrcParserTests: XCTestCase {

    // MARK: - 测试素材

    /// 读取共享 KRC 样例（内容等于原库 `"""…""".trimIndent()`）。
    private func krcFixture(_ name: String = "kugou-come-alive") throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "krc", subdirectory: "Lyrics"),
            "缺少测试素材 \(name).krc"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 原库测试里的 `split("\n")` 行列表。文件末尾的换行会多带一个空元素，
    /// 解析器本来就跳过空行，不影响结果。
    private func krcFixtureLines(_ name: String = "kugou-come-alive") throws -> [String] {
        try krcFixture(name).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// fixture 里的 `[language:…]` 行。
    private func languageHeader(of krc: String) throws -> String {
        let line = try XCTUnwrap(
            krc.split(separator: "\n", omittingEmptySubsequences: false)
                .first { $0.hasPrefix(KugouKrcMetadataDecoder.languageTag) },
            "样例里没有 [language:…] 行"
        )
        return String(line)
    }

    /// 取第 index 行并要求它是音节对齐行（对应原库测试里的 `as KaraokeLine`）。
    ///
    /// 不用 `lines[index] as! KaraokeLine` 那套：下标越界或类型不符时判失败，
    /// 比抛异常崩掉整个测试进程更容易定位。
    private func karaokeLine(
        _ lines: [LyricsLine],
        at index: Int,
        file: StaticString = #filePath,
        line testLine: UInt = #line
    ) throws -> any KaraokeLine {
        guard lines.indices.contains(index) else {
            XCTFail("没有第 \(index) 行（共 \(lines.count) 行）", file: file, line: testLine)
            throw XCTSkip("行下标越界")
        }
        guard let karaoke = lines[index].karaokeLine else {
            XCTFail("第 \(index) 行不是音节对齐行", file: file, line: testLine)
            throw XCTSkip("行类型不符")
        }
        return karaoke
    }

    /// 取音节正文；同样不直接下标，越界时判失败而不是崩进程。
    private func syllableContent(
        of line: any KaraokeLine,
        at index: Int,
        file: StaticString = #filePath,
        line testLine: UInt = #line
    ) throws -> String {
        guard line.syllables.indices.contains(index) else {
            XCTFail("音节下标 \(index) 越界（共 \(line.syllables.count) 个）", file: file, line: testLine)
            throw XCTSkip("音节下标越界")
        }
        return line.syllables[index].content
    }

    /// 取第 index 条译文并去空白；越界返回 nil（断言照常判失败，不会崩进程）。
    private func trimmedTranslation(
        of metadata: KugouKrcMetadataDecoder.Metadata,
        at index: Int
    ) -> String? {
        metadata.translations.indices.contains(index) ? metadata.translations[index].trimmed : nil
    }

    // MARK: - 原库 KugouParserTest.kt 的两条 golden case

    func testParseKugouKrcWithoutTranslation() throws {
        let result = KugouKrcParser().parse(try krcFixtureLines())

        // 验证解析出的行数 (100行主歌词和翻译)
        XCTAssertEqual(result.lines.count, 100)

        // 行按时间排序
        let nineLine = try karaokeLine(result.lines, at: 8)
        let tenLine = try karaokeLine(result.lines, at: 9)
        let jiuShiJiuLine = try karaokeLine(result.lines, at: 99)

        // 验证第九行翻译
        XCTAssertEqual(nineLine.translation?.trimmed, "还能")

        // 验证第十行翻译
        XCTAssertEqual(tenLine.translation?.trimmed, "抵抗多久？")

        // 验证第九行是否解析正确
        XCTAssertEqual(try syllableContent(of: nineLine, at: 0), "How ")

        // 验证第十行是否解析正确
        XCTAssertEqual(try syllableContent(of: tenLine, at: 0), "Can ")

        // 验证九十九行翻译
        XCTAssertEqual(jiuShiJiuLine.translation?.trimmed, "我们终将走出迷惘")

        // 验证九十九行第三个
        XCTAssertEqual(try syllableContent(of: jiuShiJiuLine, at: 2), "make ")
    }

    func testKugouKrcSpacing() throws {
        // KRC 数据行本身有几百字符，折行就等于改了 golden 素材，故这一段放行 line_length。
        // swiftlint:disable line_length
        let krc = """
            [ti:绝世舞姬]
            [ar:张晓涵/戚琦/戚琦]
            [al:绝世舞姬]
            [by:]
            [offset:0]
            [0,880]<0,67,0>绝<67,68,0>世<135,68,0>舞<203,67,0>姬<270,68,0> <338,68,0>-<406,67,0> <473,68,0>张<541,68,0>曦<609,67,0>匀<676,68,0>/<744,68,0>戚<812,68,0>琦
            [882,882]<0,147,0>词<147,147,0>：<294,147,0>清<441,147,0>玄<588,147,0>小<735,147,0>仙
            [1764,882]<0,176,0>曲<176,176,0>：<352,176,0>房<528,176,0>雪<704,176,0>娇
            [2646,882]<0,110,0>Rap<110,110,0>编<220,110,0>写<330,110,0> <440,110,0>Rap <550,110,0>Arrangement：<660,110,0>顾<770,110,0>雄
            [3528,882]<0,147,0>编<147,147,0>曲<294,147,0> <441,147,0>Arranger：<588,147,0>甘<735,147,0>虎
            [4410,882]<0,80,0>制<80,80,0>作<160,80,0>人<240,80,0> <320,80,0>Producer：<400,80,0>顾<480,80,0>雄<560,80,0>/<640,80,0>胡<720,80,0>小<800,80,0>健
            [5292,882]<0,98,0>和<98,98,0>声<196,98,0>编<294,98,0>写<392,98,0> <490,98,0>Harmony <588,98,0>Arrangement：<686,98,0>曾<784,98,0>婕
            [6174,882]<0,88,0>和<88,88,0>声<176,88,0> <264,88,0>Harmony <352,88,0>Vocals：<440,88,0>曾<528,88,0>婕<616,88,0>/<704,88,0>顾<792,88,0>雄
            [7056,882]<0,73,0>人<73,73,0>声<146,73,0>录<219,73,0>音<292,73,0>工<365,73,0>程<438,73,0>师<511,73,0> <584,73,0>Recording <657,73,0>Engineer：<730,73,0>顾<803,73,0>雄
            [7938,882]<0,51,0>人<51,51,0>声<102,51,0>录<153,51,0>音<204,51,0>室<255,51,0> <306,51,0>Vocal <357,51,0>Recording <408,51,0>Studio：<459,51,0>华<510,51,0>音<561,51,0>·<612,51,0>鼎<663,51,0>天<714,51,0>录<765,51,0>音<816,51,0>棚
            [8820,882]<0,88,0>混<88,88,0>音<176,88,0>工<264,88,0>程<352,88,0>师<440,88,0> <528,88,0>Mixing <616,88,0>Engineer：<704,88,0>顾<792,88,0>雄
            [9702,882]<0,98,0>母<98,98,0>带<196,98,0>工<294,98,0>程<392,98,0>师<490,98,0> <588,98,0>Mastering：<686,98,0>顾<784,98,0>雄
            [10584,882]<0,98,0>封<98,98,0>面<196,98,0>设<294,98,0>计<392,98,0> <490,98,0>Cover <588,98,0>Design：<686,98,0>路<784,98,0>畅
            [11466,882]<0,110,0>出<110,110,0>品<220,110,0>人<330,110,0> <440,110,0>Publisher：<550,110,0>胡<660,110,0>小<770,110,0>健
            [12348,882]<0,294,0>戚<294,294,0>琦<588,294,0>：
            [13230,2249]<0,448,0>绝<448,456,0>世<904,320,0>舞<1224,1025,0>姬
            [15479,3616]<0,623,0>天<623,824,0>下<1447,2169,0>先
            [19686,4220]<0,224,0>张<224,192,0>晓<416,328,0>涵<744,3476,0>：
            [23906,2439]<0,223,0>烽<223,200,0>烟<423,224,0>燃<647,448,0>起<1075,0,0> <1095,264,0>乱<1359,248,0>风<1607,832,0>华
            [26673,2368]<0,184,0>胭<184,184,0>脂<368,177,0>落<545,335,0>泪<860,0,0> <880,192,0>染<1072,343,0>红<1415,953,0>霞
            [29321,2368]<0,193,0>眉<193,167,0>目<360,200,0>如<560,488,0>画<1028,0,0> <1048,207,0>宜<1255,240,0>其<1495,289,0>室<1784,584,0>家
            [31689,2672]<0,200,0>说<200,152,0>陪<352,168,0>我<520,192,0>浪<712,175,0>迹<887,241,0>天<1128,224,0>涯<1332,0,0> <1352,208,0>都<1560,208,0>作<1768,904,0>假
            [34594,2463]<0,215,0>心<215,168,0>死<383,192,0>就<575,312,0>在<867,0,0> <887,231,0>那<1118,305,0>一<1423,1040,0>刹
            [37329,2528]<0,192,0>世<192,247,0>间<439,200,0>安<639,209,0>得<828,0,0> <848,208,0>双<1056,312,0>全<1368,1160,0>法
            [39857,2469]<0,304,0>眸<304,248,0>中<552,280,0>无<832,376,0>他<1188,0,0> <1208,200,0>便<1408,224,0>无<1632,366,0>冬<1998,471,0>夏
            [42326,712]<0,192,0>君<192,184,0>临<376,137,0>天<513,199,0>下
            [43038,1978]<0,177,0>也<177,144,0>只<321,177,0>能<498,279,0>道<777,200,0>一<977,208,0>声<1165,0,0> <1185,793,0>寡
            [45263,2552]<0,224,0>若<224,344,0>我<568,248,0>一<816,248,0>舞<1064,208,0>断<1272,288,0>杀<1560,992,0>伐
            [47815,2768]<0,224,0>兵<224,193,0>临<417,199,0>城<616,336,0>下<952,216,0>万<1168,376,0>箭<1544,1224,0>发
            [50583,2019]<0,193,0>若<193,175,0>我<368,168,0>一<536,288,0>舞<824,256,0>定<1080,540,0>天<1620,399,0>下
            [52602,4106]<0,184,0>在<184,208,0>你<392,281,0>方<673,303,0>寸<976,208,0>棋<1184,393,0>盘<1577,440,0>倒<2017,305,0>也<2322,1784,0>罢
            [57172,3796]<0,208,0>戚<208,208,0>琦<416,3380,0>：
            [60968,2559]<0,329,0>美<329,239,0>人<568,199,0>舞<767,256,0>如<1023,265,0>莲<1288,711,0>花<1999,560,0>旋
            [63527,2710]<0,208,0>世<208,343,0>人<551,224,0>见<775,583,0>之<1358,329,0>惊<1687,231,0>且<1918,792,0>叹
            [66237,2368]<0,376,0>一<376,248,0>曲<624,225,0>终<849,439,0>了<1288,329,0>与<1617,207,0>君<1824,544,0>断
            [68605,2896]<0,218,0>绝<218,206,0>世<424,256,0>舞<680,280,0>姬<960,256,0>天<1216,288,0>下<1504,1392,0>先
            [71749,2369]<0,224,0>美<224,224,0>人<448,249,0>舞<697,351,0>如<1048,257,0>清<1305,327,0>泉<1632,737,0>涧
            [74118,2847]<0,327,0>世<327,384,0>人<711,208,0>见<919,400,0>之<1319,208,0>惊<1527,305,0>且<1832,1015,0>叹
            [76965,2464]<0,344,0>剪<344,248,0>不<592,248,0>断<840,416,0>的<1256,200,0>理<1456,304,0>还<1760,704,0>乱
            [79429,2736]<0,216,0>绝<216,193,0>世<409,223,0>舞<632,312,0>姬<944,176,0>天<1120,288,0>下<1408,1328,0>先
            [82461,10608]<0,200,0>张<200,184,0>晓<384,10224,0>涵<10608,0,0>：
            [93069,3016]<0,384,0>烽<384,384,0>烟<768,232,0>燃<1000,368,0>起<1348,0,0> <1368,208,0>乱<1576,216,0>风<1792,1224,0>华
            [96085,2441]<0,216,0>胭<216,216,0>脂<432,242,0>落<674,262,0>泪<916,0,0> <936,224,0>染<1160,288,0>红<1448,993,0>霞
            [98749,2272]<0,184,0>眉<184,184,0>目<368,208,0>如<576,456,0>画<1012,0,0> <1032,200,0>宜<1232,216,0>其<1448,440,0>室<1888,384,0>家
            [101021,2728]<0,168,0>说<168,160,0>陪<328,168,0>我<496,184,0>浪<680,200,0>迹<880,168,0>天<1048,248,0>涯<1276,0,0> <1296,184,0>都<1480,225,0>作<1705,1023,0>假
            [103957,2528]<0,192,0>若<192,176,0>我<368,232,0>一<600,297,0>舞<897,167,0>断<1064,320,0>杀<1384,1144,0>伐
            [106485,2703]<0,248,0>兵<248,184,0>临<432,218,0>城<650,334,0>下<984,256,0>万<1240,438,0>箭<1678,1025,0>发
            [109188,2127]<0,223,0>若<223,184,0>我<407,200,0>一<607,352,0>舞<959,455,0>定<1414,376,0>天<1790,337,0>下
            [111315,1574]<0,183,0>在<183,216,0>你<399,232,0>方<631,272,0>寸<903,199,0>棋<1102,472,0>盘
            [112889,3537]<0,249,0>倒<249,615,0>也<864,2673,0>罢
            [116641,545]<0,200,0>戚<200,345,0>琦<545,0,0>：
            [117186,2488]<0,215,0>美<215,241,0>人<456,256,0>舞<712,287,0>如<999,208,0>莲<1207,353,0>花<1560,928,0>旋
            [119674,2583]<0,320,0>世<320,223,0>人<543,257,0>见<800,367,0>之<1167,161,0>惊<1328,376,0>且<1704,879,0>叹
            [122257,2280]<0,369,0>一<369,224,0>曲<593,265,0>终<858,383,0>了<1241,192,0>与<1433,368,0>君<1801,479,0>断
            [124537,3057]<0,192,0>绝<192,200,0>世<392,192,0>舞<584,377,0>姬<961,288,0>天<1249,336,0>下<1585,1472,0>先
            [127594,2832]<0,416,0>美<416,184,0>人<600,312,0>舞<912,407,0>如<1319,377,0>清<1696,327,0>泉<2023,809,0>涧
            [130426,2496]<0,296,0>世<296,232,0>人<528,303,0>见<831,288,0>之<1119,177,0>惊<1296,328,0>且<1624,872,0>叹
            [132922,2417]<0,392,0>剪<392,352,0>不<744,280,0>断<1024,344,0>的<1368,215,0>理<1583,506,0>还<2089,328,0>乱
            [135339,2157]<0,168,0>绝<168,168,0>世<336,176,0>舞<512,424,0>姬<936,184,0>天<1120,452,0>下<1572,585,0>先
            [137496,439]<0,160,0>张<160,135,0>晓<295,144,0>涵<439,0,0>：
            [137935,1370]<0,144,0>烽<144,153,0>烟<277,0,0> <297,160,0>燃<457,240,0>起<697,247,0>了<944,144,0>风<1088,282,0>华
            [139305,1215]<0,158,0>胭<158,144,0>脂<282,0,0> <302,161,0>染<463,160,0>泪<623,168,0>染<791,184,0>红<975,240,0>霞
            [140520,1416]<0,160,0>眉<160,160,0>目<320,152,0>如<472,223,0>画<675,0,0> <695,177,0>宜<872,160,0>其<1032,159,0>室<1191,225,0>家
            [141936,1231]<0,175,0>我<175,137,0>陪<312,169,0>你<481,151,0>浪<632,160,0>迹<792,168,0>天<960,271,0>涯
            [143167,1176]<0,176,0>心<176,169,0>死<345,159,0>在<504,169,0>一<673,207,0>刹<880,296,0>那
            [144343,1392]<0,177,0>世<177,176,0>间<353,167,0>安<520,192,0>得<712,184,0>双<896,168,0>全<1064,328,0>法
            [145735,736]<0,168,0>眸<168,152,0>中<320,176,0>无<496,240,0>他
            [146471,776]<0,217,0>君<217,167,0>临<384,169,0>天<553,223,0>下
            [147247,1577]<0,176,0>只<176,184,0>能<360,160,0>道<520,168,0>一<688,184,0>声<872,705,0>寡
            [148824,503]<0,208,0>血<208,295,0>溅
            [149327,2464]<0,169,0>尸<169,184,0>骸<353,200,0>踏<553,239,0>燃<792,234,0>起<1026,278,0>风<1304,1160,0>沙
            [151791,2477]<0,296,0>兵<296,200,0>临<496,184,0>城<680,240,0>下<920,200,0>万<1120,517,0>箭<1637,840,0>发
            [154268,2288]<0,360,0>三<360,192,0>千<552,240,0>鸦<792,423,0>杀<1195,0,0> <1215,192,0>它<1407,185,0>终<1592,176,0>是<1768,193,0>虚<1961,327,0>话
            [156556,840]<0,192,0>绝<192,168,0>世<360,176,0>舞<536,304,0>姬
            [157396,1897]<0,216,0>此<216,249,0>生<465,271,0>已<736,224,0>了<960,232,0>无<1192,200,0>牵<1392,505,0>挂
            [159293,335]<0,175,0>戚<175,160,0>琦<335,0,0>：
            [159628,2608]<0,232,0>美<232,176,0>人<408,256,0>舞<664,376,0>如<1040,224,0>莲<1264,417,0>花<1681,927,0>旋
            [162236,2528]<0,248,0>世<248,384,0>人<632,194,0>见<826,390,0>之<1216,240,0>惊<1456,545,0>且<2001,527,0>叹
            [164764,2337]<0,353,0>一<353,368,0>曲<721,192,0>终<913,360,0>了<1273,272,0>与<1545,256,0>君<1801,536,0>断
            [167101,3008]<0,199,0>绝<199,210,0>世<409,223,0>舞<632,313,0>姬<945,207,0>天<1152,360,0>下<1512,1496,0>先
            [170341,2395]<0,192,0>美<192,403,0>人<595,200,0>舞<795,224,0>如<1019,265,0>清<1284,295,0>泉<1579,816,0>涧
            [172736,2616]<0,296,0>世<296,305,0>人<601,231,0>见<832,424,0>之<1256,281,0>惊<1537,368,0>且<1905,711,0>叹
            [175352,2529]<0,305,0>剪<305,288,0>不<593,232,0>断<825,271,0>的<1096,408,0>理<1504,489,0>还<1993,536,0>乱
            [177881,3519]<0,232,0>绝<232,183,0>世<415,185,0>舞<600,312,0>姬<912,176,0>天<1088,296,0>下<1384,2135,0>先
            """
        // swiftlint:enable line_length
        let result = KugouKrcParser().parse(krc)
        // 验证解析出的行数 (84行主歌词)
        XCTAssertEqual(result.lines.count, 84)

        let shiWuLine = try karaokeLine(result.lines, at: 14)
        let shiBaiLine = try karaokeLine(result.lines, at: 17)

        // Validate KaraokeAlignment
        XCTAssertEqual(shiWuLine.alignment, KaraokeAlignment.end)
        XCTAssertEqual(shiBaiLine.alignment, KaraokeAlignment.start)
    }

    // MARK: - （补充）头部元数据

    /// （补充）`[language:…]` 里 type == 1 的译文按行号对齐：fixture 实测 100 条译文，
    /// 下标 8/9/99 与正文第 9/10/100 行一一对应。
    ///
    /// 这也解释了译文为什么能直接挂到行上：解码层保留全部 100 个槽位（含 `" "` 占位），
    /// 由解析层判空丢弃，下标不会因为空行错位。
    func testDecodeLanguageHeaderTranslations() throws {
        let metadata = KugouKrcMetadataDecoder.decode(try languageHeader(of: try krcFixture()))

        XCTAssertEqual(metadata.translations.count, 100)
        XCTAssertEqual(trimmedTranslation(of: metadata, at: 8), "还能")
        XCTAssertEqual(trimmedTranslation(of: metadata, at: 9), "抵抗多久？")
        XCTAssertEqual(trimmedTranslation(of: metadata, at: 99), "我们终将走出迷惘")
        // 这份样例只有 type == 1，没有注音
        XCTAssertTrue(metadata.phonetics.isEmpty)
    }

    /// （补充）type == 0 的注音：先按「行 → 音节」两层拼串，再按行号对齐注入音节。
    /// golden case 用的样例里没有 type == 0，这条把这条链路补上。
    func testDecodePhoneticsAndInjectIntoSyllables() throws {
        let json = #"{"content":[{"type":1,"lyricContent":[["译文一"],["译文二"]]},"#
            + #"{"type":0,"lyricContent":[[["ni"],["hao"]],[["zai"],["jian"]]]}],"version":1}"#
        let header = KugouKrcMetadataDecoder.languageTag + Data(json.utf8).base64EncodedString() + "]"

        let result = KugouKrcParser().parse([
            header,
            "[0,1000]<0,500,0>你<500,500,0>好",
            "[1000,1000]<0,500,0>再<500,500,0>见"
        ])

        XCTAssertEqual(result.lines.count, 2)

        let firstLine = try karaokeLine(result.lines, at: 0)
        XCTAssertEqual(firstLine.syllables.map(\.content), ["你", "好"])
        XCTAssertEqual(firstLine.syllables.map { $0.phonetic ?? "" }, ["ni", "hao"])
        XCTAssertEqual(firstLine.translation, "译文一")

        let secondLine = try karaokeLine(result.lines, at: 1)
        XCTAssertEqual(secondLine.syllables.map { $0.phonetic ?? "" }, ["zai", "jian"])
        XCTAssertEqual(secondLine.translation, "译文二")
    }

    /// （补充）注音个数与音节个数不等时一个都不注入：宁可没注音，也不能让注音与字错配。
    func testPhoneticsAreSkippedWhenSyllableCountsDiffer() throws {
        let json = #"{"content":[{"type":0,"lyricContent":[[["ni"],["hao"],["ma"]]]}]}"#
        let header = KugouKrcMetadataDecoder.languageTag + Data(json.utf8).base64EncodedString() + "]"

        // 这一行只有 2 个音节，注音却给了 3 个
        let result = KugouKrcParser().parse([
            header,
            "[0,1000]<0,500,0>你<500,500,0>好"
        ])

        let line = try karaokeLine(result.lines, at: 0)
        XCTAssertEqual(line.syllables.map { $0.phonetic ?? "" }, ["", ""])
    }

    /// （补充）头部坏掉（nil / 空白 / 不是 base64 / base64 里不是 JSON）时落回空元数据，
    /// 正文照常解析 —— 元数据坏了不该让整首歌没歌词。
    func testMalformedLanguageHeaderFallsBackToNoMetadata() throws {
        XCTAssertEqual(KugouKrcMetadataDecoder.decode(nil), KugouKrcMetadataDecoder.Metadata())
        XCTAssertEqual(KugouKrcMetadataDecoder.decode("   "), KugouKrcMetadataDecoder.Metadata())

        let notBase64 = "[language:这不是 base64!!]"
        let notJson = KugouKrcMetadataDecoder.languageTag
            + Data("hello".utf8).base64EncodedString() + "]"

        for header in [notBase64, notJson] {
            XCTAssertEqual(KugouKrcMetadataDecoder.decode(header), KugouKrcMetadataDecoder.Metadata())

            let result = KugouKrcParser().parse([
                header,
                "[0,1000]<0,500,0>你<500,500,0>好"
            ])
            XCTAssertEqual(result.lines.count, 1)
            XCTAssertNil(result.lines[0].translation)
        }
    }

    // MARK: - （补充）伴奏行与时间轴修正

    /// （补充）`[bg:…]` 行是伴奏/和声：
    ///   - 前一条是主唱行时挂到它的 `accompanimentLines` 上（不单独占一行）；
    ///   - 前面还没有主唱行时自成一条伴奏行。
    func testBackgroundLineIsAttachedToPreviousMainLine() throws {
        let result = KugouKrcParser().parse([
            "[bg:<0,500,0>前<500,500,0>奏]",
            "[0,1000]<0,500,0>主<500,500,0>唱",
            "[bg:<2000,500,0>和<2500,500,0>声]",
            "[1000,1000]<0,500,0>再<500,500,0>见"
        ])

        // 前奏行成了独立的一行；和声行挂到了主唱行上，所以总共 3 行
        XCTAssertEqual(result.lines.count, 3)

        guard case .accompaniment(let prelude) = result.lines[0] else {
            XCTFail("第 0 行应当是伴奏行")
            return
        }
        XCTAssertEqual(prelude.syllables.map(\.content), ["前", "奏"])
        XCTAssertEqual(prelude.alignment, KaraokeAlignment.unspecified)
        XCTAssertNil(prelude.translation)

        guard case .main(let mainLine) = result.lines[1] else {
            XCTFail("第 1 行应当是主唱行")
            return
        }
        XCTAssertEqual(mainLine.syllables.map(\.content), ["主", "唱"])
        XCTAssertEqual(mainLine.accompanimentLines?.count, 1)
        XCTAssertEqual(mainLine.accompanimentLines?.first?.syllables.map(\.content), ["和", "声"])
        XCTAssertEqual(mainLine.accompanimentLines?.first?.start, 2000)
        XCTAssertEqual(mainLine.accompanimentLines?.first?.end, 3000)

        guard case .main(let lastLine) = result.lines[2] else {
            XCTFail("第 2 行应当是主唱行")
            return
        }
        XCTAssertNil(lastLine.accompanimentLines)
    }

    /// （补充）行起点不前进时被推到「上一行 +3ms」（原库用 `<=`，所以与上一行相等也推）。
    func testNonIncreasingLineStartIsPushedForward() throws {
        let result = KugouKrcParser().parse([
            "[1000,500]<0,100,0>甲",
            "[999,500]<0,100,0>乙",
            "[1000,500]<0,100,0>丙"
        ])

        XCTAssertEqual(result.lines.count, 3)
        XCTAssertEqual(result.lines[0].start, 1000)
        XCTAssertEqual(result.lines[0].end, 1100)
        XCTAssertEqual(result.lines[1].start, 1003)
        XCTAssertEqual(result.lines[1].end, 1103)
        XCTAssertEqual(result.lines[2].start, 1006)
    }

    // MARK: - （补充）格式识别

    /// （补充）`canParse`：同一行要同时有行时间戳和一个「后面还有字」的逐字标签。
    ///
    /// 最后两条钉住 `.{1}` 这个条件：只有时间戳、标签后面没内容，都不算 KRC。
    func testCanParseDistinguishesKrcFromLrc() throws {
        XCTAssertTrue(KugouKrcParser().canParse(try krcFixture()))
        XCTAssertFalse(KugouKrcParser().canParse("[00:01.00]普通 LRC"))
        XCTAssertFalse(KugouKrcParser().canParse("[0,728]只有行时间戳"))
        // EnhancedLRC 的逐字标签用冒号，不会命中 KRC 的 `<数字,数字,数字>`
        XCTAssertFalse(KugouKrcParser().canParse("[00:01.00]<00:01.00>逐词"))
        XCTAssertFalse(KugouKrcParser().canParse("[0,728]<0,60,0>"))
    }
}

private extension String {

    /// 原库测试里的 `.trim()`。
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
