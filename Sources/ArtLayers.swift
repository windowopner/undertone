import SwiftUI

// Abstract-art backgrounds. No text anywhere — only curves, flat colour and tempo-locked motion.
// Colours always come from the current Lumn / album palette (ColorSync).

// MARK: - Beat clock shared by every piece

struct Groove {
    /// 0…1 pulse for the current beat: snaps up, glides down, lands just before the next beat.
    var env: Double = 0
    /// 0…1 position inside the current beat.
    var phase: Double = 0
    /// Monotonic beat counter (includes tempo-flywheel beats between detections).
    var count: Int = 0

    private static var lastRaw = 0
    private static var mono = 0

    /// Call on the main thread (TimelineView bodies).
    static func from(_ lv: Levels, now: TimeInterval) -> Groove {
        guard lv.beatCount > 0 else { return Groove() }
        let period = Double(min(1.0, max(0.3, lv.period)))
        var p = (now - lv.beatTime) / period
        var weight = 1.0
        var raw = lv.beatCount
        if p >= 1 {
            // Flywheel: keep pulsing on the estimated tempo for a few beats while music plays.
            if lv.active && p < 8 {
                let k = floor(p)
                p -= k
                raw += Int(k)
                weight = 0.75
            } else {
                p = 0.99
                weight = 0
            }
        }
        if raw > lastRaw { mono += raw - lastRaw }
        lastRaw = raw
        return Groove(env: weight * shape(p) * Double(lv.motionGain), phase: p, count: mono)
    }

    static func shape(_ p: Double) -> Double {
        if p <= 0 || p >= 0.9 { return 0 }
        if p < 0.08 {
            let q = 1 - p / 0.08
            return 1 - q * q * q
        }
        let q = (p - 0.08) / 0.82
        return 0.5 * (1 + cos(.pi * q))
    }

    /// Eased 0→1 across the first third of the beat, for "click forward on every beat" motion.
    var step: Double {
        let p = min(1, phase / 0.35)
        return 1 - pow(1 - p, 3)
    }

    /// Alternate beats favour alternate elements.
    func accent(_ index: Int) -> Double {
        index % 2 == count % 2 ? env : env * 0.3
    }
}

// MARK: - Palette tones

private func hsv(_ c: SIMD4<Float>) -> SIMD3<Float> { rgb2hsv(SIMD3<Float>(c.x, c.y, c.z)) }

private func col(_ c: SIMD3<Float>, _ alpha: Double = 1) -> Color {
    Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: alpha)
}

private func mixc(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Double) -> SIMD3<Float> {
    a + (b - a) * Float(min(1, max(0, t)))
}

/// Harmonised tones derived from the palette: accents slightly muted, plus a pale and a deep tone.
private struct Tones {
    let ground: SIMD3<Float>   // background
    let deep: SIMD3<Float>
    let a: SIMD3<Float>
    let b: SIMD3<Float>
    let c: SIMD3<Float>
    let pale: SIMD3<Float>

    init(_ p: Palette) {
        let h1 = hsv(p.c1), h2 = hsv(p.c2), h3 = hsv(p.c3), hb = hsv(p.bg)
        ground = hsv2rgb(hb.x, min(hb.y, 0.5), 0.055)
        deep = hsv2rgb(h1.x, min(0.55, h1.y), 0.2)
        a = hsv2rgb(h1.x, h1.y * 0.85, h1.z * 0.92)
        b = hsv2rgb(h2.x, h2.y * 0.8, h2.z * 0.88)
        c = hsv2rgb(h3.x, h3.y * 0.75, h3.z * 0.8)
        pale = hsv2rgb(h3.x, 0.12, 0.92)
    }

    /// Same hue as `base`, explicit saturation scale and value — for colour fields.
    static func shade(_ base: SIMD4<Float>, sat: Float, val: Float) -> SIMD3<Float> {
        let h = hsv(base)
        return hsv2rgb(h.x, min(1, h.y * sat), val)
    }
}

// MARK: - 물결 선 (op-art: dense flowing lines bent by two wandering lenses)

