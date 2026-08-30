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
        hotkey.onCommit = { [weak self, weak model, weak window] in
            self?.cancelPendingPresent()
            model?.commit()
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
        model.onMetricsChange = { [weak window] in window?.applyContentSize() }
        hotkey.onCloseSelected = { present(); model.closeSelected() }
        hotkey.onCloseSelectedApp = { present(); model.closeSelectedApp() }
        hotkey.onHideSelected = { present(); model.hideSelected() }
        hotkey.onNavigate = { present(); model.navigate(direction: $0) }
        hotkey.onPickIndex = { present(); model.pickIndex($0) }
        hotkey.onPickSelectOnly = { present(); model.selectIndex($0) }
        hotkey.onFilterAppend = { present(); model.appendFilter($0) }
        hotkey.onFilterBackspace = { present(); model.backspaceFilter() }
        hotkey.onFilterEnabled = {
            model.filterSession = true
            model.stickySession = true
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
        // List rows are sized from the icon, so the panel has to be remeasured with it.
        SwitchPreferences.shared.$appIconSize
            .dropFirst()
            .sink { [weak window] _ in window?.applyContentSize() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$maxListRows
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
        // Row count is capped by the screen, so fall back to the one we are on.
        let fitted = SwitcherPanelSize.current(
            mode: model.mode,
            itemCount: model.filteredWindows.count,
            metrics: model.metrics,
            screen: screen ?? self.screen ?? NSScreen.main
        )
        model.panelSize = CGSize(width: fitted.width, height: fitted.height)
        setContentSize(fitted)
    }

    func present() {
        // Re-asserted every present so the panel migrates across Spaces.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = SwitchPreferences.shared.disableAnimations ? .none : .default

        let screen: NSScreen?
        switch SwitchPreferences.shared.pickerDisplay {
        case .mouse:
            let cursor = NSEvent.mouseLocation
            screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) })
                ?? NSScreen.main
        case .active:
            // NSScreen.main is the screen holding the key window, not the primary display.
            screen = NSScreen.main
        case .primary:
            screen = NSScreen.screens.first
        }
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
    static func current(mode: HotkeyManager.Mode, itemCount: Int, metrics: PanelMetrics, screen: NSScreen?) -> NSSize {
        let defaults = UserDefaults.standard
        let isList = defaults.bool(forKey: SwitchPreferences.verticalListKey)
        let thumb = CGFloat((defaults.object(forKey: SwitchPreferences.thumbnailHeightKey) as? Double) ?? SwitchPreferences.defaultThumbnailHeight)
        let scale = thumb / CGFloat(SwitchPreferences.defaultThumbnailHeight)
        let count = max(itemCount, 1)
        // Matches showHeader in SwitchView, minus the filter-text case: a filter both
        // reveals the header and changes the count, and the panel is remeasured then.
        let showsHeader = mode == .spaces || !isList
            || ((defaults.object(forKey: SwitchPreferences.verticalShowHeaderKey) as? Bool) ?? true)
        // Every mode sizes to the window count; a fixed panel leaves rows of empty backdrop (#134).
        let size = (mode == .spaces || isList)
            ? listSize(defaults: defaults, count: count, scale: scale, showsHeader: showsHeader,
                       metrics: metrics, screen: screen)
            : gridSize(defaults: defaults, count: count, thumb: thumb, scale: scale, metrics: metrics)
        return fit(size, on: screen)
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    // Mirrors hintStrip in SwitchView: one line of pills plus .padding(.vertical, 8),
    // where the key pill adds .padding(.vertical, 1) around its monospaced text.
    private static let hintStripHeight: CGFloat = {
        let label = lineHeight(.systemFont(ofSize: 11))
        let key = lineHeight(.monospacedSystemFont(ofSize: 10, weight: .semibold)) + 2
        return max(label, key) + 16
    }()

    // Mirrors listRow in SwitchView: the row is as tall as its tallest element plus
    // .padding(.vertical, 6) on each side. A hardcoded height silently disagreed with
    // non-default icon sizes and left a partial extra row visible.
    private static let listRowTextHeight: CGFloat =
        lineHeight(.systemFont(ofSize: 13, weight: .medium)) + 2 + lineHeight(.systemFont(ofSize: 11))
    private static let listRowPreviewHeight: CGFloat = 50
    private static let listRowVerticalPadding: CGFloat = 6

    private static func listRowHeight(iconSize: CGFloat, showPreview: Bool) -> CGFloat {
        var content = max(iconSize, listRowTextHeight)
        if showPreview { content = max(content, listRowPreviewHeight) }
        return content + listRowVerticalPadding * 2
    }

    /// A measurement of the real thing beats any constant that mirrors the view by hand.
    private static func measured(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value > 0 ? value : fallback
    }

    private static let listRowSpacing: CGFloat = 4

    private static func listSize(defaults: UserDefaults, count: Int, scale: CGFloat, showsHeader: Bool,
                                 metrics: PanelMetrics, screen: NSScreen?) -> NSSize {
        let showHints = (defaults.object(forKey: SwitchPreferences.showHintStripKey) as? Bool) ?? true
        let showThumbs = (defaults.object(forKey: SwitchPreferences.showThumbnailsKey) as? Bool) ?? true
        let showPreview = ((defaults.object(forKey: SwitchPreferences.verticalShowPreviewKey) as? Bool) ?? true) && showThumbs
        let iconSize = CGFloat((defaults.object(forKey: SwitchPreferences.appIconSizeKey) as? Double) ?? SwitchPreferences.defaultAppIconSize)
        let hintHeight: CGFloat = showHints ? measured(metrics.hintHeight, fallback: hintStripHeight) : 0
        let rowHeight = measured(
            metrics.rowHeight,
            fallback: listRowHeight(iconSize: iconSize, showPreview: showPreview)
        )
        let headerHeight: CGFloat = showsHeader ? measured(metrics.headerHeight, fallback: 26) : 0
        let topPadding: CGFloat = showsHeader ? 10 : 14
        // The top padding is inside the scroll content; the bottom one sits outside it,
        // so both are always on screen and neither can be filled by a clipped row.
        let bottomPadding: CGFloat = 10
        let chrome = headerHeight + topPadding + bottomPadding + hintHeight

        // Whole rows only: a height the rows do not divide into leaves the remainder
        // showing as a clipped row, which is what a fixed pixel cap used to produce.
        let ceiling = (screen?.visibleFrame.height ?? .greatestFiniteMagnitude) * screenFraction
        let fitting = Int(floor((ceiling - chrome + listRowSpacing) / (rowHeight + listRowSpacing)))
        let maxRows = (defaults.object(forKey: SwitchPreferences.maxListRowsKey) as? Int)
            ?? SwitchPreferences.defaultMaxListRows
        let visibleRows = max(1, min(count, maxRows, fitting))
        let rowGaps = CGFloat(max(visibleRows - 1, 0)) * listRowSpacing
        let height = chrome + CGFloat(visibleRows) * rowHeight + rowGaps
        return NSSize(width: 520 * scale, height: max(260, height))
    }

    private static func gridSize(defaults: UserDefaults, count: Int, thumb: CGFloat, scale: CGFloat, metrics: PanelMetrics) -> NSSize {
        let showHints = (defaults.object(forKey: SwitchPreferences.showHintStripKey) as? Bool) ?? true
        let showThumbs = (defaults.object(forKey: SwitchPreferences.showThumbnailsKey) as? Bool) ?? true
        let tileThumb: CGFloat = showThumbs ? thumb : SwitchPreferences.compactThumbnailHeight
        let configuredColumns = (defaults.object(forKey: SwitchPreferences.gridColumnsKey) as? Int) ?? SwitchPreferences.defaultGridColumns
        let columns = min(max(configuredColumns, 1), max(count, 3))
        let baseWidth: CGFloat = 880 * scale
        let horizontalPadding: CGFloat = 44
        let columnSpacing: CGFloat = 14
        let usable = baseWidth - horizontalPadding - CGFloat(max(configuredColumns - 1, 0)) * columnSpacing
        let columnWidth = usable / CGFloat(configuredColumns)
        let width = horizontalPadding + CGFloat(columns) * columnWidth + CGFloat(max(columns - 1, 0)) * columnSpacing

        let rows = Int(ceil(Double(count) / Double(columns)))
        let tileHeight = measured(metrics.tileHeight, fallback: tileThumb + 52)
        let rowsHeight = CGFloat(rows) * tileHeight + CGFloat(max(rows - 1, 0)) * 14
        let hintHeight: CGFloat = showHints ? measured(metrics.hintHeight, fallback: hintStripHeight) : 0
        let height = measured(metrics.headerHeight, fallback: 26) + 16 + rowsHeight + hintHeight
        return NSSize(width: max(560, width), height: min(560 * scale, max(320, height)))
    }

    private static let screenFraction: CGFloat = 0.92

    private static func fit(_ size: NSSize, on screen: NSScreen?) -> NSSize {
        guard let screen else { return size }
        let visible = screen.visibleFrame
        return NSSize(
            width: min(size.width, visible.width * screenFraction),
            height: min(size.height, visible.height * screenFraction)
        )
    }
}
