# 设置页切换卡顿：定位与修复（2026-10-02）

范围：设置分类导航与滑杆布局。先定位与修改源码，再由主智能体与其他页面一起统一构建 / 测试，未提交。

## 1. 现象与测量

在 `dist/NeriPlayer.app`（0.9.0 (3)，pid 89977，macOS 27.0.1，Apple Silicon）上直接操作并采样：

- 切页采样 `/tmp/neri-burst2.txt` 中，主线程大量落在 `NSView` 布局、SwiftUI `DisplayList.ViewUpdater` 与 `NSSliderCell` 路径，包含 `_rebuildTickMarkRectCache`。空闲采样 `/tmp/neri-idle-settings.txt` 未出现该刻度重建调用。
- 分类切换的工具往返时间受 CUA 观测与背景绘制影响；不能把整个进程 CPU 或工具调用耗时当作用户可见切页延迟。这里仅用调用栈定位具体热点，不公布未经基线扣除的“每次切换成本”。

## 2. 根因（有证据部分）

1. **分类切换的布局开销。** 设置页在主导航里又嵌了一个 `NavigationSplitView`，详情树在分类切换时替换，采样显示大量 `NSView` 布局调用。嵌套导航和转场可能放大这部分成本；本次改为稳定双栏并禁动画，但采样本身不能证明全部布局成本都由嵌套导航造成。
2. **带 step 的 Slider 触发刻度绘制。** 「通用」的启动音量是 `Slider(in: 0...100, step: 1)`，
   「播放与音质」的 10 段 EQ / 音量为 `step: 0.5`、淡变为 `step: 100`。macOS 上带 step 的 Slider 会
   让 AppKit 为每个刻度画 tick mark（0–100 即 101 个）。`_rebuildTickMarkRectCache` 仅在切页时出现，
   是音效页的一个确定热点。
另修复账号状态观察问题：`SettingsView.onlineViewModel` 原为普通 `var`，读取不建立订阅，账号异步加载后不保证刷新。这是状态显示问题，不把它归为已测量的切页卡顿原因。

未列为根因：网络 / 账号请求。设置页各视图模型是内存操作，切页路径上没有同步 IO；本次未观察到切页期间
有账号或推荐请求，故不把切页卡顿归因到网络加载。

## 3. 修改

- `SettingsView.body`：去掉嵌套 `NavigationSplitView`，改为稳定 `HStack`（`categoryList` + `Divider` +
  `categoryDetail`）；详情用 `.transaction { $0.disablesAnimations = true }` 关闭隐式动画。
- `SettingsView` 启动音量：去掉 `Slider` 的 `step: 1`，吸附改到 `volumeBinding`（`\$0.rounded()`），
  取值粒度不变、不再画刻度。
- `AudioEffectsSettingsView`：去掉全部 `Slider(step:)`（EQ / 响度 / 淡入 / 淡出 / 交叉淡变），
  用 `AudioEffectSliderStep.half` / `.hundred` 在 setter 里吸附，粒度与原先一致。
- 新增 `AccountSettingsSection` 子视图：用 `@ObservedObject` 订阅账号状态，`.task(id: model.source)`
  只调用 `loadAccountContent()`（不拉推荐 / 歌单）；含加载指示与账号错误文案。
- 「网络与下载」在线服务入口文案「打开探索」→「打开搜索」（`SettingsDestination.explore` 现指向搜索页）。
- 测试：`Tests/SearchPageTests.swift` 的 `testAccountContentLoadsAccountWithoutBrowsingData`，
  断言 `loadAccountContent()` 只请求账号、不请求歌单 / 推荐，并能读到账号名。

## 4. 未做 / 边界

- 统一测试 738 项（6 项跳过、0 失败）、lint / Release 打包完成；最终应用为 `0.9.0 (5)`。
- 修复后在实际应用反复切换通用 / 音效页，采样 `/tmp/neriplayer-settings-after.txt` 中已无 `_rebuildTickMarkRectCache`。仍存在布局 / 背景绘制调用；不同轮次的窗口尺寸、切换节奏与采样长度不完全一致，未形成严格的总耗时改善百分比。
- Metal `HyperBackgroundView` 在主线程有持续绘制开销（空闲采样可见），但那与切页无关，本次未改动。
- 此处只记录设置导航与滑杆的修改；其他页面和播放栏变更见同日页面验收记录。
