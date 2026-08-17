import SwiftUI

struct SwitchView: View {
    @EnvironmentObject var model: SwitchModel
    @ObservedObject private var prefs = SwitchPreferences.shared
    @Namespace private var selectionNS
    @State private var hoveredID: CGWindowID?
    @State private var openMouseLocation: CGPoint = .zero
    @State private var hasMouseMovedSinceOpen = false
    @State private var lastSelectionFromMouse = false

    private func handleHover(_ isHovering: Bool, windowID: CGWindowID, index: Int) {
        guard !prefs.disableMouse else { return }
        if isHovering {
            model.pointerWindowID = windowID
        } else if model.pointerWindowID == windowID {
            model.pointerWindowID = nil
        }
        if isHovering {
            // Ignore hover until cursor has actually moved 10pt+ since panel opened.
            // Otherwise a static cursor parked over a tile hijacks the default selection.
            if !hasMouseMovedSinceOpen {
                let loc = NSEvent.mouseLocation
                let dx = loc.x - openMouseLocation.x
                let dy = loc.y - openMouseLocation.y
                if hypot(dx, dy) < 10 { return }
                hasMouseMovedSinceOpen = true
            }
            hoveredID = windowID
            if model.selected != index {
                lastSelectionFromMouse = true
                model.selected = index
            }
        } else if hoveredID == windowID {
            hoveredID = nil
        }
    }

    private func handleTap(index: Int) {
        guard !prefs.disableMouse else { return }
        lastSelectionFromMouse = true
        model.selected = index
        model.commitAndDismiss?()
    }

