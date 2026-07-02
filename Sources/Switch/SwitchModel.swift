import AppKit
import SwiftUI

@MainActor
final class SwitchModel: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var selected: Int = 0
    @Published var mode: HotkeyManager.Mode = .allWindows
    @Published var visible: Bool = false
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    @Published var filterText: String = ""
    @Published var panelSize = CGSize(width: 880, height: 560)

    /// Set by AppDelegate so the view can request a commit + window dismiss from a mouse click.
    var commitAndDismiss: (() -> Void)?
    /// Set by AppDelegate so the model can request a dismiss when no windows remain after a close.
    var cancelAndDismiss: (() -> Void)?

    private var refreshTimer: Timer?
    private var prewarmTimer: Timer?
    private var armGeneration = 0
    private var armFrontmostPID: pid_t?
    private var thumbnailTasks: [Task<Void, Never>] = []
    var pointerWindowID: CGWindowID?

    var filteredWindows: [WindowInfo] {
        let q = filterText.lowercased()
        if q.isEmpty { return windows }
        let scored: [(WindowInfo, Int)] = windows.compactMap { w in
            let a = Self.fuzzyScore(pattern: q, target: w.appName.lowercased())
            let t = Self.fuzzyScore(pattern: q, target: w.title.lowercased())
            guard let s = [a, t].compactMap({ $0 }).max() else { return nil }
            return (w, s)
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
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

    func arm(_ mode: HotkeyManager.Mode) {
        armGeneration &+= 1
        let gen = armGeneration
        self.mode = mode
        filterText = ""
        pointerWindowID = nil
        armFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
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
    }

    private func apply(snapshot: WindowStore.Snapshot, initial: Bool) {
        let previousSelectedID: CGWindowID? = {
            guard !initial else { return nil }
            let list = filteredWindows
            return list.indices.contains(selected) ? list[selected].id : nil
        }()

        let final: [WindowInfo]
        if mode == .spaces {
            let active = Int(CGSGetActiveSpace(CGSMainConnectionID()))
            final = snapshot.windows.spaceRepresentatives.map { rep in
                var out = rep
                out.isCrossSpace = out.spaceID != active
                out.spaceLabel = out.spaceID == active ? "Current" : nil
                return out
            }
        } else {
            final = buildWindowList(from: snapshot.windows)
        }
        let changed = final != windows
        if changed { windows = final }

        if initial {
            if mode == .spaces {
                let reps = filteredWindows
                if let current = reps.firstIndex(where: { !$0.isCrossSpace }), reps.count > 1 {
                    selected = (current + 1) % reps.count
                } else {
                    selected = 0
                }
            } else {
                selected = SwitchPreferences.shared.stickyMode ? 0 : (filteredWindows.count > 1 ? 1 : 0)
            }
        } else if changed {
            let list = filteredWindows
            if let previousSelectedID, let idx = list.firstIndex(where: { $0.id == previousSelectedID }) {
                selected = idx
            } else if selected >= list.count {
                selected = max(list.count - 1, 0)
            }
        }

        thumbnailTasks.forEach { $0.cancel() }
        thumbnailTasks = []
        let thumbTargets = final.filter { !$0.isWindowless }
        let gen = armGeneration
        if initial {
            let task = Task {
                await fetchThumbnails(for: thumbTargets, force: false)
            }
            thumbnailTasks.append(task)
        } else {
            let liveIDs = Set(thumbTargets.map { $0.id })
            let task = Task {
                if SwitchPreferences.shared.showThumbnails, #available(macOS 14.0, *) {
                    // Don't full-purge — pre-warmed thumbs are valid as long as the window still exists.
                    await WindowSnapshotter.shared.purge(keeping: liveIDs)
                }
                await fetchThumbnails(for: thumbTargets, force: false)
                guard armGeneration == gen, visible else { return }
                await fetchThumbnails(for: thumbTargets, force: true, batch: true)
            }
            thumbnailTasks.append(task)
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
        if mode == .currentApp, let f = armFrontmostPID {
            active = active.filter { $0.pid == f }
            cross = cross.filter { $0.pid == f }
        }
        if !SwitchPreferences.shared.showCrossSpace {
            cross = cross.filter { !$0.isCrossSpace }
        }
        let activeFront = WindowMRU.mostRecent(in: active) ?? active.first
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
            ws = WindowMRU.sorted(active + cross, frontmost: activeFront)
        } else {
            ws = WindowMRU.sorted(active, frontmost: activeFront) + WindowMRU.sorted(cross, frontmost: nil)
        }
        var final = ws
        if SwitchPreferences.shared.includeWindowlessApps && mode == .allWindows {
            let switchablePIDs = full.allPIDs
            let ownBundle = Bundle.main.bundleIdentifier
            let extras = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && !switchablePIDs.contains($0.processIdentifier) && $0.bundleIdentifier != ownBundle }
                .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
                .map { app in
                    WindowInfo(
                        id: CGWindowID(0xF0000000) | CGWindowID(UInt32(bitPattern: Int32(app.processIdentifier))),
                        pid: app.processIdentifier,
                        appName: app.localizedName ?? "",
                        title: "",
                        bounds: .zero,
                        isWindowless: true,
                        bundleID: app.bundleIdentifier
                    )
                }
            final += extras
        }
        let pinned = SwitchPreferences.shared.pinnedBundleIDs
        if !pinned.isEmpty {
            final.sort { (a, b) in
                let aP = a.bundleID.map { pinned.contains($0) } ?? false
                let bP = b.bundleID.map { pinned.contains($0) } ?? false
                return aP && !bP
            }
        }
        return final
    }

    func closeSelected() {
        let list = filteredWindows
        guard list.indices.contains(selected) else { return }
        close(list[selected])
    }

    func close(_ target: WindowInfo) {
        guard mode != .spaces else { return }
        WindowCloser.close(target)
        removeFromPicker { $0.id == target.id }
    }

    func quitApp(withWindowID id: CGWindowID) {
        guard mode != .spaces else { return }
        guard let target = windows.first(where: { $0.id == id }) else { return }
        AppCloser.close(target)
        removeFromPicker { $0.pid == target.pid }
    }

    private func removeFromPicker(_ shouldRemove: (WindowInfo) -> Bool) {
        windows.removeAll(where: shouldRemove)
        let liveIDs = Set(windows.map { $0.id })
        thumbnails = thumbnails.filter { liveIDs.contains($0.key) }
        let remaining = filteredWindows
        if remaining.isEmpty {
            cancelAndDismiss?()
            return
        }
        if selected >= remaining.count {
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

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
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
        WindowStore.shared.refresh { snap in
            let ws = snap.windows.allWindows
            let liveIDs = Set(ws.map { $0.id })
            WindowMRU.purge(keeping: snap.windows.allIDs)
            Task.detached(priority: .utility) {
                AXWindowCache.purgeDead()
            }
            guard SwitchPreferences.shared.showThumbnails, #available(macOS 14.0, *) else { return }
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

    func advance(reverse: Bool) {
        let list = filteredWindows
        guard !list.isEmpty else { return }
        let n = list.count
        selected = reverse ? (selected - 1 + n) % n : (selected + 1) % n
    }

    func navigate(direction: HotkeyManager.Direction) {
        let list = filteredWindows
        guard !list.isEmpty else { return }
        let n = list.count
        let cols = (SwitchPreferences.shared.verticalList || mode == .spaces) ? 1 : SwitchPreferences.shared.gridColumns
        let delta: Int
        switch direction {
        case .left:  delta = -1
        case .right: delta = 1
        case .up:    delta = -cols
        case .down:  delta = cols
        }
        selected = ((selected + delta) % n + n) % n
    }

    func pickIndex(_ index: Int) {
        let list = filteredWindows
        guard list.indices.contains(index) else { return }
        selected = index
        commitAndDismiss?()
    }

    func selectIndex(_ index: Int) {
        let list = filteredWindows
        guard list.indices.contains(index) else { return }
        selected = index
    }

    func closeSelectedApp() {
        guard mode != .spaces else { return }
        let list = filteredWindows
        guard list.indices.contains(selected) else { return }
        AppCloser.close(list[selected])
        cancelAndDismiss?()
    }


    func hideSelected() {
        guard mode != .spaces else { return }
        let list = filteredWindows
        guard list.indices.contains(selected) else { return }
        let target = list[selected]
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

    func commit() {
        let list = filteredWindows
        if list.indices.contains(selected) {
            WindowFocuser.focus(list[selected])
        }
        teardown()
    }

    func cancel() {
        teardown()
    }

    private func teardown() {
        visible = false
        windows = []
        thumbnails = [:]
        filterText = ""
        stopRefreshTimer()
        thumbnailTasks.forEach { $0.cancel() }
        thumbnailTasks = []
    }

    private func fetchThumbnails(for windows: [WindowInfo], force: Bool, batch: Bool = false) async {
        guard SwitchPreferences.shared.showThumbnails else {
            thumbnails = [:]
            return
        }
        if #available(macOS 14.0, *) {
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
                        else if visible { thumbnails[id] = img }
                    }
                }
            }
            if batch, !collected.isEmpty, visible, !Task.isCancelled {
                thumbnails.merge(collected) { _, new in new }
            }
        }
    }
}
