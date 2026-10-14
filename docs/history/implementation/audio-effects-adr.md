# ADR：音效引擎方案（EQ / 响度增强 / 淡入淡出）

- 编号：M1-T8（决策基线供 M8-T4 落实）
- 状态：已接受（Accepted）
- 日期：2026-09-27
- 范围：只定方案与接口草案，**不实现 EQ**，不写 Swift 源码
- 关联任务：M1-T8（本记录）、M8-T4（音效系统，落实本决策）、M8-T6（USB 独占）、M8-T3（流体背景 / 未来音频 beat 响应）
- 参考实现：Android 侧 `core/player/effects/PlaybackEffectsController.kt`、`core/player/effects/AudioReactive.kt`、`core/player/model/PlaybackSoundModels.kt`、`PlayerManager`（fade / crossfade 部分）

> 审查补充（2026-09-30）：以下探针为历史记录，本轮没有重新进行音效/硬件验证。顺次淡出再淡入不是重叠 crossfade，不应以“交叉淡入淡出已支持”宣传。自定义 IOProc、直接 libusb 和 mpv 自带 AO 是不同架构；IOProc 本身不构成独占保证。M8-T6 必须另行验证路由、设备占用、采样率与退出恢复，不能从此 ADR 推出已兼容。

> 本文是 M8-T4 的实现基线。M8-T4 开工前若有异议，应先修改本文件再动代码，而不是在实现里另起一套。

---

## 1. 背景

Android 版音效由三块组成，各自独立：

1. **均衡器（Equalizer）**：系统 `android.media.audiofx.Equalizer`，绑定音频会话 ID，最多 5 段（默认锚点 60 / 230 / 910 / 3600 / 14000 Hz），提供 23 个预设 + 自定义频段，增益量程 ±1500 mB（±15 dB）。预设以 5 个锚点增益做对数插值后落到实际频段。
2. **响度增强（LoudnessEnhancer）**：系统 `android.media.audiofx.LoudnessEnhancer`，目标增益 0~1500 mB（0~15 dB）。
3. **淡入淡出 / 交叉淡入淡出**：不依赖系统音效 API，在播放控制层按时长分步改 `player.volume`（`fadeStepsFor = durationMs/40`，钳制 4~30 步）。

macOS 没有 ExoPlayer 的音频会话与 `AudioEffect` 绑定机制，也没有等价的系统级 EQ 会话 API。macOS 侧播放内核是 libmpv（M1 已落地：`MPVController` / `MPVEngine`，libmpv 0.41.0，API 2.5），因此音效必须建立在「libmpv 的音频链路」或「自建音频链路」之上。本 ADR 要回答的正是：macOS 版把音效挂在哪一层。

同时 M8 还有两个约束会与本决策强耦合：

- **M8-T6 USB 独占**：计划用自定义 CoreAudio IOProc（复用参考仓库的 libusb 代码）直连 DAC 做独占输出。独占路径会绕过普通混音，任何「在系统混音层做音效」的方案都会失效。
- **M8-T3 音频 beat 响应**：任务表当前明确「不做音频 beat 响应（后续）」，但后续做时需要有可用的音频电平/频谱数据来源，方案选型不能把这条路堵死。

## 2. 目标与非目标

**目标**

- 让 10 段 EQ（预设 + 自定义频段）、响度增强、淡入淡出、交叉淡入淡出有一个统一、可测试、可维护的落点。
- 决策必须与 M8-T6 USB 独占路径兼容，并与 M1-T7 的输出设备切换（mpv `audio-device`）不冲突。
- 明确 EQ 参数模型（10 段预设 + 自定义）到选定方案的完整映射规则，使 M8-T4 可以直接照做。
- 给出 `AudioEffectsController` 的接口签名草案（只签名，不实现）。

**非目标（本 ADR 不做）**

- 不实现任何音效算法、不写 Swift 源码、不改现有源文件。
- 不做 DSD、不做空间音频 / HRTF、不做解码后重采样链的自定义。
- 不做 M8-T3 的 beat 响应本身；只评估数据可得性。

## 3. 备选方案

### 方案 A：mpv 回读 PCM → AVAudioEngine → 输出

思路：把 mpv 的 `audio-output` 切到能吐出 PCM 的后端（形如 `lavc` / `pcm`），在 Swift 侧读到 PCM，送入 AVAudioEngine 的处理链（EQ / 响度 / 淡入淡出都在 AVAudioEngine 做），再由 AVAudioEngine 输出到设备。

