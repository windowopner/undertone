import AppKit
import MetalKit
import SwiftUI

/// Matches `struct U` in ArtShaders (9 × float4).
struct ArtUniforms {
    var timeRes = SIMD4<Float>(0, 1, 1, 1)     // t, aspect, width, height
    var levels = SIMD4<Float>(0, 0, 0, 0)      // bass, mid, high, level (smoothed)
    var groove = SIMD4<Float>(0, 0, 0, 0)      // beat env, beat phase, beat count, step
    var drop = SIMD4<Float>(1000, 0, 0, 0)     // seconds since drop, drop count, slow swell, active
    var c1 = SIMD4<Float>(0, 0, 0, 1)
    var c2 = SIMD4<Float>(0, 0, 0, 1)
    var c3 = SIMD4<Float>(0, 0, 0, 1)
    var bg = SIMD4<Float>(0, 0, 0, 1)
    var image = SIMD4<Float>(0, 1, 0.5, 0)     // has image, image aspect, beat period, 0
}

/// GPU renderer for the abstract backgrounds. Shaders are compiled from source at launch,
/// so no Xcode build step is needed. Shared by every screen.
final class ArtEngine: NSObject {
    static let shared = ArtEngine()

    static let shaderNames: [VisualStyle: String] = [
        .contour: "art_contour",
        .cutout: "art_cutout",
        .orbit: "art_orbit",
        .field: "art_field",
        .aurora: "art_aurora",
        .pulse: "art_pulse",
        .image: "art_image",
    ]

    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipelines: [VisualStyle: MTLRenderPipelineState] = [:]
    private var sampler: MTLSamplerState?
    private var blank: MTLTexture?
    private(set) var shaderError: String?

    /// Set by AppDelegate before any window is built.
    var audio: AudioReactor?

    // Image style
    private var imageTex: MTLTexture?
    private var imagePathLoaded: String?
    private var imageAspect: Float = 1

    // Smoothing (main thread)
    private var last: TimeInterval = 0
    private var smooth = SIMD4<Float>(0, 0, 0, 0)
    private var swell: Float = 0
    private let start = ProcessInfo.processInfo.systemUptime

    private override init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        super.init()
        build()
    }

    func supports(_ style: VisualStyle) -> Bool { pipelines[style] != nil }

    // MARK: - Setup

    private func build() {
        guard let device = device else {
            report("Metal을 쓸 수 없는 Mac")
            return
        }
        do {
            let library = try device.makeLibrary(source: ArtShaders.source, options: nil)
            guard let vertex = library.makeFunction(name: "art_vertex") else {
                report("art_vertex 함수 없음")
                return
            }
            for (style, name) in Self.shaderNames {
                guard let fragment = library.makeFunction(name: name) else {
                    report("\(name) 함수 없음")
                    continue
                }
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = vertex
                d.fragmentFunction = fragment
                d.colorAttachments[0].pixelFormat = .bgra8Unorm
                do {
                    pipelines[style] = try device.makeRenderPipelineState(descriptor: d)
                } catch let pipelineError {
                    report("\(name): \(pipelineError)")
                }
            }
        } catch let compileError {
            report("\(compileError)")
        }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        if let t = device.makeTexture(descriptor: td) {
            var px: [UInt8] = [0, 0, 0, 255]
            t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
            blank = t
        }
    }

    /// Shader problems go to the menu and to ~/Library/Logs/Undertone-shader.log.
    private func report(_ message: String) {
        shaderError = (shaderError.map { $0 + "\n\n" } ?? "") + message
        NSLog("Undertone shader: %@", message)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Undertone-shader.log")
        try? (shaderError ?? "").write(to: url, atomically: true, encoding: .utf8)
    }

    private func ensureImage(_ path: String?) {
        guard path != imagePathLoaded else { return }
        imagePathLoaded = path
        imageTex = nil
        guard let path = path, let device = device else { return }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [.SRGB: false]
        if let t = try? loader.newTexture(URL: URL(fileURLWithPath: path), options: options) {
            imageTex = t
            imageAspect = Float(t.width) / Float(max(t.height, 1))
        }
    }

    // MARK: - Frame

    private func follow(_ cur: Float, _ target: Float, _ up: Float, _ down: Float, _ dt: Float) -> Float {
        let tau = target > cur ? up : down
        return cur + (target - cur) * (1 - exp(-dt / tau))
    }

    private func uniforms(size: CGSize) -> ArtUniforms {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = Float(min(max(now - last, 0), 0.1))
        last = now

        let lv = (audio?.snapshot() ?? Levels()).scaled(Settings.shared.sensitivity)
        smooth.x = follow(smooth.x, lv.bass, 0.05, 0.30, dt)
        smooth.y = follow(smooth.y, lv.mid, 0.12, 0.45, dt)
        smooth.z = follow(smooth.z, lv.high, 0.05, 0.25, dt)
        smooth.w = follow(smooth.w, lv.level, 0.08, 0.40, dt)
        swell = follow(swell, lv.bass, 0.25, 1.4, dt)

        let g = Groove.from(lv, now: now)
        let pal = ColorSync.shared.palette

        var u = ArtUniforms()
        let t = Float((now - start).truncatingRemainder(dividingBy: 7200))
        u.timeRes = SIMD4<Float>(t, Float(size.width / max(size.height, 1)), Float(size.width), Float(size.height))
        u.levels = smooth
        u.groove = SIMD4<Float>(Float(g.env), Float(g.phase), Float(g.count % 1_000_000), Float(g.step))
        u.drop = SIMD4<Float>(lv.dropCount > 0 ? Float(min(now - lv.dropTime, 1000)) : 1000,
                              Float(lv.dropCount % 1_000_000), swell, lv.active ? 1 : 0)
        u.c1 = pal.c1
        u.c2 = pal.c2
        u.c3 = pal.c3
        u.bg = pal.bg
        u.image = SIMD4<Float>(imageTex == nil ? 0 : 1, imageAspect, min(1, max(0.3, lv.period)), 0)
        return u
    }

    func render(_ view: MTKView, style: VisualStyle) {
        // Render a little below Retina resolution: these are soft images, and it keeps the GPU cool.
        let scale = (view.window?.backingScaleFactor ?? 2) * 0.62
        let want = CGSize(width: max(1, (view.bounds.width * scale).rounded()),
                          height: max(1, (view.bounds.height * scale).rounded()))
        if view.drawableSize != want { view.drawableSize = want }

        if style == .image { ensureImage(Settings.shared.imagePath) }
        guard let pipeline = pipelines[style],
              let queue = queue,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        var u = uniforms(size: view.drawableSize)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<ArtUniforms>.stride, index: 0)
        encoder.setFragmentTexture(imageTex ?? blank, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

/// SwiftUI host for one GPU background.
struct ShaderView: NSViewRepresentable {
    let style: VisualStyle
    let visible: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: ArtEngine.shared.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.autoResizeDrawable = false
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        v.enableSetNeedsDisplay = false
        v.isPaused = false
        v.preferredFramesPerSecond = 60
        context.coordinator.style = style
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        context.coordinator.style = style
        v.preferredFramesPerSecond = visible ? 60 : 1
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var style: VisualStyle = .contour
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) { ArtEngine.shared.render(view, style: style) }
    }
}
