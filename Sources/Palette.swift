import AppKit
import SwiftUI

/// Four colors handed to the shaders: three accents and a dark base.
struct Palette: Equatable {
    var c1, c2, c3, bg: SIMD4<Float>

    static let fallback = Palette.fromHue(0.62)

    static func fromHue(_ hue: Double) -> Palette {
        let h = Float(hue)
        return Palette(
            c1: rgba(hsv2rgb(h, 0.70, 0.95)),
            c2: rgba(hsv2rgb(h + 0.08, 0.60, 0.90)),
            c3: rgba(hsv2rgb(h - 0.10, 0.75, 0.85)),
            bg: rgba(hsv2rgb(h, 0.55, 0.07))
        )
    }

    /// Palette built from Lumn's two fixed ambient colors.
    static func fromLumn(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Palette {
        let ha = rgb2hsv(a)
        let hb = rgb2hsv(b)
        let mid = rgb2hsv((a + b) * 0.5)
        let c3 = hsv2rgb(mid.x - 0.04, min(1, max(ha.y, hb.y)), max(0.8, mid.z))
        let bg = hsv2rgb(ha.x, min(0.7, ha.y), 0.075)
        return Palette(
            c1: rgba(hsv2rgb(ha.x, max(ha.y, 0.45), max(ha.z, 0.85))),
            c2: rgba(hsv2rgb(hb.x, max(hb.y, 0.45), max(hb.z, 0.85))),
            c3: rgba(c3),
            bg: rgba(bg)
        )
    }

    var rgb1: SIMD3<Float> { SIMD3<Float>(c1.x, c1.y, c1.z) }
    var rgb2: SIMD3<Float> { SIMD3<Float>(c2.x, c2.y, c2.z) }

    func lerp(to other: Palette, t: Float) -> Palette {
        Palette(
            c1: c1 + (other.c1 - c1) * t,
            c2: c2 + (other.c2 - c2) * t,
            c3: c3 + (other.c3 - c3) * t,
            bg: bg + (other.bg - bg) * t
        )
    }

    func color(_ index: Int) -> Color {
        switch index {
        case 0: return c1.color
        case 1: return c2.color
        case 2: return c3.color
        default: return bg.color
        }
    }
}

extension SIMD4 where Scalar == Float {
    var color: Color { Color(red: Double(x), green: Double(y), blue: Double(z)) }
}

func rgba(_ c: SIMD3<Float>) -> SIMD4<Float> { SIMD4<Float>(c.x, c.y, c.z, 1) }

func hsv2rgb(_ hue: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
    let h = hue - floorf(hue)
    let h6 = h * 6
    let c = v * s
    let x = c * (1 - abs(h6.truncatingRemainder(dividingBy: 2) - 1))
    let m = v - c
    var rgb = SIMD3<Float>(0, 0, 0)
    switch Int(h6) {
    case 0: rgb = SIMD3<Float>(c, x, 0)
    case 1: rgb = SIMD3<Float>(x, c, 0)
    case 2: rgb = SIMD3<Float>(0, c, x)
    case 3: rgb = SIMD3<Float>(0, x, c)
    case 4: rgb = SIMD3<Float>(x, 0, c)
    default: rgb = SIMD3<Float>(c, 0, x)
    }
    return rgb + SIMD3<Float>(m, m, m)
}

func rgb2hsv(_ c: SIMD3<Float>) -> SIMD3<Float> {
    let mx = max(c.x, max(c.y, c.z))
    let mn = min(c.x, min(c.y, c.z))
    let d = mx - mn
    var h: Float = 0
    if d > 1e-5 {
        if mx == c.x {
            h = (c.y - c.z) / d
            if h < 0 { h += 6 }
        } else if mx == c.y {
            h = (c.z - c.x) / d + 2
        } else {
            h = (c.x - c.y) / d + 4
        }
        h /= 6
    }
    let s: Float = mx > 1e-5 ? d / mx : 0
    return SIMD3<Float>(h, s, mx)
}

/// Pulls a glow-friendly palette out of album artwork.
enum PaletteExtractor {
    static func extract(from image: NSImage) -> Palette? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = 32, h = 32
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }

        var weights = [Float](repeating: 0, count: 12)
        var sums = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: 12)
        var dark = SIMD3<Float>(0, 0, 0)
        var darkCount: Float = 0
        var all = SIMD3<Float>(0, 0, 0)

        for i in 0..<(w * h) {
            let rgb = SIMD3<Float>(Float(pixels[i * 4]) / 255, Float(pixels[i * 4 + 1]) / 255, Float(pixels[i * 4 + 2]) / 255)
            all += rgb
            let hsv = rgb2hsv(rgb)
            if hsv.z < 0.35 { dark += rgb; darkCount += 1 }
            guard hsv.y > 0.18, hsv.z > 0.18 else { continue }
            let wgt = hsv.y * hsv.y * sqrtf(hsv.z)
            let bucket = min(11, Int(hsv.x * 12))
            weights[bucket] += wgt
            sums[bucket] += rgb * wgt
        }

        let ranked = (0..<12).filter { weights[$0] > 2.0 }.sorted { weights[$0] > weights[$1] }
        var accents: [SIMD3<Float>] = ranked.prefix(3).map { sums[$0] / weights[$0] }

        let mean = all / Float(w * h)
        if accents.isEmpty {
            // Monochrome artwork: keep it monochrome but bright enough to glow.
            let v = max(0.75, rgb2hsv(mean).z)
            accents = [SIMD3<Float>(v, v, v * 1.02), SIMD3<Float>(v * 0.8, v * 0.8, v * 0.85), SIMD3<Float>(v * 0.6, v * 0.6, v * 0.65)]
        } else {
            let base = rgb2hsv(accents[0])
            while accents.count < 3 {
                let shift: Float = accents.count == 1 ? 0.07 : -0.09
                accents.append(hsv2rgb(base.x + shift, base.y, base.z))
            }
            accents = accents.map(vivid)
        }

        let darkAvg = darkCount > 0 ? dark / darkCount : mean * 0.2
        var bgHSV = rgb2hsv(darkAvg * 0.4 + accents[0] * 0.6)
        bgHSV.y = min(bgHSV.y, 0.7)
        bgHSV.z = 0.075
        let bg = hsv2rgb(bgHSV.x, bgHSV.y, bgHSV.z)

        return Palette(c1: rgba(accents[0]), c2: rgba(accents[1]), c3: rgba(accents[2]), bg: rgba(bg))
    }

    private static func vivid(_ c: SIMD3<Float>) -> SIMD3<Float> {
        var hsv = rgb2hsv(c)
        hsv.y = min(1, max(hsv.y, 0.45) * 1.05)
        hsv.z = max(hsv.z, 0.82)
        return hsv2rgb(hsv.x, hsv.y, hsv.z)
    }
}