### 方案 B：纯 mpv `af` 链（lavfi 滤镜）实现 EQ

思路：全部音效都在 mpv 的音频滤镜链上做。EQ 用 mpv 自带的 libavfilter 滤镜（`equalizer` / `anequalizer` / `firequalizer`，可经 `lavfi=[...]` 调用），响度用 lavfi `loudnorm`/`volume`，淡入淡出用 lavfi `afade`；都由 `af` 属性（运行期 `set_property af`）驱动。

### 方案 C：混合（EQ 走 mpv `af`，系统级效果走播放控制层）★ 采纳

思路：分工而非二选一。

- **EQ**：走 mpv `af` + lavfi（同方案 B 的 EQ 部分）。
- **响度增强**：由播放控制层实现，作用点是 mpv 的属性层 `volume-gain`（dB 增益）——控制层负责量程、钳制与下发，增益本身由内核施加，不塞进 EQ 滤镜链、也不做 PCM 处理。
- **淡入淡出**：走播放控制层，按时长分步改 mpv `volume`（对齐 Android 的 `fadeStepsFor` 做法）。
- **交叉淡入淡出**：基线用「淡出 → 换曲 → 淡入」的顺次近似（无重叠）；真正的重叠淡变作为后续增强，预留 `lavfi-complex` 路径。

> 命名说明：本 ADR 把「mpv `af` 滤镜链」与「mpv 属性层（`volume` / `volume-gain`）」统称 mpv 侧；「播放控制层」指 NeriPlayer 自己的 Swift 控制逻辑（定时器 / 任务 + 调用 mpv 属性）。方案 C 的关键是**不引入第二条音频链路**。

> 相对原始描述的一处细化：任务里方案 C 写作「系统级效果（响度增强 / 淡入淡出）用播放控制层实现」。本 ADR 把「控制层实现」进一步落到具体机制——淡变直接改 `volume`，响度则改 `volume-gain`。这样响度与淡变作用在不同的属性上，互不覆盖（若两者都改 `volume`，淡变结束时的收尾赋值会把响度增益覆盖掉）。这与原意一致，只是明确了载体。

## 4. 评估维度对比

| 维度 | 方案 A（PCM 回读 + AVAudioEngine） | 方案 B（纯 mpv `af`） | 方案 C（混合）★ |
|---|---|---|---|
| 音频延迟 | 高。需自建环形缓冲与音频时钟；mpv 依赖 AO 回报的延迟做 A/V 同步，自建 sink 会破坏该约定，易累积漂移 | 低。滤镜在 mpv 音频链内串联，IIR 峰值滤波器本身几乎不引入延迟 | 低。同 B；淡变只是属性阶梯，不额外缓冲 |
| 实现复杂度 | 高。要写 PCM sink、时钟、seek 冲刷、设备管理、重采样 | 低。构造 `af` 字符串 + `set_property af` | 低-中。EQ 同 B；淡变是控制层的分步循环 |
| 与 M8-T6 USB 独占兼容 | 差。独占要求自有 IOProc 直连设备，而 AVAudioEngine 走 CoreAudio HAL 混音；两条路互斥，等于要把独占也重写进自建链 | 好。滤镜在 AO 之前，对任何 AO 都生效（含 `coreaudio_exclusive`） | 好。同 B |
| 与 M1-T7 输出设备切换兼容 | 差。设备切换归 AVAudioEngine 管，mpv 的 `audio-device` 失效，M1-T7 需推倒 | 好。不触碰 AO 选择 | 好。不触碰 AO 选择 |
| 音频 beat 数据可用性（M8-T3 后续） | 好（进程内有 PCM）。但代价是必须承担 A 的全部复杂度 | 好。可用 `astats` 探针（`af-metadata`）拿 RMS/峰值，无需 PCM | 好。同 B，且与 EQ 共链、零额外链路 |
| 维护成本 | 高。多一套需长期维护的音频子系统 | 低。依赖 ffmpeg（libmpv 已内置） | 低。只多一个控制层渐变工具（Android 已有等价实现可照搬） |
| 依赖风险 | 中。需确认存在可用的实时 PCM 后端 | 低。libavfilter 由 libmpv 自带 | 低。同 B |

### 实测证据（本机 arm64，mpv 0.41.0 / FFmpeg 9.0.2）

