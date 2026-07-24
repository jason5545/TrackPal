import CoreGraphics

struct ForcePressActionGate {
    static let defaultMaxMovementBeforeForce: CGFloat = 0.05
    static let defaultMaxDurationBeforeForce: Double = 1.0

    let maxMovementBeforeForce: CGFloat
    let maxDurationBeforeForce: Double

    init(
        maxMovementBeforeForce: CGFloat = Self.defaultMaxMovementBeforeForce,
        maxDurationBeforeForce: Double = Self.defaultMaxDurationBeforeForce
    ) {
        self.maxMovementBeforeForce = maxMovementBeforeForce
        self.maxDurationBeforeForce = maxDurationBeforeForce
    }

    enum Decision: Equatable {
        case trigger(source: TriggerSource, movementBeforeForce: CGFloat)
        case reject(reason: RejectionReason, movementBeforeForce: CGFloat)
    }

    enum TriggerSource: String {
        case standard = "force"
        case assisted = "force-assisted"
    }

    enum RejectionReason: String {
        case belowAssistedForce
        case movedTooFarBeforeForce
        case heldTooLongBeforeForce
    }

    // 使用 force 硬體時間以前的最大偏移量，避免手指先移出去再回來，
    // 也避免延後 commit 時把 force 之後的位移倒灌進判斷。
    func evaluateForce(
        force: Float,
        standardThreshold: Float,
        assistedThreshold: Float,
        maximumTouchExcursion: CGFloat,
        touchDuration: Double
    ) -> Decision {
        guard maximumTouchExcursion < maxMovementBeforeForce else {
            return .reject(
                reason: .movedTooFarBeforeForce,
                movementBeforeForce: maximumTouchExcursion
            )
        }

        guard force >= assistedThreshold else {
            return .reject(
                reason: .belowAssistedForce,
                movementBeforeForce: maximumTouchExcursion
            )
        }

        guard touchDuration < maxDurationBeforeForce else {
            return .reject(
                reason: .heldTooLongBeforeForce,
                movementBeforeForce: maximumTouchExcursion
            )
        }

        let source: TriggerSource = force >= standardThreshold ? .standard : .assisted
        return .trigger(source: source, movementBeforeForce: maximumTouchExcursion)
    }

    /// 過渡用 overload。舊呼叫端仍可編譯，但只知道起點到 force centroid 的淨位移；
    /// 新呼叫端應改傳整段觸控的 `maximumTouchExcursion` 與實際 `touchDuration`。
    func evaluateForce(
        force: Float,
        standardThreshold: Float,
        assistedThreshold: Float,
        touchStartPosition: CGPoint,
        forcePosition: CGPoint
    ) -> Decision {
        let movementBeforeForce = hypot(
            forcePosition.x - touchStartPosition.x,
            forcePosition.y - touchStartPosition.y
        )

        return evaluateForce(
            force: force,
            standardThreshold: standardThreshold,
            assistedThreshold: assistedThreshold,
            maximumTouchExcursion: movementBeforeForce,
            touchDuration: 0
        )
    }
}

/// Candidates are already in hardware-time order. Prefer the earliest one that
/// actually triggers; if none does, return the earliest evaluable rejection for
/// diagnostics. This keeps an assisted and standard sample independent.
struct ForcePressCandidateSelection {
    static func preferredIndex(
        in decisions: [ForcePressActionGate.Decision?]
    ) -> Int? {
        if let triggeringIndex = decisions.firstIndex(where: { decision in
            guard let decision else { return false }
            if case .trigger = decision { return true }
            return false
        }) {
            return triggeringIndex
        }
        return decisions.firstIndex { $0 != nil }
    }
}

/// Timestamped cumulative excursion for correlating the independent touch and
/// force callback streams. Values never decrease, so moving away and returning
/// to the start cannot make a later force sample look stationary.
struct TouchExcursionTimeline {
    private(set) var snapshots: [(timestamp: Double, maximumExcursion: CGFloat)] = []

    mutating func begin(at timestamp: Double) {
        snapshots.removeAll(keepingCapacity: true)
        guard timestamp.isFinite else { return }
        snapshots.append((timestamp: timestamp, maximumExcursion: 0))
    }

    mutating func record(timestamp: Double, maximumExcursion: CGFloat) {
        guard timestamp.isFinite,
              maximumExcursion.isFinite,
              maximumExcursion >= 0,
              let last = snapshots.last,
              timestamp >= last.timestamp else {
            return
        }

        let cumulativeMaximum = max(last.maximumExcursion, maximumExcursion)
        if timestamp == last.timestamp {
            snapshots[snapshots.count - 1] = (
                timestamp: timestamp,
                maximumExcursion: cumulativeMaximum
            )
        } else if cumulativeMaximum > last.maximumExcursion {
            snapshots.append((
                timestamp: timestamp,
                maximumExcursion: cumulativeMaximum
            ))
        }
    }

    func maximumExcursion(through timestamp: Double) -> CGFloat? {
        guard timestamp.isFinite else { return nil }
        return snapshots.reversed().first {
            $0.timestamp <= timestamp
        }?.maximumExcursion
    }

    mutating func reset() {
        snapshots.removeAll(keepingCapacity: true)
    }
}

/// Bounded policy for a standard-force sample that trails the first movement
/// cap crossing because touch and force arrive on independent sensor streams.
/// Assisted pressure never gets this allowance, and the real sample-time
/// excursion remains visible to the force gate and diagnostics.
struct CornerForceCrossingGrace {
    static let defaultBaseMaximumExcursion: CGFloat = 0.025
    static let defaultAcceptanceWindow: Double = 0.060
    static let defaultDecisionHoldWindow: Double = 0.080
    static let defaultMaximumCrossingExcursion: CGFloat = 0.030
    static let defaultMaximumExcursionAtForce: CGFloat = 0.050

