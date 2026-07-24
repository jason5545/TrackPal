import Cocoa
import CoreGraphics
import QuartzCore

// TrackPal event signature for identifying self-generated events
private let kTrackPalEventSignature: Int64 = 0x5452504C  // "TRPL" in hex

// Private CoreDock API for Show Desktop
@_silgen_name("CoreDockSendNotification")
func CoreDockSendNotification(_ notification: CFString, _ unknown: UnsafeMutableRawPointer?) -> Void

/// Trackpad zone-based scrolling
/// - Left/Right edges: Vertical scrolling
/// - Bottom edge: Horizontal scrolling
final class TrackpadZoneScroller: @unchecked Sendable {

    static let shared = TrackpadZoneScroller()
    private static let cornerMaxMovementBeforeForce: CGFloat = 0.025

    // MARK: - Configuration

    /// Edge zone width (0.0 - 1.0, percentage of trackpad)
    var edgeZoneWidth: CGFloat = 0.15  // 15% from each edge

    /// Bottom zone height (0.0 - 1.0, percentage of trackpad)
    var bottomZoneHeight: CGFloat = 0.30  // 30% from bottom

    /// Scroll sensitivity multiplier
    var scrollMultiplier: CGFloat = 3.0

    /// Which edge to use for vertical scrolling
    var verticalEdgeMode: VerticalEdgeMode = .right

    /// Horizontal scrolling position (top or bottom)
    var horizontalPosition: HorizontalPosition = .bottom

    /// Enable middle click
    var middleClickEnabled: Bool = false

    /// Middle click zone width (percentage of trackpad center)
    var middleClickZoneWidth: CGFloat = 0.30

    /// Middle click zone height (percentage of trackpad)
    var middleClickZoneHeight: CGFloat = 0.15

    /// Enable/disable
    var isEnabled: Bool = false

    /// Acceleration curve type for scrolling
    var accelerationCurveType: AccelerationCurveType = .linear

    /// Enable corner triggers
    var cornerTriggerEnabled: Bool = false

    /// Corner trigger zone size (percentage of trackpad)
    var cornerTriggerZoneSize: CGFloat = 0.15

    /// Corner actions mapping
    var cornerActions: [ScrollZone: CornerAction] = [
        .topLeftCorner: .none,
        .topRightCorner: .none,
        .bottomLeftCorner: .none,
        .bottomRightCorner: .none
    ]

    // MARK: - Touch Filtering Configuration (Scroll2-style)

    /// Enable light touch filtering (reject barely-touching/hovering contacts)
    var filterLightTouches: Bool = true

    /// Enable large touch filtering (reject palm/wrist contacts)
    var filterLargeTouches: Bool = true

    /// Density threshold - touches below this are considered too light (hovering)
    var lightTouchDensityThreshold: Float = 0.02

    /// Major axis threshold - touches above this are considered palm/wrist
    /// Normal finger: ~7-9, palm/wrist: ~15-25+
    var largeTouchMajorAxisThreshold: Float = 15.0

    /// Minor axis threshold - touches above this are considered palm/wrist
    /// Normal finger: ~6-8, palm/wrist: ~12-20+
    var largeTouchMinorAxisThreshold: Float = 12.0

    // Touch filtering counters (for diagnostics)
    private var filteredLightTouchCount: Int = 0
    private var filteredLargeTouchCount: Int = 0

    enum VerticalEdgeMode: String, CaseIterable, LocalizedNameProvider {
        case left = "left"
        case right = "right"
        case both = "both"

        var localizedName: String {
            switch self {
            case .left: String(localized: "Left")
            case .right: String(localized: "Right")
            case .both: String(localized: "Both")
            }
        }
    }

    enum HorizontalPosition: String, CaseIterable, LocalizedNameProvider {
        case bottom = "bottom"
        case top = "top"

        var localizedName: String {
            switch self {
            case .bottom: String(localized: "Bottom")
            case .top: String(localized: "Top")
            }
        }
    }

    enum AccelerationCurveType: String, CaseIterable, LocalizedNameProvider {
        case linear = "linear"
        case quadratic = "quadratic"
        case cubic = "cubic"
        case ease = "ease"

        var localizedName: String {
            switch self {
            case .linear: String(localized: "Linear")
            case .quadratic: String(localized: "Quadratic")
            case .cubic: String(localized: "Cubic")
            case .ease: String(localized: "Ease")
            }
        }
    }

    // MARK: - State

    private var devices: [MTDeviceRef?] = []
    private var deviceCallbackContexts: [DeviceCallbackContext] = []
    // MultitouchSupport does not document whether unregister/stop drains an
    // already-running callback synchronously. Retain retired refcons for the
    // process lifetime so a late callback can fail its active-ID check safely.
    private var retiredDeviceCallbackContexts: [DeviceCallbackContext] = []
    private var activeDeviceCallbackIDs: Set<Int> = []
    private var nextDeviceCallbackID = 0
    private var touchDeviceArbitrationGate = TouchDeviceArbitrationGate()
    private var lastTouchPosition: CGPoint = .zero
    private var currentZone: ScrollZone = .none
    private var isTracking: Bool = false

    // Concurrent touch detection state
    private var currentGestureMode: GestureMode = .idle
    private var activeFingerCount: Int = 0
    private var requiresAllFingersLifted = false

    // Thread-safe flag for active zone scrolling (used by CGEventTap interceptor)
    // Using os_unfair_lock instead of NSLock to avoid deadlock from C callback threads
    private var _isActivelyScrollingInZone: Bool = false
    private var _isEvaluatingScrollCandidate: Bool = false
    private var scrollZoneLock = os_unfair_lock()

    var isActivelyScrollingInZone: Bool {
        get {
            os_unfair_lock_lock(&scrollZoneLock)
            defer { os_unfair_lock_unlock(&scrollZoneLock) }
            return _isActivelyScrollingInZone
        }
        set {
            os_unfair_lock_lock(&scrollZoneLock)
            _isActivelyScrollingInZone = newValue
            os_unfair_lock_unlock(&scrollZoneLock)
        }
    }

    var isEvaluatingScrollCandidate: Bool {
        get {
            os_unfair_lock_lock(&scrollZoneLock)
            defer { os_unfair_lock_unlock(&scrollZoneLock) }
            return _isEvaluatingScrollCandidate
        }
        set {
            os_unfair_lock_lock(&scrollZoneLock)
            _isEvaluatingScrollCandidate = newValue
            os_unfair_lock_unlock(&scrollZoneLock)
        }
    }

    // Velocity tracking for inertia
    private var lastTouchTime: Double = 0
    private var velocityHistory: [(vx: CGFloat, vy: CGFloat, time: Double)] = []
    private let velocityHistorySize = 5

    // Sub-pixel scroll accumulator (prevents truncation dead zone)
    private var scrollAccumulatorX: CGFloat = 0
    private var scrollAccumulatorY: CGFloat = 0

    // Scroll phase tracking (for CGEvent scroll phase lifecycle)
    private var hasEmittedScrollBegan: Bool = false

    // Scroll activation: determine if user really wants to scroll
    private var isScrollActivationPending: Bool = false
    private var activationOriginalZone: ScrollZone = .none  // original zone before promotion
    private var activationDeltas: [CGPoint] = []
    private var activationSampleTimestamps: [Double] = []
    private var activationDeltaAccumulator: CGPoint = .zero
    private var activationWindowStartTimestamp: Double = 0
    private var activationLastEvidenceUptime: Double?
    private var scrollIntentGate: ScrollIntentGate?
    private let minimumActivationSampleDistance: CGFloat = 0.0005
    private let minimumEvidenceActivityDistance: CGFloat = 0.00005
    private let activationEvidenceGapDeadline: Double = 0.18
    private let activationSafetyMaxSamples = 24
    private var horizontalScrollLockedUntilLift = false
    private var hasLoggedHorizontalLockSuppressionInTouch: Bool = false

    // Tap detection for middle click
    private var touchStartTime: Double = 0
    private var touchStartUptime: Double = 0
    private var touchStartPosition: CGPoint = .zero
    private var maxTouchDisplacement: CGFloat = 0
    private let tapMaxMovement: CGFloat = ForcePressActionGate.defaultMaxMovementBeforeForce
    private let forcePressMaxDuration: Double = 1.0
    private var forcePressSatisfied: Bool = false
    private var forcePressMaxForce: Float = 0
    private var forcePressSource: String = "none"
    private var forceActionTriggered: Bool = false
    private var forcePressThresholdRejected: Bool = false
    private var forceGestureDisqualified = false
    private var cornerForceWindowExpired = false
    private var isTouchEnding = false
    private var touchEndingTimestamp: Double?
    private var pendingForceEvaluation: PendingForceEvaluation?
    private let forcePressActionGate = ForcePressActionGate()
    private let cornerForcePressActionGate = ForcePressActionGate(maxMovementBeforeForce: TrackpadZoneScroller.cornerMaxMovementBeforeForce)
    private let cornerForcePressThreshold: Float = 100.0
    private let cornerForceAssistedThreshold: Float = 70.0
    private let middleClickForcePressThreshold: Float = 70.0

    // A filter spike at the physical edge should not split one contact into two
    // gestures. Three consecutive invalid frames cancel and quarantine the
    // contact until every finger has lifted.
    private var consecutiveInvalidTouchFrames = 0
    private var pretrackingInvalidTouchFrames = 0
    private let invalidTouchFramesBeforeCancellation = 3
    private var isContactQuarantinedUntilLift = false
    private var forceEvaluationSuspendedByInvalidTouch = false

    // Per-contact identity is also used to scope native click suppression.
    private var nextTouchSessionID: UInt64 = 0
    private var activeTouchSessionID: UInt64?
    private var pendingForceClickSessionID: UInt64?
    private var shouldReplayPendingPrimaryClick = false

    // Terminal telemetry. One concise record per physical contact is much more
    // useful than several unrelated threshold messages.
    private var gestureOutcome = "none"
    private var gestureInitialZone: ScrollZone = .none
    private var gesturePathX: CGFloat = 0
    private var gesturePathY: CGFloat = 0
    private var gestureNetX: CGFloat = 0
    private var gestureNetY: CGFloat = 0
    private var emittedScrollEventCount = 0
    private var emittedScrollPixelsX: Int64 = 0
    private var emittedScrollPixelsY: Int64 = 0

    private enum CornerForceRegion: String {
        case strict
        case band
    }

    private enum PendingForceTarget {
        case middleClick
        case corner(CornerForceRegion)
    }

    private struct PendingForceEvaluation {
        let target: PendingForceTarget
        var force: Float
        var sampleTimestamp: Double
        var sampleUptime: Double
    }

    enum ScrollZone {
        case none
        case leftEdge
        case rightEdge
        case bottomEdge
        case topEdge
        case middleClick
        case center
        case topLeftCorner
        case topRightCorner
        case bottomLeftCorner
        case bottomRightCorner
    }

    enum CornerAction: String, CaseIterable, LocalizedNameProvider {
        case none = "none"
        case rightClick = "rightClick"
        case missionControl = "missionControl"
        case appWindows = "appWindows"
        case showDesktop = "showDesktop"
        case launchpad = "launchpad"
        case notificationCenter = "notificationCenter"

        var localizedName: String {
            switch self {
            case .none: String(localized: "No Action")
            case .rightClick: String(localized: "Right Click")
            case .missionControl: String(localized: "Mission Control")
            case .appWindows: String(localized: "App Windows")
            case .showDesktop: String(localized: "Show Desktop")
            case .launchpad: String(localized: "Launchpad")
            case .notificationCenter: String(localized: "Notification Center")
            }
        }
    }

    /// Gesture mode for tracking single vs multi-finger state
    enum GestureMode {
        case idle           // No touch
        case singleFinger   // Single finger - TrackPal active
        case multiFinger    // Multi-finger - system gestures
    }

    // MARK: - Singleton

    private init() {}

    // MARK: - Start/Stop

