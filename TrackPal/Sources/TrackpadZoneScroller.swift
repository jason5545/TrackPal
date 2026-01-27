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

    // Intent prediction: defer zone decision near boundaries
    private var isZonePending: Bool = false
    private var pendingTouchFrames: [(x: CGFloat, y: CGFloat)] = []
    private var pendingDeltas: [CGPoint] = []  // buffered deltas during pending period
    private let pendingFramesNeeded = 3
    private let boundaryMargin: CGFloat = 0.08  // 8% ambiguous margin around zone edges

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

                // Intent prediction: defer zone if touch is near a boundary
                let preliminaryZone = determineZone(position)
                if isNearZoneBoundary(position) {
                    isZonePending = true
                    pendingTouchFrames = [(x: position.x, y: position.y)]
                    pendingDeltas = []
                    currentZone = preliminaryZone  // tentative
                    LogManager.shared.log(String(format: "Touch started at (%.2f, %.2f) zone: \(preliminaryZone) [PENDING]", x, y))
                } else {
                    isZonePending = false
                    currentZone = preliminaryZone
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

                // Resolve pending zone using movement direction
                if isZonePending {
                    pendingTouchFrames.append((x: position.x, y: position.y))
                    pendingDeltas.append(delta)

                    if pendingTouchFrames.count >= pendingFramesNeeded {
                        let predicted = predictIntendedZone()
                        if predicted != currentZone {
                            LogManager.shared.log("Intent prediction: \(currentZone) → \(predicted)")
                        }
                        currentZone = predicted
                        isZonePending = false

                        // Flush buffered deltas with the resolved zone
                        for buffered in pendingDeltas {
                            handleScroll(delta: buffered, zone: currentZone)
                        }
                        pendingDeltas.removeAll()
                    }
                    // Don't scroll yet during pending — deltas are buffered
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
            scrollVelY = -avgVy * scrollMultiplier * 50
        case .bottomEdge, .topEdge:
            // Horizontal scrolling - use X velocity (inverted for natural scrolling)
            // Compensate for trackpad aspect ratio (~1.6:1)
            scrollVelX = -avgVx * scrollMultiplier * 50 * 1.6
        default:
            return
        }

        // Only start inertia if velocity is significant
        // Below this: finger was slow/stationary — just stop, no coast
        let minVelocityThreshold: CGFloat = 50.0

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
        isZonePending = false
        pendingTouchFrames.removeAll()
        pendingDeltas.removeAll()
        velocityHistory.removeAll()
        scrollAccumulatorX = 0
        scrollAccumulatorY = 0
        isActivelyScrollingInZone = false
    }

    // MARK: - Intent Prediction

    /// Check if touch position is near a zone boundary (ambiguous region)
    private func isNearZoneBoundary(_ position: CGPoint) -> Bool {
        let y = position.y
        let x = position.x

        // Near horizontal zone boundary (only check the active side)
        if horizontalPosition == .bottom {
            let bottomBound = bottomZoneHeight
            if y > (bottomBound - boundaryMargin) && y < (bottomBound + boundaryMargin) {
                return true
            }
        } else {
            let topBound = 1.0 - bottomZoneHeight
            if y > (topBound - boundaryMargin) && y < (topBound + boundaryMargin) {
                return true
            }
        }

        // Near right edge boundary
        let rightBound = 1.0 - edgeZoneWidth
        if x > (rightBound - boundaryMargin) && x < (rightBound + boundaryMargin) {
            return true
        }

        // Near left edge boundary (if left or both mode)
        if verticalEdgeMode == .left || verticalEdgeMode == .both {
            let leftBound = edgeZoneWidth
            if x > (leftBound - boundaryMargin) && x < (leftBound + boundaryMargin) {
                return true
            }
        }

        return false
    }

    /// Predict intended zone from initial movement direction
    private func predictIntendedZone() -> ScrollZone {
        guard pendingTouchFrames.count >= 2 else {
            return currentZone
        }

        let first = pendingTouchFrames.first!
        let last = pendingTouchFrames.last!
        let dx = abs(last.x - first.x)
        let dy = abs(last.y - first.y)

        let avgX = pendingTouchFrames.map(\.x).reduce(0, +) / CGFloat(pendingTouchFrames.count)
        let avgY = pendingTouchFrames.map(\.y).reduce(0, +) / CGFloat(pendingTouchFrames.count)

        // Near bottom zone boundary: horizontal movement → bottomEdge
        let bottomBound = bottomZoneHeight
        if avgY > (bottomBound - boundaryMargin) && avgY < (bottomBound + boundaryMargin) {
            if dx > dy * 1.2 {
                return .bottomEdge
            }
        }

        // Near top zone boundary
        if horizontalPosition == .top {
            let topBound = 1.0 - bottomZoneHeight
            if avgY > (topBound - boundaryMargin) && avgY < (topBound + boundaryMargin) {
                if dx > dy * 1.2 {
                    return .topEdge
                }
            }
        }

        // Near right edge boundary: vertical movement → rightEdge
        let rightBound = 1.0 - edgeZoneWidth
        if avgX > (rightBound - boundaryMargin) && avgX < (rightBound + boundaryMargin) {
            if dy > dx * 1.2 {
                return .rightEdge
            }
        }

        // Near left edge boundary: vertical movement → leftEdge
        if verticalEdgeMode == .left || verticalEdgeMode == .both {
            let leftBound = edgeZoneWidth
            if avgX > (leftBound - boundaryMargin) && avgX < (leftBound + boundaryMargin) {
                if dy > dx * 1.2 {
                    return .leftEdge
                }
            }
        }

        // No strong directional signal — use position-based detection
        return determineZone(CGPoint(x: avgX, y: avgY))
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
            // Natural scrolling: invert direction (swipe right = content moves right)
            // Compensate for trackpad aspect ratio (~1.6:1 width:height)
            let aspectCompensation: CGFloat = 1.6
            scrollAccumulatorX += -adjustedDelta.x * scrollMultiplier * 100 * aspectCompensation
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

        postScrollEvent(deltaX: scrollX, deltaY: scrollY)
    }

    private func postScrollEvent(deltaX: Int32, deltaY: Int32) {
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

    // Only handle scroll wheel events
    guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
    }

    // Check if we should suppress this event
    if ScrollEventInterceptor.shared.shouldSuppressEvent(event) {
        return nil
    }

    return Unmanaged.passUnretained(event)
}