struct ContourLayer: View {
    let t: Double
    let lv: Levels
    let g: Groove
    let pal: Palette

    var body: some View {
        Canvas { ctx, size in
            let T = Tones(pal)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(col(T.ground)))
            let w = Double(size.width), h = Double(size.height)
            let m = min(w, h)
            let bass = Double(lv.bass), mid = Double(lv.mid)

            // Lens 1 bulges lines apart (swells on the beat), lens 2 pinches them together.
            let l1 = (x: w * (0.34 + 0.16 * sin(t * 0.07)), y: h * (0.46 + 0.2 * cos(t * 0.05)))
            let l2 = (x: w * (0.7 + 0.12 * cos(t * 0.06 + 1)), y: h * (0.55 + 0.18 * sin(t * 0.045 + 2)))
            let r1 = m * (0.2 + 0.06 * bass + 0.07 * g.env)
            let r2 = m * (0.16 + 0.05 * mid)

            let n = 46
            let spacing = h / Double(n - 1)
            let step = 6.0
            let spec = lv.spectrum

            for i in 0..<n {
                let f = Double(i) / Double(n - 1)
                let base = f * h
                let wave = spacing * 0.9 * (0.3 + 1.0 * Spectrum.at(spec, 1 - f) + 0.9 * Spectrum.at(lv.punch, 1 - f))
                var path = Path()
                var x = -step
                var first = true
                while x <= w + step {
                    var y = base + wave * sin(x * 0.0042 + t * 0.32 + f * 3.4)
                    let d1x = x - l1.x, d1y = base - l1.y
                    y += exp(-(d1x * d1x + d1y * d1y) / (r1 * r1)) * d1y * 0.6
                    let d2x = x - l2.x, d2y = base - l2.y
                    y -= exp(-(d2x * d2x + d2y * d2y) / (r2 * r2)) * d2y * 0.45
                    let pt = CGPoint(x: x, y: y)
                    if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
                    x += step
                }
                let tone = f < 0.5 ? mixc(T.c, T.a, f * 2) : mixc(T.a, T.b, (f - 0.5) * 2)
                let lw = 1.1 + 2.4 * pow(sin(.pi * f), 2) + 1.6 * g.accent(i)
                ctx.stroke(path, with: .color(col(tone, 0.92)), lineWidth: lw)
            }
        }
    }
}

// MARK: - 컷아웃 (paper cut-outs: calm drift, kick on drums, re-arranged on drops)

struct CutoutLayer: View {
    let t: Double
    let lv: Levels
    let g: Groove
    let pal: Palette

    /// Deterministic layout for a given "scene" (one scene per drop).
    private func spot(_ k: Int, _ scene: Int) -> (x: Double, y: Double) {
        func r(_ n: Double) -> Double {
            let v = sin(n * 12.9898 + Double(k) * 78.233 + Double(scene) * 37.719) * 43758.5453
            return v - floor(v)
        }
        if k == 0 { return (0.35 + 0.3 * r(1), 0.35 + 0.3 * r(2)) }   // the big ground shape stays central
        return (0.1 + 0.8 * r(1), 0.12 + 0.76 * r(2))
    }

