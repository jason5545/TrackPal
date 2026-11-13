import CoreGraphics

/// 放開後的慣性捲動：速度（像素／秒）隨時間指數衰減，每一格送出這段時間走過
/// 的像素，不足一個像素的零頭累加到下一格。
///
/// 純計算，不知道 display link 存在；呼叫端告訴它這一格過了多久，所以滑行的
/// 距離與時間跟螢幕更新率無關。時間常數與停止速度來自原生雙指捲動的實測
/// （`NativeScrollCurve`）。
public struct InertiaModel: Sendable, Equatable {
    /// 兩軸速度都低於這個值（px/s）就停。
    public var stopSpeed: CGFloat = NativeScrollCurve.momentumStopSpeed

    /// 速度衰減的時間常數（秒）。
    public var timeConstant: Double = NativeScrollCurve.momentumTimeConstant

    public private(set) var velocityX: CGFloat = 0
    public private(set) var velocityY: CGFloat = 0
    public private(set) var isScrolling = false
    private var hasEmittedMomentumBegan = false
    private var residualX: CGFloat = 0
    private var residualY: CGFloat = 0

    public init() {}

    public enum Tick: Sendable, Equatable {
        /// 沒在滑。
        case idle
        /// 還在滑，但這一格累積不到一個像素，不用送事件。
        case coasting
        /// 送出一筆捲動。`momentumPhase`：1 開始、2 持續。
        case scroll(deltaX: Int32, deltaY: Int32, momentumPhase: Int64)
        /// 慢到停下來了。`emitTerminal` 為 true 時要補一筆零位移的結束事件。
        case finished(emitTerminal: Bool)
    }

    /// 以新的速度（px/s）開始滑；非有限值直接忽略。
    @discardableResult
    public mutating func start(velocityX: CGFloat, velocityY: CGFloat) -> Bool {
        guard velocityX.isFinite, velocityY.isFinite else { return false }
        self.velocityX = velocityX
        self.velocityY = velocityY
        isScrolling = true
        hasEmittedMomentumBegan = false
        residualX = 0
        residualY = 0
        return true
    }

    /// 停下來。回傳是否要補一筆零位移的結束事件（已經送過至少一筆才需要）。
    public mutating func stop() -> Bool {
        let emitTerminal = isScrolling && hasEmittedMomentumBegan
        isScrolling = false
        velocityX = 0
        velocityY = 0
        hasEmittedMomentumBegan = false
        residualX = 0
        residualY = 0
        return emitTerminal
    }

    /// 往前推進 `elapsed` 秒。
    public mutating func tick(elapsed: Double) -> Tick {
        guard isScrolling else { return .idle }
        guard elapsed.isFinite, elapsed > 0 else { return .coasting }

        let decay = CGFloat(exp(-elapsed / max(timeConstant, 0.001)))
        velocityX *= decay
        velocityY *= decay

        if abs(velocityX) < stopSpeed, abs(velocityY) < stopSpeed {
            return .finished(emitTerminal: stop())
        }

        let deltaX = Self.takePixels(
            from: &residualX, adding: velocityX * CGFloat(elapsed)
        )
        let deltaY = Self.takePixels(
            from: &residualY, adding: velocityY * CGFloat(elapsed)
        )
        guard deltaX != 0 || deltaY != 0 else { return .coasting }

        let phase: Int64 = hasEmittedMomentumBegan ? 2 : 1
        hasEmittedMomentumBegan = true
        return .scroll(deltaX: deltaX, deltaY: deltaY, momentumPhase: phase)
    }

    /// 把新的位移加進累加器，取出整數像素（往零截斷），零頭留著。超出 Int32
    /// 範圍時夾住而不是當掉。
    private static func takePixels(
        from residual: inout CGFloat, adding amount: CGFloat
    ) -> Int32 {
        guard amount.isFinite else { return 0 }
        residual += amount
        let truncated = residual.rounded(.towardZero)
        if truncated >= CGFloat(Int32.max) {
            residual = 0
            return .max
        }
        if truncated <= CGFloat(Int32.min) {
            residual = 0
            return .min
        }
        residual -= truncated
        return Int32(truncated)
    }
}
