import AppKit
import ApplicationServices
import CoreGraphics

final class HotkeyManager {
    enum Mode { case allWindows, currentApp, spaces }
    enum Direction { case left, right, up, down }

    /// How a binding arms the picker: base mode plus per-binding overrides (#131, #130).
    struct ArmStyle {
        let mode: Mode
        var sticky = false
        var currentSpaceOnly = false
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
        (.currentSpace, ArmStyle(mode: .allWindows, currentSpaceOnly: true))
    ]

    var onArm: ((ArmStyle) -> Void)?
    var onAdvance: ((Bool) -> Void)?
    var onCommit: (() -> Void)?
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
    /// Fired when ⌘F turns filtering on or off for an invocation that started without it.
    /// Turning it on also makes the invocation sticky, so typing does not require
    /// holding the modifier.
    var onFilterSessionChanged: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?

    private let stateLock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var armed: Mode?
    private var armedBinding: HotkeyBinding?
    private var armedSticky = false
    /// Type-to-filter switched on by ⌘F for this invocation only.
    private var armedFilter = false
    private var armedAt: Date?
    private var advanced = false
    private var lastShift = false
    private var shiftTapPending = false
    private var suspended = false
    private var stopRequested = false

    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private let tapReady = DispatchSemaphore(value: 0)

    private static let stickyQuickTapMS: Double = 200
    private var wakeToken: NSObjectProtocol?
    private var screensWakeToken: NSObjectProtocol?
    private var healthTimer: Timer?

    private static let kcEscape: CGKeyCode = 53
    private static let kcReturn: CGKeyCode = 36
    private static let kcKeypadEnter: CGKeyCode = 76
    private static let kcDelete: CGKeyCode = 51
    private static let kcLeftArrow: CGKeyCode = 123
    private static let kcRightArrow: CGKeyCode = 124
    private static let kcDownArrow: CGKeyCode = 125
    private static let kcUpArrow: CGKeyCode = 126
    private static let kcW: CGKeyCode = 13
    private static let kcQ: CGKeyCode = 12
    private static let kcH: CGKeyCode = 4
    private static let kcF: CGKeyCode = 3
    private static let kcComma: CGKeyCode = 43
    private static let kcDigits: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    private static let kcKeypadDigits: [CGKeyCode] = [83, 84, 85, 86, 87, 88, 89, 91, 92]

    func start() {
        if !ensureAccessibility() { return }
        startTapThread()
        installWakeObserver()
        startHealthCheck()
    }

    func stop() {
        if let wakeToken { NSWorkspace.shared.notificationCenter.removeObserver(wakeToken) }
        if let screensWakeToken { NSWorkspace.shared.notificationCenter.removeObserver(screensWakeToken) }
        wakeToken = nil
        screensWakeToken = nil
        healthTimer?.invalidate()
        healthTimer = nil
        stateLock.lock()
        stopRequested = true
        stateLock.unlock()
        performOnTapThread { [weak self] in
            self?.uninstallTap()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        tapThread = nil
        stateLock.lock()
        tapRunLoop = nil
        stateLock.unlock()
    }

    private func startTapThread() {
        guard tapThread == nil else { return }
        stateLock.lock()
        stopRequested = false
        stateLock.unlock()
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.tapRunLoop = CFRunLoopGetCurrent()
            self.stateLock.unlock()
            self.installTap()
            self.tapReady.signal()
            while true {
                self.stateLock.lock()
                let shouldStop = self.stopRequested
                self.stateLock.unlock()
                if shouldStop { break }
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
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    private func uninstallTap() {
        stateLock.lock()
        let tap = self.tap
        let source = self.source
        self.tap = nil
        self.source = nil
        stateLock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
    }

    /// Sleep/wake + screensaver-end can leave the tap in a disabled state that
    /// `tapDisabledByTimeout` doesn't always cover. Listen explicitly and
    /// reinstall.
    private func installWakeObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        wakeToken = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reinstallIfNeeded()
        }
        screensWakeToken = nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reinstallIfNeeded()
        }
    }

