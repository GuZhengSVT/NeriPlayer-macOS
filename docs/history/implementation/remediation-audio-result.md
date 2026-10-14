# 音频整改结果

- B03：`ResolvedAudio` 保存请求档位与实际档位；三个平台 client 在解析时返回这两项。`PlaybackAudioCache.lookupAudio(_:quality:)` 按曲目和请求档位查找，缓存文件与元数据共同保留质量信息。新增回归覆盖低档缓存不能命中高档请求及同档读回实际档位。
- B04：`PlaybackStateStore.loadCachedAudio` 与解析加载接口都接收可选 `resumePosition`。运行时刷新失败后，恢复位置继续传到缓存加载、重新解析和替代音源；恢复加载沿用当前暂停状态。新增回归覆盖 42 秒处刷新失败、换至 Bilibili 后仍暂停。
- O05：缓存默认上限为 2 GiB，按最近使用顺序成组淘汰音频、元数据和临时片段；固定 pin 与播放 lease 保护活动曲目。新增小配额回归检查 pin 曲目保留且新来的未 pin 曲目被淘汰。
- 取消边界：缓存写入入口检查任务取消状态，避免已取消的旧传输创建缓存文件；传输层在交给缓存前也检查取消。新增取消写入回归。

接口：缓存构造支持 `capacityBytes`；`acquirePin`/`releasePin` 提供独立播放 lease；`lookupAudio` 返回包含请求档位和实际档位的 `ResolvedAudio`。

新增测试：`testCacheSeparatesQualityAndPersistsActualQuality`、`testCacheEvictsUnpinnedSongAndRetainsPinnedPlayback`、`testCancelledCacheRecordDoesNotCreateFiles`、`testFailedRefreshSwitchesSourceAtSavedPositionAndRemainsPaused`（`Tests/AudioRecoveryRegressionTests.swift`）。按分工未运行 SwiftPM/build/test；由主 agent 统一验证。真实平台网络、用户凭据和运行中应用未验证。
