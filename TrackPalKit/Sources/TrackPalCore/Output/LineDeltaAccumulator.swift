/// 捲動事件除了像素位移，還要帶「行」單位的位移，給只讀行位移的 App 用。
///
/// 每 `pixelsPerLine` 個像素算一行，不足一行的零頭留到下一筆事件，所以行數的
/// 總和跟像素總和成正比，不會因為事件切得細就多算。8 px 一行是沿用舊版的
/// 實際比例（當時每筆事件固定送出 8 px 與 1 行）。
public struct LineDeltaAccumulator: Sendable, Equatable {
    public static let defaultPixelsPerLine = 8

    public let pixelsPerLine: Int
    private var remainder = 0

    public init(pixelsPerLine: Int = LineDeltaAccumulator.defaultPixelsPerLine) {
        self.pixelsPerLine = max(1, pixelsPerLine)
    }

    /// 加入這筆事件的像素位移，回傳這筆事件要帶的行數（可能是 0）。
    public mutating func lines(forPixels pixels: Int32) -> Int32 {
        let total = remainder + Int(pixels)
        // Swift 的整數除法往零截斷，餘數跟被除數同號，反向捲動時零頭會自然抵銷。
        remainder = total % pixelsPerLine
        return Int32(clamping: total / pixelsPerLine)
    }

    public mutating func reset() {
        remainder = 0
    }
}
