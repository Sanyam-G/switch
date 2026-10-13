import CoreGraphics
import Foundation
import Darwin

final class TrackpadGestureManager {
    var onTrackingChanged: ((Bool) -> Void)?
    var onBegin: ((HotkeyManager.Direction) -> Void)?
    var onStep: ((HotkeyManager.Direction) -> Void)?
    var onFinish: ((Bool) -> Void)?

    private struct MTPoint {
        var x: Float
        var y: Float
    }

    private struct MTVector {
        var position: MTPoint
        var velocity: MTPoint
    }

    private struct MTTouch {
        var frame: Int32
        var timestamp: Double
        var identifier: Int32
        var state: Int32
        var unknown1: Int32
        var unknown2: Int32
        var normalized: MTVector
        var size: Float
        var unknown3: Int32
        var angle: Float
        var majorAxis: Float
        var minorAxis: Float
        var millimeters: MTVector
        var unknown4: (Int32, Int32)
        var density: Float
    }

    private typealias ContactCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterCallback = @convention(c) (UnsafeMutableRawPointer?, ContactCallback) -> Void
    private typealias UnregisterCallback = @convention(c) (UnsafeMutableRawPointer?, ContactCallback) -> Void
    private typealias StartDevice = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias StopDevice = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private static let horizontalActivationDistance: Float = 0.0225
    private static let horizontalStepDistance: Float = 0.0275
    private static let verticalActivationDistance: Float = 0.045
    private static let verticalStepDistance: Float = 0.055

    /// A registration can go silently stale (observed after system gesture
    /// handling, input re-enumeration, and DarkWake): no contact frames are
    /// delivered even though the trackpad is in use. When this much time passes
    /// without frames, the registration is rebuilt on a fresh device discovery.
    private static let livenessThresholdNanos: UInt64 = 30 * 1_000_000_000
    /// Rebuild spacing doubles with each consecutive unsuccessful rebuild, capped here.
    private static let baseRestartSpacingNanos: UInt64 = 60 * 1_000_000_000
    private static let maxRestartSpacingNanos: UInt64 = 600 * 1_000_000_000
    /// MTDeviceStop tears down the device thread, and crashes inside
    /// MultitouchSupport when the teardown releases the last reference to the
    /// device: the framework then re-stops an already-stopped port. Registration
    /// therefore holds one strong reference per device for the process lifetime,
    /// so the thread-exit release never reaches zero (validated: eight live-frame
    /// cycles of unregister → 2s silence → stop with the extra reference, no
    /// crash, every subsequent registration received frames). Skipping the stop
    /// entirely is worse: abandoned device threads keep polling and eventually
    /// starve the kernel's multitouch queue for every client.
    private static let retirementDelayNanos: UInt64 = 2 * 1_000_000_000

    private static let callback: ContactCallback = { device, touches, count, _, _ in
        guard let device else { return 0 }
        registryLock.lock()
        let owner = owners[device]
        registryLock.unlock()
        owner?.handle(
            device: device,
            touches: touches?.assumingMemoryBound(to: MTTouch.self),
            count: Int(count)
        )
        return 0
    }
    private static let registryLock = NSLock()
    private static var owners: [UnsafeMutableRawPointer: TrackpadGestureManager] = [:]
    // Kept mapped for the process lifetime: dlclose while a contact callback is in
    // flight on a device thread would crash, and reloading costs nothing.
    private static var libraryHandle: UnsafeMutableRawPointer?

    private struct RetiringDevice {
        var device: UnsafeMutableRawPointer
        var unregisteredAtNanos: UInt64
    }

