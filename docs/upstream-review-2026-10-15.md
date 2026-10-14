# 上游更新与 macOS 移植调研（2026-10-15）

## 上游同步进度

原 Android 仓库从 `12351888e64178b145bc612b7d8e40efa7497d95`（2026-09-26，评论功能提交）快进到 `bf8bfe9ec093a745d8f1c6d82bd573acadfe7e8b`（2026-10-14，`#523`），沿 first-parent 新增 43 个提交。更新前的保留分支为 `codex/upstream-before-20261015`，指向旧提交。更新前后上游工作树均干净；原目录只快进到作者版本，没有添加本地业务改动，子模块已核对。

## 值得关注的变化

| 方向 | 上游近期变化 | 参考提交 |
| --- | --- | --- |
| 同步协议 | 引入 V4：Protobuf manifest/记录流、ZSTD 内容分块、对象哈希校验及旧协议迁移流程；大同步实现同时重构 WebDAV/GitHub 传输、缓存和启动加载。V4 不是旧 JSON/GZIP 快照的兼容扩展。 | [#475](https://github.com/cwuom/NeriPlayer/pull/475)、[#516](https://github.com/cwuom/NeriPlayer/pull/516) |
| 播放恢复与蓝牙 | 修复静音切换、设备路由恢复、陈旧播放错误；最新提交让蓝牙断开保持静默并修复 Nutstore 同步。 | [#519](https://github.com/cwuom/NeriPlayer/pull/519)、[#523](https://github.com/cwuom/NeriPlayer/pull/523) |
| 歌词 | 修正翻译匹配容差、重开正在播放页面时保留已加载歌词，并加入可选悬浮歌词预览和换行。 | [#507](https://github.com/cwuom/NeriPlayer/pull/507)、[#522](https://github.com/cwuom/NeriPlayer/pull/522)、[#510](https://github.com/cwuom/NeriPlayer/pull/510) |
| 下载与媒体库 | 恢复旧 HLS 检查点续传，稳定旧版升级状态与目录索引；整理播放、收藏和本地数据恢复。 | [#508](https://github.com/cwuom/NeriPlayer/pull/508)、[#499](https://github.com/cwuom/NeriPlayer/pull/499) |
| 音频效果 | 增加原生 DSP 效果，并加强 USB 独占输出。 | [#502](https://github.com/cwuom/NeriPlayer/pull/502) |
| 模块化 | 将应用及 native、playback、sync 等代码拆分为更清楚的模块边界。 | [#464](https://github.com/cwuom/NeriPlayer/pull/464)、[#467](https://github.com/cwuom/NeriPlayer/pull/467) |

这些提交显示上游最近的重心是同步存储/恢复可靠性、播放设备故障处理，以及继续拆分 Android 代码，而不只是新增界面功能。

## 与本 Swift 工程的同步协议差异

本工程的 [SyncSnapshotCodec.swift](../NeriPlayer/Core/Sync/SyncSnapshotCodec.swift) 可读 JSON 快照和旧 GZIP + Android Protobuf 记录，也接受旧版本 `1.0`/`2.0`；上传端编码为 JSON。GitHub 传输见 [GitHubSyncTransport.swift](../NeriPlayer/Core/Sync/GitHubSyncTransport.swift)。随仓库维护的 schema 也是 Android-compatible SyncData 2.0。

Android 当前 V4 则以 `NPSYNC04` 标记的 Protobuf manifest 描述 `main`、`legacy`、`pool` 流，记录拆成带原始/压缩哈希的 ZSTD 对象，协议号为 4、schema 为 1；首次迁移会要求用户确认。Swift 解码器没有 V4 manifest、ZSTD 分块或 V4 对象图的读写实现，因此当前不支持读写上游已升级到 V4 的同步目标。两端若共用同步地址，版本升级前应把这项差异作为互通阻断因素处理；本记录不规划协议迁移，也不建议在只升级一端后继续共用该地址。上游的 [同步模块说明](https://github.com/cwuom/NeriPlayer/blob/master/modules/sync/README.md) 记录了 V4 与旧格式迁移语义。

## macOS 项目调研

| 项目 | 技术与发布状态 | 对本工程的参考意义 |
| --- | --- | --- |
| [作者的 NeriPlayer-Desktop](https://github.com/cwuom/NeriPlayer-Desktop) / [Releases](https://github.com/cwuom/NeriPlayer-Desktop/releases) | 上游作者名下的桌面移植，Tauri 2 + Vue 3 + Rust，README 标为 Preview；发布页已有 macOS arm64 与 x64 DMG。仓库标注的打包最低版本分别是 arm64 macOS 11.0+、x64 macOS 10.15+，这不等于各版本均完成实机验证。 | 这是目前能确认的官方桌面方向，值得单独比较桌面交互和协议实现；并非 Swift/SwiftUI 移植。**本次未安装或实测该软件。** |
| [NeriPlayer-macOS（本项目）](https://github.com/GuZhengSVT/NeriPlayer-macOS) | SwiftUI 原生 macOS 工程，使用 libmpv、GRDB 等；当前配置要求 macOS 27.0+，发布为 Apple Silicon。 | 独立的原生 Swift 移植实验；同步代码仍停留在 Android 旧快照协议。 |

截至本次调研，使用 GitHub 仓库搜索检索 NeriPlayer/macOS/Swift（含 fork）并核对作者账号与已知仓库后，只确认上述本项目是独立 Swift 移植；未确认其他独立 Swift 移植。作者的 Desktop 仓库另有 fork，例如 issunmihaichi、ColdMoonBUG、Ericlu123456 的同名仓库；它们是已有桌面路线的派生，未确认是另一套独立 Swift 移植。检索使用 `NeriPlayer macOS in:name,description fork:true`、`NeriPlayer language:Swift fork:true`、`NeriPlayer-Desktop in:name fork:true`，结果以本次公开搜索范围为限。

## 本工程当前决策

本工程继续按 macOS 27.0+ 作为支持范围，README、Swift Package 部署目标和打包兼容检查已一致；这一要求与当前打包依赖的系统下限一致。作者 Desktop 项目的较低打包目标不自动改变本工程的依赖条件。上游 V4 变化仅作为同步兼容边界记录，不在此次更新中展开协议迁移或更改部署目标。


## 本地验证

macOS 27 部署目标下全量 `swift test`：835 项，跳过 10 项，0 失败；日志 `/tmp/neriplayer-macos27-tests.log`。SwiftLint 无 error；两个工作流的 actionlint、打包 shell 语法与 diff 空白检查通过。CI/Release 已切换为官方 `xcode-27` 镜像和 Xcode 27.0，来源为 [GitHub runner 镜像说明](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)。云端 CI 尚未触发。

常规运行版已生成：`dist/macos27-20261015/NeriPlayer.app` 和 `NeriPlayer-0.1.0.dmg`，0.1.0 / build 6。未使用 auto 或验证数据根；应用标识为 `moe.ouom.NeriPlayer`，运行时使用正式数据和 Keychain。主程序与包声明最低版本均为 27.0，49 个二进制依赖闭包通过默认 27.0 检查，ad-hoc 签名校验通过；未启动该包或访问账号凭据。日志 `/tmp/neriplayer-macos27-package.log`。旧包保留，本轮未提交或推送 macOS 工程、未发布 Release，也没有执行真实云同步。
