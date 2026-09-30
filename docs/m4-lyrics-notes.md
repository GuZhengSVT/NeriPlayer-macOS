# M4 歌词系统 —— 移植工作笔记

> 状态：M4-T1–T6 实现已落地；最终测试与人工截图验收见 `docs/acceptance/m4.md`。
> 2026-09-30 审查补充见 [审查记录](code-review-2026-09-30.md)：修复整数溢出、XML 实体/混合内容顺序、翻译转义等；本轮补齐歌词来源、播放绑定、SwiftUI 界面、逐字高亮与 PNG 导出。
> 参考实现：`/Volumes/taurus/Document/Code/NeriPlayer/np-submodule/accompanist-lyrics-core`
> （Kotlin Multiplatform，`src/commonMain` 共约 2156 行，纯逻辑、无平台依赖，可逐文件平移）

## 1. 任务范围（摘自移植规划.md 的 M4）

| 编号 | 任务 | 边界 |
|---|---|---|
| M4-T1 | 解析器移植：LRC（逐行 + 逐词/逐字）、翻译/音译多行、YRC、TTML | 纯解析，不涉及 UI |
| M4-T2 | 歌词来源：本地同名 `.lrc`/`.txt` + 网易云歌词接口（M5 前仅此一个） | 不做其他平台 |
| M4-T3 | `LyricsModel` 与播放进度绑定：当前行/当前字 + 偏移设置 | 不做动画 |
| M4-T4 | SwiftUI 渲染 v1：逐行滚动高亮、点击跳转、字号/模糊设置、边缘渐隐 | 不做逐字动画、景深 |
| M4-T5 | 逐字时间戳动画（karaoke 高亮） | 不做全屏歌词 |
| M4-T6 | 歌词卡片导出（PNG，对齐原版 1080px 规格） | — |

## 2. 文件对照表（Kotlin → Swift，全部落在 `NeriPlayer/Core/Lyrics/`）

**契约与模型层（已完成）**

| Kotlin | Swift | 说明 |
|---|---|---|
| `model/ISyncedLine.kt` | `LyricsModel.swift` 的 `LyricsTimedLine` | `start`/`end`/`duration`，毫秒 `Int` |
| `model/synced/SyncedLine.kt` | `LyricsModel.swift` 的 `SyncedLine` | 逐行歌词 + 翻译 |
| `model/karaoke/KaraokeLine.kt` | `KaraokeModel.swift` | `KaraokeLine` 协议 + `MainKaraokeLine` / `AccompanimentKaraokeLine` |
| `model/karaoke/KaraokeSyllable.kt` | `KaraokeModel.swift` | 逐字单元 + `progress(current:)` |
| `model/karaoke/KaraokeAlignment.kt` / `PhoneticLevel.kt` | `KaraokeModel.swift` | 枚举 |
| `model/SyncedLyrics.kt` | `LyricsModel.swift` | 顶层容器 + 两个二分查找 |
| `model/Attributes.kt` / `Artist.kt` | `LyricsModel.swift` | 元数据 |
| `model/*/mapper/*.kt` | `KaraokeModel.swift` | `toSyncedLine()` / `toKaraokeLine()` / `joinedContent` / `joinedPhonetic` |
| `utils/TimeUtils.kt` | `LyricsTimeUtils.swift` | `LyricsTime.parseAsTime(_:)` / `LyricsTime.formatted(_:)` |
| `utils/LrcMetadataHelper.kt` | `LrcMetadataHelper.swift` | 头部标签 + `isCreditLine` |
| `utils/PhoneticProvider.kt` + `parser/ILyricsParser.kt` | `LyricsParser.swift` | 两个协议 |
| `parser/EnhancedLrcParser.kt` | `EnhancedLrcParser.swift` | 逐行 + 逐词 + `[bg:]` + 压缩时间戳 |
| `parser/TTMLParser.kt` + `utils/SimpleXmlParser.kt` | `TTMLParser.swift` / `SimpleXmlParser.swift` | Apple TTML |
| `parser/NeteaseYrcParser.kt` | `NeteaseYrcParser.swift` | 网易云 YRC |
| `parser/LyricifySyllableParser.kt` | `LyricifySyllableParser.swift` | Lyricify `.syl` |
| `parser/KugouKrcParser.kt` + `utils/KugouKrcMetadataDecoder.kt` | `KugouKrcParser.swift` (+ decoder) | 酷狗 KRC |
| `parser/AutoParser.kt` | `AutoParser.swift` | 按顺序取第一个 `canParse` 的解析器 |
| `exporter/ILyricsExporter.kt` + `LrcExporter.kt` + `EnhancedLrcExporter.kt` | `LyricsExporter.swift` / `EnhancedLrcExporter.swift` | 往返测试需要，顺带落地 |
| `exporter/TTMLExporter.kt` | `TTMLExporter.swift` | 同上 |

