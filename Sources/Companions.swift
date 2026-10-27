import AppKit

/// Finds and launches the apps that should start together with Undertone (Verci, Lumn by default).
enum Companions {
    static func find(_ name: String) -> URL? {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    NSHomeDirectory() + "/Applications"]
        for d in dirs {
            let p = "\(d)/\(name).app"
            if fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        }
        // Maybe it was given as a bundle identifier.
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) { return u }
        return spotlight(name)
    }

    /// Fallback: ask Spotlight for an app with that display name.
    private static func spotlight(_ name: String) -> URL? {
        let safe = name.replacingOccurrences(of: "'", with: "")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["kMDItemContentType == 'com.apple.application-bundle' && kMDItemDisplayName == '\(safe)'cd"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let first = out.split(separator: "\n").first else { return nil }
        return URL(fileURLWithPath: String(first))
    }

    /// Launches the apps that aren't already running. Returns the names it couldn't find.
    @discardableResult
    static func launch(_ names: [String]) -> [String] {
        var missing: [String] = []
        let running = NSWorkspace.shared.runningApplications
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if running.contains(where: { $0.localizedName == name || $0.bundleIdentifier == name }) { continue }
            guard let url = find(name) else { missing.append(name); continue }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        }
        return missing
    }
}
