import CoreGraphics
import Foundation

// 水平長條（游標優先）：判斷期間游標照常移動，啟動後監看是否該交回游標。
extension ZoneScrollEngine {

    // MARK: - Horizontal Strip (pointer-first)

    func beginStripIntentEvaluation(
        zone: ScrollZone,
        position: CGPoint,
        timestamp: Double,
        eventUptime: Double
    ) {
        // 不走 contact.isScrollActivationPending 那套緩衝流程，也不凍結游標：
        // 在 gate 啟動之前，這次接觸就是一般的游標移動。
        contact.isScrollActivationPending = false
        contact.activationOriginalZone = zone
        contact.scrollIntentGate = nil
        isActivelyScrollingInZone = false
        isEvaluatingScrollCandidate = false
        contact.gestureOutcome = .stripPending

        let landedAfterPointerActivity = pointerActivityRecency
            .landedAfterPointerActivity(at: eventUptime)
        let continuesRecentScroll = pointerActivityRecency
            .continuesHorizontalScroll(at: eventUptime)
        var gate = HorizontalStripIntentGate(
            side: zone == .topEdge ? .top : .bottom,
            configuration: .init(stripDepth: configuration.bottomZoneHeight),
            landedAfterPointerActivity: landedAfterPointerActivity,
            continuesRecentScroll: continuesRecentScroll
        )
        let decision = gate.observe(position: position, timestamp: timestamp)
        contact.stripIntentGate = gate
        contact.stripPointerOrigin = effects.pointerLocation()

        effects.log(String(
            format: "Gesture %llu started at (%.3f, %.3f) zone=%@ [STRIP-PENDING afterPointer=%d afterScroll=%d required=%.3f/%.2fs]",
            contact.activeTouchSessionID ?? 0,
            position.x,
            position.y,
            String(describing: zone),
            landedAfterPointerActivity ? 1 : 0,
            continuesRecentScroll ? 1 : 0,
            gate.requiredDistance,
            gate.requiredDuration
        ))
        applyStripIntentDecision(decision, gate: gate)
    }

    func applyStripIntentDecision(
        _ decision: HorizontalStripIntentGate.Decision,
        gate: HorizontalStripIntentGate
    ) {
        switch decision {
        case .pending:
            return

        case .activate:
            contact.stripIntentGate = nil
            contact.horizontalExitMonitor = makeHorizontalExitMonitor(for: contact.currentZone)
            // 判斷期間的位移已經用在游標上，不補送成捲動；從這一幀之後
            // 的位移才開始捲。
            contact.scrollAccumulatorX = 0
            contact.scrollAccumulatorY = 0
            isActivelyScrollingInZone = true
            contact.gestureOutcome = .scroll(contact.currentZone)
            // 判斷期間游標跟著手指走了一小段。確認是捲動後放回落指時的位置，
            // 捲動事件才會送到原本游標底下的內容。Associate 是為了取消
            // warp 之後預設 0.25 秒的滑鼠事件抑制。
            if let origin = contact.stripPointerOrigin {
                effects.warpPointer(to: origin)
            }
            effects.log(String(
                format: "Scroll activated: %@ (strip) deltas=%d net=(%.4f,%.4f) required=%.3f/%.2fs afterPointer=%d",
                String(describing: contact.currentZone),
                gate.windowDeltaCount,
                gate.windowNet.x,
                gate.windowNet.y,
                gate.requiredDistance,
                gate.requiredDuration,
                gate.landedAfterPointerActivity ? 1 : 0
            ))

        case let .reject(reason):
            contact.stripIntentGate = nil
            contact.velocityHistory.removeAll()
            let rejectedZone = contact.currentZone
            contact.currentZone = .center
            contact.gestureOutcome = .stripRejected(reason)
            effects.log(String(
                format: "Strip scroll rejected → center (%@) zone=%@ deltas=%d net=(%.4f,%.4f) excursion=%.4f",
                reason.rawValue,
                String(describing: rejectedZone),
                gate.windowDeltaCount,
                gate.windowNet.x,
                gate.windowNet.y,
                gate.maximumExcursionFromTouchDown
            ))
        }
    }

    func makeHorizontalExitMonitor(
        for zone: ScrollZone
    ) -> HorizontalScrollExitMonitor? {
        switch zone {
        case .bottomEdge:
            return HorizontalScrollExitMonitor(
                side: .bottom,
                configuration: .init(stripDepth: configuration.bottomZoneHeight)
            )
        case .topEdge:
            return HorizontalScrollExitMonitor(
                side: .top,
                configuration: .init(stripDepth: configuration.bottomZoneHeight)
            )
        default:
            return nil
        }
    }

    /// 水平捲動啟動後，手指離開長條或明顯轉向垂直時，取消捲動並交回游標。
    /// 這一幀不送捲動事件；mouseMoved 隨 `isActivelyScrollingInZone`
    /// 變成 false 恢復放行。
    func demoteActivatedHorizontalScrollIfNeeded(
        position: CGPoint,
        delta: CGPoint
    ) -> Bool {
        guard var monitor = contact.horizontalExitMonitor else { return false }
        guard isActivelyScrollingInZone,
              isHorizontalZone(contact.currentZone) else {
            return false
        }

        let reason = monitor.observe(
            position: position,
            delta: ScrollIntentGate.Sample(dx: delta.x, dy: delta.y)
        )
        contact.horizontalExitMonitor = monitor
        guard let reason else { return false }

        let demotedZone = contact.currentZone
        contact.horizontalExitMonitor = nil
        if contact.hasEmittedScrollBegan {
            effects.postScroll(deltaX: 0, deltaY: 0, scrollPhase: 4, momentumPhase: 0)
        }
        contact.hasEmittedScrollBegan = false
        contact.velocityHistory.removeAll()
        contact.scrollAccumulatorX = 0
        contact.scrollAccumulatorY = 0
        isActivelyScrollingInZone = false
        contact.currentZone = .center
        contact.gestureOutcome = .scrollDemoted(demotedZone)
        effects.log(String(
            format: "Scroll demoted → center (%@) zone=%@ position=(%.3f,%.3f) pixels=(%lld,%lld)",
            reason.rawValue,
            String(describing: demotedZone),
            position.x,
            position.y,
            contact.emittedScrollPixelsX,
            contact.emittedScrollPixelsY
        ))
        return true
    }
}
