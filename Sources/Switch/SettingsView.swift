import AppKit
import Carbon.HIToolbox
import SwiftUI
import ServiceManagement

/// Wrapper that pairs a binding with a stable SwiftUI identity, so reordering /
/// deleting rows doesn't reshuffle `KeyRecorderField` NSViews mid-recording.
struct EditableBinding: Identifiable, Equatable {
    let id: UUID
    var binding: HotkeyBinding

    init(_ binding: HotkeyBinding, id: UUID = UUID()) {
        self.id = id
        self.binding = binding
    }
}

enum HotkeyAction: CaseIterable {
    case allWindows, currentApp, spaces, stickyToggle

    var label: String {
        switch self {
        case .allWindows:    return "All windows"
        case .currentApp:    return "Current app"
        case .spaces:        return "Spaces"
        case .stickyToggle:  return "Sticky toggle"
        }
    }

    var placeholder: String {
        switch self {
        case .allWindows, .currentApp, .spaces: return "—"
        case .stickyToggle:                     return "Not set"
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var launchAtLogin: Bool = false
    @Published var allWindowsBindings: [EditableBinding] = []
    @Published var currentAppBindings: [EditableBinding] = []
    @Published var spacesBindings: [EditableBinding] = []
    @Published var stickyToggleBindings: [EditableBinding] = []

    init() { refresh() }

    func refresh() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        allWindowsBindings = HotkeyConfig.shared.allWindowsBindings.map { EditableBinding($0) }
        currentAppBindings = HotkeyConfig.shared.currentAppBindings.map { EditableBinding($0) }
        spacesBindings = HotkeyConfig.shared.spacesBindings.map { EditableBinding($0) }
        stickyToggleBindings = HotkeyConfig.shared.stickyToggleBindings.map { EditableBinding($0) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLogin = enabled
            } catch {
                NSLog("Switch: login-item toggle failed: \(error)")
                refresh()
            }
        }
    }

    func bindings(for action: HotkeyAction) -> [EditableBinding] {
        switch action {
        case .allWindows:    return allWindowsBindings
        case .currentApp:    return currentAppBindings
        case .spaces:        return spacesBindings
        case .stickyToggle:  return stickyToggleBindings
        }
    }

    /// Replace the binding at `id` and persist. Empty (placeholder) bindings are
    /// allowed in the in-memory list for UX (just-added empty row) but get
    /// stripped at the persistence layer.
    func updateBinding(_ action: HotkeyAction, id: UUID, to b: HotkeyBinding) {
        mutate(action) { list in
            guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
            list[idx].binding = b
        }
    }

    func addBinding(_ action: HotkeyAction) {
        mutate(action) { list in
            // Avoid appending a second empty placeholder row.
            guard !list.contains(where: { $0.binding.isEmpty }) else { return }
            list.append(EditableBinding(.empty))
        }
    }

    /// Whether this row may be removed. All windows / Current app must keep at
    /// least one real binding — otherwise the persistence layer would drop the
    /// defaults key and the default combo would silently come back while the UI
    /// shows nothing. Sticky toggle stays fully optional.
    func canRemoveBinding(_ action: HotkeyAction, id: UUID) -> Bool {
        guard action != .stickyToggle else { return true }
        let list = bindings(for: action)
        guard let row = list.first(where: { $0.id == id }) else { return false }
        if row.binding.isEmpty { return true }
        return list.filter { !$0.binding.isEmpty }.count > 1
    }

    func removeBinding(_ action: HotkeyAction, id: UUID) {
        guard canRemoveBinding(action, id: id) else { return }
        mutate(action) { list in
            list.removeAll { $0.id == id }
        }
    }

    func resetHotkeys() {
        HotkeyConfig.shared.resetToDefaults()
        refresh()
    }

    private func mutate(_ action: HotkeyAction, _ change: (inout [EditableBinding]) -> Void) {
        switch action {
        case .allWindows:    change(&allWindowsBindings); persist(action)
        case .currentApp:    change(&currentAppBindings); persist(action)
        case .spaces:        change(&spacesBindings); persist(action)
        case .stickyToggle:  change(&stickyToggleBindings); persist(action)
        }
    }

