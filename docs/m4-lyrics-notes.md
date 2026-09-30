# M4 歌词系统 —— 移植工作笔记

> 状态：**调研完成，尚未开始编码**（除本文档外 M4 无任何产出）。
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

## 2. 参考实现的文件清单与移植优先级

放在 `commonMain`，逐个对应到 Swift 文件（建议目标目录 `NeriPlayer/Core/Lyrics/`）。

**契约与模型层（先做，其余都依赖它）**

| Kotlin 文件 | 行数 | 说明 |
|---|---|---|
| `model/ISyncedLine.kt` | 7 | 最小接口：`start`/`end`/`duration`（**毫秒 Int**） |
| `model/synced/SyncedLine.kt` | 32 | 逐行歌词 + 翻译；`duration = max(end-start, 0)` 容错 |
| `model/karaoke/KaraokeLine.kt` | 105 | 密封接口 + `MainKaraokeLine` / `AccompanimentKaraokeLine`（双语对唱） |
| `model/karaoke/KaraokeSyllable.kt` | 24 | 逐字单元 + `progress(current:)` |
| `model/karaoke/KaraokeAlignment.kt` | 4 | `Start` / `End` / `Unspecified` |
| `model/karaoke/PhoneticLevel.kt` | 4 | `LINE` / `SYLLABLE` |
| `model/SyncedLyrics.kt` | 90 | 顶层容器 + **两个二分查找**（单行高亮 / 多行重叠高亮） |
| `model/Attributes.kt` / `Artist.kt` | 9 / 5 | 元数据 |
| `model/*/mapper/*.kt` | 46 | `SyncedLine ↔ KaraokeLine`、音节拼接 |
| `utils/TimeUtils.kt` | 68 | `parseAsTime()`（`MM:SS.ms` / `HH:MM:SS.ms`，毫秒位 1/2/3 位补零）与格式化 |
| `utils/LrcMetadataHelper.kt` | 95 | `[ar:]/[ti:]/[al:]/[offset:]/[length:]`；**`isCreditLine()`** 识别「作词 : X」这类制作信息行 |
| `utils/PhoneticProvider.kt` | 7 | 音译来源协议（`LINE`/`SYLLABLE` 两级） |
| `parser/ILyricsParser.kt` | 32 | `canParse(String)` + `parse(String/List<String>)` |

**解析器（M4-T1 的主体）**

| Kotlin 文件 | 行数 | 备注 |
|---|---|---|
| `parser/EnhancedLrcParser.kt` | 349 | 逐行 LRC + 增强（逐词 `<mm:ss.ms>`）+ 多行翻译 |
| `parser/TTMLParser.kt` | 343 | Apple TTML；依赖 `utils/SimpleXmlParser.kt`（148 行，需一并移植） |
| `parser/NeteaseYrcParser.kt` | 125 | 网易云 YRC（逐字） |
| `parser/AutoParser.kt` | 33 | 按顺序试各解析器；**默认列表含 TTML / YRC / LyricifySyllable / EnhancedLrc / KugouKrc** |

**暂不在 M4-T1 范围**（规划未列，且 KRC 是酷狗私有格式）：
`KugouKrcParser.kt`(201) + `KugouKrcMetadataDecoder.kt`(78) + `LyricifySyllableParser.kt`(96)。
→ AutoParser 的默认列表需要相应裁剪，或留 TODO 占位。

**导出器**（属 M4-T6，`exporter/` 共 ~255 行）：`LrcExporter` / `EnhancedLrcExporter` /
`TTMLExporter`。到时再移植。

## 3. 现成的 golden 测试样本（规划要求「用原仓库测试样本做 golden test」）

`src/commonTest/.../parser/` 下可直接改写成 XCTest：

- `EnhancedLrcParserTest.kt` —— 逐词/翻译的主样本
- `LrcParserTest.kt`、`CompressedTimestampTest.kt`（`[00:01.00][00:05.00]同一句` 这类压缩时间戳）
- `NeteaseYrcParserTest.kt`
- `TTMLParserTest.kt`
- `AutoParserTest.kt`（格式自动识别分流）
- `utils/TimeUtilsTest.kt`
- 另有 `LyricifySyllableParserTest.kt`、`KugouParserTest.kt`（不在本期范围）

## 4. 移植时要注意的语义细节（已从参考实现确认）

1. **时间单位一律是毫秒 `Int`**，不是秒/Double。与现有 `Track.duration: Double?`（秒）不同，
   转换要在边界处显式做，别混。
2. **容错优先于严格**：参考实现多处刻意钳制 `duration = max(end - start, 0)` 并注释说明
   「避免单行构造抛异常导致整份歌词失效」。但 `KaraokeSyllable` 仍有 `require(end >= start)`，
   `SyncedLine` 的构造（非 Unchecked 版）会抛 —— 移植时要么保留这个区分，要么统一为不抛。
3. **`UncheckedSyncedLine` 的存在是刻意的**：解析中途允许 end < start，最后 `toSyncedLine()`
   才收敛。TX 移植时建议保留同名类型以维持代码对照性。
4. **两处二分查找的返回值语义不同**：`getCurrentFirstHighlightLineIndexByTime` 在时间落在所有
   行之外时返回「紧随其后的行索引」或 `lines.size`；`getCurrentAllHighlightLineIndexIndicesByTime`
   返回所有重叠行（对唱场景）并已排序。这两条是最值得写边界单测的地方。
5. **`LrcMetadataHelper.isCreditLine()`** 是「过滤制作信息行」的关键，角色词表含简繁与英文两套；
   参考实现刻意避开 unicode 属性正则以兼容 KMP，Swift 侧可用 `Character.isWhitespace` 等价改写。
6. **`canParse` 的顺序敏感**：AutoParser 按列表顺序取第一个能解析的，TTML 在最前（它最容易被
   误判），所以顺序本身是逻辑的一部分，移植时不要重排。

## 5. 下一步（本轮结束时未开始）

1. 先落契约与模型层（第 2 节上半部分），配 `TimeUtilsTest` / `LrcMetadataHelperTest` golden 测试；
2. 再逐个移植三个解析器，每个都带参考样本的 golden test；
3. 最后接 `AutoParser` 分流 + 格式识别单测。