以下结论均在当前 checkout 的机器上实跑得到，命令与结果摘录如下。

1. **本 build 没有 `lavc` AO，`pcm` AO 也不是实时后端**

   ```
   $ mpv --ao=help
     coreaudio / avfoundation / null / coreaudio_exclusive / pcm

   $ mpv --no-video --ao=lavc /tmp/probe.wav
   [ao] Failed to initialize audio driver 'lavc'      # 不可用

   $ /usr/bin/time -p mpv --no-video --ao=pcm --ao-pcm-file=/tmp/x.wav /tmp/6s.wav
   real 0.12                                          # 6 秒素材 0.12 秒写完 ≈ 全速
   ```

   即方案 A 里「回读 PCM」的实际形态是**写文件/FIFO**，且是离线全速，不是实时流。要喂给 AVAudioEngine 必须自己造实时节拍与缓冲，这正是方案 A 复杂度与延迟的来源。

2. **mpv `af` + lavfi EQ 可用，且运行期可换**

   ```
   $ mpv --no-video --af='lavfi=[equalizer=f=1000:t=o:w=1:g=6]' --ao=pcm --ao-pcm-file=/tmp/eq.wav /tmp/probe.wav
   $ ffmpeg -i /tmp/eq.wav -af volumedetect -f null -     # 输出电平较基线抬高，滤波确实生效

   # 10 段全 +6 dB：mean -15.8 dB；全 0（Flat）：mean -24.1 dB（与原始基线相同 = 恒等）

   # 运行期热切换（playback 中）
   > {"command":["set_property","af","lavfi=[volume=0.25]"]}
   < {"request_id":0,"error":"success"}
   < {"data":[{"name":"lavfi","enabled":true,"params":{"graph":"volume=0.25"}}]}
   ```

   日志里可见 `[swresample] format change, reinitializing resampler` 与滤镜图重建，说明**换 `af` 会重建滤镜图**（见「影响」里的抖动风险）。

3. **响度增强可用 mpv `volume-gain`，量程可放宽**

   ```
   $ mpv --no-video --idle=yes --volume-gain-max=20 --input-ipc-server=$SOCK --ao=null
   > {"command":["set_property","volume-gain",15]}    < error: success
   > {"command":["get_property","volume-gain"]}       < data: 15.0
   > {"command":["get_property","volume-gain-max"]}   < data: 20.0
   ```

   注意 `volume-gain-max` 默认 12 dB，低于 Android 的 15 dB 上限；落地时需在初始化显式抬高（见第 7 节）。

4. **beat / 电平数据可由 `astats` 探针提供，无需 PCM**

   ```
   $ mpv --af='@meter:lavfi=[astats=metadata=1:reset=1]' ...
   > {"command":["get_property","af-metadata/meter"]}
   < {"lavfi.astats.Overall.RMS_level":"-24.088752", "Peak_level":"-21.07", ...}
   ```

   `astats` / `aspectralstats` / `ebur128` 在本 build 的滤镜表里均存在，后续做 beat 时可在 `af` 链末端挂探针，不必回到方案 A。

5. **真正重叠的交叉淡变需要混流，mpv 有路径但复杂**

   ```
   $ mpv --lavfi-complex='[aid1]volume=0.3[a1];[aid2]volume=0.3[a2];[a1][a2]amix=inputs=2[ao]' two-track.mkv
   # 可用：两条音频轨被 amix 混为一路输出
   ```

   可行，但要求两首歌同时作为同一 mpv 实例内的可用轨道并手工管理滤镜图，与现有单文件播放 + 队列结构冲突较大，故不进基线。

6. **独占 AO 存在**：`mpv --ao=help` 含 `coreaudio_exclusive`（对方案 B/C 有利；与 M8-T6 自建独占并存的细节见第 9 节）。

## 5. 决策

**采纳方案 C（混合）：EQ 走 mpv `af` + lavfi；响度增强走 mpv `volume-gain`；淡入淡出 / 交叉淡变在播放控制层实现。**

具体口径：

