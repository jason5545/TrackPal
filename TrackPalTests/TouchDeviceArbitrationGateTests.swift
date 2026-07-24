import XCTest

final class TouchDeviceArbitrationGateTests: XCTestCase {
    func testStartsWithoutOwner() {
        let gate = TouchDeviceArbitrationGate()

        XCTAssertNil(gate.ownerDeviceID)
    }

    func testZeroFrameCannotClaimOwnership() {
        var gate = TouchDeviceArbitrationGate()

        XCTAssertEqual(gate.processTouchFrame(deviceID: 1, touchCount: 0), .ignore)
        XCTAssertNil(gate.ownerDeviceID)
    }

    func testFirstPositiveFrameClaimsOwnership() {
        var gate = TouchDeviceArbitrationGate()

        XCTAssertEqual(gate.processTouchFrame(deviceID: 11, touchCount: 1), .accept)
        XCTAssertEqual(gate.ownerDeviceID, 11)
    }

    func testFirstMultiTouchFrameCanClaimOwnership() {
        var gate = TouchDeviceArbitrationGate()

        XCTAssertEqual(gate.processTouchFrame(deviceID: 12, touchCount: 3), .accept)
        XCTAssertEqual(gate.ownerDeviceID, 12)
    }

    func testOwnerPositiveFramesContinueToBeAccepted() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(deviceID: 1, touchCount: 1)

