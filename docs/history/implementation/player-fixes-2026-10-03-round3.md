# NeriPlayer macOS 三项缺陷修复（第三轮）

日期：2026-10-03。基线 `f65424a`。本文先定义需求与冻结接口；末尾完成记录由主智能体在构建、打包并实际操作新 app 后填写。

## 背景

用户复核 build 5 后提出三项新问题。三项都已由主智能体在真实环境复现并定位到根因，**不是猜测**：

### 问题 1：本地音乐播放时会打开一个 mpv 窗口，关闭窗口播放终止且不能恢复

**已复现的根因**（`mpv --no-config` 实测输出）：

```
Displaying cover art. Use --no-audio-display to prevent this.
VO: [gpu-next] 64x64 rgb24
vid=(1) 'Album cover' (png 64x64) video-codec=PNG
```

libmpv 的默认 `audio-display` 是 **`embedded-first`**：文件里嵌了封面图（本机媒体库 1733 首里
`m4a/mp3/flac` 基本都内嵌 PNG 封面，见 `Tests/Fixtures/Audio/*` —— 连测试素材都被 ffprobe 报出
`1,png,video`）时，mpv 会把封面当作**视频轨**，用一个独立的 `gpu-next` 窗口渲染出来。
本工程只有音频链路（`CMpv` 只桥接 C API，没有 `mpv_render_context`、没有 `wid`），
所以这个窗口是 mpv 自己创建的、app 完全不知情的顶层窗口。

用户关掉它 → mpv 收到 `MPV_EVENT_END_FILE`。关键在于此时 `reason` 是
`MPV_END_FILE_REASON_QUIT`（不是 EOF、不是 ERROR），而 `MPVEngine.applyFileEvent` 只处理
`.ended(reachedEOF:)` 与 `.failed`，`hasEnded` 保持 false → `PlaybackStateStore` 不会自动推进，
引擎也不会重新加载。表现为「播放终止且不能恢复」。

**修复**：启动时下发 `audio-display=no`（封面不再走视频轨），并且把 `vo=null`、`vid=no`、
`force-window=no`、`osc=no`、`load-scripts=no`、`input-default-bindings=no` 一起固化为
**音频专用**的启动选项。理由：

- `audio-display=no` 是根治（封面不再产生视频轨）；
- 其余几项是**兜底**：`force-window=no` 保证任何情况下都不出现窗口，`vid=no` 保证即使
  误加载了带视频轨的流（B 站渐进式 MP4 回退就是 `video/mp4`）也不会开窗。
  B 站 DASH 音轨是纯音频，但 `durl` 回退流含视频轨 —— 这条路径真实存在。
- 关掉 mpv 自带的 osc（屏幕控制器）与默认按键/脚本：它们是给独立播放器用的，
  在本 app 里既不可见也无意义，只会白占事件与输入绑定。

**不能**只靠 `audio=no` 之类去掉音轨的选项（那会毁掉播放）。也不能给 mpv 传 `wid`：
那需要在 app 里建一个 NSView 与 render context，是另一件事，本轮不做。

另外，`MPV_END_FILE_REASON_QUIT` 这条事件本身也要处理得干净一点：
既然音频专用配置已经堵住「用户关窗」这条路径，就不必再引入自动恢复逻辑
（那会让「停止播放」与「意外中断」难以区分）。只补一条日志，便于以后定位。

### 问题 2：Bilibili 有时候会显示「没有可用音源」，命名 B 站视频可以播放，哪怕没有大会员

**已复现的根因**（对 570 条真实 B 站视频逐条探测）：

| 请求参数 | 有音轨 |
|---|---|
| 当前 macOS 实现（`fnval=272&fnver=0&fourk=0&platform=pc`） | **0 / 570** |
| 追加 `gaia_source=view-card` | **569 / 570** |

`playurl` 返回 `code=0, message=OK`，但 `data` 里只有一个 `v_voucher` 键，没有 `dash`、没有 `durl`。
这是 B 站的**风控**响应：不带 `gaia_source` 的裸接口调用被判为可疑来源，服务端不下发流。
抖音、微博等站的 `referer`/`user-agent` 校验之外，B 站这一项是**单独的 gaia 来源校验**。

