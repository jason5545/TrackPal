import CoreGraphics
import TrackPalCore

/// 送出捲動事件的唯一出口。手指跟隨的捲動與慣性都經過這裡，行位移的零頭
/// 才會連續累加。
@MainActor
public final class ScrollEventPoster {
    private var lineX = LineDeltaAccumulator()
    private var lineY = LineDeltaAccumulator()
    private let send: (CGEvent) -> Void

    /// `send` 預設把事件送到 HID 層；測試可以換成只收集的版本。
    public init(send: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.send = send
    }

    /// 送出一筆像素位移。兩軸都是 0 也會送（捲動或慣性結束時的標記）。
    @discardableResult
    public func post(deltaX: Int32, deltaY: Int32) -> Bool {
        guard let event = SyntheticEvents.makeScrollEvent(
            deltaX: deltaX,
            deltaY: deltaY,
            lineX: lineX.lines(forPixels: deltaX),
            lineY: lineY.lines(forPixels: deltaY)
        ) else {
            return false
        }
        send(event)
        return true
    }
}