    func start() {
        guard !isEnabled else { return }

        LogManager.shared.log("Starting zone scroller...")
        resetInputLifecycleForRestart()

        guard let cfArray = MTDeviceCreateList() else {
            LogManager.shared.log("MTDeviceCreateList returned nil")
            return
        }

        let count = CFArrayGetCount(cfArray)
        LogManager.shared.log("Found \(count) multitouch device(s)")

        if count == 0 {
            LogManager.shared.log("No devices found")
            return
        }

        for i in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(cfArray, i) else {
                LogManager.shared.log("Device \(i) pointer is nil")
                continue
            }
            // MTDeviceRef is void* - use UnsafeMutableRawPointer
            let device = UnsafeMutableRawPointer(mutating: rawPtr)
            devices.append(device)
            nextDeviceCallbackID &+= 1
            let callbackContext = DeviceCallbackContext(
                deviceID: nextDeviceCallbackID
            )
            deviceCallbackContexts.append(callbackContext)
            activeDeviceCallbackIDs.insert(callbackContext.deviceID)
            let callbackRefcon = Unmanaged.passUnretained(callbackContext).toOpaque()

            LogManager.shared.log("Device \(i) found, registering callback...")

            // Use the refcon variant for better compatibility
            MTRegisterContactFrameCallbackWithRefcon(device, touchCallbackWithRefcon, callbackRefcon)
            if MTDeviceSupportsForce(device) {
                MTRegisterForceCentroidCallbackWithRefcon(device, forceCentroidCallbackWithRefcon, callbackRefcon)
                LogManager.shared.log("Device \(i) supports force, registered force callback")
            } else {
                LogManager.shared.log("Device \(i) does not support force; force-gated actions unavailable")
            }
            MTDeviceStart(device, 0)
            LogManager.shared.log("Device \(i) started")
        }

        // Start scroll event interceptor
        ScrollEventInterceptor.shared.start()