- 不引入 AVAudioEngine，不留第二条音频链路，不接管 mpv 的 AO。
- EQ 作为**一个命名 `af` 滤镜**挂入 mpv 链，参数变化时重建该滤镜（`set_property af`）。
- 响度增强不塞进 EQ 滤镜，独立用 `volume-gain`（dB），从而与淡变用的 `volume` 互相独立、互不覆盖。
- 淡入淡出用控制层的分步改 `volume`（对齐 Android 的 40 ms 步长、4~30 步）。
- 交叉淡变基线为**顺次近似**（淡出 → `loadfile` → 淡入）；真正的重叠淡变登记为后续增强（`lavfi-complex` 路径）。
- 每条设置变更都经 `MPVController`（M1-T2 既有 API：`setString` / `setDouble` / `getString` / `command`），**无需新增任何 C 桥接或原生代码**。

## 6. 理由

决定性的是**独占路径的兼容性**。M8-T6 要求自建 IOProc 直连 DAC，独占时会绕过系统混音；而方案 A 把音效放在系统混音侧（AVAudioEngine），两者在架构上互斥——要么放弃独占，要么把独占也重写进自建链，代价失控。方案 C 的音效位于 mpv 的 AO **之前**，因此对 `coreaudio`、`avfoundation`、`coreaudio_exclusive`，以及未来自建独占 AO 都同样生效，天然满足 M8-T6 的前置条件。M1-T7 的设备切换也因此完全不受影响。

其次，方案 A 的「回读 PCM」在本 build 上并不存在实时形态：没有 `lavc` AO，`pcm` AO 是离线全速写文件。要实现它必须自建环形缓冲与音频时钟，还要处理 seek 冲刷和音画同步——这是一个需要长期维护的音频子系统，收益却只是「把已有的滤镜换成自己写」。维护成本与失败面都明显更高。

第三，方案 C 的每项能力都有现成落点：EQ 有 libavfilter，响度有 `volume-gain`，淡变有 Android 已验证的分步算法。因而实现量集中在「参数模型映射」与「控制层渐变」这两处，可测试、可回退，符合 M8-T4「单测：参数设置管道」的验收口径。

最后，beat 响应（M8-T3 后续）不构成对方案 A 的需求：`astats` 探针经 `af-metadata` 即可提供 RMS/峰值，足够支撑 Android `AudioReactive` 那套 EMA + 自适应噪声地板的算法；需要频谱时可再加 `aspectralstats`。把数据来源留在 mpv 链内，也避免了为将来一个可选特效提前背上整套 PCM 管线。

## 7. EQ 参数模型 → 方案 C 的映射

### 7.1 频段定义

macOS 版采用 **10 段标准倍频程中心频率**（Android 默认 5 段是取了自己的预设锚点；本任务要求 10 段，故按标准 10 段展开）：

```
31  63  125  250  500  1000  2000  4000  8000  16000   (Hz)
```

（最低段的 ISO 标称中心频率为 31.5 Hz；参数模型用整数 Hz，取 31，与其余各段一样是倍频程步进。滤镜的 `f` 为浮点，如需精确可下发 31.5。）

增益量程沿用 Android：**±15 dB**（对应 ±1500 mB）。libavfilter `equalizer` 的 `g` 量程为 -900~900 dB，量程不成问题。

### 7.2 预设 → 10 段增益

- 预设 ID 与 Android 完全一致（`flat` / `acoustic` / `bass_boost` / … / `vocal_boost`，共 23 个 + `custom`），保证两端的音效设置将来可对齐。
- Android 每个预设由 5 个锚点增益定义（锚点频率 `60 / 230 / 910 / 3600 / 14000 Hz`）。映射到 10 段时，沿用 Android `interpolatePresetLevelDb` 的**对数频率插值**：对每个目标中心频率，在相邻锚点间按 `ln(f)` 线性插值，端点外取端点值，结果四舍五入到整 dB 并钳制在 ±15 dB。
- `flat` 恒为全 0（恒等，实测已确认）。

### 7.3 自定义频段

- `custom` 时直接采用用户给出的 10 个增益值，逐段钳制到 ±15 dB。
- 缺省（字段长度不足）按 0 补齐，与 Android `resolvePlaybackEqualizerBandLevelsMb` 的语义一致。

### 7.4 预增益（防削波）

Android 会先取「所有频段中的最大正增益」作为 headroom，避免 Boost 后整体过载。方案 C 沿用同样思路，但以**独立预增益节点**表达（等价于 Android 的整条曲线平移，且不改变用户可见的分段数值）：

```
af = "@eq:lavfi=[volume=<linearPreGain>,<10 段 equalizer 串联>]"
            linearPreGain = 10^(-max(0, maxBandDB)/20)
```

### 7.5 `af` 字符串构造规则（基线）

