#if DEBUG
import AppKit

/// Debug-build-only test rig: drive focus strategies from the command line and
/// read back what actually happened, since external processes lack AX trust.
///
///   post "switch.debug.dump"                       → /tmp/switch_debug.json
///   post "switch.debug.focus" {"wid": N, "strategy": S} → focuses, then dumps
///     strategies: current | slps | slps-noax | slps-activate
final class DebugFocusHarness {
    private var tokens: [NSObjectProtocol] = []

    func start() {
        let dnc = DistributedNotificationCenter.default()
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.dump"), object: nil, queue: .main
        ) { _ in
            Self.dump(to: "/tmp/switch_debug.json")
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.focus"), object: nil, queue: .main
        ) { note in
            guard let widStr = note.userInfo?["wid"] as? String,
                  let wid = UInt32(widStr),
                  let strategy = note.userInfo?["strategy"] as? String else { return }
            Self.runFocus(wid: CGWindowID(wid), strategy: strategy)
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.axdump"), object: nil, queue: .main
        ) { note in
            guard let pidStr = note.userInfo?["wid"] as? String, let pid = Int32(pidStr) else { return }
            Self.axDump(pid: pid)
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.axcapture"), object: nil, queue: .main
        ) { note in
            guard let pidStr = note.userInfo?["wid"] as? String, let pid = Int32(pidStr) else { return }
            Self.capture(pid: pid)
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.axenable"), object: nil, queue: .main
        ) { note in
            guard let pidStr = note.userInfo?["wid"] as? String, let pid = Int32(pidStr) else { return }
            let appAX = AXUIElementCreateApplication(pid)
            let r1 = AXUIElementSetAttributeValue(appAX, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            let r2 = AXUIElementSetAttributeValue(appAX, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            try? "axenable \(pid): manual=\(r1.rawValue) enhanced=\(r2.rawValue)".write(toFile: "/tmp/switch_debug_capture.txt", atomically: true, encoding: .utf8)
        })
    }

    private static func runFocus(wid: CGWindowID, strategy: String) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let all = WindowEnumerator.currentWindows(scope: .allWindows, frontmostPID: frontmost)
        guard let window = all.first(where: { $0.id == wid }) else {
            try? "{\"error\": \"wid \(wid) not found\"}".write(toFile: "/tmp/switch_debug_result.json", atomically: true, encoding: .utf8)
            return
        }
        switch strategy {
        case "current":       WindowFocuser.focus(window)
        case "cached":
            if let ax = stash[wid] {
                AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
                let appAX = AXUIElementCreateApplication(window.pid)
                AXUIElementSetAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, ax)
                NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
            } else {
                try? "{\"error\": \"no cached ax for \(wid)\"}".write(toFile: "/tmp/switch_debug_result.json", atomically: true, encoding: .utf8)
                return
            }
        case "setfs":
            if let ax = stash[wid] {
                AXUIElementSetAttributeValue(ax, "AXFullScreen" as CFString, kCFBooleanTrue)
            }
        case "menu":
            let ok = WindowFocuser.focusViaWindowMenu(window)
            if !ok {
                try? "{\"error\": \"no menu item matched\"}".write(toFile: "/tmp/switch_debug_result.json", atomically: true, encoding: .utf8)
                return
            }
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            dump(to: "/tmp/switch_debug_result.json", focusedWid: wid, strategy: strategy)
        }
    }

    /// AX elements captured while their windows were on the active Space.
    /// Remote AX handles stay valid after the window leaves the Space; this is
    /// how AltTab can raise windows Chromium no longer enumerates.
    nonisolated(unsafe) static var stash: [CGWindowID: AXUIElement] = [:]

    static func capture(pid: pid_t) {
        let appAX = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else { return }
        for ax in axWindows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(ax, &wid) == .success, wid != 0 {
                stash[wid] = ax
            }
        }
        try? "captured \(axWindows.count) for \(pid), stash now \(stash.count)".write(toFile: "/tmp/switch_debug_capture.txt", atomically: true, encoding: .utf8)
    }

    /// Dump an app's AX window list (wid, title, fullscreen, minimized) so we can
    /// see what Chromium actually exposes for cross-Space windows.
    private static func axDump(pid: pid_t) {
        let appAX = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        var rows: [[String: Any]] = []
        let err = AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &ref)
        if err == .success, let axWindows = ref as? [AXUIElement] {
            for ax in axWindows {
                var wid: CGWindowID = 0
                let widErr = _AXUIElementGetWindow(ax, &wid)
                var fsRef: CFTypeRef?
                AXUIElementCopyAttributeValue(ax, "AXFullScreen" as CFString, &fsRef)
                var minRef: CFTypeRef?
                AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &minRef)
                rows.append([
                    "wid": Int(wid), "widErr": widErr.rawValue,
                    "title": AXHelpers.title(of: ax),
                    "fullscreen": (fsRef as? Bool) ?? false,
                    "minimized": (minRef as? Bool) ?? false,
                ])
            }
        }
        let out: [String: Any] = ["pid": Int(pid), "axErr": err.rawValue, "windows": rows]
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/switch_debug_ax.json"))
        }
    }

    private static func dump(to path: String, focusedWid: CGWindowID? = nil, strategy: String? = nil) {
        let cid = CGSMainConnectionID()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let all = WindowEnumerator.enumerate(scope: .allWindows, frontmostPID: frontmost?.processIdentifier)
        func encode(_ w: WindowInfo) -> [String: Any] {
            [
                "wid": Int(w.id), "pid": Int(w.pid), "app": w.appName, "title": w.title,
                "crossSpace": w.isCrossSpace, "fullscreenSpace": w.isFullscreenSpace,
                "space": w.spaceLabel ?? "", "minimized": w.isMinimized, "hidden": w.isHidden,
            ]
        }
        var out: [String: Any] = [
            "activeSpace": Int(CGSGetActiveSpace(cid)),
            "frontmostApp": frontmost?.localizedName ?? "",
            "frontmostPID": Int(frontmost?.processIdentifier ?? 0),
            "activeSpaceWindows": all.activeSpace.map(encode),
            "crossSpaceWindows": all.crossSpace.map(encode),
        ]
        if let focusedWid { out["requestedWid"] = Int(focusedWid) }
        if let strategy { out["strategy"] = strategy }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
