import AppKit
import SwiftUI
import ServiceManagement
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class SettingsModel: ObservableObject {
    @Published var launchAtLogin: Bool = false
    @Published var autoUpdateCheck: Bool = true
    @Published var bindings: [HotkeyConfig.Slot: HotkeyBinding] = [:]

    init() { refresh() }

    #if canImport(Sparkle)
    private var updater: SPUUpdater? { AppDelegate.shared?.sparkleUpdater }
    #endif

    func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        #if canImport(Sparkle)
        autoUpdateCheck = updater?.automaticallyChecksForUpdates ?? true
        #endif
        bindings = HotkeyConfig.Slot.allCases.reduce(into: [:]) { $0[$1] = HotkeyConfig.shared[$1] }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            NSLog("Switch: login-item toggle failed: \(error)")
            refresh()
        }
    }

    func setAutoUpdateCheck(_ enabled: Bool) {
        #if canImport(Sparkle)
        updater?.automaticallyChecksForUpdates = enabled
        #endif
        autoUpdateCheck = enabled
    }

    func update(_ slot: HotkeyConfig.Slot, _ b: HotkeyBinding?) {
        HotkeyConfig.shared[slot] = b
        bindings[slot] = b
    }

    func resetHotkeys() {
        HotkeyConfig.shared.resetToDefaults()
        refresh()
    }
}
