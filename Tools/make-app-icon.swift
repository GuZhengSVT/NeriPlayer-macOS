// make-app-icon.swift
// M9-T1: generate the PNG sizes consumed by iconutil without checked-in binaries.
// 图标替换（2026-10-07）：不再用代码绘制 SF Symbol，改为从 Tools/AppIcon/ 下的
// 位图母版缩放派生。母版是安卓端图标的 macOS 规格重制版（深蓝底 + 白色圆环徽标），
// 已按 Apple macOS 11+ 版式（内容区 824/1024 居中、外沿透明）排好版，这里只负责缩放。
import AppKit
import Foundation
import ImageIO

// 母版路径按 #filePath 反推：脚本运行时的 cwd 不固定，理由同 Package.swift 的 vendor 路径。
let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let masterDirectory = scriptDirectory.appendingPathComponent("AppIcon", isDirectory: true)
// 位图母版：已按 Apple macOS 11+ 版式（内容区 824/1024 居中、外沿透明）排好版。
// 不再细分小尺寸专用母版：单个母版缩放到 16 px 也清晰，多套母版只会带来静默回退的坑。
let masterURL = masterDirectory.appendingPathComponent("AppIcon-1024.png")

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func loadMaster(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(
            domain: "NeriPlayerIcon",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "icon master missing or unreadable: \(url.path)"]
        )
    }
    return image
}

func render(_ master: CGImage, side: Int) throws -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "NeriPlayerIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot create \(side)x\(side) context"])
    }
    context.interpolationQuality = .high
    context.draw(master, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let scaled = context.makeImage() else {
        throw NSError(domain: "NeriPlayerIcon", code: 4, userInfo: [NSLocalizedDescriptionKey: "cannot render \(side)x\(side) image"])
    }
    let representation = NSBitmapImageRep(cgImage: scaled)
    representation.size = NSSize(width: side, height: side)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "NeriPlayerIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot encode \(side)x\(side) png"])
    }
    return data
}

// iconutil 要求的完整文件名集合；@2x 项是同一张图的两倍像素边长。
let entries: [(name: String, side: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let master = try loadMaster(masterURL)

for entry in entries {
    let data = try render(master, side: entry.side)
    try data.write(to: output.appendingPathComponent(entry.name), options: .atomic)
}
