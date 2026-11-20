import AppKit
import SwiftUI

@MainActor
final class SwitchModel: ObservableObject {
    @Published var windows: [WindowInfo] = [] { didSet { refilter() } }
    @Published var selected: Int = 0
    @Published var mode: HotkeyManager.Mode = .allWindows
    @Published var visible: Bool = false
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    /// Bundle ID to the badge on that app's Dock icon, read once per arm (#92).
    @Published var dockBadges: [String: String] = [:]
    @Published var filterText: String = "" { didSet { refilter() } }
    /// `windows` narrowed and ranked by `filterText`. Stored: the view reads it several times per pass.
    private(set) var filteredWindows: [WindowInfo] = []
    @Published var panelSize = CGSize(width: 880, height: 560)
    /// Effective sticky for this invocation: global pref or a dedicated sticky binding (#131).
    @Published var stickySession = false
    private var currentSpaceOnly = false
    /// Picker display in CGWindow coordinates, captured at arm. Nil when the display filter is off.
    private var armDisplayFrame: CGRect?
    private var armFrontWindowID: CGWindowID?
    private var armReverse = false

    /// Set by AppDelegate so the view can request a commit + window dismiss from a click or a direct pick.
    var commitAndDismiss: (() -> Void)?
    /// Set by AppDelegate so the model can request a dismiss after a close empties the list, or after hiding an app.
    var cancelAndDismiss: (() -> Void)?

    private var refreshTimer: Timer?
    private var prewarmTimer: Timer?
    private var armGeneration = 0
    private var armFrontmostPID: pid_t?
    private var armFrontmostBundleID: String?
    private var armSelfHadKeyWindow = false
    private var quitPIDs: Set<pid_t> = []
    private var thumbnailTask: Task<Void, Never>?
    var pointerWindowID: CGWindowID?

    #if DEBUG
    init() {
        for (q, t) in [("memo", "メモ"), ("weixin", "微信"), ("cafe", "Café"), ("sa", "Safari")] {
            assert(Self.fuzzyScore(pattern: Self.norm(q), target: Self.norm(t)) != nil, "\(q) should match \(t)")
        }
    }
    #endif

    private func refilter() {
        let q = Self.norm(filterText)
        guard !q.isEmpty else { filteredWindows = windows; return }
        let scored: [(WindowInfo, Bool, Int)] = windows.compactMap { w in
            if let a = Self.fuzzyScore(pattern: q, target: Self.norm(w.appName)) { return (w, true, a) }
            return Self.fuzzyScore(pattern: q, target: Self.norm(w.title)).map { (w, false, $0) }
        }
        // App-name matches before title-only ones, each by its own score; titles change, app names are muscle memory (#205).
        filteredWindows = scored.sorted { $0.1 != $1.1 ? $0.1 : $0.2 > $1.2 }.map { $0.0 }
    }

