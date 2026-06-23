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

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var armed: Mode?
    private var armedAt: Date?
    private var advanced = false
    private var lastShift = false
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
        installTap()
        installWakeObserver()
        startHealthCheck()
    }

    func stop() {
        uninstallTap()
        if let wakeToken { NSWorkspace.shared.notificationCenter.removeObserver(wakeToken) }
        if let screensWakeToken { NSWorkspace.shared.notificationCenter.removeObserver(screensWakeToken) }
        wakeToken = nil
        screensWakeToken = nil
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func uninstallTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        tap = nil
        source = nil
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
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return }
        uninstallTap()
        installTap()
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
        self.tap = tap
        self.source = src
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

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
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if armed == nil { armed = .allWindows; armedAt = Date(); advanced = false; onArm?(.allWindows) }
                    else { advanced = true; onAdvance?(shift) }
                }
                return nil
            }
            if let spacesBinding, spacesBinding.matchesTrigger(keyCode: kc, flags: flags) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if armed == nil { armed = .spaces; armedAt = Date(); advanced = false; onArm?(.spaces) }
                    else { advanced = true; onAdvance?(shift) }
                }
                return nil
            }
            if let appBinding, appBinding.matchesTrigger(keyCode: kc, flags: flags) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if armed == nil { armed = .currentApp; armedAt = Date(); advanced = false; onArm?(.currentApp) }
                    else { advanced = true; onAdvance?(shift) }
                }
                return nil
            }

            if armed != nil {
                let sticky = UserDefaults.standard.bool(forKey: SwitchPreferences.stickyModeKey)
                let typeToFilter = (UserDefaults.standard.object(forKey: SwitchPreferences.typeToFilterKey) as? Bool) ?? true
                let actionModifierMatches = cmd && (sticky || !typeToFilter || shift)
                if kc == Self.kcEscape {
                    DispatchQueue.main.async { [weak self] in
                        self?.armed = nil
                        self?.onCancel?()
                    }
                    return nil
                }
                if kc == Self.kcReturn || kc == Self.kcKeypadEnter {
                    DispatchQueue.main.async { [weak self] in
                        self?.armed = nil
                        self?.onCommit?()
                    }
                    return nil
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
                if cmd && kc == Self.kcComma {
                    DispatchQueue.main.async { [weak self] in
                        self?.armed = nil
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
            let shiftRising = shift && !lastShift
            lastShift = shift

            guard let mode = armed else { return Unmanaged.passUnretained(event) }
            let armingHeld = armingModifiersHeld(mode, flags)

            if shiftRising && armingHeld
                && UserDefaults.standard.bool(forKey: SwitchPreferences.shiftTapReversesKey) {
                DispatchQueue.main.async { [weak self] in
                    self?.advanced = true
                    self?.onAdvance?(true)
                }
                return nil
            }

            if !armingHeld {
                let sticky = UserDefaults.standard.bool(forKey: SwitchPreferences.stickyModeKey)
                let quickTap = (armedAt.map { Date().timeIntervalSince($0) * 1000 < Self.stickyQuickTapMS } ?? false) && !advanced
                if !sticky || quickTap {
                    DispatchQueue.main.async { [weak self] in
                        self?.armed = nil
                        self?.onCommit?()
                    }
                }
            }
        }

        return Unmanaged.passUnretained(event)
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

    /// Main-thread only (all mutations of `armed` happen on main).
    var isArmed: Bool { armed != nil }

    func clearArmed() {
        armed = nil
        armedAt = nil
        advanced = false
    }

    /// Reinstall the tap so the new HotkeyConfig is picked up. Called when bindings change.
    /// Only touches the tap — wake observers + health timer stay in place.
    func reload() {
        guard tap != nil else { return }
        uninstallTap()
        installTap()
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
        case Self.kcUpArrow:    return .up
        case Self.kcDownArrow:  return .down
        default:                return nil
        }
    }

    private func digitIndex(for kc: CGKeyCode) -> Int? {
        Self.kcDigits.firstIndex(of: kc) ?? Self.kcKeypadDigits.firstIndex(of: kc)
    }
}
