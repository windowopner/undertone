import AppKit
import CoreGraphics

/// Lumn's live settings, read straight from its preferences domain.
struct LumnState: Equatable {
    var installed = false
    var running = false
    /// Lumn's "Override album color" switch.
    var overrideColors = false
    var colorA = SIMD3<Float>(0.0, 0.533, 0.980)
    var colorB = SIMD3<Float>(0.369, 0.361, 0.902)
    var rimThickness: Float = 2
    var rimGlow: Float = 3
    var notchCompatible = true
    var selectedDisplays = "1"
}

/// Watches Lumn (Playgroundbranch.Lumn) so Undertone's palette, rim spill and notch
/// shape follow whatever Lumn is doing. Read-only: Lumn's settings are never changed.
final class LumnLink: ObservableObject {
    static let shared = LumnLink()
    static let bundleID = "Playgroundbranch.Lumn"

    @Published private(set) var state = LumnState()
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let domain = Self.bundleID as CFString
        CFPreferencesAppSynchronize(domain)

        var s = LumnState()
        s.installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
        s.running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        s.overrideColors = Self.bool("ambientOverride", domain) ?? false
        if let a = Self.string("ambientColor", domain).flatMap(Self.hex) { s.colorA = a }
        if let b = Self.string("ambientColor2", domain).flatMap(Self.hex) { s.colorB = b }
        if let t = Self.double("rimThickness", domain) { s.rimThickness = Float(t) }
        if let g = Self.double("rimGlow", domain) { s.rimGlow = Float(g) }
        s.notchCompatible = Self.bool("notchCompatible", domain) ?? true
        if let d = Self.string("selectedDisplays", domain) { s.selectedDisplays = d }

        if s != state { state = s }
    }

    // MARK: - Preference helpers

    private static func value(_ key: String, _ domain: CFString) -> AnyObject? {
        CFPreferencesCopyAppValue(key as CFString, domain)
    }

    private static func bool(_ key: String, _ domain: CFString) -> Bool? {
        value(key, domain) as? Bool
    }

    private static func double(_ key: String, _ domain: CFString) -> Double? {
        value(key, domain) as? Double
    }

    private static func string(_ key: String, _ domain: CFString) -> String? {
        if let s = value(key, domain) as? String { return s }
        if let n = value(key, domain) as? NSNumber { return n.stringValue }
        return nil
    }

    static func hex(_ string: String) -> SIMD3<Float>? {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count >= 6, let v = UInt32(s.prefix(6), radix: 16) else { return nil }
        return SIMD3<Float>(Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255)
    }
}
