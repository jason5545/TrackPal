import CoreGraphics
import XCTest

final class ScrollIntentGateTests: XCTestCase {
    func testHorizontalOrdinaryIntentNeedsThreeSamples() {
        var gate = ScrollIntentGate(axis: .horizontal)

        XCTAssertEqual(gate.observe(deltaX: 0.003, deltaY: 0.0004), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0.003, deltaY: 0.0004), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0.003, deltaY: 0.0004),
            .activate(axis: .horizontal)
        )
    }

    func testVerticalOrdinaryIntentNeedsThreeSamples() {
        var gate = ScrollIntentGate(axis: .vertical)

        XCTAssertEqual(gate.observe(deltaX: 0.0002, deltaY: -0.0045), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0.0002, deltaY: -0.0045), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0.0002, deltaY: -0.0045),
            .activate(axis: .vertical)
        )
    }

    func testG60SizedTwoSampleVerticalTraceWaitsForThirdValidSample() {
        var gate = ScrollIntentGate(axis: .vertical)

        XCTAssertEqual(gate.observe(deltaX: 0.00065, deltaY: -0.0064), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0.00065, deltaY: -0.0064), .pending)
        XCTAssertEqual(gate.metrics.netY, -0.0128, accuracy: 0.000_001)
        XCTAssertEqual(
            gate.observe(deltaX: 0.0001, deltaY: -0.0005),
            .activate(axis: .vertical)
        )
    }

    func testInvalidTouchBoundaryPreventsReleaseTailFromConfirmingOldTrace() {
        var gate = ScrollIntentGate(axis: .vertical)

        XCTAssertEqual(gate.observe(deltaX: 0.00065, deltaY: -0.0064), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0.00065, deltaY: -0.0064), .pending)

        // Runtime resets pending evidence as soon as filtering reports an
        // invalid frame. A later lifting tail is therefore a new provisional
        // first sample, not confirmation for the pre-invalid trace.
        gate.reset()
        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: -0.010), .pending)
        XCTAssertEqual(gate.observationCount, 1)
        XCTAssertEqual(gate.metrics.sampleCount, 0)
        XCTAssertTrue(gate.acceptedSamples.isEmpty)
    }

    func testStrongTwoSampleVerticalTraceStillActivatesImmediately() {
        var gate = ScrollIntentGate(axis: .vertical)

        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: -0.009), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0, deltaY: -0.009),
            .activate(axis: .vertical)
        )
        XCTAssertEqual(gate.metrics.netY, -0.017, accuracy: 0.000_001)
    }

    func testTwoSampleFastDisplacementBoundaryActivates() {
        var gate = ScrollIntentGate(axis: .vertical)

        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.007), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0, deltaY: 0.009),
            .activate(axis: .vertical)
        )
        XCTAssertEqual(gate.metrics.netY, 0.016, accuracy: 0.000_001)
    }

    func testTwoSampleTraceJustBelowFastDisplacementWaitsForThirdSample() {
        var gate = ScrollIntentGate(axis: .vertical)

        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.007), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.00899), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0, deltaY: 0.0005),
            .activate(axis: .vertical)
        )
    }

    func testTwoSampleFastDisplacementStillRequiresFastDominance() {
        var gate = ScrollIntentGate(axis: .vertical)

        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.007), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0.00225, deltaY: 0.009), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0, deltaY: 0.0005),
            .activate(axis: .vertical)
        )
    }

    func testSingleLargeHorizontalSampleCannotActivateWithoutConfirmation() {
        var gate = ScrollIntentGate(axis: .horizontal)

        XCTAssertEqual(gate.observe(deltaX: 0.011, deltaY: 0.0005), .pending)
        XCTAssertEqual(gate.observationCount, 1)
        XCTAssertEqual(gate.metrics.sampleCount, 0)
        XCTAssertTrue(gate.acceptedSamples.isEmpty)
    }

    func testSingleLargeVerticalSampleCannotActivateWithoutConfirmation() {
        var gate = ScrollIntentGate(axis: .vertical)

        XCTAssertEqual(gate.observe(deltaX: 0.0003, deltaY: -0.017), .pending)
        XCTAssertEqual(gate.observationCount, 1)
        XCTAssertEqual(gate.metrics.sampleCount, 0)
        XCTAssertTrue(gate.acceptedSamples.isEmpty)
    }

    func testLargeInitialDeltaActivatesOnlyAfterSameDirectionConfirmation() {
        var gate = ScrollIntentGate(axis: .vertical)

        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.030), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.002), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0, deltaY: 0.002),
            .activate(axis: .vertical)
        )

        XCTAssertEqual(gate.acceptedSamples.count, 3)
        XCTAssertEqual(gate.acceptedSamples[0].dy, 0.008, accuracy: 0.000_001)
        XCTAssertEqual(gate.acceptedSamples[1].dy, 0.002, accuracy: 0.000_001)
        XCTAssertEqual(gate.acceptedSamples[2].dy, 0.002, accuracy: 0.000_001)
        XCTAssertEqual(gate.metrics.netY, 0.012, accuracy: 0.000_001)
    }

    func testLargeInitialDeltaAndOppositeConfirmationCannotActivate() {
        var gate = ScrollIntentGate(axis: .vertical)

        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.030), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: -0.014), .pending)

        XCTAssertEqual(gate.acceptedSamples.count, 2)
        XCTAssertEqual(gate.metrics.netY, -0.006, accuracy: 0.000_001)
        XCTAssertLessThan(gate.metrics.pathCoherence, 0.62)
    }

    func testInitialWrongAxisJumpRemainsBoundedEvidence() {
        var gate = ScrollIntentGate(axis: .horizontal)

        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.030), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0.004, deltaY: 0), .pending)

        XCTAssertEqual(gate.acceptedSamples.count, 2)
        XCTAssertEqual(gate.acceptedSamples[0].dy, 0.008, accuracy: 0.000_001)
        XCTAssertEqual(gate.metrics.normalizedNetX, 0.0064, accuracy: 0.000_001)
        XCTAssertEqual(gate.metrics.netY, 0.008, accuracy: 0.000_001)

        XCTAssertEqual(gate.observe(deltaX: 0.004, deltaY: 0), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0.004, deltaY: 0),
            .activate(axis: .horizontal)
        )
    }

    func testInitialDiagonalSampleIsWinsorizedInPhysicalCoordinates() {
        var gate = ScrollIntentGate(axis: .horizontal)

        XCTAssertEqual(gate.observe(deltaX: 0.006, deltaY: 0.008), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0.001, deltaY: 0), .pending)

        let initial = gate.acceptedSamples[0]
        let physicalMagnitude = hypot(
            initial.dx * ScrollIntentGate.horizontalAspectCompensation,
            initial.dy
        )
        XCTAssertEqual(
            physicalMagnitude,
            ScrollIntentGate.initialSampleMaximumPhysicalMagnitude,
            accuracy: 0.000_001
        )
        XCTAssertEqual(initial.dx / initial.dy, 0.75, accuracy: 0.000_001)
    }

    func testSingleOrdinaryOnAxisSampleStaysPending() {
        var gate = ScrollIntentGate(axis: .vertical)

        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.010), .pending)
    }

    func testLargeOffAxisMovementCannotRejectBeforeThirdSample() {
        var gate = ScrollIntentGate(axis: .horizontal)

        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.020), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.003), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0, deltaY: 0.001),
            .reject(reason: .offAxisDominant)
        )
    }

    func testInitialOffAxisNoiseCanRecoverIntoHorizontalActivation() {
        var gate = ScrollIntentGate(axis: .horizontal)

        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.012), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0.005, deltaY: 0), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0.005, deltaY: 0), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0.005, deltaY: 0),
            .activate(axis: .horizontal)
        )
    }

    func testRightEdgeG200OutwardPrefixCanRestartIntoVerticalActivation() {
        var gate = ScrollIntentGate(
            axis: .vertical,
            configuration: .init(maxSamples: 24)
        )
        let outwardPrefix = Array(
            repeating: ScrollIntentGate.Sample(
                dx: 0.00138,
                dy: -0.00084
            ),
            count: 5
        )

        for (index, sample) in outwardPrefix.enumerated() {
            let decision = gate.observe(sample)
            if index < outwardPrefix.count - 1 {
                XCTAssertEqual(decision, .pending)
            } else {
                XCTAssertEqual(decision, .reject(reason: .offAxisDominant))
            }
        }

        let prefixIsRecoverable = gate
            .isRecoverableOutwardBoundaryPrefix(outwardSign: 1)
            && ScrollIntentRecoveryPolicy.rawOutwardPrefixIsWithinBounds(
                samples: outwardPrefix,
                outwardSign: 1
            )
        XCTAssertTrue(prefixIsRecoverable)
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.shouldBeginEarlyOutwardRecovery(
                alreadyUsed: false,
                prefixIsRecoverable: prefixIsRecoverable
            )
        )

        gate.reset()
        for index in 0..<4 {
            let decision = gate.observe(deltaX: 0, deltaY: 0.0021)
            if index < 3 {
                XCTAssertEqual(decision, .pending)
            } else {
                XCTAssertEqual(decision, .activate(axis: .vertical))
            }
        }
        XCTAssertEqual(gate.acceptedSamples.count, 4)
        XCTAssertTrue(gate.acceptedSamples.allSatisfy { $0.dx == 0 })
    }

    func testRightEdgeG202OutwardPrefixCanRestartIntoVerticalActivation() {
        var gate = ScrollIntentGate(
            axis: .vertical,
            configuration: .init(maxSamples: 24)
        )
        let outwardPrefix = Array(
            repeating: ScrollIntentGate.Sample(
                dx: 0.00134,
                dy: -0.00010
            ),
            count: 5
        )

        outwardPrefix.forEach { _ = gate.observe($0) }
        XCTAssertTrue(gate.isRecoverableOutwardBoundaryPrefix(outwardSign: 1))
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.rawOutwardPrefixIsWithinBounds(
                samples: outwardPrefix,
                outwardSign: 1
            )
        )

        gate.reset()
        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.003), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.003), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0, deltaY: 0.003),
            .activate(axis: .vertical)
        )
    }

    func testRightEdgeInwardPrefixRemainsTerminalCursorMovement() {
        var gate = ScrollIntentGate(
            axis: .vertical,
            configuration: .init(maxSamples: 24)
        )

        let inwardPrefix = Array(
            repeating: ScrollIntentGate.Sample(
                dx: -0.00138,
                dy: -0.00084
            ),
            count: 5
        )
        inwardPrefix.forEach { _ = gate.observe($0) }

        XCTAssertFalse(gate.isRecoverableOutwardBoundaryPrefix(outwardSign: 1))
        XCTAssertFalse(
            ScrollIntentRecoveryPolicy.rawOutwardPrefixIsWithinBounds(
                samples: inwardPrefix,
                outwardSign: 1
            )
        )
    }

    func testClearOutwardCursorMovementExceedsRecoveryCap() {
        var gate = ScrollIntentGate(
            axis: .vertical,
            configuration: .init(maxSamples: 24)
        )
        let outwardMove = Array(
            repeating: ScrollIntentGate.Sample(dx: 0.0035, dy: 0),
            count: 3
        )

        outwardMove.forEach { _ = gate.observe($0) }

        XCTAssertEqual(
            gate.metrics.normalizedNetX,
            0.0168,
            accuracy: 0.000_001
        )
        XCTAssertFalse(gate.isRecoverableOutwardBoundaryPrefix(outwardSign: 1))
        XCTAssertFalse(
            ScrollIntentRecoveryPolicy.rawOutwardPrefixIsWithinBounds(
                samples: outwardMove,
                outwardSign: 1
            )
        )
    }

    func testWinsorizedLargeFirstFrameCannotEnterOutwardRecovery() {
        var gate = ScrollIntentGate(
            axis: .vertical,
            configuration: .init(maxSamples: 24)
        )
        let rawPrefix: [ScrollIntentGate.Sample] = [
            .init(dx: 0.030, dy: 0),
            .init(dx: 0.0013, dy: 0),
            .init(dx: 0.0013, dy: 0),
        ]

        rawPrefix.forEach { _ = gate.observe($0) }

        XCTAssertTrue(gate.isRecoverableOutwardBoundaryPrefix(outwardSign: 1))
        XCTAssertFalse(
            ScrollIntentRecoveryPolicy.rawOutwardPrefixIsWithinBounds(
                samples: rawPrefix,
                outwardSign: 1
            )
        )
    }

    func testFoldbackPrefixCannotEnterOutwardRecovery() {
        var gate = ScrollIntentGate(
            axis: .vertical,
            configuration: .init(maxSamples: 24)
        )
        let foldbackPrefix: [ScrollIntentGate.Sample] = [
            .init(dx: 0.0025, dy: 0.003),
            .init(dx: 0.0025, dy: -0.003),
            .init(dx: 0.0025, dy: 0),
        ]

        foldbackPrefix.forEach { _ = gate.observe($0) }

        XCTAssertTrue(gate.isRecoverableOutwardBoundaryPrefix(outwardSign: 1))
        XCTAssertFalse(
            ScrollIntentRecoveryPolicy.rawOutwardPrefixIsWithinBounds(
                samples: foldbackPrefix,
                outwardSign: 1
            )
        )
    }

    func testOutwardPrefixMustFormBeforeEarlyDeadline() {
        let outwardPrefix = Array(
            repeating: ScrollIntentGate.Sample(
                dx: 0.00138,
                dy: -0.00084
            ),
            count: 5
        )

        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.rawOutwardPrefixIsWithinBounds(
                samples: outwardPrefix,
                outwardSign: 1,
                elapsed: 0.149_999
            )
        )
        XCTAssertFalse(
            ScrollIntentRecoveryPolicy.rawOutwardPrefixIsWithinBounds(
                samples: outwardPrefix,
                outwardSign: 1,
                elapsed: 0.150
            )
        )
        XCTAssertFalse(
            ScrollIntentRecoveryPolicy.rawOutwardPrefixIsWithinBounds(
                samples: outwardPrefix,
                outwardSign: 1,
                elapsed: 0.680
            )
        )
    }

    func testSubthresholdFoldbackCountsTowardRawOutwardPath() {
        var gate = ScrollIntentGate(
            axis: .vertical,
            configuration: .init(maxSamples: 24)
        )
        let hiddenFoldback = (0..<5).flatMap { _ in
            [
                ScrollIntentGate.Sample(dx: 0.00030, dy: 0),
                ScrollIntentGate.Sample(dx: -0.00030, dy: 0),
            ]
        }
        let outwardPrefix = Array(
            repeating: ScrollIntentGate.Sample(
                dx: 0.00138,
                dy: -0.00084
            ),
            count: 5
        )

        outwardPrefix.forEach { _ = gate.observe($0) }

        XCTAssertTrue(gate.isRecoverableOutwardBoundaryPrefix(outwardSign: 1))
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.rawOutwardPrefixIsWithinBounds(
                samples: outwardPrefix,
                outwardSign: 1,
                elapsed: 0.100
            )
        )
        XCTAssertFalse(
            ScrollIntentRecoveryPolicy.rawOutwardPrefixIsWithinBounds(
                samples: hiddenFoldback + outwardPrefix,
                outwardSign: 1,
                elapsed: 0.100
            )
        )
    }

    func testStationaryReanchorDropsEarlierSubactivityNoise() {
        let oldHoldNoise = (0..<100).flatMap { _ in
            [
                ScrollIntentGate.Sample(dx: 0.00002, dy: 0),
                ScrollIntentGate.Sample(dx: -0.00002, dy: 0),
            ]
        }
        let latestStationarySample = ScrollIntentGate.Sample(
            dx: 0.00002,
            dy: 0
        )
        let outwardPrefix = Array(
            repeating: ScrollIntentGate.Sample(
                dx: 0.00138,
                dy: -0.00084
            ),
            count: 5
        )

        XCTAssertFalse(
            ScrollIntentRecoveryPolicy.rawOutwardPrefixIsWithinBounds(
                samples: oldHoldNoise + outwardPrefix,
                outwardSign: 1,
                elapsed: 0.040
            )
        )
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.rawOutwardPrefixIsWithinBounds(
                samples: [latestStationarySample] + outwardPrefix,
                outwardSign: 1,
                elapsed: 0.040
            )
        )
    }

    func testOutwardSettlingRecoveryIsOneShotPerContact() {
        XCTAssertFalse(
            ScrollIntentRecoveryPolicy.shouldBeginEarlyOutwardRecovery(
                alreadyUsed: true,
                prefixIsRecoverable: true
            )
        )
    }

    func testRecoveryWindowStillRequiresFullActivationDistance() {
        var gate = ScrollIntentGate(
            axis: .vertical,
            configuration: .init(maxSamples: 24)
        )

        for _ in 0..<ScrollIntentRecoveryPolicy.defaultRecoveryMaxSamples {
            let decision = gate.observe(deltaX: 0, deltaY: 0.0003)
            XCTAssertEqual(decision, .pending)
        }
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.recoveryHasExpired(
                sampleCount: gate.metrics.sampleCount,
                elapsed: 0.100
            )
        )
    }

    func testAcceptedSamplesPreserveFullActivationDisplacementForFlush() {
        var gate = ScrollIntentGate(axis: .vertical)

        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.006), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.001), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0, deltaY: 0.001),
            .activate(axis: .vertical)
        )

        let replayedDeltaY = gate.acceptedSamples.reduce(CGFloat.zero) { partial, sample in
            partial + sample.dy
        }
        let defaultLinearPixelDelta = replayedDeltaY * 3.0 * 100.0

        XCTAssertEqual(replayedDeltaY, 0.008, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(defaultLinearPixelDelta, 1)
    }

    func testSingleLargeDiagonalSampleDoesNotUseFastActivation() {
        var gate = ScrollIntentGate(axis: .horizontal)

        XCTAssertEqual(gate.observe(deltaX: 0.012, deltaY: 0.010), .pending)
    }

    func testSlowVerticalMovementAccumulatesIntoActivation() {
        var gate = ScrollIntentGate(axis: .vertical)

        for _ in 0..<5 {
            XCTAssertEqual(gate.observe(deltaX: 0.0001, deltaY: 0.0015), .pending)
        }
        XCTAssertEqual(
            gate.observe(deltaX: 0.0001, deltaY: 0.0015),
            .activate(axis: .vertical)
        )
    }

    func testSlowHorizontalMovementAccumulatesIntoActivation() {
        var gate = ScrollIntentGate(axis: .horizontal)

        for _ in 0..<4 {
            XCTAssertEqual(gate.observe(deltaX: 0.001, deltaY: 0.0001), .pending)
        }
        XCTAssertEqual(
            gate.observe(deltaX: 0.001, deltaY: 0.0001),
            .activate(axis: .horizontal)
        )
    }

    func testSlowVerticalMovementWithTremorStillActivates() {
        var gate = ScrollIntentGate(axis: .vertical)

        for index in 0..<4 {
            let dx: CGFloat = index.isMultiple(of: 2) ? 0.0004 : -0.0004
            XCTAssertEqual(gate.observe(deltaX: dx, deltaY: 0.0016), .pending)
        }
        XCTAssertEqual(
            gate.observe(deltaX: 0.0004, deltaY: 0.0016),
            .activate(axis: .vertical)
        )
    }

    func testTapSizedMovementNeverActivatesAndReportsInsufficientMovement() {
        var gate = ScrollIntentGate(axis: .vertical)

        for index in 0..<8 {
            let decision = gate.observe(deltaX: 0.00005, deltaY: 0.0003)
            if index < 7 {
                XCTAssertEqual(decision, .pending)
            } else {
                XCTAssertEqual(decision, .reject(reason: .insufficientMovement))
            }
        }
    }

    func testBackAndForthJitterNeverActivatesAndReportsIncoherentMovement() {
        var gate = ScrollIntentGate(axis: .vertical)

        for index in 0..<8 {
            let dy: CGFloat = index.isMultiple(of: 2) ? 0.004 : -0.004
            let decision = gate.observe(deltaX: 0, deltaY: dy)
            if index < 7 {
                XCTAssertEqual(decision, .pending)
            } else {
                XCTAssertEqual(decision, .reject(reason: .incoherentMovement))
            }
        }
    }

    func testDeadlineReportsOffAxisReasonEvenBelowEarlyRejectDistance() {
        var gate = ScrollIntentGate(axis: .horizontal)

        for index in 0..<8 {
            let decision = gate.observe(deltaX: 0, deltaY: 0.001125)
            if index < 7 {
                XCTAssertEqual(decision, .pending)
            } else {
                XCTAssertEqual(decision, .reject(reason: .offAxisDominant))
            }
        }
    }

    func testDeadlineDistinguishesCoherentButInsufficientOnAxisMovement() {
        let configuration = ScrollIntentGate.Configuration(
            maxSamples: 3,
            activationDisplacement: 0.020
        )
        var gate = ScrollIntentGate(axis: .vertical, configuration: configuration)

        XCTAssertEqual(gate.observe(deltaX: 0.005, deltaY: 0.006), .pending)
        XCTAssertEqual(gate.observe(deltaX: -0.005, deltaY: 0.006), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0, deltaY: 0.006),
            .reject(reason: .insufficientOnAxisMovement)
        )
    }

    func testHorizontalAspectCompensationAffectsDominance() {
        var gate = ScrollIntentGate(axis: .horizontal)

        XCTAssertEqual(gate.observe(deltaX: 0.003, deltaY: 0.002), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0.003, deltaY: 0.002), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0.003, deltaY: 0.002),
            .activate(axis: .horizontal)
        )
        XCTAssertEqual(gate.metrics.rawNetX, 0.009, accuracy: 0.000_001)
        XCTAssertEqual(gate.metrics.normalizedNetX, 0.0144, accuracy: 0.000_001)
    }

    func testCompensatedHorizontalMovementRejectsVerticalCandidate() {
        var gate = ScrollIntentGate(axis: .vertical)

        XCTAssertEqual(gate.observe(deltaX: 0.003, deltaY: 0.001), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0.003, deltaY: 0.001), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0.003, deltaY: 0.001),
            .reject(reason: .offAxisDominant)
        )
    }

    func testLargePathWithLittleNetDisplacementDoesNotActivate() {
        var gate = ScrollIntentGate(axis: .horizontal)
        let samples: [ScrollIntentGate.Sample] = [
            .init(dx: 0.008, dy: 0.010),
            .init(dx: -0.007, dy: -0.009),
            .init(dx: 0.007, dy: 0.009),
            .init(dx: -0.007, dy: -0.009),
            .init(dx: 0.007, dy: 0.009),
            .init(dx: -0.007, dy: -0.009),
            .init(dx: 0.007, dy: 0.009),
            .init(dx: -0.007, dy: -0.009),
        ]

        for (index, sample) in samples.enumerated() {
            let decision = gate.observe(sample)
            if index < samples.count - 1 {
                XCTAssertEqual(decision, .pending)
            } else {
                XCTAssertEqual(decision, .reject(reason: .incoherentMovement))
            }
        }
    }

    func testTerminalDecisionDoesNotConsumeAdditionalSamples() {
        var gate = ScrollIntentGate(axis: .horizontal)

        XCTAssertEqual(gate.observe(deltaX: 0.011, deltaY: 0), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0.007, deltaY: 0),
            .activate(axis: .horizontal)
        )
        XCTAssertEqual(gate.metrics.sampleCount, 2)
        XCTAssertEqual(gate.acceptedSamples.count, 2)
        XCTAssertEqual(gate.observationCount, 2)

        XCTAssertEqual(
            gate.observe(deltaX: 0, deltaY: 1),
            .activate(axis: .horizontal)
        )
        XCTAssertEqual(gate.metrics.sampleCount, 2)
        XCTAssertEqual(gate.acceptedSamples.count, 2)
        XCTAssertEqual(gate.observationCount, 2)
    }

    func testResetStartsANewDecisionWindow() {
        var gate = ScrollIntentGate(axis: .horizontal)
        _ = gate.observe(deltaX: 0.011, deltaY: 0)

        gate.reset()

        XCTAssertEqual(gate.metrics.sampleCount, 0)
        XCTAssertEqual(gate.observationCount, 0)
        XCTAssertTrue(gate.acceptedSamples.isEmpty)
        XCTAssertEqual(gate.observe(deltaX: 0.002, deltaY: 0), .pending)
    }

    func testSubthresholdReleaseTailCannotConfirmInitialContradiction() {
        var gate = ScrollIntentGate(axis: .horizontal)

        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.030), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0.011, deltaY: 0), .pending)

        let releaseTail = ScrollIntentGate.Sample(dx: 0.0001, dy: 0)
        XCTAssertFalse(ScrollIntentGate.releaseTailCanConfirm(
            releaseTail,
            minimumPhysicalMagnitude: 0.0005
        ))
        XCTAssertEqual(gate.observationCount, 2)
    }

    func testMeaningfulReleaseTailCanStillConfirm() {
        XCTAssertTrue(ScrollIntentGate.releaseTailCanConfirm(
            .init(dx: 0, dy: 0.0005),
            minimumPhysicalMagnitude: 0.0005
        ))
    }

    func testInertiaSeedDropsProvisionalInitialVelocity() {
        let velocities = ScrollIntentGate.confirmedVelocitySamples(
            samples: [
                .init(dx: 0, dy: 0.008),
                .init(dx: 0, dy: 0.001),
            ],
            timestamps: [0.008, 0.108],
            windowStartTimestamp: 0
        )

        XCTAssertEqual(velocities.count, 1)
        XCTAssertEqual(velocities[0].vy, 0.01, accuracy: 0.000_001)
        XCTAssertEqual(velocities[0].time, 0.108, accuracy: 0.000_001)
    }

    func testInertiaSeedKeepsConfirmedTrueFlickVelocity() {
        let velocities = ScrollIntentGate.confirmedVelocitySamples(
            samples: [
                .init(dx: 0, dy: 0.008),
                .init(dx: 0, dy: 0.008),
                .init(dx: 0, dy: 0.006),
            ],
            timestamps: [0.008, 0.016, 0.024],
            windowStartTimestamp: 0
        )

        XCTAssertEqual(velocities.count, 2)
        XCTAssertEqual(velocities[0].vy, 1.0, accuracy: 0.000_001)
        XCTAssertEqual(velocities[1].vy, 0.75, accuracy: 0.000_001)
    }

    func testInertiaSeedRejectsSamplesOlderThanRestartedWindow() {
        XCTAssertTrue(ScrollIntentGate.confirmedVelocitySamples(
            samples: [
                .init(dx: 0, dy: 0.008),
                .init(dx: 0, dy: 0.008),
            ],
            timestamps: [0.200, 0.208],
            windowStartTimestamp: 0.205
        ).isEmpty)
    }

    func testConfigurationNeverAllowsOffAxisRejectionBeforeThreeSamples() {
        let configuration = ScrollIntentGate.Configuration(maxSamples: 1)
        var gate = ScrollIntentGate(axis: .horizontal, configuration: configuration)

        XCTAssertEqual(configuration.maxSamples, 3)
        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.020), .pending)
        XCTAssertEqual(gate.observe(deltaX: 0, deltaY: 0.003), .pending)
        XCTAssertEqual(
            gate.observe(deltaX: 0, deltaY: 0.001),
            .reject(reason: .offAxisDominant)
        )
    }

    // MARK: - Corner resolution

    func testCornerPreservesForceCandidateForSmallIncoherentMovement() {
        let resolution = ScrollIntentGate.resolveCorner(
            samples: [
                .init(dx: 0.010, dy: 0.010),
                .init(dx: -0.008, dy: -0.008),
                .init(dx: 0.012, dy: 0),
            ],
            availableAxes: [.horizontal, .vertical]
        )

        guard case let .preserveForceCandidate(maximumExcursion) = resolution else {
            return XCTFail("Expected corner force candidate to be preserved")
        }
        XCTAssertLessThan(maximumExcursion, 0.025)
    }

    func testCornerPreservesForceCandidateForSmallTremorInsideCap() {
        let resolution = ScrollIntentGate.resolveCorner(
            samples: [
                .init(dx: 0.002, dy: -0.001),
                .init(dx: -0.002, dy: 0.001),
                .init(dx: 0.002, dy: 0.001),
                .init(dx: -0.002, dy: -0.001),
            ],
            availableAxes: [.horizontal, .vertical]
        )

        guard case let .preserveForceCandidate(maximumExcursion) = resolution else {
            return XCTFail("Expected small tremor to preserve the force candidate")
        }
        XCTAssertLessThan(maximumExcursion, 0.025)
    }

    func testCornerEarlyClearMovementActivatesBeforeForceCap() {
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [
                    .init(dx: 0.004, dy: 0),
                    .init(dx: 0.004, dy: 0),
                ],
                availableAxes: [.horizontal, .vertical]
            ),
            .activate(axis: .horizontal)
        )
    }

    func testCornerSingleSampleInsideCapCannotEarlyActivate() {
        let resolution = ScrollIntentGate.resolveCorner(
            samples: [.init(dx: 0.009, dy: 0)],
            availableAxes: [.horizontal, .vertical]
        )

        guard case let .preserveForceCandidate(maximumExcursion) = resolution else {
            return XCTFail("Expected one inside-cap sample to preserve force")
        }
        XCTAssertEqual(maximumExcursion, 0.0144, accuracy: 0.000_001)
    }

    func testCornerExactCompensatedBoundaryMustDecide() {
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [
                    .init(dx: 0, dy: 0.0125),
                    .init(dx: 0, dy: 0.0125),
                ],
                availableAxes: [.horizontal, .vertical]
            ),
            .activate(axis: .vertical)
        )
    }

    func testCornerUsesMeasuredExcursionWhenFirstHardwareDeltaWasSkipped() {
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [
                    .init(dx: 0.005, dy: 0),
                    .init(dx: 0.005, dy: 0),
                ],
                availableAxes: [.horizontal],
                measuredMaximumExcursion: 0.025
            ),
            .activate(axis: .horizontal)
        )
    }

    func testCornerMeasuredExcursionWaitsWhenTwoSamplesAreStillAmbiguous() {
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [
                    .init(dx: 0.002, dy: 0.002),
                    .init(dx: -0.001, dy: 0.001),
                ],
                availableAxes: [.horizontal, .vertical],
                measuredMaximumExcursion: 0.030
            ),
            .awaitMoreScrollEvidence(maximumExcursion: 0.030)
        )
    }

    func testCornerCoherentAmbiguityRecoversAfterVerticalInitialNoise() {
        let samples: [ScrollIntentGate.Sample] = [
            .init(dx: 0, dy: 0.008),
            .init(dx: 0.003, dy: 0),
            .init(dx: 0.003, dy: 0),
            .init(dx: 0.003, dy: 0),
            .init(dx: 0.003, dy: 0),
        ]

        for prefixCount in 1..<samples.count {
            XCTAssertEqual(
                ScrollIntentGate.resolveCorner(
                    samples: Array(samples.prefix(prefixCount)),
                    availableAxes: [.horizontal, .vertical],
                    measuredMaximumExcursion: 0.030
                ),
                .awaitMoreScrollEvidence(maximumExcursion: 0.030),
                "Expected coherent prefix of length \(prefixCount) to remain recoverable"
            )
        }

        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: samples,
                availableAxes: [.horizontal, .vertical],
                measuredMaximumExcursion: 0.030
            ),
            .activate(axis: .horizontal)
        )
    }

    func testCornerExcursionUsesHorizontalAspectCompensation() {
        let insideResolution = ScrollIntentGate.resolveCorner(
            samples: [.init(dx: 0.015, dy: 0)],
            availableAxes: [.horizontal]
        )
        guard case let .preserveForceCandidate(maximumExcursion) = insideResolution else {
            return XCTFail("Expected compensated excursion below the cap")
        }
        XCTAssertEqual(maximumExcursion, 0.024, accuracy: 0.000_001)

        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [.init(dx: 0.016, dy: 0)],
                availableAxes: [.horizontal]
            ),
            .activate(axis: .horizontal)
        )
    }

    func testCornerOutsideCapUsesAtLeastStandardGateThresholds() {
        // Raw x:y 只有 3:2；乘上 1.6 後 horizontal dominance 約 0.706。
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [
                    .init(dx: 0.009, dy: 0.006),
                    .init(dx: 0.009, dy: 0.006),
                ],
                availableAxes: [.horizontal, .vertical]
            ),
            .activate(axis: .horizontal)
        )

        let ambiguousResolution = ScrollIntentGate.resolveCorner(
            samples: [
                .init(dx: 0.008, dy: 0.007),
                .init(dx: 0.008, dy: 0.007),
            ],
            availableAxes: [.horizontal, .vertical]
        )
        guard case let .awaitMoreScrollEvidence(maximumExcursion) = ambiguousResolution else {
            return XCTFail("Expected a third sample before rejecting an ambiguous corner")
        }
        XCTAssertGreaterThanOrEqual(maximumExcursion, 0.025)
    }

    func testCornerSingleSampleOutsideCapStillNeedsConfirmation() {
        let sample = ScrollIntentGate.Sample(dx: 0.018, dy: 0.008)

        let singleSampleResolution = ScrollIntentGate.resolveCorner(
            samples: [sample],
            availableAxes: [.horizontal, .vertical]
        )
        guard case let .awaitMoreScrollEvidence(maximumExcursion) = singleSampleResolution else {
            return XCTFail("Expected one corner sample to wait for confirmation")
        }
        XCTAssertGreaterThanOrEqual(maximumExcursion, 0.025)
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [
                    .init(dx: sample.dx / 2, dy: sample.dy / 2),
                    .init(dx: sample.dx / 2, dy: sample.dy / 2),
                ],
                availableAxes: [.horizontal, .vertical]
            ),
            .activate(axis: .horizontal)
        )
    }

    func testCornerCanUseBoundedInitialEvidenceAfterRawExcursionClearsForce() {
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [
                    .init(dx: 0, dy: 0.008),
                    .init(dx: 0, dy: 0.001),
                ],
                availableAxes: [.vertical],
                measuredMaximumExcursion: 0.031
            ),
            .activate(axis: .vertical)
        )
    }

    func testCornerEarlyClearMovementTowardUnavailableAxisRejects() {
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [
                    .init(dx: 0.004, dy: 0),
                    .init(dx: 0.004, dy: 0),
                ],
                availableAxes: [.vertical]
            ),
            .reject(reason: .movementTargetsUnavailableAxis)
        )
    }

    func testCornerOnlyHorizontalCandidateStillRejectsVerticalMovementOutsideCap() {
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [
                    .init(dx: 0, dy: 0.015),
                    .init(dx: 0, dy: 0.015),
                ],
                availableAxes: [.horizontal]
            ),
            .reject(reason: .movementTargetsUnavailableAxis)
        )
    }

    func testOneAxisCornerInitialSettlingRejectionRemainsRecoverable() {
        let rawSamples: [ScrollIntentGate.Sample] = [
            .init(dx: 0, dy: 0.030),
            .init(dx: 0.001, dy: 0),
            .init(dx: 0.001, dy: 0),
        ]
        let resolverSamples = rawSamples.enumerated().map { index, sample in
            index == 0
                ? ScrollIntentGate.winsorizedInitialSample(sample)
                : sample
        }

        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: resolverSamples,
                availableAxes: [.horizontal],
                measuredMaximumExcursion: 0.030
            ),
            .reject(reason: .movementTargetsUnavailableAxis)
        )
        XCTAssertTrue(ScrollIntentGate.shouldAwaitUnavailableAxisRejection(
            rawSamples: rawSamples,
            availableAxis: .horizontal,
            maximumSampleCount: 24
        ))

        let recoveredRawSamples = [rawSamples[0]]
            + Array(repeating: ScrollIntentGate.Sample(dx: 0.001, dy: 0), count: 11)
        let recoveredResolverSamples = recoveredRawSamples.enumerated().map { index, sample in
            index == 0
                ? ScrollIntentGate.winsorizedInitialSample(sample)
                : sample
        }
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: recoveredResolverSamples,
                availableAxes: [.horizontal],
                measuredMaximumExcursion: 0.030
            ),
            .activate(axis: .horizontal)
        )
    }

    func testOneAxisCornerInitialSettlingRecoveryStopsAtSafetyBoundary() {
        let rawSamples = [ScrollIntentGate.Sample(dx: 0, dy: 0.030)]
            + Array(repeating: ScrollIntentGate.Sample(dx: 0, dy: 0.0005), count: 23)

        XCTAssertFalse(ScrollIntentGate.shouldAwaitUnavailableAxisRejection(
            rawSamples: rawSamples,
            availableAxis: .horizontal,
            maximumSampleCount: 24
        ))
    }

    func testOneAxisCornerRecoveryStopsWhenFollowupConfirmsUnavailableAxis() {
        let rawSamples = [ScrollIntentGate.Sample(dx: 0, dy: 0.030)]
            + Array(repeating: ScrollIntentGate.Sample(dx: 0, dy: 0.004), count: 3)

        XCTAssertFalse(ScrollIntentGate.shouldAwaitUnavailableAxisRejection(
            rawSamples: rawSamples,
            availableAxis: .horizontal,
            maximumSampleCount: 24
        ))
    }

    func testCornerCanActivateTheOnlyCandidateWhenMovementMatchesIt() {
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [.init(dx: 0.030, dy: 0.001)],
                availableAxes: [.horizontal]
            ),
            .activate(axis: .horizontal)
        )
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [.init(dx: 0.001, dy: 0.030)],
                availableAxes: [.vertical]
            ),
            .activate(axis: .vertical)
        )
    }

    func testCornerInsideForceCapPreservesCandidateWhenNoAxisIsAvailable() {
        guard case let .preserveForceCandidate(maximumExcursion) =
            ScrollIntentGate.resolveCorner(
                samples: [
                    .init(dx: 0.004, dy: 0),
                    .init(dx: 0.004, dy: 0),
                ],
                availableAxes: []
            ) else {
            return XCTFail("Expected force candidate to survive without a scroll axis")
        }

        XCTAssertLessThan(
            maximumExcursion,
            ScrollIntentGate.defaultForceCandidateMaxExcursion
        )
    }

    func testCornerAtForceCapRejectsWhenNoAxisIsAvailable() {
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [
                    .init(dx: 0.010, dy: 0),
                    .init(dx: 0.005625, dy: 0),
                ],
                availableAxes: []
            ),
            .reject(reason: .noAvailableAxis)
        )
    }

    func testCornerTwelveFrameCleanTraceActivates() {
        let perFrame = ScrollIntentGate.Sample(dx: 0.00125, dy: 0.00078)
        let firstEleven = Array(repeating: perFrame, count: 11)

        guard case .preserveForceCandidate = ScrollIntentGate.resolveCorner(
            samples: firstEleven,
            availableAxes: [.horizontal, .vertical]
        ) else {
            return XCTFail("Expected the trace to remain below the cap for 11 frames")
        }

        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: firstEleven + [perFrame],
                availableAxes: [.horizontal, .vertical]
            ),
            .activate(axis: .horizontal)
        )
    }

    func testCornerTwoSampleReturnToOriginWaitsBeforeFinalRejection() {
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [
                    .init(dx: 0.030, dy: 0),
                    .init(dx: -0.029, dy: 0),
                ],
                availableAxes: [.horizontal, .vertical]
            ),
            .awaitMoreScrollEvidence(maximumExcursion: 0.048)
        )

        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [
                    .init(dx: 0.030, dy: 0),
                    .init(dx: -0.029, dy: 0),
                    .init(dx: 0.0005, dy: 0),
                ],
                availableAxes: [.horizontal, .vertical]
            ),
            .reject(reason: .incoherentMovement)
        )
    }

    func testCornerDoesNotEraseFoldbackCoherenceAtActivation() {
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: [
                    .init(dx: 0.02986, dy: 0.01333),
                    .init(dx: -0.00486, dy: 0),
                    .init(dx: 0.001, dy: 0),
                ],
                availableAxes: [.horizontal, .vertical]
            ),
            .reject(reason: .incoherentMovement)
        )
    }

    func testForceWindowTremorMustBeDiscardedBeforeScrollOnlyDecision() {
        let tremor = (0..<24).map { index in
            ScrollIntentGate.Sample(
                dx: index.isMultiple(of: 2) ? 0.0003125 : -0.0003125,
                dy: 0
            )
        }
        let deliberateScroll: [ScrollIntentGate.Sample] = [
            .init(dx: 0.005, dy: 0),
            .init(dx: 0.005, dy: 0),
        ]

        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: tremor + deliberateScroll,
                availableAxes: [.horizontal],
                forceCandidateMaxExcursion: 0
            ),
            .reject(reason: .incoherentMovement)
        )
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: deliberateScroll,
                availableAxes: [.horizontal],
                forceCandidateMaxExcursion: 0
            ),
            .activate(axis: .horizontal)
        )
    }

    func testAmbiguousCornerAtSafetyLimitCanBeginOneShotRecovery() {
        let ambiguousPrefix = Array(
            repeating: ScrollIntentGate.Sample(dx: 0.0005, dy: 0.0008),
            count: 24
        )

        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: ambiguousPrefix,
                availableAxes: [.horizontal, .vertical],
                measuredMaximumExcursion: 0.0272
            ),
            .awaitMoreScrollEvidence(maximumExcursion: 0.0272)
        )
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.shouldBeginCornerRecovery(
                alreadyUsed: false,
                resolutionIsAwaitingMoreEvidence: true,
                isEligibleContact: true,
                availableAxisCount: 2,
                sampleCount: 24,
                initialSampleLimit: 24,
                maximumExcursion: 0.0272,
                forceCandidateMaximumExcursion: 0.025,
                hasTriggeringForceCandidate: false
            )
        )
    }

    func testCornerRecoveryUsesOnlyFreshSuffixForActivation() {
        let ambiguousPrefix = Array(
            repeating: ScrollIntentGate.Sample(dx: 0.0005, dy: 0.0008),
            count: 24
        )
        let verticalSuffix = Array(
            repeating: ScrollIntentGate.Sample(dx: 0.0001, dy: 0.003),
            count: 3
        )

        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: verticalSuffix,
                availableAxes: [.horizontal, .vertical],
                forceCandidateMaxExcursion: 0
            ),
            .activate(axis: .vertical)
        )
        guard case .awaitMoreScrollEvidence = ScrollIntentGate.resolveCorner(
            samples: ambiguousPrefix + verticalSuffix,
            availableAxes: [.horizontal, .vertical],
            forceCandidateMaxExcursion: 0,
            measuredMaximumExcursion: 0.0272
        ) else {
            return XCTFail("Old ambiguous prefix must not be replayed into recovery")
        }
    }

    func testCornerRecoveryPolicyRejectsUnsafeEntryConditions() {
        func shouldBegin(
            alreadyUsed: Bool = false,
            resolutionIsAwaiting: Bool = true,
            isEligibleContact: Bool = true,
            axisCount: Int = 2,
            sampleCount: Int = 24,
            maximumExcursion: CGFloat = 0.0272,
            hasTriggeringForce: Bool = false
        ) -> Bool {
            ScrollIntentRecoveryPolicy.shouldBeginCornerRecovery(
                alreadyUsed: alreadyUsed,
                resolutionIsAwaitingMoreEvidence: resolutionIsAwaiting,
                isEligibleContact: isEligibleContact,
                availableAxisCount: axisCount,
                sampleCount: sampleCount,
                initialSampleLimit: 24,
                maximumExcursion: maximumExcursion,
                forceCandidateMaximumExcursion: 0.025,
                hasTriggeringForceCandidate: hasTriggeringForce
            )
        }

        XCTAssertFalse(shouldBegin(alreadyUsed: true))
        XCTAssertFalse(shouldBegin(resolutionIsAwaiting: false))
        XCTAssertFalse(shouldBegin(isEligibleContact: false))
        XCTAssertFalse(shouldBegin(axisCount: 0))
        XCTAssertFalse(shouldBegin(sampleCount: 23))
        XCTAssertTrue(shouldBegin(sampleCount: 25))
        XCTAssertFalse(shouldBegin(maximumExcursion: 0.024_999))
        XCTAssertFalse(shouldBegin(hasTriggeringForce: true))
    }

    func testCornerCanBeginRecoveryWhenForceCapCrossesAfterSampleLimit() {
        let ambiguousSamples = Array(
            repeating: ScrollIntentGate.Sample(dx: 0.00045, dy: 0.00072),
            count: 25
        )

        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: Array(ambiguousSamples.prefix(24)),
                availableAxes: [.horizontal, .vertical],
                measuredMaximumExcursion: 0.024_9
            ),
            .preserveForceCandidate(maximumExcursion: 0.024_9)
        )
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: ambiguousSamples,
                availableAxes: [.horizontal, .vertical],
                measuredMaximumExcursion: 0.026
            ),
            .awaitMoreScrollEvidence(maximumExcursion: 0.026)
        )
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.shouldBeginCornerRecovery(
                alreadyUsed: false,
                resolutionIsAwaitingMoreEvidence: true,
                isEligibleContact: true,
                availableAxisCount: 2,
                sampleCount: 25,
                initialSampleLimit: 24,
                maximumExcursion: 0.026,
                forceCandidateMaximumExcursion: 0.025,
                hasTriggeringForceCandidate: false
            )
        )
    }

    func testSixteenthRecoverySampleMayConfirmButCannotStayPending() {
        let firstFifteen = Array(
            repeating: ScrollIntentGate.Sample(dx: 0.00032, dy: 0),
            count: 15
        )
        let sixteenth = ScrollIntentGate.Sample(dx: 0.00032, dy: 0)

        guard case .awaitMoreScrollEvidence = ScrollIntentGate.resolveCorner(
            samples: firstFifteen,
            availableAxes: [.horizontal, .vertical],
            forceCandidateMaxExcursion: 0
        ) else {
            return XCTFail("The 15th recovery sample must still be pending")
        }
        XCTAssertFalse(
            ScrollIntentRecoveryPolicy.recoveryHasExpired(
                sampleCount: 15,
                elapsed: 0.100
            )
        )
        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: firstFifteen + [sixteenth],
                availableAxes: [.horizontal, .vertical],
                forceCandidateMaxExcursion: 0
            ),
            .activate(axis: .horizontal)
        )
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.recoveryHasExpired(
                sampleCount: 16,
                elapsed: 0.100
            )
        )
    }

    func testCornerRecoveryRequiresThirdFreshConfirmationSample() {
        let twoFrameSuffix: [ScrollIntentGate.Sample] = [
            .init(dx: 0.0025, dy: 0),
            .init(dx: 0.0025, dy: 0),
        ]

        XCTAssertEqual(
            ScrollIntentGate.resolveCorner(
                samples: twoFrameSuffix,
                availableAxes: [.horizontal, .vertical],
                forceCandidateMaxExcursion: 0
            ),
            .activate(axis: .horizontal)
        )
        XCTAssertFalse(
            ScrollIntentRecoveryPolicy.cornerRecoveryCanActivate(
                freshSampleCount: 2
            )
        )
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.cornerRecoveryCanActivate(
                freshSampleCount: 3
            )
        )
    }

    func testCornerRecoveryHasStrictSampleAndTimeBoundaries() {
        XCTAssertFalse(
            ScrollIntentRecoveryPolicy.recoveryHasExpired(
                sampleCount: 15,
                elapsed: 0.149_999
            )
        )
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.recoveryHasExpired(
                sampleCount: 16,
                elapsed: 0
            )
        )
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.recoveryHasExpired(
                sampleCount: 0,
                elapsed: 0.150
            )
        )
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.recoveryHasExpired(
                sampleCount: 0,
                elapsed: .nan
            )
        )
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.recoveryHasExpired(
                sampleCount: 0,
                elapsed: -0.001
            )
        )
    }

    func testRecoveryAndScrollOnlyCornerExpireOnEvidenceGap() {
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.isScrollOnlyCornerDecision(
                isCorner: true,
                hasActiveForceCandidate: false,
                forceGestureDisqualified: false,
                maximumExcursion: 0.010,
                forceCandidateMaximumExcursion: 0.025
            )
        )
        XCTAssertFalse(
            ScrollIntentRecoveryPolicy.isScrollOnlyCornerDecision(
                isCorner: true,
                hasActiveForceCandidate: true,
                forceGestureDisqualified: false,
                maximumExcursion: 0.024_999,
                forceCandidateMaximumExcursion: 0.025
            )
        )
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.isScrollOnlyCornerDecision(
                isCorner: true,
                hasActiveForceCandidate: true,
                forceGestureDisqualified: false,
                maximumExcursion: 0.025,
                forceCandidateMaximumExcursion: 0.025
            )
        )
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.shouldExpireOnEvidenceGap(
                hasActiveRecovery: true,
                isScrollOnlyCorner: false
            )
        )
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.shouldExpireOnEvidenceGap(
                hasActiveRecovery: false,
                isScrollOnlyCorner: true
            )
        )
        XCTAssertFalse(
            ScrollIntentRecoveryPolicy.shouldExpireOnEvidenceGap(
                hasActiveRecovery: false,
                isScrollOnlyCorner: false
            )
        )
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.recoveryHasExpired(
                sampleCount: 0,
                elapsed: 0.181
            )
        )
    }

    func testAmbiguousCornerCannotLoopPastRecoveryWindow() {
        let diagonalRecovery = Array(
            repeating: ScrollIntentGate.Sample(dx: 0.0005, dy: 0.0008),
            count: 16
        )

        guard case .awaitMoreScrollEvidence = ScrollIntentGate.resolveCorner(
            samples: diagonalRecovery,
            availableAxes: [.horizontal, .vertical],
            forceCandidateMaxExcursion: 0
        ) else {
            return XCTFail("A balanced diagonal must remain ambiguous")
        }
        XCTAssertTrue(
            ScrollIntentRecoveryPolicy.recoveryHasExpired(
                sampleCount: diagonalRecovery.count,
                elapsed: 0.100
            )
        )
        XCTAssertFalse(
            ScrollIntentRecoveryPolicy.shouldBeginCornerRecovery(
                alreadyUsed: true,
                resolutionIsAwaitingMoreEvidence: true,
                isEligibleContact: true,
                availableAxisCount: 2,
                sampleCount: 24,
                initialSampleLimit: 24,
                maximumExcursion: 0.040,
                forceCandidateMaximumExcursion: 0.025,
                hasTriggeringForceCandidate: false
            )
        )
    }
}