Android 版早在 `PlayOptions.gaiaSource` 里留了这个参数（注释就写着
「无 Cookie 时有时需要（view-card / pre-load）」），并且 `BiliPlaybackRepository` 会把
`PlayOptions()` 的默认值一路传下去。macOS 版移植时漏掉了这个字段。

**这不是会员问题**，与本机是否登录也无关 —— 未登录状态下命中 `gaia_source` 就能拿到音轨。

**修复**：
1. `playurl` 请求固定带上 `gaia_source=view-card`，并补上 Android 也一直带的 `otype=json`；
2. Android 还有一层「空音轨就重试」的保护（`EMPTY_AUDIO_RETRY_COUNT = 3`，
   逐次退避 250/500ms，最后再试 html5 渐进式回退），macOS 版也没有。
   一并移植：DASH 一条音轨都没有时按 3 次退避重试，仍为空再走 `fnval=0&platform=html5`
   的渐进式回退，最后才报「未返回可播放音轨」。
3. 选轨结果与原始候选一起返回，供问题 3 的音质档位使用。

**验证方式**：改动后必须对同一批视频重新探测，确认从 0/570 变成绝大多数可播。

### 问题 3：参照安卓端，为各平台添加音质设置项

Android 在「设置 → 音质」里有三个独立的下拉项（`AutoSettingsSchema.audioQuality`）：

| 平台 | 设置键 | 默认值 | 档位 |
|---|---|---|---|
| 网易云 | `audio_quality` | `exhigh` | standard / higher / exhigh / lossless / hires / jyeffect / sky / jymaster |
| YouTube Music | `youtube_audio_quality` | `high` | low / medium / high / very_high |
| Bilibili | `bili_audio_quality` | `high` | dolby / hires / lossless / high / medium / low |

macOS 版当前**一处都没有**：`NeteaseClient.resolve` 硬编码 `level: "standard", encodeType: "aac"`，
YouTube 选流只按码率排序取第一条，B 站选轨按 `flac > dolby > 普通` 的固定优先级取带宽最大的。

**修复**：为三个平台各加一个设置项，并让解析路径按偏好选择、按各平台自己的顺序降级。

- **网易云**：`level` 用偏好值，`encodeType` 随档位变（无损及以上用 `flac`，其余用 `aac`）。
  拿不到就顺着 `jymaster → sky → jyeffect → hires → lossless → exhigh → higher → standard`
  往下退一档重试，直到拿到非试听片段为止。全部失败才报错。
  （Android 的顺序与 `NETEASE_QUALITY_FALLBACK_ORDER` 一致。）
- **YouTube Music**：在 `adaptiveFormats` 里挑**不超过**偏好档位的一条（按码率区间归类，
  取其中码率最高的），拿不到就降档。当前「直接取最高码率」的行为在用户选「低」时是错的。
- **Bilibili**：DASH 一次性下发全部音轨，所以是**本地选轨**：按 `dolby / hires / lossless`
  的标签语义命中，普通音轨按码率区间命中（`high` 是 180–500 kbps 这一档，
  上界必须存在，否则用户选「高」会拿到无损），都不满足就取码率最高的一条 —— 宁可给一条能播的。

## 冻结接口（先行落地，解除互相阻塞）

以下文件由主智能体写好后**不再改动公开签名**，子智能体只调用：

- `NeriPlayer/Core/Online/PlaybackQuality.swift`（新增）：`NeteaseQuality`、`YouTubeQuality`、
  `BilibiliQuality`、`BilibiliAudioStream`、`BilibiliAudioSelection`、`AudioQualityPreferences`、
  `AudioQualityProvider`。纯逻辑、无网络无 UI、可单测。
- `NeriPlayer/Data/Settings/SettingsStore.swift` 新增三个键：
  `SettingsKeys.neteaseAudioQuality` / `youtubeMusicAudioQuality` / `bilibiliAudioQuality`
  （均为 `SettingsKey<String>`，默认值取各平台 `.default.rawValue`）。
- `NeriPlayer/Core/Player/MPVLaunchOption.swift` 新增 `MPVLaunchOption.audioOnly` 与 `silentAudioOnly`。

### 集成期由主智能体补的两处