范围说明：原笔记把 Kugou/Lyricify/导出器列为"暂不移植"，实际开工后改为**全部移植**，理由是
`AutoParser` 的默认解析器列表里就含这两个格式，留空会让"格式自动识别"这条链路出现说不清的
缺口；导出器则被 `LrcParserTest` 的往返用例和 M4-T6 同时需要。代价是 T1 的体量比原规划大，
因此 T1 拆成"契约层"（已提交）与"解析器层"两步走。

## 3. 落地时确定的实现约定（与 Kotlin 的差异都在这里）

1. **`List<ISyncedLine>` → `LyricsLine` 枚举**（`.synced` / `.main` / `.accompaniment`）。
   原库用 sealed interface + 到处 `when (line) { is KaraokeLine -> …; is SyncedLine -> … }`，
   其中还夹着 `else -> ""` 兜底分支。Swift 用枚举后 switch 必须穷尽，兜底分支在编译期消失，
   渲染端（T4/T5）也能直接取音节数组。
2. **`UncheckedSyncedLine` 保留为兼容模型**：当前源码与测试已有此类型，但不进入
   `LyricsLine` 联合类型，解析和渲染以 `.synced` / `.main` / `.accompaniment` 为准。
3. **`KaraokeSyllable` 的 `require(end >= start)` 改成钳制**：原库坏数据会抛异常中断整份解析。
   解析器已经在能修的地方修（`rearrangeTime()`），修不了的地方也不该让整首歌没歌词。
   连带后果：`duration == 0` 时 `progress` 不能照抄除法（会 NaN），判定为"已走完"返回 1。
4. **`LyricsLine.progress(current:)` / `isFocused(current:)` 是新增 API**（原库 `SyncedLine`
   自己没有 progress）。T4 的逐行高亮需要统一入口，算法与卡拉OK 行一致；已在单测里钉住。
5. **时间工具收进 `LyricsTime` 命名空间**，不做 `String`/`Int` 的全局扩展（原库是扩展函数），
   避免给全工程的 `String` 加容易撞名的方法。
6. **解析器是无状态 `struct`**（原库是 Kotlin `object`）：协议要的是实例方法，`AutoParser`
   又要把解析器当值放进列表。调用点从 `EnhancedLrcParser.parse(x)` 变成
   `EnhancedLrcParser().parse(x)`。
7. **正则用 Swift 原生 regex 字面量** `#/pattern/#` + `wholeMatch(of:)`（≈`matchEntire`）/
   `firstMatch(of:)`（≈`find`）/`matches(of:)`（≈`findAll`），捕获组走 `match.output.1`。
   只有必须运行时拼接的 pattern 才用 `NSRegularExpression`。
8. **`String.isDigitsOnly()` 没有单独移植**：它只被 `LyricifySyllableParser` 使用，实现放在
   该解析器自己的文件里。注意它是 Kotlin `Char.isDigit()`，即 **Unicode 语义**
   （阿拉伯-印度数字也算数字），不能写成 `"0"..."9"` 的 ASCII 区间判断。
9. **`attributes` 的 `offset`/`length` 缺失时落 0**（原库 `?: 0`），不是 nil；`artists` 默认
   空数组而不是 nil。两处都是原库行为，容易被"顺手改成可选"。
