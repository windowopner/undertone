import AppKit

/// Tracks what Spotify / Music is playing and derives a palette from its artwork.
/// Uses AppleScript (like Verci), triggered by the players' own track-change
/// notifications plus a slow fallback poll.
final class NowPlaying: NSObject, ObservableObject {
    static let shared = NowPlaying()

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var source = ""
    @Published private(set) var artwork: NSImage?
    @Published private(set) var palette = Palette.fallback
    /// Bumped whenever new artwork arrives (the renderer uploads it as a texture).
    @Published private(set) var artworkVersion = 0
    private(set) var artworkCG: CGImage?

    private let queue = DispatchQueue(label: "undertone.nowplaying")
    private var lastKey = ""
    private var timer: Timer?

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(playerChanged(_:)),
                           name: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil)
        center.addObserver(self, selector: #selector(playerChanged(_:)),
                           name: Notification.Name("com.apple.Music.playerInfo"), object: nil)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc private func playerChanged(_ note: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let info = Self.run(Self.infoScript)?.stringValue, !info.isEmpty else { return }
            let parts = info.components(separatedBy: "\t")
            guard parts.count >= 3 else { return }

            let key = parts[0] + "|" + parts[1] + "|" + parts[2]
            if key == self.lastKey { return }

            var image: NSImage?
            if parts[0] == "spotify", parts.count >= 4, let url = URL(string: parts[3]),
               let data = try? Data(contentsOf: url) {
                image = NSImage(data: data)
            } else if parts[0] == "music", let data = Self.run(Self.musicArtworkScript)?.data {
                image = NSImage(data: data)
            }
            // Only remember the track once artwork arrived, so a failed fetch retries.
            if image != nil { self.lastKey = key }

            let artworkImage = image
            let cg = artworkImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let extracted = artworkImage.flatMap { PaletteExtractor.extract(from: $0) }
            DispatchQueue.main.async {
                self.source = parts[0]
                self.title = parts[1]
                self.artist = parts[2]
                if let artworkImage {
                    self.artwork = artworkImage
                    self.artworkCG = cg
                    self.artworkVersion += 1
                }
                if let extracted { self.palette = extracted }
            }
        }
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    private static let infoScript = """
    if application "Spotify" is running then
        tell application "Spotify"
            if player state is playing then
                set t to current track
                return "spotify" & tab & (name of t) & tab & (artist of t) & tab & (artwork url of t)
            end if
        end tell
    end if
    if application "Music" is running then
        tell application "Music"
            if player state is playing then
                set t to current track
                return "music" & tab & (name of t) & tab & (artist of t)
            end if
        end tell
    end if
    return ""
    """

    private static let musicArtworkScript = """
    tell application "Music"
        if (count of artworks of current track) > 0 then
            return raw data of artwork 1 of current track
        end if
    end tell
    return ""
    """
}
