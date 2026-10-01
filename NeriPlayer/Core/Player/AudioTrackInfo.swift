// AudioTrackInfo.swift
// NeriPlayer macOS —— 当前音源的实际音频规格（播放信息层）。
//
// 定位：底部播放器要显示「真实音质 / 比特率 / 采样率」这类信息，值只能来自播放内核实际打开的文件，
// 不能由界面按标题或平台猜。本文件只定义一个纯值类型与它的展示格式化规则：
//   - 采集（谁去读 libmpv 的属性、什么时候读）在 MPVEngine；
//   - 聚合与发布在 PlaybackStateStore（随快照一起下发）；
//   - 界面只负责把有值的字段排成一行，缺值的字段直接省略。
//
// 「不编造」是硬约束：所有字段都是可选的，读不到就是 nil，界面因此不显示该段，而不是回落到
// 猜测的默认码率或「无损」这类没有依据的标签。这个类型本身不做任何默认值填充。
//
// 值与单位：bitrate 用 bit/s（libmpv 的 audio-bitrate 即为 bit/s），sampleRate 用 Hz，
// channels 用声道数。格式化只在这里做一次，界面与测试共用同一套规则。

import Foundation

/// 当前播放文件的真实音频规格。所有字段可缺省；缺省表示「内核没有报告该值」。
public struct AudioTrackInfo: Equatable, Hashable, Sendable {

    /// 音频编码名（libmpv 的 audio-codec-name，例如 "mp3" / "flac" / "pcm_s24be"）。
    public var codec: String?
    /// 容器格式（libmpv 的 file-format，例如 "mp3" / "flac" / "aiff"）。
    public var container: String?
    /// 实际比特率（bit/s，libmpv 的 audio-bitrate）。
    public var bitrate: Int?
    /// 采样率（Hz，libmpv 的 audio-params/samplerate）。
    public var sampleRate: Int?
    /// 声道数（libmpv 的 audio-params/channel-count）。
    public var channels: Int?

    public init(
        codec: String? = nil,
        container: String? = nil,
        bitrate: Int? = nil,
        sampleRate: Int? = nil,
        channels: Int? = nil
    ) {
        // 只接受有意义的正数：0 或负数表示内核尚未报告，按「没有」处理，避免显示 0 kbps。
        self.codec = Self.clean(codec)
        self.container = Self.clean(container)
        self.bitrate = bitrate.flatMap { $0 > 0 ? $0 : nil }
        self.sampleRate = sampleRate.flatMap { $0 > 0 ? $0 : nil }
        self.channels = channels.flatMap { $0 > 0 ? $0 : nil }
    }

    /// 是否一个字段都没有 —— 界面据此整段不渲染。
    public var isEmpty: Bool {
        codec == nil && container == nil && bitrate == nil && sampleRate == nil && channels == nil
    }

    /// 去掉首尾空白；空串视为没有。
    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 增量填充（供播放内核按属性事件逐项更新）
    //
    // 为什么用 mutating setter 而不是让调用方先构造新值再整体替换：libmpv 的这几条属性是分别、
    // 先后到达的事件（编码名先到、比特率后到），逐项更新才与事件语义一致；每个 setter 都复用
    // 与 init 相同的「0/负数/空白 = 没有」规则，避免两处口径漂移。

    /// 设置音频编码名。
    public mutating func setCodec(_ value: String?) { codec = Self.clean(value) }
    /// 设置容器格式。
    public mutating func setContainer(_ value: String?) { container = Self.clean(value) }
    /// 设置比特率（bit/s）；非正数按「没有」处理。
    public mutating func setBitrate(_ value: Int?) { bitrate = value.flatMap { $0 > 0 ? $0 : nil } }
    /// 设置采样率（Hz）；非正数按「没有」处理。
    public mutating func setSampleRate(_ value: Int?) { sampleRate = value.flatMap { $0 > 0 ? $0 : nil } }
    /// 设置声道数；非正数按「没有」处理。
    public mutating func setChannels(_ value: Int?) { channels = value.flatMap { $0 > 0 ? $0 : nil } }
}

// MARK: - 展示格式化

/// AudioTrackInfo 的展示文本。纯函数，不依赖任何界面框架，可脱离 SwiftUI 单测。
public enum AudioInfoText {

    /// 编码名大写显示；缺省为 nil。
    public static func codecLabel(_ info: AudioTrackInfo) -> String? {
        info.codec?.uppercased()
    }

    /// 比特率文本。bit/s → "128 kbps"；不足 1 kbps 用 bps；缺省为 nil。
    ///
    /// 取整规则：以 1000 为进制（音频码率的通行口径），四舍五入到整数 kbps。
    public static func bitrateLabel(_ bitrate: Int?) -> String? {
        guard let bitrate, bitrate > 0 else { return nil }
        if bitrate < 1000 {
            return "\(bitrate) bps"
        }
        let kbps = Int((Double(bitrate) / 1000).rounded())
        return "\(kbps) kbps"
    }

    /// 采样率文本。Hz → "48 kHz" / "44.1 kHz"；缺省为 nil。
    public static func sampleRateLabel(_ sampleRate: Int?) -> String? {
        guard let sampleRate, sampleRate > 0 else { return nil }
        let kHz = Double(sampleRate) / 1000
        // 整数 kHz 不显示小数位，44.1 这类保留一位。
        if kHz.rounded() == kHz {
            return "\(Int(kHz)) kHz"
        }
        return String(format: "%.1f kHz", kHz)
    }

    /// 声道数文本，例如 "2ch"；缺省为 nil。
    public static func channelsLabel(_ channels: Int?) -> String? {
        guard let channels, channels > 0 else { return nil }
        return "\(channels)ch"
    }

    /// 一行规格摘要：只把有值的片段用 " · " 连起来，全空返回 nil。
    ///
    /// 片段顺序固定为 编码 → 比特率 → 采样率 → 声道，界面各处显示一致。
    public static func summary(_ info: AudioTrackInfo?) -> String? {
        guard let info, !info.isEmpty else { return nil }
        let parts = [
            codecLabel(info),
            bitrateLabel(info.bitrate),
            sampleRateLabel(info.sampleRate),
            channelsLabel(info.channels)
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
