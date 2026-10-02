// MPVLaunchOption.swift — typed libmpv launch options.
import Foundation

// MARK: - 启动选项

/// 一条 mpv 启动选项（等价于命令行的 `--name=value`）。
///
/// 与运行期属性的区别：启动选项只在 `mpv_initialize` 之前有效，用来决定内核**以什么形态**
/// 起来（音频输出、解码器、配置来源等）；初始化之后同名项属于运行期属性，语义与可写性都不同。
public struct MPVLaunchOption: Equatable, Sendable {

    /// 选项名（不含前导 `--`）。
    public let name: String
    /// 选项值；会被 mpv 按该选项自身的语法解析。
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    /// 把音频输出接到 null 设备：音频照常解码、照常推进时钟，只是最后的输出环节把采样丢弃。
    ///
    /// 用途是测试：本仓库的播放素材是系统提示音（/System/Library/Sounds/*.aiff），
    /// 真机跑测试会持续出声。刻意不用 `audio=no` —— 那会整个关掉音频轨，文件在 mpv 眼里
    /// 变成「没有音轨」，测到的就不是真实的解码与时钟，而是一个被削掉一半的播放链路。
    /// `ao=null` 保留完整链路，只换掉输出设备。
    ///
    /// 为什么不是默认全局静音：音频输出设备枚举（M1-T7 的 AudioDeviceManager）测的正是
    /// 「当前 AO 下有哪些设备」，全局换成 null 会让那份设备列表退化成只有 null 一项。
    /// 因此由需要出声的测试夹具显式传入，而不是塞进所有实例的默认值。
    public static let silentAudio: [MPVLaunchOption] = [
        MPVLaunchOption(name: "ao", value: "null")
    ]

    /// 音频专用配置：不创建任何窗口、不渲染视频轨。
    ///
    /// 为什么必须显式关掉 `audio-display`：libmpv 的默认值是 `embedded-first`，即「文件里嵌了
    /// 封面就用视频输出把它画出来」。本机媒体库里的 m4a/mp3/flac 基本都内嵌 PNG 封面，
    /// 于是 mpv 把封面当成一条视频轨，用 gpu-next **另开一个顶层窗口**渲染 —— 这个窗口由 mpv
    /// 自己创建，app 完全不知情（本工程只桥接 C API，没有 mpv_render_context、也没有传 wid）。
    /// 用户关掉那个窗口会让 mpv 发 MPV_EVENT_END_FILE（reason=QUIT），播放就此中断。
    /// `audio-display=no` 是这条链路的根治手段：封面不再产生视频轨，窗口无从创建。
    ///
    /// 其余几项是兜底与降噪，不是主因：
    ///   - `vo=null` / `vid=no`：即使文件里真有视频轨（B 站渐进式回退流就是 video/mp4）也不开窗；
    ///   - `force-window=no`：显式确认「永远不为音频建窗」，避免被系统或用户配置覆盖；
    ///   - `osc=no` / `load-scripts=no` / `input-default-bindings=no`：关掉 mpv 自带播放器的
    ///     屏幕控制器、脚本与键盘绑定。它们服务于独立播放器，在本 app 内既不可见也无意义。
    ///
    /// 刻意不用 `audio=no` 或 `no-audio`：那会连音频轨一起关掉，播放直接失效。
    public static let audioOnly: [MPVLaunchOption] = [
        MPVLaunchOption(name: "audio-display", value: "no"),
        MPVLaunchOption(name: "vo", value: "null"),
        MPVLaunchOption(name: "vid", value: "no"),
        MPVLaunchOption(name: "force-window", value: "no"),
        MPVLaunchOption(name: "osc", value: "no"),
        MPVLaunchOption(name: "load-scripts", value: "no"),
        MPVLaunchOption(name: "input-default-bindings", value: "no")
    ]

    /// 生产默认：音频专用 + 静音输出。测试夹具用它避免真机出声，同时保持无窗口。
    public static let silentAudioOnly: [MPVLaunchOption] = audioOnly + silentAudio
}