        XCTAssertEqual(gate.processTouchFrame(deviceID: 1, touchCount: 2), .accept)
        XCTAssertEqual(gate.processTouchFrame(deviceID: 1, touchCount: 1), .accept)
        XCTAssertEqual(gate.ownerDeviceID, 1)
    }

    func testNonOwnerPositiveFrameIsIgnoredAndCannotStealOwnership() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(deviceID: 1, touchCount: 1)

        XCTAssertEqual(gate.processTouchFrame(deviceID: 2, touchCount: 1), .ignore)
        XCTAssertEqual(gate.ownerDeviceID, 1)
    }

    func testNonOwnerZeroFrameIsIgnoredAndCannotReleaseOwner() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(deviceID: 1, touchCount: 1)

        XCTAssertEqual(gate.processTouchFrame(deviceID: 2, touchCount: 0), .ignore)
        XCTAssertEqual(gate.ownerDeviceID, 1)
    }

    func testOwnerForceIsAccepted() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(deviceID: 7, touchCount: 1)

        XCTAssertEqual(gate.processForce(deviceID: 7), .accept)
        XCTAssertEqual(gate.ownerDeviceID, 7)
    }

    func testNonOwnerForceIsIgnored() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(deviceID: 7, touchCount: 1)

        XCTAssertEqual(gate.processForce(deviceID: 8), .ignore)
        XCTAssertEqual(gate.ownerDeviceID, 7)
    }

    func testForceCannotClaimOwnership() {
        let gate = TouchDeviceArbitrationGate()

        XCTAssertEqual(gate.processForce(deviceID: 4), .ignore)
        XCTAssertNil(gate.ownerDeviceID)
    }

    func testMultiToSingleTransitionDoesNotReleaseOwnership() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(deviceID: 3, touchCount: 2)

        XCTAssertEqual(gate.processTouchFrame(deviceID: 3, touchCount: 1), .accept)
        XCTAssertEqual(gate.ownerDeviceID, 3)
    }

    func testOwnerZeroFrameIsAcceptedThenReleasesOwnership() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(deviceID: 5, touchCount: 1)

        XCTAssertEqual(gate.processTouchFrame(deviceID: 5, touchCount: 0), .accept)
        XCTAssertNil(gate.ownerDeviceID)
    }

    func testFormerOwnerForceIsIgnoredAfterRelease() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(deviceID: 5, touchCount: 1)
        _ = gate.processTouchFrame(deviceID: 5, touchCount: 0)

        XCTAssertEqual(gate.processForce(deviceID: 5), .ignore)
    }

    func testAnotherDeviceCanClaimAfterOwnerReleases() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(deviceID: 1, touchCount: 1)
        _ = gate.processTouchFrame(deviceID: 1, touchCount: 0)

        XCTAssertEqual(gate.processTouchFrame(deviceID: 2, touchCount: 1), .accept)
        XCTAssertEqual(gate.ownerDeviceID, 2)
    }

    func testRepeatedZeroFrameIsIgnoredAfterRelease() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(deviceID: 1, touchCount: 1)
        _ = gate.processTouchFrame(deviceID: 1, touchCount: 0)

        XCTAssertEqual(gate.processTouchFrame(deviceID: 1, touchCount: 0), .ignore)
        XCTAssertNil(gate.ownerDeviceID)
    }

    func testResetClearsOwnership() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(deviceID: 9, touchCount: 1)

        gate.reset()

        XCTAssertNil(gate.ownerDeviceID)
        XCTAssertEqual(gate.processForce(deviceID: 9), .ignore)
        XCTAssertEqual(gate.processTouchFrame(deviceID: 9, touchCount: 0), .ignore)
    }

    func testDifferentDeviceCanClaimAfterReset() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(deviceID: 1, touchCount: 1)
        gate.reset()

        XCTAssertEqual(gate.processTouchFrame(deviceID: 2, touchCount: 1), .accept)
        XCTAssertEqual(gate.ownerDeviceID, 2)
    }

    func testNegativeTouchCountCannotClaimOwnership() {
        var gate = TouchDeviceArbitrationGate()

        XCTAssertEqual(gate.processTouchFrame(deviceID: 1, touchCount: -1), .ignore)
        XCTAssertNil(gate.ownerDeviceID)
    }

    func testNegativeTouchCountCannotReleaseOwner() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(deviceID: 1, touchCount: 1)

        XCTAssertEqual(gate.processTouchFrame(deviceID: 1, touchCount: -1), .ignore)
        XCTAssertEqual(gate.ownerDeviceID, 1)
    }

    func testInterleavedDevicesPreserveSingleOwnerUntilOwnerZero() {
        var gate = TouchDeviceArbitrationGate()

        XCTAssertEqual(gate.processTouchFrame(deviceID: 10, touchCount: 1), .accept)
        XCTAssertEqual(gate.processTouchFrame(deviceID: 20, touchCount: 2), .ignore)
        XCTAssertEqual(gate.processForce(deviceID: 20), .ignore)
        XCTAssertEqual(gate.processTouchFrame(deviceID: 20, touchCount: 0), .ignore)
        XCTAssertEqual(gate.processTouchFrame(deviceID: 10, touchCount: 2), .accept)
        XCTAssertEqual(gate.processTouchFrame(deviceID: 10, touchCount: 1), .accept)
        XCTAssertEqual(gate.processForce(deviceID: 10), .accept)
        XCTAssertEqual(gate.processTouchFrame(deviceID: 10, touchCount: 0), .accept)
        XCTAssertNil(gate.ownerDeviceID)
        XCTAssertEqual(gate.processTouchFrame(deviceID: 20, touchCount: 1), .accept)
        XCTAssertEqual(gate.ownerDeviceID, 20)
    }

    func testForceFromOlderGenerationOnSameDeviceIsIgnored() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(
            deviceID: 5,
            contactGeneration: 41,
            touchCount: 1
        )

        XCTAssertEqual(
            gate.processForce(deviceID: 5, contactGeneration: 40),
            .ignore
        )
        XCTAssertEqual(
            gate.processForce(deviceID: 5, contactGeneration: 41),
            .accept
        )
    }

    func testNewGenerationCannotStealSameDeviceBeforeOwnerZero() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(
            deviceID: 3,
            contactGeneration: 10,
            touchCount: 1
        )

        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 3,
                contactGeneration: 11,
                touchCount: 1
            ),
            .ignore
        )
        XCTAssertEqual(
            gate.ownerContact,
            .init(deviceID: 3, generation: 10)
        )
    }

    func testStaleZeroCannotReleaseNewGenerationOnSameDevice() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(
            deviceID: 8,
            contactGeneration: 70,
            touchCount: 1
        )
        _ = gate.processTouchFrame(
            deviceID: 8,
            contactGeneration: 70,
            touchCount: 0
        )
        _ = gate.processTouchFrame(
            deviceID: 8,
            contactGeneration: 71,
            touchCount: 1
        )

        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 8,
                contactGeneration: 70,
                touchCount: 0
            ),
            .ignore
        )
        XCTAssertEqual(
            gate.ownerContact,
            .init(deviceID: 8, generation: 71)
        )
    }

    func testContactRejectedWhileAnotherDeviceOwnsCannotClaimMidContact() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 1
        )
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 1,
                touchCount: 1
            ),
            .ignore
        )
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 0
        )

        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 1,
                touchCount: 1
            ),
            .ignore
        )
        XCTAssertNil(gate.ownerContact)

        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 1,
                touchCount: 0
            ),
            .ignore
        )
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 2,
                touchCount: 1
            ),
            .accept
        )
    }

    func testDisallowedExistingContactCannotClaimUntilNextGeneration() {
        var gate = TouchDeviceArbitrationGate()

        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 4,
                contactGeneration: 9,
                touchCount: 1,
                allowClaim: false
            ),
            .ignore
        )
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 4,
                contactGeneration: 9,
                touchCount: 1,
                allowClaim: true
            ),
            .ignore
        )
        _ = gate.processTouchFrame(
            deviceID: 4,
            contactGeneration: 9,
            touchCount: 0
        )

        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 4,
                contactGeneration: 10,
                touchCount: 1,
                allowClaim: true
            ),
            .accept
        )
    }

    func testLateDeliveredOverlappingStartCannotClaimAfterOwnerZero() {
        var gate = TouchDeviceArbitrationGate()

        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 1,
                contactGeneration: 1,
                touchCount: 1,
                eventTimestamp: 10
            ),
            .accept
        )
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 1,
                contactGeneration: 1,
                touchCount: 0,
                eventTimestamp: 20
            ),
            .accept
        )

        // Device 2 physically started while device 1 still owned the gesture,
        // but its main-queue block arrived only after device 1's zero block.
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 1,
                touchCount: 1,
                eventTimestamp: 15
            ),
            .ignore
        )
        XCTAssertNil(gate.ownerContact)

        // The rest of that same physical contact stays blocked until its zero.
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 1,
                touchCount: 1,
                eventTimestamp: 21
            ),
            .ignore
        )
        _ = gate.processTouchFrame(
            deviceID: 2,
            contactGeneration: 1,
            touchCount: 0,
            eventTimestamp: 22
        )
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 2,
                touchCount: 1,
                eventTimestamp: 23
            ),
            .accept
        )
    }

    func testPostZeroStartDeliveredBeforeOwnerZeroBecomesPromotable() {
        var gate = TouchDeviceArbitrationGate()
        let owner = TouchDeviceArbitrationGate.Contact(
            deviceID: 1,
            generation: 1
        )
        let successor = TouchDeviceArbitrationGate.Contact(
            deviceID: 2,
            generation: 1
        )

        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: owner.deviceID,
                contactGeneration: owner.generation,
                touchCount: 1,
                eventTimestamp: 10
            ),
            .accept
        )

        // Main delivery is reversed: this start is processed while the previous
        // owner is still present, although hardware time puts it after the zero.
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: successor.deviceID,
                contactGeneration: successor.generation,
                touchCount: 1,
                eventTimestamp: 21
            ),
            .deferClaim
        )
        XCTAssertEqual(gate.ownerContact, owner)

        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: owner.deviceID,
                contactGeneration: owner.generation,
                touchCount: 0,
                eventTimestamp: 20
            ),
            .accept
        )
        XCTAssertNil(gate.ownerContact)
        XCTAssertEqual(
            gate.nextPromotableContact,
            .init(contact: successor, startTimestamp: 21)
        )

        XCTAssertEqual(
            gate.promoteNextDeferredContact(),
            .init(contact: successor, startTimestamp: 21)
        )
        XCTAssertEqual(gate.ownerContact, successor)
        XCTAssertEqual(gate.ownerStartTimestamp, 21)
    }

    func testDeferredPhysicalOverlapBecomesBlockedAtOwnerBoundary() {
        var gate = TouchDeviceArbitrationGate()

        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 1,
            eventTimestamp: 10
        )
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 1,
                touchCount: 1,
                eventTimestamp: 15
            ),
            .deferClaim
        )
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 0,
            eventTimestamp: 20
        )

        XCTAssertNil(gate.nextPromotableContact)
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 1,
                touchCount: 1,
                eventTimestamp: 21
            ),
            .ignore
        )
    }

    func testStartAtOwnerZeroBoundaryCanBePromoted() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 1,
            eventTimestamp: 10
        )

        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 1,
                touchCount: 1,
                eventTimestamp: 20
            ),
            .deferClaim
        )
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 0,
            eventTimestamp: 20
        )

        XCTAssertEqual(
            gate.promoteNextDeferredContact(),
            .init(
                contact: .init(deviceID: 2, generation: 1),
                startTimestamp: 20
            )
        )
    }

    func testDisallowedContactCannotEnterDeferredPromotion() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 1,
            eventTimestamp: 10
        )

        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 1,
                touchCount: 1,
                allowClaim: false,
                eventTimestamp: 21
            ),
            .ignore
        )
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 0,
            eventTimestamp: 20
        )

        XCTAssertNil(gate.nextPromotableContact)
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 1,
                touchCount: 1,
                allowClaim: true,
                eventTimestamp: 22
            ),
            .ignore
        )
    }

    func testDeferredContactForceWaitsForExplicitPromotion() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 1,
            eventTimestamp: 10
        )
        _ = gate.processTouchFrame(
            deviceID: 2,
            contactGeneration: 1,
            touchCount: 1,
            eventTimestamp: 21
        )

        XCTAssertEqual(
            gate.processForce(deviceID: 2, contactGeneration: 1),
            .ignore
        )
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 0,
            eventTimestamp: 20
        )
        XCTAssertEqual(
            gate.processForce(deviceID: 2, contactGeneration: 1),
            .ignore
        )

        _ = gate.promoteNextDeferredContact()
        XCTAssertEqual(
            gate.processForce(deviceID: 2, contactGeneration: 1),
            .accept
        )
    }

    func testKnownStaleStartIsIgnoredWhileAnotherContactOwns() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 1,
            eventTimestamp: 10
        )
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 0,
            eventTimestamp: 20
        )
        _ = gate.processTouchFrame(
            deviceID: 3,
            contactGeneration: 1,
            touchCount: 1,
            eventTimestamp: 25
        )

        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 1,
                touchCount: 1,
                eventTimestamp: 15
            ),
            .ignore
        )
        XCTAssertEqual(
            gate.ownerContact,
            .init(deviceID: 3, generation: 1)
        )
    }

    func testPromotionChoosesEarliestPhysicalStartNotDeliveryOrder() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 1,
            eventTimestamp: 10
        )

        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 3,
                contactGeneration: 1,
                touchCount: 1,
                eventTimestamp: 24
            ),
            .deferClaim
        )
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 1,
                touchCount: 1,
                eventTimestamp: 22
            ),
            .deferClaim
        )
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 0,
            eventTimestamp: 20
        )

        XCTAssertEqual(
            gate.nextPromotableContact,
            .init(
                contact: .init(deviceID: 2, generation: 1),
                startTimestamp: 22
            )
        )
        _ = gate.promoteNextDeferredContact()
        XCTAssertEqual(
            gate.ownerContact,
            .init(deviceID: 2, generation: 1)
        )

        // The later candidate is deferred behind the promoted owner instead of
        // being allowed to steal ownership.
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 3,
                contactGeneration: 1,
                touchCount: 1,
                eventTimestamp: 25
            ),
            .deferClaim
        )
    }

    func testDeferredContactZeroCancelsPromotion() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 1,
            eventTimestamp: 10
        )
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 1,
                touchCount: 1,
                eventTimestamp: 21
            ),
            .deferClaim
        )
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 2,
                contactGeneration: 1,
                touchCount: 0,
                eventTimestamp: 22
            ),
            .ignore
        )
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 0,
            eventTimestamp: 20
        )

        XCTAssertNil(gate.nextPromotableContact)
        XCTAssertNil(gate.promoteNextDeferredContact())
    }

    func testResetClearsTimestampBoundaryAndDeferredClaims() {
        var gate = TouchDeviceArbitrationGate()
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 1,
            eventTimestamp: 10
        )
        _ = gate.processTouchFrame(
            deviceID: 2,
            contactGeneration: 1,
            touchCount: 1,
            eventTimestamp: 21
        )
        _ = gate.processTouchFrame(
            deviceID: 1,
            contactGeneration: 1,
            touchCount: 0,
            eventTimestamp: 20
        )

        gate.reset()

        XCTAssertNil(gate.nextPromotableContact)
        XCTAssertEqual(
            gate.processTouchFrame(
                deviceID: 3,
                contactGeneration: 1,
                touchCount: 1,
                eventTimestamp: 5
            ),
            .accept
        )
    }
}

