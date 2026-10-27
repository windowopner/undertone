import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let settings = Settings.shared
    let audio = AudioReactor()
    private var windows: [NSWindow] = []
    private var observers: [NSObjectProtocol] = []
    private var statusItem: NSStatusItem!
    private var lastMissing: [String] = []

    // Full-screen stage
    private var stageWindow: StageWindow?
    private var stageObserver: NSObjectProtocol?
    private var cursorTimer: Timer?
    private var lastMouse = NSPoint.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        buildWindows()
        setupStatusItem()
        if settings.startFullscreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openStage() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        audio.start()
        ColorSync.shared.start()
        if settings.launchCompanions {
            lastMissing = Companions.launch(settings.companionApps)
        }
    }

    // MARK: - Desktop-level wallpaper windows (one per screen)

    @objc private func screensChanged() { buildWindows() }

    private func buildWindows() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        windows.forEach { $0.orderOut(nil) }

        windows = NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                             backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: true)
            // Above the real wallpaper, below desktop icons and every normal window.
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            w.ignoresMouseEvents = true
            w.isOpaque = true
            w.backgroundColor = .black
            w.hasShadow = false
            w.isReleasedWhenClosed = false

            let vis = WindowVisibility()
            w.contentView = NSHostingView(rootView: WallpaperView(audio: audio, settings: settings, visibility: vis))
            w.orderFront(nil)

            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main
            ) { [weak w] _ in
                guard let w = w else { return }
                vis.visible = w.occlusionState.contains(.visible)
            })
            return w
        }
    }

    // MARK: - Full-screen stage window

    /// Opening Undertone again (Spotlight, Launchpad, double-click) jumps into full screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if stageWindow == nil { openStage() } else { stageWindow?.makeKeyAndOrderFront(nil) }
        return false
    }

    @objc private func toggleStage() {
        if stageWindow == nil { openStage() } else { closeStage() }
    }

    private func openStage() {
        guard stageWindow == nil else { return }
        // A regular app gets its own full-screen Space, Dock icon and ⌘-Tab entry.
        NSApp.setActivationPolicy(.regular)

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let w = StageWindow(
            contentRect: screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.15,
                                                    dy: screen.visibleFrame.height * 0.15),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Undertone"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.collectionBehavior = [.fullScreenPrimary, .managed]
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.delegate = self

        let vis = WindowVisibility()
        w.contentView = NSHostingView(rootView: WallpaperView(audio: audio, settings: settings, visibility: vis))
        stageObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main
        ) { [weak w] _ in
            guard let w = w else { return }
            vis.visible = w.occlusionState.contains(.visible)
        }

        stageWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Give the activation-policy change a moment before going full screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak w] in
            guard let w = w, !w.styleMask.contains(.fullScreen) else { return }
            w.toggleFullScreen(nil)
        }
    }

    private func closeStage() {
        guard let w = stageWindow else { return }
        if w.styleMask.contains(.fullScreen) {
            w.toggleFullScreen(nil)   // windowDidExitFullScreen closes it afterwards
        } else {
            w.close()
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard (notification.object as? NSWindow) === stageWindow else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
        lastMouse = NSEvent.mouseLocation
        // Hide the cursor again after ~3 s without movement.
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self = self, let w = self.stageWindow,
                  w.styleMask.contains(.fullScreen), w.isKeyWindow else { return }
            let p = NSEvent.mouseLocation
            if p == self.lastMouse { NSCursor.setHiddenUntilMouseMoves(true) }
            self.lastMouse = p
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === stageWindow else { return }
        w.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === stageWindow else { return }
        cursorTimer?.invalidate()
        cursorTimer = nil
        if let o = stageObserver { NotificationCenter.default.removeObserver(o) }
        stageObserver = nil
        stageWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Menu bar controls

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Undertone")
        img?.isTemplate = true
        statusItem.button?.image = img
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(info("오디오: \(audio.status)"))
        if !audio.hasPermission {
            menu.addItem(item("권한 설정 열기…", #selector(openPrivacySettings)))
            menu.addItem(item("Undertone 재시작 (허용한 뒤)", #selector(relaunch)))
        }
        let lv = audio.snapshot()
        let filled = Int((lv.level * 10).rounded())
        let meter = String(repeating: "▮", count: filled) + String(repeating: "▯", count: 10 - filled)
        let bpm = Int((60 / max(lv.period, 0.3)).rounded())
        menu.addItem(info(lv.active ? "레벨 \(meter)  ·  약 \(bpm) BPM  ·  박자 \(lv.beatCount)회"
                                    : "소리 없음 — 음악을 틀어줘"))
        if !lastMissing.isEmpty {
            menu.addItem(info("못 찾은 앱: \(lastMissing.joined(separator: ", "))"))
        }
        menu.addItem(.separator())

        let stage = item(stageWindow == nil ? "전체화면으로 보기" : "전체화면 닫기", #selector(toggleStage))
        menu.addItem(stage)
        let sf = item("시작할 때 전체화면", #selector(toggleStartFullscreen))
        sf.state = settings.startFullscreen ? .on : .off
        menu.addItem(sf)
        menu.addItem(.separator())

        for s in VisualStyle.allCases {
            let i = item(s.title, #selector(pickStyle(_:)))
            i.representedObject = s.rawValue
            i.state = settings.style == s ? .on : .off
            menu.addItem(i)
        }
        menu.addItem(item("배경 이미지 선택…", #selector(chooseImage)))
        let ma = item("Lumn·앨범 색 맞추기", #selector(toggleMatchAlbum))
        ma.state = settings.matchAlbum ? .on : .off
        menu.addItem(ma)
        menu.addItem(info("색: \(ColorSync.shared.label)"))

        sensitivitySlider?.doubleValue = settings.sensitivity
        updateSensitivityLabel()
        menu.addItem(sensitivityItem)
        menu.addItem(item("반응 강도 기본값으로", #selector(resetSensitivity)))
        menu.addItem(.separator())

        menu.addItem(info("같이 켤 앱: \(settings.companionApps.joined(separator: ", "))"))
        let lc = item("Undertone 켤 때 같이 실행", #selector(toggleLaunchCompanions))
        lc.state = settings.launchCompanions ? .on : .off
        menu.addItem(lc)
        menu.addItem(item("지금 같이 실행", #selector(launchNow)))
        menu.addItem(item("같이 켤 앱 편집…", #selector(editCompanions)))
        menu.addItem(.separator())

        let login = item("로그인 시 자동 실행", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("오디오 다시 연결", #selector(reconnectAudio)))
        menu.addItem(.separator())
        menu.addItem(item("Undertone 종료", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    // MARK: - Actions

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = VisualStyle(rawValue: raw) else { return }
        if s == .image && settings.imagePath == nil {
            chooseImage()
            return
        }
        settings.style = s
    }

    @objc private func chooseImage() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "배경으로 쓸 이미지를 골라줘"
        if panel.runModal() == .OK, let url = panel.url {
            settings.imagePath = url.path
            settings.style = .image
        }
    }

    // MARK: - Reaction strength slider

    private var sensitivitySlider: NSSlider?
    private var sensitivityLabel: NSTextField?
    private lazy var sensitivityItem: NSMenuItem = makeSensitivityItem()

    private func makeSensitivityItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 50))
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.frame = NSRect(x: 20, y: 28, width: 228, height: 18)
        let slider = NSSlider(value: settings.sensitivity, minValue: 0.2, maxValue: 3.0,
                              target: self, action: #selector(sensitivityChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 18, y: 4, width: 226, height: 22)
        view.addSubview(label)
        view.addSubview(slider)
        sensitivityLabel = label
        sensitivitySlider = slider
        let item = NSMenuItem()
        item.view = view
        updateSensitivityLabel()
        return item
    }

    @objc private func sensitivityChanged(_ sender: NSSlider) {
        settings.sensitivity = sender.doubleValue
        updateSensitivityLabel()
    }

    @objc private func resetSensitivity() {
        settings.sensitivity = 1.0
        sensitivitySlider?.doubleValue = 1.0
        updateSensitivityLabel()
    }

    private func updateSensitivityLabel() {
        let v = settings.sensitivity
        let word = v < 0.6 ? "잔잔하게" : (v < 1.3 ? "보통" : (v < 2.2 ? "강하게" : "아주 강하게"))
        sensitivityLabel?.stringValue = "반응 강도  \(String(format: "%.1f", v))x  ·  \(word)"
    }

    @objc private func toggleMatchAlbum() {
        settings.matchAlbum.toggle()
        ColorSync.shared.update()
    }

    @objc private func toggleStartFullscreen() {
        settings.startFullscreen.toggle()
    }

    @objc private func toggleLaunchCompanions() {
        settings.launchCompanions.toggle()
    }

    @objc private func launchNow() {
        lastMissing = Companions.launch(settings.companionApps)
    }

    @objc private func editCompanions() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "같이 켤 앱"
        alert.informativeText = "앱 이름을 쉼표로 구분해서 적어줘 (예: Verci, Lumn)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = settings.companionApps.joined(separator: ", ")
        alert.accessoryView = field
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            settings.companionApps = field.stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            lastMissing = []
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "자동 실행 설정 실패"
            a.informativeText = "시스템 설정 → 일반 → 로그인 항목에서 Undertone을 직접 추가해줘.\n(\(error.localizedDescription))"
            a.runModal()
        }
    }

    @objc private func reconnectAudio() { audio.restart() }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Quit and open again — macOS only applies a new recording permission after a restart.
    @objc private func relaunch() {
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open '\(path)'"]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
