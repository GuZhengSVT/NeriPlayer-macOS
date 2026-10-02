# NeriPlayer macOS 播放体验与媒体库整改（第二轮）

日期：2026-10-03。基线 `d8df291`。本文先定义本轮实施需求；末尾完成记录由主智能体在构建、打包并实际操作新 app 后填写。

## 背景

上一轮同类整改的成果已保存在分支 `redesign-backup`（提交 `e5a13f7`）。本轮是在会话前基线之上**重做并修订**，其中第 2 项排版规格、第 3 项悬停提示、第 7 项首页卡片底色为新增或改写内容。`redesign-backup` 可作为实现参考，但**不得直接整文件覆盖**——排版规格已变（见第 2 项）。

## 目标与实施原则

对应用户提出的十项问题，直接改动现有 SwiftUI 原生 app。保留现有播放会话、队列、收藏、歌单及桌面歌词能力。以实现和实际操作为主，只运行必要构建与少量针对性检查，不扩展到无关重构、发布安全或全量测试。

## 逐项设计

### 1. 点击进度条闪烁

`PlayerProgressBar` 松手立即清空本地 scrub 值，mpv 的旧 position 可能先回流一帧，导致进度短暂回退。提交 seek 后应保留目标位置，直到引擎报告目标附近的位置；切歌时清空 pending 状态。把判定抽成纯函数 `PlayerProgressSeekResolution`（可单测）：

- `isConfirmed(pending:position:tolerance:)`：`abs(position - pending) <= tolerance` 即认为到位，非有限值按已确认处理。
- `resolve(scrub:pending:position:duration:tolerance:)`：显示值优先级为 拖动值 → 未确认的 seek 目标 → 引擎位置，并钳到 `0...duration`。

进度条高度与点击区域扩大，点击与拖动共用同一交互。轨道始终保留，播放中的 seek 不触发整栏加载占位。

### 2. 底部播放器重新排版（本轮修订重点）

布局按「左信息 / 中控制 / 右动作」三区，左右等宽使中间控制组落在**整窗水平中心**：

- **左区（左对齐）**：歌曲封面在最左，贴窗口左边界（水平内边距 14pt）。封面右侧紧接歌曲名、歌手、歌曲数据，全部左对齐，与封面保持合适间隔（14pt）。歌曲名约 17pt，歌手与数据约 13pt，两行纵向排列。
- **封面尺寸**：网易云与本地为方形；Bilibili 为横向容器并按原比例完整显示。封面高度与播放器栏高相当，即栏高约等于封面高度。
- **中区（居中）**：上方为「已播时间 + 进度条 + 总时长」一行，进度条在控制按钮**上方**，长度适中；下方为传输组（上一首 / 播放暂停 / 下一首），播放按钮明显放大。中区宽度固定，保证居中不随左右内容漂移。
- **右区（右对齐）**：其余按钮（播放模式、播完暂停、收藏、加入歌单、桌面歌词、队列、音量、更多）右对齐，**大小相等、间隔相等**，不分组建。窄窗口收起次要控制，保留传输组与队列入口。
- **音乐来源不再单独一行**，并入歌曲数据行显示（如「某歌手 网易云 · AAC · 128 kbps · 48 kHz · 2ch」）。注意：**本轮不要求去掉码率**——沿用 `AudioInfoText.summary` 的现有片段（编码 → 比特率 → 采样率 → 声道），只把来源并进去。
- 无曲与换歌期间不改变布局骨架，栏高恒定。

具体常量由实现者在合理范围内确定，并在注释中说明依据；关键是上述对齐关系、居中关系与「来源并入数据行」。

### 3. 按钮悬停显示功能说明

光标停留一段时间后自动显示该按钮的功能说明，移开即取消。使用 SwiftUI 原生 `.help(_:)`（macOS 悬停提示）实现，不要自绘浮层：

- 播放器栏与歌曲播放页中**所有可点击按钮**都要有 `.help`，包括传输组、模式、播完暂停、收藏、加入歌单、桌面歌词、队列、音量、更多，以及封面/曲目信息（打开播放页）入口。
- 文案简短、描述该按钮实际动作与其当前状态（如「取消收藏」「单曲循环」）。
- 收起进「更多」菜单的项同样要有说明或等价的菜单文案。

### 4. 独立歌曲播放页

删除旧「歌词页面」按钮与 sheet 导航入口（`MainContentView` 中的 `lyricsPresented` sheet），保留外部/桌面悬浮歌词按钮。点击底部封面或歌曲信息打开歌曲播放页：

