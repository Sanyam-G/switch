import AppKit
import ApplicationServices

/// Watches AX focused-window changes across every running app so WindowMRU
/// reflects all focus events, not just the ones Switch initiated. Without
/// this, MRU only knows about Switch-driven focus, and active-Space ordering
/// falls back to CGWindowList z-order, which clusters all of an app's
/// windows together when any one of them is raised.
/// All methods run on the main thread; not @MainActor-annotated so AppDelegate
/// can call start() from synchronous lifecycle hooks.
final class FocusTracker {
    private var observersByPID: [pid_t: AXObserver] = [:]
    private var launchToken: NSObjectProtocol?
    private var terminateToken: NSObjectProtocol?
    private var activateToken: NSObjectProtocol?

    func start() {
        for app in NSWorkspace.shared.runningApplications {
            attach(app)
        }
        let nc = NSWorkspace.shared.notificationCenter
        launchToken = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.attach(app)
        }
        terminateToken = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.detach(app.processIdentifier)
        }
        activateToken = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Retries an app whose AX wasn't ready at launch (Electron); a no-op once attached.
            self?.attach(app)
            self?.touchFocused(of: app.processIdentifier)
        }
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, observersByPID[pid] == nil, app.activationPolicy != .prohibited,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        var observer: AXObserver?
        let result = AXObserverCreate(pid, focusObserverCallback, &observer)
        guard result == .success, let observer else { return }
        let appAX = AXHelpers.appElement(for: pid)
        let added = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification].map {
            AXObserverAddNotification(observer, appAX, $0 as CFString, nil)
        }
        // Not stored on failure, so the next activation tries again.
        guard added.contains(where: { $0 == .success || $0 == .notificationAlreadyRegistered }) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observersByPID[pid] = observer
    }

    private func detach(_ pid: pid_t) {
        guard let observer = observersByPID.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Touch MRU on app activation as a backstop; AX observers don't always
    /// fire reliably immediately after an app launches, but didActivate does.
    private func touchFocused(of pid: pid_t) {
        // AX against our own process from its main thread would wait out the timeout; our windows aren't listed anyway.
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let element = AXHelpers.attribute(kAXFocusedWindowAttribute, of: AXHelpers.appElement(for: pid)),
              let id = AXHelpers.windowID(of: element as! AXUIElement) else { return }
        WindowMRU.touch(id)
    }
}

private let focusObserverCallback: AXObserverCallback = { _, element, _, _ in
    if let id = AXHelpers.windowID(of: element) {
        WindowMRU.touch(id)
    }
}
