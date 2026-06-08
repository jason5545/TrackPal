import CoreGraphics
import XCTest

final class ForcePressActionGateTests: XCTestCase {
    func testAllowsForceTriggerAfterLongHoldWhenFingerStayedInPlace() {
        let gate = ForcePressActionGate(maxMovementBeforeForce: 0.05)

        let decision = gate.evaluateForce(
            force: 101,
            standardThreshold: 100,
            assistedThreshold: 70,
            touchStartPosition: CGPoint(x: 0.92, y: 0.02),
            forcePosition: CGPoint(x: 0.93, y: 0.02)
        )

        guard case let .trigger(source: source, movementBeforeForce: movementBeforeForce) = decision else {
            return XCTFail("Expected force action to trigger")
        }
        XCTAssertEqual(source, .standard)
        XCTAssertEqual(movementBeforeForce, 0.01, accuracy: 0.0001)
    }

    func testAllowsAssistedForceTriggerForNearThresholdPress() {
        let gate = ForcePressActionGate(maxMovementBeforeForce: 0.05)

        let decision = gate.evaluateForce(
            force: 72,
            standardThreshold: 100,
            assistedThreshold: 70,
            touchStartPosition: CGPoint(x: 0.01, y: 0.91),
            forcePosition: CGPoint(x: 0.01, y: 0.92)
        )

        guard case let .trigger(source: source, movementBeforeForce: movementBeforeForce) = decision else {
            return XCTFail("Expected assisted force action to trigger")
        }
        XCTAssertEqual(source, .assisted)
        XCTAssertEqual(movementBeforeForce, 0.01, accuracy: 0.0001)
    }

    func testRejectsForceBelowAssistedThreshold() {
        let gate = ForcePressActionGate(maxMovementBeforeForce: 0.05)

        let decision = gate.evaluateForce(
            force: 69,
            standardThreshold: 100,
            assistedThreshold: 70,
            touchStartPosition: CGPoint(x: 0.01, y: 0.91),
            forcePosition: CGPoint(x: 0.01, y: 0.92)
        )

        guard case let .reject(reason: reason, movementBeforeForce: movementBeforeForce) = decision else {
            return XCTFail("Expected sub-threshold force action to be rejected")
        }
        XCTAssertEqual(reason, .belowAssistedForce)
        XCTAssertEqual(movementBeforeForce, 0.01, accuracy: 0.0001)
    }

    func testRejectsForceTriggerAfterLargePreForceMovement() {
        let gate = ForcePressActionGate(maxMovementBeforeForce: 0.05)

        let decision = gate.evaluateForce(
            force: 200,
            standardThreshold: 100,
            assistedThreshold: 70,
            touchStartPosition: CGPoint(x: 0.92, y: 0.02),
            forcePosition: CGPoint(x: 0.80, y: 0.02)
        )

        guard case let .reject(reason: reason, movementBeforeForce: movementBeforeForce) = decision else {
            return XCTFail("Expected force action to be rejected")
        }
        XCTAssertEqual(reason, .movedTooFarBeforeForce)
        XCTAssertEqual(movementBeforeForce, 0.12, accuracy: 0.0001)
    }

    func testRejectsMovementAtLegacyTapBoundary() {
        let gate = ForcePressActionGate(maxMovementBeforeForce: 0.05)

        let decision = gate.evaluateForce(
            force: 200,
            standardThreshold: 100,
            assistedThreshold: 70,
            touchStartPosition: CGPoint(x: 0.0, y: 0.0),
            forcePosition: CGPoint(x: 0.05, y: 0.0)
        )

        guard case let .reject(reason: reason, movementBeforeForce: movementBeforeForce) = decision else {
            return XCTFail("Expected force action to be rejected")
        }
        XCTAssertEqual(reason, .movedTooFarBeforeForce)
        XCTAssertEqual(movementBeforeForce, 0.05, accuracy: 0.0001)
    }
}
