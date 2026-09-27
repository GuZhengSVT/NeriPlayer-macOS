// PlaybackEntry.swift
// NeriPlayer macOS —— 「随机播放」的首曲选择与入队动作（移植规划 M2-T8）。
//
// 为什么随机播放不切到 shuffle 模式、而是「整组入队 + 队列内部随机取起点」：
//   1) 队列模式是用户偏好，属于队列自有状态（QueueManager.setMode）。歌手/专辑详情与歌单里的
//      「随机播放」是一次动作，不该顺带把全局模式改成随机 —— 用户随后按「下一首」时预期仍是
//      顺序走，而不是被这一个按钮永久改成随机。因此这里不动 queue.mode。
//   2) 整组仍然全量入队（setQueue），next/previous 因此能走完整组，而不是只播随机到的那一首；
//   3) 起点用 playTrack 跳转（它按 id 在队列里定位后 load），复用已有的「跳转当前曲」路径，
//      不需要给 PlaybackStateStore / QueueManager 增加任何新 API。
//
// 抽成独立类型的两个理由：三处入口（歌手详情 / 专辑详情 / 歌单详情）共用同一段动作，避免抄三份；
// 「随机出来的那首一定属于该组」这条不变量也才能被单测直接打在真实执行路径上（shuffle(_:store:)），
// 而不是在测试里复制一遍调用顺序。

import Foundation

/// 随机取数：在一组曲目里随机挑一个下标。纯函数，随机源可注入。
enum PlaybackShuffleEntry {

    /// 在 count 个元素里随机取一个下标；count 小于等于 0 时返回 nil（调用方据此什么都不做）。
    static func randomIndex<Generator: RandomNumberGenerator>(count: Int, using generator: inout Generator) -> Int? {
        guard count > 0 else { return nil }
        return Int.random(in: 0..<count, using: &generator)
    }

    /// 在一组曲目里随机取一个下标；空数组返回 nil。
    /// - Parameter isSeedFixed: true 时用固定种子的生成器，使取数过程可复现（测试用）；
    ///   false 时用系统随机源。
    static func randomIndex(in tracks: [Track], isSeedFixed: Bool = false) -> Int? {
        guard !tracks.isEmpty else { return nil }
        if isSeedFixed {
            var generator = SeededGenerator(seed: 0x5EED_2026)
            return randomIndex(count: tracks.count, using: &generator)
        }
        var generator = SystemRandomNumberGenerator()
        return randomIndex(count: tracks.count, using: &generator)
    }
}

/// 整组播放入口：把「随机播放」的完整动作收在一处，三处 UI 调用同一个函数。
enum PlaybackEntry {

    /// 整组入队并从随机起点开播。
    /// - Returns: 被随机选中的曲目；组为空时返回 nil（防呆：空组不产生任何播放动作）。
    @discardableResult
    static func shuffle(
        _ tracks: [Track],
        store: PlaybackStateStore,
        isSeedFixed: Bool = false
    ) -> Track? {
        guard !tracks.isEmpty else { return nil }
        // 先整组入队，next/previous 才能走完整组；随后把当前曲跳到随机起点。
        store.setQueue(tracks, startIndex: 0)
        guard let index = PlaybackShuffleEntry.randomIndex(in: tracks, isSeedFixed: isSeedFixed) else { return nil }
        let picked = tracks[index]
        store.playTrack(picked)
        return picked
    }
}

/// 固定种子的线性同余随机源：只用于测试与「可复现的随机起点」，不用于安全场景。
/// 参数取自 Numerical Recipes 的 LCG 常数，够用且实现一眼可验。
struct SeededGenerator: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        // 种子为 0 时 LCG 会退化（永远输出 0），换成非零初值。
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