    private func isPinned(_ window: WindowInfo) -> Bool {
        window.bundleID.map { prefs.pinnedBundleIDs.contains($0) } ?? false
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
            Text("\(index + 1)")
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

    private var showHeader: Bool {
        isSpaceMode || !prefs.verticalList || prefs.verticalShowHeader || !model.filterText.isEmpty
    }

    private var isSpaceMode: Bool { model.mode == .spaces }
    private var animationsEnabled: Bool { !prefs.disableAnimations }

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
            if !model.filteredWindows.isEmpty {
                Text(isSpaceMode ? "\(model.filteredWindows.count) spaces" : "\(model.filteredWindows.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 26)
    }

    private var grid: some View {
        ZStack {
            let list = model.filteredWindows
            if list.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        if isSpaceMode || prefs.verticalList {
                            LazyVStack(spacing: 4) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { idx, w in
                                    listRow(window: w, index: idx)
                                        .id(w.id)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, showHeader ? 10 : 14)
                            .padding(.bottom, 10)
                        } else {
                            LazyVGrid(columns: gridColumns, spacing: 14) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { idx, w in
                                    tile(window: w, index: idx, list: list)
                                        .id(w.id)
                                }
                            }
                            .padding(.horizontal, 22)
                            .padding(.top, 4)
                            .padding(.bottom, 12)
                        }
                    }
                    .onChange(of: model.selected) { _, new in
                        // Skip auto-scroll when selection came from mouse hover;
                        // user is already looking at where they're pointing.
                        if lastSelectionFromMouse {
                            lastSelectionFromMouse = false
                            return
                        }
                        let cur = model.filteredWindows
                        guard cur.indices.contains(new) else { return }
                        withAnimation(switcherAnimation(.easeInOut(duration: 0.22))) {
                            proxy.scrollTo(cur[new].id, anchor: .center)
                        }
                    }
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
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.18))
    }

    private var navKey: String {
        if prefs.verticalList || isSpaceMode {
            return prefs.vimNavigation ? "↑↓ / jk" : "↑↓"
        }
        return prefs.vimNavigation ? "←↑↓→ / hjkl" : "←↑↓→"
    }

    private var closeKey: String {
        (prefs.stickyMode || !prefs.typeToFilter) ? "⌘W" : "⇧⌘W"
    }

    private func stoplights(for window: WindowInfo) -> some View {
        HStack(spacing: 4) {
            stoplight(color: Color(red: 1.0, green: 0.36, blue: 0.34), symbol: "xmark") {
                model.close(window)
            }
            stoplight(color: Color(red: 1.0, green: 0.74, blue: 0.20), symbol: "minus") {
                WindowMinimizer.minimize(window)
            }
            stoplight(color: Color(red: 0.30, green: 0.78, blue: 0.34), symbol: "plus") {
                WindowZoomer.zoom(window)
            }
        }
        .opacity(prefs.disableMouse ? 0 : 1)
        .allowsHitTesting(!prefs.disableMouse)
    }

    private func pinButton(for window: WindowInfo) -> some View {
        let bid = window.bundleID
        let isPinned = bid.map { prefs.pinnedBundleIDs.contains($0) } ?? false
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
        .opacity(prefs.disableMouse ? 0 : 1)
        .allowsHitTesting(!prefs.disableMouse)
    }

    private func stoplight(color: Color, symbol: String, action: @escaping () -> Void) -> some View {
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
                        .fill(Color.white.opacity(0.10))
                )
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .help(label)
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14), count: prefs.gridColumns)
    }

    private func tile(window: WindowInfo, index: Int, list: [WindowInfo]) -> some View {
        let selected = index == model.selected
        let hovered = hoveredID == window.id
        let icon = appIcon(for: window)

        return VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
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
                    if !window.isWindowless && (isPinned(window) || hovered) {
                        pinButton(for: window).padding(7)
                    }
                }
                .animation(switcherAnimation(.easeOut(duration: 0.18)), value: model.thumbnails[window.id] != nil)

                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: prefs.appIconSize, height: prefs.appIconSize)
                        .scaleEffect(selected ? 1.06 : 1.0)
                        .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 1)
                        .padding(7)
                        .animation(switcherAnimation(.spring(response: 0.20, dampingFraction: 0.82)), value: selected)
                }

                HStack(spacing: 0) {
                    Spacer()
                    VStack {
                        Spacer()
                        windowBadge(for: window).padding(7)
                    }
                }
            }

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
            .padding(.horizontal, 2)
        }
        .padding(9)
        .modifier(SelectionChrome(selected: selected, hovered: hovered, cornerRadius: 9, accent: prefs.accent.color, namespace: selectionNS, selectedValue: model.selected, animationsEnabled: animationsEnabled))
        .contentShape(Rectangle())
        .onHover { handleHover($0, windowID: window.id, index: index) }
        .onTapGesture { handleTap(index: index) }
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
            if !isSpaceMode && !window.isWindowless && (isPinned(window) || hovered) {
                pinButton(for: window)
                    .opacity(hovered ? 1 : 0.8)
            }
            if isSpaceMode {
                if window.spaceLabel == "Current" {
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
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SelectionChrome(selected: selected, hovered: hovered, cornerRadius: 8, accent: prefs.accent.color, namespace: selectionNS, selectedValue: model.selected, animationsEnabled: animationsEnabled))
        .contentShape(Rectangle())
        .onHover { handleHover($0, windowID: window.id, index: index) }
        .onTapGesture { handleTap(index: index) }
    }

    private func appIcon(for window: WindowInfo) -> NSImage? {
        let key = window.bundleID ?? "pid:\(window.pid)"
        if let cached = Self.iconCache[key] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: window.pid)?.icon else { return nil }
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
    let animationsEnabled: Bool

    private func selectionAnimation(_ animation: Animation) -> Animation? {
        animationsEnabled ? animation : nil
    }

    func body(content: Content) -> some View {
        content
            .background(
                // Clipping at the row level hides the matched-geometry fill while it slides between rows, so the rounding lives on the fills themselves (#133).
                ZStack {
                    if hovered && !selected {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    }
                    if selected {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(accent.opacity(0.22))
                            .matchedGeometryEffect(id: "selectionBG", in: namespace)
                    }
                }
            )
            .overlay(
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(accent.opacity(0.7), lineWidth: 1)
                            .matchedGeometryEffect(id: "selectionRing", in: namespace)
                    }
                }
            )
            .animation(selectionAnimation(.spring(response: 0.22, dampingFraction: 0.85)), value: selectedValue)
            .animation(selectionAnimation(.easeOut(duration: 0.10)), value: hovered)
    }
}
