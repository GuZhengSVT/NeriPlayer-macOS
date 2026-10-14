# 2026-10-14 独立检查整改与并行实施记录

## 1. 目标与证据边界

**当前状态：2026-10-15 已完成本轮整改、统一测试和 build 5 实际界面复验。** 最新完整测试为 835 项、10 项跳过、0 失败；对应日志 `/tmp/neriplayer-remediation-tests-resumed.log`，包含最后一轮滚动捕获及标题覆盖修改。媒体库切页后滚动位置和播放页标题已在最新包通过实际操作。源码保留未提交；macOS 13 依赖重建及未执行的硬件/私有账号验收仍保留待办，详见第 6 节。

用户要求把本轮检查得到的问题和优化写成详细文档，由多个 subagent 实施，期间无需用户参与交互。
本次依据 2026-10-14 独立阅读代码、操作现有应用和运行测试的结果；旧清单与旧验收记录只作为导航，不作为 PASS 证据。

检查基线：Git HEAD `6837988`；现有 `dist/NeriPlayer.app` 为 0.1.0 / build 1。
已有未提交改动：`Tools/make-app-icon.swift`、`Tools/AppIcon/`，由用户保留，本轮不覆盖或回退。
原始测试日志：`/tmp/neriplayer-review-tests-20261014.log`；812 项、10 项跳过、0 失败。
真实在线日志：`/tmp/neriplayer-review-live-20261014.log`、`/tmp/neriplayer-review-bilibili-recheck-20261014.log`。
网易云、YouTube 的搜索/解析/短时解码通过；B 站首次匿名搜索为空，复验返回 20 条并解码成功。偶发空结果原因未确认，不按永久失效处理。

本轮允许：源码修复、必要回归测试、文档、构建和独立输出目录下的验证包。
不执行：发布 Release、上传凭据、修改用户 Keychain ACL、输入或索取 Mac 密码、操作真实同步/备份恢复、改动既有图标成果。
不能完成的真机验收如实记为 NOT_RUN，不通过抬高声明或改写历史记录伪装完成。

## 2. 分工、文件所有权与共享接口

所有 agent 共用工作目录，直接编辑，不建立额外分支，不提交 Git。一个文件同一时刻仅一个 owner。
子 agent 只携带本文件及明确任务，短结果写入独立报告，避免重复传递完整历史。
主 agent 汇总后统一运行完整测试和最终打包；子 agent 默认不并行启动 SwiftPM 构建，避免 `.build` 锁竞争。

| 工作包 | Owner | 文件边界 | 交付 |
|---|---|---|---|
| A 音源、缓存与换源 | audio agent | `Core/Online/OnlinePlaybackCoordinator.swift`、`OnlineModels.swift`、`Core/Download/PlaybackAudioCache.swift`，必要的 `OnlineAudioTransport.swift`；独立音频回归测试 | B03/B04/O05；接口说明与回归结果 |
| B 扫描与媒体键 | library agent | `UI/Settings/SettingsViewModel.swift`、`UI/Library/LibraryViewModel.swift`、`Core/GlobalShortcutManager.swift`；独立扫描/键码回归测试 | B02/B05；调用链测试 |
| C 导航与播放器 UI | ui agent | `UI/MainContentView.swift`、`UI/Library/LibraryView.swift`、`MediaLibraryView.swift`、`UI/Online/SearchView.swift`、`SearchPageModel.swift`、`UI/NowPlayingPage.swift`、`FloatingPlayerBar.swift`、`UI/Playback/PlayerProgressBar.swift`、`PlaybackQueuePopover.swift`；独立 UI/状态测试 | B06/B07/B08/O02/O03 |
| D 集成、打包、存储与性能 | 主 agent | `Tools/package.sh`及新增工具、README、本文件、`App/AppState.swift`、`Core/Download/DownloadViewModel.swift`、`StorageUsage.swift`、`UI/Downloads/DownloadsView.swift`、`UI/Background/HyperBackgroundView.swift`、`UI/Library/LibraryTrackRow.swift`、凭据模块（仅必要范围） | B01/O01/O04/O05 集成，统一验证 |