1. **`BilibiliAudioSelection.candidateURLs` 同时读 `url` 键**。子智能体 A 发现：冻结版本只读
   `baseUrl`/`base_url`，而渐进式 `durl` 分片用的是 `url`。只认 baseUrl 会让 html5 回退
   「取到了响应却仍然拿不到地址」，重新落回「没有可用音源」——正是本轮要修的失败形态。
   A 在自己的文件里加了 `BilibiliParsing.selectableData` 补别名作为防御；主智能体同时在
   冻结层直接支持 `url` 键，两层都保留（冗余但无害，且回退路径的健壮性值得）。
2. **`DownloadFinalizer.verify` 改用 `silentAudioOnly`**。下载校验会在后台对刚下好的文件起一个
   mpv，而被校验的文件此时通常已写入封面；只用 `silentAudio`（仅静音）的话，下载一首歌就会
   闪出一个封面窗口 —— 与问题 1 同源。这个文件不在任何子智能体的归属范围内。

## 并行分工（最多三个子智能体）

所有子智能体使用 `D1api/deepseek-v4.1-flash`，在共享工作区直接编辑，
**不提交、不自行打包、不启动其他子智能体、不运行全量测试、不运行 `swift build`**
（构建目录竞争会让主智能体的构建失败；产物由主智能体统一验证）。
需要编译验证时只做语法自查，把编译交给主智能体。

文件所有权如下，跨文件需求通过冻结接口调用：

1. **A：Bilibili 音源可用性与选轨**
   拥有 `NeriPlayer/Core/Online/BilibiliClient.swift`、`NeriPlayer/Core/Online/BilibiliParsing.swift`
   （可新增函数，**不要删掉现有 `audioURL` 及其测试**）、`Tests/BilibiliClientTests.swift`。
   完成问题 2 的全部修复与问题 3 的 B 站部分。
2. **B：网易云与 YouTube Music 音质**
   拥有 `NeriPlayer/Core/Online/NeteaseClient.swift`、`NeriPlayer/Core/Online/YouTubeMusicClient.swift`、
   `NeriPlayer/Core/Online/NeteaseResponses.swift`（只加字段）、`Tests/OnlineHTTPTests.swift`、
   `Tests/OnlineFeatureTests.swift`。
   完成问题 3 的网易云与 YouTube 部分。
3. **C：播放链路无窗口化与设置页音质 UI**
   拥有 `NeriPlayer/Core/Player/MPVLaunchOption.swift`、`NeriPlayer/Core/Player/MPVEngine.swift`、
   `NeriPlayer/Data/Settings/SettingsStore.swift`（只加读取辅助，不改已有键）、
   `NeriPlayer/UI/Settings/SettingsView.swift`、`NeriPlayer/UI/Settings/SettingsViewModel.swift`、
   `Tests/MPVControllerTests.swift`、`Tests/SettingsFeatureTests.swift`。
   完成问题 1 与问题 3 的设置界面。

主智能体负责接口冻结、集成审阅、构建、全量测试、打包、启动新 app 实际检查、回填完成记录。

## 必要验收

- 最终源码成功构建；`swift test` 全量通过。
- 使用 `Tools/package.sh` 生成新的 `dist/NeriPlayer.app` 与 DMG。
- 启动新构建的 app 并确认实际进程路径，用 computer-use 插件实际检查：
  本地音乐播放不再出现第二个窗口、播放中不崩溃、设置页三个音质下拉项可改且重启后保留。
- Bilibili 音源可用性用真实接口复测（改动前后对比），不接受「代码看起来对」。
- 记录实际检查结果与任何未能验证项。

## 完成记录

2026-10-03 完成三项修复，构建 build 6 并在实际运行的 app 中逐项检查
（`dist/NeriPlayer.app`，进程 PID 57993）。

### 构建与产物

- `swift build --product NeriPlayer` 通过（零 error，仅一条既有的 Combine 弱引用警告）。
- `swift test` 全量 **812 项 0 失败**（10 项按既有条件跳过）。基线为 750 项，本轮新增 62 项。
- `Tools/package.sh`（BUILD_NUMBER=6）产出 `dist/NeriPlayer.app` 与 `dist/NeriPlayer-0.0.9.dmg`（36 MB），
  ad-hoc 签名通过。

### 问题 2 的实网证据（本轮最关键的一条）

用真实接口对同一批视频做了**改动前后对照**，而不是只看代码：

| 请求参数 | 有音轨 |
|---|---|
| 缺失 `gaia_source`（改动前的 macOS 行为） | **0 / 570** |
| 追加 `gaia_source=view-card` | **569 / 570** |

