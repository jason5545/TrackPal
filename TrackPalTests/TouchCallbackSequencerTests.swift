import XCTest

final class TouchCallbackSequencerTests: XCTestCase {
    func testLateZeroStillReceivesItsFullHoldWindow() {
        var buffer = TouchCallbackOrderingBuffer<String>()
        buffer.enqueue(
            hardwareTimestamp: 19,
            arrivalUptimeNanoseconds: 0,
            payload: "move"
        )
        buffer.enqueue(
            hardwareTimestamp: 20,
            arrivalUptimeNanoseconds: 7_000_000,
            payload: "zero"
        )

        XCTAssertEqual(
            buffer.releaseReadyEvents(at: 8_000_000),
            ["move"]
        )
        XCTAssertEqual(buffer.pendingCount, 1)
        XCTAssertEqual(buffer.nextReleaseUptimeNanoseconds, 15_000_000)
        XCTAssertTrue(
            buffer.releaseReadyEvents(at: 14_999_999).isEmpty
        )
        XCTAssertEqual(
            buffer.releaseReadyEvents(at: 15_000_000),
            ["zero"]
        )
    }

    func testEarlierZeroBlocksLaterReadyStart() {
        var buffer = TouchCallbackOrderingBuffer<String>()
        buffer.enqueue(
            hardwareTimestamp: 21,
            arrivalUptimeNanoseconds: 0,
            payload: "start"
        )
        buffer.enqueue(
            hardwareTimestamp: 20,
            arrivalUptimeNanoseconds: 7_000_000,
            payload: "zero"
        )

        XCTAssertTrue(
            buffer.releaseReadyEvents(at: 8_000_000).isEmpty
        )
        XCTAssertTrue(
            buffer.releaseReadyEvents(at: 14_999_999).isEmpty
        )
        XCTAssertEqual(
            buffer.releaseReadyEvents(at: 15_000_000),
            ["zero", "start"]
        )
    }

    func testContinuousFrameStreamReleasesIncrementally() {
        var buffer = TouchCallbackOrderingBuffer<Int>()

        for frame in 0..<20 {
            buffer.enqueue(
                hardwareTimestamp: 100 + Double(frame),
                arrivalUptimeNanoseconds: UInt64(frame) * 1_000_000,
                payload: frame
            )

            let released = buffer.releaseReadyEvents(
                at: UInt64(frame) * 1_000_000
            )
            if frame < 8 {
                XCTAssertTrue(released.isEmpty)
            } else {
                XCTAssertEqual(released, [frame - 8])
            }
        }

        for uptime in 20...27 {
            XCTAssertEqual(
                buffer.releaseReadyEvents(
                    at: UInt64(uptime) * 1_000_000
                ),
                [uptime - 8]
            )
        }
        XCTAssertEqual(buffer.pendingCount, 0)
    }

    func testZeroHoldKeepsClosingGenerationAvailableForLatePreZeroForce() {
        enum Event: Equatable {
            case move
            case zero
        }

        var buffer = TouchCallbackOrderingBuffer<Event>(
            minimumHoldNanoseconds: 8
        )
        let context = DeviceCallbackContext(deviceID: 1)
        let contact = context.replaceFingerCount(
            with: 1,
            eventTimestamp: 10,
            eventUptime: 0
        )

        buffer.enqueue(
            hardwareTimestamp: 19,
            arrivalUptimeNanoseconds: 0,
            payload: .move
        )
        _ = context.replaceFingerCount(
            with: 0,
            eventTimestamp: 20,
            eventUptime: 7
        )
        buffer.enqueue(
            hardwareTimestamp: 20,
            arrivalUptimeNanoseconds: 7,
            payload: .zero
        )

        XCTAssertEqual(buffer.releaseReadyEvents(at: 8), [.move])
        XCTAssertEqual(
            context.recordForceSample(
                x: 0.1,
                y: 0.1,
                force: 100,
                sampleTimestamp: 19.5,
                sampleUptime: 14
            ),
            contact.contactGeneration
        )

        XCTAssertEqual(buffer.releaseReadyEvents(at: 15), [.zero])
        let drained = context.takePendingForceSamples(
            contactGeneration: contact.contactGeneration,
            throughEventTimestamp: 20
        )
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.first?.sampleTimestamp, 19.5)
        context.discardPendingForceSamples(
            contactGeneration: contact.contactGeneration
        )
    }

    func testOrderedZeroLetsSuccessorDeviceClaimAtPhysicalBoundary() {
        enum Event: Equatable {
            case ownerZero
            case successorStart
        }

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

        var buffer = TouchCallbackOrderingBuffer<Event>(
            minimumHoldNanoseconds: 8
        )
        buffer.enqueue(
            hardwareTimestamp: 21,
            arrivalUptimeNanoseconds: 0,
            payload: .successorStart
        )
        buffer.enqueue(
            hardwareTimestamp: 20,
            arrivalUptimeNanoseconds: 7,
            payload: .ownerZero
        )

        XCTAssertTrue(buffer.releaseReadyEvents(at: 8).isEmpty)
        let orderedEvents = buffer.releaseReadyEvents(at: 15)
        XCTAssertEqual(orderedEvents, [.ownerZero, .successorStart])

        for event in orderedEvents {
            switch event {
            case .ownerZero:
                XCTAssertEqual(
                    gate.processTouchFrame(
                        deviceID: 1,
                        contactGeneration: 1,
                        touchCount: 0,
                        eventTimestamp: 20
                    ),
                    .accept
                )
            case .successorStart:
                XCTAssertEqual(
                    gate.processTouchFrame(
                        deviceID: 2,
                        contactGeneration: 1,
                        touchCount: 1,
                        eventTimestamp: 21
                    ),
                    .accept
                )
            }
        }
        XCTAssertEqual(gate.ownerDeviceID, 2)
    }
}
