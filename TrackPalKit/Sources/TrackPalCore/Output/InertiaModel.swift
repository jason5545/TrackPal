import CoreGraphics

/// 放開後的慣性捲動：每個 tick 把速度乘上固定的衰減，換成整數像素送出去。
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

    public private(set) var velocityX: CGFloat = 0
    public private(set) var velocityY: CGFloat = 0
    public private(set) var isScrolling = false
    private var hasEmittedMomentumBegan = false

    public init() {}

    public enum Tick: Sendable, Equatable {
        /// 沒在滑。
        case idle
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
        return true
    }

    /// 停下來。回傳是否要補一筆零位移的結束事件（已經送過至少一筆才需要）。
    public mutating func stop() -> Bool {
        let emitTerminal = isScrolling && hasEmittedMomentumBegan
        isScrolling = false
        velocityX = 0
        velocityY = 0
        hasEmittedMomentumBegan = false
        return emitTerminal
    }

    public mutating func tick() -> Tick {
        guard isScrolling else { return .idle }

        velocityX *= Self.decayPerTick
        velocityY *= Self.decayPerTick

        if abs(velocityX) < minimumVelocity, abs(velocityY) < minimumVelocity {
            return .finished(emitTerminal: stop())
        }

        let phase: Int64 = hasEmittedMomentumBegan ? 2 : 1
        hasEmittedMomentumBegan = true
        return .scroll(
            deltaX: Self.pixels(velocityX),
            deltaY: Self.pixels(velocityY),
            momentumPhase: phase
        )
    }

    /// 往零截斷；超出 Int32 範圍時夾住而不是當掉。
    private static func pixels(_ velocity: CGFloat) -> Int32 {
        guard velocity.isFinite else { return 0 }
        let truncated = velocity.rounded(.towardZero)
        if truncated >= CGFloat(Int32.max) { return .max }
        if truncated <= CGFloat(Int32.min) { return .min }
        return Int32(truncated)
    }
}
