import AppKit
import Carbon.HIToolbox
import SwiftUI
import ServiceManagement
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class SettingsModel: ObservableObject {
    @Published var launchAtLogin: Bool = false
    @Published var autoUpdateCheck: Bool = true
    @Published var bindings: [HotkeyConfig.Slot: HotkeyBinding] = [:]

    init() { refresh() }

    #if canImport(Sparkle)
    private var updater: SPUUpdater? { AppDelegate.shared?.sparkleUpdater }
    #endif

    func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        #if canImport(Sparkle)
        autoUpdateCheck = updater?.automaticallyChecksForUpdates ?? true
        #endif
        bindings = HotkeyConfig.Slot.allCases.reduce(into: [:]) { $0[$1] = HotkeyConfig.shared[$1] }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
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

    func setAutoUpdateCheck(_ enabled: Bool) {
        #if canImport(Sparkle)
        updater?.automaticallyChecksForUpdates = enabled
        #endif
        autoUpdateCheck = enabled
    }

    func update(_ slot: HotkeyConfig.Slot, _ b: HotkeyBinding?) {
        HotkeyConfig.shared[slot] = b
        bindings[slot] = b
    }

    func resetHotkeys() {
        HotkeyConfig.shared.resetToDefaults()
        refresh()
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
                    toggleRow("Launch Switch at login",
                              "Run automatically when you sign in to your Mac.",
                              Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                }

                section("Hotkeys") {
                    VStack(alignment: .leading, spacing: 12) {
                        hotkeyRow("All windows", rows: [("Primary", .allWindows), ("Alternate", .allWindowsAlternate)])
                        hotkeyRow("Current app", rows: [("Primary", .currentApp), ("Alternate", .currentAppAlternate)])
                        hotkeyRow("Spaces", rows: [("Primary", .spaces), ("Alternate", .spacesAlternate)],
                                  detail: "Cycle Spaces. Conflicts with browser tab switching if set to ⌃Tab.")
                        hotkeyRow("Sticky picker", rows: [("All windows", .allWindowsSticky), ("Current app", .currentAppSticky)],
                                  detail: "Opens the picker in sticky mode, leaving your main hotkeys quick.")
                        hotkeyRow("Current Space", rows: [("Primary", .currentSpace)],
                                  detail: "All windows on the current Space only, whatever the cross-Space setting.")
                        hotkeyRow("Sticky toggle", rows: [("Primary", .stickyToggle)],
                                  detail: "Turns sticky mode on or off for the main hotkeys.")
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
                        .padding(.top, 4)
                    }
                    .padding(14)
                    .background(rowBackground)
                }

                section("Updates") {
                    toggleRow("Check for updates automatically",
                              "Look for new versions in the background and offer to install them. Turn off if you update through Homebrew.",
                              Binding(get: { model.autoUpdateCheck }, set: { model.setAutoUpdateCheck($0) }))
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
                        toggleRow("Sticky picker",
                                  "Release ⌘ to leave the picker open. Return to switch, Esc to cancel.",
                                  $prefs.stickyMode)
                        Divider().opacity(0.4)
                        toggleRow("Keyboard only",
                                  "Ignore mouse hover and click while the picker is open.",
                                  $prefs.disableMouse)
                        Divider().opacity(0.4)
                        toggleRow("Reduce motion",
                                  "Turn off picker fade, selection movement, and other switcher animations.",
                                  $prefs.disableAnimations)
                        Divider().opacity(0.4)
                        toggleRow("Hide menu bar icon",
                                  "Keep Switch off the menu bar. Open Settings by pressing comma while the picker is open.",
                                  $prefs.hideMenuBarIcon)
                        Divider().opacity(0.4)
                        toggleRow("Type to filter",
                                  "Filter windows by typing while the picker is open. When disabled, ⌘W/⌘Q/⌘H work directly.",
                                  $prefs.typeToFilter)
                        Divider().opacity(0.4)
                        toggleRow("Static order",
                                  "Keep windows in the same spot every time instead of sorting by recent use.",
                                  $prefs.staticOrder)
                        if prefs.staticOrder {
                            Divider().opacity(0.4)
                            appOrderList
                        }
                        Divider().opacity(0.4)
                        toggleRow("Hide minimized and hidden windows",
                                  "Leave out windows that are minimized to the Dock or belong to hidden apps.",
                                  $prefs.hideMinimizedWindows)
                        Divider().opacity(0.4)
                        toggleRow("Show number key hints",
                                  "Label the first nine windows with the 1-9 key that picks them.",
                                  $prefs.showNumberKeyHints)
                        Divider().opacity(0.4)
                        toggleRow("Include apps with no windows",
                                  "Show running Dock apps that don't currently have any windows. Picking one activates the app.",
                                  $prefs.includeWindowlessApps)
                        Divider().opacity(0.4)
                        toggleRow("Show thumbnails",
                                  "Capture window previews. Turn off to run without Screen Recording.",
                                  $prefs.showThumbnails)
                        Divider().opacity(0.4)
                        toggleRow("Show stoplights on thumbnails",
                                  "Red/yellow/green buttons to close, minimize, or zoom each window. ⌘W closes the selected window either way.",
                                  $prefs.showStoplights)
                        Divider().opacity(0.4)
                        toggleRow("Show hint strip",
                                  "Keyboard shortcut hints at the bottom of the picker.",
                                  $prefs.showHintStrip)
                        Divider().opacity(0.4)
                        toggleRow("Show window title first",
                                  "Put the window title ahead of the app name in each tile and row.",
                                  $prefs.showTitleFirst)
                    }
                }

                section("Vertical mode") {
                    VStack(spacing: 0) {
                        toggleRow("Vertical list",
                                  "One window per row instead of a grid.",
                                  $prefs.verticalList)
                        Divider().opacity(0.4)
                        toggleRow("Show top header",
                                  "Filter text and window count at the top of the picker.",
                                  $prefs.verticalShowHeader)
                        Divider().opacity(0.4)
                        toggleRow("Show preview",
                                  "Window thumbnail at the trailing edge of each row.",
                                  $prefs.verticalShowPreview)
                        Divider().opacity(0.4)
                        toggleRow("Show stoplights",
                                  "Close/minimize/zoom buttons inside each row.",
                                  $prefs.verticalShowStoplights)
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
                        row(title: "Rows",
                            detail: "Rows visible at once in the list view. \(prefs.maxListRows)") {
                            Slider(value: Binding(
                                get: { Double(prefs.maxListRows) },
                                set: { prefs.maxListRows = Int($0.rounded()) }
                            ), in: 4...20, step: 1)
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
                            detail: "Restore columns, rows, thumbnail size, and app icon size.") {
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
                toggleRow("Reverse with Shift tap",
                          "While holding the hotkey, tap Shift to step backward. ⇧-Tab still works too.",
                          $prefs.shiftTapReverses)
                Divider().opacity(0.4)
                row(title: "Show picker on",
                    detail: "Mouse: the screen under the cursor. Active: the screen with the focused window. Primary: your main display.") {
                    Picker("", selection: $prefs.pickerDisplay) {
                        ForEach(SwitchPreferences.PickerDisplay.allCases) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
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
                toggleRow("Show cross-Space windows",
                          "Include windows on other Spaces. Picking one moves it to your current Space.",
                          $prefs.showCrossSpace)
                Divider().opacity(0.4)
                toggleRow("Mix by recent use",
                          "Sort all windows together by recency instead of grouping by Space.",
                          $prefs.mruMixSpaces)
            }
        }
    }

    private func resetSizing() {
        prefs.gridColumns = SwitchPreferences.defaultGridColumns
        prefs.maxListRows = SwitchPreferences.defaultMaxListRows
        prefs.thumbnailHeight = SwitchPreferences.defaultThumbnailHeight
        prefs.appIconSize = SwitchPreferences.defaultAppIconSize
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

    private func toggleRow(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        row(title: title, detail: detail) {
            Toggle("", isOn: isOn)
                .labelsHidden().toggleStyle(.switch)
                .tint(prefs.accent.color)
        }
    }

    private func hotkeyRow(_ label: String, rows: [(String, HotkeyConfig.Slot)], detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 100, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows, id: \.1) { sub in
                        hotkeyBindingRow(label: sub.0, slot: sub.1)
                    }
                }
                Spacer()
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 112)
            }
        }
    }

    private func hotkeyBindingRow(label: String, slot: HotkeyConfig.Slot) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            KeyRecorderField(
                initialBinding: model.bindings[slot] ?? HotkeyBinding(keyCode: 0, modifiersRaw: 0),
                onCapture: { applyHotkey($0, to: slot) },
                accent: prefs.accent.color,
                placeholder: "Not set"
            )
            .frame(width: 150, height: 28)
            if model.bindings[slot] != nil {
                Button { applyHotkey(nil, to: slot) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear \(label.lowercased()) shortcut")
            }
        }
        .frame(height: 28)
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

    private func applyHotkey(_ b: HotkeyBinding?, to slot: HotkeyConfig.Slot) {
        guard let b else {
            rejectMessage = nil
            model.update(slot, nil)
            return
        }
        if let msg = HotkeyValidator.reject(keyCode: b.keyCode, flags: b.cgFlags) {
            rejectMessage = msg
        } else if model.bindings.contains(where: { $0.key != slot && $0.value.conflicts(with: b) }) {
            rejectMessage = "That shortcut is already assigned."
        } else {
            rejectMessage = nil
            model.update(slot, b)
        }
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
        if recording { stopRecording() } else { startRecording() }
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
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
                self?.stopRecording()
            }
        }
        NotificationCenter.default.post(name: .switchRecorderBegan, object: nil)
    }

    private func stopRecording() {
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
        let mods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let held = event.flags.intersection(mods)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Bare Esc cancels; Esc with a modifier is a recordable combo (#116).
            if kc != 53 || !held.isEmpty {
                let b = HotkeyBinding(keyCode: UInt16(kc), modifiersRaw: held.rawValue)
                self.binding = b
                self.onCapture?(b)
            }
            self.stopRecording()
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
