import CoreGraphics
import Foundation

/// In-memory most-recently-used tracking for windows.
/// Touched on any focus change, from Switch or FocusTracker. Sorted output puts most recent first.
enum WindowMRU {
    private static let lock = NSLock()
    private static var stamps: [CGWindowID: Date] = [:]

    static func touch(_ id: CGWindowID) {
        lock.lock(); defer { lock.unlock() }
        stamps[id] = Date()
    }

    /// Returns `windows` sorted by MRU descending. If `frontmost` is provided, it is pinned to position 0.
    /// Windows with no MRU stamp fall back to their original enumeration order.
    static func sorted(_ windows: [WindowInfo], frontmost: WindowInfo?) -> [WindowInfo] {
        lock.lock()
        let snapshot = stamps
        lock.unlock()

        let rest = windows.filter { $0.id != frontmost?.id }
        let originalIndex = Dictionary(uniqueKeysWithValues: windows.enumerated().map { ($1.id, $0) })
        let sorted = rest.sorted { (a, b) in
            let ta = snapshot[a.id]
            let tb = snapshot[b.id]
            switch (ta, tb) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                return (originalIndex[a.id] ?? 0) < (originalIndex[b.id] ?? 0)
            }
        }
        if let front = frontmost {
            return [front] + sorted
        }
        return sorted
    }

    static func mostRecent(in windows: [WindowInfo]) -> WindowInfo? {
        lock.lock()
        let snapshot = stamps
        lock.unlock()
        return windows
            .compactMap { w in snapshot[w.id].map { (w, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// The last focused window anywhere, listed or not: a window opened since the last sweep counts.
    static var mostRecentID: CGWindowID? {
        lock.lock(); defer { lock.unlock() }
        return stamps.max { $0.value < $1.value }?.key
    }

    /// Stamps newer than `since` survive: a window focused while the sweep ran isn't in its list yet.
    static func purge(keeping ids: Set<CGWindowID>, since: Date) {
        lock.lock(); defer { lock.unlock() }
        stamps = stamps.filter { ids.contains($0.key) || $0.value >= since }
    }
}
