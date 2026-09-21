import AppKit
import SwiftUI
import Combine

@MainActor
final class SwitchPreferences: ObservableObject {
    static let shared = SwitchPreferences()
    nonisolated static let defaultThumbnailHeight = 130.0
    nonisolated static let defaultAppIconSize = 32.0
    nonisolated static let defaultGridColumns = 4
    nonisolated static let defaultMaxListRows = 8
    nonisolated static let defaultPickerActivationDelay = 130.0
    nonisolated static let compactThumbnailHeight = 72.0

    enum AccentChoice: String, CaseIterable, Identifiable {
        case system, rose, blue, mint, peach, lavender, monochrome
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "System"
            case .rose: return "Rose"
            case .blue: return "Blue"
            case .mint: return "Mint"
            case .peach: return "Peach"
            case .lavender: return "Lavender"
            case .monochrome: return "Mono"
            }
        }
        var color: Color {
            switch self {
            case .system: return Color.accentColor
            case .rose: return Color(red: 0.741, green: 0.514, blue: 0.467)
            case .blue: return Color(red: 0.40, green: 0.62, blue: 0.92)
            case .mint: return Color(red: 0.42, green: 0.80, blue: 0.69)
            case .peach: return Color(red: 0.98, green: 0.69, blue: 0.49)
            case .lavender: return Color(red: 0.66, green: 0.58, blue: 0.86)
            case .monochrome: return Color(white: 0.86)
            }
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    enum PickerDisplay: String, CaseIterable, Identifiable {
        case mouse, active, primary
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mouse: return "Mouse"
            case .active: return "Active"
            case .primary: return "Primary"
            }
        }
    }

    enum BackgroundBlur: String, CaseIterable, Identifiable {
        case light, medium, heavy
        var id: String { rawValue }
        var label: String {
            switch self {
            case .light: return "Light"
            case .medium: return "Medium"
            case .heavy: return "Heavy"
            }
        }
        var material: Material {
            switch self {
            case .light: return .ultraThinMaterial
            case .medium: return .regularMaterial
            case .heavy: return .ultraThickMaterial
            }
        }
        var nsMaterial: NSVisualEffectView.Material {
            switch self {
            case .light: return .hudWindow
            case .medium: return .popover
            case .heavy: return .underWindowBackground
            }
        }
    }

    @Published var accent: AccentChoice {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: accentKey) }
    }

    @Published var backgroundBlur: BackgroundBlur {
        didSet { UserDefaults.standard.set(backgroundBlur.rawValue, forKey: backgroundBlurKey) }
    }

    @Published var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: appearanceKey) }
    }

    @Published var moveCursorToWindow: Bool {
        didSet { UserDefaults.standard.set(moveCursorToWindow, forKey: SwitchPreferences.moveCursorToWindowKey) }
    }

    @Published var showTitleFirst: Bool {
        didSet { UserDefaults.standard.set(showTitleFirst, forKey: showTitleFirstKey) }
    }

    @Published var showCrossSpace: Bool {
        didSet { UserDefaults.standard.set(showCrossSpace, forKey: SwitchPreferences.crossSpaceKey) }
    }

    @Published var stickyMode: Bool {
        didSet { UserDefaults.standard.set(stickyMode, forKey: SwitchPreferences.stickyModeKey) }
    }

    @Published var disableMouse: Bool {
        didSet { UserDefaults.standard.set(disableMouse, forKey: SwitchPreferences.disableMouseKey) }
    }

    @Published var disableAnimations: Bool {
        didSet { UserDefaults.standard.set(disableAnimations, forKey: disableAnimationsKey) }
    }

    @Published var verticalList: Bool {
        didSet { UserDefaults.standard.set(verticalList, forKey: SwitchPreferences.verticalListKey) }
    }

    @Published var blacklist: Set<String> {
        didSet { UserDefaults.standard.set(Array(blacklist), forKey: SwitchPreferences.blacklistKey) }
    }

    @Published var titleExclusions: [String] {
        didSet { UserDefaults.standard.set(titleExclusions, forKey: SwitchPreferences.titleExclusionsKey) }
    }

    @Published var mruMixSpaces: Bool {
        didSet { UserDefaults.standard.set(mruMixSpaces, forKey: mruMixSpacesKey) }
    }

    @Published var staticOrder: Bool {
        didSet { UserDefaults.standard.set(staticOrder, forKey: SwitchPreferences.staticOrderKey) }
    }

    @Published var appOrder: [String] {
        didSet { UserDefaults.standard.set(appOrder, forKey: SwitchPreferences.appOrderKey) }
    }

    @Published var includeWindowlessApps: Bool {
        didSet { UserDefaults.standard.set(includeWindowlessApps, forKey: SwitchPreferences.includeWindowlessKey) }
    }

    @Published var hideMenuBarIcon: Bool {
        didSet { UserDefaults.standard.set(hideMenuBarIcon, forKey: SwitchPreferences.hideMenuBarIconKey) }
    }

    @Published var showThumbnails: Bool {
        didSet { UserDefaults.standard.set(showThumbnails, forKey: SwitchPreferences.showThumbnailsKey) }
    }

    @Published var showStoplights: Bool {
        didSet { UserDefaults.standard.set(showStoplights, forKey: SwitchPreferences.showStoplightsKey) }
    }

    @Published var verticalShowStoplights: Bool {
        didSet { UserDefaults.standard.set(verticalShowStoplights, forKey: SwitchPreferences.verticalShowStoplightsKey) }
    }

    @Published var verticalShowPreview: Bool {
        didSet { UserDefaults.standard.set(verticalShowPreview, forKey: SwitchPreferences.verticalShowPreviewKey) }
    }

    @Published var verticalShowHeader: Bool {
        didSet { UserDefaults.standard.set(verticalShowHeader, forKey: SwitchPreferences.verticalShowHeaderKey) }
    }

    @Published var showHintStrip: Bool {
        didSet { UserDefaults.standard.set(showHintStrip, forKey: SwitchPreferences.showHintStripKey) }
    }

    @Published var showWindowCount: Bool {
        didSet { UserDefaults.standard.set(showWindowCount, forKey: SwitchPreferences.showWindowCountKey) }
    }

    @Published var currentDisplayOnly: Bool {
        didSet { UserDefaults.standard.set(currentDisplayOnly, forKey: SwitchPreferences.currentDisplayOnlyKey) }
    }

    @Published var typeToFilter: Bool {
        didSet {
            UserDefaults.standard.set(typeToFilter, forKey: SwitchPreferences.typeToFilterKey)
            if typeToFilter && vimNavigation { vimNavigation = false }
        }
    }

    @Published var vimNavigation: Bool {
        didSet {
            UserDefaults.standard.set(vimNavigation, forKey: SwitchPreferences.vimNavigationKey)
            if vimNavigation && typeToFilter { typeToFilter = false }
        }
    }

    @Published var thumbnailHeight: Double {
        didSet { UserDefaults.standard.set(thumbnailHeight, forKey: SwitchPreferences.thumbnailHeightKey) }
    }

    @Published var appIconSize: Double {
        didSet { UserDefaults.standard.set(appIconSize, forKey: SwitchPreferences.appIconSizeKey) }
    }

    @Published var gridColumns: Int {
        didSet { UserDefaults.standard.set(gridColumns, forKey: SwitchPreferences.gridColumnsKey) }
    }

    @Published var maxListRows: Int {
        didSet { UserDefaults.standard.set(maxListRows, forKey: SwitchPreferences.maxListRowsKey) }
    }

    @Published var pinnedBundleIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(pinnedBundleIDs), forKey: SwitchPreferences.pinnedBundleIDsKey) }
    }

    @Published var pickerActivationDelay: Double {
        didSet { UserDefaults.standard.set(pickerActivationDelay, forKey: SwitchPreferences.pickerActivationDelayKey) }
    }

    @Published var shiftTapReverses: Bool {
        didSet { UserDefaults.standard.set(shiftTapReverses, forKey: SwitchPreferences.shiftTapReversesKey) }
    }

    @Published var hideMinimizedWindows: Bool {
        didSet { UserDefaults.standard.set(hideMinimizedWindows, forKey: SwitchPreferences.hideMinimizedWindowsKey) }
    }

    @Published var showNumberKeyHints: Bool {
        didSet { UserDefaults.standard.set(showNumberKeyHints, forKey: SwitchPreferences.showNumberKeyHintsKey) }
    }

    @Published var pickerDisplay: PickerDisplay {
        didSet { UserDefaults.standard.set(pickerDisplay.rawValue, forKey: SwitchPreferences.pickerDisplayKey) }
    }

    private let accentKey = "switch.accent"
    private let backgroundBlurKey = "switch.backgroundBlur"
    private let appearanceKey = "switch.appearance"
    nonisolated static let moveCursorToWindowKey = "switch.moveCursorToWindow"
    private let showTitleFirstKey = "switch.showTitleFirst"
    nonisolated static let crossSpaceKey = "switch.showCrossSpace"
    nonisolated static let stickyModeKey = "switch.stickyMode"
    nonisolated static let disableMouseKey = "switch.disableMouse"
    private let disableAnimationsKey = "switch.disableAnimations"
    nonisolated static let verticalListKey = "switch.verticalList"
    nonisolated static let blacklistKey = "switch.blacklist"
    nonisolated static let titleExclusionsKey = "switch.titleExclusions"
    private let mruMixSpacesKey = "switch.mruMixSpaces"
    nonisolated static let staticOrderKey = "switch.staticOrder"
    nonisolated static let appOrderKey = "switch.appOrder"
    nonisolated static let includeWindowlessKey = "switch.includeWindowlessApps"
    nonisolated static let hideMenuBarIconKey = "switch.hideMenuBarIcon"
    nonisolated static let showThumbnailsKey = "switch.showThumbnails"
    nonisolated static let showStoplightsKey = "switch.showStoplights"
    nonisolated static let verticalShowStoplightsKey = "switch.verticalShowStoplights"
    nonisolated static let verticalShowPreviewKey = "switch.verticalShowPreview"
    nonisolated static let verticalShowHeaderKey = "switch.verticalShowHeader"
    nonisolated static let showHintStripKey = "switch.showHintStrip"
    nonisolated static let showWindowCountKey = "switch.showWindowCount"
    nonisolated static let currentDisplayOnlyKey = "switch.currentDisplayOnly"
    nonisolated static let typeToFilterKey = "switch.typeToFilter"
    nonisolated static let vimNavigationKey = "switch.vimNavigation"
    nonisolated static let thumbnailHeightKey = "switch.thumbnailHeight"
    nonisolated static let appIconSizeKey = "switch.appIconSize"
    nonisolated static let gridColumnsKey = "switch.gridColumns"
    nonisolated static let maxListRowsKey = "switch.maxListRows"
    nonisolated static let pinnedBundleIDsKey = "switch.pinnedBundleIDs"
    nonisolated static let pickerActivationDelayKey = "switch.pickerActivationDelay"
    nonisolated static let shiftTapReversesKey = "switch.shiftTapReverses"
    nonisolated static let hideMinimizedWindowsKey = "switch.hideMinimizedWindows"
    nonisolated static let showNumberKeyHintsKey = "switch.showNumberKeyHints"
    nonisolated static let pickerDisplayKey = "switch.pickerDisplay"

    private init() {
        accent = AccentChoice(rawValue: UserDefaults.standard.string(forKey: accentKey) ?? "") ?? .system
        appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system
        moveCursorToWindow = UserDefaults.standard.bool(forKey: SwitchPreferences.moveCursorToWindowKey)
        backgroundBlur = BackgroundBlur(rawValue: UserDefaults.standard.string(forKey: backgroundBlurKey) ?? "") ?? .light
        showTitleFirst = UserDefaults.standard.bool(forKey: showTitleFirstKey)
        showCrossSpace = (UserDefaults.standard.object(forKey: SwitchPreferences.crossSpaceKey) as? Bool) ?? true
        stickyMode = UserDefaults.standard.bool(forKey: SwitchPreferences.stickyModeKey)
        disableMouse = UserDefaults.standard.bool(forKey: SwitchPreferences.disableMouseKey)
        disableAnimations = UserDefaults.standard.bool(forKey: disableAnimationsKey)
        verticalList = UserDefaults.standard.bool(forKey: SwitchPreferences.verticalListKey)
        blacklist = Set(UserDefaults.standard.stringArray(forKey: SwitchPreferences.blacklistKey) ?? [])
        titleExclusions = UserDefaults.standard.stringArray(forKey: SwitchPreferences.titleExclusionsKey) ?? []
        mruMixSpaces = (UserDefaults.standard.object(forKey: mruMixSpacesKey) as? Bool) ?? true
        staticOrder = UserDefaults.standard.bool(forKey: SwitchPreferences.staticOrderKey)
        appOrder = UserDefaults.standard.stringArray(forKey: SwitchPreferences.appOrderKey) ?? []
        includeWindowlessApps = UserDefaults.standard.bool(forKey: SwitchPreferences.includeWindowlessKey)
        hideMenuBarIcon = UserDefaults.standard.bool(forKey: SwitchPreferences.hideMenuBarIconKey)
        showThumbnails = (UserDefaults.standard.object(forKey: SwitchPreferences.showThumbnailsKey) as? Bool) ?? true
        showStoplights = (UserDefaults.standard.object(forKey: SwitchPreferences.showStoplightsKey) as? Bool) ?? true
        verticalShowStoplights = (UserDefaults.standard.object(forKey: SwitchPreferences.verticalShowStoplightsKey) as? Bool) ?? true
        verticalShowPreview = (UserDefaults.standard.object(forKey: SwitchPreferences.verticalShowPreviewKey) as? Bool) ?? true
        verticalShowHeader = (UserDefaults.standard.object(forKey: SwitchPreferences.verticalShowHeaderKey) as? Bool) ?? true
        showHintStrip = (UserDefaults.standard.object(forKey: SwitchPreferences.showHintStripKey) as? Bool) ?? true
        showWindowCount = (UserDefaults.standard.object(forKey: SwitchPreferences.showWindowCountKey) as? Bool) ?? true
        currentDisplayOnly = UserDefaults.standard.bool(forKey: SwitchPreferences.currentDisplayOnlyKey)
        let storedVimNavigation = UserDefaults.standard.bool(forKey: SwitchPreferences.vimNavigationKey)
        vimNavigation = storedVimNavigation
        typeToFilter = storedVimNavigation
            ? false
            : (UserDefaults.standard.object(forKey: SwitchPreferences.typeToFilterKey) as? Bool) ?? true
        thumbnailHeight = (UserDefaults.standard.object(forKey: SwitchPreferences.thumbnailHeightKey) as? Double) ?? Self.defaultThumbnailHeight
        appIconSize = (UserDefaults.standard.object(forKey: SwitchPreferences.appIconSizeKey) as? Double) ?? Self.defaultAppIconSize
        gridColumns = (UserDefaults.standard.object(forKey: SwitchPreferences.gridColumnsKey) as? Int) ?? Self.defaultGridColumns
        maxListRows = (UserDefaults.standard.object(forKey: SwitchPreferences.maxListRowsKey) as? Int) ?? Self.defaultMaxListRows
        pinnedBundleIDs = Set(UserDefaults.standard.stringArray(forKey: SwitchPreferences.pinnedBundleIDsKey) ?? [])
        pickerActivationDelay = (UserDefaults.standard.object(forKey: SwitchPreferences.pickerActivationDelayKey) as? Double) ?? Self.defaultPickerActivationDelay
        shiftTapReverses = UserDefaults.standard.bool(forKey: SwitchPreferences.shiftTapReversesKey)
        hideMinimizedWindows = UserDefaults.standard.bool(forKey: SwitchPreferences.hideMinimizedWindowsKey)
        showNumberKeyHints = UserDefaults.standard.bool(forKey: SwitchPreferences.showNumberKeyHintsKey)
        pickerDisplay = PickerDisplay(rawValue: UserDefaults.standard.string(forKey: SwitchPreferences.pickerDisplayKey) ?? "") ?? .mouse
    }
}
