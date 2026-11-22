import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

final class HotkeyManager {
    enum Mode { case allWindows, currentApp, spaces }
    enum Direction { case left, right, up, down }

    /// How a binding arms the picker: base mode plus per-binding overrides (#131, #130).
    struct ArmStyle {
        let mode: Mode
        var sticky = false
        var currentSpaceOnly = false
        var currentDisplayOnly = false
        /// Shift held at arm: start from the least-recent window, like native ⌘⇧Tab (#144).
        var reverse = false
    }

    private static let armSlots: [(slot: HotkeyConfig.Slot, style: ArmStyle)] = [
        (.allWindows, ArmStyle(mode: .allWindows)),
        (.allWindowsAlternate, ArmStyle(mode: .allWindows)),
        (.spaces, ArmStyle(mode: .spaces)),
        (.spacesAlternate, ArmStyle(mode: .spaces)),
        (.currentApp, ArmStyle(mode: .currentApp)),
        (.currentAppAlternate, ArmStyle(mode: .currentApp)),
        (.allWindowsSticky, ArmStyle(mode: .allWindows, sticky: true)),
        (.currentAppSticky, ArmStyle(mode: .currentApp, sticky: true)),
        (.currentSpace, ArmStyle(mode: .allWindows, currentSpaceOnly: true)),
        (.currentDisplay, ArmStyle(mode: .allWindows, currentDisplayOnly: true))
    ]

    var onArm: ((ArmStyle) -> Void)?
    /// (reverse, clamp): clamp is set for held keys so they stop at the ends (#200).
    var onAdvance: ((Bool, Bool) -> Void)?
    /// Shift pressed alone steps back (false); a chord then undoes that step (true) (#199).
    var onShiftStep: ((Bool) -> Void)?
    /// True for a sticky-mode quick tap: the picker never showed, so commit the previous window (#96).
    var onCommit: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onCloseSelected: (() -> Void)?
    var onCloseSelectedApp: (() -> Void)?
    var onHideSelected: (() -> Void)?
    var onNavigate: ((Direction) -> Void)?
    var onPickIndex: ((Int) -> Void)?
    var onPickSelectOnly: ((Int) -> Void)?
    var onFilterAppend: ((Character) -> Void)?
    var onFilterBackspace: (() -> Void)?
    var onStickyToggle: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let stateLock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var armed: Mode?
    private var armedBinding: HotkeyBinding?
    private var armedSticky = false
    private var armedAt: Date?
    /// Bumped per arm. shownArmGen is the last one main received, so main never clears an arm it hasn't seen.
    private var armGen = 0
    private var shownArmGen = 0
    private var advanced = false
    private var lastShift = false
    /// Shift's press stepped back and nothing else followed yet, so a key now makes it a chord to undo (#199).
    private var shiftTapPending = false
    private var shiftRepeating = false
    /// Bumped on every Shift edge and key, so a stale repeat timer stops.
    private var shiftGen = 0
    private var suspended = false
    /// Read on the tap thread; NSWorkspace is only safe to query from main.
    private var frontmostBundleID: String?
    /// Read on the tap thread; TIS calls hit TSM, which is only safe from main.
    private var layoutData: Data?
    private var keyboardType: UInt32 = 0

    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private let tapReady = DispatchSemaphore(value: 0)

    private static let stickyQuickTapMS: Double = 200
    private static let shiftRepeatExtraDelay: TimeInterval = 0.25
    private var healthTimer: Timer?
    private var tapPingPending = false

    private static let kcEscape = CGKeyCode(kVK_Escape)
    private static let kcReturn = CGKeyCode(kVK_Return)
    private static let kcKeypadEnter = CGKeyCode(kVK_ANSI_KeypadEnter)
    private static let kcDelete = CGKeyCode(kVK_Delete)
    private static let kcLeftArrow = CGKeyCode(kVK_LeftArrow)
    private static let kcRightArrow = CGKeyCode(kVK_RightArrow)
    private static let kcDownArrow = CGKeyCode(kVK_DownArrow)
    private static let kcUpArrow = CGKeyCode(kVK_UpArrow)
    private static let kcBacktick = CGKeyCode(kVK_ANSI_Grave)
    private static let kcDigits: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    private static let kcKeypadDigits: [CGKeyCode] = [83, 84, 85, 86, 87, 88, 89, 91, 92]

