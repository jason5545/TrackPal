import CoreGraphics
import XCTest

final class ForcePressActionGateTests: XCTestCase {
    func testAllowsForceTriggerAfterLongHoldWhenFingerStayedInPlace() {
        let gate = ForcePressActionGate(
            maxMovementBeforeForce: 0.05,
            maxDurationBeforeForce: 1.0
        )

        let decision = gate.evaluateForce(
            force: 101,
            standardThreshold: 100,
            assistedThreshold: 70,
            maximumTouchExcursion: 0.01,
            touchDuration: 0.99
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
            maximumTouchExcursion: 0.01,
            touchDuration: 0.2
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
            maximumTouchExcursion: 0.01,
            touchDuration: 0.2
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
            maximumTouchExcursion: 0.12,
            touchDuration: 0.2
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
            maximumTouchExcursion: 0.05,
            touchDuration: 0.2
        )

        guard case let .reject(reason: reason, movementBeforeForce: movementBeforeForce) = decision else {
            return XCTFail("Expected force action to be rejected")
        }
        XCTAssertEqual(reason, .movedTooFarBeforeForce)
        XCTAssertEqual(movementBeforeForce, 0.05, accuracy: 0.0001)
    }

    func testRejectsScrollLikeMovementWithCornerSizedGate() {
        let gate = ForcePressActionGate(maxMovementBeforeForce: 0.025)

        let decision = gate.evaluateForce(
            force: 200,
            standardThreshold: 100,
            assistedThreshold: 100,
            maximumTouchExcursion: 0.03,
            touchDuration: 0.2
        )

        guard case let .reject(reason: reason, movementBeforeForce: movementBeforeForce) = decision else {
            return XCTFail("Expected corner force action to be rejected after scroll-like movement")
        }
        XCTAssertEqual(reason, .movedTooFarBeforeForce)
        XCTAssertEqual(movementBeforeForce, 0.03, accuracy: 0.0001)
    }

    func testRejectsTouchThatMovedAwayBeforeReturningToStart() {
        let gate = ForcePressActionGate(maxMovementBeforeForce: 0.05)
        let touchStart = CGPoint(x: 0.90, y: 0.02)
        let touchPositions = [
            touchStart,
            CGPoint(x: 0.97, y: 0.02),
            touchStart
        ]
        let maximumTouchExcursion = touchPositions
            .map { hypot($0.x - touchStart.x, $0.y - touchStart.y) }
            .max() ?? 0

        XCTAssertEqual(touchPositions.last, touchStart, "Net movement should be zero")

        let decision = gate.evaluateForce(
            force: 200,
            standardThreshold: 100,
            assistedThreshold: 70,
            maximumTouchExcursion: maximumTouchExcursion,
            touchDuration: 0.2
        )

        guard case let .reject(reason: reason, movementBeforeForce: movementBeforeForce) = decision else {
            return XCTFail("Expected returned touch to retain its maximum excursion and be rejected")
        }
        XCTAssertEqual(reason, .movedTooFarBeforeForce)
        XCTAssertEqual(movementBeforeForce, 0.07, accuracy: 0.0001)
    }

    func testRejectsForceThatArrivesAtMaximumDuration() {
        let gate = ForcePressActionGate(maxDurationBeforeForce: 1.0)

        let decision = gate.evaluateForce(
            force: 200,
            standardThreshold: 100,
            assistedThreshold: 70,
            maximumTouchExcursion: 0.01,
            touchDuration: 1.0
        )

        guard case let .reject(reason: reason, movementBeforeForce: movementBeforeForce) = decision else {
            return XCTFail("Expected late force action to be rejected")
        }
        XCTAssertEqual(reason, .heldTooLongBeforeForce)
        XCTAssertEqual(movementBeforeForce, 0.01, accuracy: 0.0001)
    }

    func testAllowsStableTrackedTouchDespiteSmallForceCentroidDrift() {
        let gate = ForcePressActionGate(maxMovementBeforeForce: 0.025)

        let decision = gate.evaluateForce(
            force: 100,
            standardThreshold: 100,
            assistedThreshold: 70,
            maximumTouchExcursion: 0.004,
            touchDuration: 0.2
        )

        guard case let .trigger(source: source, movementBeforeForce: movementBeforeForce) = decision else {
            return XCTFail("Expected stable tracked touch to trigger")
        }
        XCTAssertEqual(source, .standard)
        XCTAssertEqual(movementBeforeForce, 0.004, accuracy: 0.0001)
    }

    func testLegacyPositionOverloadRemainsAvailableDuringMigration() {
        let gate = ForcePressActionGate(maxMovementBeforeForce: 0.05)

        let decision = gate.evaluateForce(
            force: 101,
            standardThreshold: 100,
            assistedThreshold: 70,
            touchStartPosition: CGPoint(x: 0.92, y: 0.02),
            forcePosition: CGPoint(x: 0.93, y: 0.02)
        )

        guard case let .trigger(source: source, movementBeforeForce: movementBeforeForce) = decision else {
            return XCTFail("Expected legacy overload to keep working during migration")
        }
        XCTAssertEqual(source, .standard)
        XCTAssertEqual(movementBeforeForce, 0.01, accuracy: 0.0001)
    }
}