        isEnabled = true
        LogManager.shared.log("Trackpad zone scrolling enabled successfully")
    }

    func stop() {
        if isTracking {
            cancelActiveScrolling(reason: "stopped")
        }

        // Stop scroll event interceptor
        ScrollEventInterceptor.shared.stop()

        guard isEnabled else {
            resetInputLifecycleForRestart()
            return
        }

        for device in devices {
            MTUnregisterContactFrameCallbackWithRefcon(
                device,
                touchCallbackWithRefcon
            )
            MTUnregisterForceCentroidCallback(device, forceCentroidCallbackWithRefcon)
            MTDeviceStop(device)
        }

        devices.removeAll()
        retiredDeviceCallbackContexts.append(contentsOf: deviceCallbackContexts)
        deviceCallbackContexts.removeAll()
        resetInputLifecycleForRestart()
        isEnabled = false
        LogManager.shared.log("Trackpad zone scrolling disabled")
    }

    /// Stop/start is also a hard physical-contact boundary. Without clearing
    /// these flags, disabling TrackPal during a multi-touch or quarantined
    /// contact can poison the first complete gesture after it is re-enabled.
    private func resetInputLifecycleForRestart() {
        activeDeviceCallbackIDs.removeAll()
        touchDeviceArbitrationGate.reset()
        currentGestureMode = .idle
        activeFingerCount = 0
        requiresAllFingersLifted = false
        isContactQuarantinedUntilLift = false
        consecutiveInvalidTouchFrames = 0
        pretrackingInvalidTouchFrames = 0
        forceEvaluationSuspendedByInvalidTouch = false
        cornerForceWindowExpired = false
        isTouchEnding = false
        touchEndingTimestamp = nil
        pendingForceEvaluation = nil
        isActivelyScrollingInZone = false
        isEvaluatingScrollCandidate = false
    }

    func isDeviceCallbackActive(deviceID: Int) -> Bool {
        activeDeviceCallbackIDs.contains(deviceID)
    }

    // MARK: - Touch Processing

    func processTouch(
        x: Float,
        y: Float,
        state: Int32,
        timestamp: Double,
        eventUptime: Double
    ) {
        let position = CGPoint(x: CGFloat(x), y: CGFloat(y))
        let chronologicalEventUptime: Double
        if isTracking,
           timestamp.isFinite,
           timestamp >= touchStartTime {
            chronologicalEventUptime = touchStartUptime
                + (timestamp - touchStartTime)
        } else {
            chronologicalEventUptime = eventUptime
        }

        // Touch states from MultitouchSupport:
        // 1 = not touching (hovering)
        // 2 = starting
        // 3 = making contact
        // 4 = touching/moving
        // 5 = moving (velocity)
        // 6 = lifting
        // 7 = released

        switch state {
        case 2, 3, 4, 5: // Touch active states
            guard !isContactQuarantinedUntilLift else { return }
            isTouchEnding = false
            touchEndingTimestamp = nil

            if !isTracking {
                isTracking = true
                lastTouchPosition = position
                lastTouchTime = timestamp
                velocityHistory.removeAll()

                // Record for tap detection
                touchStartTime = timestamp
                touchStartUptime = eventUptime
                touchStartPosition = position
                maxTouchDisplacement = 0
                forcePressSatisfied = false
                forcePressMaxForce = 0
                forcePressSource = "none"
                forceActionTriggered = false
                forcePressThresholdRejected = false
                forceGestureDisqualified = false
                cornerForceWindowExpired = false
                pendingForceEvaluation = nil
                forceEvaluationSuspendedByInvalidTouch = false
                consecutiveInvalidTouchFrames = 0
                pretrackingInvalidTouchFrames = 0

                nextTouchSessionID &+= 1
                activeTouchSessionID = nextTouchSessionID
                gestureOutcome = "pending"
                gesturePathX = 0
                gesturePathY = 0
                gestureNetX = 0
                gestureNetY = 0
                emittedScrollEventCount = 0
                emittedScrollPixelsX = 0
                emittedScrollPixelsY = 0

                let preliminaryZone = determineZone(position)
                currentZone = preliminaryZone
                gestureInitialZone = preliminaryZone
                if shouldPreemptNativePrimaryClick(for: preliminaryZone) {
                    pendingForceClickSessionID = activeTouchSessionID
                    shouldReplayPendingPrimaryClick = true
                    if let sessionID = activeTouchSessionID {
                        ScrollEventInterceptor.shared.beginPendingForceGesture(
                            token: sessionID,
                            gestureUptime: chronologicalEventUptime
                        )
                    }
                } else {
                    pendingForceClickSessionID = nil
                    shouldReplayPendingPrimaryClick = false
                }

                if isScrollZone(preliminaryZone) {
                    // Cancel any running inertia from a previous scroll direction
                    DispatchQueue.main.async { InertiaScroller.shared.stopInertia() }
                    // Normal edge scrolling does not require force.
                    isScrollActivationPending = true
                    activationOriginalZone = preliminaryZone
                    activationDeltas = []
                    activationSampleTimestamps = []
                    activationDeltaAccumulator = .zero
                    activationWindowStartTimestamp = timestamp
                    activationLastEvidenceUptime = nil
                    scrollIntentGate = makeScrollIntentGate(for: preliminaryZone)
                    isActivelyScrollingInZone = false
                    isEvaluatingScrollCandidate = true
                    LogManager.shared.log(String(format: "Gesture %llu started at (%.3f, %.3f) zone=%@ [SCROLL-PENDING]",
                                                 activeTouchSessionID ?? 0, x, y, String(describing: preliminaryZone)))
                } else if isCornerZone(preliminaryZone) {
                    // Cancel any running inertia from a previous scroll direction
                    DispatchQueue.main.async { InertiaScroller.shared.stopInertia() }
                    // Corner touches enter activation pending too:
                    // if user slides (not taps), promote to adjacent scroll zone.
                    isScrollActivationPending = true
                    activationOriginalZone = preliminaryZone
                    activationDeltas = []
                    activationSampleTimestamps = []
                    activationDeltaAccumulator = .zero
                    activationWindowStartTimestamp = timestamp
                    activationLastEvidenceUptime = nil
                    scrollIntentGate = nil
                    isActivelyScrollingInZone = false
                    isEvaluatingScrollCandidate = true
                    LogManager.shared.log(String(format: "Gesture %llu started at (%.3f, %.3f) zone=%@ [CORNER-PENDING]",
                                                 activeTouchSessionID ?? 0, x, y, String(describing: preliminaryZone)))
                } else {
                    isScrollActivationPending = false
                    scrollIntentGate = nil
                    isEvaluatingScrollCandidate = false
                    LogManager.shared.log(String(format: "Gesture %llu started at (%.3f, %.3f) zone=%@",
                                                 activeTouchSessionID ?? 0, x, y, String(describing: currentZone)))
                }
            } else {
                processTrackedMovement(
                    to: position,
                    timestamp: timestamp,
                    eventUptime: chronologicalEventUptime
                )
            }

        case 6: // Lifting; wait for the real zero-touch/released boundary.
            guard isTracking else { return }
            // MultitouchSupport can report the final physical displacement on
            // state 6. Feed it through the exact same trajectory path before
            // closing the force window, otherwise a legitimate threshold tail
            // disappears at lift.
            processTrackedMovement(
                to: position,
                timestamp: timestamp,
                eventUptime: chronologicalEventUptime
            )
            isTouchEnding = true
            touchEndingTimestamp = timestamp

        case 7: // Released / zero-touch boundary
            guard isTracking else { return }
            isTouchEnding = true
            if touchEndingTimestamp == nil {
                touchEndingTimestamp = timestamp
            }

            finalizeScrollActivationOnRelease(
                timestamp: timestamp,
                eventUptime: chronologicalEventUptime
            )

            // A force callback can arrive after the last moving frame. Commit it
            // here only after the complete touch trajectory is known.
            if !forceGestureDisqualified {
                commitPendingForceEvaluation(allowDuringRelease: true)
            }

            if currentZone == .middleClick {
                handleMiddleClickTap(endPosition: lastTouchPosition, endTime: timestamp)
            } else if isCornerZone(currentZone) {
                handleCornerTap(zone: currentZone, endPosition: lastTouchPosition, endTime: timestamp)
            } else if isScrollActivationPending && isScrollZone(currentZone) {
                LogManager.shared.log("Touch released during scroll activation pending → no scroll")
                gestureOutcome = "tap-in-scroll-zone"
            } else {
                // Send scroll phase ended event before starting inertia
                if hasEmittedScrollBegan {
                    postScrollEvent(deltaX: 0, deltaY: 0, scrollPhase: 4, momentumPhase: 0)
                }
                startInertiaIfNeeded()
            }
            resolvePendingPrimaryClick(
                replayCapturedClick: shouldReplayPendingPrimaryClick && !forceActionTriggered,
                gestureUptime: chronologicalEventUptime
            )
            resetTracking()

        default:
            break
        }
    }

    private func processTrackedMovement(
        to position: CGPoint,
        timestamp: Double,
        eventUptime: Double
    ) {
        let delta = CGPoint(
            x: position.x - lastTouchPosition.x,
            y: position.y - lastTouchPosition.y
        )
        maxTouchDisplacement = max(
            maxTouchDisplacement,
            physicalTouchDistance(from: touchStartPosition, to: position)
        )
        gesturePathX += abs(delta.x)
        gesturePathY += abs(delta.y)
        gestureNetX += delta.x
        gestureNetY += delta.y

        let wasEvaluatingScroll = isScrollActivationPending

        let dt = timestamp - lastTouchTime
        if dt > 0, !wasEvaluatingScroll {
            velocityHistory.append((
                vx: delta.x / CGFloat(dt),
                vy: delta.y / CGFloat(dt),
                time: timestamp
            ))
            if velocityHistory.count > velocityHistorySize {
                velocityHistory.removeFirst()
            }
        }

        // Scroll direction gets the first decision on this touch frame. A
        // queued force sample is committed only afterwards, using the complete
        // trajectory through this hardware timestamp.
        if wasEvaluatingScroll {
            expireCornerForceWindowIfNeeded(
                at: eventUptime,
                activationTimestamp: timestamp
            )
            if scrollActivationEvidenceHasGoneStale(at: eventUptime) {
                restartScrollActivationEvidence(at: timestamp)
            }
        }

        if isScrollActivationPending {
            var didAppendActivationSample = false
            let deltaMagnitude = physicalDeltaMagnitude(delta)

            // While no evidence exists, stationary callbacks keep the velocity
            // window anchored at the last real sensor frame. A deliberate flick
            // after a long hold is then measured from its actual onset, not from
            // the original touch-down time.
            if activationDeltas.isEmpty,
               physicalDeltaMagnitude(activationDeltaAccumulator)
                    < minimumEvidenceActivityDistance,
               activationLastEvidenceUptime == nil,
               deltaMagnitude < minimumEvidenceActivityDistance {
                activationWindowStartTimestamp = timestamp
            }

            activationDeltaAccumulator.x += delta.x
            activationDeltaAccumulator.y += delta.y
            if deltaMagnitude >= minimumEvidenceActivityDistance {
                activationLastEvidenceUptime = eventUptime
            }

            if physicalDeltaMagnitude(activationDeltaAccumulator)
                >= minimumActivationSampleDistance {
                activationDeltas.append(activationDeltaAccumulator)
                activationSampleTimestamps.append(timestamp)
                activationDeltaAccumulator = .zero
                didAppendActivationSample = true
            }

            if didAppendActivationSample {
                applyScrollIntentResult(
                    evaluateScrollIntent(),
                    eventUptime: eventUptime
                )
            }
        }

        if !forceActionTriggered,
           !forceGestureDisqualified,
           !shouldDeferPendingForceForScrollEvidence() {
            commitPendingForceEvaluation()
        }

        if !wasEvaluatingScroll && !forceActionTriggered {
            handleScroll(delta: delta, zone: currentZone)
        }

        lastTouchPosition = position
        lastTouchTime = timestamp
    }

    private func startInertiaIfNeeded() {
        guard isTracking, currentZone != .none, currentZone != .center else { return }
        guard !isScrollActivationPending else { return }
        guard hasEmittedScrollBegan else { return }
        guard !velocityHistory.isEmpty else { return }

        // Calculate average velocity from recent history
        var avgVx: CGFloat = 0
        var avgVy: CGFloat = 0
        for v in velocityHistory {
            avgVx += v.vx
            avgVy += v.vy
        }
        avgVx /= CGFloat(velocityHistory.count)
        avgVy /= CGFloat(velocityHistory.count)

        // Convert to scroll velocity based on zone
        // Natural scrolling: invert direction
        var scrollVelX: CGFloat = 0
        var scrollVelY: CGFloat = 0

        switch currentZone {
        case .leftEdge, .rightEdge:
            // Vertical scrolling - use Y velocity (inverted for natural scrolling)
            // Reduced from *50 to *20 to prevent content flying past
            scrollVelY = -avgVy * scrollMultiplier * 20
        case .bottomEdge, .topEdge:
            // Horizontal scrolling - use X velocity
            // No sign inversion: trackpad +X = screen +X (both rightward)
            // Compensate for trackpad aspect ratio (~1.6:1)
            scrollVelX = avgVx * scrollMultiplier * 20 * 1.6
        default:
            return
        }

        // Only start inertia if velocity is significant
        // Below this: finger was slow/stationary — just stop, no coast
        let minVelocityThreshold: CGFloat = 20.0

        if abs(scrollVelX) > minVelocityThreshold || abs(scrollVelY) > minVelocityThreshold {
            LogManager.shared.log(String(format: "Starting inertia vx=%.1f vy=%.1f", scrollVelX, scrollVelY))
            DispatchQueue.main.async {
                InertiaScroller.shared.startInertia(velocityX: scrollVelX, velocityY: scrollVelY)
            }
        }
    }

    func resetTracking() {
        if let sessionID = activeTouchSessionID {
            let duration = max(0, CACurrentMediaTime() - touchStartUptime)
            LogManager.shared.log(String(
                format: "Gesture %llu terminal outcome=%@ initial=%@ final=%@ duration=%.3f maxExcursion=%.4f path=(%.4f,%.4f) net=(%.4f,%.4f) force=%.1f scrollEvents=%d pixels=(%lld,%lld)",
                sessionID,
                gestureOutcome,
                String(describing: gestureInitialZone),
                String(describing: currentZone),
                duration,
                maxTouchDisplacement,
                gesturePathX,
                gesturePathY,
                gestureNetX,
                gestureNetY,
                forcePressMaxForce,
                emittedScrollEventCount,
                emittedScrollPixelsX,
                emittedScrollPixelsY
            ))
        }

        isTracking = false
        currentZone = .none
        isScrollActivationPending = false
        activationOriginalZone = .none
        activationDeltas.removeAll()
        activationSampleTimestamps.removeAll()
        activationDeltaAccumulator = .zero
        activationWindowStartTimestamp = 0
        activationLastEvidenceUptime = nil
        scrollIntentGate = nil
        velocityHistory.removeAll()
        scrollAccumulatorX = 0
        scrollAccumulatorY = 0
        hasLoggedHorizontalLockSuppressionInTouch = false
        hasEmittedScrollBegan = false
        horizontalScrollLockedUntilLift = false
        forcePressSatisfied = false
        forcePressMaxForce = 0
        forcePressSource = "none"
        forceActionTriggered = false
        forcePressThresholdRejected = false
        forceGestureDisqualified = false
        cornerForceWindowExpired = false
        isTouchEnding = false
        touchEndingTimestamp = nil
        pendingForceEvaluation = nil
        forceEvaluationSuspendedByInvalidTouch = false
        maxTouchDisplacement = 0
        consecutiveInvalidTouchFrames = 0
        pretrackingInvalidTouchFrames = 0
        activeTouchSessionID = nil
        pendingForceClickSessionID = nil
        shouldReplayPendingPrimaryClick = false
        isActivelyScrollingInZone = false
        isEvaluatingScrollCandidate = false
    }

    // MARK: - Scroll Intent Detection

    enum ScrollIntentResult {
        case activated      // Direction coherent, start scrolling
        case rejected       // Direction mismatch, demote to center
        case needMoreFrames // Too little movement, need more data
    }

    private func scrollActivationHasExpired(at _: Double) -> Bool {
        guard isScrollActivationPending else { return false }
        // A force-enabled corner may legitimately sit under the finger for most
        // of its one-second press window. Bounded tremor must not cancel the
        // action merely because the sensor produced 24 tiny samples.
        if isActiveForceCandidateCorner(activationOriginalZone),
           maxTouchDisplacement < Self.cornerMaxMovementBeforeForce {
            return false
        }
        return activationDeltas.count >= activationSafetyMaxSamples
    }

    private func scrollActivationEvidenceHasGoneStale(at now: Double) -> Bool {
        guard isScrollActivationPending,
              let activationLastEvidenceUptime else {
            return false
        }

        return max(0, now - activationLastEvidenceUptime)
            >= activationEvidenceGapDeadline
    }

    private func expireCornerForceWindowIfNeeded(
        at now: Double,
        activationTimestamp: Double
    ) {
        guard isActiveForceCandidateCorner(activationOriginalZone),
              max(0, now - touchStartUptime) >= forcePressMaxDuration,
              !hasTimelyPendingForceEvaluation() else {
            return
        }

        cornerForceWindowExpired = true
        forceGestureDisqualified = true
        pendingForceEvaluation = nil
        // The evidence accumulated while force had priority is mostly hold
        // tremor. Once that window closes, begin a clean scroll-only decision
        // with the current physical frame instead of carrying the old foldback
        // path into the 24-sample safety deadline.
        restartScrollActivationEvidence(at: activationTimestamp)
        LogManager.shared.log(
            "Corner force window expired; restarted as scroll-only candidate"
        )
    }

    /// A pause invalidates old evidence but not the user's entire contact. The
    /// next movement starts a fresh two-sample decision, so tremor followed by a
    /// deliberate slow scroll is not permanently demoted to cursor movement.
    private func restartScrollActivationEvidence(at timestamp: Double) {
        activationDeltas.removeAll()
        activationSampleTimestamps.removeAll()
        activationDeltaAccumulator = .zero
        activationWindowStartTimestamp = timestamp
        activationLastEvidenceUptime = nil
        scrollIntentGate = makeScrollIntentGate(for: activationOriginalZone)
        LogManager.shared.log("Scroll evidence window restarted after pause")
    }

    private func expireScrollActivation() {
        let isForceCorner = isActiveForceCandidateCorner(activationOriginalZone)
        if isForceCorner, !hasTimelyPendingForceEvaluation() {
            forceGestureDisqualified = true
            pendingForceEvaluation = nil
        }

        isScrollActivationPending = false
        activationDeltas.removeAll()
        activationSampleTimestamps.removeAll()
        activationDeltaAccumulator = .zero
        activationWindowStartTimestamp = 0
        isActivelyScrollingInZone = false
        isEvaluatingScrollCandidate = false
        gestureOutcome = "scroll-timeout"

        if isForceCorner {
            currentZone = activationOriginalZone
            LogManager.shared.log("Scroll timeout → restored \(activationOriginalZone)")
        } else {
            currentZone = .center
            LogManager.shared.log("Scroll timeout → center")
        }
    }

    private func applyScrollIntentResult(
        _ result: ScrollIntentResult,
        eventUptime: Double
    ) {
        switch result {
        case .activated:
            forceGestureDisqualified = true
            pendingForceEvaluation = nil
            shouldReplayPendingPrimaryClick = false
            isScrollActivationPending = false
            isActivelyScrollingInZone = true
            isEvaluatingScrollCandidate = false
            gestureOutcome = "scroll:\(currentZone)"

            let acceptedDeltas = acceptedActivationDeltasForFlush()
            seedVelocityHistoryFromActivation(acceptedDeltas: acceptedDeltas)
            for buffered in acceptedDeltas {
                handleScroll(delta: buffered, zone: currentZone)
            }
            ensureActivatedScrollEmitsAtLeastOnePixel(
                acceptedDeltas: acceptedDeltas,
                zone: currentZone
            )
            activationDeltas.removeAll()
            activationSampleTimestamps.removeAll()
            LogManager.shared.log("Scroll activated: \(currentZone)")

        case .rejected:
            let isForceCorner = isActiveForceCandidateCorner(
                activationOriginalZone
            )
            if isForceCorner {
                forceGestureDisqualified = true
                pendingForceEvaluation = nil
            }
            isScrollActivationPending = false
            activationDeltas.removeAll()
            activationSampleTimestamps.removeAll()
            isActivelyScrollingInZone = false
            isEvaluatingScrollCandidate = false
            gestureOutcome = "scroll-rejected"
            if isForceCorner {
                currentZone = activationOriginalZone
                LogManager.shared.log(
                    "Scroll rejected → restored \(activationOriginalZone) (corner tap still possible)"
                )
            } else {
                currentZone = .center
                LogManager.shared.log("Scroll rejected → center (cursor movement)")
            }

        case .needMoreFrames:
            if scrollActivationHasExpired(at: eventUptime) {
                expireScrollActivation()
            }
        }
    }

    private func finalizeScrollActivationOnRelease(
        timestamp: Double,
        eventUptime: Double
    ) {
        guard isScrollActivationPending,
              physicalDeltaMagnitude(activationDeltaAccumulator) > 0 else {
            return
        }

        let tail = ScrollIntentGate.Sample(
            dx: activationDeltaAccumulator.x,
            dy: activationDeltaAccumulator.y
        )
        guard ScrollIntentGate.releaseTailCanConfirm(
            tail,
            minimumPhysicalMagnitude: minimumActivationSampleDistance
        ) else {
            return
        }

        activationDeltas.append(activationDeltaAccumulator)
        activationSampleTimestamps.append(timestamp)
        activationDeltaAccumulator = .zero
        activationLastEvidenceUptime = eventUptime
        applyScrollIntentResult(
            evaluateScrollIntent(),
            eventUptime: eventUptime
        )
    }

    private func seedVelocityHistoryFromActivation(
        acceptedDeltas: [CGPoint]
    ) {
        velocityHistory.removeAll()
        let samples = acceptedDeltas.map {
            ScrollIntentGate.Sample(dx: $0.x, dy: $0.y)
        }
        let confirmedVelocities = ScrollIntentGate.confirmedVelocitySamples(
            samples: samples,
            timestamps: activationSampleTimestamps,
            windowStartTimestamp: activationWindowStartTimestamp
        )
        for velocity in confirmedVelocities.suffix(velocityHistorySize) {
            velocityHistory.append((
                vx: velocity.vx,
                vy: velocity.vy,
                time: velocity.time
            ))
        }
    }

    /// Evaluate scroll intent from cumulative displacement and direction. A
    /// candidate is not an activation until the pure gate says so.
    private func evaluateScrollIntent() -> ScrollIntentResult {
        guard let latestDelta = activationDeltas.last else { return .needMoreFrames }

        if isCornerZone(currentZone) {
            let adjacent = adjacentScrollZones(for: currentZone)
            var availableAxes: Set<ScrollIntentGate.Axis> = []
            if adjacent.horizontal != nil { availableAxes.insert(.horizontal) }
            if adjacent.vertical != nil { availableAxes.insert(.vertical) }

            let samples = cornerIntentSamples()
            // One callback can still be a centroid-settling jump. Even after
            // movement crosses the force cap, wait for a second physical sample
            // before committing a corner to scroll or rejection.
            guard samples.count >= 2 else { return .needMoreFrames }
            let resolution = ScrollIntentGate.resolveCorner(
                samples: samples,
                availableAxes: availableAxes,
                forceCandidateMaxExcursion: isActiveForceCandidateCorner(currentZone)
                    ? Self.cornerMaxMovementBeforeForce
                    : 0,
                measuredMaximumExcursion: maxTouchDisplacement
            )

            switch resolution {
            case .preserveForceCandidate:
                return .needMoreFrames

            case .awaitMoreScrollEvidence:
                return .needMoreFrames

            case let .reject(reason):
                if reason == .movementTargetsUnavailableAxis,
                   availableAxes.count == 1,
                   let availableAxis = availableAxes.first,
                   ScrollIntentGate.shouldAwaitUnavailableAxisRejection(
                       rawSamples: activationDeltas.map {
                           ScrollIntentGate.Sample(dx: $0.x, dy: $0.y)
                       },
                       availableAxis: availableAxis,
                       maximumSampleCount: activationSafetyMaxSamples
                   ) {
                    return .needMoreFrames
                }
                LogManager.shared.log("Corner scroll rejected: \(reason)")
                return .rejected

            case let .activate(axis):
                if activationDeltas.count < 3,
                   cornerInitialSampleContradicts(axis: axis) {
                    return .needMoreFrames
                }
                guard let promotedZone = axis == .horizontal ? adjacent.horizontal : adjacent.vertical else {
                    return .rejected
                }

                currentZone = promotedZone
                scrollIntentGate = nil
                LogManager.shared.log("Corner direction committed → \(promotedZone)")
                return .activated
            }
        }

        guard var gate = scrollIntentGate ?? makeScrollIntentGate(for: currentZone) else {
            return .rejected
        }

        let decision = gate.observe(deltaX: latestDelta.x, deltaY: latestDelta.y)
        scrollIntentGate = gate

        if decision != .pending {
            LogManager.shared.log(String(
                format: "Scroll intent %@ samples=%d net=(%.4f,%.4f) path=(%.4f,%.4f)",
                String(describing: decision),
                gate.metrics.sampleCount,
                gate.metrics.rawNetX,
                gate.metrics.rawNetY,
                gate.metrics.normalizedPathX,
                gate.metrics.pathY
            ))
        }

        return scrollIntentResult(from: decision)
    }

    private func cornerIntentSamples() -> [ScrollIntentGate.Sample] {
        activationDeltas.enumerated().map { index, delta in
            let sample = ScrollIntentGate.Sample(dx: delta.x, dy: delta.y)
            return index == 0
                ? ScrollIntentGate.winsorizedInitialSample(sample)
                : sample
        }
    }

    private func cornerInitialSampleContradicts(
        axis: ScrollIntentGate.Axis
    ) -> Bool {
        guard let first = activationDeltas.first else { return false }
        let normalizedX = abs(
            first.x * ScrollIntentGate.horizontalAspectCompensation
        )
        let vertical = abs(first.y)
        guard hypot(normalizedX, vertical)
                > ScrollIntentGate.initialSampleMaximumPhysicalMagnitude else {
            return false
        }

        switch axis {
        case .horizontal:
            return vertical > normalizedX
        case .vertical:
            return normalizedX > vertical
        }
    }

    private func acceptedActivationDeltasForFlush() -> [CGPoint] {
        if let scrollIntentGate,
           !scrollIntentGate.acceptedSamples.isEmpty {
            return scrollIntentGate.acceptedSamples.map {
                CGPoint(x: $0.dx, y: $0.dy)
            }
        }

        return cornerIntentSamples().map {
            CGPoint(x: $0.dx, y: $0.dy)
        }
    }

    private func makeScrollIntentGate(for zone: ScrollZone) -> ScrollIntentGate? {
        guard let axis = scrollAxis(for: zone) else { return nil }
        return ScrollIntentGate(
            axis: axis,
            configuration: .init(maxSamples: activationSafetyMaxSamples)
        )
    }

    private func scrollAxis(for zone: ScrollZone) -> ScrollIntentGate.Axis? {
        switch zone {
        case .bottomEdge, .topEdge:
            return .horizontal
        case .leftEdge, .rightEdge:
            return .vertical
        default:
            return nil
        }
    }

    private func scrollIntentResult(from decision: ScrollIntentGate.Decision) -> ScrollIntentResult {
        switch decision {
        case .pending:
            return .needMoreFrames
        case .activate:
            return .activated
        case .reject:
            return .rejected
        }
    }

    private func adjacentScrollZones(
        for corner: ScrollZone
    ) -> (horizontal: ScrollZone?, vertical: ScrollZone?) {
        let horizontalScrollLocked = isHorizontalScrollTemporarilyLocked()

        switch corner {
        case .bottomLeftCorner:
            return (
                (!horizontalScrollLocked && horizontalPosition == .bottom) ? .bottomEdge : nil,
                (verticalEdgeMode == .left || verticalEdgeMode == .both) ? .leftEdge : nil
            )
        case .bottomRightCorner:
            return (
                (!horizontalScrollLocked && horizontalPosition == .bottom) ? .bottomEdge : nil,
                (verticalEdgeMode == .right || verticalEdgeMode == .both) ? .rightEdge : nil
            )
        case .topLeftCorner:
            return (
                (!horizontalScrollLocked && horizontalPosition == .top) ? .topEdge : nil,
                (verticalEdgeMode == .left || verticalEdgeMode == .both) ? .leftEdge : nil
            )
        case .topRightCorner:
            return (
                (!horizontalScrollLocked && horizontalPosition == .top) ? .topEdge : nil,
                (verticalEdgeMode == .right || verticalEdgeMode == .both) ? .rightEdge : nil
            )
        default:
            return (nil, nil)
        }
    }

    /// Check if a zone is a horizontal scroll zone
    private func isHorizontalZone(_ zone: ScrollZone) -> Bool {
        switch zone {
        case .bottomEdge, .topEdge:
            return true
        default:
            return false
        }
    }

    private func isHorizontalScrollTemporarilyLocked() -> Bool {
        horizontalScrollLockedUntilLift
    }

    private func engageHorizontalScrollLockAfterRightClick() {
        horizontalScrollLockedUntilLift = true
        LogManager.shared.log("Horizontal scroll locked until the right-click contact lifts")
    }

    /// Check if a zone is a scroll zone (edges that produce scroll events)
    private func isScrollZone(_ zone: ScrollZone) -> Bool {
        switch zone {
        case .leftEdge, .rightEdge, .bottomEdge, .topEdge:
            return true
        default:
            return false
        }
    }

    // MARK: - Concurrent Touch Handling

    func acceptedPreviousFingerCount(
        deviceID: Int,
        contactGeneration: UInt64,
        touchCount: Int,
        devicePreviousFingerCount: Int,
        allowClaimNewContact: Bool = true,
        eventTimestamp: Double? = nil
    ) -> Int? {
        let isClaimingNewOwnership = touchDeviceArbitrationGate.ownerContact == nil
            && touchCount > 0
        let contact = TouchDeviceArbitrationGate.Contact(
            deviceID: deviceID,
            generation: contactGeneration
        )
        let owner = touchDeviceArbitrationGate.ownerContact
        // The callback sequencer already orders ordinary cross-device overlap.
        // While another owner is still present, omit the timestamp so the gate
        // fails closed instead of creating a deferred claim that this hot path
        // cannot replay. Once owner is nil, the timestamp still blocks a truly
        // overlapping start that arrived outside the bounded reorder window.
        let arbitrationTimestamp = touchCount == 0
            || owner == nil
            || owner == contact
            ? eventTimestamp
            : nil
        let decision = touchDeviceArbitrationGate.processTouchFrame(
            deviceID: deviceID,
            contactGeneration: contactGeneration,
            touchCount: touchCount,
            allowClaim: allowClaimNewContact,
            eventTimestamp: arbitrationTimestamp
        )
        guard decision == .accept else { return nil }
        return isClaimingNewOwnership ? 0 : devicePreviousFingerCount
    }

    func shouldAcceptForceSample(
        deviceID: Int,
        contactGeneration: UInt64
    ) -> Bool {
        touchDeviceArbitrationGate.processForce(
            deviceID: deviceID,
            contactGeneration: contactGeneration
        ) == .accept
    }

    func handleFingerCountTransition(from oldCount: Int, to newCount: Int) {
        // Once a device enters a multi-finger gesture, do not reinterpret the
        // remaining finger as a fresh TrackPal gesture. A real zero-touch frame
        // is the only reset boundary.
        if newCount > 1 {
            if oldCount == 1 && isTracking {
                cancelActiveScrolling(reason: "multi-finger")
            }
            requiresAllFingersLifted = true
            currentGestureMode = .multiFinger
            LogManager.shared.log("Single→Multi transition, cancelling scroll")
        }
        else if newCount == 0 {
            currentGestureMode = .idle
            requiresAllFingersLifted = false
        }
        else if newCount == 1 && !requiresAllFingersLifted {
            currentGestureMode = .singleFinger
        } else if newCount == 1 {
            currentGestureMode = .multiFinger
            LogManager.shared.log("Multi→Single transition ignored until all fingers lift")
        }

        activeFingerCount = newCount
    }

    func completeZeroTouchBoundary() {
        isContactQuarantinedUntilLift = false
        pretrackingInvalidTouchFrames = 0
        consecutiveInvalidTouchFrames = 0
        forceEvaluationSuspendedByInvalidTouch = false
    }

    private func cancelActiveScrolling(reason: String = "cancelled") {
        gestureOutcome = reason
        shouldReplayPendingPrimaryClick = false
        forceGestureDisqualified = true
        pendingForceEvaluation = nil
        resolvePendingPrimaryClick(replayCapturedClick: false)

        // Send scroll phase ended if we had started tracking
        if hasEmittedScrollBegan {
            postScrollEvent(deltaX: 0, deltaY: 0, scrollPhase: 4, momentumPhase: 0)
        }
        DispatchQueue.main.async {
            InertiaScroller.shared.stopInertia()
        }
        isActivelyScrollingInZone = false

        resetTracking()
    }

    func shouldProcessSingleFingerTouch() -> Bool {
        activeFingerCount == 1
            && currentGestureMode == .singleFinger
            && !requiresAllFingersLifted
    }

    // MARK: - Touch Filtering (Scroll2-style)

    enum TouchFilterResult {
        case valid
        case tooLight
        case tooLarge
    }

    /// Process touch with filtering applied. Called from the callback on main thread.
    func processFilteredTouch(
        x: Float,
        y: Float,
        state: Int32,
        timestamp: Double,
        eventUptime: Double,
        density: Float,
        majorAxis: Float,
        minorAxis: Float
    ) {
        // Density drops to 0 while lifting, so release frames bypass filtering.
        // Quarantine is cleared only at the real released/zero-touch boundary.
        if state >= 6 {
            if isTracking {
                processTouch(
                    x: x,
                    y: y,
                    state: state,
                    timestamp: timestamp,
                    eventUptime: eventUptime
                )
            }
            if state >= 7 {
                isContactQuarantinedUntilLift = false
                consecutiveInvalidTouchFrames = 0
                pretrackingInvalidTouchFrames = 0
                forceEvaluationSuspendedByInvalidTouch = false
            }
            return
        }

        guard !isContactQuarantinedUntilLift else { return }

        let result = classifyTouchValues(density: density, majorAxis: majorAxis, minorAxis: minorAxis)

        switch result {
        case .valid:
            consecutiveInvalidTouchFrames = 0
            pretrackingInvalidTouchFrames = 0
            forceEvaluationSuspendedByInvalidTouch = false
            processTouch(
                x: x,
                y: y,
                state: state,
                timestamp: timestamp,
                eventUptime: eventUptime
            )

        case .tooLight:
            filteredLightTouchCount += 1
            handleInvalidTouchFrame(
                x: x,
                y: y,
                timestamp: timestamp,
                reason: "filter-light",
                detail: String(format: "density=%.3f", density)
            )

        case .tooLarge:
            filteredLargeTouchCount += 1
            handleInvalidTouchFrame(
                x: x,
                y: y,
                timestamp: timestamp,
                reason: "filter-large",
                detail: String(format: "major=%.3f minor=%.3f", majorAxis, minorAxis)
            )
        }
    }

    private func handleInvalidTouchFrame(
        x: Float,
        y: Float,
        timestamp: Double,
        reason: String,
        detail: String
    ) {
        if isTracking {
            recordInvalidTouchTrajectory(x: x, y: y, timestamp: timestamp)
            forceEvaluationSuspendedByInvalidTouch = true
            consecutiveInvalidTouchFrames += 1

            guard consecutiveInvalidTouchFrames >= invalidTouchFramesBeforeCancellation else {
                return
            }

            LogManager.shared.log(
                "Touch cancelled after \(consecutiveInvalidTouchFrames) consecutive invalid frames (\(detail))"
            )
            isContactQuarantinedUntilLift = true
            cancelActiveScrolling(reason: reason)
            return
        }

        // A normal finger can spend several scan frames below the density
        // threshold while settling onto the pad. Before tracking starts, wait
        // for it to become valid; only palm-sized contacts earn quarantine.
        if reason == "filter-light" {
            // Palm quarantine requires consecutive large-contact evidence.
            // A light/settling frame breaks that sequence.
            pretrackingInvalidTouchFrames = 0
            return
        }

        pretrackingInvalidTouchFrames += 1
        guard pretrackingInvalidTouchFrames >= invalidTouchFramesBeforeCancellation else {
            return
        }

        isContactQuarantinedUntilLift = true
        LogManager.shared.log(
            "Contact quarantined before activation after \(pretrackingInvalidTouchFrames) invalid frames (\(detail))"
        )
    }

    private func recordInvalidTouchTrajectory(x: Float, y: Float, timestamp: Double) {
        let position = CGPoint(x: CGFloat(x), y: CGFloat(y))
        let delta = CGPoint(
            x: position.x - lastTouchPosition.x,
            y: position.y - lastTouchPosition.y
        )

        maxTouchDisplacement = max(
            maxTouchDisplacement,
            physicalTouchDistance(from: touchStartPosition, to: position)
        )
        gesturePathX += abs(delta.x)
        gesturePathY += abs(delta.y)
        gestureNetX += delta.x
        gestureNetY += delta.y
        lastTouchPosition = position
        lastTouchTime = timestamp
        activationDeltaAccumulator = .zero

        // Invalid samples are useful as trajectory boundaries but must never
        // contribute momentum or a single huge recovery delta.
        velocityHistory.removeAll()
    }

    /// Classify touch using extracted values (thread-safe, no MTTouch struct needed)
    func classifyTouchValues(density: Float, majorAxis: Float, minorAxis: Float) -> TouchFilterResult {
        // Light touch filter: reject hovering / barely touching contacts
        if filterLightTouches {
            if density < lightTouchDensityThreshold {
                return .tooLight
            }
        }

        // Large touch filter: reject palm/wrist sized contacts
        if filterLargeTouches {
            if majorAxis > largeTouchMajorAxisThreshold {
                return .tooLarge
            }
            if minorAxis > largeTouchMinorAxisThreshold {
                return .tooLarge
            }
        }

        return .valid
    }

    private func physicalTouchDistance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        physicalDeltaMagnitude(
            CGPoint(x: end.x - start.x, y: end.y - start.y)
        )
    }

    private func physicalDeltaMagnitude(_ delta: CGPoint) -> CGFloat {
        hypot(
            delta.x * ScrollIntentGate.horizontalAspectCompensation,
            delta.y
        )
    }

    func processForceCentroid(
        x _: Float,
        y _: Float,
        force: Float,
        sampleTimestamp: Double,
        sampleUptime: Double
    ) {
        guard isTracking else { return }

        // Force centroid samples are delivered on a separate event stream from
        // touch frames. Use the touch trajectory for zone/movement evidence;
        // centroid coordinates are diagnostic only and can drift at the edge.
        forcePressMaxForce = max(forcePressMaxForce, force)
        if isTouchEnding {
            guard let touchEndingTimestamp,
                  sampleTimestamp <= touchEndingTimestamp else {
                return
            }
        }
        guard !forceGestureDisqualified,
              !forceEvaluationSuspendedByInvalidTouch else {
            return
        }

        if currentZone == .middleClick && middleClickEnabled {
            if force >= middleClickForcePressThreshold {
                queuePendingForceEvaluation(
                    target: .middleClick,
                    force: force,
                    sampleTimestamp: sampleTimestamp,
                    sampleUptime: sampleUptime
                )
            }
            return
        }

        guard isActiveForceCandidateCorner(currentZone) else { return }
        guard let cornerForceRegion = cornerForceRegion(for: touchStartPosition, in: currentZone) else { return }

        let assistedThreshold: Float
        if cornerForceRegion == .strict {
            assistedThreshold = cornerForceAssistedThreshold
        } else {
            assistedThreshold = cornerForcePressThreshold
        }

        if force >= assistedThreshold {
            queuePendingForceEvaluation(
                target: .corner(cornerForceRegion),
                force: force,
                sampleTimestamp: sampleTimestamp,
                sampleUptime: sampleUptime
            )
        }
    }

    private func queuePendingForceEvaluation(
        target: PendingForceTarget,
        force: Float,
        sampleTimestamp: Double,
        sampleUptime: Double
    ) {
        let sample = PendingForceEvaluation(
            target: target,
            force: force,
            sampleTimestamp: sampleTimestamp,
            sampleUptime: sampleUptime
        )
        guard let pending = pendingForceEvaluation else {
            pendingForceEvaluation = sample
            return
        }

        // Preserve one real hardware sample. Combining a later maximum force
        // with an earlier timestamp invents a press that never existed.
        if sampleTimestamp < pending.sampleTimestamp
            || (sampleTimestamp == pending.sampleTimestamp
                && sampleUptime < pending.sampleUptime) {
            pendingForceEvaluation = sample
        }
    }

    /// When a corner has already moved far enough to be meaningful but still
    /// lacks a confirming direction sample, do not let force win the same frame.
    /// The next touch sample (or release) resolves the full trajectory first.
    private func shouldDeferPendingForceForScrollEvidence() -> Bool {
        isScrollActivationPending
            && isActiveForceCandidateCorner(activationOriginalZone)
            && !activationDeltas.isEmpty
            && maxTouchDisplacement
                >= ScrollIntentGate.initialSampleMaximumPhysicalMagnitude
    }

    private func hasTimelyPendingForceEvaluation() -> Bool {
        guard let pendingForceEvaluation else { return false }
        return max(0, pendingForceEvaluation.sampleTimestamp - touchStartTime)
            < forcePressMaxDuration
    }

    private func commitPendingForceEvaluation(allowDuringRelease: Bool = false) {
        guard let pending = pendingForceEvaluation,
              isTracking,
              !forceGestureDisqualified,
              !forceEvaluationSuspendedByInvalidTouch,
              allowDuringRelease || !isTouchEnding else {
            return
        }

        pendingForceEvaluation = nil

        // Revalidate at commit as a final barrier against callback delivery
        // reordering around state 6. A force sampled after lift cannot become a
        // corner/middle action merely because it entered the pending queue first.
        if let touchEndingTimestamp,
           pending.sampleTimestamp > touchEndingTimestamp {
            return
        }

        switch pending.target {
        case .middleClick:
            guard currentZone == .middleClick, middleClickEnabled else {
                forceGestureDisqualified = true
                return
            }
            markForcePressSatisfied(
                force: pending.force,
                standardThreshold: middleClickForcePressThreshold,
                assistedThreshold: middleClickForcePressThreshold,
                actionGate: forcePressActionGate,
                maxMovementBeforeForce: tapMaxMovement,
                sampleTimestamp: pending.sampleTimestamp
            )

        case let .corner(region):
            guard isCornerZone(currentZone),
                  cornerForceRegion(for: touchStartPosition, in: currentZone) == region else {
                forceGestureDisqualified = true
                return
            }

            let assistedThreshold = region == .strict
                ? cornerForceAssistedThreshold
                : cornerForcePressThreshold
            markForcePressSatisfied(
                force: pending.force,
                standardThreshold: cornerForcePressThreshold,
                assistedThreshold: assistedThreshold,
                actionGate: cornerForcePressActionGate,
                maxMovementBeforeForce: Self.cornerMaxMovementBeforeForce,
                sampleTimestamp: pending.sampleTimestamp,
                cornerRegion: region
            )
        }
    }

    private func markForcePressSatisfied(
        force: Float,
        standardThreshold: Float,
        assistedThreshold: Float,
        actionGate: ForcePressActionGate,
        maxMovementBeforeForce: CGFloat,
        sampleTimestamp: Double,
        cornerRegion: CornerForceRegion? = nil
    ) {
        guard !forcePressSatisfied else { return }

        let decision = actionGate.evaluateForce(
            force: force,
            standardThreshold: standardThreshold,
            assistedThreshold: assistedThreshold,
            maximumTouchExcursion: maxTouchDisplacement,
            touchDuration: max(0, sampleTimestamp - touchStartTime)
        )

        if case let .reject(reason: reason, movementBeforeForce: movementBeforeForce) = decision {
            forceGestureDisqualified = true
            if !forcePressThresholdRejected {
                forcePressThresholdRejected = true
                LogManager.shared.log(String(format: "Force action rejected: %@ movementBeforeForce=%.4f max=%.4f",
                                             reason.rawValue, movementBeforeForce, maxMovementBeforeForce))
            }
            return
        }

        forcePressSatisfied = true
        guard case let .trigger(source: triggerSource, movementBeforeForce: _) = decision else { return }
        forcePressSource = triggerSource.rawValue

        if currentZone == .middleClick && middleClickEnabled {
            forceActionTriggered = true
            shouldReplayPendingPrimaryClick = false
            gestureOutcome = "middle-click"
            LogManager.shared.log(String(format: "Middle click press accepted: source=%@ maxForce=%.1f",
                                         forcePressSource, forcePressMaxForce))
            postMiddleClickEvent()
            return
        }

        guard isCornerZone(currentZone) else { return }

        isScrollActivationPending = false
        activationDeltas.removeAll()
        activationSampleTimestamps.removeAll()
        isActivelyScrollingInZone = false
        isEvaluatingScrollCandidate = false

        let region = cornerRegion?.rawValue ?? "unknown"
        LogManager.shared.log(String(format: "Corner force press accepted: zone=%@ region=%@ source=%@ maxForce=%.1f",
                                     String(describing: currentZone), region, forcePressSource, forcePressMaxForce))

        let action = cornerActions[currentZone] ?? .none
        guard action != .none else { return }

        forceActionTriggered = true
        shouldReplayPendingPrimaryClick = false
        gestureOutcome = "corner-action:\(action.rawValue)"
        LogManager.shared.log(String(format: "Corner action accepted: zone=%@ source=%@ maxForce=%.1f",
                                     String(describing: currentZone), forcePressSource, forcePressMaxForce))
        executeCornerAction(action)
    }

    private func shouldPreemptNativePrimaryClick(for zone: ScrollZone) -> Bool {
        if zone == .middleClick {
            return middleClickEnabled
        }

        if isCornerZone(zone) {
            return isForceEnabledCorner(zone)
        }

        return false
    }

    private func isForceEnabledCorner(_ zone: ScrollZone) -> Bool {
        cornerTriggerEnabled
            && isCornerZone(zone)
            && (cornerActions[zone] ?? .none) != .none
    }

    private func isActiveForceCandidateCorner(_ zone: ScrollZone) -> Bool {
        isForceEnabledCorner(zone) && !cornerForceWindowExpired
    }

    private func resolvePendingPrimaryClick(
        replayCapturedClick: Bool,
        gestureUptime: Double? = nil
    ) {
        guard let token = pendingForceClickSessionID else { return }
        pendingForceClickSessionID = nil

        ScrollEventInterceptor.shared.finishPendingForceGesture(
            token: token,
            replayCapturedClick: replayCapturedClick,
            gestureUptime: gestureUptime
        )
    }

    private func cornerForceRegion(for position: CGPoint, in zone: ScrollZone) -> CornerForceRegion? {
        guard let corner = cornerActivationCorner(for: zone) else { return nil }

        let activationZone = CornerActivationZone(edgeSize: cornerTriggerZoneSize)
        guard activationZone.contains(position, corner: corner) else { return nil }

        return activationZone.containsStrict(position, corner: corner) ? .strict : .band
    }

    private func determineZone(_ position: CGPoint) -> ScrollZone {
        // Position is normalized: x and y are 0.0 to 1.0
        // x: 0 = left, 1 = right
        // y: 0 = bottom (near user), 1 = top (away from user)

        // Check corners first (highest priority)
        if cornerTriggerEnabled {
            if let zone = cornerZone(at: position, includeExpandedCorners: true) {
                let action = cornerActions[zone] ?? .none
                if action != .none {
                    return zone
                }
            }
            // Unassigned corners are not dead zones. They fall through to the
            // configured edge scroll candidates, where movement intent decides
            // whether scrolling should actually begin.
        }

        // Calculate middle click zone boundaries
        let middleLeft = (1.0 - middleClickZoneWidth) / 2
        let middleRight = middleLeft + middleClickZoneWidth

        // Check Middle Click zone (highest priority)
        if middleClickEnabled {
            let isInMiddleX = position.x >= middleLeft && position.x <= middleRight

            if horizontalPosition == .bottom {
                // Horizontal at bottom → Middle Click at top
                if position.y > (1.0 - middleClickZoneHeight) && isInMiddleX {
                    return .middleClick
                }
            } else {
                // Horizontal at top → Middle Click at bottom
                if position.y < middleClickZoneHeight && isInMiddleX {
                    return .middleClick
                }
            }
        }

        // When vertical and horizontal scroll zones overlap, neither axis gets
        // static priority. Route the contact through the dual-axis resolver so
        // movement direction chooses the scroll instead of making one corner
        // permanently dead for horizontal input.
        if let overlapCorner = overlappingScrollCorner(at: position) {
            return overlapCorner
        }

        // Check left edge based on mode
        if position.x < edgeZoneWidth {
            switch verticalEdgeMode {
            case .left, .both:
                return .leftEdge
            case .right:
                break // Skip left edge
            }
        }

        // Check right edge based on mode
        if position.x > (1.0 - edgeZoneWidth) {
            switch verticalEdgeMode {
            case .right, .both:
                return .rightEdge
            case .left:
                break // Skip right edge
            }
        }

        // Check horizontal scrolling zone based on position
        let horizontalScrollLocked = isHorizontalScrollTemporarilyLocked()
        if horizontalPosition == .bottom {
            if position.y < bottomZoneHeight {
                if horizontalScrollLocked {
                    LogManager.shared.log("Horizontal zone suppressed by right-click cooldown")
                    return .center
                }
                return .bottomEdge
            }
        } else {
            if position.y > (1.0 - bottomZoneHeight) {
                if horizontalScrollLocked {
                    LogManager.shared.log("Horizontal zone suppressed by right-click cooldown")
                    return .center
                }
                return .topEdge
            }
        }

        return .center
    }

    private func overlappingScrollCorner(at position: CGPoint) -> ScrollZone? {
        guard !isHorizontalScrollTemporarilyLocked() else { return nil }

        let horizontalSide: HorizontalPosition?
        switch horizontalPosition {
        case .bottom where position.y < bottomZoneHeight:
            horizontalSide = .bottom
        case .top where position.y > (1.0 - bottomZoneHeight):
            horizontalSide = .top
        default:
            horizontalSide = nil
        }
        guard let horizontalSide else { return nil }

        let isLeftEnabled = verticalEdgeMode == .left || verticalEdgeMode == .both
        let isRightEnabled = verticalEdgeMode == .right || verticalEdgeMode == .both

        if isLeftEnabled, position.x < edgeZoneWidth {
            return horizontalSide == .bottom ? .bottomLeftCorner : .topLeftCorner
        }
        if isRightEnabled, position.x > (1.0 - edgeZoneWidth) {
            return horizontalSide == .bottom ? .bottomRightCorner : .topRightCorner
        }
        return nil
    }

    private func cornerZone(
        at position: CGPoint,
        includeExpandedCorners: Bool
    ) -> ScrollZone? {
        let activationZone = CornerActivationZone(edgeSize: cornerTriggerZoneSize)

        guard let corner = activationZone.corner(
            at: position,
            includeExpandedCorners: includeExpandedCorners
        ) else {
            return nil
        }

        return scrollZone(for: corner)
    }

    private func cornerActivationCorner(
        for zone: ScrollZone
    ) -> CornerActivationZone.Corner? {
        switch zone {
        case .topLeftCorner:
            return .topLeft
        case .topRightCorner:
            return .topRight
        case .bottomLeftCorner:
            return .bottomLeft
        case .bottomRightCorner:
            return .bottomRight
        default:
            return nil
        }
    }

    private func scrollZone(
        for corner: CornerActivationZone.Corner
    ) -> ScrollZone {
        switch corner {
        case .topLeft:
            return .topLeftCorner
        case .topRight:
            return .topRightCorner
        case .bottomLeft:
            return .bottomLeftCorner
        case .bottomRight:
            return .bottomRightCorner
        }
    }

    private func applyAccelerationCurve(_ delta: CGPoint) -> CGPoint {
        switch accelerationCurveType {
        case .linear:
            return delta

        case .quadratic:
            // Quadratic: delta * |delta| - preserves sign, accelerates larger movements
            return CGPoint(
                x: delta.x * abs(delta.x),
                y: delta.y * abs(delta.y)
            )

        case .cubic:
            // Cubic: delta * delta² - even stronger acceleration for large movements
            return CGPoint(
                x: delta.x * delta.x * delta.x,
                y: delta.y * delta.y * delta.y
            )

        case .ease:
            // Smoothstep-like easing: smooth transition for small and large movements
            func smoothstep(_ x: CGFloat) -> CGFloat {
                let t = min(max(abs(x) * 10, 0), 1) // Normalize to 0-1 range
                let smooth = t * t * (3 - 2 * t)    // Smoothstep formula
                return x * (0.5 + smooth * 0.5)     // Scale factor 0.5 to 1.0
            }
            return CGPoint(
                x: smoothstep(delta.x),
                y: smoothstep(delta.y)
            )
        }
    }

    private func handleScroll(delta: CGPoint, zone: ScrollZone) {
        // Apply acceleration curve to delta
        let adjustedDelta = applyAccelerationCurve(delta)

        switch zone {
        case .leftEdge, .rightEdge:
            // Vertical scrolling - use Y delta
            // Natural scrolling: invert direction (swipe up = content moves up)
            scrollAccumulatorY += -adjustedDelta.y * scrollMultiplier * 100
            isActivelyScrollingInZone = true

        case .bottomEdge, .topEdge:
            if isHorizontalScrollTemporarilyLocked() {
                if !hasLoggedHorizontalLockSuppressionInTouch {
                    hasLoggedHorizontalLockSuppressionInTouch = true
                    LogManager.shared.log("Horizontal scroll suppressed by right-click cooldown")
                }
                isActivelyScrollingInZone = false
                return
            }
            // Horizontal scrolling - use X delta
            // Trackpad +X and screen +X both point right, so no sign inversion needed
            // (unlike vertical where trackpad +Y=up but screen +Y=down)
            // Compensate for trackpad aspect ratio (~1.6:1 width:height)
            let aspectCompensation: CGFloat = 1.6
            scrollAccumulatorX += adjustedDelta.x * scrollMultiplier * 100 * aspectCompensation
            isActivelyScrollingInZone = true

        case .center, .none, .middleClick,
             .topLeftCorner, .topRightCorner, .bottomLeftCorner, .bottomRightCorner:
            isActivelyScrollingInZone = false
            return
        }

        // Extract integer pixels from accumulator, keep fractional remainder
        let scrollX = Int32(scrollAccumulatorX)
        let scrollY = Int32(scrollAccumulatorY)
        scrollAccumulatorX -= CGFloat(scrollX)
        scrollAccumulatorY -= CGFloat(scrollY)

        guard scrollX != 0 || scrollY != 0 else { return }

        // Determine scroll phase: began on first event, changed on subsequent
        let phase: Int64 = hasEmittedScrollBegan ? 2 : 1  // 1=began, 2=changed
        hasEmittedScrollBegan = true
        emittedScrollEventCount += 1
        emittedScrollPixelsX += Int64(scrollX)
        emittedScrollPixelsY += Int64(scrollY)

        postScrollEvent(deltaX: scrollX, deltaY: scrollY, scrollPhase: phase, momentumPhase: 0)
    }

    /// A gesture that passed the intent gate must produce observable output.
    /// At 1x sensitivity (or with a nonlinear curve), a threshold-sized buffer
    /// can still truncate to zero. Emit one signed pixel and clear that axis's
    /// sub-pixel partial; subtracting the borrowed pixel would create a reverse
    /// debt that stalls later movement, especially on quadratic/cubic curves.
    private func ensureActivatedScrollEmitsAtLeastOnePixel(
        acceptedDeltas: [CGPoint],
        zone: ScrollZone
    ) {
        guard !hasEmittedScrollBegan, !acceptedDeltas.isEmpty else { return }

        let net = acceptedDeltas.reduce(into: CGPoint.zero) { partial, delta in
            partial.x += delta.x
            partial.y += delta.y
        }

        let scrollX: Int32
        let scrollY: Int32
        switch zone {
        case .leftEdge, .rightEdge:
            guard net.y != 0 else { return }
            scrollX = 0
            scrollY = net.y > 0 ? -1 : 1
            scrollAccumulatorY = 0

        case .bottomEdge, .topEdge:
            guard net.x != 0 else { return }
            scrollX = net.x > 0 ? 1 : -1
            scrollY = 0
            scrollAccumulatorX = 0

        default:
            return
        }

        hasEmittedScrollBegan = true
        emittedScrollEventCount += 1
        emittedScrollPixelsX += Int64(scrollX)
        emittedScrollPixelsY += Int64(scrollY)
        postScrollEvent(
            deltaX: scrollX,
            deltaY: scrollY,
            scrollPhase: 1,
            momentumPhase: 0
        )
    }

    /// Post a scroll wheel CGEvent with pixel-precise deltas.
    /// Phase fields are intentionally left at 0 to avoid triggering NSScrollView's
    /// responsive scrolling tracking loop, which silently drops synthetic events.
    private func postScrollEvent(deltaX: Int32, deltaY: Int32, scrollPhase: Int64, momentumPhase: Int64) {
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return }

        // Tag with TrackPal signature so interceptor won't suppress our own events
        event.setIntegerValueField(.eventSourceUserData, value: kTrackPalEventSignature)

        // Phase fields left at 0: avoids NSScrollView responsive scrolling
        // tracking loop that drops synthetic events in Preview, Catalyst, etc.
        // Field 99 = kCGScrollWheelEventScrollPhase
        // Field 123 = kCGScrollWheelEventMomentumPhase
        event.setIntegerValueField(CGEventField(rawValue: 99)!, value: 0)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: 0)

        // Mark as continuous (trackpad-style) scroll for pixel-precise deltas
        // Field 88 = kCGScrollWheelEventIsContinuous
        event.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)

        // Set pixel-level point deltas — this is what NSEvent.scrollingDeltaY/X reads
        // when hasPreciseScrollingDeltas == true (isContinuous == 1)
        // Field 96/97 = kCGScrollWheelEventPointDeltaAxis1/2
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(deltaY))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(deltaX))

        // Set line-level deltas as fallback for apps that read these
        // Field 11/12 = kCGScrollWheelEventDeltaAxis1/2
        if deltaY != 0 {
            let lineDY = deltaY > 0 ? max(Int32(1), deltaY / 10) : min(Int32(-1), deltaY / 10)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(lineDY))
        }
        if deltaX != 0 {
            let lineDX = deltaX > 0 ? max(Int32(1), deltaX / 10) : min(Int32(-1), deltaX / 10)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(lineDX))
        }

        // Zero out fixed-point deltas — not needed when PointDelta fields are set
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)

        event.post(tap: .cghidEventTap)
    }

    // MARK: - Middle Click

    private func handleMiddleClickTap(endPosition: CGPoint, endTime: Double) {
        guard !forceActionTriggered else { return }

        let duration = endTime - touchStartTime
        let movement = hypot(
            endPosition.x - touchStartPosition.x,
            endPosition.y - touchStartPosition.y
        )

        guard movement < tapMaxMovement else {
            LogManager.shared.log(String(format: "Middle click ignored: moved too far (movement=%.4f max=%.4f)",
                                         movement, tapMaxMovement))
            return
        }

        guard duration < forcePressMaxDuration else {
            LogManager.shared.log(String(format: "Middle click ignored: held too long without force (duration=%.3fs max=%.3fs maxForce=%.1f)",
                                         duration, forcePressMaxDuration, forcePressMaxForce))
            return
        }

        guard forcePressSatisfied else {
            LogManager.shared.log(String(format: "Middle click ignored: no press signal (maxForce=%.1f)", forcePressMaxForce))
            return
        }

        LogManager.shared.log(String(format: "Middle click press accepted: source=%@ maxForce=%.1f", forcePressSource, forcePressMaxForce))
        postMiddleClickEvent()
    }

    private func postMiddleClickEvent() {
        let mouseLocation = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let cgPoint = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)

        if postPairedMouseEvents(
            downType: .otherMouseDown,
            upType: .otherMouseUp,
            at: cgPoint,
            button: .center
        ) {
            LogManager.shared.log("Middle click triggered")
        }
    }

    // MARK: - Corner Triggers

    private func isCornerZone(_ zone: ScrollZone) -> Bool {
        switch zone {
        case .topLeftCorner, .topRightCorner, .bottomLeftCorner, .bottomRightCorner:
            return true
        default:
            return false
        }
    }

    private func handleCornerTap(zone: ScrollZone, endPosition: CGPoint, endTime: Double) {
        guard !forceActionTriggered else { return }

        let duration = endTime - touchStartTime
        let movement = hypot(
            endPosition.x - touchStartPosition.x,
            endPosition.y - touchStartPosition.y
        )

        // Check if it's a valid force tap (short-ish duration, minimal movement)
        guard duration < forcePressMaxDuration && movement < tapMaxMovement else {
            LogManager.shared.log(String(format: "Corner action ignored: release guard failed (zone=%@ duration=%.3fs movement=%.4f maxDuration=%.3fs maxMovement=%.4f maxForce=%.1f)",
                                         String(describing: zone), duration, movement,
                                         forcePressMaxDuration, tapMaxMovement, forcePressMaxForce))
            return
        }

        // Get the action for this corner
        let action = cornerActions[zone] ?? .none

        guard action != .none else {
            return
        }

        guard forcePressSatisfied else {
            LogManager.shared.log(String(format: "Corner action ignored: no force press (zone=%@ maxForce=%.1f)",
                                         String(describing: zone), forcePressMaxForce))
            return
        }

        LogManager.shared.log(String(format: "Corner action accepted: zone=%@ source=%@ maxForce=%.1f",
                                     String(describing: zone), forcePressSource, forcePressMaxForce))
        executeCornerAction(action)
    }

    private func postRightClickEvent() {
        let mouseLocation = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let cgPoint = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)

        _ = postPairedMouseEvents(
            downType: .rightMouseDown,
            upType: .rightMouseUp,
            at: cgPoint,
            button: .right
        )
    }

    private func executeCornerAction(_ action: CornerAction) {
        switch action {
        case .none:
            break

        case .rightClick:
            postRightClickEvent()
            engageHorizontalScrollLockAfterRightClick()
            LogManager.shared.log("Right click triggered")

        case .missionControl:
            // Use private CoreDock API
            CoreDockSendNotification("com.apple.expose.awake" as CFString, nil)
            LogManager.shared.log("Mission Control triggered")

        case .appWindows:
            // Use private CoreDock API
            CoreDockSendNotification("com.apple.expose.front.awake" as CFString, nil)
            LogManager.shared.log("App Windows triggered")

        case .showDesktop:
            // Use private CoreDock API
            CoreDockSendNotification("com.apple.showdesktop.awake" as CFString, nil)
            LogManager.shared.log("Show Desktop triggered")

        case .launchpad:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Launchpad.app"))
            LogManager.shared.log("Launchpad triggered")

        case .notificationCenter:
            // Click on the top-right corner of the screen
            clickNotificationCenter()
            LogManager.shared.log("Notification Center triggered")
        }
    }

    private func clickNotificationCenter() {
        // Click on the top-right corner of the screen (notification center area)
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame

        // Notification center is at the top-right, click near the clock area
        let clickPoint = CGPoint(x: screenFrame.maxX - 20, y: 12) // Near top-right

        _ = postPairedMouseEvents(
            downType: .leftMouseDown,
            upType: .leftMouseUp,
            at: clickPoint,
            button: .left
        )
    }
}

