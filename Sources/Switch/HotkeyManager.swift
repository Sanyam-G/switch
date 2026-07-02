import AppKit
import ApplicationServices
import CoreGraphics

final class HotkeyManager {
    enum Mode { case allWindows, currentApp, spaces }
    enum Direction { case left, right, up, down }

    var onArm: ((Mode) -> Void)?
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
    var onOpenSettings: (() -> Void)?

    private let stateLock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var armed: Mode?
    private var armedAt: Date?
    private var advanced = false
    private var lastShift = false
    private var suspended = false
    private var stopRequested = false

    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

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
        tapRunLoop = nil
    }

    private func startTapThread() {
        guard tapThread == nil else { return }
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.tapRunLoop = CFRunLoopGetCurrent()
            self.installTap()
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
    }

    private func performOnTapThread(_ block: @escaping () -> Void) {
        guard let rl = tapRunLoop else { return }
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
        let shift = flags.contains(.maskShift)
        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown {
            let allBinding = HotkeyConfig.shared.allWindows
            let appBinding = HotkeyConfig.shared.currentApp
            let spacesBinding = HotkeyConfig.shared.spaces

            if let stickyBinding = HotkeyConfig.shared.stickyToggle,
               stickyBinding.matchesTrigger(keyCode: kc, flags: flags) {
                DispatchQueue.main.async { [weak self] in
                    self?.onStickyToggle?()
                }
                return nil
            }

            if let allBinding, allBinding.matchesTrigger(keyCode: kc, flags: flags) {
                armOrAdvance(.allWindows, shift: shift)
                return nil
            }
            if let spacesBinding, spacesBinding.matchesTrigger(keyCode: kc, flags: flags) {
                armOrAdvance(.spaces, shift: shift)
                return nil
            }
            if let appBinding, appBinding.matchesTrigger(keyCode: kc, flags: flags) {
                armOrAdvance(.currentApp, shift: shift)
                return nil
            }

            stateLock.lock()
            let armedMode = armed
            stateLock.unlock()

            if let mode = armedMode {
                let sticky = UserDefaults.standard.bool(forKey: SwitchPreferences.stickyModeKey)
                let typeToFilter = (UserDefaults.standard.object(forKey: SwitchPreferences.typeToFilterKey) as? Bool) ?? true
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
                if !sticky && !armingModifiersHeld(mode, flags) {
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
                if actionModifierMatches && kc == Self.kcH {
                    DispatchQueue.main.async { [weak self] in
                        self?.onHideSelected?()
                    }
                    return nil
                }
                if kc == Self.kcComma {
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
                if typeToFilter, let c = filterChar(from: event) {
                    DispatchQueue.main.async { [weak self] in
                        self?.onFilterAppend?(c)
                    }
                    return nil
                }
            }
        }

        if type == .flagsChanged {
            stateLock.lock()
            let shiftRising = shift && !lastShift
            lastShift = shift
            guard let mode = armed else {
                stateLock.unlock()
                return Unmanaged.passUnretained(event)
            }
            let armingHeld = armingModifiersHeld(mode, flags)

            if shiftRising && armingHeld
                && UserDefaults.standard.bool(forKey: SwitchPreferences.shiftTapReversesKey) {
                advanced = true
                stateLock.unlock()
                DispatchQueue.main.async { [weak self] in
                    self?.onAdvance?(true)
                }
                return nil
            }

            if !armingHeld {
                let sticky = UserDefaults.standard.bool(forKey: SwitchPreferences.stickyModeKey)
                let quickTap = (armedAt.map { Date().timeIntervalSince($0) * 1000 < Self.stickyQuickTapMS } ?? false) && !advanced
                if !sticky || quickTap {
                    armed = nil
                    armedAt = nil
                    advanced = false
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

    private func armOrAdvance(_ mode: Mode, shift: Bool) {
        stateLock.lock()
        let isFirst = armed == nil
        if isFirst {
            armed = mode
            armedAt = Date()
            advanced = false
        } else {
            advanced = true
        }
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            if isFirst { self?.onArm?(mode) } else { self?.onAdvance?(shift) }
        }
    }

    private func armingModifiersHeld(_ mode: Mode, _ flags: CGEventFlags) -> Bool {
        let binding: HotkeyBinding?
        switch mode {
        case .allWindows: binding = HotkeyConfig.shared.allWindows
        case .currentApp: binding = HotkeyConfig.shared.currentApp
        case .spaces:     binding = HotkeyConfig.shared.spaces
        }
        return binding?.modifiersHeld(flags) ?? false
    }

    var isArmed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return armed != nil
    }

    func clearArmed() {
        stateLock.lock()
        armed = nil
        armedAt = nil
        advanced = false
        stateLock.unlock()
    }

    func setSuspended(_ value: Bool) {
        stateLock.lock()
        suspended = value
        if value {
            armed = nil
            armedAt = nil
            advanced = false
        }
        stateLock.unlock()
    }

    func recoverIfReleaseWasMissed() {
        let hardware = CGEventSource.flagsState(.combinedSessionState)
        stateLock.lock()
        guard let mode = armed else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        let sticky = UserDefaults.standard.bool(forKey: SwitchPreferences.stickyModeKey)
        guard !sticky, !armingModifiersHeld(mode, hardware) else { return }
        stateLock.lock()
        let stillArmed = armed != nil
        armed = nil
        armedAt = nil
        advanced = false
        stateLock.unlock()
        if stillArmed {
            DispatchQueue.main.async { [weak self] in
                self?.onCommit?()
            }
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

    private func filterChar(from event: CGEvent) -> Character? {
        guard let ns = NSEvent(cgEvent: event),
              let chars = ns.charactersIgnoringModifiers,
              let c = chars.first else { return nil }
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
