import CoreGraphics
import Foundation

// 把位移換成捲動像素：加速曲線、次像素累加、啟動時至少送出一個像素。
extension ZoneScrollEngine {

    func applyAccelerationCurve(_ delta: CGPoint) -> CGPoint {
        switch configuration.accelerationCurveType {
        case .linear:
            return delta

        case .quadratic:
            // Quadratic: delta * |delta| - preserves sign, accelerates larger movements
            return CGPoint(
                x: delta.x * abs(delta.x),
                y: delta.y * abs(delta.y)
            )

        case .cubic:
            // Cubic: delta * delta² - even stronger acceleration for large movements
            return CGPoint(
                x: delta.x * delta.x * delta.x,
                y: delta.y * delta.y * delta.y
            )

        case .ease:
            // Smoothstep-like easing: smooth transition for small and large movements
            func smoothstep(_ x: CGFloat) -> CGFloat {
                let t = min(max(abs(x) * 10, 0), 1) // Normalize to 0-1 range
                let smooth = t * t * (3 - 2 * t)    // Smoothstep formula
                return x * (0.5 + smooth * 0.5)     // Scale factor 0.5 to 1.0
            }
            return CGPoint(
                x: smoothstep(delta.x),
                y: smoothstep(delta.y)
            )
        }
    }

    /// 手指最近沿著捲動軸的速度（每秒幾個觸控板高）：最近幾幀的平均。水平方向
    /// 乘上寬高比換成同樣的實體尺度。還沒有速度樣本時回傳一個中等的速度。
    func recentAxisSpeed(for zone: ScrollZone) -> CGFloat {
        guard !contact.velocityHistory.isEmpty else {
            return NativeScrollCurve.nominalSpeed
        }
        let count = CGFloat(contact.velocityHistory.count)
        switch zone {
        case .leftEdge, .rightEdge:
            return abs(contact.velocityHistory.reduce(0) { $0 + $1.vy } / count)
        case .bottomEdge, .topEdge:
            return abs(contact.velocityHistory.reduce(0) { $0 + $1.vx } / count)
                * ScrollIntentGate.horizontalAspectCompensation
        default:
            return NativeScrollCurve.nominalSpeed
        }
    }

    func handleScroll(delta: CGPoint, zone: ScrollZone) {
        // Apply acceleration curve to delta
        let adjustedDelta = applyAccelerationCurve(delta)

        switch zone {
        case .leftEdge, .rightEdge:
            // Vertical scrolling - use Y delta
            // Natural scrolling: invert direction (swipe up = content moves up)
            contact.scrollAccumulatorY += -adjustedDelta.y
                * configuration.scrollMultiplier
                * NativeScrollCurve.contactGain(atSpeed: recentAxisSpeed(for: zone))
            isActivelyScrollingInZone = true

        case .bottomEdge, .topEdge:
            if isHorizontalScrollTemporarilyLocked() {
                if !contact.hasLoggedHorizontalLockSuppressionInTouch {
                    contact.hasLoggedHorizontalLockSuppressionInTouch = true
                    effects.log("Horizontal scroll suppressed by right-click cooldown")
                }
                isActivelyScrollingInZone = false
                return
            }
            // Horizontal scrolling - use X delta
            // Trackpad +X and screen +X both point right, so no sign inversion needed
            // (unlike vertical where trackpad +Y=up but screen +Y=down)
            // Compensate for trackpad aspect ratio (~1.6:1 width:height)
            let aspectCompensation: CGFloat = 1.6
            contact.scrollAccumulatorX += adjustedDelta.x
                * configuration.scrollMultiplier
                * NativeScrollCurve.contactGain(atSpeed: recentAxisSpeed(for: zone))
                * aspectCompensation
            isActivelyScrollingInZone = true

        case .center, .none, .middleClick,
             .topLeftCorner, .topRightCorner, .bottomLeftCorner, .bottomRightCorner:
            isActivelyScrollingInZone = false
            return
        }

        // Extract integer pixels from accumulator, keep fractional remainder
        let scrollX = Int32(contact.scrollAccumulatorX)
        let scrollY = Int32(contact.scrollAccumulatorY)
        contact.scrollAccumulatorX -= CGFloat(scrollX)
        contact.scrollAccumulatorY -= CGFloat(scrollY)

        guard scrollX != 0 || scrollY != 0 else { return }

        // Determine scroll phase: began on first event, changed on subsequent
        let phase: Int64 = contact.hasEmittedScrollBegan ? 2 : 1  // 1=began, 2=changed
        contact.hasEmittedScrollBegan = true
        contact.emittedScrollEventCount += 1
        contact.emittedScrollPixelsX += Int64(scrollX)
        contact.emittedScrollPixelsY += Int64(scrollY)

        effects.postScroll(deltaX: scrollX, deltaY: scrollY, scrollPhase: phase, momentumPhase: 0)
    }

    /// A gesture that passed the intent gate must produce observable output.
    /// At 1x sensitivity (or with a nonlinear curve), a threshold-sized buffer
    /// can still truncate to zero. Emit one signed pixel and clear that axis's
    /// sub-pixel partial; subtracting the borrowed pixel would create a reverse
    /// debt that stalls later movement, especially on quadratic/cubic curves.
    func ensureActivatedScrollEmitsAtLeastOnePixel(
        acceptedDeltas: [CGPoint],
        zone: ScrollZone
    ) {
        guard !contact.hasEmittedScrollBegan, !acceptedDeltas.isEmpty else { return }

        let net = acceptedDeltas.reduce(into: CGPoint.zero) { partial, delta in
            partial.x += delta.x
            partial.y += delta.y
        }

        let scrollX: Int32
        let scrollY: Int32
        switch zone {
        case .leftEdge, .rightEdge:
            guard net.y != 0 else { return }
            scrollX = 0
            scrollY = net.y > 0 ? -1 : 1
            contact.scrollAccumulatorY = 0

        case .bottomEdge, .topEdge:
            guard net.x != 0 else { return }
            scrollX = net.x > 0 ? 1 : -1
            scrollY = 0
            contact.scrollAccumulatorX = 0

        default:
            return
        }

        contact.hasEmittedScrollBegan = true
        contact.emittedScrollEventCount += 1
        contact.emittedScrollPixelsX += Int64(scrollX)
        contact.emittedScrollPixelsY += Int64(scrollY)
        effects.postScroll(
            deltaX: scrollX,
            deltaY: scrollY,
            scrollPhase: 1,
            momentumPhase: 0
        )
    }
}
