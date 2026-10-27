import SwiftUI
import SceneKit
import AppKit
import simd

/// SwiftUI wrapper around a SceneKit view that renders the 3D bar field.
struct BarsView: NSViewRepresentable {
    let audio: AudioReactor
    @ObservedObject var settings: Settings
    let visible: Bool

    func makeCoordinator() -> BarField { BarField(audio: audio, settings: settings) }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero, options: nil)
        v.scene = context.coordinator.scene
        v.pointOfView = context.coordinator.cameraNode
        v.backgroundColor = .black
        v.antialiasingMode = .multisampling4X
        v.allowsCameraControl = false
        v.rendersContinuously = true
        v.preferredFramesPerSecond = 60
        v.delegate = context.coordinator
        v.isPlaying = true
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        v.preferredFramesPerSecond = visible ? 60 : 1
    }
}

/// A dense grid of square pillars that fills the whole screen and moves in time with the beat.
///  - beat: pillars snap up on the beat and glide back down so they land right before the next one
///          (the fall length follows the song's tempo). Alternate beats favour alternate checkerboard squares.
///  - missed beats: a tempo "flywheel" keeps the groove going between detected beats.
///  - drop: a sudden surge after a quieter stretch launches everything high, with a flash.
///  - bass swell ("둥~~"): the resting floor itself lifts and slowly settles.
///  - highs: random pillars pop.
final class BarField: NSObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let cameraNode = SCNNode()

    private let audio: AudioReactor
    private let settings: Settings

    private struct Bar {
        let node: SCNNode
        let x: Float, z: Float, seed: Float
        let parity: Int
        let delay: Float      // tiny centre-out wave, seconds
        let shimmer: Float    // how much this pillar follows the spectrum
        let bandPos: Float    // 0 at the centre (bass) … 1 at the edges (treble)
        var amp0: Float = 0   // previous beat's height
        var amp1: Float = 0   // current beat's height
        var popT: Float = -10
        var popA: Float = 0
        var level: Int = 0
    }

    private struct Beat {
        var t: Float
        var period: Float
        var synthetic: Bool
    }

    private var bars: [Bar] = []
    private var geoms: [SCNGeometry] = []
    private var mats: [SCNMaterial] = []
    private var lastDropCount: Int?
    private var dropT: Float = -100
    private var bassS: Float = 0

    private var b0 = Beat(t: -10, period: 0.5, synthetic: true)
    private var b1 = Beat(t: -10, period: 0.5, synthetic: true)
    private var beatIdx = 0
    private var lastCount: Int?
    private var lastRealT: Float = -100

    private var swell: Float = 0
    private var fastE: Float = 0
    private var slowE: Float = 0
    private var lastDrop: Float = -100
    private var dropBoost: Float = 0
    private var flash: Float = 0
    private var kick: Float = 0
    private var lastT: Float?
    private var start: TimeInterval?

    // Colours follow Lumn / the album art (see ColorSync), blended smoothly.
    private var pal = Palette.fallback
    private let keyLight = SCNNode()
    private let ambLight = SCNNode()

    // Look
    private let K = 16                 // brightness levels (shared materials)
    private let cell: Float = 0.5      // grid pitch
    private let gap: Float = 0.08      // space between pillars
    private let camPos = SIMD3<Float>(0, 14, 8)
    private let camTarget = SIMD3<Float>(0, 0, -1)
    private let fovDeg: Float = 42
    private let origin = SIMD2<Float>(0, -1.5)   // where the beat wave starts
    private let maxWaveDelay: Float = 0.12

    init(audio: AudioReactor, settings: Settings) {
        self.audio = audio
        self.settings = settings
        super.init()
        build()
    }

    // MARK: - Scene setup

    private func build() {
        scene.background.contents = NSColor.black
        scene.fogColor = NSColor.black
        scene.fogStartDistance = 20
        scene.fogEndDistance = 44

        for _ in 0..<K {
            let m = SCNMaterial()
            m.lightingModel = .blinn
            m.diffuse.contents = NSColor(white: 0.10, alpha: 1)
            m.specular.contents = NSColor(white: 0.5, alpha: 1)
            m.emission.contents = NSColor.black
            mats.append(m)
        }

        let s = CGFloat(cell - gap)
        let box = SCNBox(width: s, height: 1, length: s, chamferRadius: 0.02)
        for i in 0..<K {
            let g = box.copy() as! SCNGeometry
            g.materials = [mats[i]]
            geoms.append(g)
        }

        // Only create pillars the camera can actually see, sized to the widest screen.
        let aspect = Float(NSScreen.screens
            .map { $0.frame.width / max($0.frame.height, 1) }
            .max() ?? 1.6)
        let fwd = simd_normalize(camTarget - camPos)
        let right = simd_normalize(simd_cross(fwd, SIMD3<Float>(0, 1, 0)))
        let up = simd_cross(right, fwd)
        let tanV = tan(fovDeg / 2 * .pi / 180)
        let tanH = tanV * aspect

        func onScreen(_ p: SIMD3<Float>) -> Bool {
            let d = p - camPos
            let depth = simd_dot(d, fwd)
            guard depth > 0.1 else { return false }
            let nx = simd_dot(d, right) / (depth * tanH)
            let ny = simd_dot(d, up) / (depth * tanV)
            return abs(nx) < 1.2 && ny > -1.25 && ny < 1.2
        }

        var spots: [(i: Int, j: Int, x: Float, z: Float, d: Float)] = []
        var maxDist: Float = 1
        for i in -70...70 {
            for j in -60...45 {
                let x = Float(i) * cell, z = Float(j) * cell
                guard onScreen(SIMD3(x, 0, z)) || onScreen(SIMD3(x, 3.5, z)) else { continue }
                let d = simd_length(SIMD2<Float>(x, z) - origin)
                maxDist = max(maxDist, d)
                spots.append((i, j, x, z, d))
            }
        }
        for sp in spots {
            let n = SCNNode(geometry: geoms[0])
            n.pivot = SCNMatrix4MakeTranslation(0, -0.5, 0)   // grow from the floor up
            n.simdPosition = SIMD3<Float>(sp.x, 0, sp.z)
            n.simdScale = SIMD3<Float>(1, 0.25, 1)
            scene.rootNode.addChildNode(n)
            let seed = Float.random(in: 0...1000)
            bars.append(Bar(node: n, x: sp.x, z: sp.z, seed: seed,
                            parity: (sp.i + sp.j) & 1,
                            delay: maxWaveDelay * sp.d / maxDist,
                            shimmer: 0.4 + 0.6 * Float.random(in: 0...1),
                            bandPos: min(1, sp.d / maxDist)))
        }

        // Lights
        let key = keyLight
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 900
        key.light!.color = NSColor(calibratedRed: 0.82, green: 0.86, blue: 1.0, alpha: 1)
        key.simdEulerAngles = SIMD3<Float>(-1.0, 0.6, 0)
        scene.rootNode.addChildNode(key)

        let amb = ambLight
        amb.light = SCNLight()
        amb.light!.type = .ambient
        amb.light!.intensity = 150
        amb.light!.color = NSColor(calibratedRed: 0.35, green: 0.38, blue: 0.55, alpha: 1)
        scene.rootNode.addChildNode(amb)

        // Camera with HDR bloom so tall pillars glow.
        let cam = SCNCamera()
        cam.fieldOfView = CGFloat(fovDeg)
        cam.zNear = 0.1
        cam.zFar = 100
        cam.wantsHDR = true
        cam.bloomThreshold = 0.55
        cam.bloomIntensity = 1.3
        cam.bloomBlurRadius = 14
        cam.vignettingIntensity = 0.5
        cam.vignettingPower = 1.2
        cameraNode.camera = cam
        cameraNode.simdPosition = camPos
        cameraNode.simdLook(at: camTarget)
        scene.rootNode.addChildNode(cameraNode)
    }

    // MARK: - Helpers

    private func noise(_ s: Float, _ k: Int) -> Float {
        let v = sin(s * 12.9898 + Float(k % 100_000) * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }

    private func ease(_ dt: Float, _ tau: Float) -> Float { 1 - exp(-dt / tau) }

    private func rgb(_ c: SIMD4<Float>) -> SIMD3<Float> { SIMD3<Float>(c.x, c.y, c.z) }

    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * min(1, max(0, t))
    }

    private func color(_ c: SIMD3<Float>) -> NSColor {
        NSColor(srgbRed: CGFloat(min(1, max(0, c.x))),
                green: CGFloat(min(1, max(0, c.y))),
                blue: CGFloat(min(1, max(0, c.z))), alpha: 1)
    }

    /// Beat envelope over one beat (p = 0…1): snap up fast, glide down, land at p = 0.9.
    private func env(_ p: Float) -> Float {
        if p <= 0 || p >= 0.9 { return 0 }
        if p < 0.08 {
            let q = 1 - p / 0.08
            return 1 - q * q * q
        }
        let q = (p - 0.08) / 0.82
        return 0.5 * (1 + cos(.pi * q))
    }

    /// Start a new beat: every pillar picks its height for it.
    private func fire(at t: Float, amp: Float, period: Float, drop: Bool, synthetic: Bool) {
        beatIdx += 1
        b0 = b1
        b1 = Beat(t: t, period: period, synthetic: synthetic)
        let odd = beatIdx & 1
        for i in bars.indices {
            var a = amp * (0.6 + 0.8 * noise(bars[i].seed, beatIdx))
            if !drop && odd != bars[i].parity { a *= 0.45 }
            bars[i].amp0 = bars[i].amp1
            bars[i].amp1 = a
        }
    }

    // MARK: - Per-frame update (render thread)

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if start == nil { start = time }
        let t = Float(time - (start ?? time))
        let dt = min(max(t - (lastT ?? t), 0), 0.05)
        lastT = t
        let lv = audio.snapshot().scaled(settings.sensitivity)
        let period = min(1.0, max(0.3, lv.period))
        if lastCount == nil { lastCount = lv.beatCount }

        // Drops come from the audio analyser (shared with every background).
        if lastDropCount == nil { lastDropCount = lv.dropCount }
        let isDrop = lv.dropCount != lastDropCount
        lastDropCount = lv.dropCount
        bassS += (lv.bass - bassS) * (lv.bass > bassS ? ease(dt, 0.05) : ease(dt, 0.3))
        dropBoost *= exp(-dt / 2.0)
        let boost = 1 + 1.2 * dropBoost
        let beatGain = lv.motionGain

        if isDrop {
            lastDrop = t
            dropT = t
            flash = 1
            kick = 1
            dropBoost = 1
            lastCount = lv.beatCount
            lastRealT = t
            fire(at: t, amp: 3.0 * beatGain, period: period, drop: true, synthetic: false)
        } else if lv.beatCount != lastCount {
            lastCount = lv.beatCount
            lastRealT = t
            if b1.synthetic && t - b1.t < 0.2 * b1.period {
                // The flywheel already hit this beat; just line it up with the real one.
                b1.t = t
                b1.synthetic = false
            } else {
                fire(at: t, amp: (0.9 + 1.5 * lv.bass) * boost * beatGain, period: period, drop: false, synthetic: false)
            }
        } else if lv.active && t - lastRealT < 4 && t - b1.t >= b1.period {
            // Flywheel: keep the groove going on the estimated tempo between detected beats.
            let next = b1.t + b1.period
            fire(at: t - next < 0.1 ? next : t, amp: (0.7 + 1.2 * lv.bass) * boost * beatGain,
                 period: period, drop: false, synthetic: true)
        }

        // "둥~~": rise quickly, settle slowly.
        swell += (lv.bass - swell) * (lv.bass > swell ? ease(dt, 0.08) : ease(dt, 0.8))
        flash *= exp(-dt * 2.5)
        kick *= exp(-dt * 3.0)

        let hiBucket = Int(t * 10)
        let sparkle = lv.high > 0.55

        for i in bars.indices {
            var b = bars[i]

            let breath = 0.05 * (sin(b.x * 0.4 + t * 0.8) + sin(b.z * 0.5 - t * 0.6))
            var h = max(0.06, 0.22 + breath + 0.8 * swell)

            // Beat-locked motion (current beat + tail of the previous one).
            h += b.amp1 * env((t - b1.t - b.delay) / b1.period)
            h += b.amp0 * env((t - b0.t - b.delay) / b0.period)

            // Live bass shimmer so the field always moves with the music.
            // Spectrum landscape: centre pillars follow the bass, outer ones the treble.
            h += 0.8 * Float(Spectrum.at(lv.spectrum, Double(b.bandPos))) * (0.55 + 0.45 * b.shimmer)

            // Highs: random short pops.
            if sparkle && t - b.popT > 0.5 && noise(b.seed, hiBucket) > 0.993 {
                b.popT = t
                b.popA = 0.9 * lv.high
            }
            h += b.popA * env((t - b.popT) / 0.35)

            b.node.simdScale = SIMD3<Float>(1, max(0.05, h), 1)

            let lvl = min(K - 1, max(0, Int(h / 3.2 * Float(K - 1))))
            if lvl != b.level {
                b.node.geometry = geoms[lvl]
                b.level = lvl
            }
            bars[i] = b
        }

        // Recolour by height using the Lumn / album palette:
        // low pillars sit in the dark base tone, tall ones glow in the main accent.
        pal = pal.lerp(to: ColorSync.shared.palette, t: ease(dt, 0.8))
        let c1 = rgb(pal.c1), c2 = rgb(pal.c2), c3 = rgb(pal.c3), bg = rgb(pal.bg)
        let white = SIMD3<Float>(1, 1, 1)
        for i in 0..<K {
            let f = Float(i) / Float(K - 1)
            let g = min(1, f + 0.15 * lv.mid)
            var c: SIMD3<Float>
            if g < 0.35 {
                c = mix(bg * 3, c3, g / 0.35)
            } else if g < 0.7 {
                c = mix(c3, c2, (g - 0.35) / 0.35)
            } else {
                c = mix(c2, c1, (g - 0.7) / 0.3)
            }
            c = mix(c, white, 0.3 * flash)
            let bright = 0.03 + 1.1 * pow(f, 1.8) + 0.35 * flash
            mats[i].emission.contents = color(c * bright)
            mats[i].diffuse.contents = color(bg * 1.6 + 0.04)
        }
        keyLight.light?.color = color(mix(SIMD3<Float>(0.85, 0.88, 1.0), c1, 0.25))
        ambLight.light?.color = color(mix(bg * 4, c3 * 0.4, 0.3))

        // Gentle camera sway; dips on drops and swells.
        let a = 0.06 * sin(t * 0.05)
        let base = camPos - SIMD3<Float>(0, 0.6 * swell + 1.2 * kick, 0)
        let off = base - camTarget
        let rotated = SIMD3<Float>(off.x * cos(a) + off.z * sin(a), off.y, -off.x * sin(a) + off.z * cos(a))
        cameraNode.simdPosition = camTarget + rotated
        cameraNode.simdLook(at: camTarget)
    }
}
