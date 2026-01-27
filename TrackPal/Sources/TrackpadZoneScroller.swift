import Cocoa
import CoreGraphics

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
    var bottomZoneHeight: CGFloat = 0.20  // 20% from bottom

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
    private var touchCount: Int = 0

    // Velocity tracking for inertia
    private var lastTouchTime: Double = 0
    private var velocityX: CGFloat = 0
    private var velocityY: CGFloat = 0
    private var velocityHistory: [(vx: CGFloat, vy: CGFloat, time: Double)] = []
    private let velocityHistorySize = 5

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

    // MARK: - Singleton

    private init() {}

    // MARK: - Start/Stop

    func start() {
        guard !isEnabled else { return }

        NSLog("TrackPal: Starting zone scroller...")

        guard let cfArray = MTDeviceCreateList() else {
            NSLog("TrackPal: MTDeviceCreateList returned nil")
            return
        }

        let count = CFArrayGetCount(cfArray)
        NSLog("TrackPal: Found \(count) multitouch device(s)")

        if count == 0 {
            NSLog("TrackPal: No devices found")
            return
        }

        for i in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(cfArray, i) else {
                NSLog("TrackPal: Device \(i) pointer is nil")
                continue
            }
            // MTDeviceRef is void* - use UnsafeMutableRawPointer
            let device = UnsafeMutableRawPointer(mutating: rawPtr)
            devices.append(device)

            NSLog("TrackPal: Device \(i) found, registering callback...")

            // Use the refcon variant for better compatibility
            MTRegisterContactFrameCallbackWithRefcon(device, touchCallbackWithRefcon, nil)
            MTDeviceStart(device, 0)
            NSLog("TrackPal: Device \(i) started")
        }

        isEnabled = true
        NSLog("TrackPal: Trackpad zone scrolling enabled successfully")
    }

    func stop() {
        guard isEnabled else { return }

        for device in devices {
            MTDeviceStop(device)
        }

        devices.removeAll()
        isEnabled = false
        NSLog("TrackPal: Trackpad zone scrolling disabled")
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
                currentZone = determineZone(position)
                velocityHistory.removeAll()

                // Record for tap detection
                touchStartTime = timestamp
                touchStartPosition = position

                NSLog("TrackPal: Touch started at (%.2f, %.2f) zone: \(currentZone)", x, y)
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

                handleScroll(delta: delta, zone: currentZone)
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
            scrollVelX = -avgVx * scrollMultiplier * 50
        default:
            return
        }

        // Only start inertia if velocity is significant
        let minVelocityThreshold: CGFloat = 5.0
        if abs(scrollVelX) > minVelocityThreshold || abs(scrollVelY) > minVelocityThreshold {
            NSLog("TrackPal: Starting inertia vx=%.1f vy=%.1f", scrollVelX, scrollVelY)
            DispatchQueue.main.async {
                InertiaScroller.shared.startInertia(velocityX: scrollVelX, velocityY: scrollVelY)
            }
        }
    }

    func resetTracking() {
        isTracking = false
        currentZone = .none
        velocityHistory.removeAll()
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

        var scrollX: Int32 = 0
        var scrollY: Int32 = 0

        switch zone {
        case .leftEdge, .rightEdge:
            // Vertical scrolling - use Y delta
            // Natural scrolling: invert direction (swipe up = content moves up)
            scrollY = Int32(-adjustedDelta.y * scrollMultiplier * 100)

        case .bottomEdge, .topEdge:
            // Horizontal scrolling - use X delta
            // Natural scrolling: invert direction (swipe right = content moves right)
            scrollX = Int32(-adjustedDelta.x * scrollMultiplier * 100)

        case .center, .none, .middleClick,
             .topLeftCorner, .topRightCorner, .bottomLeftCorner, .bottomRightCorner:
            // Normal trackpad behavior - don't intercept
            return
        }

        // Only post event if there's actual scroll
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

        NSLog("TrackPal: Middle click triggered")
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
            NSLog("TrackPal: Mission Control triggered")

        case .appWindows:
            // Use private CoreDock API
            CoreDockSendNotification("com.apple.expose.front.awake" as CFString, nil)
            NSLog("TrackPal: App Windows triggered")

        case .showDesktop:
            // Use private CoreDock API
            CoreDockSendNotification("com.apple.showdesktop.awake" as CFString, nil)
            NSLog("TrackPal: Show Desktop triggered")

        case .launchpad:
            // Open Launchpad app directly
            NSWorkspace.shared.launchApplication("Launchpad")
            NSLog("TrackPal: Launchpad triggered")

        case .notificationCenter:
            // Click on the top-right corner of the screen
            clickNotificationCenter()
            NSLog("TrackPal: Notification Center triggered")
        }
    }

    private func postKeyboardEvent(keyCode: CGKeyCode, flags: CGEventFlags) {
        // Key down
        if let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            downEvent.flags = flags
            downEvent.post(tap: .cghidEventTap)
        }

        // Key up
        if let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            upEvent.flags = flags
            upEvent.post(tap: .cghidEventTap)
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

private func touchCallbackWithRefcon(
    device: MTDeviceRef?,
    touches: UnsafeMutablePointer<MTTouch>?,
    numTouches: Int32,
    timestamp: Double,
    frame: Int32,
    refcon: UnsafeMutableRawPointer?
) {
    guard let touches = touches else { return }

    // Only process single-finger touches for zone scrolling
    if numTouches == 1 {
        let touch = touches[0]
        let ts = timestamp

        DispatchQueue.main.async {
            TrackpadZoneScroller.shared.processTouch(
                x: touch.normalized.position.x,
                y: touch.normalized.position.y,
                state: touch.state,
                timestamp: ts
            )
        }
    } else if numTouches == 0 {
        // All fingers lifted - trigger inertia with current timestamp
        let ts = timestamp
        DispatchQueue.main.async {
            TrackpadZoneScroller.shared.processTouch(x: 0, y: 0, state: 7, timestamp: ts)
        }
    }
}
