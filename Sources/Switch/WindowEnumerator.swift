import AppKit
import ApplicationServices
import CoreGraphics

struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect
    var spaceID: Int?
    var isCrossSpace: Bool = false
    var isMinimized: Bool = false
    var isHidden: Bool = false
    var spaceLabel: String?
    var isFullscreenSpace: Bool = false
    var isWindowless: Bool = false
    var bundleID: String?
}

enum WindowEnumerator {
    private static let skipApps: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center",
        "Notification Center", "Spotlight", "WallpaperAgent", "Switch",
        "loginwindow", "talagent", "TextInputMenuAgent", "TextInputSwitcher",
        "universalControl", "ControlStrip", "ScreenshotCapture", "WindowManager"
    ]

    private static let helperSuffixes: [String] = [
        "Helper", " Helper", " Helper (Renderer)", " Helper (GPU)", " Helper (Plugin)",
        "Agent", " Agent",
        "Service", " Service", " View Service",
        "Renderer", "(Renderer)",
        "WebContent", "Networking",
        "Extension"
    ]

    private static func isHelperProcess(_ name: String) -> Bool {
        for s in helperSuffixes where name.hasSuffix(s) { return true }
        return false
    }

    struct Enumeration {
        let activeSpace: [WindowInfo]
        let crossSpace: [WindowInfo]
    }

    struct FullSnapshot {
        let activeSpace: [WindowInfo]
        let crossSpace: [WindowInfo]
        let spaceRepresentatives: [WindowInfo]

        var allWindows: [WindowInfo] { activeSpace + crossSpace }
        var allIDs: Set<CGWindowID> { Set(allWindows.map(\.id)) }
        var allPIDs: Set<pid_t> { Set(allWindows.map(\.pid)) }
    }

    static func fullSnapshot() -> FullSnapshot {
        let onScreen = enumerate(option: [.optionOnScreenOnly, .excludeDesktopElements])
        let everything = enumerate(option: [.optionAll, .excludeDesktopElements])
        let pids = Set(everything.map(\.pid)).union(onScreen.map(\.pid))
        let ax = axWindowState(for: pids)
        let cid = CGSMainConnectionID()
        let metadata = spaceMetadata(cid: cid)
        let stageManager = stageManagerEnabled

        let active = pruneGhosts(onScreen, axBacked: ax.axBacked, cid: cid)
        let activeIDs = Set(active.map(\.id))
        let marked = everything.map { w -> WindowInfo in
            var out = w
            out.isCrossSpace = !activeIDs.contains(w.id)
            return out
        }
        let annotatedAll = annotateAndPrune(marked, ax: ax, cid: cid, metadata: metadata, stageManager: stageManager)
        let cross = annotatedAll.filter { !activeIDs.contains($0.id) }
        let reps = spaceRepresentatives(from: annotatedAll, cid: cid, metadata: metadata)
        return FullSnapshot(activeSpace: active, crossSpace: cross, spaceRepresentatives: reps)
    }

    static func currentWindows(scope: HotkeyManager.Mode, frontmostPID: pid_t?) -> [WindowInfo] {
        let e = enumerate(scope: scope, frontmostPID: frontmostPID)
        return e.activeSpace + e.crossSpace
    }

    static func enumerate(scope: HotkeyManager.Mode, frontmostPID: pid_t?) -> Enumeration {
        let full = fullSnapshot()
        var active = full.activeSpace
        var cross = full.crossSpace
        if scope == .currentApp, let f = frontmostPID {
            active = active.filter { $0.pid == f }
            cross = cross.filter { $0.pid == f }
        }
        let showCross = (UserDefaults.standard.object(forKey: "switch.showCrossSpace") as? Bool) ?? true
        if !showCross {
            cross = cross.filter { !$0.isCrossSpace }
        }
        return Enumeration(activeSpace: active, crossSpace: cross)
    }

    private static var stageManagerEnabled: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
    }

    private static func appElement(for pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }

    // AX-backed and minimized window IDs for the given processes; an orderedOut leftover appears in neither.
    private static func axWindowState(for pids: Set<pid_t>) -> (axBacked: Set<CGWindowID>, minimized: Set<CGWindowID>) {
        var axBacked: Set<CGWindowID> = []
        var minimized: Set<CGWindowID> = []
        for pid in pids {
            let appAX = appElement(for: pid)
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &ref) == .success,
                  let axWindows = ref as? [AXUIElement] else { continue }
            for ax in axWindows {
                var id: CGWindowID = 0
                if _AXUIElementGetWindow(ax, &id) == .success, id != 0 {
                    axBacked.insert(id)
                    var minRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &minRef) == .success,
                       let isMin = minRef as? Bool, isMin {
                        minimized.insert(id)
                    }
                }
            }
        }
        return (axBacked, minimized)
    }

    // Drop orphaned on-screen entries: no live AX window and no Space. Real windows always have a Space.
    private static func pruneGhosts(_ windows: [WindowInfo], axBacked: Set<CGWindowID>, cid: CGSConnectionID) -> [WindowInfo] {
        guard !windows.isEmpty else { return windows }
        return windows.filter { w in
            if axBacked.contains(w.id) { return true }
            let arr = [NSNumber(value: w.id)] as CFArray
            let spaces = CGSCopySpacesForWindows(cid, 7, arr)?.takeRetainedValue() as? [Int] ?? []
            return !spaces.isEmpty
        }
    }

    private static func annotateAndPrune(
        _ candidates: [WindowInfo],
        ax: (axBacked: Set<CGWindowID>, minimized: Set<CGWindowID>),
        cid: CGSConnectionID,
        metadata: (labels: [Int: (label: String, isFullscreen: Bool)], order: [Int]),
        stageManager: Bool
    ) -> [WindowInfo] {
        return candidates.compactMap { w in
            var out = w
            if out.isHidden {
                out.isCrossSpace = false
                return out
            }
            if ax.minimized.contains(w.id) {
                out.isMinimized = true
                out.isCrossSpace = false
                return out
            }
            let arr = [NSNumber(value: w.id)] as CFArray
            let spaces = CGSCopySpacesForWindows(cid, 7, arr)?.takeRetainedValue() as? [Int] ?? []
            if spaces.isEmpty {
                // Empty Space list + no AX window = orderOut'd ghost, drop it.
                // Empty Space list + live AX window = a real window the window
                // server has ordered out (Stage Manager off-stage). With Stage
                // Manager off that signature is a closed Settings/Preferences
                // leftover, so it only survives while Stage Manager is on.
                guard ax.axBacked.contains(w.id), stageManager else { return nil }
                out.isCrossSpace = false
                return out
            }
            if let sid = spaces.first {
                let info = metadata.labels[sid]
                out.spaceID = sid
                out.spaceLabel = info?.label
                out.isFullscreenSpace = info?.isFullscreen ?? false
            }
            return out
        }
    }

    private static func spaceRepresentatives(
        from annotated: [WindowInfo],
        cid: CGSConnectionID,
        metadata: (labels: [Int: (label: String, isFullscreen: Bool)], order: [Int])
    ) -> [WindowInfo] {
        let active = Int(CGSGetActiveSpace(cid))
        let grouped = Dictionary(grouping: annotated) { $0.spaceID ?? -1 }
        return metadata.order.compactMap { sid in
            guard sid != -1, let windows = grouped[sid], !windows.isEmpty else { return nil }
            let sorted = WindowMRU.sorted(windows, frontmost: nil)
            guard let target = sorted.first else { return nil }
            let apps = Array(NSOrderedSet(array: sorted.map(\.appName)).compactMap { $0 as? String }).prefix(3)
            let suffix = sorted.count == 1 ? "1 window" : "\(sorted.count) windows"
            let detail = apps.isEmpty ? suffix : "\(suffix) · \(apps.joined(separator: ", "))"
            let info = metadata.labels[sid]
            return WindowInfo(
                id: target.id,
                pid: target.pid,
                appName: info?.label ?? "Desktop",
                title: detail,
                bounds: target.bounds,
                spaceID: sid,
                isCrossSpace: sid != active,
                isMinimized: false,
                isHidden: false,
                spaceLabel: sid == active ? "Current" : nil,
                isFullscreenSpace: info?.isFullscreen ?? false,
                isWindowless: false,
                bundleID: target.bundleID
            )
        }
    }

    /// Builds a `spaceID → "Desktop N" / "Fullscreen"` map by walking CGS's managed-display spaces in order.
    private static func spaceMetadata(cid: CGSConnectionID) -> (labels: [Int: (label: String, isFullscreen: Bool)], order: [Int]) {
        guard let displays = CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return ([:], []) }
        var labels: [Int: (label: String, isFullscreen: Bool)] = [:]
        var order: [Int] = []
        var desktop = 0
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                guard let id = space["id64"] as? Int else { continue }
                order.append(id)
                let type = space["type"] as? Int ?? 0
                if type == 0 {
                    desktop += 1
                    labels[id] = ("Desktop \(desktop)", false)
                } else {
                    labels[id] = ("Fullscreen", true)
                }
            }
        }
        return (labels, order)
    }

    private static func enumerate(option: CGWindowListOption) -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let blacklist = Set(UserDefaults.standard.stringArray(forKey: SwitchPreferences.blacklistKey) ?? [])
        var blockedPIDs: Set<pid_t> = []
        if !blacklist.isEmpty {
            for app in NSWorkspace.shared.runningApplications {
                if let bid = app.bundleIdentifier, blacklist.contains(bid) {
                    blockedPIDs.insert(app.processIdentifier)
                }
            }
        }
        var out: [WindowInfo] = []
        var seenIDs: Set<CGWindowID> = []
        for d in raw {
            let appName = d[kCGWindowOwnerName as String] as? String ?? ""
            guard let layer = d[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let alpha = d[kCGWindowAlpha as String] as? Double else { continue }
            guard let id = d[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let pid = d[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if skipApps.contains(appName) { continue }
            if isHelperProcess(appName) { continue }
            if blockedPIDs.contains(pid) { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            if app == nil || app?.activationPolicy != .regular { continue }
            if alpha <= 0 && app?.isHidden != true { continue }
            let title = d[kCGWindowName as String] as? String ?? ""
            let boundsDict = d[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            if bounds.width < 100 || bounds.height < 80 { continue }
            if title.isEmpty && (bounds.width < 400 || bounds.height < 300) { continue }
            // Dedupe by CGWindowID only — it's already unique per window.
            // The earlier (pid, title, bounds) dedupe was collapsing multiple
            // Chrome windows that shared the same active-tab title.
            if seenIDs.contains(id) { continue }
            seenIDs.insert(id)
            out.append(WindowInfo(
                id: id,
                pid: pid,
                appName: appName,
                title: title,
                bounds: bounds,
                isHidden: app?.isHidden == true,
                bundleID: app?.bundleIdentifier
            ))
        }
        return out
    }
}
