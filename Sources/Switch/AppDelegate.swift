import AppKit
import Carbon.HIToolbox
import Combine
import IOKit
import SwiftUI
import Sparkle

extension Notification.Name {
    static let switchCheckForUpdates = Notification.Name("switch.checkForUpdates")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Under the SwiftUI lifecycle NSApp.delegate is SwiftUI's own wrapper, so casting it to AppDelegate finds nothing (#127).
    private(set) static weak var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: self
    )
    var sparkleUpdater: SPUUpdater? { updaterController.updater }
    private var model: SwitchModel?
    private var hotkey: HotkeyManager?
    private var window: SwitcherWindow?
    private var statusBar: StatusBarController?
    private var onboardingModel: OnboardingModel?
    private var onboardingWindow: NSWindow?
    private var focusTracker: FocusTracker?
    private var servicesStarted = false
    private var permsTimer: Timer?
    private var armedWatchdog: Timer?
    private var clickAwayMonitor: Any?
    private var pendingPresent: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        let model = SwitchModel()
        let window = SwitcherWindow(model: model)
        let hotkey = HotkeyManager()

        // Most tap callbacks force a pending picker onto screen before acting.
        let present: () -> Void = { [weak self] in self?.presentNowIfPending(window: window) }

        hotkey.onArm = { [weak self] style in
            model.arm(style)
            self?.schedulePresent(window: window)
        }
        hotkey.onAdvance = { reverse, clamp in
            present()
            model.advance(reverse: reverse, clamp: clamp)
        }
        hotkey.onShiftStep = { undo in
            if undo {
                model.undoShiftStep()
            } else {
                present()
                model.shiftStepBack()
            }
        }
        hotkey.onCommit = { [weak self] quick in self?.finish(commit: true, stickyQuickTap: quick) }
        model.commitAndDismiss = { [weak self] in self?.finish(commit: true) }
        let cancelAndDismiss: () -> Void = { [weak self] in self?.finish(commit: false) }
        hotkey.onCancel = cancelAndDismiss
        model.cancelAndDismiss = cancelAndDismiss
        hotkey.onCloseSelected = { present(); model.closeSelected() }
        hotkey.onCloseSelectedApp = { present(); model.closeSelectedApp() }
        hotkey.onHideSelected = { present(); model.hideSelected() }
        hotkey.onNavigate = { present(); model.navigate(direction: $0) }
        hotkey.onPickIndex = { present(); model.pickIndex($0) }
        hotkey.onPickSelectOnly = { present(); model.selectIndex($0) }
        hotkey.onFilterAppend = { present(); model.appendFilter($0) }
        hotkey.onFilterBackspace = { present(); model.backspaceFilter() }
        hotkey.onStickyToggle = {
            SwitchPreferences.shared.stickyMode.toggle()
        }
        hotkey.onOpenSettings = {
            MainActor.assumeIsolated { SettingsWindow.shared.show() }
        }

        SwitchPreferences.shared.$appearance
            .sink { NSApp.appearance = $0.nsAppearance }
            .store(in: &cancellables)
        // present() sizes the panel, so settings changes need no resize here.
        SwitchPreferences.shared.$showThumbnails
            .dropFirst()
            .sink { [weak self] enabled in
                if enabled && CGPreflightScreenCaptureAccess() == false {
                    self?.showOnboarding()
                }
            }
            .store(in: &cancellables)
        SwitchPreferences.shared.$hideMenuBarIcon
            .dropFirst()
            .sink { [weak self] hidden in
                self?.statusBar?.setHidden(hidden)
            }
            .store(in: &cancellables)

        self.model = model
        self.hotkey = hotkey
        self.window = window
        self.statusBar = StatusBarController()
        self.onboardingModel = OnboardingModel()
        self.focusTracker = FocusTracker()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleCheckForUpdates),
            name: .switchCheckForUpdates, object: nil
        )
        _ = updaterController

        // Hotkeys need only Accessibility; a missing or reset Screen Recording grant just loses thumbnails (#198).
        startServicesIfNeeded()
        if !OnboardingModel.requiredGranted { showOnboarding() }

        // Background poll: as soon as Accessibility is granted, install the tap.
        permsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { return }
            if self.servicesStarted {
                timer.invalidate()
                self.permsTimer = nil
            } else {
                self.startServicesIfNeeded()
            }
        }

        // Watchdog: armed with no panel visible means the tap is consuming keystrokes
        // for a picker that doesn't exist (the "keyboard stops working until Switch
        // quits" report). Clear it. model.arm sets visible before scheduling the present.
        armedWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.statusBar?.setWarning(Self.hotkeyWarning())
                guard let hotkey = self.hotkey, let model = self.model else { return }
                guard hotkey.isArmed else { return }
                if !model.visible {
                    hotkey.clearShownArm()
                } else {
                    hotkey.recoverIfReleaseWasMissed()
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .switchRecorderBegan, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.model?.visible == true { cancelAndDismiss() }
                self?.hotkey?.setSuspended(true)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .switchRecorderEnded, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hotkey?.setSuspended(false)
        }

        // Nothing releases ⌘ across sleep, lock or a user switch: on return the watchdog would commit the
        // stale selection, and a sticky picker would keep eating keys (#211).
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { cancelAndDismiss() }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { cancelAndDismiss() }
        }

        // A click in another app while the picker floats (sticky mode) should
        // dismiss it; otherwise the panel lingers and the tap keeps eating keys.
        // Global monitors never see events routed to our own panel.
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model?.visible == true else { return }
                cancelAndDismiss()
            }
        }
    }

    // Relaunching while already running reopens Settings and restores the menu bar icon if it was dragged off.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBar?.setHidden(UserDefaults.standard.bool(forKey: SwitchPreferences.hideMenuBarIconKey))
        // Accessibility alone runs Switch (#198); Settings → Permissions covers Screen Recording.
        if AXIsProcessTrusted() {
            SettingsWindow.shared.show()
        } else {
            showOnboarding()
        }
        return true
    }

    /// Shown in the menu bar when macOS keeps keys from reaching the tap (#198).
    private static func hotkeyWarning() -> String? {
        if !AXIsProcessTrusted() { return "Hotkeys off: Accessibility is not granted" }
        guard IsSecureEventInputEnabled() else { return nil }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]]
        let pid = users?.lazy.compactMap { $0["kCGSSessionSecureInputPID"] as? Int }.first
        let app = pid.flatMap { NSRunningApplication(processIdentifier: pid_t($0))?.localizedName } ?? "another app"
        return "Hotkeys paused: Secure Input is on in \(app)"
    }

    private func schedulePresent(window: SwitcherWindow) {
        pendingPresent?.cancel()
        let work = DispatchWorkItem { [weak self, weak window] in
            self?.pendingPresent = nil
            window?.present()
        }
        pendingPresent = work
        let ms = SwitchPreferences.storedActivationDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000.0, execute: work)
    }

    private func presentNowIfPending(window: SwitcherWindow) {
        guard let pending = pendingPresent else { return }
        pending.cancel()
        pendingPresent = nil
        window.present()
    }

    /// Every way the picker closes. clearShownArm leaves alone an arm the tap made after this one,
    /// so a stale close can't strand a fresh picker with nothing armed.
    @MainActor private func finish(commit: Bool, stickyQuickTap: Bool = false) {
        cancelPendingPresent()
        hotkey?.clearShownArm()
        if commit { model?.commit(stickyQuickTap: stickyQuickTap) } else { model?.cancel() }
        window?.dismiss()
    }

    private func cancelPendingPresent() {
        pendingPresent?.cancel()
        pendingPresent = nil
    }

    private func startServicesIfNeeded() {
        // A failed start leaves servicesStarted false so the permission poll tries again.
        guard !servicesStarted, hotkey?.start() == true else { return }
        servicesStarted = true
        // The tap is live now; onboarding went .regular only while it couldn't be.
        if onboardingWindow != nil { NSApp.setActivationPolicy(.accessory) }
        WindowStore.shared.refresh()
        MainActor.assumeIsolated { model?.startPrewarm() }
        focusTracker?.start()
    }

    @objc private func handleCheckForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    private func showOnboarding() {
        guard let onboardingModel else { return }
        if onboardingWindow == nil {
            let host = NSHostingController(rootView: OnboardingView().environmentObject(onboardingModel))
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = "Switch"
            win.contentViewController = host
            win.center()
            win.isReleasedWhenClosed = false
            win.delegate = self
            onboardingWindow = win
        }
        // .regular (Dock, ⌘-Tab) only before the tap runs: an inactive .regular app's activate() is ignored, breaking switching.
        if !servicesStarted { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        onboardingWindow?.orderFrontRegardless()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win == onboardingWindow else { return }
        onboardingModel?.stopPolling()
        onboardingWindow = nil
        demoteIfNoWindows()
    }
}

extension AppDelegate: SPUStandardUserDriverDelegate {
    // An accessory app's windows are invisible to app switchers; go regular while Sparkle's update UI is up,
    // but only before the tap runs: an inactive .regular app's activate() is ignored, breaking switching.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !servicesStarted { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverWillFinishUpdateSession() {
        demoteIfNoWindows()
    }
}