    private func persist(_ action: HotkeyAction) {
        let payload = bindings(for: action).map(\.binding).filter { !$0.isEmpty }
        switch action {
        case .allWindows:    HotkeyConfig.shared.allWindowsBindings = payload
        case .currentApp:    HotkeyConfig.shared.currentAppBindings = payload
        case .spaces:        HotkeyConfig.shared.spacesBindings = payload
        case .stickyToggle:  HotkeyConfig.shared.stickyToggleBindings = payload
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, picker, permissions, appearance, about
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "General"
        case .picker: return "Picker"
        case .permissions: return "Permissions"
        case .appearance: return "Appearance"
        case .about: return "About"
        }
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @ObservedObject private var prefs = SwitchPreferences.shared
    @State private var rejectMessage: String?
    @State private var tab: SettingsTab = .general
    @State private var draggedApp: String?
    @State private var openWindows: [WindowInfo] = []

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().opacity(0.5)
            Group {
                switch tab {
                case .general:     generalTab
                case .picker:      pickerTab
                case .permissions: permissionsTab
                case .appearance:  appearanceTab
                case .about:       AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 500, height: 460)
        .onAppear { model.refresh() }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    Text(t.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tab == t ? prefs.accent.color : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(tab == t ? prefs.accent.color.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Tabs

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                section("Startup") {
                    row(title: "Launch Switch at login",
                        detail: "Run automatically when you sign in to your Mac.") {
                        Toggle("", isOn: Binding(
                            get: { model.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(prefs.accent.color)
                    }
                }

                section("Hotkeys") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(HotkeyAction.allCases, id: \.self) { action in
                            hotkeyActionGroup(action)
                        }
                        if let msg = rejectMessage {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                        HStack {
                            Text("Sticky: ⌘W/Q/H · Hold: ⇧⌘W/Q/H · ⇧ reverse")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset") {
                                rejectMessage = nil
                                model.resetHotkeys()
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, 2)
                    }
                    .padding(14)
                    .background(rowBackground)
                }

                section("Switch") {
                    row(title: "Quit Switch",
                        detail: "Relaunch any time from Spotlight or your Applications folder.") {
                        Button("Quit") { NSApp.terminate(nil) }
                            .controlSize(.small)
                    }
                }
            }
            .padding(24)
        }
    }

    private var pickerTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                section("Behavior") {
                    VStack(spacing: 0) {
                        row(title: "Sticky picker",
                            detail: "Release ⌘ to leave the picker open. Return to switch, Esc to cancel.") {
                            Toggle("", isOn: $prefs.stickyMode)
                                .labelsHidden().toggleStyle(.switch)
                                .tint(prefs.accent.color)
                        }
                        Divider().opacity(0.4)
                        row(title: "Keyboard only",
                            detail: "Ignore mouse hover and click while the picker is open.") {
                            Toggle("", isOn: $prefs.disableMouse)
                                .labelsHidden().toggleStyle(.switch)
                                .tint(prefs.accent.color)
                        }
                        Divider().opacity(0.4)
                        row(title: "Reduce motion",
                            detail: "Turn off picker fade, selection movement, and other switcher animations.") {
                            Toggle("", isOn: $prefs.disableAnimations)
                                .labelsHidden().toggleStyle(.switch)
                                .tint(prefs.accent.color)
                        }
                        Divider().opacity(0.4)
                        row(title: "Hide menu bar icon",
                            detail: "Keep Switch off the menu bar. Open Settings by pressing comma while the picker is open.") {
                            Toggle("", isOn: $prefs.hideMenuBarIcon)
                                .labelsHidden().toggleStyle(.switch)
                                .tint(prefs.accent.color)
                        }
                        Divider().opacity(0.4)
                        row(title: "Type to filter",
                            detail: "Filter windows by typing while the picker is open. When disabled, ⌘W/⌘Q/⌘H work directly.") {
                            Toggle("", isOn: $prefs.typeToFilter)
                                .labelsHidden().toggleStyle(.switch)
                                .tint(prefs.accent.color)
                        }
                        Divider().opacity(0.4)
                        row(title: "Static order",
                            detail: "Keep windows in the same spot every time instead of sorting by recent use.") {
                            Toggle("", isOn: $prefs.staticOrder)
                                .labelsHidden().toggleStyle(.switch)
                                .tint(prefs.accent.color)
                        }
                        if prefs.staticOrder {
                            Divider().opacity(0.4)
                            appOrderList
                        }
                        Divider().opacity(0.4)
                        row(title: "Include apps with no windows",
                            detail: "Show running Dock apps that don't currently have any windows. Picking one activates the app.") {
                            Toggle("", isOn: $prefs.includeWindowlessApps)
                                .labelsHidden().toggleStyle(.switch)
                                .tint(prefs.accent.color)
                        }
                        Divider().opacity(0.4)
                        row(title: "Show thumbnails",
                            detail: "Capture window previews. Turn off to run without Screen Recording.") {
                            Toggle("", isOn: $prefs.showThumbnails)
                                .labelsHidden().toggleStyle(.switch)
                                .tint(prefs.accent.color)
                        }
                        Divider().opacity(0.4)
                        row(title: "Show stoplights on thumbnails",
                            detail: "Red/yellow/green buttons to close, minimize, or zoom each window. ⌘W closes the selected window either way.") {
                            Toggle("", isOn: $prefs.showStoplights)
                                .labelsHidden().toggleStyle(.switch)
                                .tint(prefs.accent.color)
                        }
                        Divider().opacity(0.4)
                        row(title: "Show hint strip",
                            detail: "Keyboard shortcut hints at the bottom of the picker.") {
                            Toggle("", isOn: $prefs.showHintStrip)
                                .labelsHidden().toggleStyle(.switch)
                                .tint(prefs.accent.color)
                        }
                        Divider().opacity(0.4)
                        row(title: "Show window title first",
                            detail: "Put the window title ahead of the app name in each tile and row.") {
                            Toggle("", isOn: $prefs.showTitleFirst)
                                .labelsHidden().toggleStyle(.switch)
                                .tint(prefs.accent.color)
                        }
                    }
                }

                section("Vertical mode") {
                    VStack(spacing: 0) {
                        row(title: "Vertical list",
                            detail: "One window per row instead of a grid.") {
                            Toggle("", isOn: $prefs.verticalList)
                                .labelsHidden().toggleStyle(.switch)
                                .tint(prefs.accent.color)
                        }
                        Divider().opacity(0.4)
                        row(title: "Show top header",
                            detail: "Filter text and window count at the top of the picker.") {
                            Toggle("", isOn: $prefs.verticalShowHeader)
                                .labelsHidden().toggleStyle(.switch)
                                .tint(prefs.accent.color)
                        }
                        Divider().opacity(0.4)
                        row(title: "Show preview",
                            detail: "Window thumbnail at the trailing edge of each row.") {
                            Toggle("", isOn: $prefs.verticalShowPreview)
                                .labelsHidden().toggleStyle(.switch)
                                .tint(prefs.accent.color)
                        }
                        Divider().opacity(0.4)
                        row(title: "Show stoplights",
                            detail: "Close/minimize/zoom buttons inside each row.") {
                            Toggle("", isOn: $prefs.verticalShowStoplights)
                                .labelsHidden().toggleStyle(.switch)
                                .tint(prefs.accent.color)
                        }
                    }
                }

                section("Sizing") {
                    VStack(spacing: 0) {
                        row(title: "Columns",
                            detail: "Number of columns in the grid view. \(prefs.gridColumns)") {
                            Slider(value: Binding(
                                get: { Double(prefs.gridColumns) },
                                set: { prefs.gridColumns = Int($0.rounded()) }
                            ), in: 3...6, step: 1)
                                .frame(width: 140)
                                .tint(prefs.accent.color)
                        }
                        Divider().opacity(0.4)
                        row(title: "Thumbnail size",
                            detail: "Overall picker size. \(Int(prefs.thumbnailHeight))pt") {
                            Slider(value: $prefs.thumbnailHeight, in: 80...300, step: 5)
                                .frame(width: 140)
                                .tint(prefs.accent.color)
                        }
                        Divider().opacity(0.4)
                        row(title: "App icon size",
                            detail: "Size of the app icon on each tile and list row. \(Int(prefs.appIconSize))pt") {
                            Slider(value: $prefs.appIconSize, in: 20...48, step: 2)
                                .frame(width: 140)
                                .tint(prefs.accent.color)
                        }
                        Divider().opacity(0.4)
                        row(title: "Reset sizing",
                            detail: "Restore columns, thumbnail size, and app icon size.") {
                            Button("Reset") {
                                resetSizing()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                advancedSection

                crossSpaceSection

                blacklistSection
            }
            .padding(24)
        }
        .onAppear {
            if let snap = WindowStore.shared.current {
                openWindows = snap.windows.allWindows
                if snap.age < 3 { return }
            }
            WindowStore.shared.refresh { snap in
                openWindows = snap.windows.allWindows
            }
        }
    }

    private var advancedSection: some View {
        section("Advanced") {
            VStack(spacing: 0) {
                row(title: "Picker activation delay",
                    detail: "Hold the hotkey this long before the picker appears. A quick tap switches to your previous window without showing it. \(Int(prefs.pickerActivationDelay))ms") {
                    Slider(value: $prefs.pickerActivationDelay, in: 0...300, step: 10)
                        .frame(width: 140)
                        .tint(prefs.accent.color)
                }
                Divider().opacity(0.4)
                row(title: "Reverse with Shift tap",
                    detail: "While holding the hotkey, tap Shift to step backward. ⇧-Tab still works too.") {
                    Toggle("", isOn: $prefs.shiftTapReverses)
                        .labelsHidden().toggleStyle(.switch)
                        .tint(prefs.accent.color)
                }
            }
        }
    }

    private var blurPreview: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.36, green: 0.42, blue: 0.92),
                    Color(red: 0.86, green: 0.44, blue: 0.78),
                    Color(red: 0.98, green: 0.68, blue: 0.42)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 46, height: 34)
                }
            }
            .padding(14)
            .background(prefs.backgroundBlur.material)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(18)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var crossSpaceSection: some View {
        section("Cross-Space") {
            VStack(spacing: 0) {
                row(title: "Show cross-Space windows",
                    detail: "Include windows on other Spaces. Picking one moves it to your current Space.") {
                    Toggle("", isOn: $prefs.showCrossSpace)
                        .labelsHidden().toggleStyle(.switch)
                        .tint(prefs.accent.color)
                }
                Divider().opacity(0.4)
                row(title: "Mix by recent use",
                    detail: "Sort all windows together by recency instead of grouping by Space.") {
                    Toggle("", isOn: $prefs.mruMixSpaces)
                        .labelsHidden().toggleStyle(.switch)
                        .tint(prefs.accent.color)
                }
            }
        }
    }

