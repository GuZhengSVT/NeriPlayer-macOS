// HyperBackgroundView.swift
// M8-T3: Metal port of Android's five-point fluid background.
import MetalKit
import SwiftUI

struct HyperBackgroundView: NSViewRepresentable {
    var dark: Bool
    var colors: [SIMD4<Float>]?

    func makeCoordinator() -> Coordinator { Coordinator(dark: dark, colors: colors ?? (dark ? BgEffectPainter.darkColors : BgEffectPainter.defaultColors)) }
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        context.coordinator.configure(view)
        return view
    }
    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.dark = dark
        context.coordinator.colors = colors ?? (dark ? BgEffectPainter.darkColors : BgEffectPainter.defaultColors)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var dark: Bool
        var colors: [SIMD4<Float>]
        private var device: MTLDevice?
        private var pipeline: MTLRenderPipelineState?
        private var start = CACurrentMediaTime()
        private var view: MTKView?

        init(dark: Bool, colors: [SIMD4<Float>]) { self.dark = dark; self.colors = colors }
        func configure(_ view: MTKView) {
            self.view = view
            guard let device = MTLCreateSystemDefaultDevice() else { view.isHidden = true; return }
            self.device = device; view.device = device; view.delegate = self
            view.isPaused = false; view.enableSetNeedsDisplay = false; view.preferredFramesPerSecond = 60
            view.framebufferOnly = true; view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            guard let url = Bundle.module.url(forResource: "HyperBackground", withExtension: "metal"),
                  let source = try? String(contentsOf: url),
                  let library = try? device.makeLibrary(source: source, options: nil),
                  let vertex = library.makeFunction(name: "backgroundVertex"),
                  let fragment = library.makeFunction(name: "backgroundFragment") else { view.isHidden = true; return }
            let descriptor = MTLRenderPipelineDescriptor(); descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
            start = CACurrentMediaTime()
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard let pipeline, let commandBuffer = view.currentDrawable.flatMap({ _ in device?.makeCommandQueue()?.makeCommandBuffer() }),
                  let pass = view.currentRenderPassDescriptor, let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            var uniforms = BgEffectPainter.uniforms(size: view.drawableSize, time: Float(CACurrentMediaTime() - start), dark: dark, colors: colors)
            encoder.setRenderPipelineState(pipeline); encoder.setVertexBytes(&uniforms, length: MemoryLayout<BgEffectUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
            if let drawable = view.currentDrawable { commandBuffer.present(drawable) }; commandBuffer.commit()
        }
    }
}

struct BgEffectFiveVectors {
    var a: SIMD4<Float>; var b: SIMD4<Float>; var c: SIMD4<Float>; var d: SIMD4<Float>; var e: SIMD4<Float>
}

struct BgEffectUniforms {
    var resolution: SIMD2<Float>; var animTime: Float; var padding0: Float
    var bound: SIMD4<Float>; var translateY: Float; var padding1: SIMD3<Float>
    var points: BgEffectFiveVectors
    var colors: BgEffectFiveVectors
    var alphaMulti: Float; var saturateOffset: Float; var lightOffset: Float; var levelEase: Float
    var beatEase: Float; var motionEase: Float; var zoom: Float; var colorPulse: Float
    var globalMotion: SIMD2<Float>; var padding2: SIMD2<Float>
}

enum BgEffectPainter {
    static let defaultColors: [SIMD4<Float>] = [
        SIMD4(0.68, 0.82, 0.98, 1), SIMD4(0.96, 0.85, 0.74, 1), SIMD4(0.94, 0.76, 0.88, 1),
        SIMD4(0.74, 0.72, 0.94, 1), SIMD4(0.80, 0.88, 0.92, 1)
    ]
    static let darkColors: [SIMD4<Float>] = [
        SIMD4(0.07, 0.27, 0.42, 1), SIMD4(0.35, 0.24, 0.20, 1), SIMD4(0.34, 0.12, 0.26, 1),
        SIMD4(0.17, 0.14, 0.34, 1), SIMD4(0.18, 0.34, 0.36, 1)
    ]
    static func uniforms(size: CGSize, time: Float, dark: Bool, colors: [SIMD4<Float>]) -> BgEffectUniforms {
        let points = [
            SIMD4<Float>(0.52, 0.46, 0.92, 0), SIMD4<Float>(0.14, 0.32, 0.74, 0), SIMD4<Float>(0.92, 0.30, 0.76, 0),
            SIMD4<Float>(0.26, 0.88, 0.80, 0), SIMD4<Float>(0.84, 0.86, 0.84, 0)
        ]
        let c = Array((colors.count == 5 ? colors : (dark ? darkColors : defaultColors)).prefix(5))
        let cs = c + Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: max(0, 5 - c.count))
        return BgEffectUniforms(resolution: SIMD2(Float(max(1, size.width)), Float(max(1, size.height))), animTime: time, padding0: 0,
            bound: SIMD4(0, 0, 1, 1), translateY: 0, padding1: SIMD3(0, 0, 0),
            points: BgEffectFiveVectors(a: points[0], b: points[1], c: points[2], d: points[3], e: points[4]),
            colors: BgEffectFiveVectors(a: cs[0], b: cs[1], c: cs[2], d: cs[3], e: cs[4]),
            alphaMulti: 1, saturateOffset: 0.2, lightOffset: 0.1,
            levelEase: 0, beatEase: 0, motionEase: 0, zoom: 1, colorPulse: 0, globalMotion: SIMD2(0, 0), padding2: SIMD2(0, 0))
    }
}
