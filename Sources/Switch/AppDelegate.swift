import AppKit
import Combine
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

extension Notification.Name {
    static let switchCheckForUpdates = Notification.Name("switch.checkForUpdates")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    #if canImport(Sparkle)
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif
    private var model: SwitchModel?
    private var hotkey: HotkeyManager?
    private var window: SwitcherWindow?
    private var statusBar: StatusBarController?
    private var onboardingModel: OnboardingModel?
    private var onboardingWindow: NSWindow?
    private var focusTracker: FocusTracker?
    private var hotkeyStarted = false
    private var focusTrackerStarted = false
    #if DEBUG
    private let debugHarness = DebugFocusHarness()
    #endif
    private var permsTimer: Timer?
    private var armedWatchdog: Timer?
    private var clickAwayMonitor: Any?
    private var pendingPresent: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        debugHarness.start()
        #endif

        let model = SwitchModel()
        let window = SwitcherWindow(model: model)
        let hotkey = HotkeyManager()

        hotkey.onArm = { [weak self] mode in
            if SettingsWindow.shared.isVisible {
                self?.hotkey?.clearArmed()
                return
            }
            model.arm(mode)
            self?.schedulePresent(window: window)
        }
        hotkey.onAdvance = { [weak self] reverse in
            self?.presentNowIfPending(window: window)
            model.advance(reverse: reverse)
        }
        let commitAndDismiss: () -> Void = { [weak self] in
            self?.cancelPendingPresent()
            self?.hotkey?.clearArmed()
            model.commit()
            window.dismiss()
        }
        hotkey.onCommit = commitAndDismiss
        model.commitAndDismiss = commitAndDismiss
        let cancelAndDismiss: () -> Void = { [weak self] in
            self?.cancelPendingPresent()
            self?.hotkey?.clearArmed()
            model.cancel()
            window.dismiss()
        }
        hotkey.onCancel = cancelAndDismiss
        model.cancelAndDismiss = cancelAndDismiss
        hotkey.onCloseSelected = { [weak self] in
            self?.presentNowIfPending(window: window)
            model.closeSelected()
        }
        hotkey.onCloseSelectedApp = { [weak self] in
            self?.presentNowIfPending(window: window)
            model.closeSelectedApp()
        }
        hotkey.onHideSelected = { [weak self] in
            self?.presentNowIfPending(window: window)
            model.hideSelected()
        }
        hotkey.onNavigate = { [weak self] direction in
            self?.presentNowIfPending(window: window)
            model.navigate(direction: direction)
        }
        hotkey.onPickIndex = { [weak self] index in
            self?.presentNowIfPending(window: window)
            model.pickIndex(index)
        }
        hotkey.onPickSelectOnly = { [weak self] index in
            self?.presentNowIfPending(window: window)
            model.selectIndex(index)
        }
        hotkey.onFilterAppend = { [weak self] c in
            self?.presentNowIfPending(window: window)
            model.appendFilter(c)
        }
        hotkey.onFilterBackspace = { [weak self] in
            self?.presentNowIfPending(window: window)
            model.backspaceFilter()
        }
        hotkey.onStickyToggle = {
            SwitchPreferences.shared.stickyMode.toggle()
        }
        hotkey.onOpenSettings = {
            MainActor.assumeIsolated { SettingsWindow.shared.show() }
        }

        SwitchPreferences.shared.$verticalList
            .dropFirst()
            .sink { [weak window] _ in window?.applyContentSize() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$thumbnailHeight
            .dropFirst()
            .sink { [weak window] _ in window?.applyContentSize() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$showThumbnails
            .dropFirst()
            .sink { [weak self, weak window] enabled in
                window?.applyContentSize()
                if enabled && CGPreflightScreenCaptureAccess() == false {
                    self?.showOnboarding()
                } else if self?.requiredPermissionsGranted == true {
                    self?.startHotkeyIfNeeded()
                    self?.startFocusTrackerIfNeeded()
                }
            }
            .store(in: &cancellables)
        SwitchPreferences.shared.$hideMenuBarIcon
            .dropFirst()
            .sink { [weak self] hidden in
                self?.statusBar?.setHidden(hidden)
            }
            .store(in: &cancellables)
        model.$visible
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in self?.hotkey?.clearArmed() }
            .store(in: &cancellables)

        self.model = model
        self.hotkey = hotkey
        self.window = window
        self.statusBar = StatusBarController()
        self.onboardingModel = OnboardingModel()
        self.focusTracker = FocusTracker()

        NotificationCenter.default.addObserver(
            self, selector: #selector(showOnboarding),
            name: .switchShowOnboarding, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleCheckForUpdates),
            name: .switchCheckForUpdates, object: nil
        )
        #if canImport(Sparkle)
        _ = updaterController
        #endif
        NotificationCenter.default.addObserver(
            forName: HotkeyConfig.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hotkey?.reload()
        }

