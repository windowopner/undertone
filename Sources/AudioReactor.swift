import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import ScreenCaptureKit

struct Levels {
    var level: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var high: Float = 0
    var beat: Float = 0
    /// Increments on every detected beat — never missed, unlike the decaying `beat` value.
    var beatCount: Int = 0
    /// Uptime (seconds) of the last detected beat.
    var beatTime: TimeInterval = 0
    /// Estimated seconds per beat (0.3…1.0), from recent beat intervals.
    var period: Float = 0.5
    /// True while there is audible sound.
    var active: Bool = false
    /// Increments on every detected drop (sudden surge after a quieter stretch).
    var dropCount: Int = 0
    /// Uptime (seconds) of the last drop.
    var dropTime: TimeInterval = 0
    /// 16 log-spaced bands from 40 Hz (index 0) to 12 kHz (index 15), each 0…1, auto-gained and smoothed.
    var spectrum: [Float] = Array(repeating: 0, count: Spectrum.count)
    /// Per-band attacks (0…1): jumps when that band is suddenly hit (snare, hats, plucks…), falls fast.
    var punch: [Float] = Array(repeating: 0, count: Spectrum.count)
    /// Strummed / sustained mid-range energy (guitars, held synths): 0…1, rises on strums, rings out.
    var strum: Float = 0
    /// The reaction-strength setting this snapshot was scaled with (1 = neutral).
    var gain: Float = 1

    /// Applies the reaction-strength setting (0.2…3). A curve rather than a plain multiply:
    /// above 1 it boosts quiet parts without flattening loud ones against the ceiling,
    /// below 1 it calms everything down without going dead.
    func scaled(_ s: Double) -> Levels {
        let f = Float(min(4, max(0.05, s)))
        func c(_ v: Float) -> Float { 1 - pow(1 - min(1, max(0, v)), f) }
        var o = self
        o.level = c(level); o.bass = c(bass); o.mid = c(mid); o.high = c(high)
        o.spectrum = spectrum.map(c)
        o.punch = punch.map(c)
        o.strum = c(strum)
        o.gain = f
        return o
    }

    /// How much beat-driven motion should scale with the setting (gentler than the levels).
    var motionGain: Float { min(1.8, pow(gain, 0.7)) }
}

/// Helpers for reading the 16-band spectrum smoothly.
enum Spectrum {
    static let count = 16

    /// Value at a continuous position 0…1 (0 = lowest band, 1 = highest), linearly interpolated
    /// so neighbouring elements never step.
    static func at(_ s: [Float], _ x: Double) -> Double {
        guard s.count == count else { return 0 }
        let p = min(1, max(0, x)) * Double(count - 1)
        let i = Int(p)
        let j = min(count - 1, i + 1)
        let f = p - Double(i)
        return Double(s[i]) * (1 - f) + Double(s[j]) * f
    }

    /// Average of bands lo...hi (inclusive).
    static func avg(_ s: [Float], _ lo: Int, _ hi: Int) -> Double {
        guard s.count == count, lo <= hi else { return 0 }
        var t: Float = 0
        for k in lo...hi { t += s[k] }
        return Double(t) / Double(hi - lo + 1)
    }
}

