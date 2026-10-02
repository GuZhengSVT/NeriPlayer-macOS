// PlayerArtwork.swift
// NeriPlayer macOS —— 底部栏、歌曲播放页与队列共用的封面视图，并统一「方形 / 横向」两种平台比例。
//
// 为什么单独抽出来而不是各自画一遍：
//   1) 平台比例是同一条规则（需求 10）：网易云与本地是方形；Bilibili 是视频封面，用横向容器并
//      scaledToFit 完整显示原图，不能方形裁切；YouTube Music 维持原行为（方形）。若底部栏、
//      播放页、队列各写一份，三边迟早不一致。
//   2) 加载路径也只该有一条：远程走 ArtworkImageLoader（内存命中同步返回、同 URL 合并请求、
//      磁盘缓存），本地走同步解码的 PNG。
//
// 与 UI/Online/OnlineArtwork 的分工：OnlineArtwork 面向在线列表/网格（一律 scaledToFill 裁切），
// 本视图额外承担「本地封面路径」与「Bilibili 横向完整显示」两件事，只服务播放器、播放页与队列。
//
// 注意：常量与纯函数（isWide / barSize / pageSize / queueSize / content）刻意放在**非 private** 的
// extension 里，队列行（由 C 负责的媒体库侧）与主智能体都能直接复用同一套比例规则。

import AppKit
import SwiftUI

/// 封面来源。
enum PlayerArtworkContent: Equatable {
    /// 远程封面（网易云 / Bilibili / YouTube Music）。
    case remote(URL)
    /// 媒体库同步落盘的本地封面文件路径。
    case localFile(String)
    /// 没有可用封面：画占位。
    case empty
}

/// 播放器封面视图。容器尺寸由调用方给定，内部按 `shape` 决定填充方式。
struct PlayerArtwork: View {

    /// 视觉比例：方形（专辑）或横向（视频封面）。
    enum Shape { case square, wide }

    let content: PlayerArtworkContent
    let shape: Shape
    var cornerRadius: CGFloat = 8
    /// 占位图标字号，跟随容器高度由调用方给出。
    var symbolSize: CGFloat = 18

    /// 内存命中的图片。初始化时同步取一次：磁盘/内存缓存命中时首帧就是真图，
    /// 不会先闪一下占位再切过去（与 OnlineArtwork 同一取舍）。
    @State private var image: NSImage?

    init(content: PlayerArtworkContent, shape: Shape, cornerRadius: CGFloat = 8, symbolSize: CGFloat = 18) {
        self.content = content
        self.shape = shape
        self.cornerRadius = cornerRadius
        self.symbolSize = symbolSize
        if case .remote(let url) = content {
            _image = State(initialValue: ArtworkImageLoader.shared.cachedImage(for: url))
        }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            if let image {
                // 横向/方形用同一段 GeometryReader：容器尺寸由调用方给出，图片只决定填充方式。
                // 不用 `.scaledToFit()` 之类的简写是为了把「完整显示」与「裁切」的区别写在同一个地方，
                // 读代码时不必再去分辨哪条分支对应哪个平台。
                GeometryReader { geometry in
                    Image(nsImage: image)
                        .resizable()
                        // 横向（Bilibili）用 fit：原图完整可见，绝不方形裁切；
                        // 方形（网易云/本地/YouTube）用 fill：填满容器，边角裁掉可接受。
                        .aspectRatio(contentMode: shape == .square ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: symbolSize))
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityLabel("封面")
        .task(id: taskIdentifier) { await load() }
    }

    /// `.task(id:)` 的身份：内容不变就不重新加载。
    private var taskIdentifier: String {
        switch content {
        case .remote(let url): return ArtworkURLNormalizer.taskIdentifier(for: url)
        case .localFile(let path): return "local:" + path
        case .empty: return "artwork-empty"
        }
    }

    private func load() async {
        switch content {
        case .remote(let url):
            if let cached = ArtworkImageLoader.shared.cachedImage(for: url) {
                image = cached
                return
            }
            let loaded = try? await ArtworkImageLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        case .localFile(let path):
            // 本地封面是同步落盘的小 PNG：直接解码，避免为它走一次异步往返。
            image = NSImage(contentsOfFile: path)
        case .empty:
            image = nil
        }
    }
}

// MARK: - 平台比例与尺寸

extension PlayerArtwork {

    /// Bilibili 是视频源，封面按横向容器展示；其余平台（网易云、YouTube Music）与本地保持方形。
    static func isWide(_ track: Track?) -> Bool { track?.onlineSong?.source == .bilibili }

    /// 由当前曲目决定容器比例（视图调用点直接读它，避免各处再写一遍三元判断）。
    static func shape(for track: Track?) -> Shape { isWide(track) ? .wide : .square }

    /// 底部栏里的尺寸：方形 72×72；横向 16:9（宽 128、高同为 72）。
    ///
    /// 栏高按需求「约等于封面高度」取 72（主行区域）；横向容器保持同一高度，宽度按 16:9 得出，
    /// 因此两类封面在栏内高度一致，换歌不会让栏跳高。
    static func barSize(for track: Track?) -> CGSize {
        isWide(track) ? CGSize(width: 128, height: 72) : CGSize(width: 72, height: 72)
    }

    /// 底部栏主行高度。栏高约等于封面高度（72），因此封面上下自然贴合。
    static let barRowHeight: CGFloat = 72

    /// 歌曲播放页里的尺寸：方形 380×380；横向 16:9（宽 400、高 225），保证原图完整可见，
    /// 且不超过播放页左列（460pt 宽、左右各 28pt 留白 → 可用 404pt）的实际宽度。
    static func pageSize(for track: Track?) -> CGSize {
        isWide(track) ? CGSize(width: 400, height: 225) : CGSize(width: 380, height: 380)
    }

    /// 队列行里的小封面：高度统一 36，宽度按比例算出（方形 36、横向 64）。
    /// 队列行高度由这一对尺寸决定，横向行不会比方形行更高。
    static func queueSize(for track: Track?) -> CGSize {
        isWide(track) ? CGSize(width: 64, height: 36) : CGSize(width: 36, height: 36)
    }

    /// 由当前曲目与媒体库得到封面内容。
    ///
    /// 顺序：在线曲优先用平台封面（网易云/Bilibili 的原图），否则用媒体库同步落盘的本地封面。
    static func content(for track: Track?, library: LibraryViewModel?) -> PlayerArtworkContent {
        if let artwork = track?.onlineSong?.artworkURL { return .remote(artwork) }
        if let library,
           case .library(let item) = CurrentTrackLibraryActions.target(for: track, libraryTracks: library.tracks),
           let path = item.coverPath, !path.isEmpty {
            return .localFile(path)
        }
        return .empty
    }
}