- 播放页在主窗口内容区域展示（不是 sheet、不是独立窗口），可返回原导航页面，播放连续。
- 参考网易云桌面端：左侧大封面与歌曲资料，右侧大字号同步歌词，舒展留白与柔和背景。
- 网易云/本地用方形专辑封面；Bilibili 用完整横向视频封面。
- 复用现有逐行/逐字歌词、翻译、滚动跟随、点击歌词 seek、来源设置、歌词导出能力，去掉重复的底部播放控制，继续使用常驻播放器。

### 5. 外观与个性化的字体设置

添加 UI 字体、UI 基础字号、播放器字号、歌词字体、歌词字号及底部歌词字号设置，提供实时预览与恢复默认：

- 持久化，重启后生效；与现有歌词设置的字号一致。
- 字体采用本机可用字体和系统字体选项；UI 与歌词可分别设置。
- 设置调整即时反映到主窗口、底部栏和播放页。

### 6. 网易云无法播放时的换源顺序

原歌曲优先；原网易云源由于 VIP、无权限、无地址或实际播放失败进入换源后，**优先尝试匹配的 Bilibili 候选，再尝试 YouTube Music 候选**。保留现有同曲匹配评分/时长过滤；每个平台内按匹配度排序。搜索与解析均优先 Bilibili，避免 YouTube 先完成或高分抢占 Bilibili。Bilibili 分 P 搜索仍复用。

### 7. 首页歌曲卡片底色

首页推荐歌曲之间缺乏分隔，播放按钮容易误导为播放相邻歌曲。为歌曲卡片添加底色：

- 首页横向歌曲区（`HomeSongSectionView` 的每首歌）为卡片加圆角底色与内边距，使卡片边界清晰、相邻卡片可区分。
- 底色需在浅色/深色外观下均可辨识但不喧宾夺主，并与该分区的 loading/error 占位风格一致。
- 悬停时给出可点击反馈（如底色加深），但不得改变卡片尺寸导致布局跳动。
- 歌单/专辑卡片与 YouTube shelf 卡片保持现有视觉，除非确有同样的混淆问题。

### 8. 媒体库导航胶囊命中区域

本地、收藏、网易云、Bilibili、YouTube 标签的整个胶囊（含水平/垂直留白）可点击，明确 `contentShape(Capsule())`，选中背景与悬停反馈保持一致，不能只有文字能点击。

### 9. 歌单歌曲列表舒展与动作

本地歌单与平台歌单详情扩大行封面（约 48–56pt 高）、标题（约 16–17pt）、行高与纵向间距。常用收藏、加入歌单动作可见；保留播放、下一首播放、下载及右键动作。收藏按钮显示当前状态，加入歌单选择实际本地歌单并提供新建入口。双击或播放按钮仍使用完整歌单作为队列。

### 10. 平台封面比例

网易云的专辑、歌曲封面保持方形。Bilibili 视频搜索、歌曲列表、队列、底部播放器、播放页使用横向容器并 `scaledToFit`，原图完整可见，不能方形裁切。容器可用 16:9 默认占位，实际图像按原比例完整显示。Bilibili 收藏夹封面按收藏夹语义展示，不强行把网易云视觉一起修改。YouTube 音乐专辑维持原行为。

## 统一字体接口（先行冻结，解除互相阻塞）

主智能体在派发前已把下列契约落到代码，A/C 直接使用，B 负责填充设置界面与歌词侧接线：

```swift
public struct AppTypography: Equatable {
    public var uiScale: CGFloat
    public var playerTextSize: CGFloat
    public var compactLyricsSize: CGFloat
    public var uiFontFamily: String
    public var lyricsFontFamily: String
    public var lyricsBaseSize: CGFloat

    public func uiFont(size: CGFloat, weight: Font.Weight = .regular) -> Font
    public func lyricFont(size: CGFloat, weight: Font.Weight = .regular) -> Font
    public func lyricFont(scaledFromBase base: CGFloat, weight: Font.Weight = .regular) -> Font
    public func playerFont(size: CGFloat, weight: Font.Weight = .regular) -> Font
    public func playerFont(scaledFromBase base: CGFloat, weight: Font.Weight = .regular) -> Font
    public func lyricNSFont(size: CGFloat) -> NSFont
    public func lyricNSFont(scaledFromBase base: CGFloat) -> NSFont
}

public extension EnvironmentValues { var appTypography: AppTypography { get set } }
public struct AppTypographyModifier: ViewModifier { public init(model: SettingsViewModel?) }
```

用法：视图内 `@Environment(\.appTypography) private var typography`，用 `typography.uiFont(size:)` / `typography.playerFont(size:)` / `typography.lyricFont(...)` 取字体。根视图用 `.modifier(AppTypographyModifier(model: appState.settingsViewModel))` 注入。