    let crossingTimestamp: Double
    let crossingArrivalUptime: Double
    let maximumExcursionBeforeCrossing: CGFloat
    let maximumExcursionAtCrossing: CGFloat
    let baseMaximumExcursion: CGFloat
    let acceptanceWindow: Double
    let decisionHoldWindow: Double
    let maximumCrossingExcursion: CGFloat
    let maximumExcursionAtForce: CGFloat

    init(
        crossingTimestamp: Double,
        crossingArrivalUptime: Double,
        maximumExcursionBeforeCrossing: CGFloat,
        maximumExcursionAtCrossing: CGFloat,
        baseMaximumExcursion: CGFloat = Self.defaultBaseMaximumExcursion,
        acceptanceWindow: Double = Self.defaultAcceptanceWindow,
        decisionHoldWindow: Double = Self.defaultDecisionHoldWindow,
        maximumCrossingExcursion: CGFloat = Self.defaultMaximumCrossingExcursion,
        maximumExcursionAtForce: CGFloat = Self.defaultMaximumExcursionAtForce
    ) {
        self.crossingTimestamp = crossingTimestamp
        self.crossingArrivalUptime = crossingArrivalUptime
        self.maximumExcursionBeforeCrossing = maximumExcursionBeforeCrossing
        self.maximumExcursionAtCrossing = maximumExcursionAtCrossing
        self.baseMaximumExcursion = baseMaximumExcursion
        self.acceptanceWindow = acceptanceWindow
        self.decisionHoldWindow = decisionHoldWindow
        self.maximumCrossingExcursion = maximumCrossingExcursion
        self.maximumExcursionAtForce = maximumExcursionAtForce
    }

    struct MovementPolicy: Equatable {
        let observedMaximumExcursion: CGFloat
        let maximumAllowedExcursion: CGFloat
        let usedLateStandardForceGrace: Bool
        let hardwareDelayAfterCrossing: Double?
        let arrivalDelayAfterCrossing: Double?
    }

    func movementPolicy(
        hasAvailableScrollAxis: Bool,
        force: Float,
        standardThreshold: Float,
        forceTimestamp: Double,
        forceSampleUptime: Double,
        observedMaximumExcursion: CGFloat
    ) -> MovementPolicy {
        let hardwareDelay = forceTimestamp - crossingTimestamp
        let arrivalDelay = forceSampleUptime - crossingArrivalUptime
        let canUseGrace = !hasAvailableScrollAxis
            && hasValidCrossing
            && force.isFinite
            && standardThreshold.isFinite
            && standardThreshold > 0
            && force >= standardThreshold
            && forceTimestamp.isFinite
            && hardwareDelay > 0
            && hardwareDelay < acceptanceWindow
            && forceSampleUptime.isFinite
            && forceSampleUptime >= 0
            && arrivalDelay < decisionHoldWindow
            && observedMaximumExcursion.isFinite
            && observedMaximumExcursion >= maximumExcursionAtCrossing
            && observedMaximumExcursion < maximumExcursionAtForce

        guard canUseGrace else {
            return MovementPolicy(
                observedMaximumExcursion: observedMaximumExcursion,
                maximumAllowedExcursion: baseMaximumExcursion,
                usedLateStandardForceGrace: false,
                hardwareDelayAfterCrossing: nil,
                arrivalDelayAfterCrossing: nil
            )
        }

        return MovementPolicy(
            observedMaximumExcursion: observedMaximumExcursion,
            maximumAllowedExcursion: maximumExcursionAtForce,
            usedLateStandardForceGrace: true,
            hardwareDelayAfterCrossing: hardwareDelay,
            arrivalDelayAfterCrossing: arrivalDelay
        )
    }

    func shouldHoldDecision(
        hasAvailableScrollAxis: Bool,
        atTouchTimestamp touchTimestamp: Double,
        decisionUptime: Double
    ) -> Bool {
        guard !hasAvailableScrollAxis,
              hasValidCrossing,
              touchTimestamp.isFinite,
              decisionUptime.isFinite else {
            return false
        }
        let hardwareElapsed = touchTimestamp - crossingTimestamp
        let arrivalElapsed = decisionUptime - crossingArrivalUptime
        return hardwareElapsed >= 0
            && hardwareElapsed < decisionHoldWindow
            && arrivalElapsed >= 0
            && arrivalElapsed < decisionHoldWindow
    }

    private var hasValidCrossing: Bool {
        crossingTimestamp.isFinite
            && crossingArrivalUptime.isFinite
            && crossingArrivalUptime >= 0
            && baseMaximumExcursion.isFinite
            && baseMaximumExcursion > 0
            && acceptanceWindow.isFinite
            && acceptanceWindow > 0
            && decisionHoldWindow.isFinite
            && decisionHoldWindow >= acceptanceWindow
            && maximumCrossingExcursion.isFinite
            && maximumCrossingExcursion > baseMaximumExcursion
            && maximumExcursionAtForce.isFinite
            && maximumExcursionAtForce > maximumCrossingExcursion
            && maximumExcursionBeforeCrossing.isFinite
            && maximumExcursionBeforeCrossing >= 0
            && maximumExcursionBeforeCrossing < baseMaximumExcursion
            && maximumExcursionAtCrossing.isFinite
            && maximumExcursionAtCrossing >= baseMaximumExcursion
            && maximumExcursionAtCrossing < maximumCrossingExcursion
    }
}
