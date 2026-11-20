import AppKit
import Combine
import SwiftUI

final class SwitcherWindow: NSPanel {
    private let model: SwitchModel
    private var resizeSink: AnyCancellable?

    init(model: SwitchModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let host = NSHostingView(rootView: SwitchView().environmentObject(model))
        host.wantsLayer = true
        host.layer?.cornerRadius = 12
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        contentView = host
        // The count changes under an open picker: the fresh sweep lands, ⌘W closes a row (#134).
        // The header comes and goes with the filter in a header-less list.
        resizeSink = model.$windows.map(\.count).removeDuplicates().map { _ in }
            .merge(with: model.$filterText.map(\.isEmpty).removeDuplicates().map { _ in })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, self.isVisible else { return }
                self.layout(on: self.screen)
            }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .otherMouseUp, event.buttonNumber == 2, model.visible,
           model.mode != .spaces,
           !UserDefaults.standard.bool(forKey: SwitchPreferences.disableMouseKey),
           let wid = model.pointerWindowID {
            model.closeWindow(withWindowID: wid)
            return
        }
        super.sendEvent(event)
    }

    /// Sized to the unfiltered count, so typing doesn't resize the panel on every key.
    private func layout(on screen: NSScreen?) {
        let fitted = SwitcherPanelSize.current(
            mode: model.mode,
            itemCount: model.windows.count,
            showHeader: model.showsHeader,
            screen: screen
        )
        model.panelSize = fitted
        setContentSize(fitted)
        if let screen {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2
            ))
        }
    }

    func present() {
        // Re-asserted every present so the panel migrates across Spaces.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = SwitchPreferences.shared.disableAnimations ? .none : .default
        layout(on: Self.pickerScreen())
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }

    static func pickerScreen() -> NSScreen? {
        switch SwitchPreferences.shared.pickerDisplay {
        case .mouse:
            let cursor = NSEvent.mouseLocation
            return NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) })
                ?? NSScreen.main
        case .active:
            // NSScreen.main is the screen holding the key window, not the primary display.
            return NSScreen.main
        case .primary:
            return NSScreen.screens.first
        }
    }
}

@MainActor
private enum SwitcherPanelSize {
    private static let maxScreenFraction: CGFloat = 0.92
    private static var prefs: SwitchPreferences { .shared }

    static func current(mode: HotkeyManager.Mode, itemCount: Int, showHeader: Bool, screen: NSScreen?) -> NSSize {
        let widthScale = CGFloat(SwitchPreferences.clampedPanelWidthScale(prefs.panelWidthScale))
        let count = max(itemCount, 1)
        // Every mode sizes to the window count; a fixed panel leaves rows of empty backdrop (#134).
        let header = showHeader ? PickerLayout.headerHeight : 0
        let size = (mode == .spaces || prefs.verticalList)
            ? listSize(count: count, header: header, showHeader: showHeader, widthScale: widthScale, screen: screen)
            : gridSize(count: count, header: header, widthScale: widthScale, screen: screen)
        return fit(size, on: screen)
    }

    private static var hintHeight: CGFloat { prefs.showHintStrip ? PickerLayout.hintStripHeight : 0 }

    // Whole rows only: a screen-capped height leaves a clipped row at the bottom (#132).
    // minHeight only pads when every row is visible; padding a capped panel shows part of the next row.
    private static func wholeRowsHeight(rows: Int, maxRows: Int, rowHeight: CGFloat, gap: CGFloat, chrome: CGFloat, minHeight: CGFloat, screen: NSScreen?) -> CGFloat {
        let fitting = screen.map { Int(($0.visibleFrame.height * maxScreenFraction - chrome + gap) / (rowHeight + gap)) } ?? maxRows
        let visible = max(1, min(rows, maxRows, fitting))
        let height = chrome + CGFloat(visible) * rowHeight + CGFloat(visible - 1) * gap
        return visible < rows ? height : max(minHeight, height)
    }

    private static func listSize(count: Int, header: CGFloat, showHeader: Bool, widthScale: CGFloat, screen: NSScreen?) -> NSSize {
        let height = wholeRowsHeight(
            rows: count,
            maxRows: prefs.maxListRows,
            rowHeight: PickerLayout.listRowHeight(preview: prefs.showThumbnails && prefs.verticalShowPreview, icon: prefs.appIconSize),
            gap: PickerLayout.listRowSpacing,
            chrome: header + PickerLayout.listTopPadding(showHeader: showHeader) + PickerLayout.listBottomPadding + hintHeight,
            minHeight: 260,
            screen: screen
        )
        // Floor: the default hint strip (411pt) keeps its padding and narrow rows keep room for text.
        return NSSize(width: max(460, CGFloat(SwitchPreferences.defaultListPanelWidth) * widthScale), height: height)
    }

    private static func gridSize(count: Int, header: CGFloat, widthScale: CGFloat, screen: NSScreen?) -> NSSize {
        let tileThumb = prefs.showThumbnails ? prefs.thumbnailHeight : SwitchPreferences.compactThumbnailHeight
        let configuredColumns = max(prefs.gridColumns, 1)
        let columns = PickerLayout.gridColumns(configured: configuredColumns, count: count)
        let baseWidth: CGFloat = CGFloat(SwitchPreferences.defaultGridPanelWidth) * widthScale
        let horizontalPadding = PickerLayout.gridHorizontalPadding * 2
        let usable = baseWidth - horizontalPadding - CGFloat(configuredColumns - 1) * PickerLayout.gridSpacing
        let columnWidth = usable / CGFloat(configuredColumns)
        let width = horizontalPadding + CGFloat(columns) * columnWidth + CGFloat(columns - 1) * PickerLayout.gridSpacing

        let height = wholeRowsHeight(
            rows: Int(ceil(Double(count) / Double(columns))),
            maxRows: prefs.maxGridRows,
            rowHeight: CGFloat(tileThumb) + PickerLayout.tileExtraHeight,
            gap: PickerLayout.gridSpacing,
            chrome: header + PickerLayout.gridTopPadding + PickerLayout.gridBottomPadding + hintHeight,
            minHeight: 320,
            screen: screen
        )
        return NSSize(width: max(560, width), height: height)
    }

    private static func fit(_ size: NSSize, on screen: NSScreen?) -> NSSize {
        guard let screen else { return size }
        let visible = screen.visibleFrame
        return NSSize(
            width: min(size.width, visible.width * maxScreenFraction),
            height: min(size.height, visible.height * maxScreenFraction)
        )
    }
}
