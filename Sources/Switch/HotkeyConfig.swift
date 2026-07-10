import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// User-rebindable hotkey for arming the switcher.
struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt16
    /// CGEventFlags raw value of the modifier mask required to trigger the hotkey.
    var modifiersRaw: UInt64

    var cgFlags: CGEventFlags { CGEventFlags(rawValue: modifiersRaw) }

    static let defaultAllWindows = HotkeyBinding(
        keyCode: 48, // Tab
        modifiersRaw: CGEventFlags.maskCommand.rawValue
    )

    static let defaultCurrentApp = HotkeyBinding(
        keyCode: 50, // Backtick
        modifiersRaw: CGEventFlags.maskAlternate.rawValue
    )

    static let defaultSpaces = HotkeyBinding(
        keyCode: 48, // Tab
        modifiersRaw: CGEventFlags.maskControl.rawValue
    )

    /// Whether `flags` contain exactly the required modifiers (ignoring shift, which is used for reverse).
    func modifiersHeld(_ flags: CGEventFlags) -> Bool {
        let needed = cgFlags
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        let needNeeded = needed.intersection(mask)
        let havNeeded = flags.intersection(mask)
        return havNeeded.contains(needNeeded) && needNeeded.rawValue != 0
    }

    /// Match a keyDown trigger: required modifiers held, no extra primary modifiers, key matches.
    /// Shift is ignored for matching (reserved for reverse-direction nav).
    func matchesTrigger(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard CGKeyCode(self.keyCode) == keyCode else { return false }
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        let needNeeded = cgFlags.intersection(mask)
        return flags.intersection(mask) == needNeeded
    }

    var displayString: String {
        var s = ""
        if cgFlags.contains(.maskControl) { s += "⌃" }
        if cgFlags.contains(.maskAlternate) { s += "⌥" }
        if cgFlags.contains(.maskShift) { s += "⇧" }
        if cgFlags.contains(.maskCommand) { s += "⌘" }
        s += KeyName.string(for: keyCode)
        return s
    }
}

/// Persistent config for the arming hotkeys.
final class HotkeyConfig {
    static let shared = HotkeyConfig()

    private let defaults = UserDefaults.standard
    private let allKey = "switch.hotkey.allWindows"
    private let secondaryAllKey = "switch.hotkey.secondaryAllWindows"
    private let appKey = "switch.hotkey.currentApp"
    private let spacesKey = "switch.hotkey.spaces"
    private let stickyKey = "switch.hotkey.stickyToggle"
    private let seededKey = "switch.hotkey.seeded"

    private let lock = NSLock()
    private var cachedAll: HotkeyBinding?
    private var cachedSecondaryAll: HotkeyBinding?
    private var cachedApp: HotkeyBinding?
    private var cachedSpaces: HotkeyBinding?
    private var cachedSticky: HotkeyBinding?

    static let didChangeNotification = Notification.Name("com.sanyamgarg.switch.hotkeyConfigDidChange")

    // Seed the three arming hotkeys once so a fresh install gets defaults; after that nil means disabled.
    private init() {
        if !defaults.bool(forKey: seededKey) {
            if load(allKey) == nil { write(.defaultAllWindows, key: allKey) }
            if load(appKey) == nil { write(.defaultCurrentApp, key: appKey) }
            // Spaces ships unbound; ⌃Tab would swallow browser tab switching (#91). Opt in via Settings.
            defaults.set(true, forKey: seededKey)
        }
        cachedAll = load(allKey)
        cachedSecondaryAll = load(secondaryAllKey)
        cachedApp = load(appKey)
        cachedSpaces = load(spacesKey)
        cachedSticky = load(stickyKey)
    }

    var allWindows: HotkeyBinding? {
        get { lock.lock(); defer { lock.unlock() }; return cachedAll }
        set { store(newValue, key: allKey) { self.cachedAll = newValue } }
    }

