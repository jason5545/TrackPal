/// 一筆合成捲動事件要填的數值。
///
/// 像素位移之外還要給「行」單位的位移，給只讀行位移的 App 用：像素除以 10，
/// 但只要像素不是零，行位移至少是 ±1。
public struct ScrollWheelDeltas: Sendable, Equatable {
    public var pixelX: Int32
    public var pixelY: Int32

    public init(pixelX: Int32, pixelY: Int32) {
        self.pixelX = pixelX
        self.pixelY = pixelY
    }

    public var lineX: Int32 { Self.lineDelta(forPixels: pixelX) }
    public var lineY: Int32 { Self.lineDelta(forPixels: pixelY) }

    public static func lineDelta(forPixels pixels: Int32) -> Int32 {
        if pixels > 0 { return max(1, pixels / 10) }
        if pixels < 0 { return min(-1, pixels / 10) }
        return 0
    }
}
