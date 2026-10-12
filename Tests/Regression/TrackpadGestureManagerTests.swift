extension TrackpadGestureManager {
    var cancelledUntilReleaseForRegression: Bool { cancelledUntilRelease }
    var runningForRegression: Bool { framework != nil }
    var consecutiveRestartsForRegression: UInt { consecutiveRestarts }

    func regressionAttachDevice() {
        precondition(framework == nil)
        // Own a valid dlopen handle without loading MultitouchSupport or touching real devices.
        framework = dlopen(nil, RTLD_NOW)
        precondition(framework != nil)
        devices = [UnsafeMutableRawPointer(bitPattern: 1)!]
    }

    func regressionFrame(_ ids: [Int32], x: Float, y: Float = 0.5, extraX: Float? = nil) {
        var contacts = ids.map { id in
            let point = MTPoint(x: id == 4 ? (extraX ?? x) : x, y: y)
            let vector = MTVector(position: point, velocity: MTPoint(x: 0, y: 0))
            return MTTouch(frame: 0, timestamp: 0, identifier: id, state: 4,
                           unknown1: 0, unknown2: 0, normalized: vector, size: 0,
                           unknown3: 0, angle: 0, majorAxis: 0, minorAxis: 0,
                           millimeters: vector, unknown4: (0, 0), density: 0)
        }
        contacts.withUnsafeMutableBufferPointer {
            handle(device: UnsafeMutableRawPointer(bitPattern: 1)!, touches: $0.baseAddress, count: ids.count)
        }
    }

    static func runRegressionTests() {
        let manager = TrackpadGestureManager()
        var events: [String] = []
        manager.onBegin = { events.append("begin:\($0)") }
        manager.onStep = { events.append("step:\($0)") }
        manager.onTrackingChanged = { events.append("tracking:\($0)") }
        manager.onFinish = { events.append("finish:\($0)") }
        manager.regressionAttachDevice()

        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.5, y: 0.7)
        manager.regressionFrame([1, 2], x: 0.5, y: 0.7)
        drainRegressionEvents()
        precondition(events.isEmpty, "Contacts and vertical motion must not activate or suppress scrolling")
        manager.regressionFrame([], x: 0.5)

        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        drainRegressionEvents()
        precondition(events == ["begin:right", "tracking:true"], "Begin must precede scroll suppression")
        manager.regressionFrame([1, 2], x: 0.55)
        drainRegressionEvents()
        precondition(events.last == "tracking:false", "Two-finger scrolling must resume")
        manager.regressionFrame([1, 2, 3], x: 0.8, y: 0.7)
        drainRegressionEvents()
        precondition(events.last == "tracking:true", "Rebinding resumes suppression without a jump")
        manager.regressionFrame([1, 2, 3], x: 0.84, y: 0.7)
        drainRegressionEvents()
        precondition(events.last == "step:right")
        let beforeFourthFinger = events
        manager.regressionFrame([4, 1, 2, 3], x: 0.84, y: 0.7, extraX: 0.1)
        drainRegressionEvents()
        precondition(events == beforeFourthFinger, "A fourth finger must not move the tracked centroid")
        manager.regressionFrame([1, 2, 3], x: 0.84, y: 0.6)
        manager.regressionFrame([], x: 0.84)
        drainRegressionEvents()
        precondition(Array(events.suffix(3)) == ["step:down", "tracking:false", "finish:true"])

        events = []
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        manager.cancelCurrentGesture()
        manager.regressionFrame([1, 2, 3], x: 0.65)
        manager.regressionFrame([], x: 0.65)
        drainRegressionEvents()
        precondition(events == ["tracking:false"], "Cancellation must discard queued begin/steps/commit")
        events = []
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        manager.regressionFrame([], x: 0.55)
        drainRegressionEvents()
        precondition(events == ["begin:right", "tracking:true", "tracking:false", "finish:true"],
                     "Normal lift must preserve a quick gesture's queued begin and commit")

        events = []
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        manager.stop()
        drainRegressionEvents()
        precondition(events == ["tracking:false", "finish:false"], "Stop must invalidate queued activation")
        events = []
        manager.regressionAttachDevice()
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        drainRegressionEvents()
        events = []
        manager.regressionFrame([], x: 0.55)
        manager.stop()
        drainRegressionEvents()
        precondition(!events.contains("finish:true"), "Stop must invalidate an already queued commit")
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        drainRegressionEvents()
        precondition(events.isEmpty, "Frames arriving after stop must be ignored")
        print("PASS: trackpad activation, pause/resume, fourth finger, cancellation and queued callbacks")

        // A cancelled gesture whose lift frame was lost (contacts ended while
        // cancellation was still being processed) must not wedge the manager:
        // a fully fresh set of touch IDs starts a new gesture without a count == 0 frame.
        events = []
        manager.regressionAttachDevice()
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        manager.cancelCurrentGesture()
        manager.regressionFrame([1, 2, 3], x: 0.65)
        drainRegressionEvents()
        precondition(events == ["tracking:false"],
                     "The cancelled gesture's own contacts must stay ignored until they lift")
        events = []
        manager.regressionFrame([7, 8, 9], x: 0.5)
        manager.regressionFrame([7, 8, 9], x: 0.55)
        drainRegressionEvents()
        precondition(events == ["begin:right", "tracking:true"],
                     "Fresh contacts must start a new gesture without a lift frame")
        manager.regressionFrame([], x: 0.55)
        drainRegressionEvents()

        // Liveness: a silent contact stream must rebuild the registration without
        // requiring fresh input once the stream has delivered frames before — a
        // three-finger swipe produces no observable events at all. Recent frames
        // or a gesture in progress still suppress the restart.
        events = []
        var restartCount = 0
        manager.livenessRestart = { restartCount += 1 }
        manager.inputIdleSecondsOverride = { 999 }   // no observable input at all
        manager.lastFrameUptime = DispatchTime.now().uptimeNanoseconds - 120 * 1_000_000_000
        manager.performLivenessCheck()
        precondition(restartCount == 1, "A stale delivered stream must rebuild even without observable input")
        manager.lastFrameUptime = DispatchTime.now().uptimeNanoseconds
        manager.performLivenessCheck()
        precondition(restartCount == 1, "A recent frame must suppress the restart")
        manager.inputIdleSecondsOverride = { 0 }
        events = []
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        drainRegressionEvents()
        precondition(events == ["begin:right", "tracking:true"], "Gesture must be active before the mid-gesture check")
        // A live gesture has fresh frames — the rebuild must leave it alone.
        manager.lastFrameUptime = DispatchTime.now().uptimeNanoseconds - 5 * 1_000_000_000
        manager.performLivenessCheck()
        precondition(restartCount == 1, "A gesture in progress must not be restarted")
        manager.regressionFrame([], x: 0.55)
        drainRegressionEvents()
        precondition(events == ["begin:right", "tracking:true", "tracking:false", "finish:true"],
                     "The mid-gesture contacts must still finish normally")

        // A gesture abandoned mid-flight by a dead stream (its lift frame never
        // arrived) must not block future checks: the state is dropped and the
        // rebuild proceeds.
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        drainRegressionEvents()
        precondition(events.contains("begin:right"), "Gesture must be active before the abandoned check")
        manager.lastFrameUptime = DispatchTime.now().uptimeNanoseconds - 120 * 1_000_000_000
        manager.lastRestartUptime = DispatchTime.now().uptimeNanoseconds - 300 * 1_000_000_000
        manager.performLivenessCheck()
        precondition(restartCount == 2, "An abandoned mid-gesture stream must be rebuilt")
        precondition(!manager.cancelledUntilReleaseForRegression,
                     "Abandoning a gesture must clear the tracking state")
        manager.regressionFrame([], x: 0.55)
        drainRegressionEvents()

        // Receiving frames again resets the escalation; the next silent window
        // restarts at the base spacing and persistent silence doubles it, capped.
        precondition(manager.consecutiveRestartsForRegression == 0, "Frames must reset restart escalation")
        manager.lastRestartUptime = DispatchTime.now().uptimeNanoseconds - 300 * 1_000_000_000
        manager.lastFrameUptime = DispatchTime.now().uptimeNanoseconds - 120 * 1_000_000_000
        manager.performLivenessCheck()
        precondition(restartCount == 3, "A fresh silent window restarts at the base spacing")
        manager.lastRestartUptime = DispatchTime.now().uptimeNanoseconds
        manager.lastFrameUptime = DispatchTime.now().uptimeNanoseconds - 120 * 1_000_000_000
        manager.performLivenessCheck()
        precondition(restartCount == 3, "The doubled spacing must delay the next restart")

        // A stream can be dead from launch: no frame has ever arrived, so the
        // discovery time anchors the check. Active input must trigger the rebuild;
        // a user who simply never touches the trackpad must not.
        manager.regressionFrame([], x: 0.55)
        drainRegressionEvents()
        manager.consecutiveRestarts = 0
        manager.lastFrameUptime = 0
        manager.startedAtUptime = DispatchTime.now().uptimeNanoseconds - 120 * 1_000_000_000
        manager.lastRestartUptime = DispatchTime.now().uptimeNanoseconds - 300 * 1_000_000_000
        manager.inputIdleSecondsOverride = { 999 }
        manager.performLivenessCheck()
        precondition(restartCount == 3, "No input activity must not rebuild a never-delivered stream")
        manager.inputIdleSecondsOverride = { 0 }
        manager.performLivenessCheck()
        precondition(restartCount == 4, "A stream dead since launch must rebuild while input is active")
        manager.lastFrameUptime = 0
        manager.startedAtUptime = 0
        manager.performLivenessCheck()
        precondition(restartCount == 4, "No time anchor yet must not rebuild")
        print("PASS: trackpad liveness watchdog and cancelled-gesture recovery")
    }
}