- 单个命名滤镜 `@eq:lavfi=[...]`，图内先预增益 `volume`，再串联 10 个 `equalizer=f=<Hz>:t=o:w=1:g=<dB>`。
- 选**串联 `equalizer`（峰值 IIR）**而非单个 `anequalizer`：单段映射 1:1、可读可调、Flat 恒等（实测），且本机验证 10 段串联与全 0 恒等均正常；`anequalizer` 作为减少节点数的备选登记（部分宽度/类型组合在实测中未能配置，落地时若改用需重新验证）。
- EQ 关闭时该滤镜整体不挂载（`af` 置空或仅保留后续探针），等价于旁路。

### 7.6 响度增强映射

- Android 目标增益 0~1500 mB → mpv `volume-gain`（dB），0~15 dB。
- 初始化时把 `volume-gain-max` 抬到 ≥15（默认仅 12），否则 12~15 dB 段会被截断。

### 7.7 淡入淡出 / 交叉淡变映射

- 淡变对象是 mpv `volume`（用户音量），与 `volume-gain`（响度）分离，二者叠加时互不覆盖。
- 步数与步长对齐 Android：`steps = clamp(durationMs/40, 4, 30)`，`stepDelay = durationMs/steps`。
- 交叉淡变基线：在曲末 `d_out` 处开始淡出 → 淡出结束换曲（`loadfile`）→ 淡入 `d_in`；不做重叠。

## 8. 接口草案（仅签名，不实现）

形态对齐项目既有约定：构造时注入**播放侧** `MPVController`（同 `AudioDeviceManager` 的注入理由——必须作用于真正出声的那个实例）；`AnyObject + Sendable`；无 UI 依赖的 `AsyncStream` 观测。

```swift
// 预设 ID 与 Android 侧逐字一致，保证跨端设置可对齐。
public enum AudioEqualizerPresetID: String, Sendable, CaseIterable {
    case custom
    case flat, acoustic
    case bassBoost = "bass_boost", bassReducer = "bass_reducer"
    case classical, club, dance, deep, electronic, folk
    case hipHop = "hip_hop", jazz, latin, lounge, piano, pop, rnb, rock
    case smallSpeakers = "small_speakers", spokenWord = "spoken_word"
    case trebleBoost = "treble_boost", trebleReducer = "treble_reducer"
    case vocalBoost = "vocal_boost"
}

/// 单个 EQ 频段。centerFrequencyHz 由 10 段固定表决定，gainDB ∈ [-15, 15]。
public struct AudioEqualizerBand: Sendable, Equatable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var centerFrequencyHz: Int
    public var gainDB: Double
}

/// 交叉淡变配置。基线为顺次近似（见 7.7）。
public struct AudioCrossfadeConfiguration: Sendable, Equatable {
    public var isEnabled: Bool
    public var duration: TimeInterval   // 秒
}

/// 音效的一次完整状态快照（与 PlayerEngineState 同构：整体发布而非字段增量）。
public struct AudioEffectsState: Sendable, Equatable {
    public var isEnabled: Bool
    public var presetID: AudioEqualizerPresetID
    public var bands: [AudioEqualizerBand]
    public var gainRangeDB: ClosedRange<Double>
    public var loudnessGainDB: Double
    public var loudnessGainRangeDB: ClosedRange<Double>
    public var fadeInDuration: TimeInterval
    public var fadeOutDuration: TimeInterval
    public var crossfade: AudioCrossfadeConfiguration
    /// 内核是否接受本次音效（af 被拒 / AO 未就绪时为 false），供 UI 降级显示。
    public var isAvailable: Bool
}

/// 音效控制器。只负责「把参数映射并下发到 mpv」，不含音频数据通路。
public protocol AudioEffectsController: AnyObject, Sendable {

    /// 最近一次已知的音效状态快照。
    var state: AudioEffectsState { get }

    // MARK: EQ（映射见第 7.2~7.5 节）
    func setEnabled(_ enabled: Bool) throws
    func setPreset(_ presetID: AudioEqualizerPresetID) throws
    /// 自定义 10 段增益（dB），长度不足按 0 补齐、超量程钳制；同时切换到 .custom。
    func setBandGains(_ gainsDB: [Double]) throws
    /// 只改单段增益（拖动滑块时的增量入口）。
    func setBandGain(at index: Int, gainDB: Double) throws

    // MARK: 响度增强（volume-gain，见 7.6）
    func setLoudnessGain(_ gainDB: Double) throws

    // MARK: 淡入淡出 / 交叉淡变（控制层，见 7.7）
    func fadeIn(duration: TimeInterval) async
    func fadeOut(duration: TimeInterval) async
    func setCrossfade(_ configuration: AudioCrossfadeConfiguration) throws

    /// 订阅状态变更；每次订阅返回独立新流，内容为全量快照。
    func observeState() -> AsyncStream<AudioEffectsState>
}

public extension AudioEffectsController {
    /// 10 段标准中心频率，供 UI 与映射逻辑共用（单一来源）。
    static var standardBandFrequenciesHz: [Int] {
        [31, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    }
}
```