final class DeviceCallbackContextTests: XCTestCase {
    func testFutureForceWaitsForMatchingTouchHardwareTimestamp() {
        let context = DeviceCallbackContext(deviceID: 1)
        let frame = context.replaceFingerCount(
            with: 1,
            eventTimestamp: 100,
            eventUptime: 1_000
        )

        XCTAssertEqual(
            context.recordForceSample(
                x: 0.1,
                y: 0.1,
                force: 100,
                sampleTimestamp: 102,
                sampleUptime: 1_001
            ),
            frame.contactGeneration
        )
        XCTAssertTrue(
            context.takePendingForceSamples(
                contactGeneration: frame.contactGeneration,
                throughEventTimestamp: 101
            ).isEmpty
        )
        XCTAssertEqual(
            context.takePendingForceSamples(
                contactGeneration: frame.contactGeneration,
                throughEventTimestamp: 102
            ).map(\.sampleTimestamp),
            [102]
        )
    }

    func testLateForceBeforeZeroStaysWithClosingGenerationAfterNextStart() {
        let context = DeviceCallbackContext(deviceID: 1)
        let first = context.replaceFingerCount(
            with: 1,
            eventTimestamp: 100,
            eventUptime: 1_000
        )
        _ = context.replaceFingerCount(
            with: 0,
            eventTimestamp: 110,
            eventUptime: 1_010
        )
        let second = context.replaceFingerCount(
            with: 1,
            eventTimestamp: 120,
            eventUptime: 1_020
        )

        XCTAssertNotEqual(first.contactGeneration, second.contactGeneration)
        XCTAssertEqual(
            context.recordForceSample(
                x: 0.2,
                y: 0.2,
                force: 100,
                sampleTimestamp: 105,
                sampleUptime: 1_021
            ),
            first.contactGeneration
        )
        XCTAssertEqual(
            context.takePendingForceSamples(
                contactGeneration: first.contactGeneration,
                throughEventTimestamp: 110
            ).map(\.sampleTimestamp),
            [105]
        )
        XCTAssertTrue(
            context.takePendingForceSamples(
                contactGeneration: second.contactGeneration,
                throughEventTimestamp: 130
            ).isEmpty
        )
    }