    var body: some View {
        Canvas { ctx, size in
            let T = Tones(pal)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(col(T.ground)))
            let w = Double(size.width), h = Double(size.height)
            let m = min(w, h)
            let now = ProcessInfo.processInfo.systemUptime

            // Drops: glide every shape to a new arrangement over ~1.4 s.
            let scene = lv.dropCount
            let x = scene == 0 ? 1 : min(1, max(0, (now - lv.dropTime) / 1.4))
            let e = x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
            let palette = [T.deep, T.a, T.pale, T.b, T.c, T.a, T.b]

            for k in 0..<7 {
                let s = Double(k) * 1.7
                let p0 = spot(k, scene - 1), p1 = spot(k, scene)
                var cx = w * (p0.x + (p1.x - p0.x) * e)
                var cy = h * (p0.y + (p1.y - p0.y) * e)
                // Slow drift so it never sits still.
                cx += m * 0.04 * sin(t * 0.03 + s)
                cy += m * 0.04 * cos(t * 0.025 + s * 1.3)

                // Drums: alternate shapes thump outward from the centre and come back.
                let hit = g.accent(k)
                let dx = cx - w / 2, dy = cy - h / 2
                let dl = max(1, (dx * dx + dy * dy).squareRoot())
                cx += dx / dl * m * 0.018 * hit
                cy += dy / dl * m * 0.018 * hit

                let size0 = k == 0 ? 0.42 : 0.12 + 0.05 * Double(k % 3)
                let R = m * size0 * (1 + 0.06 * hit)
                let rot = t * 0.012 * (k % 2 == 0 ? 1 : -1) + s
                let morph = t * 0.05   // constant, slow: no audio in the outline itself

                var path = Path()
                let steps = 120
                for j in 0...steps {
                    let th = Double(j) / Double(steps) * 2 * .pi
                    let r = R * (1
                        + 0.17 * sin(2 * th + morph + s)
                        + 0.10 * sin(3 * th - morph * 0.8 + s * 2)
                        + 0.05 * sin(5 * th + morph * 1.3 + s * 3))
                    let pt = CGPoint(x: cx + r * cos(th + rot), y: cy + r * sin(th + rot))
                    if j == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.closeSubpath()
                // Each drop also rotates which shape wears which colour (the big one keeps the deep tone).
                let ci = k == 0 ? 0 : 1 + (k - 1 + scene) % (palette.count - 1)
                let grp = [(0, 2), (3, 4), (5, 6), (7, 8), (9, 10), (11, 12), (13, 15)][k]
                let glow = Spectrum.avg(lv.spectrum, grp.0, grp.1)
                ctx.fill(path, with: .color(col(mixc(palette[ci], T.pale, 0.16 * glow))))
            }

            // Two long drifting strands, like scissor-cut ribbons.
            for k in 0..<2 {
                var path = Path()
                let y0 = h * (k == 0 ? 0.28 : 0.74)
                var px = -20.0
                var first = true
                while px <= w + 20 {
                    let y = y0 + m * 0.06 * sin(px * 0.006 + t * 0.12 + Double(k) * 2)
                        + m * 0.025 * sin(px * 0.017 - t * 0.18)
                    let pt = CGPoint(x: px, y: y)
                    if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
                    px += 8
                }
                ctx.stroke(path, with: .color(col(k == 0 ? T.pale : T.c, 0.9)),
                           style: StrokeStyle(lineWidth: 5 + 3 * g.accent(k + 1), lineCap: .round))
            }
        }
    }
}

// MARK: - 궤도 (kinetic sculpture: off-centre arcs that click forward on every beat)

struct OrbitLayer: View {
    let t: Double
    let lv: Levels
    let g: Groove
    let pal: Palette

    private let radii: [Double] = [0.07, 0.12, 0.165, 0.23, 0.28, 0.35, 0.405, 0.5, 0.63]
    private let widths: [Double] = [9, 2.5, 6, 15, 2, 8, 3, 12, 4]
    private let speeds: [Double] = [0.12, -0.07, 0.05, -0.03, 0.09, -0.05, 0.02, -0.015, 0.01]

