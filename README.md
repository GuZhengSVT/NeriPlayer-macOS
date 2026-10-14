# NeriPlayer macOS（已归档）

本项目于 **2026-10-15** 归档，停止维护，不再发布新版本或接受功能、修复承诺。

## 归档原因

这个项目曾尝试使用 SwiftUI、libmpv、GRDB 和 TagLibSwift，将 NeriPlayer 的多源播放、本地媒体库、歌词与自建同步带到原生 macOS。

原作者现在已经维护官方桌面端 **[cwuom/NeriPlayer-Desktop](https://github.com/cwuom/NeriPlayer-Desktop)**，面向 Windows、macOS 和 Linux，并提供 macOS Apple Silicon 与 Intel 安装包。原生移植实验已经完成其历史使命，因此本仓库结束开发，作为源码与技术记录保留。

继续使用 NeriPlayer 桌面端，请前往：

- [官方桌面端仓库与使用说明](https://github.com/cwuom/NeriPlayer-Desktop)
- [官方桌面端下载 / Releases](https://github.com/cwuom/NeriPlayer-Desktop/releases)
- [原 Android 项目](https://github.com/cwuom/NeriPlayer)

官方桌面端采用 Tauri、Vue 和 Rust；它与本仓库是独立工程。本仓库的历史构建不再作为推荐下载入口。

## 归档内容

- [文档索引](docs/README.md)：核心整改、上游调研，以及分类整理的历史规划、实现与验收记录。
- [独立整改与验收记录](docs/remediation-2026-10-14.md)：问题证据、实施边界及最后一次实际界面验证。
- [上游更新与桌面移植调研](docs/upstream-review-2026-10-15.md)：原作者近期变更、官方桌面项目及同步协议差异。
- Swift 源码、回归测试、依赖锁定、图标源文件与重建工具保留；构建产物、机器缓存和运行数据不入库。

旧文档中的计划、PASS 和 NOT_RUN 只描述相应时间的历史状态，不代表持续维护或对当前第三方平台的兼容保证。旧规划不再是待执行任务。

## 最后技术状态

归档前支持目标统一为 **macOS 27.0+ / Apple Silicon**，不支持 macOS 13–26，Intel 未验证。最后一次全量测试共 835 项，跳过 10 项，0 失败；常规 build 6 的 49 个二进制依赖闭包及 ad-hoc 签名检查通过。人工与账号相关的未验证项见验收记录。

本仓库仍使用旧 JSON/GZIP/ProtoBuf 快照同步方式，**尚未适配新版 Android 的 V4（Protobuf 记录流与 ZSTD 分块）协议**。不要把历史 Android 兼容描述用于已迁移 V4 的同步地址；使用官方桌面端前请阅读其版本、同步和迁移说明。本次归档没有迁移或改写远端歌单数据。

CI 与自动 Release 工作流已移除，不再触发后续构建或发布。确需研究历史实现时，可克隆归档仓库，并参考 `Package.swift`、`Tools/` 和历史实现笔记在本地重建；仓库不提供后续运行支持。

## 许可证与致谢

项目继续按 [GPL-3.0](LICENSE) 保留；第三方组件的来源与许可说明见 [历史实现笔记](docs/history/implementation/)。感谢原作者 [cwuom](https://github.com/cwuom) 及 NeriPlayer 社区。