`uiFont` 按 UI 基础字号相对默认 14pt 缩放；`playerFont` 按播放器字号设置缩放；`lyricFont` 按歌词基准字号与倍率缩放。

## 并行分工（最多三个子智能体）

所有子智能体使用 `D1api/deepseek-v4.1-flash`，在共享工作区直接编辑，**不提交、不自行打包、不启动其他子智能体、不运行全量测试**。各自的文件所有权如下，跨文件需求通过既有接口调用。

1. **A：播放器与播放页**。拥有 `NeriPlayer/UI/FloatingPlayerBar.swift`、`NeriPlayer/UI/Playback/PlayerProgressBar.swift`、`NeriPlayer/UI/Playback/PlayerBarLayout.swift`、`NeriPlayer/UI/MainContentView.swift`、`NeriPlayer/UI/NowPlayingPage.swift`（新增）、`NeriPlayer/UI/Playback/PlayerArtwork.swift`（新增）。完成 1、2、3（播放器与播放页部分）、4 及播放器/播放页部分的 10。
2. **B：字号与字体设置**。拥有 `NeriPlayer/UI/Appearance/AppTypography.swift`（已由主智能体冻结，可微调实现但不得改动公开签名）、`NeriPlayer/Core/Settings/AppearanceSettings.swift`、`NeriPlayer/Data/Settings/SettingsStore.swift`、`NeriPlayer/UI/Settings/SettingsViewModel.swift`、`NeriPlayer/UI/Settings/SettingsView.swift`、`NeriPlayer/UI/Lyrics/LyricsViewModel.swift`、`NeriPlayer/UI/Lyrics/KaraokeText.swift`、`NeriPlayer/UI/Lyrics/LyricsView.swift`、悬浮歌词相关文件。完成 5，并让字体设置真实作用于 UI、播放器与歌词。
3. **C：媒体库、歌单与首页**。拥有 `NeriPlayer/UI/Library/MediaLibraryView.swift`、`NeriPlayer/UI/Library/LibraryView.swift`、`NeriPlayer/UI/Library/LibraryTrackRow.swift`（新增）、`NeriPlayer/UI/Library/PlaylistView.swift`、`NeriPlayer/UI/Online/OnlineArtwork.swift`、`NeriPlayer/UI/HomeView.swift`。完成 7、8、9 及列表/搜索/队列部分的 10。

主智能体负责 6（换源顺序）、接口冻结、集成审阅、构建、打包、启动新 app 实际检查、回填完成记录与 README。

## 必要验收

- 最终源码成功构建；使用 `Tools/package.sh` 生成新的 `dist/NeriPlayer.app` 与 DMG。
- 启动新构建的 app 并确认实际进程路径，用 computer-use 实际检查：播放器排版与居中关系、按钮悬停提示、播放页打开/返回、外观字号即时生效、媒体库胶囊留白、歌单行动作、首页卡片底色、Bilibili 横向封面。
- 针对换源顺序执行必要的现有检查或小规模定向用例。
- 记录实际检查结果与任何未能验证项。

## 完成记录

2026-10-03 已完成十项实施，构建 build 2 并在实际运行的 app 中逐项检查（`dist/NeriPlayer.app`，进程 PID 45582）。

### 构建与产物

- `swift build --product NeriPlayer` 通过（零 error）。
- 相关测试全绿：`PlayerBarLayoutTests` 26 项（含本轮新增 8 项 `PlayerProgressSeekResolution` 用例）、
  `OnlineFeatureTests` 17 项、`OnlinePlaybackTests` 7 项，合计 50 项 0 失败。
- `Tools/package.sh`（BUILD_NUMBER=2）产出 `dist/NeriPlayer.app` 与 `dist/NeriPlayer-0.0.9.dmg`（35 MB），
  ad-hoc 签名 `codesign --verify --deep --strict` 通过，DMG CRC32 校验有效，内嵌 48 个 dylib。

### 实际界面检查结果

用 computer-use 在真实运行的 app 上逐项核对（窗口 1248×979，窗口左边界 x=1312，水平中心 x=1936）：