    /// Defense in depth: even with timeout + wake handlers, occasionally a tap
    /// ends up disabled (TCC blip, run-loop weirdness). Cheap to check.
    private func startHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.reinstallIfNeeded()
        }
    }

    private func reinstallIfNeeded() {
        stateLock.lock()
        let tap = self.tap
        stateLock.unlock()
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return }
        performOnTapThread { [weak self] in
            self?.uninstallTap()
            self?.installTap()
        }
    }

    @discardableResult
    private func ensureAccessibility() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
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
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        stateLock.lock()
        self.tap = tap
        self.source = src
        stateLock.unlock()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateLock.lock()
            let tap = self.tap
            stateLock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        stateLock.lock()
        let isSuspended = suspended
        stateLock.unlock()
        if isSuspended { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        let cmd = flags.contains(.maskCommand)
        let control = flags.contains(.maskControl)
        let shift = flags.contains(.maskShift)
        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown {
            stateLock.lock()
            // Any key while Shift is down makes it a chord (⇧⌘W), not a reverse tap (#143).
            shiftTapPending = false
            stateLock.unlock()

            if let stickyBinding = HotkeyConfig.shared[.stickyToggle],
               stickyBinding.matchesTrigger(keyCode: kc, flags: flags) {
                DispatchQueue.main.async { [weak self] in
                    self?.onStickyToggle?()
                }
                return nil
            }

            for (slot, style) in Self.armSlots {
                guard let binding = HotkeyConfig.shared[slot],
                      binding.matchesTrigger(keyCode: kc, flags: flags) else { continue }
                armOrAdvance(style, binding: binding, shift: shift)
                return nil
            }

            stateLock.lock()
            let armedMode = armed
            let activeBinding = armedBinding
            let sticky = armedSticky
            let filterSession = armedFilter
            stateLock.unlock()

            if armedMode != nil {
                // ⌘F opts an invocation into filtering when the preference is off.
                let typeToFilter = ((UserDefaults.standard.object(forKey: SwitchPreferences.typeToFilterKey) as? Bool) ?? true)
                    || filterSession
                let actionModifierMatches = cmd && (sticky || !typeToFilter || shift)
                if kc == Self.kcEscape {
                    clearArmed()
                    DispatchQueue.main.async { [weak self] in
                        self?.onCancel?()
                    }
                    return nil
                }
                if kc == Self.kcReturn || kc == Self.kcKeypadEnter {
                    clearArmed()
                    DispatchQueue.main.async { [weak self] in
                        self?.onCommit?()
                    }
                    return nil
                }
                if !sticky && !(activeBinding?.modifiersHeld(flags) ?? false) {
                    clearArmed()
                    DispatchQueue.main.async { [weak self] in
                        self?.onCommit?()
                    }
                    return Unmanaged.passUnretained(event)
                }
                if typeToFilter && kc == Self.kcDelete {
                    DispatchQueue.main.async { [weak self] in
                        self?.onFilterBackspace?()
                    }
                    return nil
                }
                if actionModifierMatches && kc == Self.kcW {
                    DispatchQueue.main.async { [weak self] in
                        self?.onCloseSelected?()
                    }
                    return nil
                }
                if actionModifierMatches && kc == Self.kcQ {
                    DispatchQueue.main.async { [weak self] in
                        self?.onCloseSelectedApp?()
                    }
                    return nil
                }
                if actionModifierMatches && kc == Self.kcF {
                    let enabling = !filterSession
                    stateLock.lock()
                    armedFilter = enabling
                    if enabling {
                        // Typing a filter one-handed means letting go of the modifier, so the
                        // invocation goes sticky. advanced suppresses the quick-tap commit that
                        // a release within stickyQuickTapMS of arming would otherwise trigger.
                        armedSticky = true
                        advanced = true
                    }
                    stateLock.unlock()
                    DispatchQueue.main.async { [weak self] in
                        self?.onFilterSessionChanged?(enabling)
                    }
                    return nil
                }
                if actionModifierMatches && kc == Self.kcH {
                    DispatchQueue.main.async { [weak self] in
                        self?.onHideSelected?()
                    }
                    return nil
                }
                if kc == Self.kcComma && (cmd || activeBinding?.modifiersHeld(flags) == true) {
                    clearArmed()
                    DispatchQueue.main.async { [weak self] in
                        self?.onCancel?()
                        self?.onOpenSettings?()
                    }
                    return nil
                }
                if let direction = arrowDirection(for: kc) {
                    DispatchQueue.main.async { [weak self] in
                        self?.onNavigate?(direction)
                    }
                    return nil
                }
                if let index = digitIndex(for: kc) {
                    let chain = cmd
                    DispatchQueue.main.async { [weak self] in
                        if chain { self?.onPickSelectOnly?(index) }
                        else { self?.onPickIndex?(index) }
                    }
                    return nil
                }
                if typeToFilter, !cmd, !control, let c = filterChar(from: event) {
                    DispatchQueue.main.async { [weak self] in
                        self?.onFilterAppend?(c)
                    }
                    return nil
                }
                // filterChar decodes with the modifiers stripped, so ⌘A would otherwise
                // read as a plain "a" and be typed. Chords are not filter input; swallow
                // the ones this picker does not act on rather than leak them to the app
                // behind it.
                if typeToFilter, cmd || control {
                    return nil
                }
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

            // Release-fired so ⇧⌘W closes without stepping first; a pre-arm Shift never sets pending (#143).
            if armingHeld && UserDefaults.standard.bool(forKey: SwitchPreferences.shiftTapReversesKey) {
                if shiftRising {
                    shiftTapPending = true
                } else if shiftFalling && shiftTapPending {
                    shiftTapPending = false
                    advanced = true
                    stateLock.unlock()
                    DispatchQueue.main.async { [weak self] in
                        self?.onAdvance?(true)
                    }
                    return nil
                }
            }

            if !armingHeld {
                let quickTap = (armedAt.map { Date().timeIntervalSince($0) * 1000 < Self.stickyQuickTapMS } ?? false) && !advanced
                if !armedSticky || quickTap {
                    clearArmedLocked()
                    stateLock.unlock()
                    DispatchQueue.main.async { [weak self] in
                        self?.onCommit?()
                    }
                    return Unmanaged.passUnretained(event)
                }
            }
            stateLock.unlock()
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func armOrAdvance(_ style: ArmStyle, binding: HotkeyBinding, shift: Bool) {
        var effective = style
        effective.sticky = style.sticky || UserDefaults.standard.bool(forKey: SwitchPreferences.stickyModeKey)
        effective.reverse = shift
        stateLock.lock()
        let isFirst = armed == nil
        if isFirst {
            armed = style.mode
            armedBinding = binding
            armedSticky = effective.sticky
            armedFilter = false
            armedAt = Date()
            advanced = false
        } else {
            advanced = true
        }
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            if isFirst { self?.onArm?(effective) } else { self?.onAdvance?(shift) }
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
        armedFilter = false
        armedAt = nil
        advanced = false
        shiftTapPending = false
    }

    func clearArmed() {
        stateLock.lock()
        clearArmedLocked()
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
        DispatchQueue.main.async { [weak self] in
            self?.onCommit?()
        }
    }

    func reload() {
        reinstall()
    }

    private func reinstall() {
        performOnTapThread { [weak self] in
            self?.uninstallTap()
            self?.installTap()
        }
    }

    // NSEvent character APIs hit TSM, which asserts main-queue on macOS 26.2+ and traps this thread.
    private func filterChar(from event: CGEvent) -> Character? {
        guard let copy = event.copy() else { return nil }
        copy.flags = copy.flags.intersection(.maskShift)
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        copy.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0, let c = String(utf16CodeUnits: buffer, count: length).first else { return nil }
        if c.isLetter || c == " " || c == "-" || c == "." {
            return Character(c.lowercased())
        }
        return nil
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

    private func digitIndex(for kc: CGKeyCode) -> Int? {
        Self.kcDigits.firstIndex(of: kc) ?? Self.kcKeypadDigits.firstIndex(of: kc)
    }
}
