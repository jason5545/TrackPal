import CoreGraphics
import Foundation

/// 把一筆實機軌跡丟進真正的 `HorizontalStripIntentGate` 重算。
///
/// 改門檻之前先用這個看「如果規則是這樣，當時每一次接觸會怎麼判」。
/// 判斷邏輯就是 App 裡跑的那一份，沒有另外的複本要同步。
public enum StripGateReplay {
    /// 試算用的門檻覆寫；沒給的欄位用 gate 的預設值。
    public struct Overrides: Sendable, Equatable {
        public var activationDistance: Double?
        public var cautiousActivationDistance: Double?
        public var minimumWindowDuration: Double?
        public var cautiousMinimumWindowDuration: Double?
        public var maximumSlope: Double?
        public var maximumDescentSlope: Double?
        public var wanderPathBudget: Double?
        /// 游標活動結束後多久內落指算接力移游標。
        public var pointerWindow: Double?
        /// 水平捲動結束後多久內落指算接著捲。
        public var scrollWindow: Double?

        public init() {}

        /// 命令列的 `名稱=數值`。認得的名稱：`D`、`DC`、`T`、`TC`、`slope`、
        /// `descent`、`wander`、`window`、`scrollWindow`。
        public static let argumentNames = [
            "D", "DC", "T", "TC", "slope", "descent", "wander", "window",
            "scrollWindow",
        ]

        /// 回傳 false 表示名稱不認得。
        public mutating func set(_ name: String, to value: Double) -> Bool {
            switch name {
            case "D": activationDistance = value
            case "DC": cautiousActivationDistance = value
            case "T": minimumWindowDuration = value
            case "TC": cautiousMinimumWindowDuration = value
            case "slope": maximumSlope = value
            case "descent": maximumDescentSlope = value
            case "wander": wanderPathBudget = value
            case "window": pointerWindow = value
            case "scrollWindow": scrollWindow = value
            default: return false
            }
            return true
        }
    }

    public struct Result: Sendable, Equatable {
        /// `pending`、`activate` 或 `reject:<原因>`。
        public var decision: String
        /// 定案的時間（距離落指的秒數）；沒定案是 nil。
        public var decidedAt: Double?
        public var landedAfterPointerActivity: Bool
        public var continuesRecentScroll: Bool
    }

    /// 只對從水平長條起步的軌跡有意義；其他區域回傳 nil。
    public static func replay(
        _ trace: GestureTrace,
        overrides: Overrides = Overrides()
    ) -> Result? {
        let side: HorizontalStripIntentGate.Side
        switch trace.zone {
        case "bottomEdge": side = .bottom
        case "topEdge": side = .top
        default: return nil
        }

        var configuration = HorizontalStripIntentGate.Configuration(
            stripDepth: CGFloat(trace.stripDepth)
        )
        if let value = overrides.activationDistance {
            configuration.activationDistance = CGFloat(value)
        }
        if let value = overrides.cautiousActivationDistance {
            configuration.cautiousActivationDistance = CGFloat(value)
        }
        if let value = overrides.minimumWindowDuration {
            configuration.minimumWindowDuration = value
        }
        if let value = overrides.cautiousMinimumWindowDuration {
            configuration.cautiousMinimumWindowDuration = value
        }
        if let value = overrides.maximumSlope {
            configuration.maximumSlope = CGFloat(value)
        }
        if let value = overrides.maximumDescentSlope {
            configuration.maximumDescentSlope = CGFloat(value)
        }
        if let value = overrides.wanderPathBudget {
            configuration.wanderPathBudget = CGFloat(value)
        }

        let pointerWindow = overrides.pointerWindow
            ?? PointerActivityRecency.defaultWindow
        let scrollWindow = overrides.scrollWindow
            ?? PointerActivityRecency.scrollContinuationWindow
        let afterPointer = trace.pointerGap
            .map { $0 >= 0 && $0 < pointerWindow } ?? false
        let afterScroll = trace.scrollGap
            .map { $0 >= 0 && $0 < scrollWindow } ?? false

        var gate = HorizontalStripIntentGate(
            side: side,
            configuration: configuration,
            landedAfterPointerActivity: afterPointer,
            continuesRecentScroll: afterScroll
        )

        var decidedAt: Double?
        var decision = HorizontalStripIntentGate.Decision.pending
        for frame in trace.decodedFrames {
            // 抬起中（state 6 以上）的幀不經過過濾，狀態機照常餵給 gate。
            if frame.wasValid || frame.state >= 6 {
                decision = gate.observe(
                    position: CGPoint(x: CGFloat(frame.x), y: CGFloat(frame.y)),
                    timestamp: frame.elapsed
                )
            } else {
                decision = gate.interrupt()
            }
            if decision != .pending {
                decidedAt = frame.elapsed
                break
            }
        }

        let text: String
        switch decision {
        case .pending: text = "pending"
        case .activate: text = "activate"
        case let .reject(reason): text = "reject:\(reason.rawValue)"
        }
        return Result(
            decision: text,
            decidedAt: decidedAt,
            landedAfterPointerActivity: afterPointer,
            continuesRecentScroll: afterScroll
        )
    }
}
