# NeriPlayer macOS

参考 [cwuom/NeriPlayer](https://github.com/cwuom/NeriPlayer) 的原生 macOS 移植实验，使用 SwiftUI、libmpv、GRDB 和 TagLibSwift。当前为开发中的 **0.0.9**，与 Android 版版本号独立；尚未发布正式 Release 编译版本。

M9 已提供可分发的 `.app/.dmg` 打包路径：默认输出 unsigned/ad-hoc 包；配置 Developer ID 和 notarytool profile 后由同一脚本完成签名与公证。它仍不是 Android 版的完整替代，平台差异见下文。

## 当前能力

- 本地目录扫描、元数据/封面索引、歌曲/歌手/专辑浏览、搜索、收藏及歌单。
- libmpv 本地播放、队列、循环/随机模式、媒体键与 Now Playing 接入。
- 播放现场、历史及统计的数据库层，外观与启动播放偏好。
- 首页按 Android 分区组织网易云私人雷达、每日推荐、私人 FM、榜单、推荐/精品/热门/ACG 歌单及 YouTube Music 首页栏；各分区独立加载并保留缓存。
- 搜索为第二个页面：平台歌曲搜索、网易云歌单/专辑/歌手搜索、YouTube 创作者搜索、搜索历史与歌曲/歌单链接识别。
- 媒体库分为本地、收藏、网易云、Bilibili、YouTube 五栏；收藏页包含歌曲与本机收藏的歌单/专辑，各平台浏览状态独立。
- 主窗口底部播放栏保留顶部可拖动进度、曲目信息、同步歌词、实际音频规格、音量、模式、收藏/歌单及桌面歌词；队列按钮打开当前播放队列，窄窗口的辅助控制收进更多菜单。
- 设置采用分类列表与独立详情页，分为账号、通用、外观与个性化、播放与音质、歌词、网络与下载、存储与媒体库、备份与同步、一起听、关于。
- LRC、增强 LRC、YRC、TTML、Lyricify SYL、KRC 文本解析与导出；本地同名歌词、显式网易云歌曲 ID、播放同步/偏移、逐行/逐字高亮和 1080px PNG 歌词卡片。

- 网易云、Bilibili、YouTube Music 统一搜索与在线播放；平台媒体库与歌单/专辑详情、网易云/B站 QR 登录入口、YTM Cookie 导入及 Keychain 会话存储。封面统一缓存；Bilibili 优先补取收藏夹元信息，缺少封面时才尝试视频封面。
- 在线队列按稳定歌曲标识恢复；音源刷新、候选评分换源、失败跳过以及返回本地播放的取消隔离。
- 下载队列、Range/ETag 断点续传、非加密 HLS 点播续传、下载页、播放缓存命中、存储分类清理和 TagLib 标签收尾。
- GitHub/WebDAV 元数据同步、Android 2.0 快照兼容读取、歌单/收藏/历史/统计合并、在途本地修改保护，以及本机设置和数据库元数据备份恢复。

M8 已接入菜单栏播放器、悬浮歌词、Metal 流体背景、10 段 EQ/响度/淡变、左右滑手势、ListenTogether Worker 客户端、快捷键和 URL 路由。仍需人工确认真实 DAC 独占、两台设备互通、最终 `.app` 的 URL Scheme 注册、Metal 视觉/帧率和听感；顺次淡出/淡入不是重叠 crossfade。三源账号授权、私有歌单、完整曲目收听、整首下载和断网恢复也仍需平台人工验收。M7 同步/备份的真实 Android 导出 golden 和云端双向同步同样尚未人工验收。

## 本地构建

前提：macOS、Xcode 工具链、Homebrew。当前锁定的 GRDB 7.11.1 要求 **Swift 6.1+**；根清单的 tools-version 5.10 只表示其清单语法，不代表整个依赖图支持 Swift 5.10。本轮审查环境为 Apple Silicon / Swift 6.4。

```sh
Tools/fetch-mpv.sh
swift build
swift test
swift run NeriPlayer
```

创建 unsigned DMG（需要已布置 `Vendor/mpv`）：

```sh
VERSION=0.0.9 BUILD_NUMBER=1 Tools/package.sh
```

发布签名与公证需额外设置 `SIGNING_IDENTITY`、`NOTARY_PROFILE`；脚本会把可发现的 Homebrew 动态库复制到 app 内并改写为 `@rpath`。没有证书时 unsigned/ad-hoc 输出仍可用于本机和干净机器的安装验收。

`swift build` / `swift test` 只更新构建目录，不会更新已存在的 `.app`。要运行最新界面改动，需重新执行 `bash Tools/package.sh`；脚本会清空 `dist` 后生成 `dist/NeriPlayer.app` 与 `dist/NeriPlayer-0.0.9.dmg`。打包产物不提交到源码仓库。

在窗口切换到媒体库，选择导入目录，再播放歌曲。可选校验：

```sh
Tools/run-swiftlint.sh
actionlint .github/workflows/ci.yml
swift build -c release
```

**重要限制：**

- `Vendor/mpv` 不入库，首次构建前必须运行获取脚本；它可能执行 `brew install mpv`。
- 这里只复制 libmpv 本体，FFmpeg 等间接依赖仍引用本机 Homebrew 路径，不能把 `.build` 里的程序直接复制给其他机器。
- 清单部署目标为 macOS 13，但本轮 `vtool` 实测当前 libmpv 的 `minos` 为 **27.0**，Release 链接器也报告不匹配。发布前必须重建兼容目标系统的依赖闭包；尚未验证 macOS 13 或 Intel。部署目标不是兼容性证明。
- 打包脚本已生成 `.app/.dmg`、URL Scheme 和图标；App Sandbox 授权链路与安全作用域书签仍需要在最终签名包中验证。Developer ID 签名、公证依赖本机证书和 notarytool profile。
- 崩溃标记目前只覆盖未捕获的 Objective-C `NSException`，不覆盖所有 Swift trap、信号或 native 崩溃。About/帮助菜单可查看并导出已有诊断记录。

## 同步与备份

设置页可配置 GitHub 用户名、同步仓库及 PAT/已有 OAuth access token，令牌存入 Keychain；私有仓库由显式按钮创建。WebDAV 配置完整 HTTPS 快照文件地址，已有文件必须支持强 ETag 条件写入。同步仅交换元数据，不上传音频、登录凭据或本地文件路径。

“导出备份/恢复备份”是本机全量元数据操作：含设置、库、歌单、收藏、历史和统计，不打包音频/封面/缓存/下载任务，也不包含 Keychain 凭据。恢复会替换当前元数据，界面要求确认；备份未加密且可能含本机路径，应按个人数据保管。跨平台请使用同步快照，本机备份不与 Android 全量备份格式互换。

## 数据与测试

应用数据默认位于 `~/Library/Application Support/NeriPlayer`；测试主要使用临时目录与独立 UserDefaults suite，不需要音乐平台账号。运行程序本身则会访问真实应用数据，试验前建议自行备份。

测试包含真实 libmpv 解码（播放测试使用 null 音频输出）以及可控引擎替身。硬件媒体键、控制中心、真实 DAC、权限撤销、长时间稳定性及 UI 性能仍需人工验收。

## Android 差异与未覆盖功能

macOS 版明确未覆盖或不等价的 Android 能力：Android Service/WorkManager 生命周期、Media3/ExoPlayer 专用行为、Android Equalizer 与 LoudnessEnhancer 硬件管道、USB UAC 驱动与 DSD、Android WebView 登录容器、App Widget、通知渠道、系统分享/投屏、Android 专属权限与后台限制，以及 Android 端的完整账号授权、私有歌单和平台 DRM 能力。macOS 使用 libmpv、SwiftUI、Keychain、URLSession、MenuBarExtra/NSPanel 和 Metal 等原生替代；具体边界以 M8/M9 验收记录为准。

## 发布

- `Tools/package.sh`：构建 `.app` 和 `.dmg`，默认 unsigned/ad-hoc；`SIGNING_IDENTITY` + `NOTARY_PROFILE` 启用 Developer ID 与 notarization。
- `.github/workflows/release.yml`：推送 `v*.*.*` tag 后构建 DMG、上传 artifact 并创建 draft release。签名密钥只从 GitHub Actions secrets 读取。
- Sparkle 自动更新暂不接入：当前没有稳定的 AppCast 服务；发布阶段使用 GitHub draft release，后续可在不改变播放/设置数据格式的前提下替换更新通道。

## 开发文档

- [迁移规划](移植规划.md)：里程碑目标，不是全部功能已完成的声明。
- [代码审查与验证记录](docs/code-review-2026-09-30.md)：本轮缺陷、回归测试、验证结果及后续优先级。
- [歌词移植笔记](docs/m4-lyrics-notes.md)、[在线音源笔记](docs/m5-online-notes.md)、[M5 验收记录](docs/acceptance/m5.md)、[M6 验收记录](docs/acceptance/m6.md) 与 [音效 ADR](docs/audio-effects-adr.md)。
- [同步与备份笔记](docs/m7-sync-notes.md)、[M7 验收记录](docs/acceptance/m7.md)、[同步快照 JSON Schema](docs/sync-snapshot.schema.json)。
- [M8 验收记录](docs/acceptance/m8.md)：桌面播放器、Metal、音效、ListenTogether 与人工验收边界。
- [播放栏与页面重做验收](docs/acceptance/player-pages-2026-10-02.md)、[设置切页性能记录](docs/acceptance/settings-navigation-2026-10-02.md)：最新范围、验证与限制。
- [早期桌面 UI 记录](docs/acceptance/desktop-ui.md)：2026-10-01 的历史状态，后续变更以最新验收为准。
- [历史验收记录](docs/acceptance/)：保留既有阶段记录；本轮无法独立确认其中所有截图、压力轮数和真机结论。

## 上游与来源

本轮行为对照基于本地 Android checkout `12351888e64178b145bc612b7d8e40efa7497d95`，歌词子模块 `825661a10101b6b17cdcf8f39e0d5a12ff8d21fd`。在线上游持续变化，不应把当前主分支的全部特性当作本仓库能力。

发布前还需补齐本仓库许可证、移植代码来源/署名和第三方依赖许可清单，并核对随包分发的二进制依赖。当前文档不替代这些发布工作。