    var body: some View {
        Canvas { ctx, size in
            let T = Tones(pal)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(col(T.ground)))
            let w = Double(size.width), h = Double(size.height)
            let m = min(w, h)
            let c = CGPoint(x: w * 0.6, y: h * 0.53)
            let tones = [T.a, T.pale, T.b, T.deep, T.c, T.a, T.pale, T.b, T.c]
            let beats = Double(g.count) + g.step

            for i in radii.indices {
                let dir = speeds[i] >= 0 ? 1.0 : -1.0
                let start = t * speeds[i] + dir * 0.24 * beats + Double(i) * 1.3
                let band = Spectrum.at(lv.spectrum, 1 - Double(i) / Double(radii.count - 1))
                let len = (0.45 + 0.9 * abs(sin(Double(i) * 2.1))) * (0.7 + 0.55 * band) * .pi
                let r = m * radii[i] * (1 + 0.02 * g.accent(i))
                var arc = Path()
                arc.addArc(center: c, radius: r, startAngle: .radians(start),
                           endAngle: .radians(start + len), clockwise: false)
                ctx.stroke(arc, with: .color(col(tones[i])),
                           style: StrokeStyle(lineWidth: widths[i] * (1 + 0.4 * band), lineCap: .round))
            }

            // Three bodies riding on orbits, swelling on alternate beats.
            for (j, oi) in [2, 4, 7].enumerated() {
                let dir = j % 2 == 0 ? 1.0 : -1.0
                let a = t * 0.04 * dir + dir * 0.24 * beats + Double(j) * 2.2
                let r = m * radii[oi]
                let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                let s = m * (0.016 + 0.009 * Double(j)) * (1 + 0.6 * g.accent(j))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - s, y: p.y - s, width: 2 * s, height: 2 * s)),
                         with: .color(col([T.pale, T.a, T.b][j])))
            }

            // One faint counter-weight circle off to the side.
            let big = m * 0.9
            let bc = CGPoint(x: w * 0.18, y: h * 0.2)
            ctx.stroke(Path(ellipseIn: CGRect(x: bc.x - big, y: bc.y - big, width: 2 * big, height: 2 * big)),
                       with: .color(col(T.c, 0.25)), lineWidth: 1.5)
        }
    }
}

// MARK: - 색면 (colour field: soft-edged bands that breathe with the bass)

struct FieldLayer: View {
    let t: Double
    let lv: Levels
    let g: Groove
    let pal: Palette

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let bass = Double(lv.bass)
            let ground = Tones.shade(pal.c1, sat: 0.6, val: 0.12)
            let top = Tones.shade(pal.c1, sat: 0.8, val: 0.55)
            let thin = Tones.shade(pal.c2, sat: 0.7, val: 0.72)
            let low = Tones.shade(pal.c3, sat: 0.6, val: 0.38)
            let blur = 24 + 22 * bass
            let lowB = Spectrum.avg(lv.spectrum, 0, 4)
            let midB = Spectrum.avg(lv.spectrum, 5, 9)
            let highB = Spectrum.avg(lv.spectrum, 10, 15)

            let topH = h * (0.44 + 0.025 * sin(t * 0.05) + 0.02 * bass)
            let thinH = h * (0.1 + 0.02 * g.env)
            let lowH = h * (0.3 - 0.02 * sin(t * 0.05))
            let gap = h * 0.035
            let y0 = h * 0.07

            ZStack {
                col(ground)
                band(top, w * 0.84, topH, w / 2, y0 + topH / 2, blur, 0.08 * g.accent(0) + 0.07 * lowB)
                band(thin, w * 0.8, thinH, w / 2, y0 + topH + gap + thinH / 2, blur * 0.8, 0.1 * g.accent(1) + 0.07 * midB)
                band(low, w * 0.84, lowH, w / 2, y0 + topH + gap * 2 + thinH + lowH / 2, blur, 0.08 * g.accent(2) + 0.07 * highB)
            }
            .drawingGroup()
        }
    }

    private func band(_ c: SIMD3<Float>, _ bw: CGFloat, _ bh: CGFloat,
                      _ x: CGFloat, _ y: CGFloat, _ blur: Double, _ lift: Double) -> some View {
        Rectangle()
            .fill(col(c))
            .frame(width: bw, height: bh)
            .brightness(lift)
            .blur(radius: blur)
            .position(x: x, y: y)
    }
}

// MARK: - 소리의 천 (a woven fabric of lines: every part of the spectrum moves it at its own scale)
//   bass         → two large bulges swell the fabric like a dome (and one pinches it)
//   low → high   → six wave layers, each driven by its own band group: low bands make long slow
//                   swells, high bands make short quick ripples
//   kick         → a ripple ring spreads from a wandering point
//   drop         → the whole weave turns to a new direction

