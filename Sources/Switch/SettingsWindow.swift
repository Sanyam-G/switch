import AppKit
import SwiftUI

/// Promotes app to .regular while open, reverts to .accessory on close.
/// Required because SwiftUI's Settings scene + .accessory don't cooperate.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private var demoteWork: DispatchWorkItem?

    var isVisible: Bool { window?.isVisible == true }

    /// Drop level so Sparkle's update sheet/window isn't covered by the floating Settings.
    /// Restored to .floating when Settings regains key (see delegate).
    func dropLevelForDialog() {
        window?.level = .normal
    }

    private init() {}

    func show() {
        demoteWork?.cancel()
        demoteWork = nil
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }

        if let existing = window {
            NSApp.activate()
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }

        let host = NSHostingController(rootView: SettingsView())
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Switch Settings"
        win.contentViewController = host
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating
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

    func windowDidBecomeKey(_ notification: Notification) {
        if let win = notification.object as? NSWindow { win.level = .floating }
    }
}