@discardableResult
private func postPairedMouseEvents(
    downType: CGEventType,
    upType: CGEventType,
    at location: CGPoint,
    button: CGMouseButton,
    flags: CGEventFlags = [],
    clickState: Int64 = 1
) -> Bool {
    let source = CGEventSource(stateID: .combinedSessionState)
    guard let downEvent = CGEvent(
        mouseEventSource: source,
        mouseType: downType,
        mouseCursorPosition: location,
        mouseButton: button
    ), let upEvent = CGEvent(
        mouseEventSource: source,
        mouseType: upType,
        mouseCursorPosition: location,
        mouseButton: button
    ) else {
        LogManager.shared.log("Failed to construct paired synthetic mouse events")
        return false
    }

    downEvent.flags = flags
    upEvent.flags = flags
    downEvent.setIntegerValueField(.mouseEventClickState, value: clickState)
    upEvent.setIntegerValueField(.mouseEventClickState, value: clickState)
    tagTrackPalMouseEvent(downEvent)
    tagTrackPalMouseEvent(upEvent)
    downEvent.post(tap: .cghidEventTap)
    upEvent.post(tap: .cghidEventTap)
    return true
}

private func tagTrackPalMouseEvent(_ event: CGEvent) {
    event.setIntegerValueField(.eventSourceUserData, value: kTrackPalEventSignature)
}

