import CoreGraphics

struct ForcePressActionGate {
    static let defaultMaxMovementBeforeForce: CGFloat = 0.05

    let maxMovementBeforeForce: CGFloat

    init(maxMovementBeforeForce: CGFloat = Self.defaultMaxMovementBeforeForce) {
        self.maxMovementBeforeForce = maxMovementBeforeForce
    }

    enum Decision: Equatable {
        case trigger(movementBeforeForce: CGFloat)
        case reject(reason: RejectionReason, movementBeforeForce: CGFloat)
    }

    enum RejectionReason: String {
        case movedTooFarBeforeForce
    }

    func evaluateAtForceThreshold(
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

        return .trigger(movementBeforeForce: movementBeforeForce)
    }
}
