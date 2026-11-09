import AppKit
import SwiftUI

final class SwitcherWindow: NSPanel {
    private let model: SwitchModel

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
        applyContentSize()
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

    func applyContentSize(for screen: NSScreen? = nil) {
        let fitted = SwitcherPanelSize.current(
            mode: model.mode,
            itemCount: model.filteredWindows.count,
            screen: screen
        )
        model.panelSize = CGSize(width: fitted.width, height: fitted.height)
        setContentSize(fitted)
    }

    func present() {
        // Re-asserted every present so the panel migrates across Spaces.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = SwitchPreferences.shared.disableAnimations ? .none : .default

        let screen = Self.pickerScreen()
        applyContentSize(for: screen)
        if let screen {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2
            ))
        }
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

private enum SwitcherPanelSize {
    private static let maxScreenFraction: CGFloat = 0.92

    static func current(mode: HotkeyManager.Mode, itemCount: Int, screen: NSScreen?) -> NSSize {
        let isList = UserDefaults.standard.bool(forKey: SwitchPreferences.verticalListKey)
        let widthScale = CGFloat(SwitchPreferences.clampedPanelWidthScale(
            UserDefaults.standard.object(forKey: SwitchPreferences.panelWidthScaleKey) as? Double
        ))
        let count = max(itemCount, 1)
        // Every mode sizes to the window count; a fixed panel leaves rows of empty backdrop (#134).
        let size = (mode == .spaces || isList)
            ? listSize(count: count, widthScale: widthScale, screen: screen)
            : gridSize(count: count, widthScale: widthScale, screen: screen)
        return fit(size, on: screen)
    }

    private static var hintHeight: CGFloat { SwitchPreferences.storedShowHintStrip ? 38 : 0 }

    // Whole rows only: a screen-capped height leaves a clipped row at the bottom (#132).
    private static func wholeRowsHeight(rows: Int, maxRows: Int, rowHeight: CGFloat, gap: CGFloat, chrome: CGFloat, screen: NSScreen?) -> CGFloat {
        let fitting = screen.map { Int(($0.visibleFrame.height * maxScreenFraction - chrome + gap) / (rowHeight + gap)) } ?? maxRows
        let visible = max(1, min(rows, maxRows, fitting))
        return chrome + CGFloat(visible) * rowHeight + CGFloat(visible - 1) * gap
    }

    private static func listSize(count: Int, widthScale: CGFloat, screen: NSScreen?) -> NSSize {
        let showPreview = SwitchPreferences.storedVerticalShowPreview && SwitchPreferences.storedShowThumbnails
        let height = wholeRowsHeight(
            rows: count,
            maxRows: UserDefaults.standard.read(SwitchPreferences.maxListRowsKey, default: SwitchPreferences.defaultMaxListRows),
            rowHeight: showPreview ? 62 : 48,
            gap: PickerLayout.listRowSpacing,
            chrome: PickerLayout.headerHeight + hintHeight + 20,
            screen: screen
        )
        return NSSize(width: CGFloat(SwitchPreferences.defaultListPanelWidth) * widthScale, height: max(260, height))
    }

    private static func gridSize(count: Int, widthScale: CGFloat, screen: NSScreen?) -> NSSize {
        let defaults = UserDefaults.standard
        let thumb = CGFloat(defaults.read(SwitchPreferences.thumbnailHeightKey, default: SwitchPreferences.defaultThumbnailHeight))
        let tileThumb = SwitchPreferences.storedShowThumbnails ? thumb : CGFloat(SwitchPreferences.compactThumbnailHeight)
        let configuredColumns = defaults.read(SwitchPreferences.gridColumnsKey, default: SwitchPreferences.defaultGridColumns)
        let columns = min(max(configuredColumns, 1), max(count, 3))
        let baseWidth: CGFloat = CGFloat(SwitchPreferences.defaultGridPanelWidth) * widthScale
        let horizontalPadding: CGFloat = 44
        let usable = baseWidth - horizontalPadding - CGFloat(max(configuredColumns - 1, 0)) * PickerLayout.gridSpacing
        let columnWidth = usable / CGFloat(configuredColumns)
        let width = horizontalPadding + CGFloat(columns) * columnWidth + CGFloat(max(columns - 1, 0)) * PickerLayout.gridSpacing

        let height = wholeRowsHeight(
            rows: Int(ceil(Double(count) / Double(columns))),
            maxRows: defaults.read(SwitchPreferences.maxGridRowsKey, default: SwitchPreferences.defaultMaxGridRows),
            rowHeight: tileThumb + 52,
            gap: PickerLayout.gridSpacing,
            chrome: PickerLayout.headerHeight + 16 + hintHeight,
            screen: screen
        )
        return NSSize(width: max(560, width), height: max(320, height))
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
