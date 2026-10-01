// make-app-icon.swift
// M9-T1: generate the PNG sizes consumed by iconutil without checked-in binaries.
import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset", isDirectory: true)
let sizes = [16, 32, 128, 256, 512, 1024]
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for size in sizes {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: CGFloat(size) * 0.22, yRadius: CGFloat(size) * 0.22).fill()
    let symbolSize = CGFloat(size) * 0.58
    if let symbol = NSImage(systemSymbolName: "music.note.house.fill", accessibilityDescription: nil) {
        let configuration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
        let configured = symbol.withSymbolConfiguration(configuration) ?? symbol
        configured.draw(in: NSRect(x: (CGFloat(size) - symbolSize) / 2, y: (CGFloat(size) - symbolSize) / 2, width: symbolSize, height: symbolSize), from: .zero, operation: .sourceOver, fraction: 1)
    }
    image.unlockFocus()
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "NeriPlayerIcon", code: 1)
    }
    let name = size == 16 ? "icon_16x16.png" : size == 32 ? "icon_16x16@2x.png" : size == 128 ? "icon_128x128.png" : size == 256 ? "icon_128x128@2x.png" : size == 512 ? "icon_256x256@2x.png" : "icon_512x512@2x.png"
    try data.write(to: output.appendingPathComponent(name), options: .atomic)
}