10. **`for (i in n downTo 0)` 在 `n < 0` 时是空循环**：Swift 用 `while` 复刻时注意别写出
    负数下标（第二处二分查找里 `firstAfterIndex == 0` 就是这种情况）。

## 4. golden 测试的落点

| 原库测试 | Swift 测试 |
|---|---|
| `utils/TimeUtilsTest.kt`（7 条） | `Tests/LyricsModelTests.swift`（`LyricsTimeTests`） |
| （原库没有）元数据/模型/二分查找 | `Tests/LyricsModelTests.swift` |
| `parser/EnhancedLrcParserTest.kt` / `LrcParserTest.kt` / `CompressedTimestampTest.kt` | `Tests/LyricsEnhancedLrcTests.swift` |
| `parser/TTMLParserTest.kt` / `exporter/TTMLExporterTest.kt` | `Tests/LyricsTTMLParserTests.swift` |
| `parser/NeteaseYrcParserTest.kt` | `Tests/LyricsNeteaseYrcParserTests.swift` |
| `parser/LyricifySyllableParserTest.kt` | `Tests/LyricsLyricifySyllableParserTests.swift` |
| `parser/KugouParserTest.kt` | `Tests/LyricsKugouKrcParserTests.swift` |
| `parser/AutoParserTest.kt` | `Tests/LyricsAutoParserTests.swift`（格式分流） |

补充用例（原库没有的）在测试里都标了"（补充）"，方便和原库对照复查。

## 5. 还没做的（留给后续任务）

1. **在线歌曲播放与登录**属于 M5；M4 已接独立 URLSession 网易云歌词接口，只对显式关联 ID 请求。
2. **`PhoneticProvider` 的两个自动生成实现**（日文假名 / 中文拼音）不在本子模块中，M4 只落协议；
   TTML / KRC / 网易云现有音译可以直接显示，不会自行生成不存在的音译。
3. **硬件与性能专项人工验收**：Instruments 60fps 与真实发布包沙盒尚未证实，窗口截图与逻辑测试不是性能证明。

## 6. 审查后的约束

- Swift 整数不会像 Kotlin Long 一样默认回绕；外部时间戳使用饱和算术，避免溢出 trap。
- XML 实体只解码一次；保留文本与 span 的文档顺序，翻译导出必须转义。
- 当前为宽容解析器，不是完整 TTML/XML 实现；CDATA、完整命名空间与嵌套深度限制尚待完善。
- LRC offset 保留在 `LyricsDocument`，`LyricsViewModel.totalOffset` 只组合一次文件与用户偏移；时间轴正偏移提前、点击跳转反向扣除。
- 生产播放绑定使用新 `LyricsTimeline`，区间树覆盖嵌套长行；原模型历史二分 API 保留但不用于新 UI。
- 文本格式导出时音译/顶层伴唱/对齐信息完整性仍需后续专项用例；PNG 卡片导出聚焦选中正文和可选译文。

## 7. M4-T2–T6 落点

- `LyricsProvider.swift`：本地 sidecar、纯文本、网易云歌词、翻译与音译合并；不更改音频扫描逻辑。
- `LyricsTimeline.swift`：预索引时间轴与音节进度，毫秒/秒饱和换算。
- `LyricsViewModel.swift`：播放快照适配、异步请求取消及 generation 防旧响应、按文件地址存关联与偏移。
- `LyricsView.swift` / `KaraokeText.swift`：SwiftUI 滚动、原生 TextKit 字形排版与音节裁切，渲染最多补间 300ms 后等待播放器进度，不盲目累计计时。
- `LyricsPreferencesView.swift`：字号、模糊、翻译、音译、偏移和网易云歌曲 ID。
- `LyricsShareView.swift` / `LyricsCardExporter.swift`：选择 1–6 行、1080px 位图预览、保存和复制；资源上限防超长输入分配过大图像。
- 测试与截图见 [M4 验收](acceptance/m4.md)。
