import XCTest

final class PrimaryClickSuppressionGateTests: XCTestCase {
    func testPassesClickWhenNoGestureIsPending() {
        var gate = PrimaryClickSuppressionGate()

        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_000), .pass)
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_010), .pass)
    }

    func testCompletePairReplaysImmediatelyWhenFinishedAsNormalClick() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 1, at: 1_000)

        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_010), .suppress(token: 1))
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_020), .suppress(token: 1))
        XCTAssertEqual(
            gate.finish(token: 1, replayCapturedClick: true, at: 1_030),
            .replayClicks(
                token: 1,
                pairs: [.init(downAt: 1_010, upAt: 1_020)]
            )
        )
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_040), .pass)
    }

    func testCompletePairIsDroppedImmediatelyAfterSuccessfulForceAction() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 1, at: 1_000)

        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_010), .suppress(token: 1))
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_020), .suppress(token: 1))
        XCTAssertEqual(
            gate.finish(token: 1, replayCapturedClick: false, at: 1_030),
            .discard(token: 1)
        )
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_040), .pass)
    }

    func testSuccessfulForceActionKeepsPartialUntilMatchingUpThenDropsPair() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 1, at: 1_000)
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_010), .suppress(token: 1))

        XCTAssertEqual(
            gate.finish(token: 1, replayCapturedClick: false, at: 1_020),
            .none
        )
        XCTAssertTrue(gate.contains(token: 1))
        XCTAssertEqual(
            gate.capture(event: .leftMouseUp, at: 1_030),
            .suppressAndResolve(.discard(token: 1))
        )
        XCTAssertFalse(gate.contains(token: 1))
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_040), .pass)
    }

    func testNormalClickKeepsPartialUntilMatchingUpThenRequestsReplay() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 9, at: 1_000)
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_010), .suppress(token: 9))

        XCTAssertEqual(
            gate.finish(token: 9, replayCapturedClick: true, at: 1_020),
            .none
        )
        XCTAssertEqual(
            gate.capture(event: .leftMouseUp, at: 1_030),
            .suppressAndResolve(
                .replayClicks(
                    token: 9,
                    pairs: [.init(downAt: 1_010, upAt: 1_030)]
                )
            )
        )
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_040), .pass)
    }

    func testFinishWithoutCapturedDownDisarmsImmediately() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 1, at: 1_000)

        XCTAssertEqual(
            gate.finish(token: 1, replayCapturedClick: true, at: 1_010),
            .discard(token: 1)
        )
        XCTAssertFalse(gate.contains(token: 1))
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_020), .pass)
    }

    func testEndingPartialExpiresAndPassesNextEventWithResetSignal() {
        var gate = PrimaryClickSuppressionGate()
        let finishedAt: UInt64 = 1_020
        gate.begin(token: 1, at: 1_000)
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_010), .suppress(token: 1))
        XCTAssertEqual(
            gate.finish(token: 1, replayCapturedClick: true, at: finishedAt),
            .none
        )

        let afterExpiry = finishedAt
            + PrimaryClickSuppressionGate.endingPartialExpiryNanoseconds
            + 1
        XCTAssertEqual(
            gate.capture(event: .leftMouseUp, at: afterExpiry),
            .passAndReset
        )
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: afterExpiry + 1), .pass)
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: afterExpiry + 2), .pass)
    }

    func testEndingPartialAcceptsUpAtExpiryBoundary() {
        var gate = PrimaryClickSuppressionGate()
        let finishedAt: UInt64 = 1_020
        gate.begin(token: 1, at: 1_000)
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_010), .suppress(token: 1))
        XCTAssertEqual(
            gate.finish(token: 1, replayCapturedClick: true, at: finishedAt),
            .none
        )

        let expiry = finishedAt
            + PrimaryClickSuppressionGate.endingPartialExpiryNanoseconds
        XCTAssertEqual(
            gate.capture(event: .leftMouseUp, at: expiry),
            .suppressAndResolve(
                .replayClicks(
                    token: 1,
                    pairs: [.init(downAt: 1_010, upAt: expiry)]
                )
            )
        )
    }

    func testDuplicateDownDoesNotReplaceOriginalCapturedDown() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 1, at: 1_000)

        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_010), .suppress(token: 1))
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_020), .suppress(token: 1))
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_030), .suppress(token: 1))
        XCTAssertEqual(
            gate.finish(token: 1, replayCapturedClick: true, at: 1_040),
            .replayClicks(
                token: 1,
                pairs: [.init(downAt: 1_010, upAt: 1_030)]
            )
        )
    }

    func testNewDownDuringEndingPassesAndResetsOldPartial() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 1, at: 1_000)
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_010), .suppress(token: 1))
        XCTAssertEqual(
            gate.finish(token: 1, replayCapturedClick: true, at: 1_020),
            .none
        )

        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_030), .passAndReset)
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_040), .pass)
    }

    func testStandaloneUpPassesWithoutBecomingCapturedPair() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 1, at: 1_000)

        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_010), .pass)
        XCTAssertEqual(
            gate.finish(token: 1, replayCapturedClick: true, at: 1_020),
            .discard(token: 1)
        )
    }

    func testStaleFinishAndDisarmDoNotAffectCurrentToken() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 1, at: 1_000)
        gate.begin(token: 2, at: 1_010)

        XCTAssertEqual(
            gate.finish(token: 1, replayCapturedClick: false, at: 1_020),
            .none
        )
        gate.disarm(token: 1)

        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_030), .suppress(token: 2))
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_040), .suppress(token: 2))
        XCTAssertEqual(
            gate.finish(token: 2, replayCapturedClick: true, at: 1_050),
            .replayClicks(
                token: 2,
                pairs: [.init(downAt: 1_030, upAt: 1_040)]
            )
        )
    }

    func testNewTokenKeepsEndingStateUntilOldUpArrives() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 1, at: 1_000)
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_010), .suppress(token: 1))
        XCTAssertEqual(
            gate.finish(token: 1, replayCapturedClick: true, at: 1_020),
            .none
        )

        gate.begin(token: 2, at: 1_030)
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseUp,
                at: 1_015,
                receivedAt: 1_040
            ),
            .suppressAndResolve(
                .replayClicks(
                    token: 1,
                    pairs: [.init(downAt: 1_010, upAt: 1_015)]
                )
            )
        )
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_050), .suppress(token: 2))
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_060), .suppress(token: 2))
        XCTAssertTrue(gate.contains(token: 2))
        XCTAssertEqual(
            gate.finish(token: 2, replayCapturedClick: true, at: 1_070),
            .replayClicks(
                token: 2,
                pairs: [.init(downAt: 1_050, upAt: 1_060)]
            )
        )
        XCTAssertFalse(gate.contains(token: 2))
    }

    func testMultipleCompletePairsReplayInCaptureOrder() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 7, at: 1_000)

        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_010), .suppress(token: 7))
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_020), .suppress(token: 7))
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_030), .suppress(token: 7))
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_040), .suppress(token: 7))

        XCTAssertEqual(
            gate.finish(token: 7, replayCapturedClick: true, at: 1_050),
            .replayClicks(
                token: 7,
                pairs: [
                    .init(downAt: 1_010, upAt: 1_020),
                    .init(downAt: 1_030, upAt: 1_040)
                ]
            )
        )
        XCTAssertFalse(gate.contains(token: 7))
    }

    func testForceFinishDiscardsEveryCompletePair() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 7, at: 1_000)

        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_010), .suppress(token: 7))
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_020), .suppress(token: 7))
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_030), .suppress(token: 7))
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_040), .suppress(token: 7))

        XCTAssertEqual(
            gate.finish(token: 7, replayCapturedClick: false, at: 1_050),
            .discard(token: 7)
        )
        XCTAssertTrue(gate.contains(token: 7))
    }

    func testForceFinishDiscardsCompletePairsAndKeepsTrailingPartial() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 7, at: 1_000)

        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_010), .suppress(token: 7))
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_020), .suppress(token: 7))
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_030), .suppress(token: 7))

        XCTAssertEqual(
            gate.finish(token: 7, replayCapturedClick: false, at: 1_040),
            .discard(token: 7)
        )
        XCTAssertTrue(gate.contains(token: 7))
        XCTAssertEqual(
            gate.capture(event: .leftMouseUp, at: 1_050),
            .suppressAndResolve(.discard(token: 7))
        )
        XCTAssertFalse(gate.contains(token: 7))
    }

    func testNormalFinishReplaysCompletePairsAndKeepsTrailingPartial() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 3, at: 1_000)

        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_010), .suppress(token: 3))
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_020), .suppress(token: 3))
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_030), .suppress(token: 3))

        XCTAssertEqual(
            gate.finish(token: 3, replayCapturedClick: true, at: 1_040),
            .replayClicks(
                token: 3,
                pairs: [.init(downAt: 1_010, upAt: 1_020)]
            )
        )
        XCTAssertTrue(gate.contains(token: 3))
        XCTAssertEqual(
            gate.capture(event: .leftMouseUp, at: 1_050),
            .suppressAndResolve(
                .replayClicks(
                    token: 3,
                    pairs: [.init(downAt: 1_030, upAt: 1_050)]
                )
            )
        )
        XCTAssertFalse(gate.contains(token: 3))
    }

    func testForceFinishWithoutDownGuardsDelayedCompletePair() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 5, at: 1_000)

        XCTAssertEqual(
            gate.finish(token: 5, replayCapturedClick: false, at: 1_010),
            .none
        )
        XCTAssertTrue(gate.contains(token: 5))
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseDown,
                at: 1_005,
                receivedAt: 1_020
            ),
            .suppress(token: 5)
        )
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseUp,
                at: 1_008,
                receivedAt: 1_030
            ),
            .suppressAndResolve(.discard(token: 5))
        )
        XCTAssertTrue(gate.contains(token: 5))
    }

    func testForceFinishWithCompletePairStillGuardsDelayedSecondPair() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 5, at: 1_000)
        XCTAssertEqual(gate.capture(event: .leftMouseDown, at: 1_010), .suppress(token: 5))
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: 1_020), .suppress(token: 5))

        XCTAssertEqual(
            gate.finish(token: 5, replayCapturedClick: false, at: 1_030),
            .discard(token: 5)
        )
        XCTAssertTrue(gate.contains(token: 5))
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseDown,
                at: 1_025,
                receivedAt: 1_040
            ),
            .suppress(token: 5)
        )
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseUp,
                at: 1_028,
                receivedAt: 1_050
            ),
            .suppressAndResolve(.discard(token: 5))
        )
        XCTAssertTrue(gate.contains(token: 5))
    }

    func testForceActionGuardSuppressesDuplicateDelayedDown() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 5, at: 1_000)
        XCTAssertEqual(
            gate.finish(token: 5, replayCapturedClick: false, at: 1_010),
            .none
        )

        XCTAssertEqual(
            gate.capture(
                event: .leftMouseDown,
                at: 1_005,
                receivedAt: 1_020
            ),
            .suppress(token: 5)
        )
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseDown,
                at: 1_006,
                receivedAt: 1_025
            ),
            .suppress(token: 5)
        )
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseUp,
                at: 1_008,
                receivedAt: 1_030
            ),
            .suppressAndResolve(.discard(token: 5))
        )
    }

    func testForceActionGuardExpiresAndPassesNextPair() {
        var gate = PrimaryClickSuppressionGate()
        let finishedAt: UInt64 = 1_010
        gate.begin(token: 5, at: 1_000)
        XCTAssertEqual(
            gate.finish(token: 5, replayCapturedClick: false, at: finishedAt),
            .none
        )

        let afterExpiry = finishedAt
            + PrimaryClickSuppressionGate.endingPartialExpiryNanoseconds
            + 1
        XCTAssertEqual(
            gate.capture(event: .leftMouseDown, at: afterExpiry),
            .passAndReset
        )
        XCTAssertEqual(gate.capture(event: .leftMouseUp, at: afterExpiry + 1), .pass)
        XCTAssertFalse(gate.contains(token: 5))
    }

    func testForceActionGuardExpiryUsesReceiptTimeNotOldEventTimestamp() {
        var gate = PrimaryClickSuppressionGate()
        let finishedAt: UInt64 = 1_010
        let finishReceipt: UInt64 = 2_000_000_000
        let expiry = finishReceipt
            + PrimaryClickSuppressionGate.endingPartialExpiryNanoseconds

        gate.begin(token: 5, at: 1_000, receivedAt: 1_900_000_000)
        XCTAssertEqual(
            gate.finish(
                token: 5,
                replayCapturedClick: false,
                at: finishedAt,
                receivedAt: finishReceipt
            ),
            .none
        )

        XCTAssertEqual(
            gate.capture(
                event: .leftMouseDown,
                at: 1_005,
                receivedAt: expiry
            ),
            .suppress(token: 5)
        )
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseUp,
                at: 1_008,
                receivedAt: expiry
            ),
            .suppressAndResolve(.discard(token: 5))
        )

        XCTAssertEqual(
            gate.capture(
                event: .leftMouseDown,
                at: 1_006,
                receivedAt: expiry + 1
            ),
            .passAndReset
        )
        XCTAssertFalse(gate.contains(token: 5))
    }

    func testOldForceActionGuardResolvesBeforeNewActiveToken() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 1, at: 1_000)
        XCTAssertEqual(
            gate.finish(token: 1, replayCapturedClick: false, at: 1_010),
            .none
        )

        gate.begin(token: 2, at: 1_020)
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseDown,
                at: 1_005,
                receivedAt: 1_030
            ),
            .suppress(token: 1)
        )
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseUp,
                at: 1_008,
                receivedAt: 1_040
            ),
            .suppressAndResolve(.discard(token: 1))
        )

        XCTAssertEqual(
            gate.capture(
                event: .leftMouseDown,
                at: 1_030,
                receivedAt: 1_050
            ),
            .suppress(token: 2)
        )
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseUp,
                at: 1_040,
                receivedAt: 1_060
            ),
            .suppress(token: 2)
        )
        XCTAssertEqual(
            gate.finish(token: 2, replayCapturedClick: true, at: 1_070),
            .replayClicks(
                token: 2,
                pairs: [.init(downAt: 1_030, upAt: 1_040)]
            )
        )
    }

    func testForceActionGuardDiscardsMultiplePhysicallyOldDelayedPairs() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 1, at: 1_000)
        XCTAssertEqual(
            gate.finish(token: 1, replayCapturedClick: false, at: 1_100),
            .none
        )

        XCTAssertEqual(
            gate.capture(
                event: .leftMouseDown,
                at: 1_020,
                receivedAt: 1_120
            ),
            .suppress(token: 1)
        )
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseUp,
                at: 1_030,
                receivedAt: 1_130
            ),
            .suppressAndResolve(.discard(token: 1))
        )
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseDown,
                at: 1_040,
                receivedAt: 1_140
            ),
            .suppress(token: 1)
        )
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseUp,
                at: 1_050,
                receivedAt: 1_150
            ),
            .suppressAndResolve(.discard(token: 1))
        )

        // A click that physically occurred after the old contact ended is not
        // delayed old input merely because it arrived inside the 150 ms guard.
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseDown,
                at: 1_110,
                receivedAt: 1_160
            ),
            .passAndReset
        )
        XCTAssertFalse(gate.contains(token: 1))
    }

    func testNewActiveTokenOwnsItsFirstPhysicallyNewPairAheadOfOldGuard() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 1, at: 1_000)
        XCTAssertEqual(
            gate.finish(token: 1, replayCapturedClick: false, at: 1_010),
            .none
        )

        gate.begin(token: 2, at: 1_020)
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseDown,
                at: 1_030,
                receivedAt: 1_040
            ),
            .suppress(token: 2)
        )
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseUp,
                at: 1_035,
                receivedAt: 1_045
            ),
            .suppress(token: 2)
        )
        XCTAssertEqual(
            gate.finish(
                token: 2,
                replayCapturedClick: true,
                at: 1_050
            ),
            .replayClicks(
                token: 2,
                pairs: [.init(downAt: 1_030, upAt: 1_035)]
            )
        )
        XCTAssertTrue(gate.contains(token: 1))
    }

    func testPhysicalTimestampsKeepInterleavedOldAndNewPairsOnTheirTokens() {
        var gate = PrimaryClickSuppressionGate()
        gate.begin(token: 1, at: 1_000)
        XCTAssertEqual(
            gate.finish(token: 1, replayCapturedClick: false, at: 1_010),
            .none
        )
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseDown,
                at: 1_005,
                receivedAt: 1_030
            ),
            .suppress(token: 1)
        )

        gate.begin(token: 2, at: 1_020, receivedAt: 1_035)
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseDown,
                at: 1_025,
                receivedAt: 1_040
            ),
            .suppress(token: 2)
        )
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseUp,
                at: 1_028,
                receivedAt: 1_045
            ),
            .suppress(token: 2)
        )

        // Delivery can be interleaved without changing physical ownership.
        XCTAssertEqual(
            gate.capture(
                event: .leftMouseUp,
                at: 1_008,
                receivedAt: 1_050
            ),
            .suppressAndResolve(.discard(token: 1))
        )
        XCTAssertEqual(
            gate.finish(
                token: 2,
                replayCapturedClick: true,
                at: 1_030,
                receivedAt: 1_060
            ),
            .replayClicks(
                token: 2,
                pairs: [.init(downAt: 1_025, upAt: 1_028)]
            )
        )
    }
}
