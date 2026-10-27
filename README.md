# Undertone

A macOS desktop wallpaper that listens. Undertone captures whatever your Mac is playing, splits it into frequency bands, finds the beat, and turns it into a living background behind your desktop icons, tinted by the album art of the current track.

> Screenshot / demo GIF coming soon.

[한국어 README](README.ko.md)

## How it works

```
system audio ──► ScreenCaptureKit ──► 16-band biquad filter bank (40 Hz – 12 kHz)
                                        │
                                        ├─► bass / mid / high levels
                                        ├─► per-band attacks (snare, hats, plucks)
                                        └─► beat + tempo tracking
                                                │
album art ──► palette extraction ──► colors ────┤
                                                ▼
                     desktop-level window per display (SwiftUI Canvas · SceneKit)
```

- **Audio**: `AudioReactor` captures system audio with ScreenCaptureKit and runs it through a bank of 16 log-spaced band-pass biquads (transposed direct form II). Each band is auto-gained and smoothed; sudden rises become per-band "attacks", and a beat/tempo tracker drives the groove clock.
- **Mapping**: low frequencies are big and central, high frequencies small and at the edges, in every style.
- **Color**: a fixed color from the Lumn lighting app if set, otherwise the current album cover's palette, otherwise a default blue.
- **Window**: one borderless window per display at the desktop window level, so it sits under your icons. It can also go fullscreen in its own Space.

## Styles

3D bars (SceneKit pillar grid) · Weave · Contour lines · Cut-out · Orbit · Color field · Aurora · Pulse · Your own image (breathes with the music)

## Build

Requires macOS 14+ and the Xcode command line tools (`xcode-select --install`).

```bash
./build.sh        # builds Undertone.app, installs it to /Applications and launches it
```

On first launch, allow **Screen & System Audio Recording** in System Settings, then choose **Reconnect audio** from the menu bar icon.

## Menu bar

Style picker · background image · reactivity (0.2× – 3.0×) · fullscreen on launch · launch at login · companion apps to open alongside (defaults: Verci for lyrics, Lumn for lighting).

## Code map

| File | Role |
|---|---|
| `AudioReactor.swift` | system audio capture, filter bank, beats, tempo |
| `WallpaperView.swift` | the background styles (SwiftUI Canvas) |
| `BarField.swift` | 3D bars (SceneKit) |
| `ArtLayers.swift` | abstract styles + groove clock |
| `ColorSync.swift`, `NowPlaying.swift`, `Palette.swift` | album-art colors |
| `AppDelegate.swift`, `StageWindow.swift` | desktop-level windows, menu |
| `Companions.swift`, `LumnLink.swift` | launching and reading companion apps |
| `_gpu-experiment/` | work in progress: moving the styles to Metal shaders |