// MARK: - C Callback with Refcon

private func drainPendingForceSamples(
    from callbackContext: DeviceCallbackContext,
    contactGeneration: UInt64,
    throughEventTimestamp cutoffTimestamp: Double,
    into scroller: TrackpadZoneScroller
) {
    let samples = callbackContext.takePendingForceSamples(
        contactGeneration: contactGeneration,
        throughEventTimestamp: cutoffTimestamp
    )
    guard !samples.isEmpty else { return }

    let deviceID = callbackContext.deviceID
    guard scroller.shouldAcceptForceSample(
        deviceID: deviceID,
        contactGeneration: contactGeneration
    ) else {
        return
    }

    for sample in samples {
        scroller.processForceCentroid(
            x: sample.x,
            y: sample.y,
            force: sample.force,
            sampleTimestamp: sample.sampleTimestamp,
            sampleUptime: sample.sampleUptime
        )
    }
}

private func touchCallbackWithRefcon(
    device: MTDeviceRef?,
    touches: UnsafeMutablePointer<MTTouch>?,
    numTouches: Int32,
    timestamp: Double,
    frame: Int32,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let callbackContext = Unmanaged<DeviceCallbackContext>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    let callbackUptime = CACurrentMediaTime()

    let scroller = TrackpadZoneScroller.shared
    let touchCount = Int(numTouches)
    let fingerFrameState = callbackContext.replaceFingerCount(
        with: numTouches,
        eventTimestamp: timestamp,
        eventUptime: callbackUptime
    )
    let prevCount = Int(fingerFrameState.previousFingerCount)
    let contactGeneration = fingerFrameState.contactGeneration
    let deviceID = callbackContext.deviceID

    // Only process single-finger touches for zone scrolling
    if numTouches == 1 {
        guard let touches else { return }
        let touch = touches[0]
        let ts = timestamp

        // Diagnostic: log actual MTTouch values for threshold calibration
        if touch.state >= 4, callbackContext.claimTouchValueDiagnostic() {
            LogManager.shared.log(String(format: "[DIAG] Device %d MTTouch values - density=%.4f, majorAxis=%.4f, minorAxis=%.4f, size=%.4f, angle=%.4f, state=%d", deviceID, touch.density, touch.majorAxis, touch.minorAxis, touch.size, touch.angle, touch.state))
        }

        // Extract values from the touch struct BEFORE dispatching
        let x = touch.normalized.position.x
        let y = touch.normalized.position.y
        let state = touch.state
        let density = touch.density
        let majorAxis = touch.majorAxis
        let minorAxis = touch.minorAxis

        // A state-1 frame is hover, not a failed physical contact. Ignoring it
        // here lets a later state 2/3 in the same raw generation claim input
        // instead of being quarantined by the arbitration gate until zero.
        guard state != 1 else { return }

        TouchCallbackSequencer.shared.enqueue(timestamp: ts) {
            guard scroller.isDeviceCallbackActive(deviceID: deviceID) else {
                return
            }
            guard let acceptedPrevCount = scroller.acceptedPreviousFingerCount(
                deviceID: deviceID,
                contactGeneration: contactGeneration,
                touchCount: touchCount,
                devicePreviousFingerCount: prevCount,
                allowClaimNewContact: state == 2 || state == 3,
                eventTimestamp: ts
            ) else { return }

            // Handle finger count transition synchronously within main thread block
            if touchCount != acceptedPrevCount {
                scroller.handleFingerCountTransition(from: acceptedPrevCount, to: touchCount)
            }

            // Check debounce after multi→single transition
            guard scroller.shouldProcessSingleFingerTouch() else { return }

            // Existing contacts drain force before the touch frame so scroll
            // direction still gets the first commit decision on this frame.
            // A new contact establishes its zone first, then drains any force
            // sample that raced ahead of the main-queue touch block.
            if acceptedPrevCount > 0 {
                drainPendingForceSamples(
                    from: callbackContext,
                    contactGeneration: contactGeneration,
                    throughEventTimestamp: ts,
                    into: scroller
                )
            }

            // Apply touch filtering, then process
            scroller.processFilteredTouch(
                x: x, y: y, state: state, timestamp: ts,
                eventUptime: callbackUptime,
                density: density, majorAxis: majorAxis, minorAxis: minorAxis
            )

            if acceptedPrevCount == 0 {
                drainPendingForceSamples(
                    from: callbackContext,
                    contactGeneration: contactGeneration,
                    throughEventTimestamp: ts,
                    into: scroller
                )
            }
        }
    } else if numTouches == 0 {
        let ts = timestamp
        TouchCallbackSequencer.shared.enqueue(timestamp: ts) {
            guard scroller.isDeviceCallbackActive(deviceID: deviceID) else {
                return
            }
            // Drain samples captured before the physical zero boundary while
            // this contact still owns the arbitration gate.
            drainPendingForceSamples(
                from: callbackContext,
                contactGeneration: contactGeneration,
                throughEventTimestamp: ts,
                into: scroller
            )
            callbackContext.discardPendingForceSamples(
                contactGeneration: contactGeneration
            )

            guard let acceptedPrevCount = scroller.acceptedPreviousFingerCount(
                deviceID: deviceID,
                contactGeneration: contactGeneration,
                touchCount: touchCount,
                devicePreviousFingerCount: prevCount,
                eventTimestamp: ts
            ) else { return }

            if touchCount != acceptedPrevCount {
                scroller.handleFingerCountTransition(from: acceptedPrevCount, to: touchCount)
            }
            scroller.processTouch(
                x: 0,
                y: 0,
                state: 7,
                timestamp: ts,
                eventUptime: callbackUptime
            )
            scroller.completeZeroTouchBoundary()
        }
    } else {
        // Multi-finger: handle transition, let system handle gestures
        TouchCallbackSequencer.shared.enqueue(timestamp: timestamp) {
            guard scroller.isDeviceCallbackActive(deviceID: deviceID) else {
                return
            }
            guard let acceptedPrevCount = scroller.acceptedPreviousFingerCount(
                deviceID: deviceID,
                contactGeneration: contactGeneration,
                touchCount: touchCount,
                devicePreviousFingerCount: prevCount,
                eventTimestamp: timestamp
            ) else { return }

            if touchCount != acceptedPrevCount {
                scroller.handleFingerCountTransition(from: acceptedPrevCount, to: touchCount)
            }
            drainPendingForceSamples(
                from: callbackContext,
                contactGeneration: contactGeneration,
                throughEventTimestamp: timestamp,
                into: scroller
            )
        }
    }
}