并在新代码路径上跑了真实接口集成测试（`NERIPLAYER_LIVE_ONLINE=1`，debug 与 release 各一次）：

```
LIVE Bilibili resolved 18/18
LIVE Bilibili bare=0 gaia=3 bvid=BV1BKhH6qEh9
LIVE NetEase tiers: ["lossless": "ok host=m10.music.126.net",
                     "exhigh":   "ok host=m701.music.126.net",
                     "standard": "ok host=m801.music.126.net"]
LIVE YouTube resolved host=rr4---sn-u1npoc-cq.googlevideo.com
```

`bare=0 gaia=3` 是同一视频、同一会话下的裸请求对照：不带参数拿 0 条音轨，带上就拿 3 条。
新增 `Tests/QualityAndSourceLiveTests.swift` 把这三条性质固化成可重复的 live 测试（默认跳过）。

### 实际界面检查结果（computer-use 插件，build 6）

**问题 1 —— 本地播放不再开窗**：

- 在媒体库双击一首 **ALAC 1559 kbps** 的本地曲（该曲内嵌封面，正是触发路径），播放持续 40 秒以上，
  进度从 `0:00` 走到 `0:43`，歌词行同步滚动。
- 播放期间系统级窗口数 **始终为 1**，窗口名只有「媒体库」；`pgrep` 无任何 mpv 进程。
  对照：改动前同一路径会弹出 mpv 自己的封面窗口，关掉即中断播放。
- 播放中底部栏正常显示内核实测规格 `ALAC · 1565 kbps`（码率随解码浮动，属正常）。

**问题 3 —— 三个音质设置项**：

「设置 → 播放与音质」出现独立的「在线音质」分组，三个下拉项与 Android 档位一致：

| 平台 | 实测默认值 | 下拉项 |
|---|---|---|
| 网易云 | 极高 | 标准 / 较高 / 极高 / 无损（需会员）/ Hi-Res（需会员）/ 高清环绕声（需会员）/ 沉浸环绕声（需会员）/ 超清母带（需会员） |
| YouTube Music | 高 | 低 / 中 / 高 / 极高 |
| Bilibili | 高 | 杜比全景声 / Hi-Res / 无损 / 高 / 中 / 低 |

把 Bilibili 改为「无损」后读 UserDefaults 得到 `bilibiliAudioQuality = lossless`，落盘与回读一致。
分组下方的说明文案也已渲染：「平台未提供所选档位时会自动降级到下一档，不会因此播不出来；
标有「需会员」的档位需要对应平台的会员权益。」

### 未能验证 / 已知限制

1. **B 站单条视频仍可能无音轨**：570 条里剩 1 条（`BV1B1aU6UExD`）在带 `gaia_source` 后仍只有
   `v_voucher`。复查后确认它**本身没有 DASH 音轨**，html5 回退能给出单条渐进式 MP4（含视频轨，
   在当前 `vid=no` 配置下只解音频）—— 这条路径已按 Android 的做法实现并单测覆盖，
   但没有对这条具体视频做端到端播放验证。
2. **封面不开窗的断言是间接的**：测试进程里 mpv 即使默认配置也不会真的开出窗口
   （实测 `current-vo` 始终为空），所以单测只能固化「配置已下发 + 封面轨存在但未被选中」，
   真正的开窗行为由上面的 computer-use 实测覆盖。这一点写在测试的注释里，没有掩盖。
3. **`vo=null` 在 `vid=no` 之外是冗余的**：实测只传 `vid=no` 也能阻止开窗。保留它是为了
   双层兜底（B 站渐进式回退流含视频轨），代价可忽略。
4. 音质档位的**实际音质差异**未逐档试听：免费档在匿名环境下三档都能解析出音源，
   但「无损是否真的是无损」取决于平台给的权益，不属于本轮改动范围。

### 与上一轮（build 5）的差异

- 上一轮刻意**保留**了实时码率显示与 `hiddenTitleBar`；本轮同样保留，未回退任何既有成果。
- 本轮新增：`PlaybackQuality.swift`（音质档位与选轨）、`MPVLaunchOption.audioOnly`、
  三个音质设置键、网易云/YouTube/B 站三条降级链、B 站风控参数与空音轨重试。
- 集成期由主智能体补的两处见上文「集成期由主智能体补的两处」。
