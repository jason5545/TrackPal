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

    func testExcursionTimelineExcludesMovementAfterForceTimestamp() throws {
        var timeline = TouchExcursionTimeline()
        timeline.begin(at: 10.0)
        timeline.record(timestamp: 10.1, maximumExcursion: 0.01)
        timeline.record(timestamp: 10.2, maximumExcursion: 0.03)

        XCTAssertEqual(
            try XCTUnwrap(timeline.maximumExcursion(through: 10.15)),
            0.01,
            accuracy: 0.0001
        )
    }

    func testExcursionTimelineRetainsEarlierPeak() throws {
        var timeline = TouchExcursionTimeline()
        timeline.begin(at: 20.0)
        timeline.record(timestamp: 20.1, maximumExcursion: 0.03)
        timeline.record(timestamp: 20.2, maximumExcursion: 0.005)

        XCTAssertEqual(
            try XCTUnwrap(timeline.maximumExcursion(through: 20.2)),
            0.03,
            accuracy: 0.0001
        )
    }

    func testExcursionTimelineIncludesTouchAtSameTimestampAsForce() throws {
        var timeline = TouchExcursionTimeline()
        timeline.begin(at: 30.0)
        timeline.record(timestamp: 30.1, maximumExcursion: 0.03)

        XCTAssertEqual(
            try XCTUnwrap(timeline.maximumExcursion(through: 30.1)),
            0.03,
            accuracy: 0.0001
        )
    }

    func testExcursionTimelineUsesHardwareTimestampDespiteLateLookup() throws {
        var timeline = TouchExcursionTimeline()
        timeline.begin(at: 40.0)
        timeline.record(timestamp: 40.1, maximumExcursion: 0.01)
        timeline.record(timestamp: 40.3, maximumExcursion: 0.04)

        // The query can happen much later; only the force hardware timestamp
        // controls which touch evidence is visible.
        XCTAssertEqual(
            try XCTUnwrap(timeline.maximumExcursion(through: 40.2)),
            0.01,
            accuracy: 0.0001
        )
    }

    func testCornerCrossingGraceCoversObservedStandardForceDelays() {
        let grace = makeCornerGrace(
            beforeCrossing: 0.0247,
            atCrossing: 0.0259
        )

        let eightMilliseconds = movementPolicy(
            grace: grace,
            force: 100,
            forceTimestamp: 0.008,
            forceSampleUptime: 0.010,
            observedMaximumExcursion: 0.0262
        )
        let sixteenMilliseconds = movementPolicy(
            grace: grace,
            force: 112,
            forceTimestamp: 0.016,
            forceSampleUptime: 0.018,
            observedMaximumExcursion: 0.0270
        )

        XCTAssertTrue(eightMilliseconds.usedLateStandardForceGrace)
        XCTAssertTrue(sixteenMilliseconds.usedLateStandardForceGrace)
        XCTAssertEqual(eightMilliseconds.observedMaximumExcursion, 0.0262, accuracy: 0.0001)
        XCTAssertEqual(sixteenMilliseconds.observedMaximumExcursion, 0.0270, accuracy: 0.0001)
        XCTAssertEqual(eightMilliseconds.maximumAllowedExcursion, 0.05, accuracy: 0.0001)
        XCTAssertEqual(sixteenMilliseconds.maximumAllowedExcursion, 0.05, accuracy: 0.0001)
        XCTAssertEqual(
            eightMilliseconds.hardwareDelayAfterCrossing ?? 0,
            0.008,
            accuracy: 0.000_001
        )
    }

    func testCornerCrossingGraceKeepsObservedMovementVisibleToGate() {
        let policy = movementPolicy(
            grace: makeCornerGrace(),
            force: 100,
            forceTimestamp: 0.056,
            forceSampleUptime: 0.058,
            observedMaximumExcursion: 0.0367
        )
        let gate = ForcePressActionGate(
            maxMovementBeforeForce: policy.maximumAllowedExcursion
        )

        let decision = gate.evaluateForce(
            force: 100,
            standardThreshold: 100,
            assistedThreshold: 70,
            maximumTouchExcursion: policy.observedMaximumExcursion,
            touchDuration: 0.2
        )

        guard case let .trigger(source, observedMovement) = decision else {
            return XCTFail("Expected bounded standard-force grace to trigger")
        }
        XCTAssertEqual(source, .standard)
        XCTAssertEqual(observedMovement, 0.0367, accuracy: 0.0001)
    }

    func testCornerCrossingGraceNeverWidensAssistedForceMovementCap() {
        let policy = movementPolicy(
            grace: makeCornerGrace(),
            force: 71,
            forceTimestamp: 0.056,
            forceSampleUptime: 0.058,
            observedMaximumExcursion: 0.0367
        )

        XCTAssertFalse(policy.usedLateStandardForceGrace)
        XCTAssertEqual(policy.maximumAllowedExcursion, 0.025, accuracy: 0.0001)

        let decision = ForcePressActionGate(
            maxMovementBeforeForce: policy.maximumAllowedExcursion
        ).evaluateForce(
            force: 71,
            standardThreshold: 100,
            assistedThreshold: 70,
            maximumTouchExcursion: policy.observedMaximumExcursion,
            touchDuration: 0.2
        )
        guard case let .reject(reason, observedMovement) = decision else {
            return XCTFail("Expected assisted sample outside base cap to reject")
        }
        XCTAssertEqual(reason, .movedTooFarBeforeForce)
        XCTAssertEqual(observedMovement, 0.0367, accuracy: 0.0001)
    }

    func testCornerCrossingGraceRequiresStandardForceAndNoScrollAxis() {
        let grace = makeCornerGrace()
        let belowStandard = movementPolicy(grace: grace, force: 99.999)
        let withAvailableAxis = movementPolicy(
            grace: grace,
            hasAvailableScrollAxis: true
        )
        let infiniteForce = movementPolicy(grace: grace, force: .infinity)

        XCTAssertFalse(belowStandard.usedLateStandardForceGrace)
        XCTAssertFalse(withAvailableAxis.usedLateStandardForceGrace)
        XCTAssertFalse(infiniteForce.usedLateStandardForceGrace)
    }

    func testCornerCrossingGraceUsesStrictHardwareDelayBounds() {
        let grace = makeCornerGrace()
        let justInside = movementPolicy(
            grace: grace,
            forceTimestamp: CornerForceCrossingGrace.defaultAcceptanceWindow.nextDown
        )
        let sameTimestamp = movementPolicy(grace: grace, forceTimestamp: 0)
        let beforeCrossing = movementPolicy(grace: grace, forceTimestamp: -0.001)
        let exactLimit = movementPolicy(
            grace: grace,
            forceTimestamp: CornerForceCrossingGrace.defaultAcceptanceWindow
        )

        XCTAssertTrue(justInside.usedLateStandardForceGrace)
        XCTAssertFalse(sameTimestamp.usedLateStandardForceGrace)
        XCTAssertFalse(beforeCrossing.usedLateStandardForceGrace)
        XCTAssertFalse(exactLimit.usedLateStandardForceGrace)
    }

    func testCornerCrossingGraceUsesStrictCrossingBounds() {
        let exactBaseCrossing = movementPolicy(
            grace: makeCornerGrace(atCrossing: 0.025),
            observedMaximumExcursion: 0.026
        )
        let beforeAlreadyAtBase = movementPolicy(
            grace: makeCornerGrace(beforeCrossing: 0.025)
        )
        let neverCrossed = movementPolicy(
            grace: makeCornerGrace(atCrossing: 0.0249)
        )
        let justInsideMaximum = movementPolicy(
            grace: makeCornerGrace(atCrossing: CGFloat(0.030).nextDown),
            observedMaximumExcursion: CGFloat(0.030).nextDown
        )
        let exactMaximum = movementPolicy(
            grace: makeCornerGrace(atCrossing: 0.030),
            observedMaximumExcursion: 0.031
        )

        XCTAssertTrue(exactBaseCrossing.usedLateStandardForceGrace)
        XCTAssertFalse(beforeAlreadyAtBase.usedLateStandardForceGrace)
        XCTAssertFalse(neverCrossed.usedLateStandardForceGrace)
        XCTAssertTrue(justInsideMaximum.usedLateStandardForceGrace)
        XCTAssertFalse(exactMaximum.usedLateStandardForceGrace)
    }

    func testCornerCrossingGraceUsesStrictObservedMovementBounds() {
        let justInside = movementPolicy(
            grace: makeCornerGrace(),
            observedMaximumExcursion: CGFloat(0.050).nextDown
        )
        let exactMaximum = movementPolicy(
            grace: makeCornerGrace(),
            observedMaximumExcursion: 0.050
        )
        let belowCrossingSnapshot = movementPolicy(
            grace: makeCornerGrace(atCrossing: 0.026),
            observedMaximumExcursion: 0.0259
        )

        XCTAssertTrue(justInside.usedLateStandardForceGrace)
        XCTAssertFalse(exactMaximum.usedLateStandardForceGrace)
        XCTAssertFalse(belowCrossingSnapshot.usedLateStandardForceGrace)
    }

    func testCornerCrossingGraceRejectsForceCallbackAtArrivalDeadline() {
        let grace = makeCornerGrace()
        let justInside = movementPolicy(
            grace: grace,
            forceSampleUptime:
                CornerForceCrossingGrace.defaultDecisionHoldWindow.nextDown
        )
        let exactDeadline = movementPolicy(
            grace: grace,
            forceSampleUptime:
                CornerForceCrossingGrace.defaultDecisionHoldWindow
        )

        XCTAssertTrue(justInside.usedLateStandardForceGrace)
        XCTAssertFalse(exactDeadline.usedLateStandardForceGrace)
    }

    func testCornerCrossingGraceDecisionHoldHasStrictHardwareAndArrivalBounds() {
        let grace = makeCornerGrace()

        XCTAssertTrue(grace.shouldHoldDecision(
            hasAvailableScrollAxis: false,
            atTouchTimestamp: 0,
            decisionUptime: 0
        ))
        XCTAssertTrue(grace.shouldHoldDecision(
            hasAvailableScrollAxis: false,
            atTouchTimestamp: CornerForceCrossingGrace.defaultDecisionHoldWindow.nextDown,
            decisionUptime:
                CornerForceCrossingGrace.defaultDecisionHoldWindow.nextDown
        ))
        XCTAssertFalse(grace.shouldHoldDecision(
            hasAvailableScrollAxis: false,
            atTouchTimestamp: CornerForceCrossingGrace.defaultDecisionHoldWindow,
            decisionUptime: 0.079
        ))
        XCTAssertFalse(grace.shouldHoldDecision(
            hasAvailableScrollAxis: false,
            atTouchTimestamp: 0.079,
            decisionUptime:
                CornerForceCrossingGrace.defaultDecisionHoldWindow
        ))
        XCTAssertFalse(grace.shouldHoldDecision(
            hasAvailableScrollAxis: true,
            atTouchTimestamp: 0.001,
            decisionUptime: 0.001
        ))
    }

    func testCornerCrossingGraceRejectsNonFiniteEvidence() {
        let invalidTimestamp = movementPolicy(
            grace: makeCornerGrace(),
            forceTimestamp: .nan
        )
        let invalidMovement = movementPolicy(
            grace: makeCornerGrace(),
            observedMaximumExcursion: .infinity
        )
        let invalidCrossing = movementPolicy(
            grace: CornerForceCrossingGrace(
                crossingTimestamp: 0,
                crossingArrivalUptime: 0,
                maximumExcursionBeforeCrossing: .nan,
                maximumExcursionAtCrossing: 0.026
            )
        )

        XCTAssertFalse(invalidTimestamp.usedLateStandardForceGrace)
        XCTAssertFalse(invalidMovement.usedLateStandardForceGrace)
        XCTAssertFalse(invalidCrossing.usedLateStandardForceGrace)
    }

    func testCandidateSelectionKeepsEarlierValidAssistedSample() {
        let assisted: ForcePressActionGate.Decision = .trigger(
            source: .assisted,
            movementBeforeForce: 0.010
        )
        let laterStandard: ForcePressActionGate.Decision = .reject(
            reason: .heldTooLongBeforeForce,
            movementBeforeForce: 0.030
        )

        XCTAssertEqual(
            ForcePressCandidateSelection.preferredIndex(
                in: [Optional(assisted), Optional(laterStandard)]
            ),
            0
        )
    }

    func testCandidateSelectionUsesLaterStandardWhenAssistedCannotPass() {
        let assisted: ForcePressActionGate.Decision = .reject(
            reason: .movedTooFarBeforeForce,
            movementBeforeForce: 0.026
        )
        let standard: ForcePressActionGate.Decision = .trigger(
            source: .standard,
            movementBeforeForce: 0.031
        )

        XCTAssertEqual(
            ForcePressCandidateSelection.preferredIndex(
                in: [Optional(assisted), Optional(standard)]
            ),
            1
        )
    }

    func testCandidateSelectionKeepsEarliestWhenBothCanTrigger() {
        let assisted: ForcePressActionGate.Decision = .trigger(
            source: .assisted,
            movementBeforeForce: 0.010
        )
        let standard: ForcePressActionGate.Decision = .trigger(
            source: .standard,
            movementBeforeForce: 0.020
        )

        XCTAssertEqual(
            ForcePressCandidateSelection.preferredIndex(
                in: [Optional(assisted), Optional(standard)]
            ),
            0
        )
    }

    private func makeCornerGrace(
        beforeCrossing: CGFloat = 0.024,
        atCrossing: CGFloat = 0.026
    ) -> CornerForceCrossingGrace {
        CornerForceCrossingGrace(
            crossingTimestamp: 0,
            crossingArrivalUptime: 0,
            maximumExcursionBeforeCrossing: beforeCrossing,
            maximumExcursionAtCrossing: atCrossing
        )
    }

    private func movementPolicy(
        grace: CornerForceCrossingGrace,
        hasAvailableScrollAxis: Bool = false,
        force: Float = 100,
        forceTimestamp: Double = 0.010,
        forceSampleUptime: Double = 0.012,
        observedMaximumExcursion: CGFloat = 0.027
    ) -> CornerForceCrossingGrace.MovementPolicy {
        grace.movementPolicy(
            hasAvailableScrollAxis: hasAvailableScrollAxis,
            force: force,
            standardThreshold: 100,
            forceTimestamp: forceTimestamp,
            forceSampleUptime: forceSampleUptime,
            observedMaximumExcursion: observedMaximumExcursion
        )
    }
}
