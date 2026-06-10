import CoreGraphics
import XCTest

final class CornerActivationZoneTests: XCTestCase {
    func testExpandedCornerZonesAcceptFarEdgeAreas() {
        let zone = CornerActivationZone(edgeSize: 0.15)

        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.10, y: 0.78),
                includeExpandedCorners: true
            ),
            .topLeft
        )

        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.90, y: 0.78),
                includeExpandedCorners: true
            ),
            .topRight
        )

        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.10, y: 0.22),
                includeExpandedCorners: true
            ),
            .bottomLeft
        )

        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.90, y: 0.22),
                includeExpandedCorners: true
            ),
            .bottomRight
        )
    }

    func testExpandedCornerZonesRejectNearMisses() {
        let zone = CornerActivationZone(edgeSize: 0.15)

        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.10, y: 0.76),
                includeExpandedCorners: true
            )
        )

        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.90, y: 0.76),
                includeExpandedCorners: true
            )
        )

        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.10, y: 0.24),
                includeExpandedCorners: true
            )
        )

        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.90, y: 0.24),
                includeExpandedCorners: true
            )
        )
    }

    func testExpandedCornerZonesRejectMiddleSideAreas() {
        let zone = CornerActivationZone(edgeSize: 0.15)

        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.05, y: 0.59),
                includeExpandedCorners: true
            )
        )

        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.95, y: 0.59),
                includeExpandedCorners: true
            )
        )
    }

    func testExpandedCornerZonesIncludeBoundaries() {
        let zone = CornerActivationZone(edgeSize: 0.15)
        let nearEdgeBoundary = 1.0 - CornerActivationZone.defaultFarEdgeBoundary

        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.03, y: 0.77),
                includeExpandedCorners: true
            ),
            .topLeft
        )

        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.97, y: 0.77),
                includeExpandedCorners: true
            ),
            .topRight
        )

        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.03, y: nearEdgeBoundary),
                includeExpandedCorners: true
            ),
            .bottomLeft
        )

        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.97, y: nearEdgeBoundary),
                includeExpandedCorners: true
            ),
            .bottomRight
        )
    }

    func testExpandedCornerZonesRespectSideBoundaries() {
        let zone = CornerActivationZone(edgeSize: 0.15)

        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.16, y: 0.78),
                includeExpandedCorners: true
            )
        )

        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.84, y: 0.78),
                includeExpandedCorners: true
            )
        )

        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.16, y: 0.22),
                includeExpandedCorners: true
            )
        )

        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.84, y: 0.22),
                includeExpandedCorners: true
            )
        )
    }

    func testStrictCornersStaySquare() {
        let zone = CornerActivationZone(edgeSize: 0.15)

        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.90, y: 0.90),
                includeExpandedCorners: true
            ),
            .topRight
        )
        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.90, y: 0.60),
                includeExpandedCorners: true
            )
        )
    }

    func testStrictCornersCanBeCheckedWithoutExpandedAreas() {
        let zone = CornerActivationZone(edgeSize: 0.15)

        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.10, y: 0.78),
                includeExpandedCorners: false
            )
        )
        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.90, y: 0.78),
                includeExpandedCorners: false
            )
        )
        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.10, y: 0.22),
                includeExpandedCorners: false
            )
        )
        XCTAssertNil(
            zone.corner(
                at: CGPoint(x: 0.90, y: 0.22),
                includeExpandedCorners: false
            )
        )

        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.10, y: 0.90),
                includeExpandedCorners: false
            ),
            .topLeft
        )
        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.90, y: 0.90),
                includeExpandedCorners: false
            ),
            .topRight
        )
        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.10, y: 0.10),
                includeExpandedCorners: false
            ),
            .bottomLeft
        )
        XCTAssertEqual(
            zone.corner(
                at: CGPoint(x: 0.90, y: 0.10),
                includeExpandedCorners: false
            ),
            .bottomRight
        )
    }
}
