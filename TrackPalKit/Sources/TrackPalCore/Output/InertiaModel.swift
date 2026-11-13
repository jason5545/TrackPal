import CoreGraphics

/// 放開後的慣性捲動：每個 tick 把速度乘上固定的衰減，換成像素送出去。
///
/// 純計算，不知道 display link 存在。一個 tick 對應螢幕更新一次；這跟
/// 2026-01 以來的行為一致（衰減量是以 16.67 ms 一格算的，在 120 Hz 螢幕上
/// 每秒跑 120 格），改成依實際時間計算會改變手感，所以沒有動。
public struct InertiaModel: Sendable, Equatable {
    /// 兩軸速度都低於這個值就停。
    public var minimumVelocity: CGFloat = 2.0

    /// 每毫秒的衰減率與假設的一格時間。
    static let decelerationRate: CGFloat = 0.998
    static let frameIntervalMilliseconds: CGFloat = 16.67
    static let decayPerTick = pow(decelerationRate, frameIntervalMilliseconds)

    /// 速度換成每個 tick 送出的像素。
    ///
    /// 2026-11-13 以前是直接送出速度的整數部分，但事件被系統量化成「每 10
    /// 換 8 px、最少 8 px」：速度 20 以上實際送出約 0.8 倍，20 以下則固定每格
    /// 8 px，一路滑到速度低於門檻才突然停。改成逐像素後用 0.8 倍：起始速度
    /// 接近原本，總距離是原本的 0.8–1.04 倍（輕輕一撥的短一些），並且是平滑
    /// 減速到停。不足一個像素的零頭累加到下一格。
    static let pixelsPerVelocityUnit: CGFloat = 0.8

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

    /// 以新的速度開始滑；非有限值直接忽略。
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

    public mutating func tick() -> Tick {
        guard isScrolling else { return .idle }

        velocityX *= Self.decayPerTick
        velocityY *= Self.decayPerTick

        if abs(velocityX) < minimumVelocity, abs(velocityY) < minimumVelocity {
            return .finished(emitTerminal: stop())
        }

        let deltaX = Self.takePixels(
            from: &residualX, adding: velocityX * Self.pixelsPerVelocityUnit
        )
        let deltaY = Self.takePixels(
            from: &residualY, adding: velocityY * Self.pixelsPerVelocityUnit
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