    /// False when Accessibility isn't granted yet, so the caller retries instead of treating hotkeys as running.
    @discardableResult
    func start() -> Bool {
        // No prompt: start() is polled, and onboarding's Open Settings already prompts.
        guard AXIsProcessTrusted() else { return false }
        startTapThread()
        installWakeObserver()
        installFrontmostObserver()
        installLayoutObserver()
        startHealthCheck()
        return true
    }

    private func startTapThread() {
        guard tapThread == nil else { return }
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.tapRunLoop = CFRunLoopGetCurrent()
            self.stateLock.unlock()
            self.installTap()
            self.tapReady.signal()
            while true {
                let result = CFRunLoopRunInMode(.defaultMode, 3600, false)
                if result == .finished { Thread.sleep(forTimeInterval: 1.0) }
            }
        }
        thread.name = "com.sanyamgarg.switch.eventtap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        _ = tapReady.wait(timeout: .now() + 1.0)
    }

    private func performOnTapThread(_ block: @escaping () -> Void) {
        stateLock.lock()
        let rl = tapRunLoop
        stateLock.unlock()
        guard let rl else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            // A thread abandoned by restartTapThread may unstick later; its queued work must not touch the new tap.
            guard let self else { return }
            self.stateLock.lock()
            let current = self.tapRunLoop === CFRunLoopGetCurrent()
            self.stateLock.unlock()
            if current { block() }
        }
        CFRunLoopWakeUp(rl)
    }

    /// Main thread. The tap thread is stuck (a callback never returned), so work queued to it never runs
    /// and reload() can't heal it. Abandon it and start a fresh one.
    // ponytail: leaks the stuck thread instead of killing it; Foundation has no safe way to kill one.
    private func restartTapThread() {
        stateLock.lock()
        let oldTap = tap
        tap = nil
        source = nil
        tapRunLoop = nil
        tapPingPending = false
        stateLock.unlock()
        if let oldTap { killTap(oldTap) }
        NSLog("Switch: event tap thread stopped responding, restarting it")
        // The old thread may still hold a press the new tap never saw released.
        clearArmed()
        onCancel?()
        tapThread = nil
        startTapThread()
    }

    private func uninstallTap() {
        stateLock.lock()
        let tap = self.tap
        let source = self.source
        self.tap = nil
        self.source = nil
        stateLock.unlock()
        if let tap { killTap(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
    }

    private func killTap(_ tap: CFMachPort) {
        CGEvent.tapEnable(tap: tap, enable: false)
        // Without this a replaced tap can stay registered with the window server.
        CFMachPortInvalidate(tap)
    }

    /// Sleep/wake + screensaver-end can leave the tap in a disabled state that
    /// `tapDisabledByTimeout` doesn't always cover. Listen explicitly and
    /// reinstall.
    private func installWakeObserver() {
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reinstallIfNeeded()
            }
        }
    }

    private func installFrontmostObserver() {
        setFrontmost(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.setFrontmost(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    private func setFrontmost(_ app: NSRunningApplication?) {
        stateLock.lock()
        frontmostBundleID = app?.bundleIdentifier
        stateLock.unlock()
    }

    private func installLayoutObserver() {
        refreshLayoutData()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshLayoutData()
        }
    }

    private func refreshLayoutData() {
        let data = KeyName.layoutData()
        let type = UInt32(LMGetKbdType())
        stateLock.lock()
        layoutData = data
        keyboardType = type
        stateLock.unlock()
    }

    /// Hotkeys go to pass-through apps (VMs, remote desktops) instead of arming the picker.
    /// Once armed, keep handling them so cycling onto such an app doesn't drop the picker.
    private func shouldPassThrough() -> Bool {
        stateLock.lock()
        let bid = frontmostBundleID
        let isArmed = armed != nil
        stateLock.unlock()
        guard !isArmed, let bid else { return false }
        let apps = UserDefaults.standard.stringArray(forKey: SwitchPreferences.passthroughAppsKey) ?? []
        return apps.contains(bid)
    }

    /// Defense in depth: even with timeout + wake handlers, occasionally a tap
    /// ends up disabled (TCC blip, run-loop weirdness). Cheap to check.
    private func startHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
    }

    /// Pings the tap thread each tick. If last tick's ping never ran, the thread is stuck.
    private func checkHealth() {
        stateLock.lock()
        let stuck = tapPingPending
        tapPingPending = true
        stateLock.unlock()
        if stuck {
            restartTapThread()
            return
        }
        performOnTapThread { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.tapPingPending = false
            self.stateLock.unlock()
        }
        reinstallIfNeeded()
    }

    private func reinstallIfNeeded() {
        stateLock.lock()
        let tap = self.tap
        stateLock.unlock()
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return }
        reload()
    }

    private func installTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        let cb: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return mgr.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: cb,
            userInfo: info
        ) else {
            NSLog("Switch: failed to create event tap")
            return
        }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        // A thread restartTapThread abandoned mid-install must not publish a second live tap.
        stateLock.lock()
        let owner = tapRunLoop === CFRunLoopGetCurrent()
        if owner {
            self.tap = tap
            self.source = src
        }
        stateLock.unlock()
        guard owner else {
            CFMachPortInvalidate(tap)
            return
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateLock.lock()
            let tap = self.tap
            stateLock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A release while the tap was off never reached us (#211).
            recoverIfReleaseWasMissed()
            return Unmanaged.passUnretained(event)
        }

        stateLock.lock()
        let isSuspended = suspended
        stateLock.unlock()
        if isSuspended { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        let cmd = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if type == .keyDown {
            stateLock.lock()
            // Any key while Shift is down makes it a chord (⇧⌘W), not a reverse tap (#143), so
            // take back the step Shift's press made unless it was already repeating (#199).
            let undoShiftStep = shiftTapPending && !shiftRepeating
            shiftTapPending = false
            shiftGen &+= 1
            stateLock.unlock()
            if undoShiftStep {
                onMain { $0.onShiftStep?(true) }
            }

            // Ahead of the hotkey match: a key can carry a modifier that isn't down, so plain Tab
            // advances and every key is swallowed (#211). The session state is read now, not when
            // the key was made, so a lagging tap sees a release still queued; recheck shortly instead.
            stateLock.lock()
            let heldBinding = armedSticky ? nil : armedBinding
            stateLock.unlock()
            if let heldBinding, kc != Self.kcEscape, kc != Self.kcReturn, kc != Self.kcKeypadEnter {
                if !heldBinding.modifiersHeld(flags) {
                    clearArmed()
                    onMain { $0.onCommit?(false) }
                    return Unmanaged.passUnretained(event)
                }
                if !heldBinding.modifiersHeld(CGEventSource.flagsState(.combinedSessionState)) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.recoverIfReleaseWasMissed()
                    }
                }
            }

            if let stickyBinding = HotkeyConfig.shared[.stickyToggle],
               stickyBinding.matchesTrigger(keyCode: kc, flags: flags) {
                if shouldPassThrough() { return Unmanaged.passUnretained(event) }
                onMain { $0.onStickyToggle?() }
                return nil
            }

            // Ahead of armSlots so a ⌘` binding steps back once armed; key code like the system ⌘` (#177).
            if cmd && kc == Self.kcBacktick && isArmed
                && UserDefaults.standard.bool(forKey: SwitchPreferences.backtickReversesKey) {
                stateLock.lock()
                advanced = true
                stateLock.unlock()
                onMain { $0.onAdvance?(true, isRepeat) }
                return nil
            }

            for (slot, style) in Self.armSlots {
                guard let binding = HotkeyConfig.shared[slot],
                      binding.matchesTrigger(keyCode: kc, flags: flags) else { continue }
                if shouldPassThrough() { return Unmanaged.passUnretained(event) }
                armOrAdvance(style, binding: binding, shift: shift, isRepeat: isRepeat)
                return nil
            }

            stateLock.lock()
            let armedMode = armed
            let activeBinding = armedBinding
            let sticky = armedSticky
            stateLock.unlock()

            if armedMode != nil {
                let key = layoutChar(from: event)
                let (homeRow, vimNavigation, typeToFilter) = SwitchPreferences.storedInputModes()
                // ⌃⌘Q (Lock Screen) isn't ⌘Q: no primary modifiers beyond ⌘ and the binding's own.
                let extraModifiers = flags.intersection(.primaryModifiers)
                    .subtracting((activeBinding?.cgFlags ?? []).union(.maskCommand))
                let actionModifierMatches = cmd && extraModifiers.isEmpty && (sticky || !typeToFilter || shift)
                if kc == Self.kcEscape {
                    clearArmed()
                    onMain { $0.onCancel?() }
                    return nil
                }
                if kc == Self.kcReturn || kc == Self.kcKeypadEnter {
                    clearArmed()
                    onMain { $0.onCommit?(false) }
                    return nil
                }
                if typeToFilter && kc == Self.kcDelete {
                    onMain { $0.onFilterBackspace?() }
                    return nil
                }
                if actionModifierMatches && key == "w" {
                    onMain { $0.onCloseSelected?() }
                    return nil
                }
                if actionModifierMatches && key == "q" {
                    onMain { $0.onCloseSelectedApp?() }
                    return nil
                }
                // Vim's H moves left, so ⌘H needs Shift there (#171 left H out of home row keys for the same reason).
                if actionModifierMatches && key == "h" && (!vimNavigation || shift) {
                    onMain { $0.onHideSelected?() }
                    return nil
                }
                if key == "," && (cmd || activeBinding?.modifiersHeld(flags) == true) {
                    clearArmed()
                    onMain { $0.onCancel?(); $0.onOpenSettings?() }
                    return nil
                }
                if let direction = arrowDirection(for: kc) ?? (vimNavigation ? vimDirection(for: key) : nil) {
                    onMain { $0.onNavigate?(direction) }
                    return nil
                }
                if let index = digitIndex(for: kc)
                    ?? (homeRow ? key.flatMap { SwitchPreferences.homeRowKeys.firstIndex(of: $0) } : nil) {
                    let chain = cmd
                    onMain { chain ? $0.onPickSelectOnly?(index) : $0.onPickIndex?(index) }
                    return nil
                }
                if typeToFilter, let c = filterChar(from: event) {
                    onMain { $0.onFilterAppend?(c) }
                    return nil
                }
                // Unbound keys stay with the picker; otherwise ⌘S or ⌘X lands in the app underneath.
                return nil
            }
        }

        if type == .flagsChanged {
            stateLock.lock()
            let shiftRising = shift && !lastShift
            let shiftFalling = !shift && lastShift
            lastShift = shift
            guard armed != nil else {
                stateLock.unlock()
                return Unmanaged.passUnretained(event)
            }
            let armingHeld = armedBinding?.modifiersHeld(flags) ?? false

            if shiftFalling {
                shiftTapPending = false
                shiftGen &+= 1
            }
            // Steps on press and repeats while held; a chord undoes the step, a pre-arm Shift never steps (#143, #199).
            if shiftRising && armingHeld && UserDefaults.standard.bool(forKey: SwitchPreferences.shiftTapReversesKey) {
                shiftTapPending = true
                shiftRepeating = false
                advanced = true
                shiftGen &+= 1
                let gen = shiftGen
                stateLock.unlock()
                onMain { $0.onShiftStep?(false); $0.scheduleShiftRepeat(gen, first: true) }
                return Unmanaged.passUnretained(event)
            }

            if !armingHeld {
                // Only quick if the picker hasn't shown yet, so a 0ms delay never flips back (#179).
                let delayMS = SwitchPreferences.storedActivationDelay
                let quickTapMS = min(Self.stickyQuickTapMS, delayMS)
                let quickTap = (armedAt.map { Date().timeIntervalSince($0) * 1000 < quickTapMS } ?? false) && !advanced
                if !armedSticky || quickTap {
                    let stickyQuickTap = armedSticky
                    clearArmedLocked()
                    stateLock.unlock()
                    onMain { $0.onCommit?(stickyQuickTap) }
                    return Unmanaged.passUnretained(event)
                }
            }
            stateLock.unlock()
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    /// Main thread. Shift sends no key repeats, so follow the system repeat timing while it stays held alone.
    private func scheduleShiftRepeat(_ gen: Int, first: Bool) {
        // Longer than a key's repeat delay so a slow ⇧⌘W lands before Shift starts repeating.
        let delay = first ? NSEvent.keyRepeatDelay + Self.shiftRepeatExtraDelay : NSEvent.keyRepeatInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let live = self.shiftGen == gen && self.shiftTapPending && self.armed != nil
            if live { self.shiftRepeating = true }
            self.stateLock.unlock()
            guard live else { return }
            self.onAdvance?(true, true)
            self.scheduleShiftRepeat(gen, first: false)
        }
    }

    /// The tap thread never waits on main; it hands work over and returns the event.
    private func onMain(_ f: @escaping (HotkeyManager) -> Void) {
        DispatchQueue.main.async { [weak self] in self.map(f) }
    }

    private func armOrAdvance(_ style: ArmStyle, binding: HotkeyBinding, shift: Bool, isRepeat: Bool) {
        var effective = style
        effective.sticky = style.sticky || UserDefaults.standard.bool(forKey: SwitchPreferences.stickyModeKey)
        effective.reverse = shift
        stateLock.lock()
        let isFirst = armed == nil
        if isFirst {
            armGen &+= 1
            armed = style.mode
            armedBinding = binding
            armedSticky = effective.sticky
            armedAt = Date()
            advanced = false
        } else {
            advanced = true
        }
        let gen = armGen
        stateLock.unlock()
        onMain {
            if isFirst {
                $0.stateLock.lock()
                $0.shownArmGen = gen
                $0.stateLock.unlock()
                $0.onArm?(effective)
            } else {
                $0.onAdvance?(shift, isRepeat)
            }
        }
    }

    var isArmed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return armed != nil
    }

    private func clearArmedLocked() {
        armed = nil
        armedBinding = nil
        armedSticky = false
        armedAt = nil
        advanced = false
        shiftTapPending = false
        shiftRepeating = false
    }

    private func clearArmed() {
        stateLock.lock()
        clearArmedLocked()
        stateLock.unlock()
    }

    /// Main thread. Clears the arm main has shown, never a newer one whose onArm is still queued.
    func clearShownArm() {
        stateLock.lock()
        if armGen == shownArmGen { clearArmedLocked() }
        stateLock.unlock()
    }

    func setSuspended(_ value: Bool) {
        stateLock.lock()
        suspended = value
        if value { clearArmedLocked() }
        stateLock.unlock()
    }

    func recoverIfReleaseWasMissed() {
        let hardware = CGEventSource.flagsState(.combinedSessionState)
        stateLock.lock()
        guard let mode = armed, let binding = armedBinding, let at = armedAt else {
            stateLock.unlock()
            return
        }
        let sticky = armedSticky
        stateLock.unlock()
        guard !sticky, !binding.modifiersHeld(hardware) else { return }
        stateLock.lock()
        guard armed == mode, armedBinding == binding, armedAt == at else {
            stateLock.unlock()
            return
        }
        clearArmedLocked()
        stateLock.unlock()
        onMain { $0.onCommit?(false) }
    }

    func reload() {
        performOnTapThread { [weak self] in
            self?.uninstallTap()
            self?.installTap()
        }
    }

    // NSEvent character APIs hit TSM, which asserts main-queue on macOS 26.2+ and traps this thread.
    private func filterChar(from event: CGEvent) -> Character? {
        guard let c = layoutChar(from: event, keeping: .maskShift) else { return nil }
        if c.isLetter || c == " " || c == "-" || c == "." {
            return c
        }
        return nil
    }

    // The character the key produces on the current layout, so ⌘W is the W key on AZERTY too (#149).
    private func layoutChar(from event: CGEvent, keeping: CGEventFlags = []) -> Character? {
        // A key event's string is fixed when it's created, so clearing ⌥ on a copy still gives ç for C, and ⌃H gives 0x08.
        if !event.flags.intersection([.maskAlternate, .maskControl]).isEmpty, let c = translatedChar(from: event, keeping: keeping) {
            return c
        }
        guard let copy = event.copy() else { return nil }
        copy.flags = copy.flags.intersection(keeping)
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        copy.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0, let c = String(utf16CodeUnits: buffer, count: length).first else { return nil }
        return Character(c.lowercased())
    }

    private func translatedChar(from event: CGEvent, keeping: CGEventFlags) -> Character? {
        stateLock.lock()
        let layout = layoutData
        let type = keyboardType
        stateLock.unlock()
        guard let layout else { return nil }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shifted = keeping.contains(.maskShift) && event.flags.contains(.maskShift)
        return KeyName.translate(layout, code: code, action: kUCKeyActionDown,
                                 modifiers: shifted ? UInt32(shiftKey >> 8) : 0, kbdType: type)?.lowercased().first
    }

    private func arrowDirection(for kc: CGKeyCode) -> Direction? {
        switch kc {
        case Self.kcLeftArrow:  return .left
        case Self.kcRightArrow: return .right
        case Self.kcDownArrow:  return .down
        case Self.kcUpArrow:    return .up
        default:                return nil
        }
    }

    private func vimDirection(for key: Character?) -> Direction? {
        switch key {
        case "h": return .left
        case "j": return .down
        case "k": return .up
        case "l": return .right
        default: return nil
        }
    }

    private func digitIndex(for kc: CGKeyCode) -> Int? {
        Self.kcDigits.firstIndex(of: kc) ?? Self.kcKeypadDigits.firstIndex(of: kc)
    }
}
