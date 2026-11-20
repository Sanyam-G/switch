import AppKit
import ApplicationServices

enum WindowFocuser {
    private static var focusGen = 0  // main thread only

    /// `bringHere` pulls a desktop window from another Space into this one;
    /// Spaces mode passes false so picking a Space goes there instead.
    static func focus(_ window: WindowInfo, bringHere: Bool = true) {
        focusGen &+= 1
        if window.isWindowless {
            let app = NSRunningApplication(processIdentifier: window.pid)
            if app?.isHidden == true { app?.unhide() }
            if let url = app?.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            } else {
                app?.activate(options: [])
            }
            return
        }
        // "Bring the window here" only between desktop Spaces. Fullscreen
        // windows own their Space and can't be moved into another one, and
        // moving a desktop window while standing on a fullscreen Space sucks
        // it INTO that Space. Any fullscreen involvement → go to the window.
        if bringHere && window.isCrossSpace && !window.isFullscreenSpace {
            let cid = CGSMainConnectionID()
            let currentSpace = CGSGetActiveSpace(cid)
            if WindowEnumerator.spaceMetadata(cid: cid).labels[Int(currentSpace)]?.isFullscreen != true {
                let ids = [NSNumber(value: window.id)] as CFArray
                CGSMoveWindowsToManagedSpace(cid, ids, currentSpace)
                // Exempt from the current-space-claim prune: if the raise below
                // fails, the moved window sits here off-screen with no AX element.
                WindowEnumerator.noteSwitchMovedWindow(window.id)
            }
        }

        let app = NSRunningApplication(processIdentifier: window.pid)
        if app?.isHidden == true { app?.unhide() }

        // Same-Space targets get an early best-effort activate so slow AX apps
        // (Godot, #117) start coming forward before the raise calls below. The
        // late activate still runs; cross-Space skips this because the
        // focused-window write must steer activation first.
        if !window.isCrossSpace { cooperativeActivate(app) }

        let appAX = AXUIElementCreateApplication(window.pid)
        let axWindows = AXHelpers.windowList(of: appAX)
        var raised = false
        if let target = bestMatch(for: window, in: axWindows) {
            raised = raise(target, in: appAX)
            if AXHelpers.windowID(of: target) == window.id { recheck(target, in: appAX, for: window) }
        }
        // No usable element (Chromium hiding off-Space windows + cold cache, or
        // a stale cached handle): let the app focus it via its own Window menu.
        if !raised && window.isCrossSpace {
            focusViaWindowMenu(window)
        }

        cooperativeActivate(app)

        if UserDefaults.standard.bool(forKey: SwitchPreferences.moveCursorToWindowKey) { moveCursor(to: window.bounds) }
        WindowMRU.touch(window.id)
    }

    @discardableResult
    private static func raise(_ target: AXUIElement, in appAX: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        // Focused-window steers which Space activate() lands on when the
        // app has windows across several Spaces (fullscreen Chrome).
        AXUIElementSetAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, target)
        return AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
    }

    // activate() lands asynchronously, after the raise, and AppKit can then
    // restore the app's previous key window over the target (#57). Once the
    // app is frontmost, raise the same element again if it lost. Never a sibling.
    private static func recheck(_ target: AXUIElement, in appAX: AXUIElement, for window: WindowInfo) {
        let gen = focusGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard gen == focusGen,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid else { return }
            let focused = AXHelpers.attribute(kAXFocusedWindowAttribute, of: appAX).flatMap { AXHelpers.windowID(of: $0 as! AXUIElement) }
            if focused != window.id { raise(target, in: appAX) }
        }
    }

    // Only when the target sits on a different display than the pointer (#151).
    private static func moveCursor(to bounds: CGRect) {
        guard let mouse = CGEvent(source: nil)?.location else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var mouseDisplay = CGDirectDisplayID(0), targetDisplay = CGDirectDisplayID(0), n: UInt32 = 0
        CGGetDisplaysWithPoint(mouse, 1, &mouseDisplay, &n)
        CGGetDisplaysWithPoint(center, 1, &targetDisplay, &n)
        if mouseDisplay != targetDisplay { CGWarpMouseCursorPosition(center) }
    }

    // macOS 26 cooperative activation ignores activate() from the active app; yield first (#90).
    private static func cooperativeActivate(_ app: NSRunningApplication?) {
        if let app, NSApp.isActive { NSApp.yieldActivation(to: app) }
        app?.activate(options: [])
    }

    /// Last-resort cross-Space focus: press the app's Window-menu item whose
    /// title matches the target window. The menu bar stays AX-accessible even
    /// when the app hides off-Space windows from enumeration (Chromium), and
    /// the app's own handler does makeKeyAndOrderFront, so macOS performs the
    /// Space switch natively. Only a unique match counts: two "New Tab" items
    /// can't be told apart, and the wrong one switches to the wrong window.
    @discardableResult
    static func focusViaWindowMenu(_ window: WindowInfo) -> Bool {
        guard !window.title.isEmpty,
              let bar = AXHelpers.attribute(kAXMenuBarAttribute, of: AXUIElementCreateApplication(window.pid)) else { return false }
        // Window/Help only; Chrome's History menu matches closed windows by title and pressing one reopens it (#115).
        let hits = AXHelpers.children(of: bar as! AXUIElement).suffix(2)
            .flatMap(AXHelpers.children(of:))  // submenus
            .flatMap(AXHelpers.children(of:))  // items
            .filter { AXHelpers.title(of: $0) == window.title }
        guard hits.count == 1 else { return false }
        return AXUIElementPerformAction(hits[0], kAXPressAction as CFString) == .success
    }

    /// Direct CGWindowID match via private SPI, then AXWindowCache (Chromium
    /// apps hide off-Space windows from kAXWindowsAttribute entirely). Bounds
    /// and title only as last resorts, and only when exactly one window fits:
    /// raising an arbitrary sibling sends focus to the wrong window. A window
    /// whose id resolves isn't the target (the exact match already failed),
    /// so only id-less elements (Java/Qt, a failed lookup) are candidates.
    private static func bestMatch(for window: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement? {
        if let exact = AXHelpers.element(for: window, in: axWindows) { return exact }
        let unknown = axWindows.filter { AXHelpers.windowID(of: $0) == nil }
        let b = window.bounds
        let near = unknown.filter { ax in
            guard let f = AXHelpers.frame(of: ax) else { return false }
            return abs(f.minX - b.minX) + abs(f.minY - b.minY) + abs(f.width - b.width) + abs(f.height - b.height) < 40
        }
        if near.count == 1 { return near[0] }
        guard !window.title.isEmpty else { return nil }
        let titled = (near.isEmpty ? unknown : near).filter { AXHelpers.title(of: $0) == window.title }
        return titled.count == 1 ? titled[0] : nil
    }
}