    private let stateLock = NSLock()
    // framework doubles as the enabled flag: while nil, contact frames are ignored.
    private var framework: UnsafeMutableRawPointer?
    private var devices: [UnsafeMutableRawPointer] = []
    private var retiringDevices: [RetiringDevice] = []
    private var registerCallback: RegisterCallback?
    private var unregisterCallback: UnregisterCallback?
    private var startDeviceCallback: StartDevice?
    private var stopDeviceCallback: StopDevice?
    private var trackingDevice: UnsafeMutableRawPointer?
    private var trackedTouchIDs: Set<Int32> = []
    private var needsTouchRebind = false
    private var initialPosition = MTPoint(x: 0, y: 0)
    private var active = false
    private var eligible = false
    private var cancelledUntilRelease = false
    private var cancelledTouchIDs: Set<Int32> = []
    private var scrollSuppressionRequested = false
    private var callbackGeneration: UInt = 0
    private var lastFrameUptime: UInt64 = 0
    private var startedAtUptime: UInt64 = 0
    private var lastRestartUptime: UInt64 = 0
    private var consecutiveRestarts: UInt = 0
    private var lastStartFailureLog: String?
    // One strong reference per discovered device, held for the process lifetime:
    // without it the device thread's exit release hits refcount zero and the
    // framework's final-release path re-stops a stopped port and crashes.
    private var keepAliveDevices: [AnyObject] = []
    /// Regression hook: when set, replaces the system-wide idle query.
    var inputIdleSecondsOverride: (() -> Double)?
    /// Regression hook: when set, replaces the rediscovery rebuild.
    var livenessRestart: (() -> Void)?

    deinit {
        stop()
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return framework != nil
    }

    /// Discard queued input and wait for the current contacts to lift before recognizing another gesture.
    func cancelCurrentGesture() {
        stateLock.lock()
        callbackGeneration &+= 1
        active = false
        eligible = false
        cancelledUntilRelease = trackingDevice != nil
        cancelledTouchIDs = trackingDevice != nil ? trackedTouchIDs : []
        setScrollSuppressionLocked(false)
        stateLock.unlock()
    }

    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        let frameworkLoaded = framework != nil
        let cachedDevices = devices
        stateLock.unlock()
        // framework != nil with no devices means a rebuild was interrupted before
        // discovery succeeded (rediscoverDevices empties the list first): fall
        // through and discover again instead of short-circuiting into nothing.
        if frameworkLoaded && !cachedDevices.isEmpty { return true }

        guard let library = Self.loadLibrary() else {
            logStartFailure("failed to load MultitouchSupport")
            return false
        }
        guard let createList: CreateList = symbol("MTDeviceCreateList", in: library),
              let register: RegisterCallback = symbol("MTRegisterContactFrameCallback", in: library),
              let unregister: UnregisterCallback = symbol("MTUnregisterContactFrameCallback", in: library),
              let startDevice: StartDevice = symbol("MTDeviceStart", in: library),
              let stopDevice: StopDevice = symbol("MTDeviceStop", in: library),
              let list = createList()?.takeRetainedValue() else {
            logStartFailure("MultitouchSupport symbols unavailable")
            return false
        }