        // Show onboarding if any permission is missing; otherwise install the tap.
        if !requiredPermissionsGranted {
            showOnboarding()
        } else {
            startHotkeyIfNeeded()
            startFocusTrackerIfNeeded()
        }

        // Background poll: as soon as both are granted, install the tap.
        permsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.requiredPermissionsGranted {
                self.startHotkeyIfNeeded()
                self.startFocusTrackerIfNeeded()
            }
        }

        // Watchdog: armed with no panel visible and none pending means the tap
        // is consuming keystrokes for a picker that doesn't exist (the "keyboard
        // stops working until Switch quits" report). Clear it.
        armedWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let hotkey = self.hotkey, let model = self.model else { return }
                if hotkey.isArmed && !model.visible && self.pendingPresent == nil {
                    hotkey.clearArmed()
                }
            }
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

    // Relaunching while already running reopens Settings — the way back when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if requiredPermissionsGranted {
            SettingsWindow.shared.show()
        } else {
            showOnboarding()
        }
        return true
    }

    private var requiredPermissionsGranted: Bool {
        let thumbnailsEnabled = (UserDefaults.standard.object(forKey: SwitchPreferences.showThumbnailsKey) as? Bool) ?? true
        let screenCaptureOK = !thumbnailsEnabled || CGPreflightScreenCaptureAccess()
        return AXIsProcessTrusted() && screenCaptureOK
    }

    private func schedulePresent(window: SwitcherWindow) {
        pendingPresent?.cancel()
        let work = DispatchWorkItem { [weak self, weak window] in
            self?.pendingPresent = nil
            window?.present()
        }
        pendingPresent = work
        let ms = (UserDefaults.standard.object(forKey: SwitchPreferences.pickerActivationDelayKey) as? Double) ?? SwitchPreferences.defaultPickerActivationDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000.0, execute: work)
    }

    private func presentNowIfPending(window: SwitcherWindow) {
        guard let pending = pendingPresent else { return }
        pending.cancel()
        pendingPresent = nil
        window.present()
    }

    private func cancelPendingPresent() {
        pendingPresent?.cancel()
        pendingPresent = nil
    }

    private func startHotkeyIfNeeded() {
        guard !hotkeyStarted else { return }
        hotkey?.start()
        hotkeyStarted = true
        // Seed the AX window cache right away — the prewarm timer only runs
        // after the first arm, and a window that goes fullscreen before then
        // would otherwise be unfocusable in Chromium apps.
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pids = Set(WindowEnumerator.currentWindows(scope: .allWindows, frontmostPID: frontmost).map { $0.pid })
        Task.detached(priority: .utility) {
            AXWindowCache.capture(pids: pids)
        }
    }

    private func startFocusTrackerIfNeeded() {
        guard !focusTrackerStarted else { return }
        focusTracker?.start()
        focusTrackerStarted = true
    }

    @objc private func handleCheckForUpdates() {
        #if canImport(Sparkle)
        updaterController.checkForUpdates(nil)
        #else
        let alert = NSAlert()
        alert.messageText = "Updates not configured"
        alert.informativeText = "This build doesn't include Sparkle. Visit switch-dev.sanyamgarg.com to download the latest."
        alert.runModal()
        #endif
    }

    @objc private func showOnboarding() {
        guard let onboardingModel else { return }
        if onboardingWindow == nil {
            let host = NSHostingView(rootView: OnboardingView().environmentObject(onboardingModel))
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = "Switch"
            win.contentView = host
            win.center()
            win.isReleasedWhenClosed = false
            onboardingWindow = win
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}

final class SwitcherWindow: NSPanel {
    private let model: SwitchModel

    init(model: SwitchModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let host = NSHostingView(rootView: SwitchView().environmentObject(model))
        host.wantsLayer = true
        host.layer?.cornerRadius = 12
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        contentView = host
        applyContentSize()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func applyContentSize(for screen: NSScreen? = nil) {
        let fitted = SwitcherPanelSize.current(
            mode: model.mode,
            itemCount: model.filteredWindows.count,
            screen: screen
        )
        model.panelSize = CGSize(width: fitted.width, height: fitted.height)
        setContentSize(fitted)
    }

    func present() {
        // Re-asserted every present so the panel migrates across Spaces.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) })
            ?? NSScreen.main
        applyContentSize(for: screen)
        if let screen {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2
            ))
        }
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }
}

