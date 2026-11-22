import AppKit
import SwiftUI

/// Back to menu-bar-only once no titled window (Settings, About, onboarding, Sparkle) is left on screen.
/// The picker panel is borderless, so it never counts. A quick reopen is still visible by the time this runs.
func demoteIfNoWindows() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        MainActor.assumeIsolated {
            if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

/// Settings window host. Close demotes in case Sparkle promoted to .regular.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    private init() {}

    func show() {
        // Stays .accessory: an inactive .regular app's activate() calls are ignored, breaking switching.
        if window == nil {
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = .minSize // resizable, SwiftUI only sets the floor (#209)
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Switch Settings"
            win.contentViewController = host
            win.setContentSize(NSSize(width: 500, height: 460))
            win.center()
            win.setFrameAutosaveName("SwitchSettings")
            win.isReleasedWhenClosed = false
            win.delegate = SettingsWindowDelegate.shared
            window = win
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func handleClose() {
        window = nil
        demoteIfNoWindows()
    }
}

private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowDelegate()

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            SettingsWindow.shared.handleClose()
        }
    }
}