    private func resetSizing() {
        prefs.gridColumns = SwitchPreferences.defaultGridColumns
        prefs.thumbnailHeight = SwitchPreferences.defaultThumbnailHeight
        prefs.appIconSize = SwitchPreferences.defaultAppIconSize
    }

    private func hotkeyActionGroup(_ action: HotkeyAction) -> some View {
        let rows = model.bindings(for: action)
        return HStack(alignment: .top, spacing: 10) {
            Text(action.label)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 100, alignment: .leading)
                .padding(.top, 4)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(rows) { row in
                    hotkeyEditorRow(action: action, row: row)
                }
                Button {
                    rejectMessage = nil
                    model.addBinding(action)
                } label: {
                    Label("Add", systemImage: "plus.circle")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(prefs.accent.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hotkeyEditorRow(action: HotkeyAction, row: EditableBinding) -> some View {
        HStack(spacing: 4) {
            KeyRecorderField(
                initialBinding: row.binding,
                onCapture: { b in
                    apply(b, existing: model.bindings(for: action).filter { $0.id != row.id }.map(\.binding)) {
                        model.updateBinding(action, id: row.id, to: $0)
                    }
                },
                accent: prefs.accent.color,
                placeholder: action.placeholder
            )
            .frame(width: 110, height: 24)
            if model.canRemoveBinding(action, id: row.id) {
                Button {
                    rejectMessage = nil
                    model.removeBinding(action, id: row.id)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove this shortcut")
            }
        }
    }

    private var appOrderList: some View {
        let apps = orderedPickerApps()
        return VStack(alignment: .leading, spacing: 6) {
            Text("Drag to reorder. Unranked apps fall to the bottom alphabetically.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if apps.isEmpty {
                Text("No windows open right now.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 2) {
                    ForEach(apps, id: \.self) { name in
                        appOrderRow(name: name)
                            .onDrag {
                                draggedApp = name
                                return NSItemProvider(object: name as NSString)
                            }
                            .onDrop(of: [.text], delegate: AppOrderDropDelegate(
                                item: name,
                                current: $draggedApp,
                                apps: apps,
                                commit: { prefs.appOrder = $0 }
                            ))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func appOrderRow(name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.system(size: 11))
            if let icon = iconForApp(named: name) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            Text(name).font(.system(size: 12))
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(draggedApp == name ? Color.accentColor.opacity(0.10) : Color.clear)
        )
    }

    private func orderedPickerApps() -> [String] {
        let names = Set(openWindows.map(\.appName))
        let ranked = prefs.appOrder.filter { names.contains($0) }
        let unranked = names.subtracting(ranked).sorted { $0.lowercased() < $1.lowercased() }
        return ranked + unranked
    }

    private func iconForApp(named name: String) -> NSImage? {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            return app.icon
        }
        return nil
    }

    private var blacklistSection: some View {
        section("Excluded apps") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Windows from these apps won't appear in the picker.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if prefs.blacklist.isEmpty {
                    Text("Nothing excluded.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(prefs.blacklist).sorted(by: { sortKey($0) < sortKey($1) }), id: \.self) { bid in
                            blacklistRow(bundleID: bid)
                        }
                    }
                }
                Menu {
                    ForEach(addableApps(), id: \.bundleIdentifier) { app in
                        Button {
                            if let bid = app.bundleIdentifier {
                                prefs.blacklist.insert(bid)
                            }
                        } label: {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                            }
                            Text(app.localizedName ?? app.bundleIdentifier ?? "—")
                        }
                    }
                } label: {
                    Text("+ Add app")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(14)
            .background(rowBackground)
        }
    }

    private func blacklistRow(bundleID: String) -> some View {
        let (name, icon) = appInfo(for: bundleID)
        return HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12))
                Text(bundleID)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                prefs.blacklist.remove(bundleID)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    private func addableApps() -> [NSRunningApplication] {
        let pids = Set(openWindows.map(\.pid))
        let ownBundle = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { pids.contains($0.processIdentifier) }
            .filter { $0.bundleIdentifier != ownBundle }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private static var appInfoCache: [String: (name: String, icon: NSImage?)] = [:]

    private func appInfo(for bid: String) -> (name: String, icon: NSImage?) {
        if let cached = Self.appInfoCache[bid] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let name = url.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleName"] as? String }
            ?? url?.deletingPathExtension().lastPathComponent
            ?? bid
        let info = (name, icon)
        Self.appInfoCache[bid] = info
        return info
    }

    private func sortKey(_ bid: String) -> String {
        appInfo(for: bid).name.lowercased()
    }

    private var appearanceTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                section("Accent") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            ForEach(SwitchPreferences.AccentChoice.allCases) { choice in
                                accentSwatch(choice)
                            }
                        }
                        Text(prefs.accent.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Accent shows up in the selection highlight and across this Settings window.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(rowBackground)
                }

                section("Background") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("", selection: $prefs.backgroundBlur) {
                            ForEach(SwitchPreferences.BackgroundBlur.allCases) { b in
                                Text(b.label).tag(b)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        blurPreview
                        Text("How much the desktop blurs through the picker background.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(rowBackground)
                }

            }
            .padding(24)
        }
    }

    private var permissionsTab: some View {
        PermissionsTabView(accent: prefs.accent.color)
    }

    // MARK: - Building blocks

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(prefs.accent.color)
                    .frame(width: 5, height: 5)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func row<Trailing: View>(title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(14)
        .background(rowBackground)
    }

    private func accentSwatch(_ choice: SwitchPreferences.AccentChoice) -> some View {
        let active = prefs.accent == choice
        return Button {
            prefs.accent = choice
        } label: {
            ZStack {
                Circle().fill(choice.color)
                if active {
                    Circle()
                        .stroke(Color.primary.opacity(0.9), lineWidth: 2)
                        .padding(-3)
                }
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(choice.label)
    }

    private func pillLink(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.07))
                .foregroundStyle(.primary)
                .clipShape(Capsule())
        }
    }