落地时的接线约定（不在本任务实现）：`AudioEffectsController` 由播放侧持有，与 `QueueManager` / `PlaybackStateStore` 平级；队列切歌与交叉淡变的协作点在 `QueueManager` 的换曲路径上，由控制层决定何时淡出、何时换曲、何时淡入。

## 9. 影响

**正面**

- 一套音频链路：所有音效在 mpv 内完成，AO 与设备选择（M1-T7）保持不变，独占（M8-T6）天然兼容。
- 零新增原生桥接：只用 M1-T2 既有 `MPVController` API（`setString` / `setDouble` / `getString`）。
- 可测试：EQ 参数映射、预设插值、预增益计算、淡变步数列均可纯逻辑单测（不依赖真实音频设备），正好对上 M8-T4 的验收口径。

**代价与风险**

- **换 `af` 会重建滤镜图**。实测日志出现 resampler 重建；运行中切换预设/拖动频段可能产生一次极短的重启抖动。缓解：对连续拖动做去抖（例如停止输入后再下发），或在 M8-T4 手动听感验收中评估抖动是否可接受；若不可接受，再考虑 `anequalizer` 单滤镜 + 只重建一次图的重构策略。
- **交叉淡变基线是顺次近似**，两次淡变之间可能有可闻的短暂空隙，不是真正的重叠淡变。真正的重叠淡变需要同实例混流（`lavfi-complex`，实测可行但需重构播放/队列模型），登记为后续增强。
- **独占路径的最终形态未验证**。方案 C 依赖「音效位于 AO 之前」这一前提对自建独占 IOProc 也成立；M8-T6 走自建 AO 时，需实测确认 `af` 仍先于其生效。此项标记为 **未验证**。
- **`volume-gain-max` 默认 12 dB**：不抬高会静默截断 12~15 dB 的响度增益，落地时必须显式设置。
- **未验证项**（不得据本 ADR 当作已验证）：`coreaudio_exclusive` 下 EQ 的实机听感、`af` 重建抖动的主观可闻度、交叉淡变空隙听感、10 段 `anequalizer` 备选路径的可配置性。

## 10. 后续（M8-T4 落地清单）

1. 实现 `AudioEffectsController`（协议见第 8 节），基于 `MPVController`。
2. 移植 `PlaybackSoundModels` 的：10 段频率表、23 预设锚点表、对数插值、量程钳制、预增益计算；预设 ID 与 Android 保持一致。
3. `af` 字符串构造器 + 去抖下发；EQ 关闭时旁路。
4. 初始化时抬高 `volume-gain-max`；`volume-gain` 承载响度。
5. 控制层淡变工具（`steps = clamp(ms/40, 4, 30)`），接入队列换曲路径；交叉淡变先做顺次近似。
6. 单元测试：预设→10 段映射、自定义频段钳制、预增益、`af` 字符串形状、淡变步数列。
7. 手动听感验收：接耳机/DAC 逐预设试听、开独占复验、观察换曲有无爆音。
8. 后续增强（新任务编号，不在 M8-T4 边界内）：真正重叠的交叉淡变；M8-T3 的 beat 响应（用 `astats` 探针经 `af-metadata` 供数）。

## 附：本决策与任务边界的对应

- M1-T8：本文即交付物；只出方案与接口，未实现 EQ、未改源码。
- M8-T4：EQ（10 段 + 预设）、响度增强、淡入淡出、交叉淡入淡出均按本文落位。
- M8-T6：音效位于 mpv AO 之前，不与之冲突（自建独占下仍需实测，见第 9 节）。
- M8-T3：本 ADR 保留 `astats` 探针供后续 beat 使用，不提前实现。
