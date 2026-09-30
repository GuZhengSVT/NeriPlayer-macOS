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
}