    /// Validate `b` against system-reserved combos and the user's other bindings,
    /// then either show a reject message or hand it to `save`.
    private func apply(_ b: HotkeyBinding, existing: [HotkeyBinding] = [], save: (HotkeyBinding) -> Void) {
        if let msg = HotkeyValidator.reject(keyCode: b.keyCode, flags: b.cgFlags) {
            rejectMessage = msg
            return
        }
        if HotkeyValidator.duplicate(of: b, in: existing) {
            rejectMessage = "That combo is already bound to this action."
            return
        }
        rejectMessage = nil
        save(b)
    }

}

struct PermissionsTabView: View {
    let accent: Color
    @StateObject private var perms = OnboardingModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Switch needs Accessibility for the ⌘-Tab hotkey. Screen Recording is only needed when thumbnails are enabled.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                permRow(
                    title: "Accessibility",
                    detail: "Intercept ⌘-Tab and ⌥-` system-wide.",
                    granted: perms.accessibility,
                    action: { perms.openAccessibility() }
                )
                permRow(
                    title: "Screen Recording",
                    detail: SwitchPreferences.shared.showThumbnails ? "Capture live thumbnails of every window." : "Optional while thumbnails are disabled.",
                    granted: perms.screenCapture,
                    action: { perms.openScreenCapture() }
                )
            }
            .padding(24)
        }
        .onAppear { perms.startPolling() }
        .onDisappear { perms.stopPolling() }
    }

    private func permRow(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open in System Settings", action: action)
                    .controlSize(.small)
            } else {
                Text("Granted").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

// MARK: - Key recorder

struct KeyRecorderField: NSViewRepresentable {
    let initialBinding: HotkeyBinding
    let onCapture: (HotkeyBinding) -> Void
    var accent: Color = .accentColor
    var placeholder: String = "—"

    func makeNSView(context: Context) -> KeyRecorderNSView {
        let v = KeyRecorderNSView()
        v.binding = initialBinding
        v.onCapture = onCapture
        v.accentNSColor = NSColor(accent)
        v.placeholder = placeholder
        return v
    }

    func updateNSView(_ view: KeyRecorderNSView, context: Context) {
        if view.binding != initialBinding {
            view.binding = initialBinding
        }
        view.onCapture = onCapture
        view.accentNSColor = NSColor(accent)
        view.placeholder = placeholder
    }
}

extension Notification.Name {
    static let switchRecorderBegan = Notification.Name("com.sanyamgarg.switch.recorderBegan")
    static let switchRecorderEnded = Notification.Name("com.sanyamgarg.switch.recorderEnded")
}

final class KeyRecorderNSView: NSView {
    var onCapture: ((HotkeyBinding) -> Void)?
    var accentNSColor: NSColor = .controlAccentColor { didSet { redraw() } }
    var placeholder: String = "—" { didSet { redraw() } }
    private let label = NSTextField(labelWithString: "")
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var resignToken: NSObjectProtocol?
    private var recording = false { didSet { redraw() } }

    var binding: HotkeyBinding = .defaultAllWindows {
        didSet { redraw() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        redraw()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if recording { stopRecording(commit: false) } else { startRecording() }
    }

    override func resignFirstResponder() -> Bool {
        stopRecording(commit: false)
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording(commit: false) }
    }

    deinit { teardownTap() }

    // NSEvent local monitors never see Cmd+Tab (system app switcher grabs it upstream).
    // Session tap at head fires first, swallows.
    private func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue))
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<KeyRecorderNSView>.fromOpaque(info).takeUnretainedValue().capture(type, event)
        }, userInfo: info) else { recording = false; return }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = src
        if let win = window {
            resignToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: win, queue: .main
            ) { [weak self] _ in
                self?.stopRecording(commit: false)
            }
        }
        NotificationCenter.default.post(name: .switchRecorderBegan, object: nil)
    }

    private func stopRecording(commit: Bool) {
        let wasRecording = eventTap != nil || recording
        teardownTap()
        recording = false
        if wasRecording {
            NotificationCenter.default.post(name: .switchRecorderEnded, object: nil)
        }
    }

    private func teardownTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        if let resignToken { NotificationCenter.default.removeObserver(resignToken) }
        resignToken = nil
    }

    fileprivate func capture(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .flagsChanged { return nil }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if kc != 53 {
                let mods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
                let b = HotkeyBinding(keyCode: UInt16(kc), modifiersRaw: event.flags.intersection(mods).rawValue)
                self.binding = b
                self.onCapture?(b)
            }
            self.stopRecording(commit: kc != 53)
        }
        return nil
    }

    private func redraw() {
        if recording {
            label.stringValue = "Press a key…"
            label.textColor = .secondaryLabelColor
            layer?.borderColor = accentNSColor.cgColor
            layer?.backgroundColor = accentNSColor.withAlphaComponent(0.10).cgColor
        } else {
            if binding.keyCode == 0 && binding.modifiersRaw == 0 {
                label.stringValue = placeholder
                label.textColor = .tertiaryLabelColor
            } else {
                label.stringValue = binding.displayString
                label.textColor = .labelColor
            }
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        }
    }
}

