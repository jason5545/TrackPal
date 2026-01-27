import Cocoa
import CoreGraphics
import CoreVideo

/// Handles inertia/momentum scrolling
@MainActor
final class InertiaScroller {

    static let shared = InertiaScroller()

    // MARK: - Configuration

    var friction: CGFloat = 0.95
    var minVelocity: CGFloat = 0.1
    var enabled: Bool = true

    // MARK: - State

    private var velocityX: CGFloat = 0
    private var velocityY: CGFloat = 0
    private var displayLink: CVDisplayLink?
    private var isScrolling: Bool = false

    private init() {}

    // MARK: - Public Methods

    func startInertia(velocityX: CGFloat, velocityY: CGFloat) {
        guard enabled else { return }

        self.velocityX = velocityX
        self.velocityY = velocityY
        self.isScrolling = true

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

            Task { @MainActor in
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

        event.post(tap: .cghidEventTap)
    }
}
