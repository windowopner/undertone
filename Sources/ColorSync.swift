import AppKit

/// Decides which palette the visuals use, so they match Lumn's lighting:
///  1. Lumn's own fixed colours, when "Override album color" is on in Lumn
///  2. otherwise the album artwork of what's playing (the same source Lumn uses)
///  3. otherwise the default blue palette
/// Thread-safe: the render thread reads `palette` every frame.
final class ColorSync {
    static let shared = ColorSync()

    private let lock = NSLock()
    private var from = Palette.fallback
    private var target = Palette.fallback
    private var changedAt: TimeInterval = 0
    private let blendTime: TimeInterval = 1.6
    private var timer: Timer?

    /// Main thread only — shown in the menu.
    private(set) var label = "기본 색"

    /// Current palette, cross-fading smoothly after a track / colour change.
    var palette: Palette {
        lock.lock(); defer { lock.unlock() }
        return blended(at: ProcessInfo.processInfo.systemUptime)
    }

    private func blended(at now: TimeInterval) -> Palette {
        let x = min(1, max(0, (now - changedAt) / blendTime))
        let e = Float(x * x * (3 - 2 * x))
        return from.lerp(to: target, t: e)
    }

    func start() {
        NowPlaying.shared.start()
        LumnLink.shared.start()
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    func update() {
        let lumn = LumnLink.shared.state
        let now = NowPlaying.shared
        var p = Palette.fallback
        var l = "기본 색"

        if Settings.shared.matchAlbum {
            if lumn.installed && lumn.overrideColors {
                p = Palette.fromLumn(lumn.colorA, lumn.colorB)
                l = "Lumn 고정 색"
            } else if now.artwork != nil {
                p = now.palette
                l = now.title.isEmpty ? "앨범 색" : "앨범 색 · \(now.title)"
            } else {
                l = "앨범 색 — 재생 중인 곡 기다리는 중"
            }
        }

        label = l
        lock.lock()
        if p != target {
            let uptime = ProcessInfo.processInfo.systemUptime
            from = blended(at: uptime)
            target = p
            changedAt = uptime
        }
        lock.unlock()
    }
}
