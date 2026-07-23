import AppKit
import ApplicationServices

private func axWindowID(_ element: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    let err = _AXUIElementGetWindow(element, &id)
    return err == .success ? id : nil
}

enum WindowFocuser {
    static func focus(_ window: WindowInfo) {
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
        if window.isCrossSpace && !window.isFullscreenSpace {
            let cid = CGSMainConnectionID()
            let currentSpace = CGSGetActiveSpace(cid)
            if !isFullscreenSpace(currentSpace, cid: cid) {
                let ids = [NSNumber(value: window.id)] as CFArray
                CGSMoveWindowsToManagedSpace(cid, ids, currentSpace)
                // Exempt from the current-space-claim prune: if the raise below
                // fails, the moved window sits here off-screen with no AX element.
                WindowEnumerator.noteSwitchMovedWindow(window.id)
            }
        }

        let app = NSRunningApplication(processIdentifier: window.pid)
        if app?.isHidden == true { app?.unhide() }

        let appAX = AXUIElementCreateApplication(window.pid)
        var ref: CFTypeRef?
        let axWindows = (AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &ref) == .success
            ? ref as? [AXUIElement] : nil) ?? []
        var raised = false
        if let target = bestMatch(for: window, in: axWindows) {
            AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
            // Focused-window steers which Space activate() lands on when the
            // app has windows across several Spaces (fullscreen Chrome).
            AXUIElementSetAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, target)
            raised = AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
        }
        // No usable element (Chromium hiding off-Space windows + cold cache, or
        // a stale cached handle): let the app focus it via its own Window menu.
        if !raised && window.isCrossSpace {
            focusViaWindowMenu(window)
        }

        // When Switch itself is the active app (owns a key Settings/About window while
        // staying .accessory), macOS 26 cooperative activation can ignore an activate()
        // from the active app; yield first so the target actually comes forward.
        if let app, NSApp.isActive { NSApp.yieldActivation(to: app) }
        app?.activate(options: [])

        WindowMRU.touch(window.id)
    }

    /// Last-resort cross-Space focus: press the app's Window-menu item whose
    /// title matches the target window. The menu bar stays AX-accessible even
    /// when the app hides off-Space windows from enumeration (Chromium), and
    /// the app's own handler does makeKeyAndOrderFront, so macOS performs the
    /// Space switch natively. Returns false when no item matched.
    @discardableResult
    static func focusViaWindowMenu(_ window: WindowInfo) -> Bool {
        guard !window.title.isEmpty else { return false }
        let appAX = AXUIElementCreateApplication(window.pid)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appAX, kAXMenuBarAttribute as CFString, &barRef) == .success,
              let bar = barRef else { return false }
        var menusRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &menusRef) == .success,
              let menus = menusRef as? [AXUIElement] else { return false }
        // Window/Help only; Chrome's History menu matches closed windows by title and pressing one reopens it (#115).
        for menuBarItem in menus.suffix(2).reversed() {
            var subRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(menuBarItem, kAXChildrenAttribute as CFString, &subRef) == .success,
                  let submenus = subRef as? [AXUIElement] else { continue }
            for submenu in submenus {
                var itemsRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(submenu, kAXChildrenAttribute as CFString, &itemsRef) == .success,
                      let items = itemsRef as? [AXUIElement] else { continue }
                for item in items where AXHelpers.title(of: item) == window.title {
                    if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
                        WindowMRU.touch(window.id)
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func isFullscreenSpace(_ space: CGSSpaceID, cid: CGSConnectionID) -> Bool {
        guard let displays = CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return false }
        for display in displays {
            for s in display["Spaces"] as? [[String: Any]] ?? [] {
                if let id = s["id64"] as? Int, CGSSpaceID(id) == space {
                    return (s["type"] as? Int ?? 0) != 0
                }
            }
        }
        return false
    }

    /// Direct CGWindowID match via private SPI; falls back to the AXWindowCache
    /// element captured while the window was on-screen (Chromium apps hide
    /// off-Space windows from kAXWindowsAttribute entirely, so the live list
    /// misses exactly the windows that need cross-Space focusing). Bounds and
    /// title matching remain as last resorts; never `first` — raising an
    /// arbitrary sibling sends focus to the wrong window.
    private static func bestMatch(for window: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement? {
        if let exact = axWindows.first(where: { axWindowID($0) == window.id }) {
            return exact
        }
        if let cached = AXWindowCache.element(for: window.id) {
            return cached
        }
        var bestByBounds: (element: AXUIElement, distance: CGFloat)?
        for ax in axWindows {
            guard let frame = AXHelpers.frame(of: ax) else { continue }
            let d = abs(frame.origin.x - window.bounds.origin.x)
                  + abs(frame.origin.y - window.bounds.origin.y)
                  + abs(frame.size.width  - window.bounds.size.width)
                  + abs(frame.size.height - window.bounds.size.height)
            if bestByBounds == nil || d < bestByBounds!.distance {
                bestByBounds = (ax, d)
            }
        }
        if let bestByBounds, bestByBounds.distance < 40 { return bestByBounds.element }
        return axWindows.first(where: { AXHelpers.title(of: $0) == window.title })
    }
}

enum AppCloser {
    static func close(_ window: WindowInfo) {
        NSRunningApplication(processIdentifier: window.pid)?.terminate()
    }
}

enum WindowCloser {
    static func close(_ window: WindowInfo) { pressButton(window, attribute: kAXCloseButtonAttribute) }

    /// Close only the specific window, resolving its AX element the way focus does
    /// (live wid match, then AXWindowCache) — never an arbitrary sibling. Returns
    /// false without acting when nothing resolves, so callers can decline to fall back.
    @discardableResult
    static func closeExact(_ window: WindowInfo) -> Bool {
        let appAX = AXUIElementCreateApplication(window.pid)
        var ref: CFTypeRef?
        let axWindows = (AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &ref) == .success
            ? ref as? [AXUIElement] : nil) ?? []
        guard let target = axWindows.first(where: { axWindowID($0) == window.id })
            ?? AXWindowCache.element(for: window.id) else { return false }
        var btnRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXCloseButtonAttribute as CFString, &btnRef) == .success,
              let btn = btnRef else { return false }
        return AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString) == .success
    }
}

enum WindowMinimizer {
    static func minimize(_ window: WindowInfo) { pressButton(window, attribute: kAXMinimizeButtonAttribute) }
}

enum WindowZoomer {
    static func zoom(_ window: WindowInfo) { pressButton(window, attribute: kAXZoomButtonAttribute) }
}

/// Press one of the stoplight buttons on the AX window matching `window`. Best-effort.
private func pressButton(_ window: WindowInfo, attribute: String) {
    let appAX = AXUIElementCreateApplication(window.pid)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &ref) == .success,
          let axWindows = ref as? [AXUIElement] else { return }
    let exact = axWindows.first(where: { axWindowID($0) == window.id })
    let target = exact
        ?? axWindows.first(where: { AXHelpers.title(of: $0) == window.title })
        ?? axWindows.first
    guard let target else { return }
    var btnRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(target, attribute as CFString, &btnRef) == .success,
          let btnObj = btnRef else { return }
    AXUIElementPerformAction(btnObj as! AXUIElement, kAXPressAction as CFString)
}

enum AXHelpers {
    static func title(of element: AXUIElement) -> String {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref)
        return ref as? String ?? ""
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