private func forceCentroidCallbackWithRefcon(
    device: MTDeviceRef?,
    centroid: UnsafeMutablePointer<MTForceCentroid>?,
    refcon: UnsafeMutableRawPointer?
) {
    guard let centroid, let refcon else { return }
    let callbackContext = Unmanaged<DeviceCallbackContext>
        .fromOpaque(refcon)
        .takeUnretainedValue()

    let forceCentroid = centroid.pointee
    let x = forceCentroid.normalizedX
    let y = forceCentroid.normalizedY
    let force = forceCentroid.force
    let sampleTimestamp = forceCentroid.timestamp
    let sampleUptime = CACurrentMediaTime()
    _ = callbackContext.recordForceSample(
        x: x,
        y: y,
        force: force,
        sampleTimestamp: sampleTimestamp,
        sampleUptime: sampleUptime
    )
}

// MARK: - Scroll Event Interceptor

private func monotonicNanoseconds(
    fromSystemUptime uptime: Double,
    fallback: UInt64
) -> UInt64 {
    let nanosecondsPerSecond = 1_000_000_000.0
    guard uptime.isFinite,
          uptime > 0,
          uptime <= Double(UInt64.max) / nanosecondsPerSecond else {
        return fallback
    }
    return UInt64((uptime * nanosecondsPerSecond).rounded())
}

