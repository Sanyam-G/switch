import AppKit
import ApplicationServices
import CoreGraphics

struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let bounds: CGRect
    var title: String
    var spaceID: Int?
    var isCrossSpace: Bool = false
    var isMinimized: Bool = false
    var isHidden: Bool = false
    var spaceLabel: String?
    var isFullscreenSpace: Bool = false
    var isWindowless: Bool = false
    var bundleID: String?

    func isPinned(in pinned: Set<String>) -> Bool {
        bundleID.map { pinned.contains($0) } ?? false
    }
}

enum WindowEnumerator {
    typealias SpaceMetadata = (labels: [Int: (label: String, isFullscreen: Bool)], order: [Int], currentSpaces: Set<Int>)
    private typealias AXState = (axBacked: Set<CGWindowID>, minimized: Set<CGWindowID>, titles: [CGWindowID: String], overlays: Set<CGWindowID>)

    private static let skipApps: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center",
        "Notification Center", "Spotlight", "WallpaperAgent", "Switch",
        "loginwindow", "talagent", "TextInputMenuAgent", "TextInputSwitcher",
        "universalControl", "ControlStrip", "ScreenshotCapture", "WindowManager"
    ]

    private static let helperSuffixes: [String] = [
        "Helper", " Helper (GPU)", " Helper (Plugin)",
        "Agent",
        "Service",
        "Renderer", "(Renderer)",
        "WebContent", "Networking",
        "Extension"
    ]

    private static let chromiumBundles: [String] = [
        "com.google.Chrome", "org.chromium.Chromium", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi"
    ]

    // Steam draws its windows from its CEF browser process, an LSUIElement helper (#206).
    private static let hostedHelpers: [String: String] = [
        "com.valvesoftware.steam.helper": "com.valvesoftware.steam"
    ]

    private static func isHelperProcess(_ name: String) -> Bool {
        helperSuffixes.contains { name.hasSuffix($0) }
    }

    // Read once per sweep, not once per CGWindowList pass.
    private struct Sweep {
        // Without Screen Recording every CG title is empty, so emptiness is no ghost signal (#106).
        let titlesReliable = CGPreflightScreenCaptureAccess()
        let stageManager = UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
        let includedAppNames = UserDefaults.standard.stringArray(forKey: SwitchPreferences.includedAppNamesKey) ?? []
        let blockedPIDs: Set<pid_t> = {
            let blacklist = Set(UserDefaults.standard.stringArray(forKey: SwitchPreferences.blacklistKey) ?? [])
            guard !blacklist.isEmpty else { return [] }
            return Set(NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier.map(blacklist.contains) == true }
                .map(\.processIdentifier))
        }()
    }

    struct FullSnapshot {
        let activeSpace: [WindowInfo]
        let crossSpace: [WindowInfo]
        let spaceRepresentatives: [WindowInfo]

        var allWindows: [WindowInfo] { activeSpace + crossSpace }
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
        let sweep = Sweep()
        let rawOnScreen = enumerate(option: [.optionOnScreenOnly, .excludeDesktopElements], sweep)
        let rawEverything = enumerate(option: [.optionAll, .excludeDesktopElements], sweep)
        let pids = Set(rawEverything.map(\.pid)).union(rawOnScreen.map(\.pid))
        let needsTitle = Set((rawOnScreen + rawEverything).filter(\.title.isEmpty).map(\.id))
        let ax = axWindowState(for: pids, needingTitles: needsTitle)
        let cid = CGSMainConnectionID()
        let metadata = spaceMetadata(cid: cid)
        let titlesReliable = sweep.titlesReliable
        // An untitled on-screen window AX doesn't list, from an app whose other windows AX does list,
        // is an overlay: Notes' find highlight (#152), in-process border windows (#154).
        let axPIDs = Set(rawEverything.filter { ax.axBacked.contains($0.id) }.map(\.pid))
        let untitled: Set<CGWindowID> = titlesReliable ? Set(rawOnScreen.filter {
            $0.title.isEmpty && !ax.axBacked.contains($0.id) && axPIDs.contains($0.pid)
        }.map(\.id)) : []
        // Chromium's find bar is a titled borderless child window, AX subrole AXUnknown (#186).
        let overlays = untitled.union(ax.overlays).union(rawEverything.filter { w in
            chromiumBundles.contains(where: { w.bundleID?.hasPrefix($0) == true })
                && AXWindowCache.element(for: w.id).flatMap { AXHelpers.attribute(kAXSubroleAttribute, of: $0) as? String } == kAXUnknownSubrole
        }.map(\.id))
        let onScreen = rawOnScreen.filter { !overlays.contains($0.id) }
        let everything = rawEverything.filter { !overlays.contains($0.id) }

        let active = pruneGhosts(onScreen, axBacked: ax.axBacked, cid: cid)
        let activeIDs = Set(active.map(\.id))
        let marked = everything.map { w -> WindowInfo in
            var out = w
            out.isCrossSpace = !activeIDs.contains(w.id)
            return out
        }
        let annotatedAll = annotateAndPrune(marked, ax: ax, axPIDs: axPIDs, cid: cid, metadata: metadata, stageManager: sweep.stageManager, titlesReliable: titlesReliable)
        // After annotateAndPrune on purpose: ghost detection keys on the CG title (#111).
        let titledActive = backfillTitles(active, from: ax.titles)
        let fullscreenDupes = fullscreenDuplicates(annotatedAll, axBacked: ax.axBacked)
        let titledAll = backfillTitles(annotatedAll, from: ax.titles).filter { !fullscreenDupes.contains($0.id) }
        let onScreenIDs = Set(onScreen.map(\.id))
        housekeepGhostState(
            onScreen: onScreenIDs,
            enumerated: onScreenIDs.union(everything.map(\.id)),
            axBacked: ax.axBacked
        )
        let cross = titledAll.filter { !activeIDs.contains($0.id) }
        let reps = spaceRepresentatives(from: titledAll, metadata: metadata)
        return FullSnapshot(activeSpace: titledActive.filter { !fullscreenDupes.contains($0.id) }, crossSpace: cross, spaceRepresentatives: reps)
    }

    // Apps set their badge on NSDockTile, and only the Dock's own AX tree exposes it (#92).
    static func dockBadges() -> [String: String] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let list = AXHelpers.children(of: AXHelpers.appElement(for: dock.processIdentifier)).first { AXHelpers.attribute(kAXRoleAttribute, of: $0) as? String == kAXListRole }
        var badges: [String: String] = [:]
        for item in list.map(AXHelpers.children) ?? [] {
            guard let badge = AXHelpers.attribute("AXStatusLabel", of: item) as? String, !badge.isEmpty,
                  let url = AXHelpers.attribute(kAXURLAttribute, of: item) as? URL,
                  let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            badges[bundleID] = badge
        }
        return badges
    }

    // AX-backed windows, minimized window IDs, and AX titles for the given processes; an orderedOut leftover appears in neither.
    private static func axWindowState(for pids: Set<pid_t>, needingTitles needsTitle: Set<CGWindowID>) -> AXState {
        var axBacked: Set<CGWindowID> = []
        var minimized: Set<CGWindowID> = []
        var titles: [CGWindowID: String] = [:]
        var overlays: Set<CGWindowID> = []
        for pid in pids {
            for ax in AXHelpers.windowList(of: AXHelpers.appElement(for: pid)) {
                guard let id = AXHelpers.windowID(of: ax) else { continue }
                axBacked.insert(id)
                AXWindowCache.store(ax, for: id)
                if needsTitle.contains(id) {
                    let title = AXHelpers.title(of: ax)
                    if !title.isEmpty {
                        titles[id] = title
                    } else if AXHelpers.attribute(kAXSubroleAttribute, of: ax) as? String == kAXSystemDialogSubrole {
                        // An untitled companion panel AX does list, e.g. Rex's second terminal entry (#204).
                        overlays.insert(id)
                    }
                }
                if AXHelpers.attribute(kAXMinimizedAttribute, of: ax) as? Bool == true {
                    minimized.insert(id)
                }
            }
        }
        return (axBacked, minimized, titles, overlays)
    }

    // A destroyed window's element answers invalidUIElement; a suspended off-stage one doesn't.
    private static func isLiveElement(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) != .invalidUIElement
    }

    private static func backfillTitles(_ windows: [WindowInfo], from titles: [CGWindowID: String]) -> [WindowInfo] {
        windows.map { w in
            guard w.title.isEmpty, let title = titles[w.id] else { return w }
            var out = w
            out.title = title
            return out
        }
    }

    // A fullscreen game can stack a second full-width window of its own on its Space,
    // listed as a second "Fullscreen" row (#207). Keep the AX-backed, titled, larger one;
    // split-view halves and auxiliary panels differ in width and stay.
    private static func fullscreenDuplicates(_ windows: [WindowInfo], axBacked: Set<CGWindowID>) -> Set<CGWindowID> {
        let groups = Dictionary(grouping: windows.filter(\.isFullscreenSpace)) { "\($0.pid):\($0.spaceID ?? -1)" }
        var drop: Set<CGWindowID> = []
        for group in groups.values where group.count > 1 {
            let rank = { (w: WindowInfo) in (axBacked.contains(w.id) ? 1 : 0, w.title.isEmpty ? 0 : 1, w.bounds.width * w.bounds.height) }
            var kept: [CGRect] = []
            for w in group.sorted(by: { rank($0) > rank($1) }) {
                let b = w.bounds
                let stacked = kept.contains { k in
                    abs(k.width - b.width) <= 1
                        && (k.insetBy(dx: -1, dy: -1).contains(b) || b.insetBy(dx: -1, dy: -1).contains(k))
                }
                if stacked { drop.insert(w.id) } else { kept.append(b) }
            }
        }
        return drop
    }

    private static func spaces(of id: CGWindowID, cid: CGSConnectionID) -> [Int] {
        CGSCopySpacesForWindows(cid, 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [Int] ?? []
    }

    private static func annotateSpace(_ w: inout WindowInfo, spaces: [Int], metadata: SpaceMetadata) {
        guard let sid = spaces.first else { return }
        let info = metadata.labels[sid]
        w.spaceID = sid
        w.spaceLabel = info?.label
        w.isFullscreenSpace = info?.isFullscreen ?? false
    }

    // Drop orphaned on-screen entries: no live AX window and no Space. Real windows always have a Space.
    private static func pruneGhosts(_ windows: [WindowInfo], axBacked: Set<CGWindowID>, cid: CGSConnectionID) -> [WindowInfo] {
        windows.filter { w in
            axBacked.contains(w.id) || !spaces(of: w.id, cid: cid).isEmpty
        }
    }

    private static func annotateAndPrune(
        _ candidates: [WindowInfo],
        ax: AXState,
        axPIDs: Set<pid_t>,
        cid: CGSConnectionID,
        metadata: SpaceMetadata,
        stageManager: Bool,
        titlesReliable: Bool
    ) -> [WindowInfo] {
        return candidates.compactMap { w in
            var out = w
            let spaces = spaces(of: w.id, cid: cid)
            if out.isHidden || ax.minimized.contains(w.id) {
                out.isMinimized = ax.minimized.contains(w.id)
                // A window with no Space claim counts as current, older macOS drops the assignment once a window is ordered out (#129).
                out.isCrossSpace = !spaces.isEmpty && !spaces.contains(where: { metadata.currentSpaces.contains($0) })
                // A window AX ever backed is real; the cache outlives per-sweep AX gaps (timeouts, Chromium's off-Space omissions), so a never-backed CG entry is an Electron shell (#126).
                let everBacked = ax.axBacked.contains(w.id) || AXWindowCache.element(for: w.id) != nil
                // Same real-window signature as the cross-Space prune below, for windows hidden before Switch ever saw them.
                let offSpaceReal = out.isCrossSpace && (!titlesReliable || !w.title.isEmpty)
                guard everBacked || offSpaceReal else { return nil }
                annotateSpace(&out, spaces: spaces, metadata: metadata)
                return out
            }
            if spaces.isEmpty {
                // Empty Space list + no AX window = orderOut'd ghost, drop it.
                // Empty Space list + AX window = a real window the window server
                // has ordered out (Stage Manager off-stage). Stage Manager suspends
                // AX for off-stage apps, so the cache stands in for the live list (#99),
                // but only while the app lists no windows: one that lists others closed this one.
                // With Stage Manager off that signature is a closed Settings/Preferences
                // leftover, so it only survives while Stage Manager is on.
                let everBacked = ax.axBacked.contains(w.id)
                    || (!axPIDs.contains(w.pid) && AXWindowCache.element(for: w.id).map(isLiveElement) == true)
                guard everBacked, stageManager else { return nil }
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
            annotateSpace(&out, spaces: spaces, metadata: metadata)
            return out
        }
    }

    // isCrossSpace and spaceLabel are set by SwitchModel against the live active Space.
    private static func spaceRepresentatives(from annotated: [WindowInfo], metadata: SpaceMetadata) -> [WindowInfo] {
        let grouped = Dictionary(grouping: annotated) { $0.spaceID ?? -1 }
        return metadata.order.compactMap { sid in
            guard sid != -1, let windows = grouped[sid], !windows.isEmpty else { return nil }
            let sorted = WindowMRU.sorted(windows, frontmost: nil)
            guard let target = sorted.first else { return nil }
            var seen = Set<String>()
            let apps = sorted.map(\.appName).filter { seen.insert($0).inserted }.prefix(3)
            let suffix = sorted.count == 1 ? "1 window" : "\(sorted.count) windows"
            let detail = apps.isEmpty ? suffix : "\(suffix) · \(apps.joined(separator: ", "))"
            let info = metadata.labels[sid]
            return WindowInfo(
                id: target.id,
                pid: target.pid,
                appName: info?.label ?? "Desktop",
                bounds: target.bounds,
                title: detail,
                spaceID: sid,
                isFullscreenSpace: info?.isFullscreen ?? false,
                bundleID: target.bundleID
            )
        }
    }

    /// Builds a `spaceID → "Desktop N" / "Fullscreen"` map by walking CGS's managed-display spaces in order.
    static func spaceMetadata(cid: CGSConnectionID) -> SpaceMetadata {
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

    private static func enumerate(option: CGWindowListOption, _ sweep: Sweep) -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] else {
            return []
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
            let app = NSRunningApplication(processIdentifier: pid)
            let host = app?.bundleIdentifier.flatMap { hostedHelpers[$0] }
                .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            // Menu-bar and helper processes stay out unless the user lists them (#63, #196).
            if host == nil && (isHelperProcess(appName) || app?.activationPolicy != .regular)
                && !SwitchPreferences.isIncluded(appName, in: sweep.includedAppNames) { continue }
            let owner = host ?? app
            if sweep.blockedPIDs.contains(owner?.processIdentifier ?? pid) { continue }
            let title = d[kCGWindowName as String] as? String ?? ""
            let bounds = (d[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
            // Stage Manager reports tiny bounds for real off-stage windows, so titled or AX-seen ones skip the size check (#99).
            if (bounds.width < 100 || bounds.height < 80)
                && !(sweep.stageManager && (!title.isEmpty || AXWindowCache.element(for: id) != nil)) { continue }
            if title.isEmpty && sweep.titlesReliable
                && (bounds.width < 400 || bounds.height < 300) { continue }
            if alpha <= 0 && app?.isHidden != true { continue }
            guard seenIDs.insert(id).inserted else { continue }
            out.append(WindowInfo(
                id: id,
                pid: pid,
                appName: host?.localizedName ?? appName,
                bounds: bounds,
                title: title,
                isHidden: app?.isHidden == true,
                bundleID: owner?.bundleIdentifier
            ))
        }
        return out
    }
}
