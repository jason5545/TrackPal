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

    // [AI-Codex: 2026-07-24] 使用整段觸控的最大偏移量，避免手指移出去再回來後被誤判成穩定按壓。
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
