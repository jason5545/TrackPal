import CoreGraphics

struct CornerActivationZone {
    static let defaultTopLeftMinimumY: CGFloat = 0.50

    enum Corner {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    let edgeSize: CGFloat
    let topLeftMinimumY: CGFloat

    init(
        edgeSize: CGFloat,
        topLeftMinimumY: CGFloat = Self.defaultTopLeftMinimumY
    ) {
        self.edgeSize = edgeSize
        self.topLeftMinimumY = topLeftMinimumY
    }

    func contains(_ position: CGPoint, corner: Corner) -> Bool {
        switch corner {
        case .topLeft:
            return isLeft(position) && position.y >= topLeftMinimumY
        case .topRight:
            return containsStrict(position, corner: .topRight)
        case .bottomLeft:
            return containsStrict(position, corner: .bottomLeft)
        case .bottomRight:
            return containsStrict(position, corner: .bottomRight)
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

    func corner(at position: CGPoint, includeExpandedTopLeft: Bool) -> Corner? {
        if includeExpandedTopLeft && contains(position, corner: .topLeft) {
            return .topLeft
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

    private func isTop(_ position: CGPoint) -> Bool {
        position.y > (1.0 - edgeSize)
    }

    private func isBottom(_ position: CGPoint) -> Bool {
        position.y < edgeSize
    }
}