共享约定：不扩展 `PlaybackSnapshot` 来承载 UI 独有状态；实际来源读取现有 coordinator 的 `currentResolvedAudio`。
在线缓存由 A 定义音质维度，并保持已有 `lookup/song` 测试调用可用；默认音频容量上限建议 2 GiB，必须保护活动文件。
媒体库导航持久状态由 C 在视图层持有，B 不更改相关视图结构。扫描排队由 B 在 LibraryViewModel 接收层处理。
下载完成文件定位/播放由 D 实现，通过 `DownloadViewModel` 返回检查过的文件 URL，MainContentView 默认现有 initializer 无需强制新增参数。
新增接口或需要跨 owner 文件时先发消息，等 owner 协调；不顺手修改其他工作包。

## 3. 已确认问题与验收任务

### B01 / P1：发布包最低系统版本不一致

证据：本轮 `vtool` 读取主程序 minos 13.0、包内 libmpv minos 27.0；Info.plist 声明 13.0。
实施：检查打包依赖闭包，最低系统要求必须覆盖所有 Mach-O。保持项目目标 13 的支持意图；现有依赖不兼容时给出明确结果，禁止静默输出宣称 13 的包。
不能靠只改 Mach-O load command 伪造兼容；重建 macOS 13 依赖闭包的成本先查可用工具与依赖，若无可行条件，交付检测及诚实标识的本机验证包，旧系统支持保留待办。
验收：兼容闭包检查可发现当前 libmpv；合法包的 plist 与实际要求一致；缺少必要依赖即失败；不删除旧 dist 成果。

### B02 / P1：多个目录扫描被忙碌判断忽略

证据：SettingsViewModel.rescanAll 同步调用多次 rescanHandler；LibraryViewModel.importDirectory 首次置 isSyncing，后续立即 return。
实施：串行队列接收多个目录，合并重复目录；设置反馈是已提交还是已完成，扫描结束与失败可见。
验收：两个有效临时目录均入库；第一个失败不阻止第二个；重复提交不重复扫描；扫描期间队列与 isSyncing 状态正确。

### B03 / P1：旧缓存绕过新音质偏好

证据：播放缓存只按 song.id 命中，缓存 entry 无音质；命中后不走平台解析。
实施：缓存记录与查询带明确音质维度，记录请求偏好和可获得的信息；无法确认的历史缓存不能在改变音质后假装满足新档位。
验收：低档缓存不能满足新的高档请求；同偏好可复用；换账号不泄漏凭据；旧缓存可安全处理；缓存地址刷新不产生错误共享。

### B04 / P1：运行失败换源丢失当前位置

证据：failed 保存 resumePosition，仅 refresh 成功加载时传入；refresh 请求失败后 resolveCurrent/attempt 未传位置。
实施：位置贯穿恢复、候选换源和缓存加载；保留暂停意图，正常手动换曲不带入上一首位置。
验收：模拟在 42 秒失败，刷新请求失败而其他源可用，最终 seek 42 秒；暂停与播放分别验证；快速切曲不受旧请求影响。

### B05 / P1：全局媒体键分支不可达

证据：`(data1 >> 16) & 0xF` 范围 0–15，switch case 为 16–19。
实施：按系统键码正确提取、按下/释放去重，与已有 MPRemoteCommandCenter 通道职责协调，避免一键触发两次。
验收：纯事件解码测试覆盖播放/下一首/上一首、释放和未知键；真实硬件媒体键若无法执行明确 NOT_RUN。

### B06 / P2：切搜索类型仍留在歌手详情

复现：搜索“洛天依”→歌手→洛天依Official→歌曲；选中类型变化、内容不变化。
实施：搜索类型、查询、平台、链接模式切换时清理不再适用的详情与任务；不发重复网络请求。
验收：该路径回到歌曲结果；旧详情慢响应不覆盖新结果；再次进入歌手详情可用。

