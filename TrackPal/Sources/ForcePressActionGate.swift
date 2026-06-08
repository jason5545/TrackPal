import CoreGraphics

struct ForcePressActionGate {
    static let defaultMaxMovementBeforeForce: CGFloat = 0.05

    let maxMovementBeforeForce: CGFloat

    init(maxMovementBeforeForce: CGFloat = Self.defaultMaxMovementBeforeForce) {
        self.maxMovementBeforeForce = maxMovementBeforeForce
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
    }

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

        guard movementBeforeForce < maxMovementBeforeForce else {
            return .reject(
                reason: .movedTooFarBeforeForce,
                movementBeforeForce: movementBeforeForce
            )
        }

        if force >= standardThreshold {
            return .trigger(source: .standard, movementBeforeForce: movementBeforeForce)
        }

        guard force >= assistedThreshold else {
            return .reject(
                reason: .belowAssistedForce,
                movementBeforeForce: movementBeforeForce
            )
        }

        return .trigger(source: .assisted, movementBeforeForce: movementBeforeForce)
    }
}
