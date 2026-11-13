import CoreGraphics
import Foundation

// 區域判定：座標落在哪一區、角落相鄰的捲動軸、哪些角落有壓力動作。
extension ZoneScrollEngine {

    func determineZone(_ position: CGPoint) -> ScrollZone {
        // Position is normalized: x and y are 0.0 to 1.0
        // x: 0 = left, 1 = right
        // y: 0 = bottom (near user), 1 = top (away from user)

        // Check corners first (highest priority)
        if configuration.cornerTriggerEnabled {
            if let zone = cornerZone(at: position, includeExpandedCorners: true) {
                let action = configuration.cornerActions[zone]
                if action != .none {
                    return zone
                }
            }
            // Unassigned corners are not dead zones. They fall through to the
            // configured edge scroll candidates, where movement intent decides
            // whether scrolling should actually begin.
        }

        // Calculate middle click zone boundaries
        let middleLeft = (1.0 - configuration.middleClickZoneWidth) / 2
        let middleRight = middleLeft + configuration.middleClickZoneWidth

        // Check Middle Click zone (highest priority)
        if configuration.middleClickEnabled {
            let isInMiddleX = position.x >= middleLeft && position.x <= middleRight

            if configuration.horizontalPosition == .bottom {
                // Horizontal at bottom → Middle Click at top
                if position.y > (1.0 - configuration.middleClickZoneHeight) && isInMiddleX {
                    return .middleClick
                }
            } else {
                // Horizontal at top → Middle Click at bottom
                if position.y < configuration.middleClickZoneHeight && isInMiddleX {
                    return .middleClick
                }
            }
        }

        // When vertical and horizontal scroll zones overlap, neither axis gets
        // static priority. Route the contact through the dual-axis resolver so
        // movement direction chooses the scroll instead of making one corner
        // permanently dead for horizontal input.
        if let overlapCorner = overlappingScrollCorner(at: position) {
            return overlapCorner
        }

        // Check left edge based on mode
        if position.x < configuration.edgeZoneWidth {
            switch configuration.verticalEdgeMode {
            case .left, .both:
                return .leftEdge
            case .right:
                break // Skip left edge
            }
        }

        // Check right edge based on mode
        if position.x > (1.0 - configuration.edgeZoneWidth) {
            switch configuration.verticalEdgeMode {
            case .right, .both:
                return .rightEdge
            case .left:
                break // Skip right edge
            }
        }

        // Check horizontal scrolling zone based on position
        let horizontalScrollLocked = isHorizontalScrollTemporarilyLocked()
        if configuration.horizontalPosition == .bottom {
            if position.y < configuration.bottomZoneHeight {
                if horizontalScrollLocked {
                    effects.log("Horizontal zone suppressed by right-click cooldown")
                    return .center
                }
                return .bottomEdge
            }
        } else {
            if position.y > (1.0 - configuration.bottomZoneHeight) {
                if horizontalScrollLocked {
                    effects.log("Horizontal zone suppressed by right-click cooldown")
                    return .center
                }
                return .topEdge
            }
        }

        return .center
    }

    func overlappingScrollCorner(at position: CGPoint) -> ScrollZone? {
        guard !isHorizontalScrollTemporarilyLocked() else { return nil }

        let horizontalSide: HorizontalPosition?
        switch configuration.horizontalPosition {
        case .bottom where position.y < configuration.bottomZoneHeight:
            horizontalSide = .bottom
        case .top where position.y > (1.0 - configuration.bottomZoneHeight):
            horizontalSide = .top
        default:
            horizontalSide = nil
        }
        guard let horizontalSide else { return nil }

        let isLeftEnabled = configuration.verticalEdgeMode == .left || configuration.verticalEdgeMode == .both
        let isRightEnabled = configuration.verticalEdgeMode == .right || configuration.verticalEdgeMode == .both

        if isLeftEnabled, position.x < configuration.edgeZoneWidth {
            return horizontalSide == .bottom ? .bottomLeftCorner : .topLeftCorner
        }
        if isRightEnabled, position.x > (1.0 - configuration.edgeZoneWidth) {
            return horizontalSide == .bottom ? .bottomRightCorner : .topRightCorner
        }
        return nil
    }

    func cornerZone(
        at position: CGPoint,
        includeExpandedCorners: Bool
    ) -> ScrollZone? {
        let activationZone = CornerActivationZone(edgeSize: configuration.cornerTriggerZoneSize)

        guard let corner = activationZone.corner(
            at: position,
            includeExpandedCorners: includeExpandedCorners
        ) else {
            return nil
        }

        return scrollZone(for: corner)
    }

