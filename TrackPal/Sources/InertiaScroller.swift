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
    /// Friction computed from initial velocity magnitude (velocity-adaptive)
    private var friction: CGFloat = 0.95

    private init() {}

    // MARK: - Public Methods

    func startInertia(velocityX: CGFloat, velocityY: CGFloat) {
        guard enabled else { return }

        self.velocityX = velocityX
        self.velocityY = velocityY
        self.isScrolling = true

        // Velocity-adaptive friction: small velocities decay fast, large ones carry
        let magnitude = max(abs(velocityX), abs(velocityY))
        if magnitude < 50 {
            friction = 0.88       // ~8 frames to halve, stops in ~0.3s
        } else if magnitude < 120 {
            friction = 0.93       // ~10 frames to halve, stops in ~0.8s
        } else if magnitude < 250 {
            friction = 0.95       // ~14 frames to halve, stops in ~1.3s
        } else {
            friction = 0.97       // ~23 frames to halve, stops in ~3s
        }

        startDisplayLink()
    }

    func stopInertia() {
        isScrolling = false
        velocityX = 0
        velocityY = 0
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

        velocityX *= friction
        velocityY *= friction

        if abs(velocityX) < minVelocity && abs(velocityY) < minVelocity {
            stopInertia()
            return
        }

        generateScrollEvent()
    }

    private func generateScrollEvent() {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(velocityY),
            wheel2: Int32(velocityX),
            wheel3: 0
        ) else { return }

        // Tag with TrackPal signature so interceptor won't suppress our own events
        event.setIntegerValueField(.eventSourceUserData, value: kTrackPalEventSignature)
        event.post(tap: .cghidEventTap)
    }
}
