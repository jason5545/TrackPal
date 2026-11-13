import CoreGraphics

struct CornerActivationZone {
    static let defaultFarEdgeBoundary: CGFloat = 0.77

    enum Corner {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    let edgeSize: CGFloat
    let farEdgeBoundary: CGFloat

    init(
        edgeSize: CGFloat,
        farEdgeBoundary: CGFloat = Self.defaultFarEdgeBoundary
    ) {
        self.edgeSize = edgeSize
        self.farEdgeBoundary = farEdgeBoundary
    }

    func contains(_ position: CGPoint, corner: Corner) -> Bool {
        switch corner {
        case .topLeft:
            return isTopBand(position) && isLeft(position)
        case .topRight:
            return isTopBand(position) && isRight(position)
        case .bottomLeft:
            return isBottomBand(position) && isLeft(position)
        case .bottomRight:
            return isBottomBand(position) && isRight(position)
        }
    }

    func containsStrict(_ position: CGPoint, corner: Corner) -> Bool {
        switch corner {
        case .topLeft:
            return isTop(position) && isLeft(position)
        case .topRight:
            return isTop(position) && isRight(position)
        case .bottomLeft:
            return isBottom(position) && isLeft(position)
        case .bottomRight:
            return isBottom(position) && isRight(position)
        }
    }

    func corner(at position: CGPoint, includeExpandedCorners: Bool) -> Corner? {
        if includeExpandedCorners {
            if contains(position, corner: .topLeft) {
                return .topLeft
            }
            if contains(position, corner: .topRight) {
                return .topRight
            }
            if contains(position, corner: .bottomLeft) {
                return .bottomLeft
            }
            if contains(position, corner: .bottomRight) {
                return .bottomRight
            }
        }

        if containsStrict(position, corner: .topLeft) {
            return .topLeft
        }
        if containsStrict(position, corner: .topRight) {
            return .topRight
        }
        if containsStrict(position, corner: .bottomLeft) {
            return .bottomLeft
        }
        if containsStrict(position, corner: .bottomRight) {
            return .bottomRight
        }

        return nil
    }

    private func isLeft(_ position: CGPoint) -> Bool {
        position.x < edgeSize
    }

    private func isRight(_ position: CGPoint) -> Bool {
        position.x > (1.0 - edgeSize)
    }

    private func isTopBand(_ position: CGPoint) -> Bool {
        position.y >= farEdgeBoundary
    }

    private func isBottomBand(_ position: CGPoint) -> Bool {
        position.y <= (1.0 - farEdgeBoundary)
    }

    private func isTop(_ position: CGPoint) -> Bool {
        position.y > (1.0 - edgeSize)
    }

    private func isBottom(_ position: CGPoint) -> Bool {
        position.y < edgeSize
    }
}