### B07 / P2：切顶层页面丢失媒体库浏览状态

复现：本地→歌手→『ユイカ』→首页→媒体库，返回歌曲列表。
实施：本地/收藏维度、详情和滚动状态在所属窗口内保留；避免简单保留所有页面而造成持续不必要任务。
验收：切顶层页后回到相同维度与详情；本地/收藏切换不串状态；入库更新后的失效详情有合理返回。

### B08 / P2：原曲与实际音源标识混淆

复现：状态条“已切换音源：网易云”，底栏“Bilibili · AAC…”；原曲身份与解析来源读取不同对象。
实施：明示原曲/播放来源，缓存命中与解析中不虚标来源；播放页同一语义。
验收：原 B 站曲换到网易云时能辨别两种来源；正常播放与本地歌曲不显示无意义重复标签。

## 4. 优化任务

### O01：下载完成后的使用路径

增加播放和 Finder 定位入口；由保存的 fileName 与已拥有目录检查得到 URL，不信任任意路径。
播放本机文件应保留正确标题/歌手，文件不存在时给可理解错误，下载管理不重下文件。
验收：完成项显示两动作；缺失/越界路径不能当成功；删除与暂停/重试行为保持正确。

### O02：紧凑播放页与标题

修复加入歌单菜单横向撑满、播放页沿用“设置”等标题；在最小 720×480 和常见宽度验证。
菜单必须仍可添加现有/新歌单，歌词控制和底部核心播放动作不遮挡。

### O03：键盘和辅助功能

进度条增加调节动作和明确可访问值；队列条目能聚焦并用键盘跳播，移除有独立可访问名称。
不把全局空格快捷键抢占到搜索输入框；无时长或空队列的操作保持禁用。

### O04：持续绘制、统计和本地封面

Metal 命令队列复用，按页面/窗口可见性与系统减少动态效果决定绘制；不添加未经用户要求的大型性能框架。
下载状态每次刷新不并行启动全量目录遍历，合并节流，明确分类用量；完成/删除/清理后最终用量更新。
本地封面避免在每次 body 求值同步读文件，使用有容量上限的共享缓存/后台读取。
验收：结构上消除每帧命令队列创建与每个进度事件扫描；没有数据时正常显示；不宣称尚未测得的 FPS/功耗改善。

### O05：音频缓存配额与分类清理

提供默认 2 GiB 上限及淘汰；活动文件受保护；清理动作明确分别影响播放/封面。
历史无音质缓存、临时文件、元数据与完成文件的淘汰一致，不误删下载成品。
验收：小配额临时测试能淘汰旧文件，pin 文件不被清理；分类数字与动作一致。

## 5. Token 授权与无交互验证

本轮只读取签名元信息及可用签名 identity 列表，不读取/打印用户凭据。
当前应用 designated requirement 为 `cdhash`，当前机器 `security find-identity -v -p codesigning` 返回 0 valid identities。
这说明当前 ad-hoc 包依赖具体构建哈希识别；重建改变哈希，可能需要重新许可现有 Keychain 项。此为有依据的原因判断，不代表已检查每个凭据项的 ACL。

已有受保护条目没有合法的无授权绕过方法。通常长期方案是同一签名身份、同一 bundle identifier；用户将该应用加入“始终允许”后，后续匹配身份的版本可继续读取。
没有本机可用签名证书时，本轮不创建证书、不扩大 ACL、不导出 token 到明文文件。公证与 Keychain 访问许可是不同机制。
工程可采用禁止系统交互的读取选项，遇到需授权时返回清晰状态，显式登录/管理入口才触发需要用户处理的访问。
验证包使用独立的内存凭据与临时数据目录，真实公共音源测试无需读取用户 Keychain；不能据此声称私有收藏/已登录账户已验收。

