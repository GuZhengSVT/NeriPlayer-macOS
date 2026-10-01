# M7 同步与备份移植笔记

## Android 对照

本次直接读取并对照本地 Android checkout `12351888e64178b145bc612b7d8e40efa7497d95`，没有启动新子代理。主要参考：

- `data/sync/model/SyncDataModels.kt`、`SyncCausalToken.kt`：SyncData 2.0 字段、毫秒时间戳、signed Int64 标识、逐设备统计分片和因果 membership token。
- `data/sync/github/SyncDataSerializer.kt`：JSON、原始 GZIP(ProtoBuf)、历史 Base64(GZIP(ProtoBuf)) 和旧 song 字段编号回退。
- `SyncPlaylistSongMergePolicy.kt`、`SyncPlaylistDeletionPolicy.kt`、`SyncSongMetadataMergePolicy.kt`：单侧修改、并发增量合并、删除墓碑、版本化元数据和旧顺序迁移。
- `SyncPlaybackStatsMergePolicy.kt`、`SyncPlaybackStatMapper.kt`：同设备计数取最大，不同设备分片求和；旧统计取最大；日桶先抬升总数，再按数据集锚点裁剪。
- `GitHubRepositorySyncTransport.kt`：固定 head 读取、binary blob、Git tree/commit、非强制更新分支。
- `WebDavSyncManager.kt`：远端冲突重新读取；在途本地修改存在时禁止应用旧合并结果。
- `data/model/SongIdentity.kt`、`data/platform/youtube/YouTubeMusicSupport.kt`、`core/api/bili/BiliSongResolver.kt`：SHA-256 前八字节 signed ID、YTM URI、B站 aid/cid/BV 旧字段。

上游源码含 GPL-3.0-or-later 声明；发布前仍需统一处理本项目许可证及来源/署名，M7 不替代该工作。

## 格式与持久化

[JSON Schema](sync-snapshot.schema.json) 由同一份 Android 字段定义生成，避免文档与 wire 编号独立演进。快照的旧字段允许缺省；已知字段类型错误会拒绝整份数据，JSON 的未知字段保留，未知 ProtoBuf tag 跳过。所有数值使用 Int64，不经 Double 中转。

上传统一使用 JSON。读取 JSON 上限 8 MiB、压缩输入 12 MiB、解压输出 16 MiB，解码嵌套深度有上限。系统 zlib 负责 GZIP 的校验和有界解压；不启动 shell 解压器。ProtoBuf 是只读兼容层，不提供 macOS 省流上传选项。

GRDB v5 新增 `SyncJournal` 与 `SyncRevision`。相关业务表的 INSERT/UPDATE/DELETE 触发器更新 revision，因此扫描、歌单操作和统计连接都会被在途修改检查覆盖。稳定设备 ID、计数器、UUID→Android Int64 歌单 ID、快照及统计观测基线与业务数据在同一数据库事务中保存。

同步过滤本地音频路径和本地封面；用户本地文件收藏、历史、统计不受远端在线数据清空影响。导入的 Android 歌词、自定义元数据及本阶段没有编辑 UI 的扩展字段保存在 journal 中。未知平台记录不进入播放器，但保留在快照中。

在线条目入库后，库/歌单投影根据稳定 identity URL 恢复 `SongData`，不会把它当成本地文件交给 mpv。B站先查 video metadata 得到 aid/cid，再存稳定 `av<aid>:cid:<cid>` 标识；Android 数字 aid/cid 与已有 BV+分P 路径均可解析。

## GitHub

设置页支持已有 PAT 或 OAuth access token 的导入，不包含浏览器 OAuth 授权回调或 device-flow 客户端。令牌由 `moe.ouom.NeriPlayer.sync` Keychain service 保存，UserDefaults 只存非敏感配置。

默认仓库名 `NeriPlayer-Backup`，可修改。创建仓库只针对当前令牌用户，默认私有并初始化分支；操作必须由用户点击。已有仓库不会自动创建或修改可见性。令牌需要相应仓库读写权限；创建仓库还需要账户层面的创建权限。

读取仓库默认分支的固定 head，合并仓库内现有 JSON/二进制同步快照。上传通过 blob→tree→commit→非强制 branch ref 更新完成。旧二进制同步文件在同一个提交中删除，Android 省流读路径可回退至 JSON，避免多文件保留不同状态。其他仓库文件与历史不改动。远端 head 变化最多重新读取并合并两次，不 force push。

## WebDAV

配置是完整 HTTPS 快照文件 URL（例如已有目录下的 `NeriPlayer/backup.json`），不是服务器根目录；本阶段不自动 MKCOL。用户名、URL 保存到设置，密码进 Keychain。

GET 404 表示首次创建，PUT 使用 `If-None-Match: *`。已有文件使用强 ETag 的 `If-Match`；409/412 冲突重新读取。相较 Android 的部分服务器兜底，macOS 对没有强 ETag 的已存在文件拒绝盲写，不宣称兼容所有 WebDAV 实现。默认会话阻止重定向、禁用 Cookie/缓存，避免凭据转发到其他端点。

## 本地备份

本机备份格式是 `neriplayer-macos-backup-envelope`，不与 Android 全量备份互换；跨平台交换使用同步快照。备份包含媒体库、歌单/条目、收藏、历史、统计/日桶、播放现场、流量统计、同步 journal 和允许的应用设置。不打包音频、封面文件、缓存、下载任务工作区或登录凭据，也不包含同步配置/Keychain。文件路径和安全作用域书签是本机引用，换机仍需重新授权音乐目录。

payload 使用 SHA-256 验证完整性（不是加密或来源认证）。恢复前检查大小、格式、版本、设置类型、表/列名、SQLite 约束和外键，在独立数据库试恢复；随后用 revision 守卫的事务恢复业务表，并清除旧目标同步时间。设置仅在数据库恢复成功后应用。UI 要求用户确认，恢复前停止播放和统计/现场录制，恢复后刷新媒体库和设置。

## 验证边界

[兼容夹具](../Tests/Fixtures/Sync/android-compatible.json) 根据 Android 当前模型和兼容测试手工构建，不是手机导出的真实文件。本地没有现成 Android backup JSON，也没有 Kotlin CLI 用来独立执行 Android serializer；真实手机导出 golden 和 GitHub/WebDAV 双端实测仍待补齐。

没有使用真实令牌或创建用户云端资源。所有 HTTP 合约测试使用 URLProtocol；原生设置页用临时数据库、独立 UserDefaults suite 和内存凭据渲染。自动验证结果及截图见 [M7 验收记录](acceptance/m7.md)。
