import CoreGraphics
import XCTest

final class ForcePressActionGateTests: XCTestCase {
    func testAllowsForceTriggerAfterLongHoldWhenFingerStayedInPlace() {
        let gate = ForcePressActionGate(maxMovementBeforeForce: 0.05)

        let decision = gate.evaluateAtForceThreshold(
            touchStartPosition: CGPoint(x: 0.92, y: 0.02),
            forcePosition: CGPoint(x: 0.93, y: 0.02)
        )

        guard case let .trigger(movementBeforeForce) = decision else {
            return XCTFail("Expected force action to trigger")
        }
        XCTAssertEqual(movementBeforeForce, 0.01, accuracy: 0.0001)
    }

    func testRejectsForceTriggerAfterLargePreForceMovement() {
        let gate = ForcePressActionGate(maxMovementBeforeForce: 0.05)

        let decision = gate.evaluateAtForceThreshold(
            touchStartPosition: CGPoint(x: 0.92, y: 0.02),
            forcePosition: CGPoint(x: 0.80, y: 0.02)
        )

        guard case let .reject(reason, movementBeforeForce) = decision else {
            return XCTFail("Expected force action to be rejected")
        }
        XCTAssertEqual(reason, .movedTooFarBeforeForce)
        XCTAssertEqual(movementBeforeForce, 0.12, accuracy: 0.0001)
    }

    func testRejectsMovementAtLegacyTapBoundary() {
        let gate = ForcePressActionGate(maxMovementBeforeForce: 0.05)

        let decision = gate.evaluateAtForceThreshold(
            touchStartPosition: CGPoint(x: 0.0, y: 0.0),
            forcePosition: CGPoint(x: 0.05, y: 0.0)
        )

        guard case let .reject(reason, movementBeforeForce) = decision else {
            return XCTFail("Expected force action to be rejected")
        }
        XCTAssertEqual(reason, .movedTooFarBeforeForce)
        XCTAssertEqual(movementBeforeForce, 0.05, accuracy: 0.0001)
    }
}
