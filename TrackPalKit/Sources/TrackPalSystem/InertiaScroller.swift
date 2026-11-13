import AppKit
import QuartzCore
import TrackPalCore

/// 放開後的慣性捲動：用螢幕的 display link 驅動 `InertiaModel`。
///
/// 模型的一個 tick 對應螢幕更新一次。display link 掉幀或以較低頻率觸發時，
/// 一次回呼會補跑對應數量的 tick，所以總距離與減速的時間感不受回呼頻率影響。
@MainActor
public final class InertiaScroller: NSObject {
    public var isEnabled = true

    private var model = InertiaModel()
    private var displayLink: CADisplayLink?
    /// 這條 display link 所屬螢幕的更新率；一個 tick 就是 1/這個值 秒。
    private var ticksPerSecond: Double = 60
    private let postScroll: (Int32, Int32) -> Void

    public init(
        postScroll: @escaping (Int32, Int32) -> Void = { deltaX, deltaY in
            SyntheticEvents.postScroll(deltaX: deltaX, deltaY: deltaY)
        }
    ) {
        self.postScroll = postScroll
    }

    public func start(velocityX: CGFloat, velocityY: CGFloat) {
        guard isEnabled,
              model.start(velocityX: velocityX, velocityY: velocityY) else {
            return
        }
        startDisplayLink()
    }

    public func stop() {
        if model.stop() {
            // Send momentum ended event with zero delta
            postScroll(0, 0)
        }
        stopDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil,
              let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        ticksPerSecond = Double(max(1, screen.maximumFramesPerSecond))
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let interval = link.targetTimestamp - link.timestamp
        let tickCount = interval.isFinite && interval > 0
            ? max(1, Int((interval * ticksPerSecond).rounded()))
            : 1

        for _ in 0..<min(tickCount, 8) {
            switch model.tick() {
            case .idle:
                stopDisplayLink()
                return

            case let .scroll(deltaX, deltaY, _):
                postScroll(deltaX, deltaY)

            case let .finished(emitTerminal):
                if emitTerminal {
                    postScroll(0, 0)
                }
                stopDisplayLink()
                return
            }
        }
    }
}