        var discovered: [UnsafeMutableRawPointer] = []
        for index in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, index) else { continue }
            let pointer = UnsafeMutableRawPointer(mutating: device)
            keepAliveDevices.append(unsafeBitCast(pointer, to: AnyObject.self))
            discovered.append(pointer)
        }

        guard !discovered.isEmpty else {
            logStartFailure("no trackpad devices found")
            return false
        }
        stateLock.lock()
        framework = library
        devices = discovered
        registerCallback = register
        unregisterCallback = unregister
        startDeviceCallback = startDevice
        stopDeviceCallback = stopDevice
        callbackGeneration &+= 1
        startedAtUptime = DispatchTime.now().uptimeNanoseconds
        lastStartFailureLog = nil
        stateLock.unlock()
        for device in discovered {
            Self.registryLock.lock()
            Self.owners[device] = self
            Self.registryLock.unlock()
            register(device, Self.callback)
            startDevice(device, 0)
        }
        Self.log("monitoring \(discovered.count) trackpad device(s)")
        return true
    }

    /// Never dlclose: the library stays mapped for the process lifetime because
    /// dlclose while a contact callback is in flight on a device thread would crash.
    private static func loadLibrary() -> UnsafeMutableRawPointer? {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let handle = libraryHandle { return handle }
        let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
        libraryHandle = handle
        return handle
    }

    private func logStartFailure(_ message: String) {
        stateLock.lock()
        let changed = lastStartFailureLog != message
        lastStartFailureLog = message
        stateLock.unlock()
        if changed { Self.log(message) }
    }

    /// Suspend recognition: unregister the contact callbacks; the devices move to
    /// the retirement queue. framework doubling as the enabled flag means frames
    /// arriving during the unregister→stop window are ignored.
    func stop() {
        stateLock.lock()
        let currentDevices = devices
        let unregister = unregisterCallback
        let shouldCancel = active
        let wasEnabled = framework != nil
        framework = nil
        devices = []
        callbackGeneration &+= 1
        resetLocked()
        if shouldCancel {
            deliver(generation: callbackGeneration) { $0.onFinish?(false) }
        }
        stateLock.unlock()

        queueForRetirement(currentDevices, unregister: unregister)
        if wasEnabled {
            Self.log("callbacks unregistered (\(currentDevices.count) device(s) queued for retirement)")
        }
    }

    /// Full re-discovery: rebuild the registration on fresh device objects. The
    /// old ones are unregistered and retired on the delay schedule.
    func rediscoverDevices() {
        stateLock.lock()
        guard framework != nil else {
            stateLock.unlock()
            return
        }
        // A gesture left mid-flight by a dead stream must not block the rebuild.
        let now = DispatchTime.now().uptimeNanoseconds
        let reference = lastFrameUptime != 0 ? lastFrameUptime : startedAtUptime
        if reference != 0, now >= reference, now &- reference > Self.livenessThresholdNanos,
           trackingDevice != nil || active {
            resetLocked()
        }
        guard trackingDevice == nil, !active else {
            stateLock.unlock()
            return
        }
        let oldDevices = devices
        let unregister = unregisterCallback
        devices = []
        callbackGeneration &+= 1
        resetLocked()
        stateLock.unlock()

        queueForRetirement(oldDevices, unregister: unregister)
        Self.log("rediscovering trackpad devices (\(oldDevices.count) retired)")
        _ = start()
    }

    private func queueForRetirement(
        _ devicesToRetire: [UnsafeMutableRawPointer], unregister: UnregisterCallback?
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        for device in devicesToRetire {
            unregister?(device, Self.callback)
            Self.registryLock.lock()
            Self.owners.removeValue(forKey: device)
            Self.registryLock.unlock()
        }
        stateLock.lock()
        retiringDevices.append(contentsOf: devicesToRetire.map {
            RetiringDevice(device: $0, unregisteredAtNanos: now)
        })
        stateLock.unlock()
    }

    /// Stop queued devices whose callback has long finished. Called every second
    /// by the availability poll — including while monitoring is disabled, so a
    /// disable that caught live frames still retires its devices.
    private func drainRetiringDevices() {
        stateLock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let due = retiringDevices.filter { now &- $0.unregisteredAtNanos >= Self.retirementDelayNanos }
        retiringDevices.removeAll { now &- $0.unregisteredAtNanos >= Self.retirementDelayNanos }
        let stopDevice = stopDeviceCallback
        stateLock.unlock()

        for entry in due {
            stopDevice?(entry.device)
        }
        if !due.isEmpty {
            Self.log("retired \(due.count) stale device object(s)")
        }
    }

    /// Periodic self-check: if no contact frame has arrived for a while, the
    /// registration has gone stale and is rebuilt on fresh devices. A
    /// three-finger swipe produces no observable events at all — no scrolling,
    /// no pointer movement, no drag — so once the stream has delivered frames,
    /// recovery runs on its spacing alone; only a never-delivered stream (dead
    /// from launch, mouse-only desktops) still requires evidence of input.
    func performLivenessCheck() {
        drainRetiringDevices()

        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        guard framework != nil else {
            stateLock.unlock()
            return
        }
        // A stream can be dead from launch: no frame has ever arrived, so the start
        // time anchors the check instead of the last-frame time.
        let reference = lastFrameUptime != 0 ? lastFrameUptime : startedAtUptime
        // `now` was sampled before the MT thread could stamp a newer frame — skip
        // this check rather than underflowing on the age comparison.
        guard reference != 0, now >= reference else {
            stateLock.unlock()
            return
        }
        let frameAge = now &- reference
        // A gesture is only "in progress" while its frames keep flowing. When the
        // stream dies mid-gesture — which a three-finger swipe tends to do — the
        // bound tracking state would otherwise block every future check.
        if frameAge > Self.livenessThresholdNanos, trackingDevice != nil || active {
            Self.log("abandoning gesture state, stream silent for \(frameAge / 1_000_000_000)s")
            resetLocked()
        }
        guard trackingDevice == nil, !active else {
            stateLock.unlock()
            return
        }
        let hasDelivered = lastFrameUptime != 0
        let restarts = consecutiveRestarts
        stateLock.unlock()
        guard frameAge > Self.livenessThresholdNanos else { return }

        let spacing = min(
            Self.baseRestartSpacingNanos << UInt64(min(Int(restarts), 4)),
            Self.maxRestartSpacingNanos
        )
        guard lastRestartUptime == 0 || now &- lastRestartUptime > spacing else { return }

        let inputActive = (inputIdleSecondsOverride?() ?? Self.systemInputIdleSeconds())
            < Double(Self.livenessThresholdNanos) / 1_000_000_000
        guard inputActive || hasDelivered else { return }

        stateLock.lock()
        lastRestartUptime = now
        consecutiveRestarts &+= 1
        stateLock.unlock()
        Self.log(String(
            format: "contact stream silent for %.0fs — rediscovering devices",
            Double(frameAge) / 1_000_000_000
        ))
        if let restart = livenessRestart {
            restart()
        } else {
            rediscoverDevices()
        }
    }

    private static func systemInputIdleSeconds() -> Double {
        [
            CGEventType.scrollWheel,      // two-finger scrolling
            CGEventType.mouseMoved,       // pointer movement
            CGEventType.leftMouseDragged
        ]
        .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
        .min() ?? .infinity
    }

    private func handle(device: UnsafeMutableRawPointer, touches: UnsafeMutablePointer<MTTouch>?, count: Int) {
        stateLock.lock()
        guard framework != nil else {
            stateLock.unlock()
            return
        }
        lastFrameUptime = DispatchTime.now().uptimeNanoseconds
        consecutiveRestarts = 0
        if count > 0 {
            Self.throttledFrameLog(count, tracking: trackingDevice != nil, active: active, cancelled: cancelledUntilRelease)
        }
        if count == 0 {
            let shouldCommit = active
            let wasTracking = trackingDevice == device
            if wasTracking { resetLocked() }
            if shouldCommit && wasTracking {
                deliver(generation: callbackGeneration) { $0.onFinish?(true) }
            }
            stateLock.unlock()
            return
        }

        guard trackingDevice == nil || trackingDevice == device else {
            stateLock.unlock()
            return
        }
        if cancelledUntilRelease {
            // The cancelled gesture's contacts are ignored until they lift. But if a
            // fully fresh set of touch IDs arrives, the lift frame was lost (contacts
            // ended while cancellation was still being processed) — treat it as a new
            // gesture instead of staying cancelled forever.
            let freshContacts = count >= 3 && touches != nil && Set(
                UnsafeBufferPointer(start: touches!, count: count).map(\.identifier)
            ).isDisjoint(with: cancelledTouchIDs)
            guard freshContacts else {
                stateLock.unlock()
                return
            }
            Self.log("cancelled gesture superseded by a fresh set of contacts")
            resetLocked()
        }
        guard count >= 3, let touches else {
            if trackingDevice == device {
                needsTouchRebind = true
                setScrollSuppressionLocked(false)
            }
            stateLock.unlock()
            return
        }

        let allTouches = Array(UnsafeBufferPointer(start: touches, count: count))
        let trackedTouches: [MTTouch]
        let rebinding = trackingDevice == device && needsTouchRebind
        if trackingDevice == nil || rebinding {
            trackedTouches = Array(allTouches.prefix(3))
            trackingDevice = device
            trackedTouchIDs = Set(trackedTouches.map(\.identifier))
            needsTouchRebind = false
        } else {
            trackedTouches = allTouches.filter { trackedTouchIDs.contains($0.identifier) }
            guard trackedTouches.count == 3 else {
                needsTouchRebind = true
                setScrollSuppressionLocked(false)
                stateLock.unlock()
                return
            }
        }
        let position = MTPoint(
            x: trackedTouches.reduce(0) { $0 + $1.normalized.position.x } / 3,
            y: trackedTouches.reduce(0) { $0 + $1.normalized.position.y } / 3
        )
        if rebinding {
            initialPosition = position
            setScrollSuppressionLocked(active)
            stateLock.unlock()
            return
        }
        if !eligible {
            initialPosition = position
            active = false
            eligible = true
            stateLock.unlock()
            return
        }

        let deltaX = position.x - initialPosition.x
        let deltaY = position.y - initialPosition.y
        let horizontalDistance = active ? Self.horizontalStepDistance : Self.horizontalActivationDistance
        let horizontalProgress = abs(deltaX) / horizontalDistance
        let direction: HotkeyManager.Direction
        if !active {
            let verticalProgress = abs(deltaY) / Self.verticalActivationDistance
            guard horizontalProgress >= 1, horizontalProgress >= verticalProgress else {
                stateLock.unlock()
                return
            }
            direction = deltaX < 0 ? .left : .right
        } else {
            let verticalProgress = abs(deltaY) / Self.verticalStepDistance
            guard max(horizontalProgress, verticalProgress) >= 1 else {
                stateLock.unlock()
                return
            }
            if horizontalProgress >= verticalProgress {
                direction = deltaX < 0 ? .left : .right
            } else {
                direction = deltaY < 0 ? .down : .up
            }
        }
        let isBeginning = !active
        active = true
        initialPosition = position
        if isBeginning {
            scrollSuppressionRequested = true
            deliver(generation: callbackGeneration) {
                $0.onBegin?(direction)
                $0.onTrackingChanged?(true)
            }
        } else {
            deliver(generation: callbackGeneration) { $0.onStep?(direction) }
        }
        stateLock.unlock()
    }

    private func setScrollSuppressionLocked(_ suppressed: Bool) {
        guard scrollSuppressionRequested != suppressed else { return }
        scrollSuppressionRequested = suppressed
        deliver(generation: callbackGeneration) { $0.onTrackingChanged?(suppressed) }
    }

    private func deliver(generation: UInt, _ action: @escaping (TrackpadGestureManager) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let current = self.callbackGeneration
            self.stateLock.unlock()
            guard current == generation else { return }
            action(self)
        }
    }

    private func resetLocked() {
        setScrollSuppressionLocked(false)
        trackingDevice = nil
        trackedTouchIDs = []
        needsTouchRebind = false
        initialPosition = MTPoint(x: 0, y: 0)
        active = false
        eligible = false
        cancelledUntilRelease = false
        cancelledTouchIDs = []
    }

    private static func log(_ message: String) {
        NSLog("Switch: trackpad \(message)")
        dbgLog(message)
    }

    /// File-based diagnostics: NSLog does not surface in the unified log for this
    /// app, and gesture failures have been invisible without this record. The pid
    /// separates app noise from regression-test noise sharing the file.
    static func dbgLog(_ message: String) {
        let line = "\(Date()) [pid \(ProcessInfo.processInfo.processIdentifier)] trackpad \(message)\n"
        if let data = line.data(using: .utf8) {
            let path = "/tmp/switch-gesture.log" as NSString
            if let fh = FileHandle(forWritingAtPath: path as String) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: path as String))
            }
        }
    }

    private static var lastFrameLogUptime: UInt64 = 0
    private static func throttledFrameLog(_ count: Int, tracking: Bool, active: Bool, cancelled: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastFrameLogUptime > 1_000_000_000 else { return }
        lastFrameLogUptime = now
        dbgLog("frames: count=\(count) tracking=\(tracking) active=\(active) cancelled=\(cancelled)")
    }

    private func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
