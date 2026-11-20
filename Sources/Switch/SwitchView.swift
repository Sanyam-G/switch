import SwiftUI

/// Numbers the panel sizer shares with the view, or whole-row sizing clips.
enum PickerLayout {
    static let headerHeight: CGFloat = 26
    static let hintStripHeight: CGFloat = 31
    static let listRowSpacing: CGFloat = 4
    static let listBottomPadding: CGFloat = 10
    /// Without a header the list keeps a little more air at the top.
    static func listTopPadding(showHeader: Bool) -> CGFloat { showHeader ? 10 : 14 }
    /// Pinned on the row: two text lines need 32pt, a preview 50pt, plus 6pt above and below.
    static func listRowHeight(preview: Bool, icon: CGFloat) -> CGFloat { max(preview ? 50 : 32, icon) + 12 }
    static let gridSpacing: CGFloat = 14
    static let gridHorizontalPadding: CGFloat = 22
    static let gridTopPadding: CGFloat = 4
    static let gridBottomPadding: CGFloat = 12
    /// Never more columns than windows (at least 3), so a short list keeps full-size tiles.
    static func gridColumns(configured: Int, count: Int) -> Int { min(max(configured, 1), max(count, 3)) }
    static let tilePadding: CGFloat = 9
    static let tileTitleSpacing: CGFloat = 7
    static let tileTitleHeight: CGFloat = 16
    /// A tile's height beyond its thumbnail.
    static let tileExtraHeight = tilePadding * 2 + tileTitleSpacing + tileTitleHeight
}

struct SwitchView: View {
    @EnvironmentObject var model: SwitchModel
    @ObservedObject private var prefs = SwitchPreferences.shared
    @Namespace private var selectionNS
    @State private var hoveredID: CGWindowID?
    @State private var openMouseLocation: CGPoint = .zero
    @State private var hasMouseMovedSinceOpen = false
    @State private var lastSelectionFromMouse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func handleHover(_ isHovering: Bool, windowID: CGWindowID, index: Int) {
        guard !prefs.disableMouse else { return }
        guard isHovering else {
            if model.pointerWindowID == windowID { model.pointerWindowID = nil }
            if hoveredID == windowID { hoveredID = nil }
            return
        }
        model.pointerWindowID = windowID
        // Ignore hover until cursor has actually moved 10pt+ since panel opened.
        // Otherwise a static cursor parked over a tile hijacks the default selection.
        if !hasMouseMovedSinceOpen {
            let loc = NSEvent.mouseLocation
            if hypot(loc.x - openMouseLocation.x, loc.y - openMouseLocation.y) < 10 { return }
            hasMouseMovedSinceOpen = true
        }
        hoveredID = windowID
        if !prefs.clickOnly && model.selected != index {
            lastSelectionFromMouse = true
            model.selected = index
        }
    }

    private func handleTap(index: Int) {
        guard !prefs.disableMouse else { return }
        lastSelectionFromMouse = true
        model.selected = index
        model.commitAndDismiss?()
    }

    @ViewBuilder
    private func windowBadge(for window: WindowInfo) -> some View {
        if window.isMinimized || window.isHidden || window.isCrossSpace || window.isWindowless {
            capsuleBadge(windowBadgeText(for: window))
        }
    }