    var secondaryAllWindows: HotkeyBinding? {
        get { lock.lock(); defer { lock.unlock() }; return cachedSecondaryAll }
        set { store(newValue, key: secondaryAllKey) { self.cachedSecondaryAll = newValue } }
    }

    var currentApp: HotkeyBinding? {
        get { lock.lock(); defer { lock.unlock() }; return cachedApp }
        set { store(newValue, key: appKey) { self.cachedApp = newValue } }
    }

    var spaces: HotkeyBinding? {
        get { lock.lock(); defer { lock.unlock() }; return cachedSpaces }
        set { store(newValue, key: spacesKey) { self.cachedSpaces = newValue } }
    }

    var stickyToggle: HotkeyBinding? {
        get { lock.lock(); defer { lock.unlock() }; return cachedSticky }
        set { store(newValue, key: stickyKey) { self.cachedSticky = newValue } }
    }

    func resetToDefaults() {
        write(.defaultAllWindows, key: allKey)
        write(.defaultCurrentApp, key: appKey)
        defaults.removeObject(forKey: secondaryAllKey)
        defaults.removeObject(forKey: spacesKey)
        defaults.removeObject(forKey: stickyKey)
        lock.lock()
        cachedAll = .defaultAllWindows
        cachedSecondaryAll = nil
        cachedApp = .defaultCurrentApp
        cachedSpaces = nil
        cachedSticky = nil
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private func load(_ key: String) -> HotkeyBinding? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotkeyBinding.self, from: data)
    }

    private func store(_ b: HotkeyBinding?, key: String, updateCache: () -> Void) {
        if let b, let data = try? JSONEncoder().encode(b) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        lock.lock()
        updateCache()
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private func write(_ b: HotkeyBinding, key: String) {
        if let data = try? JSONEncoder().encode(b) { defaults.set(data, forKey: key) }
    }
}

/// Reserved combos we refuse to rebind onto (would break the system or the user's other shortcuts).
enum HotkeyValidator {
    private static let reserved: [(keyCode: UInt16, flags: CGEventFlags)] = [
        (12, .maskCommand),  // ⌘Q
        (13, .maskCommand),  // ⌘W
        (1,  .maskCommand),  // ⌘S
        (8,  .maskCommand),  // ⌘C
        (9,  .maskCommand),  // ⌘V
        (7,  .maskCommand),  // ⌘X
        (6,  .maskCommand),  // ⌘Z
        (15, .maskCommand),  // ⌘R
        (3,  .maskCommand),  // ⌘F
        (53, [])             // bare Esc
    ]

    /// Returns nil if the combo is allowed; otherwise a short human reason.
    static func reject(keyCode: UInt16, flags: CGEventFlags, allowBare: Bool = false) -> String? {
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let cleaned = flags.intersection(mask)
        if cleaned.intersection([.maskCommand, .maskAlternate, .maskControl]).rawValue == 0,
           !(allowBare
             && cleaned.rawValue == 0
             && [105, 107, 113, 106, 64, 79, 80, 90].contains(keyCode)) {
            return "Needs at least one modifier (⌘, ⌥, or ⌃)."
        }
        for (rk, rf) in reserved where rk == keyCode && rf == cleaned {
            return "That combo is reserved by macOS or common apps."
        }
        return nil
    }
}

enum KeyName {
    /// Human-readable key name (single char where possible, "Tab" / "F1" etc otherwise).
    static func string(for code: UInt16) -> String {
        if let s = special[code] { return s }
        // Fall back to NSEvent.charactersByApplyingModifiers for printable keys.
        if let cs = chars(for: code) { return cs.uppercased() }
        return "Key \(code)"
    }

    private static let special: [UInt16: String] = [
        48: "Tab",
        49: "Space",
        50: "`",
        53: "Esc",
        36: "Return",
        76: "Enter",
        51: "Delete",
        117: "Fwd Del",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16",
        64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]

    private static func chars(for code: UInt16) -> String? {
        guard let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length: Int = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return -1
            }
            return UCKeyTranslate(
                base,
                code,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                4,
                &length,
                &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
