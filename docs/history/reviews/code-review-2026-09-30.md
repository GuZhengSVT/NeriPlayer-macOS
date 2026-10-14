# 代码审查与验证记录（2026-09-30）

## 范围与方法

审查起点为 macOS 仓库 `9d3d88a`，开始时工作区干净。对照本地 Android `12351888e64178b145bc612b7d8e40efa7497d95` 与歌词子模块 `825661a10101b6b17cdcf8f39e0d5a12ff8d21fd`；在线上游 README 用于确认项目边界，不作为本仓库已实现功能的证据。

本次优先修数据损失、错误状态机、崩溃输入及文档与实现不符的问题；没有启动 M5–M9 的新功能开发。审查不是形式化验证，也不意味着消除了所有并发或格式兼容风险。

## 已修复

| 问题 | 原行为与风险 | 本次处理 / 回归 |
|---|---|---|
| 不完整扫描触发破坏性合并 | 外置盘掉线、根目录不存在、子目录拒绝访问可被当作空/部分目录，删除曲目并级联删除收藏/歌单 | 扫描结果显式标记 `isComplete`；不完整结果不裁剪缓存、不写封面、不合并 DB；真实完整空目录仍正常删除缺失记录 |
| 元数据读取权限/类型 | 不可读文件被降级为只有文件名的成功模型；远程 URL 的 path 可能误指本地文件 | 只接受可读本地普通文件；新增权限与 URL 回归 |
| 播放 Track 覆盖完整索引 | 简化 Track 的默认值会覆盖 album、cover、fingerprint、createdAt，且可能影响稳定 ID | 部分 upsert 仅更新播放字段，保留丰富字段和引用；补重复 URL 批次、封面回退与本地删除边界测试 |
| 已删除分组仍出现在详情 | 找不到最新歌手/专辑组时退回旧快照，造成已移除歌曲重新显示 | 最新数据中缺失则显示空；外部删除的歌单清除详情 ID |
| 把 core-idle 当 EOF | 暂停/缓冲可能误切歌；继续播放可能重新加载 | 桥接 MPV_EVENT_FILE_LOADED / END_FILE，以 entry ID 匹配，只有自然 EOF 自动推进；停止、替换不算 EOF |
| 恢复现场污染新曲 | 文件未就绪时 seek 或旧 pending restore 留给之后选中的曲目 | 等显式 loaded；pending 绑定曲目 ID；新加载/清队列取消 pending；空恢复停止旧播放 |
| 暂停恢复短暂出声 | load 默认播放，等后续事件才 pause | MPV load 支持预先设置 pause；启动音量也在恢复前应用；真实 libmpv 测试验证暂停态就绪与 seek |
| 现场清除/失败重试 | 初次空快照被当作已成功清除；失败后可能不重试；写入可并发乱序 | 区分未写入/成功写入；写锁串行化；成功后才提交 lastWritten；元数据变化纳入签名；停止后拒绝旧订阅 |
| 统计退出计时与计数 | stop 后仍可能继续计时；符合阈值的播放次数未在最后 flush 结算 | 先关闭订阅代次并结束计时，串行 flush 与阈值结算；新增停止后不增量/退出计次测试 |
| 事件回调线程析构 | 在 mpv 自己的事件队列 queue.sync 可能死锁/崩溃 | 队列标识判定；回调退出后由事件循环释放句柄，不对自身同步 |
| 设置变化不驱动根窗口 | AppState 观察的是子对象引用，不是子对象字段 | 转发 settings objectWillChange；补根观察回归 |
| 安全模式永不退出 | 没有消费历史异常的应用级生命周期路径 | 正常退出只确认本次启动读到的同一份异常；不吞掉本次新异常；播放引擎失败也保留退出清理 |
| 歌词整数溢出 | 大时间戳、偏移、duration 等 Int 运算可直接 trap | 对解析和模型运算使用饱和算术与安全进度计算，极值回归 |
| TTML/XML 文本破坏 | 实体双重解码、翻译未转义、混合文本/span 顺序丢失 | 一次实体解码，命名/数值实体、转义、混合顺序、引号内分隔符与 Unicode 回归 |
| Vendor 脚本假成功 | 不完整产物也跳过、改写 install_name 失败被吞掉 | 幂等检查要求有效链接入口、rpath ID 与签名；改写/签名失败非零退出；防止重定向目录破坏 |