/// Wraps children left-to-right and breaks to a new line when the next subview
/// would overflow the proposed width. Used for hotkey-binding rows so multiple
/// shortcuts per action sit side-by-side and wrap as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var lines: [[CGSize]] = [[]]
        var lineW: CGFloat = 0
        for s in sizes {
            let needed = lines[lines.count - 1].isEmpty ? s.width : lineW + spacing + s.width
            if needed > maxW, !lines[lines.count - 1].isEmpty {
                lines.append([s])
                lineW = s.width
            } else {
                lines[lines.count - 1].append(s)
                lineW = needed
            }
        }
        var height: CGFloat = 0
        var width: CGFloat = 0
        for (i, line) in lines.enumerated() {
            let h = line.map(\.height).max() ?? 0
            let w = line.reduce(0) { $0 + $1.width } + CGFloat(max(0, line.count - 1)) * spacing
            height += h
            if i > 0 { height += lineSpacing }
            width = max(width, w)
        }
        return CGSize(width: min(width, maxW), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var lineH: CGFloat = 0
        var firstOnLine = true
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            let needed = firstOnLine ? s.width : (x - bounds.minX) + spacing + s.width
            if needed > maxW && !firstOnLine {
                x = bounds.minX
                y += lineH + lineSpacing
                lineH = 0
                firstOnLine = true
            }
            if !firstOnLine { x += spacing }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width
            lineH = max(lineH, s.height)
            firstOnLine = false
        }
    }
}

private struct AppOrderDropDelegate: DropDelegate {
    let item: String
    @Binding var current: String?
    let apps: [String]
    let commit: ([String]) -> Void

    func dropEntered(info: DropInfo) {
        guard let from = current, from != item,
              let src = apps.firstIndex(of: from),
              let dst = apps.firstIndex(of: item) else { return }
        var next = apps
        next.remove(at: src)
        next.insert(from, at: dst)
        commit(next)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        current = nil
        return true
    }
}
