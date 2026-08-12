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

    // Ghost-confirmation state. Every access takes `ghostLock`; sweeps run on a
    // background queue and noteSwitchMovedWindow is called from the focus path.
    private static let ghostLock = NSLock()
    private static var ghostStrikes: [CGWindowID: (first: Date, count: Int)] = [:]
    private static var switchMovedWindows: [CGWindowID: Date] = [:]
    private static let switchMovedGrace: TimeInterval = 10

    /// Record a window Switch just pulled to the current Space via
    /// CGSMoveWindowsToManagedSpace so the current-space-claim prune skips it: a
    /// failed raise must not strand it as a self-inflicted ghost (v0.3.9 rescue path).
    static func noteSwitchMovedWindow(_ id: CGWindowID) {
        ghostLock.lock()
        switchMovedWindows[id] = Date()
        ghostLock.unlock()
    }

    // True once the current-space-claim ghost is confirmed: count ≥ 2 and ≥ 2.5s
    // since the first strike. Switch-moved wids don't accrue strikes for 10s (#115).
    private static func ghostStrikeConfirmed(_ id: CGWindowID) -> Bool {
        ghostLock.lock()
        defer { ghostLock.unlock() }
        if let moved = switchMovedWindows[id] {
            if Date().timeIntervalSince(moved) < switchMovedGrace { return false }
            switchMovedWindows.removeValue(forKey: id)
        }
        let now = Date()
        if var entry = ghostStrikes[id] {
            entry.count += 1
            ghostStrikes[id] = entry
            return entry.count >= 2 && now.timeIntervalSince(entry.first) >= 2.5
        }
        ghostStrikes[id] = (first: now, count: 1)
        return false
    }

    // The condition no longer holds for this wid → forget its strikes so a dropped
    // window reappears automatically. There is no permanent drop set.
    private static func clearGhostStrike(_ id: CGWindowID) {
        ghostLock.lock()
        ghostStrikes.removeValue(forKey: id)
        ghostLock.unlock()
    }

    // Forget ghost state for windows that are on-screen, AX-backed, or gone.
    private static func housekeepGhostState(onScreen: Set<CGWindowID>, enumerated: Set<CGWindowID>, axBacked: Set<CGWindowID>) {
        ghostLock.lock()
        defer { ghostLock.unlock() }
        for id in ghostStrikes.keys where onScreen.contains(id) || axBacked.contains(id) || !enumerated.contains(id) {
            ghostStrikes.removeValue(forKey: id)
        }
        for id in switchMovedWindows.keys where onScreen.contains(id) || !enumerated.contains(id) {
            switchMovedWindows.removeValue(forKey: id)
        }
    }

    static func fullSnapshot() -> FullSnapshot {
        let onScreen = enumerate(option: [.optionOnScreenOnly, .excludeDesktopElements])
        let everything = enumerate(option: [.optionAll, .excludeDesktopElements])
        let pids = Set(everything.map(\.pid)).union(onScreen.map(\.pid))
        let ax = axWindowState(for: pids)
        let cid = CGSMainConnectionID()
        let metadata = spaceMetadata(cid: cid)
        let stageManager = stageManagerEnabled
        // Without Screen Recording every CG title is empty, so emptiness is no ghost signal (#106).
        let titlesReliable = CGPreflightScreenCaptureAccess()

        let active = pruneGhosts(onScreen, axBacked: ax.axBacked, cid: cid)
        let activeIDs = Set(active.map(\.id))
        let marked = everything.map { w -> WindowInfo in
            var out = w
            out.isCrossSpace = !activeIDs.contains(w.id)
            return out
        }
        let annotatedAll = annotateAndPrune(marked, ax: ax, cid: cid, metadata: metadata, stageManager: stageManager, titlesReliable: titlesReliable)
        let onScreenIDs = Set(onScreen.map(\.id))
        housekeepGhostState(
            onScreen: onScreenIDs,
            enumerated: onScreenIDs.union(everything.map(\.id)),
            axBacked: ax.axBacked
        )
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
                    AXWindowCache.store(ax, for: id)
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
        metadata: (labels: [Int: (label: String, isFullscreen: Bool)], order: [Int], currentSpaces: Set<Int>),
        stageManager: Bool,
        titlesReliable: Bool
    ) -> [WindowInfo] {
        return candidates.compactMap { w in
            var out = w
            let arr = [NSNumber(value: w.id)] as CFArray
            let spaces = CGSCopySpacesForWindows(cid, 7, arr)?.takeRetainedValue() as? [Int] ?? []
            if out.isHidden || ax.minimized.contains(w.id) {
                // Hidden Electron apps keep shell windows with no AX backing; two strikes before dropping so one slow AX sweep doesn't eat real windows (#126).
                if !ax.axBacked.contains(w.id) {
                    if ghostStrikeConfirmed(w.id) { return nil }
                } else {
                    clearGhostStrike(w.id)
                }
                out.isMinimized = ax.minimized.contains(w.id)
                // A window with no Space claim counts as current, older macOS drops the assignment once a window is ordered out (#129).
                out.isCrossSpace = !spaces.isEmpty && !spaces.contains(where: { metadata.currentSpaces.contains($0) })
                if let sid = spaces.first {
                    let info = metadata.labels[sid]
                    out.spaceID = sid
                    out.spaceLabel = info?.label
                    out.isFullscreenSpace = info?.isFullscreen ?? false
                }
                return out
            }
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
            if !ax.axBacked.contains(w.id) {
                // Every Space it claims has been deleted → can't be a real window
                // (real windows always sit on a live Space). Stateless, self-heals.
                if !spaces.contains(where: { metadata.labels[$0] != nil }) {
                    clearGhostStrike(w.id)
                    return nil
                }
                // orderOut'd shell signatures, confirmed across two strikes ≥2.5s apart
                // so a real window caught mid Space-transition survives (transitions
                // settle in <1s; Current Space races ahead of CGWindowList and Chromium
                // exposes no AX in that gap): claims the current Space, or has an empty
                // CG title; real cross-Space windows always carry one (browser windows
                // have a page title), so an untitled shell on any live Space is a ghost.
                let currentClaim = spaces.contains(where: { metadata.currentSpaces.contains($0) })
                if out.isCrossSpace && (currentClaim || (titlesReliable && out.title.isEmpty)) {
                    if ghostStrikeConfirmed(w.id) { return nil }
                } else {
                    clearGhostStrike(w.id)
                }
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
        metadata: (labels: [Int: (label: String, isFullscreen: Bool)], order: [Int], currentSpaces: Set<Int>)
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
    private static func spaceMetadata(cid: CGSConnectionID) -> (labels: [Int: (label: String, isFullscreen: Bool)], order: [Int], currentSpaces: Set<Int>) {
        guard let displays = CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return ([:], [], []) }
        var labels: [Int: (label: String, isFullscreen: Bool)] = [:]
        var order: [Int] = []
        var currentSpaces: Set<Int> = []
        var desktop = 0
        for display in displays {
            if let current = display["Current Space"] as? [String: Any], let id = current["id64"] as? Int {
                currentSpaces.insert(id)
            }
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
        return (labels, order, currentSpaces)
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
        let titlesReliable = CGPreflightScreenCaptureAccess()
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
            if title.isEmpty && titlesReliable
                && (bounds.width < 400 || bounds.height < 300) { continue }
            // Dedupe by CGWindowID only; it's already unique per window.
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