/// Captures system audio (whatever is playing — Spotify, Apple Music, YouTube…)
/// via ScreenCaptureKit and turns it into smoothed 0…1 levels, beats and tempo.
final class AudioReactor: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "undertone.audio")
    private let lock = NSLock()
    private var current = Levels()
    private var starting = false
    private var askedPermission = false

    // DSP state (audio queue only)
    private var lpB: Float = 0
    private var lpM: Float = 0
    private var peaks: [Float] = [0.05, 0.05, 0.05, 0.05]
    private var smooth = Levels()
    private var lastUpdate: TimeInterval = 0
    private var bassMean: Float = 0
    private var bassVar: Float = 0
    private var prevBass: Float = 0
    private var lastBeat: TimeInterval = 0
    private var intervals: [Float] = []
    private var fastRaw: Float = 0
    private var slowRaw: Float = 0
    private var lastDrop: TimeInterval = -100

    // 16-band filter bank (band-pass biquads, transposed direct form II)
    private var bankRate: Float = 0
    private var bq: [(b0: Float, b2: Float, a1: Float, a2: Float)] = []
    private var z1 = [Float](repeating: 0, count: Spectrum.count)
    private var z2 = [Float](repeating: 0, count: Spectrum.count)
    private var bandSum = [Float](repeating: 0, count: Spectrum.count)
    private var bandPeaks = [Float](repeating: 0.001, count: Spectrum.count)
    private var slowSpec = [Float](repeating: 0, count: Spectrum.count)
    private var prevMidE: Float = 0
    private var prevLowE: Float = 0

    /// Read on the main thread for the menu.
    private(set) var status = "연결 중…"

    func snapshot() -> Levels {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// True once this process has screen & system audio recording permission.
    /// macOS only applies a new grant after the app restarts.
    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func start() {
        guard !starting, stream == nil else { return }
        // Never touch ScreenCaptureKit without permission — every attempt pops the system dialog.
        guard hasPermission else {
            setStatus("권한 필요 — 허용한 다음 메뉴에서 'Undertone 재시작'")
            if !askedPermission {
                askedPermission = true
                DispatchQueue.main.async { _ = CGRequestScreenCaptureAccess() }   // asks at most once per launch
            }
            retry(after: 3)   // silent check only
            return
        }
        starting = true
        Task { await self.startCapture() }
    }

    func restart() {
        if let s = stream {
            stream = nil
            s.stopCapture { _ in }
        }
        setStatus("연결 중…")
        start()
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }

    private func retry(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.start() }
    }

    private func startCapture() async {
        defer { starting = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                setStatus("디스플레이를 못 찾음 — 다시 시도 중")
                retry(after: 4)
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            // We only want audio; keep the video side as cheap as possible.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            setStatus("듣는 중")
        } catch {
            setStatus("오디오 연결 실패 — 잠시 후 다시 시도")
            retry(after: 15)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        setStatus("끊김 — 다시 연결 중…")
        retry(after: 3)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        process(sb)
    }

    private func process(_ sb: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return }
        let fs = Float(asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000)

        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard sizeNeeded > 0 else { return }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded,
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard st == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let chPerBuf = interleaved ? max(Int(asbd.mChannelsPerFrame), 1) : 1
        guard let buf0 = buffers.first, let p0 = buf0.mData else { return }
        let frames = Int(buf0.mDataByteSize) / (MemoryLayout<Float>.size * chPerBuf)
        guard frames > 0 else { return }

        let channels: [UnsafeMutablePointer<Float>] = interleaved
            ? [p0.assumingMemoryBound(to: Float.self)]
            : buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }

        // One-pole filters split the signal into bass (<150 Hz), mid (150–2k), high (>2k).
        let aB = 1 - exp(-2 * Float.pi * 150 / fs)
        let aM = 1 - exp(-2 * Float.pi * 2000 / fs)
        var sB: Float = 0, sM: Float = 0, sH: Float = 0, sAll: Float = 0
        if fs != bankRate { setupBank(fs) }
        let nb = Spectrum.count
        for k in 0..<nb { bandSum[k] = 0 }

        for i in 0..<frames {
            var x: Float = 0
            if interleaved {
                let p = channels[0]
                for c in 0..<chPerBuf { x += p[i * chPerBuf + c] }
                x /= Float(chPerBuf)
            } else {
                for p in channels { x += p[i] }
                x /= Float(max(channels.count, 1))
            }
            lpB += aB * (x - lpB)
            lpM += aM * (x - lpM)
            let b = lpB, m = lpM - lpB, h = x - lpM
            sB += b * b; sM += m * m; sH += h * h; sAll += x * x
            for k in 0..<nb {
                let c = bq[k]
                let y = c.b0 * x + z1[k]
                z1[k] = z2[k] - c.a1 * y
                z2[k] = c.b2 * x - c.a2 * y
                bandSum[k] += y * y
            }
        }

        let n = Float(frames)
        let bands = bandSum.map { sqrt($0 / n) }
        update(level: sqrt(sAll / n), bass: sqrt(sB / n), mid: sqrt(sM / n), high: sqrt(sH / n), bands: bands)
    }

    /// Log-spaced band-pass filters, 40 Hz → 12 kHz, about half an octave apart.
    private func setupBank(_ fs: Float) {
        bankRate = fs
        let nb = Spectrum.count
        bq = (0..<nb).map { i in
            let f0 = 40 * pow(12000 / 40, Float(i) / Float(nb - 1))
            let w0 = 2 * Float.pi * min(f0, fs * 0.45) / fs
            let q: Float = 2.2
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha
            return (b0: alpha / a0, b2: -alpha / a0, a1: -2 * cos(w0) / a0, a2: (1 - alpha) / a0)
        }
        z1 = [Float](repeating: 0, count: nb)
        z2 = [Float](repeating: 0, count: nb)
    }

    private func update(level: Float, bass: Float, mid: Float, high: Float, bands: [Float]) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = Float(min(max(now - lastUpdate, 0.001), 0.2))
        lastUpdate = now

        // Spectrum: each band auto-gained against its own recent peak (but never boosted past
        // 8x of the loudest band, so silence-level noise stays dark), then smoothed:
        // quick to rise, low bands fall slowly, high bands fall fast.
        let nb = Spectrum.count
        for k in 0..<nb {
            bandPeaks[k] = max(bands[k], bandPeaks[k] * exp(-dt / 8), 0.0003)
        }
        let loudest = bandPeaks.max() ?? 0.001
        for k in 0..<nb {
            let ref = max(bandPeaks[k], loudest * 0.12)
            let target: Float = level > 0.002 ? min(1, bands[k] / ref) : 0
            let cur = smooth.spectrum[k]
            let release = 0.35 - 0.23 * Float(k) / Float(nb - 1)
            let tau: Float = target > cur ? 0.03 : release
            smooth.spectrum[k] = cur + (target - cur) * (1 - exp(-dt / tau))
        }

        // Attacks: how far each band jumped above its own recent average. Instant up, quick fade.
        for k in 0..<nb {
            let v = smooth.spectrum[k]
            slowSpec[k] += (v - slowSpec[k]) * (1 - exp(-dt / 0.45))
            let p = min(1, max(0, v - slowSpec[k]) * 2.4)
            let cur = smooth.punch[k]
            smooth.punch[k] = p > cur ? p : cur + (p - cur) * (1 - exp(-dt / 0.14))
        }

        // Strum: a sudden rise in the guitar range (≈270 Hz – 4 kHz) that isn't just a kick drum,
        // held up while that range keeps ringing loud.
        var midE: Float = 0
        for k in 5...12 { midE += smooth.spectrum[k] }
        midE /= 8
        var lowE: Float = 0
        for k in 0...3 { lowE += smooth.spectrum[k] }
        lowE /= 4
        let midFlux = max(0, midE - prevMidE) / dt
        let lowFlux = max(0, lowE - prevLowE) / dt
        prevMidE = midE
        prevLowE = lowE
        let hit = min(1, max(0, midFlux - 0.8 * lowFlux) * 0.07)
        let hold = min(1, max(0, midE - 0.55) * 1.3)
        smooth.strum = max(smooth.strum * exp(-dt / 0.9), hit, hold)
        if level <= 0.002 { smooth.strum *= exp(-dt / 0.2) }

        // Auto-gain: divide by a slowly decaying peak so quiet and loud tracks both move the visuals.
        func norm(_ v: Float, _ i: Int) -> Float {
            peaks[i] = max(v, peaks[i] * exp(-dt / 8), 0.01)
            return min(1, v / peaks[i])
        }
        func ease(_ cur: Float, _ tgt: Float) -> Float {
            cur + (tgt - cur) * (tgt > cur ? 0.55 : 0.12)
        }
        smooth.level = ease(smooth.level, norm(level, 0))
        smooth.bass = ease(smooth.bass, norm(bass, 1))
        smooth.mid = ease(smooth.mid, norm(mid, 2))
        smooth.high = ease(smooth.high, norm(high, 3))
        smooth.active = level > 0.002

        // Beat detection: bass rises well above its recent mean + spread (adaptive threshold).
        let a = 1 - exp(-dt / 1.2)
        bassMean += (bass - bassMean) * a
        let dev = bass - bassMean
        bassVar += (dev * dev - bassVar) * a
        let sd = bassVar.squareRoot()
        let rising = bass > prevBass
        prevBass = bass

        if smooth.active && rising && bass > bassMean + 1.2 * sd && bass > 0.002 && now - lastBeat > 0.25 {
            let gap = Float(now - lastBeat)
            if gap < 2.0 {
                // Fold the interval into a sensible beat length (0.3…1.0 s ≈ 200…60 BPM).
                var g = gap
                while g < 0.3 { g *= 2 }
                while g > 1.0 { g /= 2 }
                intervals.append(g)
                if intervals.count > 10 { intervals.removeFirst() }
                let sorted = intervals.sorted()
                smooth.period = sorted[sorted.count / 2]
            }
            lastBeat = now
            smooth.beat = 1
            smooth.beatCount &+= 1
            smooth.beatTime = now
        } else {
            smooth.beat *= exp(-dt / 0.12)
        }

        // Drop detection on the raw level (independent of auto-gain):
        // short-term energy jumps far above the last few seconds and is near the loudest we've heard.
        fastRaw += (level - fastRaw) * (1 - exp(-dt / 0.15))
        slowRaw += (level - slowRaw) * (1 - exp(-dt / 5.0))
        if smooth.active && fastRaw > slowRaw * 1.8 && fastRaw > peaks[0] * 0.6
            && smooth.bass > 0.5 && now - lastDrop > 6 {
            lastDrop = now
            smooth.dropCount &+= 1
            smooth.dropTime = now
        }

        lock.lock()
        current = smooth
        lock.unlock()
    }
}
