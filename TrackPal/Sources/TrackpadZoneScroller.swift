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

    enum VerticalEdgeMode: String, CaseIterable {
        case left = "左側"
        case right = "右側"
        case both = "雙側"
    }

    enum HorizontalPosition: String, CaseIterable {
        case bottom = "下方"
        case top = "上方"
    }

    enum AccelerationCurveType: String, CaseIterable {
        case linear = "線性"
        case quadratic = "二次"
        case cubic = "三次"
        case ease = "緩動"
    }

    // MARK: - State

    private var devices: [MTDeviceRef?] = []
    private var lastTouchPosition: CGPoint = .zero
    private var currentZone: ScrollZone = .none
    private var isTracking: Bool = false

    // Concurrent touch detection state
    private var currentGestureMode: GestureMode = .idle
    private var activeFingerCount: Int = 0
    private var multiToSingleTransitionTime: Double = 0
    private let multiToSingleDebounce: Double = 0.15  // 150ms debounce

    // Thread-safe flag for active zone scrolling (used by CGEventTap interceptor)
    // Using os_unfair_lock instead of NSLock to avoid deadlock from C callback threads
    private var _isActivelyScrollingInZone: Bool = false
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

    // Velocity tracking for inertia
    private var lastTouchTime: Double = 0
    private var velocityX: CGFloat = 0
    private var velocityY: CGFloat = 0
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
    private var activationFrames: [(x: CGFloat, y: CGFloat)] = []
    private var activationDeltas: [CGPoint] = []
    private var activationDensities: [Float] = []  // density per delta frame
    private var activationConfidence: CGFloat = 0   // Bayesian confidence for horizontal zones
    private var currentTouchDensity: Float = 0      // latest density from processFilteredTouch
    private let activationFramesNeeded = 2
    private let activationMaxFrames = 6           // max wait when barely moving
    private let directionCoherenceThreshold: CGFloat = 0.40
    private let minActivationMovement: CGFloat = 0.003
    private let minActivationVelocity: CGFloat = 0.08  // normalized units/sec on scroll axis

    // Tap detection for middle click
    private var touchStartTime: Double = 0
    private var touchStartPosition: CGPoint = .zero
    private let tapMaxDuration: Double = 0.3      // 300ms
    private let tapMaxMovement: CGFloat = 0.05    // 5% of trackpad

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

    enum CornerAction: String, CaseIterable {
        case none = "無動作"
        case missionControl = "Mission Control"
        case appWindows = "應用程式視窗"
        case showDesktop = "顯示桌面"
        case launchpad = "啟動台"
        case notificationCenter = "通知中心"
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

            LogManager.shared.log("Device \(i) found, registering callback...")

            // Use the refcon variant for better compatibility
            MTRegisterContactFrameCallbackWithRefcon(device, touchCallbackWithRefcon, nil)
            MTDeviceStart(device, 0)
            LogManager.shared.log("Device \(i) started")
        }

        // Start scroll event interceptor
        ScrollEventInterceptor.shared.start()

        isEnabled = true
        LogManager.shared.log("Trackpad zone scrolling enabled successfully")
    }

    func stop() {
        guard isEnabled else { return }

        // Stop scroll event interceptor
        ScrollEventInterceptor.shared.stop()

        for device in devices {
            MTDeviceStop(device)
        }

        devices.removeAll()
        isEnabled = false
        LogManager.shared.log("Trackpad zone scrolling disabled")
    }

    // MARK: - Touch Processing

    func processTouch(x: Float, y: Float, state: Int32, timestamp: Double) {
        let position = CGPoint(x: CGFloat(x), y: CGFloat(y))

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
            if !isTracking {
                isTracking = true
                lastTouchPosition = position
                lastTouchTime = timestamp
                velocityHistory.removeAll()

                // Record for tap detection
                touchStartTime = timestamp
                touchStartPosition = position

                let preliminaryZone = determineZone(position)
                currentZone = preliminaryZone

                if isScrollZone(preliminaryZone) {
                    // All scroll zone touches enter activation pending
                    isScrollActivationPending = true
                    activationOriginalZone = preliminaryZone
                    activationFrames = [(x: position.x, y: position.y)]
                    activationDeltas = []
                    activationDensities = []
                    activationConfidence = computeZonePrior(zone: preliminaryZone, position: position)
                    // Suppress system scroll events during activation evaluation
                    // to prevent cursor movement before scroll starts
                    isActivelyScrollingInZone = true
                    LogManager.shared.log(String(format: "Touch started at (%.2f, %.2f) zone: \(preliminaryZone) [ACTIVATING]", x, y))
                } else if isCornerZone(preliminaryZone) {
                    // Corner touches enter activation pending too:
                    // if user slides (not taps), promote to adjacent scroll zone.
                    isScrollActivationPending = true
                    activationOriginalZone = preliminaryZone
                    activationFrames = [(x: position.x, y: position.y)]
                    activationDeltas = []
                    activationDensities = []
                    activationConfidence = 0  // will be set after corner promotion
                    isActivelyScrollingInZone = true
                    LogManager.shared.log(String(format: "Touch started at (%.2f, %.2f) zone: \(preliminaryZone) [CORNER-PENDING]", x, y))
                } else {
                    isScrollActivationPending = false
                    LogManager.shared.log(String(format: "Touch started at (%.2f, %.2f) zone: \(currentZone)", x, y))
                }
            } else {
                let delta = CGPoint(
                    x: position.x - lastTouchPosition.x,
                    y: position.y - lastTouchPosition.y
                )

                // Calculate instantaneous velocity
                let dt = timestamp - lastTouchTime
                if dt > 0 {
                    let vx = delta.x / CGFloat(dt)
                    let vy = delta.y / CGFloat(dt)

                    // Store in history for smoothing
                    velocityHistory.append((vx: vx, vy: vy, time: timestamp))
                    if velocityHistory.count > velocityHistorySize {
                        velocityHistory.removeFirst()
                    }
                }

                // Scroll activation: evaluate direction coherence
                if isScrollActivationPending {
                    activationFrames.append((x: position.x, y: position.y))

                    // Skip the very first delta (frame 1): the initial contact
                    // frame is often noisy, especially at sensor edges where the
                    // finger is only partially on the trackpad surface.
                    if activationFrames.count > 1 {
                        activationDeltas.append(delta)
                        activationDensities.append(currentTouchDensity)
                    }

                    // Evaluate from the first usable delta frame onward
                    if activationDeltas.count >= 1 {
                        let result = evaluateScrollIntent()
                        switch result {
                        case .activated:
                            isScrollActivationPending = false
                            // Flush buffered deltas with graduated ramp-up to avoid jump
                            let count = activationDeltas.count
                            for (index, buffered) in activationDeltas.enumerated() {
                                let ramp = CGFloat(index + 1) / CGFloat(count + 1)
                                let scaled = CGPoint(x: buffered.x * ramp, y: buffered.y * ramp)
                                handleScroll(delta: scaled, zone: currentZone)
                            }
                            activationDeltas.removeAll()
                            LogManager.shared.log("Scroll activated: \(currentZone)")

                        case .rejected:
                            isScrollActivationPending = false
                            activationDeltas.removeAll()
                            activationDensities.removeAll()
                            activationConfidence = 0
                            isActivelyScrollingInZone = false  // Release suppression
                            if isCornerZone(activationOriginalZone) {
                                // Restore corner zone so tap handler can still fire on lift-off
                                currentZone = activationOriginalZone
                                LogManager.shared.log("Scroll rejected → restored \(activationOriginalZone) (corner tap still possible)")
                            } else {
                                currentZone = .center
                                LogManager.shared.log("Scroll rejected → center (cursor movement)")
                            }

                        case .needMoreFrames:
                            // Keep waiting, but enforce upper limit
                            if activationFrames.count >= activationMaxFrames {
                                isScrollActivationPending = false
                                activationDeltas.removeAll()
                                activationDensities.removeAll()
                                activationConfidence = 0
                                isActivelyScrollingInZone = false  // Release suppression
                                if isCornerZone(activationOriginalZone) {
                                    currentZone = activationOriginalZone
                                    LogManager.shared.log("Scroll timeout → restored \(activationOriginalZone)")
                                } else {
                                    currentZone = .center
                                    LogManager.shared.log("Scroll timeout → center")
                                }
                            }
                        }
                    }
                } else {
                    handleScroll(delta: delta, zone: currentZone)
                }

                lastTouchPosition = position
                lastTouchTime = timestamp
            }

        case 6, 7: // Touch ending/released
            if currentZone == .middleClick {
                handleMiddleClickTap(endPosition: lastTouchPosition, endTime: timestamp)
            } else if isCornerZone(currentZone) {
                handleCornerTap(zone: currentZone, endPosition: lastTouchPosition, endTime: timestamp)
            } else {
                // Send scroll phase ended event before starting inertia
                if hasEmittedScrollBegan {
                    postScrollEvent(deltaX: 0, deltaY: 0, scrollPhase: 4, momentumPhase: 0)
                }
                startInertiaIfNeeded()
            }
            resetTracking()

        default:
            break
        }
    }

    private func startInertiaIfNeeded() {
        guard isTracking, currentZone != .none, currentZone != .center else { return }
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
        isTracking = false
        currentZone = .none
        isScrollActivationPending = false
        activationOriginalZone = .none
        activationFrames.removeAll()
        activationDeltas.removeAll()
        activationDensities.removeAll()
        activationConfidence = 0
        velocityHistory.removeAll()
        scrollAccumulatorX = 0
        scrollAccumulatorY = 0
        hasEmittedScrollBegan = false
        isActivelyScrollingInZone = false
    }

    // MARK: - Scroll Intent Detection

    enum ScrollIntentResult {
        case activated      // Direction coherent, start scrolling
        case rejected       // Direction mismatch, demote to center
        case needMoreFrames // Too little movement, need more data
    }

    /// Evaluate whether the user intends to scroll based on direction coherence + on-axis velocity
    private func evaluateScrollIntent() -> ScrollIntentResult {
        guard activationDeltas.count >= 1 else { return .needMoreFrames }

        // Use deltas (which already skip the noisy first frame) for direction analysis
        var totalRawDx: CGFloat = 0
        var totalRawDy: CGFloat = 0
        for d in activationDeltas {
            totalRawDx += abs(d.x)
            totalRawDy += abs(d.y)
        }

        // --- Corner zone: promote to adjacent scroll zone based on movement ---
        // When a touch starts in a corner, we don't know if the user wants a
        // corner tap or a scroll. If they move enough, determine the dominant
        // direction and promote to the appropriate *adjacent* edge scroll zone.
        //
        // Key insight: corners sit at the intersection of two edges. We should
        // only promote to an edge that is:
        //   1. Physically adjacent to the corner
        //   2. Actually configured for scrolling
        // E.g., bottom-left corner is adjacent to bottomEdge and leftEdge.
        //       Promoting to rightEdge would be nonsensical.
        if isCornerZone(currentZone) {
            let totalMovement = totalRawDx + totalRawDy
            if totalMovement < minActivationMovement {
                return .needMoreFrames
            }

            // Determine which adjacent edges are available
            let adjacentHorizontal: ScrollZone?
            let adjacentVertical: ScrollZone?

            switch currentZone {
            case .bottomLeftCorner:
                adjacentHorizontal = (horizontalPosition == .bottom) ? .bottomEdge : nil
                adjacentVertical = (verticalEdgeMode == .left || verticalEdgeMode == .both) ? .leftEdge : nil
            case .bottomRightCorner:
                adjacentHorizontal = (horizontalPosition == .bottom) ? .bottomEdge : nil
                adjacentVertical = (verticalEdgeMode == .right || verticalEdgeMode == .both) ? .rightEdge : nil
            case .topLeftCorner:
                adjacentHorizontal = (horizontalPosition == .top) ? .topEdge : nil
                adjacentVertical = (verticalEdgeMode == .left || verticalEdgeMode == .both) ? .leftEdge : nil
            case .topRightCorner:
                adjacentHorizontal = (horizontalPosition == .top) ? .topEdge : nil
                adjacentVertical = (verticalEdgeMode == .right || verticalEdgeMode == .both) ? .rightEdge : nil
            default:
                adjacentHorizontal = nil
                adjacentVertical = nil
            }

            // Determine dominant direction with aspect ratio compensation
            let compensatedDx = totalRawDx * 1.6
            let promotedZone: ScrollZone

            if let h = adjacentHorizontal, let v = adjacentVertical {
                // Both adjacent edges are active — pick based on direction,
                // but bias toward horizontal for bottom/top corners since
                // sensor noise at the physical edge inflates Y readings
                let isBottom = (currentZone == .bottomLeftCorner || currentZone == .bottomRightCorner)
                let isTop = (currentZone == .topLeftCorner || currentZone == .topRightCorner)
                let horizontalBias: CGFloat = (isBottom || isTop) ? 1.5 : 1.0

                if compensatedDx * horizontalBias >= totalRawDy {
                    promotedZone = h
                } else {
                    promotedZone = v
                }
            } else if let h = adjacentHorizontal {
                // Only horizontal edge is available — promote there
                promotedZone = h
            } else if let v = adjacentVertical {
                // Only vertical edge is available — promote there
                promotedZone = v
            } else {
                // No adjacent edge is configured — reject
                return .rejected
            }

            currentZone = promotedZone
            LogManager.shared.log("Corner promoted → \(promotedZone)")

            // Initialize Bayesian prior for the promoted zone
            if let startPos = activationFrames.first {
                let pos = CGPoint(x: startPos.x, y: startPos.y)
                activationConfidence = computeZonePrior(zone: promotedZone, position: pos)
            }
            // Fall through to normal scroll evaluation with the new zone
        }

        // --- All scroll zones use Bayesian confidence model ---
        return evaluateScrollIntentBayesian()
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

    /// Compute initial Bayesian prior from how deep the touch is within the zone
    private func computeZonePrior(zone: ScrollZone, position: CGPoint) -> CGFloat {
        let basePrior: CGFloat = 0.50
        let priorRange: CGFloat = 0.35  // max additional prior from zone depth

        let depth: CGFloat
        switch zone {
        case .bottomEdge:
            depth = max(0, bottomZoneHeight - position.y) / bottomZoneHeight
        case .topEdge:
            depth = max(0, position.y - (1.0 - bottomZoneHeight)) / bottomZoneHeight
        case .leftEdge:
            depth = max(0, edgeZoneWidth - position.x) / edgeZoneWidth
        case .rightEdge:
            depth = max(0, position.x - (1.0 - edgeZoneWidth)) / edgeZoneWidth
        default:
            depth = 0
        }
        return basePrior + depth * priorRange  // range: 0.50 ~ 0.85
    }

    /// Bayesian confidence evaluation for horizontal zones (bottomEdge/topEdge)
    private func evaluateScrollIntentBayesian() -> ScrollIntentResult {
        guard !activationDeltas.isEmpty else { return .needMoreFrames }

        // Use the latest delta for this frame's evidence
        let delta = activationDeltas.last!
        let density = activationDensities.last ?? 0.05

        // --- Quality weight from density ---
        // Low density (edge touches) = unreliable direction data
        // qualityWeight: 0.3 (density=0.02) to 1.0 (density>=0.10)
        let qualityWeight = CGFloat(min(max((density - 0.02) / 0.08, 0.0), 1.0)) * 0.7 + 0.3

        // --- Direction evidence ---
        // Compute on-axis ratio with aspect ratio compensation
        let absDx = abs(delta.x) * 1.6  // aspect compensation
        let absDy = abs(delta.y)
        let total = absDx + absDy
        guard total > 0.0005 else {
            // Movement too small to determine direction — no update
            return activationConfidence >= 0.80 ? .activated : .needMoreFrames
        }

        let onAxisRatio: CGFloat  // how much movement is on the expected scroll axis
        switch currentZone {
        case .bottomEdge, .topEdge:
            onAxisRatio = absDx / total
        default:
            onAxisRatio = absDy / total
        }

        // Direction boost: positive when on-axis dominant, negative when off-axis
        let directionBoost: CGFloat
        if onAxisRatio >= 0.5 {
            directionBoost = (onAxisRatio - 0.5) * 0.50  // max +0.25
        } else {
            directionBoost = (onAxisRatio - 0.5) * 0.60  // max -0.30 (stronger penalty)
        }

        // --- Velocity evidence ---
        let latestV = velocityHistory.last
        let onAxisSpeed: CGFloat
        switch currentZone {
        case .bottomEdge, .topEdge:
            onAxisSpeed = abs(latestV?.vx ?? 0)
        default:
            onAxisSpeed = abs(latestV?.vy ?? 0)
        }
        let velocityBoost: CGFloat
        if onAxisSpeed > 0.30      { velocityBoost = 0.10 }
        else if onAxisSpeed > 0.15 { velocityBoost = 0.05 }
        else if onAxisSpeed > 0.05 { velocityBoost = 0.02 }
        else                       { velocityBoost = -0.03 }

        // --- Update confidence ---
        // Cap per-frame drop to prevent a single noisy frame from killing momentum
        let update = (directionBoost + velocityBoost) * qualityWeight
        activationConfidence += max(update, -0.20)
        activationConfidence = min(max(activationConfidence, 0.0), 1.0)

        LogManager.shared.log(String(format: "Bayesian confidence=%.3f (dir=%.3f vel=%.3f qw=%.2f density=%.3f)",
            activationConfidence, directionBoost, velocityBoost, qualityWeight, density))

        // --- Decision ---
        if activationConfidence >= 0.80 { return .activated }
        if activationConfidence <= 0.20 { return .rejected }
        return .needMoreFrames
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

    func handleFingerCountTransition(from oldCount: Int, to newCount: Int) {
        // Single → Multi: Cancel any active scrolling
        if oldCount == 1 && newCount > 1 {
            cancelActiveScrolling()
            currentGestureMode = .multiFinger
            LogManager.shared.log("Single→Multi transition, cancelling scroll")
        }
        // Multi → Single: Record time for debounce
        else if oldCount > 1 && newCount == 1 {
            multiToSingleTransitionTime = CACurrentMediaTime()
            currentGestureMode = .singleFinger
            LogManager.shared.log("Multi→Single transition, debounce active")
        }
        // Any → Zero: Reset to idle
        else if newCount == 0 {
            currentGestureMode = .idle
        }
        // Zero → One: Start single finger mode
        else if oldCount == 0 && newCount == 1 {
            currentGestureMode = .singleFinger
        }

        activeFingerCount = newCount
    }

    private func cancelActiveScrolling() {
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
        // Block if in multi-finger mode (system gesture active)
        if currentGestureMode == .multiFinger { return false }

        // Allow if idle (fresh start) or singleFinger mode
        // Check debounce only after multi→single transition
        if currentGestureMode == .singleFinger && multiToSingleTransitionTime > 0 {
            let timeSinceTransition = CACurrentMediaTime() - multiToSingleTransitionTime
            if timeSinceTransition < multiToSingleDebounce {
                return false
            }
        }

        return true
    }

    // MARK: - Touch Filtering (Scroll2-style)

    enum TouchFilterResult {
        case valid
        case tooLight
        case tooLarge
    }

    /// Process touch with filtering applied. Called from the callback on main thread.
    func processFilteredTouch(x: Float, y: Float, state: Int32, timestamp: Double,
                              density: Float, majorAxis: Float, minorAxis: Float) {
        // Skip filtering for lift-off states (6=lifting, 7=released)
        // Density drops to 0 on lift-off, which would falsely trigger light touch filter
        // We must let lift-off reach processTouch for proper cleanup and inertia triggering
        if state >= 6 {
            processTouch(x: x, y: y, state: state, timestamp: timestamp)
            return
        }

        let result = classifyTouchValues(density: density, majorAxis: majorAxis, minorAxis: minorAxis)

        switch result {
        case .valid:
            currentTouchDensity = density
            processTouch(x: x, y: y, state: state, timestamp: timestamp)

        case .tooLight:
            filteredLightTouchCount += 1
            if isTracking {
                LogManager.shared.log(String(format: "Light touch filtered (density=%.3f) [count=%d]", density, filteredLightTouchCount))
                resetTracking()
            }

        case .tooLarge:
            filteredLargeTouchCount += 1
            if isTracking {
                LogManager.shared.log(String(format: "Large touch filtered (major=%.3f, minor=%.3f) [count=%d]", majorAxis, minorAxis, filteredLargeTouchCount))
                resetTracking()
            }
        }
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

    private func determineZone(_ position: CGPoint) -> ScrollZone {
        // Position is normalized: x and y are 0.0 to 1.0
        // x: 0 = left, 1 = right
        // y: 0 = bottom (near user), 1 = top (away from user)

        // Check corners first (highest priority)
        if cornerTriggerEnabled {
            let isLeft = position.x < cornerTriggerZoneSize
            let isRight = position.x > (1.0 - cornerTriggerZoneSize)
            let isTop = position.y > (1.0 - cornerTriggerZoneSize)
            let isBottom = position.y < cornerTriggerZoneSize

            if isTop && isLeft { return .topLeftCorner }
            if isTop && isRight { return .topRightCorner }
            if isBottom && isLeft { return .bottomLeftCorner }
            if isBottom && isRight { return .bottomRightCorner }
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
        if horizontalPosition == .bottom {
            if position.y < bottomZoneHeight {
                return .bottomEdge
            }
        } else {
            if position.y > (1.0 - bottomZoneHeight) {
                return .topEdge
            }
        }

        return .center
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

        postScrollEvent(deltaX: scrollX, deltaY: scrollY, scrollPhase: phase, momentumPhase: 0)
    }

    /// Post a scroll wheel CGEvent with phase metadata
    /// - scrollPhase: 0=none, 1=began, 2=changed, 4=ended (matches NSEvent.Phase bitmask)
    /// - momentumPhase: 0=none, 1=began, 2=changed, 4=ended
    private func postScrollEvent(deltaX: Int32, deltaY: Int32, scrollPhase: Int64, momentumPhase: Int64) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return }

        // Tag with TrackPal signature so interceptor won't suppress our own events
        event.setIntegerValueField(.eventSourceUserData, value: kTrackPalEventSignature)

        // Set scroll phase fields (critical for native-feeling scroll in all apps)
        // Field 99 = kCGScrollWheelEventScrollPhase (tracking/finger phase)
        // Field 123 = kCGScrollWheelEventMomentumPhase (inertia phase)
        event.setIntegerValueField(CGEventField(rawValue: 99)!, value: scrollPhase)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: momentumPhase)

        event.post(tap: .cghidEventTap)
    }

    // MARK: - Middle Click

    private func handleMiddleClickTap(endPosition: CGPoint, endTime: Double) {
        let duration = endTime - touchStartTime
        let movement = hypot(
            endPosition.x - touchStartPosition.x,
            endPosition.y - touchStartPosition.y
        )

        // Check if it's a valid tap (short duration, minimal movement)
        guard duration < tapMaxDuration && movement < tapMaxMovement else {
            return
        }

        postMiddleClickEvent()
    }

    private func postMiddleClickEvent() {
        let mouseLocation = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let cgPoint = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)

        // Middle mouse down
        if let downEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseDown,
            mouseCursorPosition: cgPoint,
            mouseButton: .center
        ) {
            downEvent.post(tap: .cghidEventTap)
        }

        // Middle mouse up
        if let upEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseUp,
            mouseCursorPosition: cgPoint,
            mouseButton: .center
        ) {
            upEvent.post(tap: .cghidEventTap)
        }

        LogManager.shared.log("Middle click triggered")
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
        let duration = endTime - touchStartTime
        let movement = hypot(
            endPosition.x - touchStartPosition.x,
            endPosition.y - touchStartPosition.y
        )

        // Check if it's a valid tap (short duration, minimal movement)
        guard duration < tapMaxDuration && movement < tapMaxMovement else {
            return
        }

        // Get the action for this corner
        guard let action = cornerActions[zone], action != .none else {
            return
        }

        executeCornerAction(action)
    }

    private func executeCornerAction(_ action: CornerAction) {
        switch action {
        case .none:
            break

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

        // Mouse down
        if let downEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        ) {
            downEvent.post(tap: .cghidEventTap)
        }

        // Mouse up
        if let upEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        ) {
            upEvent.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - C Callback with Refcon

/// Thread-safe storage for callback state shared across device callbacks
/// Using os_unfair_lock for synchronization — @unchecked Sendable because we handle safety manually
private final class CallbackState: @unchecked Sendable {
    static let shared = CallbackState()
    private var lock = os_unfair_lock()
    private var _previousFingerCount: Int32 = 0
    private var _hasLoggedTouchValues: Bool = false

    var previousFingerCount: Int32 {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _previousFingerCount }
        set { os_unfair_lock_lock(&lock); _previousFingerCount = newValue; os_unfair_lock_unlock(&lock) }
    }
    var hasLoggedTouchValues: Bool {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _hasLoggedTouchValues }
        set { os_unfair_lock_lock(&lock); _hasLoggedTouchValues = newValue; os_unfair_lock_unlock(&lock) }
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
    guard let touches = touches else { return }

    let scroller = TrackpadZoneScroller.shared
    let touchCount = Int(numTouches)
    let prevCount = Int(CallbackState.shared.previousFingerCount)
    CallbackState.shared.previousFingerCount = numTouches

    // Only process single-finger touches for zone scrolling
    if numTouches == 1 {
        let touch = touches[0]
        let ts = timestamp

        // Diagnostic: log actual MTTouch values for threshold calibration
        if !CallbackState.shared.hasLoggedTouchValues && touch.state >= 4 {
            CallbackState.shared.hasLoggedTouchValues = true
            LogManager.shared.log(String(format: "[DIAG] MTTouch values - density=%.4f, majorAxis=%.4f, minorAxis=%.4f, size=%.4f, angle=%.4f, state=%d", touch.density, touch.majorAxis, touch.minorAxis, touch.size, touch.angle, touch.state))
        }

        // Extract values from the touch struct BEFORE dispatching
        let x = touch.normalized.position.x
        let y = touch.normalized.position.y
        let state = touch.state
        let density = touch.density
        let majorAxis = touch.majorAxis
        let minorAxis = touch.minorAxis

        DispatchQueue.main.async {
            // Handle finger count transition synchronously within main thread block
            if touchCount != prevCount {
                scroller.handleFingerCountTransition(from: prevCount, to: touchCount)
            }

            // Check debounce after multi→single transition
            guard scroller.shouldProcessSingleFingerTouch() else { return }

            // Apply touch filtering, then process
            scroller.processFilteredTouch(
                x: x, y: y, state: state, timestamp: ts,
                density: density, majorAxis: majorAxis, minorAxis: minorAxis
            )
        }
    } else if numTouches == 0 {
        let ts = timestamp
        DispatchQueue.main.async {
            if touchCount != prevCount {
                scroller.handleFingerCountTransition(from: prevCount, to: touchCount)
            }
            scroller.processTouch(x: 0, y: 0, state: 7, timestamp: ts)
        }
    } else {
        // Multi-finger: handle transition, let system handle gestures
        DispatchQueue.main.async {
            if touchCount != prevCount {
                scroller.handleFingerCountTransition(from: prevCount, to: touchCount)
            }
        }
    }
}

// MARK: - Scroll Event Interceptor

/// Intercepts system scroll events to prevent conflicts with TrackPal-generated events
final class ScrollEventInterceptor: @unchecked Sendable {

    static let shared = ScrollEventInterceptor()

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRunning: Bool = false
    private let lock = NSLock()

    private init() {}

    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        let eventMask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)

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
        if TrackpadZoneScroller.shared.isActivelyScrollingInZone {
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