enum AppCloser {
    static func close(_ window: WindowInfo) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        // A Steam row quits Steam, not the helper that owns its windows (#206).
        let host = app?.bundleIdentifier == window.bundleID ? nil
            : window.bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        (host ?? app)?.terminate()
    }
}

enum AXHelpers {
    static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &ref)
        return ref
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
    }

    /// App element with a short timeout, so one hung app can't stall a sweep or the main thread.
    static func appElement(for pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }

    static func title(of element: AXUIElement) -> String {
        attribute(kAXTitleAttribute, of: element) as? String ?? ""
    }

    /// Press a stoplight button (kAXCloseButtonAttribute etc.) on this exact window,
    /// never a sibling. False without acting when its element doesn't resolve.
    @discardableResult
    static func press(_ button: String, of window: WindowInfo) -> Bool {
        guard let target = element(for: window, in: windowList(of: AXUIElementCreateApplication(window.pid))),
              let btn = attribute(button, of: target) else { return false }
        return AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString) == .success
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// This exact window's element, never a sibling: the live list, then
    /// AXWindowCache, then a remote-token scan of the app's element ids.
    /// kAXWindowsAttribute only lists windows on the current Space, so a window
    /// on another Space that this Switch process never saw on-screen (after a
    /// relaunch or update) needs the scan. The app keeps the ids it vended to
    /// earlier AX clients, so the scan finds them (#176).
    static func element(for window: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement? {
        if let live = axWindows.first(where: { windowID(of: $0) == window.id }) { return live }
        if let cached = AXWindowCache.element(for: window.id) { return cached }
        guard window.isCrossSpace, let found = scanForWindow(pid: window.pid, wid: window.id) else { return nil }
        AXWindowCache.store(found, for: window.id)
        return found
    }

    // Element ids count up from 0 over the app's lifetime (~40µs per probe).
    // ponytail: linear scan capped at 0.3s, misses windows created after
    // ~7k other elements; walk in the background at launch if that bites.
    private static func scanForWindow(pid: pid_t, wid: CGWindowID) -> AXUIElement? {
        var token = Data(count: 20)  // pid, 0, "coco", element id
        withUnsafeBytes(of: pid) { token.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: UInt32(0x636f636f)) { token.replaceSubrange(8..<12, with: $0) }
        let deadline = Date().addingTimeInterval(0.3)
        var id: UInt64 = 0
        while Date() < deadline {
            withUnsafeBytes(of: id) { token.replaceSubrange(12..<20, with: $0) }
            id += 1
            guard let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(el, 0.1)
            guard windowID(of: el) == wid else { continue }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            if role as? String == kAXWindowRole { return el }
        }
        return nil
    }

    static func windowList(of appAX: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    /// AX position + size as a CGRect, or nil if either attribute is missing.
    /// Used to disambiguate windows when titles collide (e.g. Chrome).
    static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        guard let posObj = posRef, let sizeObj = sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posObj as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeObj as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
}
