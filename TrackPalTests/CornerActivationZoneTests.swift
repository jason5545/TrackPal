import CoreGraphics
import XCTest

final class CornerActivationZoneTests: XCTestCase {
    func testTopLeftActionZoneAcceptsLeftHighArea() {
        let zone = CornerActivationZone(edgeSize: 0.15)

        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.10, y: 0.60),
                includeExpandedTopLeft: true
            ),
            .topLeft
        )
    }

    func testTopLeftActionZoneRejectsLeftLowArea() {
        let zone = CornerActivationZone(edgeSize: 0.15)

        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.10, y: 0.54),
                includeExpandedTopLeft: true
            )
        )
    }

    func testTopLeftActionZoneStillRespectsLeftBoundary() {
        let zone = CornerActivationZone(edgeSize: 0.15)

        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.16, y: 0.60),
                includeExpandedTopLeft: true
            )
        )
    }

    func testStrictCornersStaySquare() {
        let zone = CornerActivationZone(edgeSize: 0.15)

        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.90, y: 0.90),
                includeExpandedTopLeft: true
            ),
            .topRight
        )
        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.90, y: 0.60),
                includeExpandedTopLeft: true
            )
        )
    }

    func testStrictTopLeftCanBeCheckedWithoutExpandedArea() {
        let zone = CornerActivationZone(edgeSize: 0.15)

        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.10, y: 0.60),
                includeExpandedTopLeft: false
            )
        )
        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.10, y: 0.90),
                includeExpandedTopLeft: false
            ),
            .topLeft
        )
    }
}