private enum SwitcherPanelSize {
    static func current(mode: HotkeyManager.Mode, itemCount: Int, screen: NSScreen?) -> NSSize {
        let defaults = UserDefaults.standard
        let isList = defaults.bool(forKey: SwitchPreferences.verticalListKey)
        let thumb = CGFloat((defaults.object(forKey: SwitchPreferences.thumbnailHeightKey) as? Double) ?? SwitchPreferences.defaultThumbnailHeight)
        let scale = thumb / CGFloat(SwitchPreferences.defaultThumbnailHeight)
        let count = max(itemCount, 1)
        let size: NSSize
        switch (mode, isList) {
        case (.spaces, _):
            size = listSize(defaults: defaults, count: count, scale: scale)
        case (.allWindows, true):
            size = NSSize(width: 520 * scale, height: 560 * scale)
        case (.allWindows, false):
            size = NSSize(width: 880 * scale, height: 560 * scale)
        case (.currentApp, true):
            size = listSize(defaults: defaults, count: count, scale: scale)
        case (.currentApp, false):
            size = gridSize(defaults: defaults, count: count, thumb: thumb, scale: scale)
        }
        return fit(size, on: screen)
    }

    private static func listSize(defaults: UserDefaults, count: Int, scale: CGFloat) -> NSSize {
        let showHints = (defaults.object(forKey: SwitchPreferences.showHintStripKey) as? Bool) ?? true
        let showPreview = (defaults.object(forKey: SwitchPreferences.verticalShowPreviewKey) as? Bool) ?? true
        let hintHeight: CGFloat = showHints ? 38 : 0
        let rowHeight: CGFloat = showPreview ? 62 : 48
        let visibleRows = min(count, 8)
        let rowGaps = CGFloat(max(visibleRows - 1, 0)) * 4
        let height = 26 + CGFloat(visibleRows) * rowHeight + rowGaps + hintHeight + 20
        return NSSize(width: 520 * scale, height: min(560 * scale, max(260, height)))
    }

    private static func gridSize(defaults: UserDefaults, count: Int, thumb: CGFloat, scale: CGFloat) -> NSSize {
        let showHints = (defaults.object(forKey: SwitchPreferences.showHintStripKey) as? Bool) ?? true
        let configuredColumns = (defaults.object(forKey: SwitchPreferences.gridColumnsKey) as? Int) ?? SwitchPreferences.defaultGridColumns
        let columns = min(max(configuredColumns, 1), max(count, 3))
        let baseWidth: CGFloat = 880 * scale
        let horizontalPadding: CGFloat = 44
        let columnSpacing: CGFloat = 14
        let usable = baseWidth - horizontalPadding - CGFloat(max(configuredColumns - 1, 0)) * columnSpacing
        let columnWidth = usable / CGFloat(configuredColumns)
        let width = horizontalPadding + CGFloat(columns) * columnWidth + CGFloat(max(columns - 1, 0)) * columnSpacing

        let rows = Int(ceil(Double(count) / Double(columns)))
        let tileHeight = thumb + 52
        let rowsHeight = CGFloat(rows) * tileHeight + CGFloat(max(rows - 1, 0)) * 14
        let hintHeight: CGFloat = showHints ? 38 : 0
        let height = 26 + 16 + rowsHeight + hintHeight
        return NSSize(width: max(560, width), height: min(560 * scale, max(320, height)))
    }

    private static func fit(_ size: NSSize, on screen: NSScreen?) -> NSSize {
        guard let screen else { return size }
        let visible = screen.visibleFrame
        return NSSize(
            width: min(size.width, visible.width * 0.92),
            height: min(size.height, visible.height * 0.92)
        )
    }
}
