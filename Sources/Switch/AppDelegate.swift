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
    // Under the SwiftUI lifecycle NSApp.delegate is SwiftUI's own wrapper, so casting it to AppDelegate finds nothing (#127).
    private(set) static weak var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    #if canImport(Sparkle)
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: self
    )
    var sparkleUpdater: SPUUpdater? { updaterController.updater }
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
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        #if DEBUG
        debugHarness.start()
        #endif

        let model = SwitchModel()
        let window = SwitcherWindow(model: model)
        let hotkey = HotkeyManager()

        // Most tap callbacks force a pending picker onto screen before acting.
        let present: () -> Void = { [weak self] in self?.presentNowIfPending(window: window) }

        hotkey.onArm = { [weak self] style in
            model.arm(style)
            self?.schedulePresent(window: window)
        }
        hotkey.onAdvance = { reverse in
            present()
            model.advance(reverse: reverse)
        }
        // Tap-originated commits already cleared armed on the tap thread; clearing again here races a fresh arm.
        hotkey.onCommit = { [weak self, weak model, weak window] quick in
            self?.cancelPendingPresent()
            model?.commit(stickyQuickTap: quick)
            window?.dismiss()
        }
        model.commitAndDismiss = { [weak self, weak model, weak window] in
            self?.cancelPendingPresent()
            self?.hotkey?.clearArmed()
            model?.commit()
            window?.dismiss()
        }
        hotkey.onCancel = { [weak self, weak model, weak window] in
            self?.cancelPendingPresent()
            model?.cancel()
            window?.dismiss()
        }
        let cancelAndDismiss: () -> Void = { [weak self, weak model, weak window] in
            self?.cancelPendingPresent()
            self?.hotkey?.clearArmed()
            model?.cancel()
            window?.dismiss()
        }
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
        func resizeOnChange<T>(_ publisher: Published<T>.Publisher) {
            publisher.dropFirst()
                .sink { [weak window] _ in window?.applyContentSize() }
                .store(in: &cancellables)
        }
        resizeOnChange(SwitchPreferences.shared.$verticalList)
        resizeOnChange(SwitchPreferences.shared.$thumbnailHeight)
        resizeOnChange(SwitchPreferences.shared.$maxListRows)
        resizeOnChange(SwitchPreferences.shared.$maxGridRows)
        resizeOnChange(SwitchPreferences.shared.$panelWidthScale)
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
                guard hotkey.isArmed else { return }
                if !model.visible && self.pendingPresent == nil {
                    hotkey.clearArmed()
                } else if model.visible {
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
        if requiredPermissionsGranted {
            SettingsWindow.shared.show()
        } else {
            showOnboarding()
        }
        return true
    }

    private var requiredPermissionsGranted: Bool {
        let thumbnailsEnabled = SwitchPreferences.storedShowThumbnails
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
        let ms = SwitchPreferences.storedActivationDelay
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
        WindowStore.shared.refresh()
        MainActor.assumeIsolated { model?.startPrewarm() }
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win == onboardingWindow else { return }
        onboardingModel?.stopPolling()
        onboardingWindow = nil
        let settingsOpen = MainActor.assumeIsolated { SettingsWindow.shared.isVisible }
        if !settingsOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

#if canImport(Sparkle)
extension AppDelegate: SPUStandardUserDriverDelegate {
    // An accessory app's windows are invisible to app switchers; go regular while Sparkle's update UI is up.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverWillFinishUpdateSession() {
        let settingsOpen = MainActor.assumeIsolated { SettingsWindow.shared.isVisible }
        if !settingsOpen { NSApp.setActivationPolicy(.accessory) }
    }
}
#endif

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

    override func sendEvent(_ event: NSEvent) {
        if event.type == .otherMouseUp, event.buttonNumber == 2, model.visible,
           model.mode != .spaces,
           !UserDefaults.standard.bool(forKey: SwitchPreferences.disableMouseKey),
           let wid = model.pointerWindowID {
            model.closeWindow(withWindowID: wid)
            return
        }
        super.sendEvent(event)
    }

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
        animationBehavior = SwitchPreferences.shared.disableAnimations ? .none : .default

        let screen = Self.pickerScreen()
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

    static func pickerScreen() -> NSScreen? {
        switch SwitchPreferences.shared.pickerDisplay {
        case .mouse:
            let cursor = NSEvent.mouseLocation
            return NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) })
                ?? NSScreen.main
        case .active:
            // NSScreen.main is the screen holding the key window, not the primary display.
            return NSScreen.main
        case .primary:
            return NSScreen.screens.first
        }
    }
}