    /// The filter arrives as layout characters, so no IME composes it (#89). Romanize both sides instead:
    /// "memo" finds メモ, "weixin" finds 微信, "cafe" finds Café. Kanji romanize with Mandarin readings.
    private static func norm(_ s: String) -> String {
        (s.applyingTransform(.toLatin, reverse: false) ?? s)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Shared with the panel sizer so it reserves the header only when the view draws one.
    var showsHeader: Bool {
        let prefs = SwitchPreferences.shared
        return mode == .spaces || !prefs.verticalList || prefs.verticalShowHeader || !filterText.isEmpty
    }

    private var selectedWindow: WindowInfo? {
        let list = filteredWindows
        return list.indices.contains(selected) ? list[selected] : nil
    }

    private static func fuzzyScore(pattern: String, target: String) -> Int? {
        let pat = Array(pattern)
        let tgt = Array(target)
        var score = 0
        var patIdx = 0
        var lastMatch = -1
        for (i, c) in tgt.enumerated() {
            guard patIdx < pat.count else { break }
            if c == pat[patIdx] {
                score += 1
                if lastMatch == i - 1 { score += 5 }
                if i == 0 || !tgt[i - 1].isLetter { score += 3 }
                lastMatch = i
                patIdx += 1
            }
        }
        return patIdx == pat.count ? score : nil
    }

    func arm(_ style: HotkeyManager.ArmStyle) {
        armGeneration &+= 1
        let gen = armGeneration
        self.mode = style.mode
        stickySession = style.sticky
        currentSpaceOnly = style.currentSpaceOnly
        armDisplayFrame = (style.currentDisplayOnly || SwitchPreferences.shared.currentDisplayOnly)
            ? SwitcherWindow.pickerScreen().map(Self.cgFrame) : nil
        armReverse = style.reverse
        quitPIDs.removeAll()
        filterText = ""
        pointerWindowID = nil
        let frontApp = NSWorkspace.shared.frontmostApplication
        armFrontmostPID = frontApp?.processIdentifier
        armFrontmostBundleID = frontApp?.bundleIdentifier
        armSelfHadKeyWindow = NSApp.keyWindow != nil
        if let snap = WindowStore.shared.current {
            apply(snapshot: snap, initial: true)
        } else {
            windows = []
            selected = 0
        }
        visible = true
        WindowStore.shared.refresh { [weak self] snap in
            guard let self, self.armGeneration == gen, self.visible else { return }
            self.apply(snapshot: snap, initial: self.windows.isEmpty)
        }
        startRefreshTimer()
        guard SwitchPreferences.shared.showDockBadges else { dockBadges = [:]; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let badges = WindowEnumerator.dockBadges()
            Task { @MainActor [weak self] in
                guard let self, self.armGeneration == gen, self.dockBadges != badges else { return }
                self.dockBadges = badges
            }
        }
    }

    private func apply(snapshot: WindowStore.Snapshot, initial: Bool) {
        let previousSelectedID = initial ? nil : selectedWindow?.id

        let final: [WindowInfo]
        if mode == .spaces {
            let active = Int(CGSGetActiveSpace(CGSMainConnectionID()))
            final = snapshot.windows.spaceRepresentatives.map { rep in
                var out = rep
                out.isCrossSpace = out.spaceID != active
                return out
            }
        } else {
            final = buildWindowList(from: snapshot.windows)
        }
        let changed = final != windows
        if changed { windows = final }

        if initial {
            // The front app's newest window, listed or not: one opened since the last sweep is the real front.
            // Other apps' stamps don't count: an accessory panel (Raycast) or a background window isn't where the user is.
            let front = armFrontmostPID
            armFrontWindowID = WindowMRU.mostRecentID.flatMap { Self.ownerPID(of: $0) == front ? $0 : nil }
                ?? front.flatMap { p in WindowMRU.mostRecent(in: snapshot.windows.allWindows.filter { $0.pid == p }) }?.id
                // Unstamped front-app windows, by bundle too for Steam's helper (#206); a windowless front app leaves it nil.
                ?? snapshot.windows.activeSpace.first { front == nil || $0.pid == front || ($0.bundleID != nil && $0.bundleID == armFrontmostBundleID) }?.id
            if mode == .spaces {
                let reps = filteredWindows
                if let current = reps.firstIndex(where: { !$0.isCrossSpace }), reps.count > 1 {
                    selected = (current + 1) % reps.count
                } else {
                    selected = 0
                }
            } else {
                // Own windows aren't listed, so with Switch frontmost the most recent listed window is already the previous one.
                // Only treat Switch as frontmost when it genuinely owns a visible key window (Settings/About/
                // onboarding); the picker panel can't become key, so keyWindow != nil rules out the stale
                // "still frontmost after closing a window" state behind #90.
                let list = filteredWindows
                selected = (stickySession || selfFront) ? mruIndex(in: list, skipping: nil) ?? 0
                    : armReverse ? max(list.count - 1, 0)
                    : mruIndex(in: list, skipping: armFrontWindowID) ?? 0
            }
        } else if changed {
            let list = filteredWindows
            if let previousSelectedID, let idx = list.firstIndex(where: { $0.id == previousSelectedID }) {
                selected = idx
            } else if selected >= list.count {
                selected = max(list.count - 1, 0)
            }
        }

        thumbnailTask?.cancel()
        let thumbTargets = final.filter { !$0.isWindowless }
        let gen = armGeneration
        // No purge here: a current-app or Spaces list would drop every other window's thumbnail; prewarm purges.
        thumbnailTask = Task {
            await fetchThumbnails(for: thumbTargets, force: false)
            guard !initial, armGeneration == gen, visible else { return }
            await fetchThumbnails(for: thumbTargets, force: true, batch: true)
        }
    }

    // FocusTracker keeps WindowMRU current across all focus events (Switch-driven
    // and external clicks). MRU-sort active-Space too so that when an Arc window
    // is raised, all OTHER Arc windows don't cluster ahead of the previously-focused
    // window from a different app. CGWindowList z-order groups windows by app
    // when any one is raised, which is the wrong signal for a window switcher.
    private func buildWindowList(from full: WindowEnumerator.FullSnapshot) -> [WindowInfo] {
        var active = full.activeSpace
        var cross = full.crossSpace
        func drop(where rejected: (WindowInfo) -> Bool) {
            active.removeAll(where: rejected)
            cross.removeAll(where: rejected)
        }
        drop { quitPIDs.contains($0.pid) }
        if SwitchPreferences.shared.hideMinimizedWindows {
            drop { $0.isMinimized || $0.isHidden }
        }
        let exclusions = SwitchPreferences.shared.titleExclusions.map { $0.lowercased() }
        if !exclusions.isEmpty {
            // Untitled windows match the app name the row shows: off-Space windows AX doesn't list (#210).
            // Titled windows match the title only, so existing entries never hide a whole app.
            drop { w in
                let t = w.title.lowercased(), a = w.appName.lowercased()
                return exclusions.contains { t.isEmpty ? a.contains($0) : t.contains($0) }
            }
        }
        if mode == .currentApp, let f = armFrontmostPID {
            // By bundle too: Steam's windows belong to its helper's pid (#206).
            drop { $0.pid != f && ($0.bundleID == nil || $0.bundleID != armFrontmostBundleID) }
        }
        if !SwitchPreferences.shared.showCrossSpace || currentSpaceOnly {
            cross = cross.filter { !$0.isCrossSpace }
        }
        if let display = armDisplayFrame {
            drop { !$0.bounds.intersects(display) }
        }
        let activeFront = WindowMRU.mostRecent(in: active) ?? active.first
        // Right after a cross-Space switch the cached snapshot still lists the
        // focused window as cross-Space; pin the frontmost app's MRU window from
        // either list so rows don't reshuffle under the selection when the fresh
        // sweep lands.
        let appFront = armFrontmostPID.flatMap { p in WindowMRU.mostRecent(in: (active + cross).filter { $0.pid == p }) }
        let ws: [WindowInfo]
        if SwitchPreferences.shared.staticOrder {
            let order = SwitchPreferences.shared.appOrder
            let rank: (String) -> Int = { order.firstIndex(of: $0) ?? Int.max }
            let stable: (WindowInfo, WindowInfo) -> Bool = {
                let ra = rank($0.appName), rb = rank($1.appName)
                if ra != rb { return ra < rb }
                if $0.appName.lowercased() != $1.appName.lowercased() {
                    return $0.appName.lowercased() < $1.appName.lowercased()
                }
                return $0.id < $1.id
            }
            ws = active.sorted(by: stable) + cross.sorted(by: stable)
        } else if SwitchPreferences.shared.mruMixSpaces {
            ws = WindowMRU.sorted(active + cross, frontmost: appFront ?? activeFront)
        } else if var front = appFront, front.isCrossSpace, let i = cross.firstIndex(of: front),
                  WindowEnumerator.isOnCurrentSpace(front.id) {
            // Same stale snapshot, unmixed: the focused window leads the current Space's rows.
            // Live check: a frontmost app whose only window really is elsewhere stays cross-Space.
            cross.remove(at: i)
            front.isCrossSpace = false
            ws = WindowMRU.sorted(active, frontmost: front) + WindowMRU.sorted(cross, frontmost: nil)
        } else {
            ws = WindowMRU.sorted(active, frontmost: activeFront) + WindowMRU.sorted(cross, frontmost: nil)
        }
        var final = ws
        if SwitchPreferences.shared.includeWindowlessApps && mode == .allWindows {
            let switchablePIDs = full.allPIDs
            // Steam's windows are listed under its helper's pid (#206). Only such hosted
            // bundles count, so a second, windowless instance of an app still shows.
            let switchableBundles = Set(full.allWindows
                .filter { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier != $0.bundleID }
                .compactMap(\.bundleID))
            let ownBundle = Bundle.main.bundleIdentifier
            let blacklist = SwitchPreferences.shared.blacklist
            let included = SwitchPreferences.shared.includedAppNames
            let extras = NSWorkspace.shared.runningApplications
                .filter {
                    ($0.activationPolicy == .regular || SwitchPreferences.isIncluded($0.localizedName ?? "", in: included))
                        && !switchablePIDs.contains($0.processIdentifier)
                        && $0.bundleIdentifier.map(switchableBundles.contains) != true
                        && $0.bundleIdentifier != ownBundle
                        && $0.bundleIdentifier.map(blacklist.contains) != true
                }
                .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
                .map { app in
                    WindowInfo(
                        id: CGWindowID(0xF0000000) | CGWindowID(UInt32(bitPattern: Int32(app.processIdentifier))),
                        pid: app.processIdentifier,
                        appName: app.localizedName ?? "",
                        bounds: .zero,
                        title: "",
                        isWindowless: true,
                        bundleID: app.bundleIdentifier
                    )
                }
            final += extras
        }
        let pinned = SwitchPreferences.shared.pinnedBundleIDs
        if !pinned.isEmpty {
            final.sort { $0.isPinned(in: pinned) && !$1.isPinned(in: pinned) }
        }
        return final
    }

    func closeSelected() { selectedWindow.map(close) }

    // Only this window, never a sibling. If no AX element resolves (cross-Space
    // Chromium, a windowless row), do nothing and keep the row.
    func close(_ target: WindowInfo) {
        guard mode != .spaces, AXHelpers.press(kAXCloseButtonAttribute, of: target) else { return }
        removeFromPicker { $0.id == target.id }
    }

    func closeWindow(withWindowID id: CGWindowID) {
        windows.first { $0.id == id }.map(close)
    }

    private func removeFromPicker(_ shouldRemove: (WindowInfo) -> Bool) {
        let selectedID = selectedWindow?.id
        windows.removeAll(where: shouldRemove)
        let liveIDs = Set(windows.map { $0.id })
        thumbnails = thumbnails.filter { liveIDs.contains($0.key) }
        let remaining = filteredWindows
        if remaining.isEmpty {
            cancelAndDismiss?()
            return
        }
        // Click only: closing another tile from under the pointer must not slide the selection onto its neighbour.
        if SwitchPreferences.shared.clickOnly, let idx = remaining.firstIndex(where: { $0.id == selectedID }) {
            selected = idx
        } else if selected >= remaining.count {
            selected = remaining.count - 1
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard SwitchPreferences.shared.showThumbnails else { return }
                let ws = self.windows.filter { !$0.isWindowless }
                guard !ws.isEmpty, self.visible else { return }
                await self.fetchThumbnails(for: ws, force: self.mode != .spaces, batch: true)
            }
        }
    }