    func testZeroHardwareTimestampIsRejectedInsteadOfRelabeled() {
        let context = DeviceCallbackContext(deviceID: 1)
        _ = context.replaceFingerCount(
            with: 1,
            eventTimestamp: 100,
            eventUptime: 1_000
        )

        XCTAssertNil(
            context.recordForceSample(
                x: 0,
                y: 0,
                force: 100,
                sampleTimestamp: 0,
                sampleUptime: 1_001
            )
        )
    }

    func testForceBufferKeepsEarliestRealSampleInEachThresholdBand() {
        let context = DeviceCallbackContext(deviceID: 1)
        let frame = context.replaceFingerCount(
            with: 1,
            eventTimestamp: 100,
            eventUptime: 1_000
        )

        _ = context.recordForceSample(
            x: 0,
            y: 0,
            force: 70,
            sampleTimestamp: 105,
            sampleUptime: 1_005
        )
        _ = context.recordForceSample(
            x: 0,
            y: 0,
            force: 100,
            sampleTimestamp: 104,
            sampleUptime: 1_004
        )
        for index in 0..<70 {
            _ = context.recordForceSample(
                x: 0,
                y: 0,
                force: 70,
                sampleTimestamp: 106 + Double(index),
                sampleUptime: 1_006 + Double(index)
            )
        }
        _ = context.recordForceSample(
            x: 0,
            y: 0,
            force: 75,
            sampleTimestamp: 103,
            sampleUptime: 1_003
        )

        let samples = context.takePendingForceSamples(
            contactGeneration: frame.contactGeneration,
            throughEventTimestamp: 200
        )
        XCTAssertEqual(samples.map(\.sampleTimestamp), [103, 104])
        XCTAssertEqual(samples.map(\.force), [75, 100])
    }
}