    func cornerActivationCorner(
        for zone: ScrollZone
    ) -> CornerActivationZone.Corner? {
        switch zone {
        case .topLeftCorner:
            return .topLeft
        case .topRightCorner:
            return .topRight
        case .bottomLeftCorner:
            return .bottomLeft
        case .bottomRightCorner:
            return .bottomRight
        default:
            return nil
        }
    }

    func scrollZone(
        for corner: CornerActivationZone.Corner
    ) -> ScrollZone {
        switch corner {
        case .topLeft:
            return .topLeftCorner
        case .topRight:
            return .topRightCorner
        case .bottomLeft:
            return .bottomLeftCorner
        case .bottomRight:
            return .bottomRightCorner
        }
    }

    func scrollAxis(for zone: ScrollZone) -> ScrollIntentGate.Axis? {
        switch zone {
        case .bottomEdge, .topEdge:
            return .horizontal
        case .leftEdge, .rightEdge:
            return .vertical
        default:
            return nil
        }
    }

    func scrollIntentResult(from decision: ScrollIntentGate.Decision) -> ScrollIntentResult {
        switch decision {
        case .pending:
            return .needMoreFrames
        case .activate:
            return .activated
        case .reject:
            return .rejected
        }
    }

    func adjacentScrollZones(
        for corner: ScrollZone
    ) -> (horizontal: ScrollZone?, vertical: ScrollZone?) {
        let horizontalScrollLocked = isHorizontalScrollTemporarilyLocked()

        switch corner {
        case .bottomLeftCorner:
            return (
                (!horizontalScrollLocked && configuration.horizontalPosition == .bottom) ? .bottomEdge : nil,
                (configuration.verticalEdgeMode == .left || configuration.verticalEdgeMode == .both) ? .leftEdge : nil
            )
        case .bottomRightCorner:
            return (
                (!horizontalScrollLocked && configuration.horizontalPosition == .bottom) ? .bottomEdge : nil,
                (configuration.verticalEdgeMode == .right || configuration.verticalEdgeMode == .both) ? .rightEdge : nil
            )
        case .topLeftCorner:
            return (
                (!horizontalScrollLocked && configuration.horizontalPosition == .top) ? .topEdge : nil,
                (configuration.verticalEdgeMode == .left || configuration.verticalEdgeMode == .both) ? .leftEdge : nil
            )
        case .topRightCorner:
            return (
                (!horizontalScrollLocked && configuration.horizontalPosition == .top) ? .topEdge : nil,
                (configuration.verticalEdgeMode == .right || configuration.verticalEdgeMode == .both) ? .rightEdge : nil
            )
        default:
            return (nil, nil)
        }
    }

    /// Check if a zone is a horizontal scroll zone
    func isHorizontalZone(_ zone: ScrollZone) -> Bool {
        switch zone {
        case .bottomEdge, .topEdge:
            return true
        default:
            return false
        }
    }

    func isHorizontalScrollTemporarilyLocked() -> Bool {
        contact.horizontalScrollLockedUntilLift
    }

    func engageHorizontalScrollLockAfterRightClick() {
        contact.horizontalScrollLockedUntilLift = true
        effects.log("Horizontal scroll locked until the right-click contact lifts")
    }

    /// Check if a zone is a scroll zone (edges that produce scroll events)
    func isScrollZone(_ zone: ScrollZone) -> Bool {
        switch zone {
        case .leftEdge, .rightEdge, .bottomEdge, .topEdge:
            return true
        default:
            return false
        }
    }

    func isCornerZone(_ zone: ScrollZone) -> Bool {
        switch zone {
        case .topLeftCorner, .topRightCorner, .bottomLeftCorner, .bottomRightCorner:
            return true
        default:
            return false
        }
    }

    func isForceEnabledCorner(_ zone: ScrollZone) -> Bool {
        configuration.cornerTriggerEnabled
            && isCornerZone(zone)
            && (configuration.cornerActions[zone]) != .none
    }

    func isActiveForceCandidateCorner(_ zone: ScrollZone) -> Bool {
        isForceEnabledCorner(zone) && !contact.cornerForceWindowExpired
    }

    func cornerForceRegion(for position: CGPoint, in zone: ScrollZone) -> CornerForceRegion? {
        guard let corner = cornerActivationCorner(for: zone) else { return nil }

        let activationZone = CornerActivationZone(edgeSize: configuration.cornerTriggerZoneSize)
        guard activationZone.contains(position, corner: corner) else { return nil }

        return activationZone.containsStrict(position, corner: corner) ? .strict : .band
    }
}
