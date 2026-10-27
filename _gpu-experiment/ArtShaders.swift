/// Metal source for the abstract backgrounds, compiled at launch (no Xcode step).
/// Every piece: palette from Lumn / album art, tempo-locked motion, drops re-compose the scene,
/// film grain + vignette to finish. No text anywhere.
enum ArtShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct U {
    float4 timeRes;   // t, aspect, width, height
    float4 levels;    // bass, mid, high, level (smoothed)
    float4 groove;    // beat env, beat phase, beat count, step
    float4 drop;      // seconds since drop, drop count, slow swell, active
    float4 c1;
    float4 c2;
    float4 c3;
    float4 bg;
    float4 image;     // has image, image aspect, beat period, 0
};

struct VOut {
    float4 pos [[position]];
    float2 uv;        // 0...1, y up
};

vertex VOut art_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// ------------------------------------------------------------------ helpers

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    float2 w = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

static float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + float2(1.7, 9.2);
        a *= 0.5;
    }
    return v;
}

static float fbm3(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 3; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + float2(1.7, 9.2);
        a *= 0.5;
    }
    return v / 0.875;
}

static float2 rot(float2 p, float a) {
    float c = cos(a);
    float s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

static float sstep(float a, float b, float x) {
    float t = clamp((x - a) / (b - a), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

static float luma(float3 col) {
    return dot(col, float3(0.299, 0.587, 0.114));
}

static float3 rgb2hsv(float3 col) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(col.b, col.g, K.w, K.z), float4(col.g, col.b, K.x, K.y), step(col.b, col.g));
    float4 q = mix(float4(p.x, p.y, p.w, col.r), float4(col.r, p.y, p.z, p.x), step(p.x, col.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

static float3 hsv2rgb(float3 hsv) {
    float3 p = abs(fract(float3(hsv.x) + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return hsv.z * mix(float3(1.0), clamp(p - 1.0, float3(0.0), float3(1.0)), hsv.y);
}

/// Same hue, scaled saturation, explicit brightness.
static float3 shade(float3 col, float satMul, float val) {
    float3 h = rgb2hsv(col);
    return hsv2rgb(float3(h.x, clamp(h.y * satMul, 0.0, 1.0), val));
}

static float3 pale(float3 col) {
    float3 h = rgb2hsv(col);
    return hsv2rgb(float3(h.x, 0.12, 0.92));
}

struct Ctx {
    float t;
    float aspect;
    float bass;
    float mid;
    float high;
    float level;
    float env;
    float phase;
    float count;
    float stepv;
    float dropAge;
    float dropCount;
    float swell;
    float active;
    float period;
    float3 c1;
    float3 c2;
    float3 c3;
    float3 bg;
};

static Ctx makeCtx(constant U& u) {
    Ctx c;
    c.t = u.timeRes.x;
    c.aspect = u.timeRes.y;
    c.bass = u.levels.x;
    c.mid = u.levels.y;
    c.high = u.levels.z;
    c.level = u.levels.w;
    c.env = u.groove.x;
    c.phase = u.groove.y;
    c.count = u.groove.z;
    c.stepv = u.groove.w;
    c.dropAge = u.drop.x;
    c.dropCount = u.drop.y;
    c.swell = u.drop.z;
    c.active = u.drop.w;
    c.period = u.image.z;
    c.c1 = u.c1.rgb;
    c.c2 = u.c2.rgb;
    c.c3 = u.c3.rgb;
    c.bg = u.bg.rgb;
    return c;
}

/// Alternate beats favour alternate elements.
static float accent(Ctx c, float i) {
    return fmod(i + c.count, 2.0) < 0.5 ? c.env : c.env * 0.3;
}

static float easeInOut(float x) {
    x = clamp(x, 0.0, 1.0);
    return x < 0.5 ? 4.0 * x * x * x : 1.0 - pow(-2.0 * x + 2.0, 3.0) * 0.5;
}

/// 0 → 1 transition after each drop (1 when there has never been one).
static float dropMix(Ctx c, float dur) {
    return c.dropCount < 0.5 ? 1.0 : easeInOut(c.dropAge / dur);
}

static float dropFlash(Ctx c, float k) {
    return c.dropCount < 0.5 ? 0.0 : exp(-c.dropAge * k);
}

static float4 finish(float3 col, float2 uv, float2 px, Ctx c, float grain, float vig) {
    float2 q = uv - 0.5;
    col *= clamp(1.0 - dot(q, q) * vig, 0.0, 1.0);
    float n = hash21(px + fract(c.t * 7.13) * 113.7) - 0.5;
    col += n * grain;
    return float4(saturate(col), 1.0);
}

// ------------------------------------------------------------------ 물결 선
// Terraced contour map: a slowly folding landscape cut into stacked paper layers,
// each edge lit from the top-left. Beats send a ripple through the terrain,
// drops morph it into a new landscape.

fragment float4 art_contour(VOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    Ctx c = makeCtx(u);
    float2 p = (in.uv - 0.5) * float2(c.aspect, 1.0);
    float dm = dropMix(c, 1.8);
    float sA = c.dropCount - 1.0;
    float sB = c.dropCount;

    float2 flow = float2(c.t * 0.016, -c.t * 0.010);
    float2 q = p * 1.3 + flow;
    float2 w = float2(fbm(q + float2(0.0, c.t * 0.02)), fbm(q + float2(5.2, 1.3) - c.t * 0.015));
    float hA = fbm(q + 0.9 * w + float2(sA * 3.1, sA * 5.3));
    float hB = fbm(q + 0.9 * w + float2(sB * 3.1, sB * 5.3));
    float h = mix(hA, hB, dm);
    h = 0.5 + (h - 0.5) * (0.9 + 0.5 * c.swell);

    float2 f = float2(0.3 * c.aspect * sin(c.t * 0.05), 0.16 * cos(c.t * 0.04));
    float r = length(p - f);
    float front = c.phase * 0.95;
    h += 0.05 * c.env * exp(-(r - front) * (r - front) * 80.0);

    float N = 15.0;
    float v = h * N;
    float band = floor(v);
    float fr = fract(v);
    float fw = max(fwidth(v), 1e-4);
    float dl = min(fr, 1.0 - fr);
    float lw = 0.035 + 0.05 * accent(c, band);
    float lineMask = 1.0 - smoothstep(lw, lw + fw * 1.5, dl);

    float hn = saturate((h - 0.22) / 0.56);
    float bn = saturate((band / N - 0.22) / 0.56);
    float3 ground = shade(c.bg, 0.6, 0.05);
    float3 terrace = mix(ground, shade(c.c3, 0.7, 0.32), pow(bn, 1.25));

    float2 gv = float2(dfdx(v), dfdy(v));
    float lit = dot(normalize(gv + 1e-6), normalize(float2(-0.6, 0.8)));
    float shadowAmt = smoothstep(0.55, 1.0, fr) * (0.25 + 0.2 * lit);
    float rim = (1.0 - smoothstep(0.0, 0.10, fr)) * (0.06 + 0.06 * lit);
    float3 col = terrace * (1.0 - shadowAmt) + rim;

    float3 lc = mix(c.c3, c.c1, sstep(0.0, 0.6, hn));
    lc = mix(lc, c.c2, sstep(0.6, 1.0, hn));
    col = mix(col, lc * (0.85 + 0.3 * c.level), lineMask * 0.92);

    // quiet moiré of fine counter-rotated hairlines
    float h2 = fbm3(rot(p, 0.6) * 1.8 - flow * 1.3 + 7.0);
    float v2 = h2 * 46.0;
    float d2 = min(fract(v2), 1.0 - fract(v2));
    float hair = 1.0 - smoothstep(0.02, 0.02 + max(fwidth(v2), 1e-4) * 1.5, d2);
    col = mix(col, lc, hair * 0.07);

    col += lc * lineMask * 0.5 * dropFlash(c, 2.0);
    return finish(col, in.uv, in.pos.xy, c, 0.03, 0.9);
}

// ------------------------------------------------------------------ 컷아웃
// Gouache-painted paper shapes on textured paper, each casting a soft shadow.
// Drums thump them outward, drops slide everything into a new arrangement.

static float2 cutSpot(float k, float scene, float aspect) {
    float2 r = float2(hash21(float2(k * 7.13 + 0.5, scene * 3.71 + 1.3)),
                      hash21(float2(k * 1.91 + 4.2, scene * 5.17 + 0.7)));
    r = (k < 0.5) ? (0.35 + 0.3 * r) : (0.1 + 0.8 * r);
    return (r - 0.5) * float2(aspect, 1.0);
}

static float blob(float2 q, float R, float morph, float s) {
    float th = atan2(q.y, q.x);
    float rr = R * (1.0 + 0.17 * sin(2.0 * th + morph + s)
                        + 0.10 * sin(3.0 * th - morph * 0.8 + s * 2.0)
                        + 0.05 * sin(5.0 * th + morph * 1.3 + s * 3.0));
    return length(q) - rr;
}

static float ribbonY(float x, float j, float t) {
    float y0 = j < 0.5 ? 0.22 : -0.24;
    return y0 + 0.06 * sin(x * 6.0 + t * 0.12 + j * 2.0) + 0.025 * sin(x * 17.0 - t * 0.18);
}

fragment float4 art_cutout(VOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    Ctx c = makeCtx(u);
    float2 p = (in.uv - 0.5) * float2(c.aspect, 1.0);
    float dm = dropMix(c, 1.4);

    float3 paper = shade(c.bg, 0.45, 0.10);
    float grainP = 0.55 * vnoise(p * 420.0) + 0.45 * fbm3(p * float2(14.0, 40.0));
    float3 col = paper * (0.9 + 0.16 * grainP);

    float3 tones[6] = {
        shade(c.c1, 0.55, 0.22),
        c.c1 * 0.92,
        pale(c.c3),
        c.c2 * 0.88,
        c.c3 * 0.80,
        mix(c.c1, c.c2, 0.5) * 0.9
    };
    float morph = c.t * 0.05;
    float2 L = normalize(float2(-0.5, 0.7));

    for (int k = 0; k < 7; k++) {
        float kf = float(k);
        float s = kf * 1.7;
        float2 pos = mix(cutSpot(kf, c.dropCount - 1.0, c.aspect), cutSpot(kf, c.dropCount, c.aspect), dm);
        pos += 0.04 * float2(sin(c.t * 0.03 + s), cos(c.t * 0.025 + s * 1.3));
        float hit = accent(c, kf);
        pos += normalize(pos + 1e-4) * 0.018 * hit;
        float R = (k == 0 ? 0.42 : 0.12 + 0.05 * fmod(kf, 3.0)) * (1.0 + 0.06 * hit);
        float ang = c.t * 0.012 * (fmod(kf, 2.0) < 0.5 ? 1.0 : -1.0) + s;

        float2 qs = rot(p - pos - float2(0.011, -0.015) * (1.0 + 1.5 * hit), -ang);
        float ds = blob(qs, R, morph, s);
        col *= 1.0 - 0.36 * (1.0 - smoothstep(-0.015, 0.045, ds));

        float2 q = rot(p - pos, -ang);
        float d = blob(q, R, morph, s) + (vnoise(q * 70.0 + s) - 0.5) * 0.004;
        float aa = max(fwidth(d), 1e-4);
        float fillMask = 1.0 - smoothstep(-aa, aa, d);
        int ci = (k == 0) ? 0 : 1 + int(fmod(kf - 1.0 + c.dropCount, 5.0));
        float3 tone = tones[ci] * (0.95 + 0.09 * vnoise(q * 260.0 + s * 3.0));
        float2 nrm = normalize(float2(dfdx(d), dfdy(d)) + 1e-6);
        float edgeBand = 1.0 - smoothstep(0.0, 0.007, -d);
        tone += edgeBand * 0.09 * dot(nrm, L);
        col = mix(col, tone, fillMask);
    }

    for (int j = 0; j < 2; j++) {
        float jf = float(j);
        float wdt = 0.0045 + 0.003 * accent(c, jf + 1.0);
        float ys = ribbonY(p.x - 0.011, jf, c.t);
        float dsr = abs(p.y + 0.015 - ys) - wdt;
        col *= 1.0 - 0.3 * (1.0 - smoothstep(-0.004, 0.02, dsr));
        float y = ribbonY(p.x, jf, c.t);
        float dr = abs(p.y - y) - wdt;
        float aa = max(fwidth(dr), 1e-4);
        float m = 1.0 - smoothstep(-aa, aa, dr);
        col = mix(col, j == 0 ? tones[2] : tones[4], m);
    }

    col += 0.05 * dropFlash(c, 3.0);
    return finish(col, in.uv, in.pos.xy, c, 0.04, 0.8);
}

// ------------------------------------------------------------------ 궤도
// Kinetic sculpture: lacquered tube arcs and three spheres, lit from the top-left,
// casting shadows on a dark ground. They click forward on every beat and
// make one full turn on a drop.

static float arcSDF(float2 q, float r, float a0, float len, float w) {
    float th = atan2(q.y, q.x);
    float rel = fmod(th - a0, 6.2831853);
    if (rel < 0.0) rel += 6.2831853;
    if (rel <= len) return abs(length(q) - r) - w;
    float2 e0 = r * float2(cos(a0), sin(a0));
    float2 e1 = r * float2(cos(a0 + len), sin(a0 + len));
    return min(length(q - e0), length(q - e1)) - w;
}

static float3 tubeShade(float3 tone, float d, float w, float2 grad) {
    float k = clamp(-d / w, 0.0, 1.0);
    float z = sqrt(clamp(1.0 - (1.0 - k) * (1.0 - k), 0.0, 1.0));
    float3 n = normalize(float3(normalize(grad + 1e-6) * (1.0 - k), z + 1e-3));
    float3 L = normalize(float3(-0.5, 0.6, 0.75));
    float diff = max(dot(n, L), 0.0);
    float spec = pow(max(dot(reflect(-L, n), float3(0.0, 0.0, 1.0)), 0.0), 28.0);
    return tone * (0.3 + 0.8 * diff) + spec * 0.35;
}

fragment float4 art_orbit(VOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    Ctx c = makeCtx(u);
    float2 p = (in.uv - 0.5) * float2(c.aspect, 1.0);
    float2 ctr = float2(0.1 * c.aspect, -0.03);
    float2 q = p - ctr;
    float rq = length(q);

    float3 col = shade(c.bg, 0.5, 0.045) + shade(c.c1, 0.5, 0.09) * exp(-rq * 2.6);
    col *= 0.94 + 0.08 * fbm3(p * 3.0 + c.t * 0.01);

    const float radii[9] = {0.07, 0.12, 0.165, 0.23, 0.28, 0.35, 0.405, 0.5, 0.63};
    const float widths[9] = {0.0085, 0.0025, 0.0055, 0.014, 0.002, 0.0075, 0.003, 0.011, 0.004};
    const float speeds[9] = {0.12, -0.07, 0.05, -0.03, 0.09, -0.05, 0.02, -0.015, 0.01};
    float3 paleC = pale(c.c3);
    float3 tones[5] = { c.c1 * 0.92, paleC, c.c2 * 0.88, shade(c.c1, 0.55, 0.3), c.c3 * 0.85 };
    float beats = c.count + c.stepv;
    float spin = dropMix(c, 1.6) * 6.2831853;
    float flash = dropFlash(c, 2.0);

    // faint orbit guides
    float frq = max(fwidth(rq), 1e-4);
    for (int i = 0; i < 9; i++) {
        float g = abs(rq - radii[i]);
        col += paleC * 0.05 * (1.0 - smoothstep(0.0, frq * 1.2, g));
    }

    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        float dir = speeds[i] >= 0.0 ? 1.0 : -1.0;
        float a0 = c.t * speeds[i] + dir * 0.24 * beats + fi * 1.3 + dir * spin;
        float len = (0.45 + 0.9 * abs(sin(fi * 2.1))) * 3.14159265 * (0.8 + 0.3 * c.mid);
        float w = widths[i] * (1.0 + 0.35 * c.bass);
        float r = radii[i] * (1.0 + 0.02 * accent(c, fi));
        float ds = arcSDF(q - float2(0.009, -0.013), r, a0, len, w);
        col *= 1.0 - 0.33 * (1.0 - smoothstep(-0.004, 0.025, ds));
        float d = arcSDF(q, r, a0, len, w);
        float aa = max(fwidth(d), 1e-4);
        float m = 1.0 - smoothstep(-aa, aa, d);
        float3 tone = tones[i % 5] * (1.0 + 0.6 * flash);
        float3 shaded = tubeShade(tone, d, w, float2(dfdx(d), dfdy(d)));
        col = mix(col, shaded, m);
    }

    const int orbitIdx[3] = {2, 4, 7};
    float3 L = normalize(float3(-0.5, 0.6, 0.75));
    for (int j = 0; j < 3; j++) {
        float jf = float(j);
        float dir = (j % 2 == 0) ? 1.0 : -1.0;
        float a = c.t * 0.04 * dir + dir * 0.24 * beats + jf * 2.2 + dir * spin;
        float r = radii[orbitIdx[j]];
        float2 pp = r * float2(cos(a), sin(a));
        float s = (0.016 + 0.009 * jf) * (1.0 + 0.6 * accent(c, jf));
        float2 sq = (q - pp - float2(0.01, -0.014)) / s;
        col *= 1.0 - 0.35 * (1.0 - smoothstep(0.7, 1.6, length(sq)));
        float2 lq = (q - pp) / s;
        float ll = length(lq);
        float aa = max(fwidth(ll), 1e-4);
        float m = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, ll);
        float z = sqrt(clamp(1.0 - ll * ll, 0.0, 1.0));
        float3 n = normalize(float3(lq, z + 1e-3));
        float diff = max(dot(n, L), 0.0);
        float spec = pow(max(dot(reflect(-L, n), float3(0.0, 0.0, 1.0)), 0.0), 40.0);
        float3 tone = (j == 0) ? paleC : ((j == 1) ? c.c1 : c.c2);
        col = mix(col, tone * (0.25 + 0.85 * diff) + spec * 0.5, m);
    }

    float dB = abs(length(p - float2(-0.32 * c.aspect, 0.3)) - 0.9) - 0.0012;
    col += c.c3 * 0.18 * (1.0 - smoothstep(0.0, max(fwidth(dB), 1e-4) * 1.5, dB));
    return finish(col, in.uv, in.pos.xy, c, 0.025, 0.85);
}

// ------------------------------------------------------------------ 색면
// Colour-field painting: three glazed bands with brushy, breathing edges on primed
// canvas. Beats lift alternate bands, drops re-proportion and re-colour them.

static float sdBox(float2 q, float2 b) {
    float2 d = abs(q) - b;
    return length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0);
}

static float3 fieldTone(Ctx c, int i) {
    int k = i % 4;
    if (k == 0) return shade(c.c1, 0.85, 0.55);
    if (k == 1) return shade(c.c2, 0.75, 0.72);
    if (k == 2) return shade(c.c3, 0.65, 0.36);
    return shade(c.c2, 0.85, 0.42);
}

static float3 fieldHeights(float scene) {
    float a = hash21(float2(scene * 1.37 + 0.2, 4.1));
    float b = hash21(float2(scene * 2.11 + 1.7, 0.6));
    float top = 0.36 + 0.14 * a;
    float thin = 0.07 + 0.07 * b;
    float low = 0.79 - top - thin;
    return float3(top, thin, low);
}

fragment float4 art_field(VOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    Ctx c = makeCtx(u);
    float2 p = (in.uv - 0.5) * float2(c.aspect, 1.0);
    float dm = dropMix(c, 2.2);
    float3 hh = mix(fieldHeights(c.dropCount - 1.0), fieldHeights(c.dropCount), dm);
    float breathe = 0.02 * sin(c.t * 0.05) + 0.015 * c.swell;
    hh.x += breathe;
    hh.z -= breathe;

    float3 ground = shade(c.c1, 0.6, 0.11);
    float weave = 0.5 + 0.25 * (sin(in.pos.x * 1.9) + sin(in.pos.y * 1.9));
    float tooth = fbm3(p * 22.0);
    float3 col = ground * (0.9 + 0.08 * weave + 0.12 * tooth);

    float y = 0.5 - 0.07;
    float halfW = 0.42 * c.aspect;
    float feather = 0.022 + 0.03 * c.swell;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float hgt = (i == 0) ? hh.x : ((i == 1) ? hh.y : hh.z);
        float cy = y - hgt * 0.5;
        y -= hgt + 0.035;
        float2 q = p - float2(0.0, cy);
        float d = sdBox(q, float2(halfW - (i == 1 ? 0.02 : 0.0), hgt * 0.5));
        d += (fbm(p * float2(2.5, 6.0) + fi * 3.1 + c.t * 0.008) - 0.5) * 0.06;
        float a = 1.0 - smoothstep(-feather, feather, d);
        int iA = i + int(fmod(c.dropCount - 1.0 + 400.0, 4.0));
        int iB = i + int(fmod(c.dropCount + 400.0, 4.0));
        float3 tone = mix(fieldTone(c, iA), fieldTone(c, iB), dm);
        float brush = fbm(float2(p.x * 1.6, p.y * 14.0) + fi * 9.0 + c.t * 0.004);
        tone *= 0.82 + 0.32 * brush;
        float inner = 1.0 - smoothstep(-0.12, 0.0, d);
        tone *= 1.0 + 0.12 * inner + 0.10 * accent(c, fi);
        col = mix(col, tone, a * 0.93);
    }

    col += 0.04 * dropFlash(c, 2.0);
    return finish(col, in.uv, in.pos.xy, c, 0.03, 0.7);
}

// ------------------------------------------------------------------ 오로라
// Curtains of light with fine vertical striations over a deep sky.
// Mids sway the curtains, a glow climbs them on each beat, drops make them surge.

fragment float4 art_aurora(VOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    Ctx c = makeCtx(u);
    float2 p = (in.uv - 0.5) * float2(c.aspect, 1.0);

    float3 col = mix(shade(c.bg, 0.6, 0.025), shade(c.c3, 0.5, 0.085), sstep(0.5, -0.5, p.y));
    float st = hash21(floor(in.pos.xy / 1.5));
    float tw = 0.5 + 0.5 * sin(c.t * 1.7 + st * 60.0);
    col += step(0.9978, st) * tw * 0.55 * sstep(-0.25, 0.3, p.y);

    float surge = 0.16 * dropFlash(c, 0.7);
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float xs = p.x * (0.75 + 0.22 * fi) + fi * 3.7;
        float sway = fbm3(float2(xs * 0.9 + c.t * 0.03 * (1.0 + 0.3 * fi), c.t * 0.05 + fi * 1.9));
        float base = -0.2 + 0.07 * fi + (sway - 0.5) * 0.5 * (0.7 + 0.6 * c.mid) - surge;
        float above = p.y - base;
        float bottom = smoothstep(-0.012, 0.012, above);
        float fade = exp(-max(above, 0.0) * (5.0 - 1.6 * c.swell));
        float stri = 0.5 + 0.5 * vnoise(float2(xs * 42.0, c.t * 0.22 + fi * 7.0));
        stri *= 0.65 + 0.35 * vnoise(float2(xs * 8.0, c.t * 0.08 + fi));
        float trav = above - c.phase * 0.45;
        float beatGlow = 1.0 + 0.7 * accent(c, fi) * exp(-trav * trav * 140.0);
        float I = bottom * fade * stri * beatGlow * (0.45 + 0.7 * c.level) / (1.0 + 0.35 * fi);
        float3 cc = mix(c.c1, c.c2, saturate(above * 2.5));
        cc = mix(cc, c.c3, sstep(0.25, 0.6, above));
        col += cc * I * 0.5;
    }

    col += mix(c.c1, c.c3, 0.5) * 0.06 * exp(-abs(p.y + 0.42) * 9.0);
    return finish(col, in.uv, in.pos.xy, c, 0.02, 0.8);
}

// ------------------------------------------------------------------ 펄스
// Ripple tank: each beat drops a stone from one of three points, waves interfere on a
// dark liquid surface that catches the light. Drops send one big wave from the centre.

static float rippleHeight(float2 p, Ctx c) {
    float2 em0 = float2(-0.28 * c.aspect, 0.08);
    float2 em1 = float2(0.22 * c.aspect, -0.12);
    float2 em2 = float2(0.02 * c.aspect, 0.22);
    float h = 0.012 * sin(p.x * 9.0 + c.t * 0.6) * sin(p.y * 7.0 - c.t * 0.45);
    if (c.count > 0.5) {
        for (int k = 0; k < 4; k++) {
            float kf = float(k);
            float age = (c.phase + kf) * c.period;
            float idx = fmod(c.count - kf + 300.0, 3.0);
            float2 em = idx < 0.5 ? em0 : (idx < 1.5 ? em1 : em2);
            float x = length(p - em) - age * 0.55;
            float amp = (1.0 - 0.22 * kf) * (0.5 + 0.7 * c.bass) * (0.6 + 0.4 * c.active);
            h += amp * 0.03 * sin(x * 52.0) * exp(-x * x * 30.0) * exp(-age * 0.7);
        }
    }
    if (c.dropCount > 0.5 && c.dropAge < 5.0) {
        float x = length(p) - c.dropAge * 0.6;
        h += 0.07 * sin(x * 30.0) * exp(-x * x * 12.0) * exp(-c.dropAge * 0.5);
    }
    return h;
}

fragment float4 art_pulse(VOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    Ctx c = makeCtx(u);
    float2 p = (in.uv - 0.5) * float2(c.aspect, 1.0);
    float e = 0.0015;
    float h = rippleHeight(p, c);
    float hx = rippleHeight(p + float2(e, 0.0), c) - rippleHeight(p - float2(e, 0.0), c);
    float hy = rippleHeight(p + float2(0.0, e), c) - rippleHeight(p - float2(0.0, e), c);
    float3 n = normalize(float3(-hx / (2.0 * e) * 0.6, -hy / (2.0 * e) * 0.6, 1.0));
    float3 L = normalize(float3(-0.45, 0.55, 0.7));
    float diff = max(dot(n, L), 0.0);
    float spec = pow(max(dot(reflect(-L, n), float3(0.0, 0.0, 1.0)), 0.0), 70.0);

    float3 deep = mix(shade(c.bg, 0.6, 0.035), shade(c.c1, 0.6, 0.13), 0.5 + 0.5 * p.y);
    float3 col = deep * (0.55 + 0.6 * diff);
    col += c.c2 * saturate(h * 14.0) * 0.22;
    col += mix(c.c1, pale(c.c3), 0.5) * spec * (0.9 + 0.6 * c.high);
    col += c.c1 * 0.25 * dropFlash(c, 1.5) * saturate(1.0 - length(p));
    return finish(col, in.uv, in.pos.xy, c, 0.025, 0.85);
}

// ------------------------------------------------------------------ 내 이미지
// Your picture, slowly drifting; a lens ripple on each beat, colour split on drops,
// a light grade toward the album palette.

fragment float4 art_image(VOut in [[stage_in]], constant U& u [[buffer(0)]],
                          texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
    Ctx c = makeCtx(u);
    float2 p = (in.uv - 0.5) * float2(c.aspect, 1.0);
    if (u.image.x < 0.5) {
        float3 col = mix(shade(c.bg, 0.6, 0.05), shade(c.c1, 0.6, 0.16), fbm3(p * 1.5 + c.t * 0.02));
        return finish(col, in.uv, in.pos.xy, c, 0.03, 0.9);
    }
    float ia = u.image.y;
    float2 uvc = in.uv - 0.5;
    if (c.aspect > ia) { uvc.y *= ia / c.aspect; } else { uvc.x *= c.aspect / ia; }
    float zoom = 1.06 + 0.03 * sin(c.t * 0.03) + 0.025 * c.swell;
    uvc = uvc / zoom + 0.02 * float2(sin(c.t * 0.021), cos(c.t * 0.017));

    float rr = length(uvc * float2(c.aspect, 1.0)) - c.phase * 0.75;
    uvc += normalize(uvc + 1e-5) * 0.006 * c.env * exp(-rr * rr * 90.0);

    float ca = 0.0035 * dropFlash(c, 1.5) + 0.0007 * c.bass;
    float2 tR = float2(0.5 + uvc.x * (1.0 + ca), 0.5 - uvc.y * (1.0 + ca));
    float2 tG = float2(0.5 + uvc.x, 0.5 - uvc.y);
    float2 tB = float2(0.5 + uvc.x * (1.0 - ca), 0.5 - uvc.y * (1.0 - ca));
    float3 col = float3(tex.sample(smp, tR).r, tex.sample(smp, tG).g, tex.sample(smp, tB).b);

    float3 duo = mix(shade(c.bg, 0.6, 0.05), c.c1, luma(col));
    col = mix(col, duo, 0.16);
    col *= 0.86 + 0.22 * c.level;
    return finish(col, in.uv, in.pos.xy, c, 0.02, 0.9);
}
"""#
}
