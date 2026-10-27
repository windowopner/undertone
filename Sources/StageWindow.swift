import AppKit

/// The full-screen "stage" window. Esc leaves full screen (which also closes it).
final class StageWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if styleMask.contains(.fullScreen) {
            toggleFullScreen(nil)
        } else {
            close()
        }
    }
}

/// Minimal main menu so ⌘Q, ⌘W and ⌃⌘F work while the stage window is open.
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Undertone 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "보기")
        let fs = NSMenuItem(title: "전체화면 전환", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fs)
        viewMenu.addItem(withTitle: "창 닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }
}
