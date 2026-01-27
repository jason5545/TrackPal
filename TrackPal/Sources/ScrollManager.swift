import Cocoa
import CoreGraphics

/// Core scroll enhancement manager
final class ScrollManager: @unchecked Sendable {

    static let shared = ScrollManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private(set) var isEnabled = false

    // MARK: - Configuration

    var scrollMultiplier: CGFloat = 1.5
    var enableInertia: Bool = true
    var smoothScrolling: Bool = true

    private init() {}

    // MARK: - Start/Stop

    func start() {
        guard !isEnabled else { return }

        let eventMask = (1 << CGEventType.scrollWheel.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: scrollEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            print("TrackPal: Failed to create event tap. Check accessibility permissions.")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        isEnabled = true
        print("TrackPal: Event tap enabled")
    }

    func stop() {
        guard isEnabled, let eventTap = eventTap else { return }

        CGEvent.tapEnable(tap: eventTap, enable: false)

        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }

        self.eventTap = nil
        self.runLoopSource = nil
        isEnabled = false

        print("TrackPal: Event tap disabled")
    }

    // MARK: - Event Processing

    func processScrollEvent(_ event: CGEvent) -> CGEvent? {
        let deltaY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let deltaX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)

        let newDeltaY = deltaY * Double(scrollMultiplier)
        let newDeltaX = deltaX * Double(scrollMultiplier)

        event.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: newDeltaY)
        event.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: newDeltaX)

        return event
    }

    // MARK: - Re-enable tap

    func reenableTap() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }
}

// MARK: - Event Tap Callback

private func scrollEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    guard let userInfo = userInfo else {
        return Unmanaged.passRetained(event)
    }

    let manager = Unmanaged<ScrollManager>.fromOpaque(userInfo).takeUnretainedValue()

    switch type {
    case .scrollWheel:
        if let modifiedEvent = manager.processScrollEvent(event) {
            return Unmanaged.passRetained(modifiedEvent)
        }
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        DispatchQueue.main.async {
            manager.reenableTap()
        }
    default:
        break
    }

    return Unmanaged.passRetained(event)
}