参考：[Apple Keychain 授权说明](https://support.apple.com/en-euro/guide/keychain-access/kyca1243/mac)、[Apple Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/index.html)。

## 6. 统一验证及最终记录

顺序：子 agent 针对性回归→主 agent 集成编译→完整 swift test→lint→release 构建→保留旧包的独立验证打包→无凭据 UI/公共音源验证。
最终记录必须包含测试数、失败/跳过、包路径/构建号、实际二进制最低系统版本、未验证条目，以及用户原有改动是否保留。
2026-10-14 用户要求暂停后保留全部未提交成果；恢复时依用户要求由 `gpt-6-luna` / high 三个子 agent 接手 A/B/C，主 agent 统一集成。工作包报告：[音频](remediation-audio-result.md)、[扫描与媒体键](remediation-library-result.md)、[导航与 UI](remediation-ui-result.md)。

### 6.1 已执行验证

| 检查 | 结果 | 证据与范围 |
|---|---|---|
| Debug 编译 / 完整测试 | PASS | 835 项、10 项跳过、0 失败；`/tmp/neriplayer-remediation-tests-resumed.log` |
| 新增音频回归 | PASS | 音质隔离、实际档位读回、配额与 pin、取消写入、42 秒刷新失败换源且保持暂停 |
| 扫描真实调用链 | PASS | 两目录实际入库、首目录扫描失败后继续、规范路径去重、回调与设置批次隔离 |
| 导航/来源/滚动回归 | PASS | 本地与收藏独立状态、失效详情、实际 NSScrollView 挂载/重挂载恢复、同级横向容器隔离、导航分支移除/恢复、重叠候选排序、慢响应失效 |
| 下载/存储/本地封面 | PASS | 已完成文件归属与完整性、单独清理封面保留播放/下载、后台缩略图降采样与内容版本更新 |
| 真实公共平台 | PASS | 网易云 30 条、B 站 20 条、YouTube 29 条；三个来源解析和短时 mpv 解码通过；`/tmp/neriplayer-remediation-live.log` |
| SwiftLint / shell / diff / Python 语法 | PASS | 无 lint error；保留已有及部分新增 warning，非 strict lint；shell 语法、diff 空白和 Python 编译通过 |
| 旧包最低系统检查 | FAIL（正确检出） | 49 个二进制的闭包要求最高为 27.0，13.0 检查拒绝；auto 检查通过；`/tmp/neriplayer-compatibility-original.log` |

第一轮完整测试的 1 项失败来自测试注入故障时 URL 目录标记的相等判定：规范化后保证首目录确实删除，并保持“首失败、第二成功”的原断言。第二轮全量通过，没有放宽期望掩盖实现问题。

### 6.2 最终行为与范围

- B02–B08 已实施并通过上述回归；真实硬件媒体键仍为 NOT_RUN，生产媒体键统一由 MPRemoteCommandCenter 接收。
- B03 按请求平台档位建立缓存键，记录实际返回档位；旧未知音质条目不满足生产查询。缓存不存 signed URL、Cookie 或请求头。
- B04 使用 pendingRestore 在文件加载后恢复位置；取消代次与缓存 lease 隔离，原曲与实际播放源分别标识。
- O01 增加已下载文件播放/Finder 入口，先经 download actor 验证归属、大小和摘要。
- O04 命令队列复用、30 fps、不可见/最小化/减少动态效果暂停绘制；下载目录遍历合并到至多每秒一次；本地封面后台降采样、32 MiB/512 项缓存。没有测量或宣称功耗/FPS 提升百分比。
- O05 默认播放缓存 2 GiB，LRU 按同组元数据/成品/partial 淘汰，活动 lease 文件可暂时超限，释放后再收敛；下载成品不属于淘汰目录。播放与封面清理入口分开。
- B01 修复的是错误兼容性声明与打包检查：默认 13.0 检查无法通过就不输出包，auto 为明确的本机验证选择。**尚未重建 macOS 13 依赖闭包，旧系统支持没有恢复。** 本机 Homebrew libmpv 同样 minos 27，且有多项间接依赖要求 26/27；不是换一个 plist 字段即可修复。
- 打包在 `.build/package.*` 临时目录完成，通过后才移入输出目录；已有同名 app/DMG 保留为 `.previous-时间戳`，原 `dist/NeriPlayer.app` 本轮保持原样。
- 验证包使用 `.validation` bundle、独立临时数据根、VolatileCredentialStore，删除 URL Scheme 注册避免抢占正式包；本地媒体库采用 SQLite 一致性副本，无需用户 token。

最终验证包：`dist/remediation-20261014-validation/NeriPlayer.app`，0.1.0 / build 5；同目录 DMG 为 `NeriPlayer-0.1.0.dmg`。包内 49 个二进制闭包检查通过，实际最低系统版本为 27.0，ad-hoc 签名检查通过；日志 `/tmp/neriplayer-remediation-package-build5.log`，机器可读报告为同目录 `compatibility.json`。build 4 及之前验证包按 `.previous-*` 保留，原 `dist/NeriPlayer.app` 未替换。

实际界面已验证下载样本播放、0:45 时长、进度调节至 0:05，以及 Finder 定位到独立临时目录中的文件。build 5 的媒体库滚动返回、下载/设置页打开播放页的标题与紧凑菜单通过，具体记录见 6.3。旧系统真机、DAC/插拔、整首下载续传、已登录私有歌单、双端同步/一起听、完整 VoiceOver/键盘流程、最小窗口布局及长期稳定性仍为 NOT_RUN；现有 10 项 opt-in 跳过没有被记作通过。

### 6.3 实际应用复验与追加修正

第一份验证包打开后，实际 UI 复验发现：歌手详情状态已经保留，但本地大列表的滚动仍归零；播放页仍使用原页面标题。这两项没有因为单元测试通过而标为最终完成。
滚动原因是 SwiftUI 把 List 的 background 标记放在 NSScrollView 旁边，只有沿祖先查找不足；修正为优先直接祖先、再在宿主树中按纵向溢出与层级距离选择，并抑制恢复布局时的 capture。新增 NSHostingView + 真实 SwiftUI List + 同级横向导航容器的重建回归，而非仅测试手工组装的 NSScrollView。
后续再次实际复验仍发现滚动归零。最后一轮增加几何重叠优先、轴向与距离正确排序，拆卸时不重新 capture，并在离开页面前停止捕获以避免销毁过程写回零值。标题竞争追踪到隐藏子页的静态 navigationTitle，最后一轮为相关页面传入一致动态覆盖值。

2026-10-15 build 5 实际复验：本地歌曲列表点击滚动条下一页后出现《你的名字。》条目，滚动值约 0.003448；首页→媒体库后仍显示相同条目，滚动值约 0.003417（列表重新布局后归一化比例轻微变化），不再返回首行。分别从下载页、设置页点击底栏进入播放页，窗口 AX 标题及工具栏均为“正在播放”。加入歌单菜单按内容紧凑显示现有歌单与“新建歌单…”入口。未据此宣称完成最小窗口或完整辅助功能验收。

追加发现 B09：本机播放 16 kHz 单声道 WAV 时 CoreAudio 输出初始化返回 -50，普通音效应用路径把 ao 固定为 coreaudio，导致已下载文件无法播放。用同一文件对照 mpv 命令行，允许备用输出后可由 avfoundation 解码。
修正普通输出为 `coreaudio,`，优先 CoreAudio、失败时继续探测其他可用共享输出，独占仍保持原请求。该逗号语义见 [mpv 官方输出文档](https://mpv.io/manual/stable/#audio-output-drivers-ao)。没有用 null 输出伪装播放成功，未修改系统音频设备偏好。
输出命令计划新增回归断言；验证包已确认实际解码信息为 PCM_S16LE / 16 kHz / 1ch，时长 0:45，辅助功能 Increment 将进度从 0:00 调至 0:05。最后一次全量共 835 项、跳过 10 项、0 失败；lint 无 error，shell 语法与 diff 空白检查通过。界面验证结束后已退出隔离验证程序。
