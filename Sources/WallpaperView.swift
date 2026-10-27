import SwiftUI
import AppKit

struct WallpaperView: View {
    let audio: AudioReactor
    @ObservedObject var settings: Settings
    @ObservedObject var visibility: WindowVisibility

    var body: some View {
        Group {
            if settings.style == .bars {
                // SceneKit drives its own frame loop.
                BarsView(audio: audio, settings: settings, visible: visibility.visible)
            } else {
                // 60 fps while the desktop is visible, 1 fps while windows cover it.
                TimelineView(.animation(minimumInterval: visibility.visible ? 1.0 / 60.0 : 1.0)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    let lv = audio.snapshot().scaled(settings.sensitivity)
                    let g = Groove.from(lv, now: ProcessInfo.processInfo.systemUptime)
                    let pal = ColorSync.shared.palette
                    Group {
                        switch settings.style {
                        case .bars: Color.black
                        case .weave: WeaveLayer(t: t, lv: lv, g: g, pal: pal)
                        case .contour: ContourLayer(t: t, lv: lv, g: g, pal: pal)
                        case .cutout: CutoutLayer(t: t, lv: lv, g: g, pal: pal)
                        case .orbit: OrbitLayer(t: t, lv: lv, g: g, pal: pal)
                        case .field: FieldLayer(t: t, lv: lv, g: g, pal: pal)
                        case .aurora: AuroraLayer(t: t, lv: lv)
                        case .pulse: PulseLayer(t: t, lv: lv)
                        case .image: ImageLayer(path: settings.imagePath, t: t, lv: lv)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Aurora: soft colour blobs drifting and swelling with the music

struct AuroraLayer: View {
    let t: Double
    let lv: Levels

    // (base hue, x speed, y speed, phase)
    private let blobs: [(Double, Double, Double, Double)] = [
        (0.62, 0.050, 0.041, 0.0),
        (0.78, 0.037, 0.053, 1.7),
        (0.92, 0.044, 0.032, 3.1),
        (0.55, 0.029, 0.047, 4.4),
        (0.70, 0.058, 0.027, 5.6),
    ]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(red: 0.03, green: 0.03, blue: 0.06)))
            ctx.blendMode = .screen
            let m = Double(min(size.width, size.height))
            for (i, b) in blobs.enumerated() {
                // Blob i answers to its slice of the spectrum (blob 0 = bass … last = treble).
                let band = Float(Spectrum.at(lv.spectrum, Double(i) / Double(blobs.count - 1)))
                let cx = Double(size.width) * (0.5 + 0.35 * sin(t * b.1 + b.3))
                let cy = Double(size.height) * (0.5 + 0.30 * cos(t * b.2 + b.3 * 1.7))
                let r = m * (0.35 + 0.25 * Double(band) + 0.10 * Double(lv.beat))
                var hue = (b.0 + 0.08 * Double(lv.mid) + t * 0.004).truncatingRemainder(dividingBy: 1)
                if hue < 0 { hue += 1 }
                let c = Color(hue: hue, saturation: 0.75, brightness: 0.45 + 0.5 * Double(band))
                let rect = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
                ctx.fill(Path(ellipseIn: rect),
                         with: .radialGradient(Gradient(colors: [c.opacity(0.85), c.opacity(0)]),
                                               center: CGPoint(x: cx, y: cy),
                                               startRadius: 0, endRadius: r))
            }
        }
    }
}

// MARK: - Pulse: rings radiating from the centre, thicker on bass hits

struct PulseLayer: View {
    let t: Double
    let lv: Levels

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(red: 0.02, green: 0.02, blue: 0.04)))
            ctx.blendMode = .screen
            let cx = Double(size.width) / 2, cy = Double(size.height) / 2
            let c = CGPoint(x: cx, y: cy)
            let maxR = Double(hypot(size.width, size.height)) / 2
            let n = 7
            for k in 0..<n {
                let phase = (t * 0.10 + Double(k) / Double(n)).truncatingRemainder(dividingBy: 1)
                let r = maxR * phase
                let alpha = (1 - phase) * (0.12 + 0.6 * Double(lv.level))
                let hue = (0.58 + 0.18 * Double(k) / Double(n) + 0.1 * Double(lv.mid))
                    .truncatingRemainder(dividingBy: 1)
                ctx.stroke(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
                           with: .color(Color(hue: hue, saturation: 0.6, brightness: 1).opacity(alpha)),
                           lineWidth: 2 + (34 * Spectrum.at(lv.spectrum, 1 - phase) + 6 * Double(lv.bass)) * (1 - phase))
            }
            let g = maxR * (0.15 + 0.25 * Double(lv.bass) + 0.15 * Double(lv.beat))
            let gc = Color(hue: 0.62 + 0.1 * Double(lv.mid), saturation: 0.7, brightness: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: cx - g, y: cy - g, width: 2 * g, height: 2 * g)),
                     with: .radialGradient(Gradient(colors: [gc.opacity(0.5 + 0.4 * Double(lv.level)), .clear]),
                                           center: c, startRadius: 0, endRadius: g))
        }
    }
}

// MARK: - Image: your own picture, breathing and glowing with the music

enum ImageCache {
    private static var path: String?
    private static var image: NSImage?

    static func get(_ p: String?) -> NSImage? {
        if p != path {
            path = p
            image = p.flatMap { NSImage(contentsOfFile: $0) }
        }
        return image
    }
}

struct ImageLayer: View {
    let path: String?
    let t: Double
    let lv: Levels

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let img = ImageCache.get(path) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(1.02 + 0.04 * Double(lv.bass) + 0.02 * Double(lv.beat))
                        .brightness(-0.12 + 0.18 * Double(lv.level))
                        .clipped()
                } else {
                    AuroraLayer(t: t, lv: lv)
                }
                LinearGradient(
                    colors: [.clear,
                             Color(hue: (0.6 + 0.15 * Double(lv.mid)).truncatingRemainder(dividingBy: 1),
                                   saturation: 0.8, brightness: 1).opacity(0.35 * Spectrum.avg(lv.spectrum, 0, 3))],
                    startPoint: .center, endPoint: .bottom)
                    .blendMode(.screen)
            }
        }
    }
}
