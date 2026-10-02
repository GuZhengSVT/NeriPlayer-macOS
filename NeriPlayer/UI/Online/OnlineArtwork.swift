// OnlineArtwork.swift
// T04: album/playlist artwork view for online surfaces. Loading, empty and failure states stay
// distinct so a broken cover is not indistinguishable from a resource that has no cover at all.
//
// 2026-10-03（需求 10）：新增可选的 `contentMode` 与 `platform`。默认值保持原行为不变 ——
// 方形容器 + `scaledToFill` + 裁切，网易云/YouTube 的专辑封面因此完全不受影响。
// Bilibili 视频封面走 `contentMode: .fit`：16:9 横向容器里完整显示原图，不做方形裁切。
// 歌单/收藏夹封面属于「收藏夹语义」，继续按方形展示，不套用视频的横向容器。
import AppKit
import SwiftUI

struct OnlineArtwork: View {

    /// 图像在容器内的填充方式。
    /// - `fill`（默认）：铺满容器并裁切，用于网易云/YouTube 的方形专辑封面；
    /// - `fit`：完整显示原图（可能留边），用于 Bilibili 视频封面，避免 16:9 被裁成方形。
    enum ImageContentMode {
        case fill
        case fit
    }

    enum LoadState: Equatable {
        case empty
        case loading
        case loaded
        case failed(String?)
    }

    /// Bilibili 视频封面的容器比例（16:9）。
    static let videoAspectRatio: CGFloat = 16.0 / 9.0

    /// 给定高度下的容器尺寸：Bilibili 视频为横向 16:9，其余平台（含 nil）为方形。
    /// 调用方（行/队列/搜索结果）用它算 `frame`，占位图形状与真实封面形状因此一致 ——
    /// 不需要在每个列表里各写一遍 16:9 判断。
    static func containerSize(height: CGFloat, platform: MusicSource?) -> CGSize {
        guard platform == .bilibili else { return CGSize(width: height, height: height) }
        return CGSize(width: (height * videoAspectRatio).rounded(), height: height)
    }

    let url: URL?
    private let loader: ArtworkImageLoader
    private let cornerRadius: CGFloat
    private let symbolSize: CGFloat
    private let contentMode: ImageContentMode
    private let platform: MusicSource?

    @State private var state: LoadState = .empty
    @State private var image: NSImage?

    init(url: URL?, loader: ArtworkImageLoader = .shared, cornerRadius: CGFloat = 4, symbolSize: CGFloat = 13,
         contentMode: ImageContentMode = .fill, platform: MusicSource? = nil) {
        self.url = url
        self.loader = loader
        self.cornerRadius = cornerRadius
        self.symbolSize = symbolSize
        self.contentMode = contentMode
        self.platform = platform
        // A memory hit renders on the first frame instead of flashing a placeholder over cached data.
        let cached = loader.cachedImage(for: url)
        _state = State(initialValue: cached == nil ? LoadState.empty : .loaded)
        _image = State(initialValue: cached)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.08))
            switch state {
            case .loaded:
                if let image {
                    GeometryReader { geometry in
                        // fit 完整显示原图（Bilibili 视频），fill 铺满裁切（方形专辑封面，保持原行为）。
                        Group {
                            if contentMode == .fit {
                                Image(nsImage: image).resizable().scaledToFit()
                            } else {
                                Image(nsImage: image).resizable().scaledToFill()
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                }
            case .loading:
                ProgressView().controlSize(.small)
            case .empty:
                Image(systemName: "music.note").font(.system(size: symbolSize)).foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle").font(.system(size: symbolSize))
                    .foregroundStyle(.secondary)
                    .help(failureMessage ?? "封面加载失败")
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityLabel(accessibilityText)
        .task(id: ArtworkURLNormalizer.taskIdentifier(for: url)) { await reload() }
    }

    private var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    private var accessibilityText: Text {
        switch state {
        case .loaded: return Text("封面")
        case .loading: return Text("封面加载中")
        case .empty: return Text("无封面")
        case .failed: return Text(failureMessage ?? "封面加载失败")
        }
    }

    private func reload() async {
        guard let url else {
            image = nil
            state = .empty
            return
        }
        if let cached = loader.cachedImage(for: url) {
            image = cached
            state = .loaded
            return
        }
        image = nil
        state = .loading
        var attempt = 0
        while true {
            do {
                let loaded = try await loader.image(for: url)
                guard !Task.isCancelled else { return }
                image = loaded
                state = .loaded
                return
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // Only a transport/HTTP miss is worth retrying: a bad URL or undecodable body is permanent.
                let retryable = (error as? ArtworkLoadFailure).map { $0.isTransient } ?? true
                guard retryable, attempt < 2 else {
                    image = nil
                    state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    return
                }
                attempt += 1
                do { try await Task.sleep(for: .milliseconds(700 * attempt)) } catch { return }
            }
        }
    }
}

// MARK: - 行内缩略图

/// 行/队列/列表通用的封面缩略图：按平台自动选择容器比例，Bilibili 视频完整显示原图。
/// 存在的意义只有一个 —— 让调用方写「一个高度」，而不是在每个列表里重复一遍 16:9 判断。
struct OnlineArtworkThumbnail: View {

    let url: URL?
    /// 曲目来源；`nil`（如本地文件、未知来源）按方形处理。
    let platform: MusicSource?
    /// 方形边长的基准；Bilibili 时高度不变、宽度按 16:9 展开。
    var height: CGFloat = 44
    var cornerRadius: CGFloat = 4

    var body: some View {
        let size = OnlineArtwork.containerSize(height: height, platform: platform)
        OnlineArtwork(url: url,
                      cornerRadius: cornerRadius,
                      contentMode: platform == .bilibili ? .fit : .fill,
                      platform: platform)
            .frame(width: size.width, height: size.height)
    }
}