struct WeaveLayer: View {
    let t: Double
    let lv: Levels
    let g: Groove
    let pal: Palette

    /// (first band, last band, wavelength as a fraction of the short side, speed rad/s, direction rad, gain)
    private let comps: [(Int, Int, Double, Double, Double, Double)] = [
        (3, 4, 0.90, 0.35, 0.30, 2.00),
        (5, 6, 0.55, 0.50, -0.50, 1.70),
        (7, 8, 0.33, 0.70, 0.90, 1.45),
        (9, 10, 0.20, 1.00, -1.20, 1.10),
        (11, 12, 0.11, 1.50, 0.15, 0.75),
        (13, 15, 0.05, 2.40, -0.70, 0.38),
    ]

    /// Weave direction for a given drop scene: stays mostly horizontal so lyrics stay readable.
    private func angle(_ scene: Int) -> Double { 0.32 * sin(Double(scene) * 1.9) }

    var body: some View {
        Canvas { ctx, size in
            let T = Tones(pal)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(col(T.ground)))
            let w = Double(size.width), h = Double(size.height)
            let m = min(w, h)
            let s = lv.spectrum
            let now = ProcessInfo.processInfo.systemUptime

            // Drop: glide to a new weave direction.
            let scene = lv.dropCount
            let x = scene == 0 ? 1 : min(1, max(0, (now - lv.dropTime) / 1.6))
            let e = x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
            let ang = angle(scene - 1) + (angle(scene) - angle(scene - 1)) * e
            let eu = (x: cos(ang), y: sin(ang))      // along the lines
            let ev = (x: -sin(ang), y: cos(ang))     // across the lines
            let cx = w / 2, cy = h / 2

            let spacing = h / 54
            let stepU = 8.0
            let ca = abs(cos(ang)), sa = abs(sin(ang))
            let uHalf = (w * ca + h * sa) / 2 + 40
            let vHalf = (h * ca + w * sa) / 2 + spacing * 3
            let iMax = Int((uHalf / stepU).rounded(.up))
            let jMax = Int((vHalf / spacing).rounded(.up))
            let nPts = 2 * iMax + 1

            // Wave layers: precompute the along-line part once per frame (sin(a+b) = sin a cos b + cos a sin b).
            let nc = comps.count
            var amp = [Double](repeating: 0, count: nc)
            var kv = [Double](repeating: 0, count: nc)
            var kc = [Double](repeating: 0, count: nc)
            var sinU = [Double](repeating: 0, count: nc * nPts)
            var cosU = [Double](repeating: 0, count: nc * nPts)
            for c in 0..<nc {
                let (lo, hi, lambda, speed, dir, gain) = comps[c]
                let k = 2 * .pi / (lambda * m)
                let kx = k * cos(dir), ky = k * sin(dir)
                let ku = kx * eu.x + ky * eu.y
                kv[c] = kx * ev.x + ky * ev.y
                kc[c] = kx * cx + ky * cy + speed * t
                // level sets the base swell, the attack makes every hit in that range jump like a kick
                amp[c] = spacing * gain * (0.05 + 0.65 * Spectrum.avg(s, lo, hi) + 0.85 * Spectrum.avg(lv.punch, lo, hi))
                for i in 0..<nPts {
                    let a = ku * Double(i - iMax) * stepU
                    sinU[c * nPts + i] = sin(a)
                    cosU[c * nPts + i] = cos(a)
                }
            }

            // Bass bulges (separable gaussians in line coordinates).
            let bass = Spectrum.avg(s, 0, 2)
            let lowMid = Spectrum.avg(s, 2, 4)
            let B1 = (x: w * (0.38 + 0.14 * sin(t * 0.05)), y: h * (0.45 + 0.15 * cos(t * 0.04)))
            let B2 = (x: w * (0.68 + 0.12 * cos(t * 0.045 + 1)), y: h * (0.56 + 0.14 * sin(t * 0.035 + 2)))
            let b1u = (B1.x - cx) * eu.x + (B1.y - cy) * eu.y, b1v = (B1.x - cx) * ev.x + (B1.y - cy) * ev.y
            let b2u = (B2.x - cx) * eu.x + (B2.y - cy) * eu.y, b2v = (B2.x - cx) * ev.x + (B2.y - cy) * ev.y
            let r1 = m * (0.22 + 0.06 * bass), r2 = m * 0.17
            let k1 = 0.15 + 0.85 * bass         // dome: pushes lines apart
            let k2 = -(0.08 + 0.45 * lowMid)    // pinch: pulls them together
            var g1u = [Double](repeating: 0, count: nPts)
            var g2u = [Double](repeating: 0, count: nPts)
            for i in 0..<nPts {
                let u = Double(i - iMax) * stepU
                g1u[i] = exp(-(u - b1u) * (u - b1u) / (r1 * r1))
                g2u[i] = exp(-(u - b2u) * (u - b2u) / (r2 * r2))
            }

            // Kick ripple.
            let F = (x: w * (0.5 + 0.28 * sin(t * 0.05)), y: h * (0.5 + 0.18 * cos(t * 0.04)))
            let front = g.phase * m * 0.9
            let ripA = spacing * 2.2 * g.env
            let ripW2 = pow(m * 0.05, 2)

            // Strums: every line trembles like a plucked string (standing waves, ~9 Hz shiver).
            let vibA = spacing * 1.0 * Double(lv.strum)
            let kS = 2 * .pi / (m * 0.18)
            var sinS = [Double](repeating: 0, count: nPts)
            var cosS = [Double](repeating: 0, count: nPts)
            if vibA > 0.05 {
                for i in 0..<nPts {
                    let a = kS * Double(i - iMax) * stepU
                    sinS[i] = sin(a)
                    cosS[i] = cos(a)
                }
            }
            let vibT = 2 * .pi * 9.0 * t

            let lw0 = 0.8 + 0.9 * Double(lv.level)
            var sv = [Double](repeating: 0, count: nc)
            var cv = [Double](repeating: 0, count: nc)

            for j in -jMax...jMax {
                let v = Double(j) * spacing
                for c in 0..<nc {
                    let a = kv[c] * v + kc[c]
                    sv[c] = sin(a)
                    cv[c] = cos(a)
                }
                let g1v = exp(-(v - b1v) * (v - b1v) / (r1 * r1))
                let g2v = exp(-(v - b2v) * (v - b2v) / (r2 * r2))
                let jd = Double(j)
                let vf = vibA * sin(vibT + jd * 0.35)
                let cphi = cos(jd * 0.3), sphi = sin(jd * 0.3)

                var path = Path()
                for i in 0..<nPts {
                    let u = Double(i - iMax) * stepU
                    var d = 0.0
                    for c in 0..<nc {
                        d += amp[c] * (sinU[c * nPts + i] * cv[c] + cosU[c * nPts + i] * sv[c])
                    }
                    d += k1 * (v - b1v) * g1u[i] * g1v
                    d += k2 * (v - b2v) * g2u[i] * g2v
                    if vibA > 0.05 {
                        d += vf * (sinS[i] * cphi + cosS[i] * sphi)
                    }
                    let bx = cx + u * eu.x + v * ev.x
                    let by = cy + u * eu.y + v * ev.y
                    if ripA > 0.05 {
                        let dx = bx - F.x, dy = by - F.y
                        let rr = (dx * dx + dy * dy).squareRoot() - front
                        d += ripA * exp(-rr * rr / ripW2)
                    }
                    let pt = CGPoint(x: bx + d * ev.x, y: by + d * ev.y)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }

                let f = min(1, max(0, (v + vHalf) / (2 * vHalf)))
                let tone = f < 0.5 ? mixc(T.c, T.a, f * 2) : mixc(T.a, T.b, (f - 0.5) * 2)
                let parity = ((j % 2) + 2) % 2
                ctx.stroke(path, with: .color(col(tone, 0.9)), lineWidth: lw0 + 0.9 * g.accent(parity))
            }
        }
    }
}
