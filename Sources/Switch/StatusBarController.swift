import AppKit

@MainActor
final class StatusBarController {
    private var item: NSStatusItem
    /// Why hotkeys aren't working, if they aren't (#198). Kept here so a recreated item shows it too.
    private var warning: String?

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configure(item)
        item.isVisible = !SwitchPreferences.shared.hideMenuBarIcon
    }

    private func configure(_ item: NSStatusItem) {
        if let button = item.button {
            let img = NSImage(systemSymbolName: warning == nil ? "square.on.square" : "exclamationmark.triangle",
                              accessibilityDescription: "Switch")
            img?.isTemplate = true
            button.image = img
            button.toolTip = warning
        }

        let menu = NSMenu()

        let header = NSMenuItem(title: "Switch", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let warning {
            let note = NSMenuItem(title: warning, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Switch", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Switch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
    }

    // Showing recreates the item: macOS won't reliably bring back an icon the user dragged off via isVisible alone.
    func setHidden(_ hidden: Bool) {
        if hidden {
            item.isVisible = false
        } else {
            NSStatusBar.system.removeStatusItem(item)
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            configure(item)
            item.isVisible = true
        }
    }

    func setWarning(_ text: String?) {
        guard text != warning else { return }
        warning = text
        configure(item)
    }

    @objc private func openSettings() {
        MainActor.assumeIsolated { SettingsWindow.shared.show() }
    }

    @objc private func openAbout() {
        MainActor.assumeIsolated { AboutWindow.shared.show() }
    }
}
