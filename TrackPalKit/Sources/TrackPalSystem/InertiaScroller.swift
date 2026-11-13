import AppKit
import QuartzCore
import TrackPalCore

/// 放開後的慣性捲動：用螢幕的 display link 驅動 `InertiaModel`。
///
/// 每次回呼把這一格的時間長度交給模型，所以滑行的距離與時間跟螢幕更新率、
/// 掉不掉幀無關。
@MainActor
public final class InertiaScroller: NSObject {
    public var isEnabled = true

    private var model = InertiaModel()
    private var displayLink: CADisplayLink?
    /// 上一次回呼的時間；nil 表示這一輪滑行的第一格。
    private var lastTimestamp: CFTimeInterval?
    private let postScroll: (Int32, Int32) -> Void

    /// `postScroll` 收到的是 (deltaX, deltaY) 像素。
    public init(postScroll: @escaping (Int32, Int32) -> Void) {
        self.postScroll = postScroll
    }

    /// 開始滑行。速度是像素／秒。
    public func start(velocityX: CGFloat, velocityY: CGFloat) {
        guard isEnabled,
              model.start(velocityX: velocityX, velocityY: velocityY) else {
            return
        }
        lastTimestamp = nil
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
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = nil
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        // 距離上一次回呼實際過了多久（第一格用這一格的標稱長度）；異常值
        // （畫面休眠回來、回呼被卡住）夾在合理範圍內。
        let interval = lastTimestamp.map { link.timestamp - $0 }
            ?? (link.targetTimestamp - link.timestamp)
        lastTimestamp = link.timestamp
        let elapsed = interval.isFinite && interval > 0
            ? min(interval, 0.05)
            : 1.0 / 60.0

        switch model.tick(elapsed: elapsed) {
        case .idle:
            stopDisplayLink()

        case .coasting:
            break

        case let .scroll(deltaX, deltaY, _):
            postScroll(deltaX, deltaY)

        case let .finished(emitTerminal):
            if emitTerminal {
                postScroll(0, 0)
            }
            stopDisplayLink()
        }
    }
}
