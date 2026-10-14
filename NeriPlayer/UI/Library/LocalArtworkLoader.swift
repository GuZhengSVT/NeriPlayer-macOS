import AppKit
import ImageIO

/// 小尺寸封面在后台读盘、降采样并共用缓存，不在 SwiftUI body 中同步加载原图。
actor LocalArtworkLoader {
    static let shared = LocalArtworkLoader()
    final class ImageBox: @unchecked Sendable {
        let image: NSImage
        init(_ image: NSImage) { self.image = image }
    }
    private let cache = NSCache<NSString, ImageBox>()
    private var inflight: [String: Task<ImageBox?, Never>] = [:]

    init() { cache.totalCostLimit = 32 * 1024 * 1024; cache.countLimit = 512 }

    func image(path: String?, revision: Double?) async -> ImageBox? {
        guard let path, !path.isEmpty else { return nil }
        let key = path + "#" + (revision.map { String($0) } ?? "unknown")
        if let image = cache.object(forKey: key as NSString) { return image }
        if let task = inflight[key] { return await task.value }
        let task = Task.detached(priority: .utility) { () -> ImageBox? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return ImageBox(NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height)))
        }
        inflight[key] = task
        let value = await task.value
        inflight[key] = nil
        if let value { cache.setObject(value, forKey: key as NSString, cost: 256 * 256 * 4) }
        return value
    }
}
