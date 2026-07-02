import Foundation

final class WindowStore {
    static let shared = WindowStore()

    struct Snapshot {
        let windows: WindowEnumerator.FullSnapshot
        let takenAt: Date

        var age: TimeInterval { Date().timeIntervalSince(takenAt) }
    }

    private let lock = NSLock()
    private var latest: Snapshot?
    private var inFlight = false
    private var completions: [(Snapshot) -> Void] = []

    var current: Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func refresh(_ completion: ((Snapshot) -> Void)? = nil) {
        lock.lock()
        if let completion { completions.append(completion) }
        if inFlight {
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let snap = Snapshot(windows: WindowEnumerator.fullSnapshot(), takenAt: Date())
            lock.lock()
            latest = snap
            let pending = completions
            completions = []
            inFlight = false
            lock.unlock()
            if !pending.isEmpty {
                DispatchQueue.main.async {
                    pending.forEach { $0(snap) }
                }
            }
        }
    }
}
