import AppKit
import SwiftUI

/// Settings window host. Close demotes in case Sparkle promoted to .regular.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private var demoteWork: DispatchWorkItem?

    var isVisible: Bool { window?.isVisible == true }

    private init() {}

    func show() {
        demoteWork?.cancel()
        demoteWork = nil
        // Stays .accessory: an inactive .regular app's activate() calls are ignored, breaking switching.

        if let existing = window {
            NSApp.activate()
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }

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
        NSApp.activate()
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }

    func handleClose() {
        window = nil
        demoteWork?.cancel()
        let work = DispatchWorkItem {
            NSApp.setActivationPolicy(.accessory)
        }
        demoteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
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
