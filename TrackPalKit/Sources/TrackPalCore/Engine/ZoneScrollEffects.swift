import CoreGraphics

/// 狀態機對外界做的每一件事。
///
/// 狀態機本身不送事件、不讀時鐘、不寫檔：全部經過這個介面，同步呼叫、順序
/// 固定。App 接上真正的實作（CGEvent、event tap、display link、檔案），測試與
/// `trackpal-replay` 接上只記錄不執行的實作，所以整條手勢流程可以離線重播。
@MainActor
public protocol ZoneScrollEffects: AnyObject {
    func log(_ message: String)

    /// 單調時鐘（秒），跟觸控 callback 的 uptime 同一個刻度。
    func now() -> Double

    /// 送出一筆像素捲動。`scrollPhase`／`momentumPhase` 是狀態機內部的生命週期
    /// 標記；實際 CGEvent 的 phase 欄位一律填 0，原因見 `SyntheticEvents`。
    func postScroll(deltaX: Int32, deltaY: Int32, scrollPhase: Int64, momentumPhase: Int64)

    /// 在游標位置送出中鍵點擊。回傳是否成功建立事件。
    func postMiddleClick() -> Bool

    func performCornerAction(_ action: CornerAction)

    /// 目前游標位置（全域螢幕座標）。
    func pointerLocation() -> CGPoint?

    /// 把游標放回指定位置，並取消 warp 之後預設 0.25 秒的滑鼠事件抑制。
    func warpPointer(to location: CGPoint)

    func startInertia(velocityX: CGFloat, velocityY: CGFloat)
    func stopInertia()

    /// 開始攔截這次接觸的原生左鍵，等手勢定案再決定補送或丟掉。
    func beginPrimaryClickCapture(token: UInt64, gestureUptime: Double)
    func finishPrimaryClickCapture(
        token: UInt64,
        replayCapturedClick: Bool,
        gestureUptime: Double?
    )

    func traceBegin(timestamp: Double)
    func traceFrame(
        timestamp: Double,
        x: Float,
        y: Float,
        state: Int32,
        density: Float,
        majorAxis: Float,
        minorAxis: Float,
        isValid: Bool
    )
    func traceFinish(_ summary: GestureTraceSummary)
}