    func startPrewarm() {
        prewarmTimer?.invalidate()
        prewarmTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.visible { return } // arm-driven refresh handles the visible case
                self.prewarmCache()
            }
        }
    }

    private func prewarmCache() {
        let started = Date()
        WindowStore.shared.refresh { snap in
            let ws = snap.windows.allWindows
            let liveIDs = Set(ws.map { $0.id })
            // By the live CG list, not the snapshot: a window one sweep skips keeps its MRU place.
            Task.detached(priority: .utility) {
                WindowMRU.purge(keeping: AXWindowCache.purgeDead(), since: started)
            }
            guard SwitchPreferences.shared.showThumbnails else { return }
            Task {
                await WindowSnapshotter.shared.purge(keeping: liveIDs)
                await withTaskGroup(of: Void.self) { group in
                    for w in ws {
                        group.addTask {
                            _ = await WindowSnapshotter.shared.snapshot(for: w.id, force: false)
                        }
                    }
                }
            }
        }
    }

    /// Where Shift's step moved the selection from and to, so a chord like ⇧⌘W can take it back (#199).
    /// Window ids, not indices, so a list change in between (a removed window) can't restore a stale slot.
    private var shiftStep: (from: WindowInfo.ID, to: WindowInfo.ID)?

    func shiftStepBack() {
        let list = filteredWindows
        guard list.indices.contains(selected) else { return advance(reverse: true) }
        let from = list[selected].id
        advance(reverse: true)
        shiftStep = (from, list[selected].id)
    }

    /// Only if nothing (hover, arrows) moved the selection since, or the chord would hit a neighbor.
    func undoShiftStep() {
        defer { shiftStep = nil }
        let list = filteredWindows
        guard let step = shiftStep, list.indices.contains(selected), list[selected].id == step.to,
              let from = list.firstIndex(where: { $0.id == step.from }) else { return }
        selected = from
    }

    /// Taps wrap around; a held key (clamp) stops at the first and last window like native ⌘Tab (#200).
    func advance(reverse: Bool, clamp: Bool = false) {
        let list = filteredWindows
        guard !list.isEmpty else { return }
        let n = list.count
        if clamp {
            selected = reverse ? max(selected - 1, 0) : min(selected + 1, n - 1)
        } else {
            selected = reverse ? (selected - 1 + n) % n : (selected + 1) % n
        }
    }

    func navigate(direction: HotkeyManager.Direction) {
        let list = filteredWindows
        guard !list.isEmpty else { return }
        let n = list.count
        let cols = (SwitchPreferences.shared.verticalList || mode == .spaces) ? 1
            : PickerLayout.gridColumns(configured: SwitchPreferences.shared.gridColumns, count: windows.count)
        switch direction {
        case .left:  selected = (selected - 1 + n) % n
        case .right: selected = (selected + 1) % n
        // A list wraps; a grid stays in the column and stops at the edge, like Finder's icon view.
        case .up:    if cols == 1 { selected = (selected - 1 + n) % n } else if selected >= cols { selected -= cols }
        case .down:  if cols == 1 { selected = (selected + 1) % n } else if selected + cols < n { selected += cols }
        }
    }

    func pickIndex(_ index: Int) {
        guard filteredWindows.indices.contains(index) else { return }
        selected = index
        commitAndDismiss?()
    }

    func selectIndex(_ index: Int) {
        guard filteredWindows.indices.contains(index) else { return }
        selected = index
    }

    func closeSelectedApp() {
        guard mode != .spaces, let target = selectedWindow else { return }
        AppCloser.close(target)
        quitPIDs.insert(target.pid)
        removeFromPicker { $0.pid == target.pid }
    }


    func hideSelected() {
        guard mode != .spaces, let target = selectedWindow else { return }
        if let app = NSRunningApplication(processIdentifier: target.pid) {
            app.hide()
        }
        cancelAndDismiss?()
    }

    func appendFilter(_ char: Character) {
        filterText.append(char)
        selected = 0
    }

    func backspaceFilter() {
        guard !filterText.isEmpty else { return }
        filterText.removeLast()
        selected = 0
    }

    private var selfFront: Bool {
        armFrontmostPID == ProcessInfo.processInfo.processIdentifier && armSelfHadKeyWindow
    }

    /// The most recently used listed window other than `skip`, by id: pinned apps and static order
    /// mean list position says nothing about recency. Unless Spaces are mixed, the current Space wins, like the list.
    private func mruIndex(in list: [WindowInfo], skipping skip: CGWindowID?) -> Int? {
        let order = WindowMRU.sorted(list, frontmost: nil).filter { $0.id != skip }
        // Hidden and minimized current-Space windows list after the visible ones, so they lose here too.
        let target = SwitchPreferences.shared.mruMixSpaces ? order.first
            : order.first { !$0.isCrossSpace && !$0.isHidden && !$0.isMinimized } ?? order.first { !$0.isCrossSpace } ?? order.first
        return target.flatMap { t in list.firstIndex { $0.id == t.id } }
    }

    private static func ownerPID(of id: CGWindowID) -> pid_t? {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
        return info?.first?[kCGWindowOwnerPID as String] as? pid_t
    }

    // kCGWindowBounds has its origin at the top-left of the primary display; NSScreen at the bottom-left.
    private static func cgFrame(_ screen: NSScreen) -> CGRect {
        let f = screen.frame
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? f.maxY
        return CGRect(x: f.minX, y: primaryMaxY - f.maxY, width: f.width, height: f.height)
    }

    func commit(stickyQuickTap: Bool = false) {
        let list = filteredWindows
        // Sticky preselects the current window, so a quick tap flips to the previous one instead (#96).
        if stickyQuickTap, mode != .spaces, !selfFront, let front = armFrontWindowID,
           selectedWindow?.id == front, let previous = mruIndex(in: list, skipping: front) {
            selected = previous
        }
        if list.indices.contains(selected) {
            WindowFocuser.focus(list[selected], bringHere: mode != .spaces)
            // Warm the cache once the Space transition settles so an immediate
            // re-invoke doesn't arm from a pre-switch snapshot (3s prewarm gap).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                WindowStore.shared.refresh()
            }
        }
        cancel()
    }

    func cancel() {
        visible = false
        windows = []
        thumbnails = [:]
        filterText = ""
        refreshTimer?.invalidate()
        refreshTimer = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
    }

    private func fetchThumbnails(for windows: [WindowInfo], force: Bool, batch: Bool = false) async {
        guard SwitchPreferences.shared.showThumbnails else {
            thumbnails = [:]
            return
        }
        var collected: [CGWindowID: NSImage] = [:]
        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for w in windows {
                group.addTask {
                    let img = await WindowSnapshotter.shared.snapshot(for: w.id, force: force)
                    return (w.id, img)
                }
            }
            for await (id, img) in group {
                guard !Task.isCancelled else { return }
                if let img {
                    if batch { collected[id] = img }
                    else if visible, thumbnails[id] !== img { thumbnails[id] = img }
                }
            }
        }
        if batch, !collected.isEmpty, visible, !Task.isCancelled {
            thumbnails.merge(collected) { _, new in new }
        }
    }
}
