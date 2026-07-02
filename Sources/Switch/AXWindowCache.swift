import AppKit
import ApplicationServices

/// Retained AX window elements keyed by CGWindowID.
///
/// Chromium-family apps return an empty kAXWindowsAttribute for windows on
/// other Spaces (their a11y tree only covers on-screen windows), so focusing a
/// fullscreen Chrome window needs an element captured earlier, while the window
/// was still on the active Space. Remote AX references stay valid for the
/// window's lifetime even after it leaves the Space. The prewarm timer keeps
/// this topped up; the query itself also nudges Chromium into enabling its
/// a11y tree.
enum AXWindowCache {
    private static let lock = NSLock()
    private static var cache: [CGWindowID: AXUIElement] = [:]

    static func store(_ element: AXUIElement, for wid: CGWindowID) {
        lock.lock()
        cache[wid] = element
        lock.unlock()
    }

    static func element(for wid: CGWindowID) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return cache[wid]
    }

    /// Drop entries whose windows no longer exist anywhere.
    static func purgeDead() {
        let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let live = Set(raw.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        lock.lock()
        cache = cache.filter { live.contains($0.key) }
        lock.unlock()
    }
}