| 项 | 结论 | 证据 |
|---|---|---|
| 1 进度条闪烁 | 通过（逻辑） | `PlayerProgressSeekResolution` 8 项单测覆盖「seek 未确认时保持目标值、不回退」；真实拖动未单独复现残留闪烁 |
| 2 播放器排版 | **通过** | 封面 x=1326 = 左边界+14；封面 72×72 = 栏高 72；信息 x=1412（间隔 14）左对齐；播放按钮中心 1912+24=**1936** = 整窗中心；进度条中心 1828+108=**1936** 亦居中且 y=1194 在控制按钮 y=1219 **上方**；右侧按钮间隔均 14；来源并入数据行 |
| 3 按钮悬停说明 | 通过 | 播放器栏 15 处、播放页 5 处 `.help`；AX 树中按钮均带功能化标签（如「播放模式」value「随机播放」、「播完当前曲暂停」value「已关闭」、「添加到收藏」） |
| 4 独立播放页 | **通过** | 点封面进入，出现 380×380 大封面、`返回` 按钮、右侧大字号可点击歌词行（逐行可点 seek）、收藏/加入歌单/队列/桌面歌词；**无**重复播放控制；原歌词 sheet 入口已移除 |
| 5 字体字号 | **通过** | 外观页含 UI 字体、UI 基础字号、播放器字号、歌词字体、歌词字号、底部歌词字号六项 + 实时预览 + 恢复默认；**实测把 UI 基础字号 16→17 后侧栏行高 59→62.5、文字 32→34、播放器栏同步变大**，确认即时生效；「恢复默认」回到 14/17/28/18 并提示「字体设置已恢复默认」 |
| 6 换源顺序 | **通过** | 真实播放网易云歌曲（VIP 不可播放）时界面显示「已切换音源：Bilibili」，且规格行变为「网易云 · AAC · 195 kbps · 44.1 kHz · 2ch」，实际出声；另有 2 项定向单测 |
| 7 首页卡片底色 | 代码通过，界面未复核 | `HomeSongSectionView.songCard`：内容固定 300pt + 水平 10/垂直 6 内边距 + `RoundedRectangle(10)` 底色 `secondary.opacity(0.06)`、悬停 `0.11`，悬停只改 fill 不改尺寸。见下方限制说明 |
| 8 胶囊命中区 | **通过** | 「本地/收藏/网易云/Bilibili/YouTube」五个标签在 AX 树中均为整块 `AXButton`（34pt 高、宽 60–84pt，含留白），非仅文字 |
| 9 歌单行舒展与动作 | **通过** | 行内含封面缩略图、标题、歌手、右侧格式角标（M4A/MP3）、**星标收藏**与**加入歌单**按钮；歌单详情参数 titleSize 17 / coverSize 56 |
| 10 封面比例 | **通过** | Bilibili 横向前端为 16:9（底部播放器 128×72、队列 64×36、首页 16:9）；网易云封面在列表中显示为方形；`OnlineArtworkThumbnail` / `PlayerArtwork` 两套实现均按 `source == .bilibili` 分平台 |

截图证据：`.dsh-computer-use/artifacts/…/observation-3bef8eec-…png`（媒体库+播放器栏）、`observation-8b73…`（播放页）。

### 未能验证 / 已知限制

- **第 7 项首页卡片底色未做像素级复核**：computer-use 的原生 helper 在读取「首页」这一页时**自身崩溃**
  （`dsh-computer-use-helper` 的 `observeSnapshot(app:limits:)` 触发 SIGTRAP，终止码 5），
  连试多次一致；媒体库/设置/播放页均正常。这是 helper 序列化超大 AX 树时的缺陷，**与 app 无关**
  （同一时刻 app 进程存活且 CPU 正常、窗口标题为「首页」）。第 7 项因此**仅以代码复核**（见上表），
  未取得首屏截图。需要时可在首页加载稳定后重试，或改用人工目视。
- 第 1 项在真实播放中未单独构造「快速连续点击进度条」以复现残留闪烁；判据以纯函数单测为准。
- 真实 VIP 账号下的换源链路只验证到「网易云失败→Bilibili 成功」这一条路径；Bilibili 亦不可用时的
  YouTube 兜底由单测覆盖，未做真实账号验证。

### 与上一轮（redesign-backup / e5a13f7）的差异

本轮**未**沿用上一轮的两项内容，因其不在用户本次十项之内：
1. **保留实时码率显示**（上一轮第 2 轮曾要求去掉；本轮只要求来源并入数据行）。
2. **未隐藏窗口顶栏**（`hiddenTitleBar`），本轮无此要求。
`MPVEngine` 的 `coreaudio,avfoundation` 备用输出与 `NeriPlayerApp` 的顶栏改动均**未**引入。

### 一处集成期修正

子智能体 A 曾按上一轮记忆把「去掉码率」一并带入；主智能体核对需求文档后确认本轮无此要求，
已更正并同步 `PlayerBarLayoutTests` 断言为保留码率的 `MP3 · 128 kbps · 48 kHz · 2ch`。
