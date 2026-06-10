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

    /// Empty placeholder used while the user is recording a new row in Settings.
    var isEmpty: Bool { keyCode == 0 && modifiersRaw == 0 }

    static let empty = HotkeyBinding(keyCode: 0, modifiersRaw: 0)

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

/// Persistent config for the arming hotkeys. Each action holds a list of bindings —
/// every binding in the list triggers the same action. Reads are served from a
/// lock-guarded cache so the event tap thread never touches UserDefaults.
final class HotkeyConfig {
    static let shared = HotkeyConfig()

    private let defaults = UserDefaults.standard
    private let allKey = "switch.hotkey.allWindows"
    private let appKey = "switch.hotkey.currentApp"
    private let spacesKey = "switch.hotkey.spaces"
    private let stickyKey = "switch.hotkey.stickyToggle"
    private let seededKey = "switch.hotkey.seeded"

    private let lock = NSLock()
    private var cachedAll: [HotkeyBinding] = []
    private var cachedApp: [HotkeyBinding] = []
    private var cachedSpaces: [HotkeyBinding] = []
    private var cachedSticky: [HotkeyBinding] = []

    static let didChangeNotification = Notification.Name("com.sanyamgarg.switch.hotkeyConfigDidChange")

    // Seed each action's defaults once so a fresh install gets its defaults; after
    // that an empty list means the user deliberately cleared the action (disabled).
    private init() {
        if !defaults.bool(forKey: seededKey) {
            if loadList(allKey) == nil { writeList([.defaultAllWindows], key: allKey) }
            if loadList(appKey) == nil { writeList([.defaultCurrentApp], key: appKey) }
            // Spaces ships unbound; ⌃Tab would swallow browser tab switching (#91). Opt in via Settings.
            defaults.set(true, forKey: seededKey)
        }
        cachedAll = loadList(allKey) ?? []
        cachedApp = loadList(appKey) ?? []
        cachedSpaces = loadList(spacesKey) ?? []
        cachedSticky = loadList(stickyKey) ?? []
    }

    // MARK: - List accessors (canonical)
    // An empty list means the action is disabled — seeding guarantees a fresh
    // install still gets its defaults, so empty here is a deliberate clear.

    var allWindowsBindings: [HotkeyBinding] {
        get { lock.lock(); defer { lock.unlock() }; return cachedAll }
        set { saveList(newValue, key: allKey) { self.cachedAll = $0 } }
    }

    var currentAppBindings: [HotkeyBinding] {
        get { lock.lock(); defer { lock.unlock() }; return cachedApp }
        set { saveList(newValue, key: appKey) { self.cachedApp = $0 } }
    }

    var spacesBindings: [HotkeyBinding] {
        get { lock.lock(); defer { lock.unlock() }; return cachedSpaces }
        set { saveList(newValue, key: spacesKey) { self.cachedSpaces = $0 } }
    }

    var stickyToggleBindings: [HotkeyBinding] {
        get { lock.lock(); defer { lock.unlock() }; return cachedSticky }
        set { saveList(newValue, key: stickyKey) { self.cachedSticky = $0 } }
    }

    func resetToDefaults() {
        writeList([.defaultAllWindows], key: allKey)
        writeList([.defaultCurrentApp], key: appKey)
        defaults.removeObject(forKey: spacesKey)
        defaults.removeObject(forKey: stickyKey)
        defaults.set(true, forKey: seededKey)
        lock.lock()
        cachedAll = [.defaultAllWindows]
        cachedApp = [.defaultCurrentApp]
        cachedSpaces = []
        cachedSticky = []
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Decode array first; fall back to legacy single-binding payload and wrap.
    private func loadList(_ key: String) -> [HotkeyBinding]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        if let arr = try? JSONDecoder().decode([HotkeyBinding].self, from: data) {
            return arr.filter { !$0.isEmpty }
        }
        if let one = try? JSONDecoder().decode(HotkeyBinding.self, from: data), !one.isEmpty {
            return [one]
        }
        return nil
    }

    private func saveList(_ list: [HotkeyBinding], key: String, updateCache: ([HotkeyBinding]) -> Void) {
        let cleaned = list.filter { !$0.isEmpty }
        if cleaned.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(cleaned) {
            defaults.set(data, forKey: key)
        }
        lock.lock()
        updateCache(cleaned)
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Persist without posting a change notification — used for one-time seeding
    /// and reset, where listeners reload through their own paths.
    private func writeList(_ list: [HotkeyBinding], key: String) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
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
    static func reject(keyCode: UInt16, flags: CGEventFlags) -> String? {
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let cleaned = flags.intersection(mask)
        if cleaned.intersection([.maskCommand, .maskAlternate, .maskControl]).rawValue == 0 {
            return "Needs at least one modifier (⌘, ⌥, or ⌃)."
        }
        for (rk, rf) in reserved where rk == keyCode && rf == cleaned {
            return "That combo is reserved by macOS or common apps."
        }
        return nil
    }

    /// Reject if the same combo (modulo shift) already appears in `existing`.
    /// Shift is ignored — matchesTrigger ignores it anyway, so two bindings that
    /// differ only by shift would behave identically.
    static func duplicate(of candidate: HotkeyBinding, in existing: [HotkeyBinding]) -> Bool {
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        let cFlags = candidate.cgFlags.intersection(mask)
        return existing.contains { b in
            b.keyCode == candidate.keyCode && b.cgFlags.intersection(mask) == cFlags
        }
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
        101: "F9", 109: "F10", 103: "F11", 111: "F12"
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