主要回归位于 `Tests/AppStateTests.swift`、`Tests/PlaybackLifecycleRegressionTests.swift`、`Tests/LyricsSafetyRegressionTests.swift`，以及既有 Library、PlaybackSession、PlaybackStatsRecorder、PlayerEngine、AudioMetadataReader 套件。

## 构建与验证

环境：Apple Silicon，Apple Swift 6.4，Xcode 工具链，当前 vendored libmpv；未切换原仓库依赖。

- `swift test`：536 条 XCTest 用例通过，0 failures；随后 `swift test --skip-build` 再次通过。输出末尾 Swift Testing 的“0 tests”来自未使用的另一套测试框架，不代表 XCTest 没运行。
- `swift build -c release`：成功，但有下述平台版本警告，不能称为零警告发布构建。
- `Tools/run-swiftlint.sh`：无 error，仅 `Repositories.swift` 的既有 file_length 类别告警；本轮新增的大文件通过拆分启动选项和测试替身收敛。
- `actionlint .github/workflows/ci.yml`、`bash -n Tools/fetch-mpv.sh`、`git diff --check`：通过。
- `Tools/fetch-mpv.sh`：本机已有有效产物的幂等路径通过；未进行干净 Homebrew 安装或 `--force` 全量重布置验收。
- 最初测试因执行沙箱拒绝 SwiftPM 失败；后续运行又碰到并行写入的中间编译状态。以上成功结果为集成修正后运行，不把失败或中间日志冒充原始基线。
- 未重跑历史文档声称的 21 轮压力测试；没有执行新的 GUI 截图、真实媒体键、DAC、长期播放、权限撤销或 kill/restart 误差验收，也没有实际运行 GitHub Actions。

### 发布阻断项：实际动态库最低版本

`xcrun vtool -show-build Vendor/mpv/lib/libmpv.2.dylib` 显示当前副本的 **minos = 27.0**，而 Package.swift 声明 macOS 13。链接器明确报告版本不匹配。

保留 macOS 13 作为产品目标，不通过抬高版本或屏蔽 warning 掩盖问题。发布前需要使用针对目标系统构建的 libmpv **及其整个依赖闭包**，再在最低系统和 Intel/Apple Silicon 上验证。当前副本仍依赖 Homebrew 绝对路径，不能作为可分发包。

## 文档纠偏

新增 README，区分实际能力、规划和开发环境；修正“目标仓库已清空”、Swift 5.10 足够构建、2 秒阈值保证 ±3 秒恢复误差等说法。明确顺次淡入淡出不是真正重叠 crossfade；CoreAudio IOProc、mpv AO、直接 libusb 不可混成一个已经验证的独占方案。历史验收文件保留为历史记录，本轮证据另列，不伪造真机结果。

## 后续优先级

1. **发布与可复现构建**：固定工具链和二进制依赖，建立兼容最低系统的依赖闭包；补 `.app`、沙盒/签名/公证、许可证/来源清单。
2. **播放并发与恢复**：真实异步快速切歌、同 URL 重载、EOF 与用户操作竞争、退出 flush 的进程级测试；核心仍有锁与同步回调混合，并非全面 actor 化或并发安全证明。
3. **媒体库权限**：沙盒下跨启动书签/外置盘/权限撤销、扫描取消与多目录重扫；当前完整性保护采用整次拒绝策略，可能需要后续明确的“保留旧数据并部分更新”产品设计。
4. **歌词边界**：重叠长行查找、LRC offset 的唯一应用层、CDATA/命名空间/深度上限、音译及伴唱完整导出；再接来源与界面。
5. **应用体验**：可见错误恢复、统计页与真实媒体键/UI 性能验收；首页/探索/下载仍为占位，不应据测试数量判断迁移完成度。

本次未自动提交 git，修改保留在工作区供审阅。
