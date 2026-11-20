import AppKit
import SwiftUI

struct KeyRecorderField: NSViewRepresentable {
    let initialBinding: HotkeyBinding
    /// Returns false when the binding is rejected, so the field keeps showing the saved one (#192).
    let onCapture: (HotkeyBinding) -> Bool
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
    var onCapture: ((HotkeyBinding) -> Bool)?
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

    // Through stopRecording so Ended is posted; otherwise the hotkeys stay suspended.
    deinit { stopRecording() }

    // NSEvent local monitors never see Cmd+Tab (system app switcher grabs it upstream).
    // Session tap at head fires first, swallows. keyDown only: modifier edges must reach everyone else (#211).
    private func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
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
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        if let resignToken { NotificationCenter.default.removeObserver(resignToken) }
        resignToken = nil
    }

    fileprivate func capture(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let held = event.flags.intersection(.primaryModifiers)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Bare Esc cancels; Esc with a modifier is a recordable combo (#116).
            if kc != 53 || !held.isEmpty {
                let b = HotkeyBinding(keyCode: UInt16(kc), modifiersRaw: held.rawValue)
                if self.onCapture?(b) == true { self.binding = b }
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
