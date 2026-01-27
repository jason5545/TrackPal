import Cocoa
import CoreGraphics
import CoreVideo

// TrackPal event signature for identifying self-generated events
private let kTrackPalEventSignature: Int64 = 0x5452504C  // "TRPL" in hex

/// Handles inertia/momentum scrolling
@MainActor
final class InertiaScroller {

    static let shared = InertiaScroller()

    // MARK: - Configuration

    var enabled: Bool = true
    /// Minimum velocity to keep scrolling (raised to stop sooner)
    var minVelocity: CGFloat = 2.0

    // MARK: - State

    private var velocityX: CGFloat = 0
    private var velocityY: CGFloat = 0
    private var displayLink: CVDisplayLink?
    private var isScrolling: Bool = false

    /// Continuous deceleration rate per millisecond (similar to UIScrollView.DecelerationRate.normal)
    /// Higher value = slower decay = longer coast
    private let decelerationRate: CGFloat = 0.998

    /// Assumed frame interval in ms (for CVDisplayLink ~60Hz)
    private let frameIntervalMs: CGFloat = 16.67

    // Momentum phase tracking
    private var hasEmittedMomentumBegan: Bool = false

    private init() {}

    // MARK: - Public Methods

    func startInertia(velocityX: CGFloat, velocityY: CGFloat) {
        guard enabled else { return }

        self.velocityX = velocityX
        self.velocityY = velocityY
        self.isScrolling = true
        self.hasEmittedMomentumBegan = false

        startDisplayLink()
    }

    func stopInertia() {
        if isScrolling && hasEmittedMomentumBegan {
            // Send momentum ended event with zero delta
            generateScrollEvent(momentumPhase: 4)  // 4 = ended
        }
        isScrolling = false
        velocityX = 0
        velocityY = 0
        hasEmittedMomentumBegan = false
        stopDisplayLink()
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)

        guard let displayLink = link else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo = userInfo else { return kCVReturnSuccess }

            let scroller = Unmanaged<InertiaScroller>.fromOpaque(userInfo).takeUnretainedValue()

            DispatchQueue.main.async {
                scroller.updateInertia()
            }

            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(displayLink, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)
        self.displayLink = displayLink
    }

    private func stopDisplayLink() {
        guard let displayLink = displayLink else { return }
        CVDisplayLinkStop(displayLink)
        self.displayLink = nil
    }

    private func updateInertia() {
        guard isScrolling else { return }

        // Continuous exponential deceleration: v *= rate^dt
        // This produces natural-feeling deceleration that slows quickly at first,
        // then gently glides to a stop (like a physical object experiencing drag).
        let decay = pow(decelerationRate, frameIntervalMs)
        velocityX *= decay
        velocityY *= decay

        if abs(velocityX) < minVelocity && abs(velocityY) < minVelocity {
            stopInertia()
            return
        }

        // Determine momentum phase: began on first event, changed on subsequent
        let phase: Int64 = hasEmittedMomentumBegan ? 2 : 1  // 1=began, 2=changed
        hasEmittedMomentumBegan = true

        generateScrollEvent(momentumPhase: phase)
    }

    private func generateScrollEvent(momentumPhase: Int64) {
        let dy: Int32
        let dx: Int32

        if momentumPhase == 4 {
            // Terminal event: zero delta
            dy = 0
            dx = 0
        } else {
            dy = Int32(velocityY)
            dx = Int32(velocityX)
        }

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        ) else { return }

        // Tag with TrackPal signature so interceptor won't suppress our own events
        event.setIntegerValueField(.eventSourceUserData, value: kTrackPalEventSignature)

        // Set phase fields: scrollPhase=0 (none), momentumPhase as specified
        // Field 99 = kCGScrollWheelEventScrollPhase
        // Field 123 = kCGScrollWheelEventMomentumPhase
        event.setIntegerValueField(CGEventField(rawValue: 99)!, value: 0)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: momentumPhase)

        event.post(tap: .cghidEventTap)
    }
}
