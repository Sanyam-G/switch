#if DEBUG
import AppKit

/// Debug-build-only test rig: drive focus strategies from the command line and
/// read back what actually happened, since external processes lack AX trust.
///
///   post "switch.debug.dump"                       → /tmp/switch_debug.json
///   post "switch.debug.focus" {"wid": N, "strategy": "current"} → focuses, then dumps
///   post "switch.debug.axdump" {"wid": PID}        → /tmp/switch_debug_ax.json
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
    }

    private static func enumerated() -> (activeSpace: [WindowInfo], crossSpace: [WindowInfo]) {
        let full = WindowEnumerator.fullSnapshot()
        let showCross = (UserDefaults.standard.object(forKey: SwitchPreferences.crossSpaceKey) as? Bool) ?? true
        return (full.activeSpace, showCross ? full.crossSpace : full.crossSpace.filter { !$0.isCrossSpace })
    }

    private static func runFocus(wid: CGWindowID, strategy: String) {
        let e = enumerated()
        let all = e.activeSpace + e.crossSpace
        guard let window = all.first(where: { $0.id == wid }) else {
            try? "{\"error\": \"wid \(wid) not found\"}".write(toFile: "/tmp/switch_debug_result.json", atomically: true, encoding: .utf8)
            return
        }
        WindowFocuser.focus(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            dump(to: "/tmp/switch_debug_result.json", focusedWid: wid, strategy: strategy)
        }
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
        let all = enumerated()
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