/// Intercepts system scroll events to prevent conflicts with TrackPal-generated events
final class ScrollEventInterceptor: @unchecked Sendable {

    static let shared = ScrollEventInterceptor()

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRunning: Bool = false
    private var primaryClickGate = PrimaryClickSuppressionGate()
    private var activePrimaryClickToken: UInt64?
    private struct PrimaryClickSnapshot {
        var location: CGPoint?
        var flags: CGEventFlags = []
        var clickState: Int64 = 1
    }
    private struct PrimaryClickCaptureState {
        var completedSnapshots: [PrimaryClickSnapshot] = []
        var pendingSnapshot: PrimaryClickSnapshot?
    }
    private var primaryClickCaptureStates: [UInt64: PrimaryClickCaptureState] = [:]
    private let lock = NSLock()

    private init() {}

    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        let eventMask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)

        // Create event tap at HID level (same as where we post events)
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: scrollInterceptorCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            LogManager.shared.log("Failed to create scroll event tap")
            return
        }

        // Create run loop source and add to main run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)

        if let runLoopSource = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            isRunning = true
            LogManager.shared.log("Scroll event interceptor started")
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        primaryClickGate.reset()
        clearAllCapturedPrimaryClicksLocked()

        guard isRunning else { return }

        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        isRunning = false
        LogManager.shared.log("Scroll event interceptor stopped")
    }

    func beginPendingForceGesture(
        token: UInt64,
        gestureUptime: Double
    ) {
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        let gestureTimestamp = monotonicNanoseconds(
            fromSystemUptime: gestureUptime,
            fallback: receivedAt
        )

        lock.lock()
        primaryClickGate.begin(
            token: token,
            at: gestureTimestamp,
            receivedAt: receivedAt
        )
        primaryClickCaptureStates = primaryClickCaptureStates.filter {
            primaryClickGate.contains(token: $0.key)
        }
        activePrimaryClickToken = token
        primaryClickCaptureStates[token] = PrimaryClickCaptureState()
        lock.unlock()

        LogManager.shared.log("Primary click capture began for gesture \(token)")
    }

    func finishPendingForceGesture(
        token: UInt64,
        replayCapturedClick: Bool,
        gestureUptime: Double?
    ) {
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        let gestureTimestamp = gestureUptime.map {
            monotonicNanoseconds(
                fromSystemUptime: $0,
                fallback: receivedAt
            )
        } ?? receivedAt
        let resolution: PrimaryClickSuppressionGate.Resolution
        var snapshots: [PrimaryClickSnapshot] = []

        lock.lock()
        guard activePrimaryClickToken == token else {
            lock.unlock()
            return
        }

        resolution = primaryClickGate.finish(
            token: token,
            replayCapturedClick: replayCapturedClick,
            at: gestureTimestamp,
            receivedAt: receivedAt
        )
        if activePrimaryClickToken == token {
            activePrimaryClickToken = nil
        }
        if resolution != .none {
            snapshots = consumePrimaryClickSnapshotsLocked(for: resolution)
        }
        lock.unlock()

        resolvePrimaryClick(
            resolution,
            snapshots: snapshots
        )
    }

    func shouldSuppressPrimaryClick(type: CGEventType, event: CGEvent) -> Bool {
        guard let mouseEvent = primaryClickEvent(for: type) else {
            return false
        }

        let userData = event.getIntegerValueField(.eventSourceUserData)
        if userData == kTrackPalEventSignature {
            return false
        }

        let receivedAt = DispatchTime.now().uptimeNanoseconds
        let eventTimestamp = event.timestamp > 0
            ? event.timestamp
            : receivedAt

        let decision: PrimaryClickSuppressionGate.CaptureDecision
        var resolution: PrimaryClickSuppressionGate.Resolution?
        var resolvedSnapshots: [PrimaryClickSnapshot] = []

        lock.lock()
        decision = primaryClickGate.capture(
            event: mouseEvent,
            at: eventTimestamp,
            receivedAt: receivedAt
        )
        switch decision {
        case .pass:
            break

        case .passAndReset:
            primaryClickCaptureStates = primaryClickCaptureStates.filter {
                primaryClickGate.contains(token: $0.key)
            }
            if let token = activePrimaryClickToken,
               !primaryClickGate.contains(token: token) {
                activePrimaryClickToken = nil
            }

        case let .suppress(token):
            recordPrimaryClickSnapshotLocked(
                token: token,
                event: mouseEvent,
                cgEvent: event
            )

        case let .suppressAndResolve(capturedResolution):
            resolution = capturedResolution
            if let token = capturedResolution.token {
                recordPrimaryClickSnapshotLocked(
                    token: token,
                    event: mouseEvent,
                    cgEvent: event
                )
                resolvedSnapshots = consumePrimaryClickSnapshotsLocked(
                    for: capturedResolution
                )
                if activePrimaryClickToken == token {
                    activePrimaryClickToken = nil
                }
            }
        }
        primaryClickCaptureStates = primaryClickCaptureStates.filter {
            primaryClickGate.contains(token: $0.key)
        }
        lock.unlock()

        if let resolution {
            resolvePrimaryClick(resolution, snapshots: resolvedSnapshots)
        }

        let shouldSuppress: Bool
        switch decision {
        case .suppress, .suppressAndResolve:
            shouldSuppress = true
        case .pass, .passAndReset:
            shouldSuppress = false
        }

        if shouldSuppress {
            LogManager.shared.log("Native left click suppressed during force action guard")
        }

        return shouldSuppress
    }

    private func recordPrimaryClickSnapshotLocked(
        token: UInt64,
        event: PrimaryClickSuppressionGate.MouseEvent,
        cgEvent: CGEvent
    ) {
        var state = primaryClickCaptureStates[token]
            ?? PrimaryClickCaptureState()

        switch event {
        case .leftMouseDown:
            guard state.pendingSnapshot == nil else { return }
            state.pendingSnapshot = PrimaryClickSnapshot(
                location: cgEvent.location,
                flags: cgEvent.flags,
                clickState: cgEvent.getIntegerValueField(.mouseEventClickState)
            )

        case .leftMouseUp:
            guard let pendingSnapshot = state.pendingSnapshot else { return }
            state.completedSnapshots.append(pendingSnapshot)
            state.pendingSnapshot = nil
        }

        primaryClickCaptureStates[token] = state
    }

    private func consumePrimaryClickSnapshotsLocked(
        for resolution: PrimaryClickSuppressionGate.Resolution
    ) -> [PrimaryClickSnapshot] {
        guard let token = resolution.token,
              var state = primaryClickCaptureStates[token] else {
            return []
        }

        let snapshots: [PrimaryClickSnapshot]
        switch resolution {
        case .none:
            return []

        case .discard:
            state.completedSnapshots.removeAll()
            snapshots = []

        case let .replayClicks(_, pairs):
            let replayCount = min(pairs.count, state.completedSnapshots.count)
            snapshots = Array(state.completedSnapshots.prefix(replayCount))
            state.completedSnapshots.removeFirst(replayCount)
        }

        if primaryClickGate.contains(token: token) {
            primaryClickCaptureStates[token] = state
        } else {
            primaryClickCaptureStates.removeValue(forKey: token)
        }
        return snapshots
    }

    private func replayPrimaryClick(
        at location: CGPoint,
        flags: CGEventFlags,
        clickState: Int64
    ) {
        _ = postPairedMouseEvents(
            downType: .leftMouseDown,
            upType: .leftMouseUp,
            at: location,
            button: .left,
            flags: flags,
            clickState: clickState
        )
    }

    private func resolvePrimaryClick(
        _ resolution: PrimaryClickSuppressionGate.Resolution,
        snapshots: [PrimaryClickSnapshot]
    ) {
        guard case let .replayClicks(token, pairs) = resolution else { return }
        guard snapshots.count == pairs.count else {
            LogManager.shared.log(
                "Primary click replay snapshot mismatch for gesture \(token): pairs=\(pairs.count) snapshots=\(snapshots.count)"
            )
            return
        }

        for snapshot in snapshots {
            guard let location = snapshot.location else {
                LogManager.shared.log(
                    "Primary click replay missing location for gesture \(token)"
                )
                continue
            }
            replayPrimaryClick(
                at: location,
                flags: snapshot.flags,
                clickState: snapshot.clickState
            )
        }
        LogManager.shared.log(
            "Native left click replayed for gesture \(token), pairs=\(pairs.count)"
        )
    }

    private func clearAllCapturedPrimaryClicksLocked() {
        activePrimaryClickToken = nil
        primaryClickCaptureStates.removeAll()
    }

    /// Check if an event should be suppressed
    func shouldSuppressEvent(_ event: CGEvent) -> Bool {
        // Don't suppress if we're not actively scrolling in a zone
        guard TrackpadZoneScroller.shared.isActivelyScrollingInZone else {
            return false
        }

        // Don't suppress TrackPal's own events (identified by our signature)
        let userData = event.getIntegerValueField(.eventSourceUserData)
        if userData == kTrackPalEventSignature {
            return false
        }

        // Suppress other scroll events while we're actively scrolling
        return true
    }
}

private func primaryClickEvent(for type: CGEventType) -> PrimaryClickSuppressionGate.MouseEvent? {
    switch type {
    case .leftMouseDown:
        return .leftMouseDown
    case .leftMouseUp:
        return .leftMouseUp
    default:
        return nil
    }
}

/// C callback for scroll event interception
private func scrollInterceptorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // Handle tap disabled event - re-enable
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let interceptor = Unmanaged<ScrollEventInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
            if let eventTap = interceptor.eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    // Suppress cursor movement during active zone scrolling
    if type == .mouseMoved {
        if TrackpadZoneScroller.shared.isActivelyScrollingInZone
            || TrackpadZoneScroller.shared.isEvaluatingScrollCandidate {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    if type == .leftMouseDown || type == .leftMouseUp {
        if ScrollEventInterceptor.shared.shouldSuppressPrimaryClick(type: type, event: event) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    // Only handle scroll wheel events beyond this point
    guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
    }

    // Check if we should suppress this event
    if ScrollEventInterceptor.shared.shouldSuppressEvent(event) {
        return nil
    }

    return Unmanaged.passUnretained(event)
}