    private func capsuleBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func numberHint(index: Int) -> some View {
        if prefs.showNumberKeyHints && !isSpaceMode && index < 9 {
            Text(prefs.homeRowSelection ? SwitchPreferences.homeRowKeys[index].uppercased() : "\(index + 1)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 16, height: 16)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    private func windowBadgeText(for window: WindowInfo) -> String {
        if window.isMinimized { return "MINIMIZED" }
        if window.isHidden { return "HIDDEN" }
        if window.isWindowless { return "NO WINDOWS" }
        return window.spaceLabel?.uppercased() ?? "OTHER SPACE"
    }

    private var showHeader: Bool { model.showsHeader }

    private var isSpaceMode: Bool { model.mode == .spaces }
    private var animationsEnabled: Bool { !prefs.disableAnimations && !reduceMotion }

    private var panelAnimation: Animation? {
        guard animationsEnabled else { return nil }
        return prefs.verticalList
            ? .spring(response: 0.22, dampingFraction: 0.9)
            : .spring(response: 0.18, dampingFraction: 0.86)
    }

    private func switcherAnimation(_ animation: Animation) -> Animation? {
        animationsEnabled ? animation : nil
    }

    private var panelScale: CGFloat {
        animationsEnabled ? (model.visible ? 1.0 : 0.97) : 1.0
    }

    private var panelYOffset: CGFloat {
        animationsEnabled && prefs.verticalList && !model.visible ? -5 : 0
    }

    var body: some View {
        VStack(spacing: 0) {
            if showHeader { header }
            grid
            if prefs.showHintStrip { hintStrip }
        }
        .frame(width: model.panelSize.width, height: model.panelSize.height)
        .background {
            // SwiftUI materials don't sample behind the panel pre-Tahoe (#81).
            if #available(macOS 26.0, *) {
                Rectangle().fill(prefs.backgroundBlur.material)
            } else {
                VisualEffectBackdrop(material: prefs.backgroundBlur.nsMaterial, blendingMode: .behindWindow)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .scaleEffect(panelScale)
        .offset(y: panelYOffset)
        .opacity(model.visible ? 1 : 0)
        .animation(panelAnimation, value: model.visible)
        .onChange(of: model.visible) { _, isVisible in
            if isVisible {
                openMouseLocation = NSEvent.mouseLocation
                hasMouseMovedSinceOpen = false
                lastSelectionFromMouse = false
                hoveredID = nil
            }
        }
        // A resize slides rows under a parked pointer; hover waits for real movement again.
        .onChange(of: model.panelSize) {
            openMouseLocation = NSEvent.mouseLocation
            hasMouseMovedSinceOpen = false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !model.filterText.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(model.filterText)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Spacer()
            if prefs.showWindowCount && !model.filteredWindows.isEmpty {
                Text(isSpaceMode ? "\(model.filteredWindows.count) spaces" : "\(model.filteredWindows.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 22)
        .frame(height: PickerLayout.headerHeight)
    }

    private var grid: some View {
        ZStack {
            let list = model.filteredWindows
            let isList = isSpaceMode || prefs.verticalList
            if list.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        if isList {
                            LazyVStack(spacing: PickerLayout.listRowSpacing) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { idx, w in
                                    listRow(window: w, index: idx)
                                        .id(w.id)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 1) // room for the selection ring's stroke
                        } else {
                            LazyVGrid(columns: gridColumns, spacing: PickerLayout.gridSpacing) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { idx, w in
                                    tile(window: w, index: idx)
                                        .id(w.id)
                                }
                            }
                            .padding(.horizontal, PickerLayout.gridHorizontalPadding)
                            .padding(.top, PickerLayout.gridTopPadding)
                            .padding(.bottom, PickerLayout.gridBottomPadding)
                        }
                    }
                    // Initial too: the ScrollView is rebuilt each arm in the same update that sets the selection.
                    .onChange(of: model.selected, initial: true) { _, new in
                        // Skip auto-scroll when selection came from mouse hover;
                        // user is already looking at where they're pointing.
                        if lastSelectionFromMouse {
                            lastSelectionFromMouse = false
                            return
                        }
                        let cur = model.filteredWindows
                        guard cur.indices.contains(new) else { return }
                        withAnimation(switcherAnimation(.easeInOut(duration: 0.22))) {
                            // nil anchor: the least scroll that shows the whole row.
                            proxy.scrollTo(cur[new].id, anchor: nil)
                        }
                    }
                    // The list's padding sits outside the viewport so a scroll always ends on whole rows (#132).
                    .padding(.top, isList ? PickerLayout.listTopPadding(showHeader: showHeader) - 1 : 0)
                    .padding(.bottom, isList ? PickerLayout.listBottomPadding - 1 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.filterText.isEmpty ? "rectangle.stack" : "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(model.filterText.isEmpty ? "No windows" : "No matches")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .transition(.scale(scale: 0.98).combined(with: .opacity))
    }

    private var hintStrip: some View {
        HStack(spacing: 18) {
            hint("↵", isSpaceMode ? "switch space" : "switch")
            hint(navKey, "navigate")
            if prefs.shiftTapReverses { hint("⇧", "reverse") }
            if !isSpaceMode { hint(closeKey, "close") }
            if prefs.typeToFilter { hint("type", "filter") }
            hint("esc", "cancel")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: PickerLayout.hintStripHeight)
        .background(Color.black.opacity(0.18))
    }

    private var navKey: String {
        if prefs.verticalList || isSpaceMode {
            return prefs.vimNavigation ? "↑↓ / jk" : "↑↓"
        }
        return prefs.vimNavigation ? "←↑↓→ / hjkl" : "←↑↓→"
    }

    private var closeKey: String {
        (model.stickySession || !prefs.typeToFilter) ? "⌘W" : "⇧⌘W"
    }

    private func stoplights(for window: WindowInfo) -> some View {
        HStack(spacing: 4) {
            stoplight(color: Color(red: 1.0, green: 0.36, blue: 0.34), symbol: "xmark", label: "Close window") {
                model.close(window)
            }
            stoplight(color: Color(red: 1.0, green: 0.74, blue: 0.20), symbol: "minus", label: "Minimize") {
                AXHelpers.press(kAXMinimizeButtonAttribute, of: window)
            }
            stoplight(color: Color(red: 0.30, green: 0.78, blue: 0.34), symbol: "plus", label: "Zoom") {
                AXHelpers.press(kAXZoomButtonAttribute, of: window)
            }
        }
        .opacity(prefs.disableMouse ? 0 : 1)
        .allowsHitTesting(!prefs.disableMouse)
    }

    private func pinButton(for window: WindowInfo) -> some View {
        let bid = window.bundleID
        let isPinned = window.isPinned(in: prefs.pinnedBundleIDs)
        return Button {
            guard let bid else { return }
            if isPinned { prefs.pinnedBundleIDs.remove(bid) }
            else { prefs.pinnedBundleIDs.insert(bid) }
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isPinned ? prefs.accent.color : Color.white.opacity(0.75))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.black.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPinned ? "Unpin app" : "Pin app")
        .opacity(prefs.disableMouse ? 0 : 1)
        .allowsHitTesting(!prefs.disableMouse)
    }

    private func stoplight(color: Color, symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.black.opacity(0.55))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                )
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .help(label)
    }

    private var gridColumns: [GridItem] {
        let n = PickerLayout.gridColumns(configured: prefs.gridColumns, count: model.windows.count)
        return Array(repeating: GridItem(.flexible(), spacing: PickerLayout.gridSpacing), count: n)
    }

    private func tile(window: WindowInfo, index: Int) -> some View {
        let selected = index == model.selected
        let hovered = hoveredID == window.id
        let icon = appIcon(for: window)

        return VStack(alignment: .leading, spacing: PickerLayout.tileTitleSpacing) {
            ZStack {
                Color.black.opacity(0.22)
                if prefs.showThumbnails, let img = model.thumbnails[window.id] {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)
                        .opacity(0.55)
                        .scaleEffect(selected ? 1.05 : 1.0)
                        .animation(switcherAnimation(.spring(response: 0.20, dampingFraction: 0.82)), value: selected)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: prefs.showThumbnails ? prefs.thumbnailHeight : SwitchPreferences.compactThumbnailHeight)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .topLeading) {
                if prefs.showStoplights && !window.isWindowless {
                    stoplights(for: window).padding(7)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !window.isWindowless && (window.isPinned(in: prefs.pinnedBundleIDs) || hovered) {
                    pinButton(for: window).padding(7)
                }
            }
            .animation(switcherAnimation(.easeOut(duration: 0.18)), value: model.thumbnails[window.id] != nil)
            .overlay(alignment: .bottomLeading) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: prefs.appIconSize, height: prefs.appIconSize)
                        .overlay(alignment: .topTrailing) { dockBadge(for: window) }
                        .scaleEffect(selected ? 1.06 : 1.0)
                        .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 1)
                        .padding(7)
                        .animation(switcherAnimation(.spring(response: 0.20, dampingFraction: 0.82)), value: selected)
                }
            }
            .overlay(alignment: .bottomTrailing) { windowBadge(for: window).padding(7) }

            HStack(spacing: 6) {
                let titleFirst = prefs.showTitleFirst && !window.title.isEmpty
                numberHint(index: index)
                Text(titleFirst ? window.title : window.appName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !window.title.isEmpty {
                    Text("·")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text(titleFirst ? window.appName : window.title)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: PickerLayout.tileTitleHeight)
            .padding(.horizontal, 2)
        }
        .padding(PickerLayout.tilePadding)
        .modifier(SelectionChrome(selected: selected, hovered: hovered, cornerRadius: 9, accent: prefs.accent.color, namespace: selectionNS, selectedValue: model.selected, animated: animationsEnabled))
        .contentShape(Rectangle())
        .onHover { handleHover($0, windowID: window.id, index: index) }
        .onTapGesture { handleTap(index: index) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { handleTap(index: index) }
    }

    private func listRow(window: WindowInfo, index: Int) -> some View {
        let selected = index == model.selected
        let hovered = hoveredID == window.id
        let icon = appIcon(for: window)

        return HStack(spacing: 11) {
            numberHint(index: index)
            ZStack {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: prefs.appIconSize, height: prefs.appIconSize)
                        .overlay(alignment: .topTrailing) { dockBadge(for: window) }
                        .scaleEffect(selected ? 1.08 : 1.0)
                        .animation(switcherAnimation(.spring(response: 0.20, dampingFraction: 0.82)), value: selected)
                } else {
                    Color.clear.frame(width: prefs.appIconSize, height: prefs.appIconSize)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                let titleFirst = prefs.showTitleFirst && !window.title.isEmpty
                Text(titleFirst ? window.title : window.appName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !window.title.isEmpty {
                    Text(titleFirst ? window.appName : window.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if !isSpaceMode && prefs.showStoplights && prefs.verticalShowStoplights && !window.isWindowless {
                stoplights(for: window)
                    .opacity(hovered ? 1 : 0.45)
            }
            if !isSpaceMode && !window.isWindowless && (window.isPinned(in: prefs.pinnedBundleIDs) || hovered) {
                pinButton(for: window)
                    .opacity(hovered ? 1 : 0.8)
            }
            if isSpaceMode {
                if !window.isCrossSpace {
                    capsuleBadge("CURRENT")
                }
            } else {
                windowBadge(for: window)
            }
            if prefs.showThumbnails && prefs.verticalShowPreview {
                Group {
                    if let img = model.thumbnails[window.id] {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 88, height: 50)
                    } else {
                        Color.black.opacity(0.22)
                            .frame(width: 88, height: 50)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PickerLayout.listRowHeight(preview: prefs.showThumbnails && prefs.verticalShowPreview, icon: prefs.appIconSize))
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SelectionChrome(selected: selected, hovered: hovered, cornerRadius: 8, accent: prefs.accent.color, namespace: selectionNS, selectedValue: model.selected, animated: animationsEnabled))
        .contentShape(Rectangle())
        .onHover { handleHover($0, windowID: window.id, index: index) }
        .onTapGesture { handleTap(index: index) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { handleTap(index: index) }
    }

    @ViewBuilder
    private func dockBadge(for window: WindowInfo) -> some View {
        if !isSpaceMode, prefs.showDockBadges, let id = window.bundleID, let badge = model.dockBadges[id] {
            Text(badge)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(Color(nsColor: .systemRed)))
                .offset(x: 5, y: -5)
        }
    }

    private func appIcon(for window: WindowInfo) -> NSImage? {
        let key = window.bundleID ?? "pid:\(window.pid)"
        if let cached = Self.iconCache[key] { return cached }
        // By bundle first: Steam's windows belong to its icon-less helper (#206).
        let app = window.bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        guard let icon = (app ?? NSRunningApplication(processIdentifier: window.pid))?.icon else { return nil }
        if Self.iconCache.count > 256 { Self.iconCache.removeAll() }
        Self.iconCache[key] = icon
        return icon
    }

    private static var iconCache: [String: NSImage] = [:]
}

private struct SelectionChrome: ViewModifier {
    let selected: Bool
    let hovered: Bool
    let cornerRadius: CGFloat
    let accent: Color
    let namespace: Namespace.ID
    let selectedValue: Int
    let animated: Bool

    func body(content: Content) -> some View {
        content
            .background(
                // Clipping at the row level hides the matched-geometry fill while it slides between rows, so the rounding lives on the fills themselves (#133).
                ZStack {
                    if hovered && !selected {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    }
                    if selected {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(accent.opacity(0.32))
                            .matchedGeometryEffect(id: "selectionBG", in: namespace)
                    }
                }
            )
            .overlay(
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(accent, lineWidth: 1.5)
                            .matchedGeometryEffect(id: "selectionRing", in: namespace)
                    }
                }
            )
            .animation(animated ? .spring(response: 0.22, dampingFraction: 0.85) : nil, value: selectedValue)
            .animation(animated ? .easeOut(duration: 0.10) : nil, value: hovered)
    }
}
