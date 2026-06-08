import XCTest

final class PrimaryClickSuppressionGateTests: XCTestCase {
    func testSuppressesLeftClickSequenceInsideArmedWindow() {
        var gate = PrimaryClickSuppressionGate()
        gate.arm(now: 1_000, durationNanoseconds: 500)

        XCTAssertTrue(gate.shouldSuppress(event: .leftMouseDown, now: 1_100))
        XCTAssertTrue(gate.shouldSuppress(event: .leftMouseUp, now: 1_200))
    }

    func testDoesNotSuppressClickAfterWindowWithoutCapturedDown() {
        var gate = PrimaryClickSuppressionGate()
        gate.arm(now: 1_000, durationNanoseconds: 500)

        XCTAssertFalse(gate.shouldSuppress(event: .leftMouseDown, now: 1_501))
        XCTAssertFalse(gate.shouldSuppress(event: .leftMouseUp, now: 1_502))
    }

    func testSuppressesLateUpAfterCapturedDown() {
        var gate = PrimaryClickSuppressionGate()
        gate.arm(now: 1_000, durationNanoseconds: 500)

        XCTAssertTrue(gate.shouldSuppress(event: .leftMouseDown, now: 1_100))
        XCTAssertTrue(gate.shouldSuppress(event: .leftMouseUp, now: 2_000))
    }

    func testStopsSuppressingAfterCapturedUp() {
        var gate = PrimaryClickSuppressionGate()
        gate.arm(now: 1_000, durationNanoseconds: 500)

        XCTAssertTrue(gate.shouldSuppress(event: .leftMouseDown, now: 1_100))
        XCTAssertTrue(gate.shouldSuppress(event: .leftMouseUp, now: 1_120))
        XCTAssertFalse(gate.shouldSuppress(event: .leftMouseDown, now: 1_130))
    }
}