private enum SwitcherPanelSize {
    private static let maxScreenFraction: CGFloat = 0.92

    static func current(mode: HotkeyManager.Mode, itemCount: Int, screen: NSScreen?) -> NSSize {
        let isList = UserDefaults.standard.bool(forKey: SwitchPreferences.verticalListKey)
        let widthScale = CGFloat(SwitchPreferences.clampedPanelWidthScale(
            UserDefaults.standard.object(forKey: SwitchPreferences.panelWidthScaleKey) as? Double
        ))
        let count = max(itemCount, 1)
        // Every mode sizes to the window count; a fixed panel leaves rows of empty backdrop (#134).
        let size = (mode == .spaces || isList)
            ? listSize(count: count, widthScale: widthScale, screen: screen)
            : gridSize(count: count, widthScale: widthScale, screen: screen)
        return fit(size, on: screen)
    }

    private static var hintHeight: CGFloat { SwitchPreferences.storedShowHintStrip ? 38 : 0 }

    // Whole rows only: a screen-capped height leaves a clipped row at the bottom (#132).
    private static func wholeRowsHeight(rows: Int, maxRows: Int, rowHeight: CGFloat, gap: CGFloat, chrome: CGFloat, screen: NSScreen?) -> CGFloat {
        let fitting = screen.map { Int(($0.visibleFrame.height * maxScreenFraction - chrome + gap) / (rowHeight + gap)) } ?? maxRows
        let visible = max(1, min(rows, maxRows, fitting))
        return chrome + CGFloat(visible) * rowHeight + CGFloat(visible - 1) * gap
    }

    private static func listSize(count: Int, widthScale: CGFloat, screen: NSScreen?) -> NSSize {
        let showPreview = SwitchPreferences.storedVerticalShowPreview && SwitchPreferences.storedShowThumbnails
        let height = wholeRowsHeight(
            rows: count,
            maxRows: UserDefaults.standard.read(SwitchPreferences.maxListRowsKey, default: SwitchPreferences.defaultMaxListRows),
            rowHeight: showPreview ? 62 : 48,
            gap: PickerLayout.listRowSpacing,
            chrome: PickerLayout.headerHeight + hintHeight + 20,
            screen: screen
        )
        return NSSize(width: CGFloat(SwitchPreferences.defaultListPanelWidth) * widthScale, height: max(260, height))
    }

    private static func gridSize(count: Int, widthScale: CGFloat, screen: NSScreen?) -> NSSize {
        let defaults = UserDefaults.standard
        let thumb = CGFloat(defaults.read(SwitchPreferences.thumbnailHeightKey, default: SwitchPreferences.defaultThumbnailHeight))
        let tileThumb = SwitchPreferences.storedShowThumbnails ? thumb : CGFloat(SwitchPreferences.compactThumbnailHeight)
        let configuredColumns = defaults.read(SwitchPreferences.gridColumnsKey, default: SwitchPreferences.defaultGridColumns)
        let columns = min(max(configuredColumns, 1), max(count, 3))
        let baseWidth: CGFloat = CGFloat(SwitchPreferences.defaultGridPanelWidth) * widthScale
        let horizontalPadding: CGFloat = 44
        let usable = baseWidth - horizontalPadding - CGFloat(max(configuredColumns - 1, 0)) * PickerLayout.gridSpacing
        let columnWidth = usable / CGFloat(configuredColumns)
        let width = horizontalPadding + CGFloat(columns) * columnWidth + CGFloat(max(columns - 1, 0)) * PickerLayout.gridSpacing

        let height = wholeRowsHeight(
            rows: Int(ceil(Double(count) / Double(columns))),
            maxRows: defaults.read(SwitchPreferences.maxGridRowsKey, default: SwitchPreferences.defaultMaxGridRows),
            rowHeight: tileThumb + 52,
            gap: PickerLayout.gridSpacing,
            chrome: PickerLayout.headerHeight + 16 + hintHeight,
            screen: screen
        )
        return NSSize(width: max(560, width), height: max(320, height))
    }

    private static func fit(_ size: NSSize, on screen: NSScreen?) -> NSSize {
        guard let screen else { return size }
        let visible = screen.visibleFrame
        return NSSize(
            width: min(size.width, visible.width * maxScreenFraction),
            height: min(size.height, visible.height * maxScreenFraction)
        )
    }
}
