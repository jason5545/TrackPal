import CoreGraphics
import XCTest
@testable import TrackPalCore

/// 水平長條的游標優先判斷。數字取自 2026-11-10～11-11 的 TrackPal.log 與
/// 部署後的 TrackPal.traces.jsonl：下方區厚度 0.1647，觸控幀間隔約 8 ms。
final class HorizontalStripIntentGateTests: XCTestCase {
    private let stripDepth: CGFloat = 0.1647
    private let frameInterval: Double = 0.008

    private func makeGate(
        side: HorizontalStripIntentGate.Side = .bottom,
        afterPointerActivity: Bool = false,
        afterScroll: Bool = false
    ) -> HorizontalStripIntentGate {
        HorizontalStripIntentGate(
            side: side,
            configuration: .init(stripDepth: stripDepth),
            landedAfterPointerActivity: afterPointerActivity,
            continuesRecentScroll: afterScroll
        )
    }

    /// 連續送入逐幀位移，記下每一幀的決策。第 0 筆是落指那一幀。
    private struct Driver {
        var gate: HorizontalStripIntentGate
        var position: CGPoint
        var time: Double = 100
        let frameInterval: Double
        private(set) var decisions: [HorizontalStripIntentGate.Decision] = []

        init(
            gate: HorizontalStripIntentGate,
            start: CGPoint,
            frameInterval: Double
        ) {
            self.gate = gate
            self.position = start
            self.frameInterval = frameInterval
            decisions.append(self.gate.observe(position: start, timestamp: time))
        }

        @discardableResult
        mutating func move(
            dx: CGFloat,
            dy: CGFloat,
            frames: Int = 1
        ) -> HorizontalStripIntentGate.Decision {
            var last = decisions.last ?? .pending
            for _ in 0..<frames {
                position.x += dx
                position.y += dy
                time += frameInterval
                last = gate.observe(position: position, timestamp: time)
                decisions.append(last)
            }
            return last
        }

        /// 第一筆不是 pending 的決策出現在第幾幀。
        var firstDecisionFrame: Int? {
            decisions.firstIndex { $0 != .pending }
        }
    }

    private func driver(
        _ gate: HorizontalStripIntentGate,
        start: CGPoint
    ) -> Driver {
        Driver(gate: gate, start: start, frameInterval: frameInterval)
    }

    // MARK: - Activation

    func testMillimeterSlideStaysPending() {
        // Gesture 4343：24 ms 內水平淨位移 0.0054，舊 gate 啟動了水平捲動。
        var run = driver(makeGate(), start: CGPoint(x: 0.40, y: 0.01))

        XCTAssertEqual(run.move(dx: 0.0018, dy: -0.0002, frames: 3), .pending)
    }

    func testOldActivationDistanceIsNoLongerEnough() {
        // 舊門檻是補償後 0.016（約 1.6 mm）。
        var run = driver(makeGate(), start: CGPoint(x: 0.40, y: 0.01))

        XCTAssertEqual(run.move(dx: 0.001, dy: 0, frames: 20), .pending)
    }

    func testRimSlideActivatesAtFiveMillimeters() {
        var run = driver(makeGate(), start: CGPoint(x: 0.30, y: 0.01))

        // 每幀補償後 0.0032；第 16 幀淨位移 0.0512、歷時 0.128 秒。
        XCTAssertEqual(run.move(dx: 0.002, dy: 0.0001, frames: 15), .pending)
        XCTAssertEqual(run.move(dx: 0.002, dy: 0.0001), .activate)
    }

    func testLeftwardRimSlideActivates() {
        var run = driver(makeGate(), start: CGPoint(x: 0.60, y: 0.015))

        XCTAssertEqual(run.move(dx: -0.0025, dy: -0.0002, frames: 20), .activate)
    }

    func testLoggedRimScrollActivates() {
        // Trace 9（11/11 15:26:58）：從 (0.402, 0.000) 貼著下緣往右慢滑，
        // 1.1 秒走到 x = 0.565，y 最高 0.016。
        var run = driver(makeGate(), start: CGPoint(x: 0.402, y: 0.0))

        let decision = run.move(dx: 0.0012, dy: 0.0001, frames: 60)

        XCTAssertEqual(decision, .activate)
        XCTAssertLessThanOrEqual(run.firstDecisionFrame ?? .max, 30)
    }

    func testSlowDeliberateSlideActivates() {
        // 約 16 mm/s 的慢速滑動不算停頓。
        var run = driver(makeGate(), start: CGPoint(x: 0.30, y: 0.01))

        XCTAssertEqual(run.move(dx: 0.0008, dy: 0, frames: 39), .pending)
        XCTAssertEqual(run.move(dx: 0.0008, dy: 0, frames: 2), .activate)
    }

    func testFastBrushAcrossRimDoesNotActivate() {
        // Gesture 929：0.07 秒內橫向掠過 0.056，是手掠過下緣。
        var run = driver(makeGate(), start: CGPoint(x: 0.404, y: 0.001))

        XCTAssertEqual(run.move(dx: 0.005, dy: 0, frames: 9), .pending)
    }

    func testActivationRequiresFingerInsideStrip() {
        // 起點在長條頂端，滑動時慢慢上飄：距離和時間都夠了，但手指已經在
        // 長條外（還沒超過離開邊界），不啟動；再飄就交給游標。
        var run = driver(makeGate(), start: CGPoint(x: 0.30, y: 0.164))

        XCTAssertEqual(run.move(dx: 0.002, dy: 0.0004, frames: 51), .pending)
        XCTAssertEqual(run.move(dx: 0.002, dy: 0.0004), .reject(.leftStrip))
    }

    // MARK: - Pointer movement

    func testDiagonalCursorMoveIsHandedToPointer() {
        // Gesture 8662：從下方區往左上走，整段淨位移 (-0.405, 0.743)。
        var run = driver(makeGate(), start: CGPoint(x: 0.57, y: 0.02))

        let decision = run.move(dx: -0.0025, dy: 0.0074, frames: 40)

        XCTAssertEqual(decision, .reject(.verticalMovement))
        XCTAssertFalse(run.decisions.contains(.activate))
        XCTAssertLessThanOrEqual(run.firstDecisionFrame ?? .max, 6)
    }

    func testLeavingStripHandsContactToPointer() {
        var run = driver(makeGate(), start: CGPoint(x: 0.30, y: 0.160))

        // 第 5 幀 y = 0.185，超過長條 0.1647 加邊界 0.02。
        XCTAssertEqual(run.move(dx: 0.002, dy: 0.005, frames: 4), .pending)
        XCTAssertEqual(run.move(dx: 0.002, dy: 0.005), .reject(.leftStrip))
    }

    func testShallowDiagonalNeverActivates() {
        // 斜度約 0.4：不夠水平，也還不算明顯垂直。走完路徑上限後交給游標。
        var run = driver(makeGate(), start: CGPoint(x: 0.10, y: 0.02))

        let decision = run.move(dx: 0.004, dy: 0.00256, frames: 40)

        XCTAssertEqual(decision, .reject(.wandering))
        XCTAssertFalse(run.decisions.contains(.activate))
    }

    func testBackAndForthDoesNotActivate() {
        var run = driver(makeGate(), start: CGPoint(x: 0.40, y: 0.01))

        run.move(dx: 0.004, dy: 0, frames: 5)
        run.move(dx: -0.004, dy: 0, frames: 5)
        let decision = run.move(dx: 0.004, dy: 0, frames: 30)

        XCTAssertEqual(decision, .reject(.wandering))
        XCTAssertFalse(run.decisions.contains(.activate))
    }

    func testDecisionIsStickyAfterRejection() {
        var run = driver(makeGate(), start: CGPoint(x: 0.57, y: 0.02))
        run.move(dx: -0.0025, dy: 0.0074, frames: 10)

        // 之後回到長條裡直直橫滑，也不會中途變成捲動。
        run.position = CGPoint(x: 0.30, y: 0.01)
        XCTAssertEqual(
            run.move(dx: 0.002, dy: 0, frames: 40),
            .reject(.verticalMovement)
        )
    }

    func testFingerSlidingOnFromBezelIsHandedToPointer() {
        // Gesture 7724：從下緣滑進觸控板再一路往左上，淨位移垂直 0.999，
        // 舊 gate 整段都當成水平捲動。貼邊那幾幀 y 被夾住，看起來是純水平。
        var run = driver(makeGate(), start: CGPoint(x: 0.70, y: 0.0))

        XCTAssertEqual(run.move(dx: -0.004, dy: 0, frames: 10), .pending)
        let decision = run.move(dx: -0.002, dy: 0.007, frames: 30)

        XCTAssertEqual(decision, .reject(.verticalMovement))
        XCTAssertFalse(run.decisions.contains(.activate))
    }

    // MARK: - Cautious contexts

    func testLandingAfterPointerActivityNeedsLongerSlide() {
        var run = driver(
            makeGate(afterPointerActivity: true),
            start: CGPoint(x: 0.20, y: 0.01)
        )

        // 一般門檻（第 16 幀）不啟動；要到 0.08、0.20 秒（第 25～26 幀）。
        XCTAssertEqual(run.move(dx: 0.002, dy: 0, frames: 24), .pending)
        XCTAssertEqual(run.move(dx: 0.002, dy: 0, frames: 3), .activate)
    }

    func testLoggedRimScrollRightAfterPointerActivityActivates() {
        // Trace 3（11/11 15:26:43）：上一個接觸結束 0.4 秒後，從 (0.048, 0.003)
        // 貼著下緣往右慢滑到 0.192。這是刻意的捲動，不能被擋掉。
        var run = driver(
            makeGate(afterPointerActivity: true),
            start: CGPoint(x: 0.048, y: 0.003)
        )

        let decision = run.move(dx: 0.00115, dy: 0.00005, frames: 125)

        XCTAssertEqual(decision, .activate)
        XCTAssertLessThanOrEqual(run.firstDecisionFrame ?? .max, 75)
    }

    func testFastRimGrazeAfterPointerActivityDoesNotActivate() {
        // Gesture 3096：游標移動結束 0.22 秒後，下緣出現 0.2 秒、橫向 0.151
        // 的接觸（手收回來時掠過邊緣）。
        var run = driver(
            makeGate(afterPointerActivity: true),
            start: CGPoint(x: 0.24, y: 0.0)
        )

        XCTAssertEqual(run.move(dx: -0.0038, dy: 0, frames: 20), .pending)
    }

    func testFastStraightSlideWaitingOnDurationIsNotWandering() {
        // Trace 64（11/11 15:35:38）：刻意的快速橫滑，在最短持續時間之前
        // 就走完路徑上限，第二版把它判成游移。
        var run = driver(
            makeGate(afterPointerActivity: true),
            start: CGPoint(x: 0.20, y: 0.056)
        )

        XCTAssertEqual(run.move(dx: 0.007, dy: 0.0002, frames: 24), .pending)
        XCTAssertEqual(run.move(dx: 0.007, dy: 0.0002, frames: 3), .activate)
    }

    // MARK: - Moving toward the rim

    func testOriginDepthDoesNotChangeThresholds() {
        // 實機記到的刻意捲動，起點離下緣 0～8 mm 都有。
        var run = driver(makeGate(), start: CGPoint(x: 0.33, y: 0.10))

        XCTAssertEqual(run.move(dx: 0.002, dy: 0, frames: 15), .pending)
        XCTAssertEqual(run.move(dx: 0.002, dy: 0), .activate)
    }

    func testDescendingToRimThenSlidingActivates() {
        // Trace 60（11/11 15:35:31）：落在 (0.485, 0.059)，先往下緣靠 3 mm
        // 再往左滑。第二版在往下那段就判成垂直移動。
        var run = driver(makeGate(), start: CGPoint(x: 0.485, y: 0.059))

        XCTAssertEqual(run.move(dx: 0, dy: -0.004, frames: 8), .pending)
        XCTAssertEqual(run.move(dx: -0.003, dy: 0, frames: 20), .activate)
    }

    func testSlidingWhileDescendingToRimActivates() {
        // Trace 58（11/11 15:35:29）：從 (0.541, 0.079) 一邊往右滑一邊往下緣
        // 靠，結束在 (0.737, 0.032)。
        var run = driver(makeGate(), start: CGPoint(x: 0.541, y: 0.079))

        XCTAssertEqual(run.move(dx: 0.0027, dy: -0.00065, frames: 20), .activate)
    }

    func testSteepDescentWithLittleSidewaysTravelDoesNotActivate() {
        // 幾乎直直往下：橫向只有垂直的一半。
        var run = driver(makeGate(), start: CGPoint(x: 0.40, y: 0.16))

        XCTAssertEqual(run.move(dx: 0.001, dy: -0.004, frames: 38), .pending)
    }

    func testFollowUpStrokeAfterScrollUsesNormalThresholds() {
        // Trace 46（11/11 15:35:07）：前一下水平捲動結束 0.8 秒後，第二下落在
        // 離下緣較遠的位置往右滑。加嚴的話 0.39 秒才啟動，只捲到 2 px。
        var run = driver(
            makeGate(afterScroll: true),
            start: CGPoint(x: 0.378, y: 0.10)
        )

        XCTAssertEqual(run.move(dx: 0.002, dy: 0, frames: 15), .pending)
        XCTAssertEqual(run.move(dx: 0.002, dy: 0), .activate)
    }

    func testScrollContinuationOverridesPointerActivity() {
        var run = driver(
            makeGate(afterPointerActivity: true, afterScroll: true),
            start: CGPoint(x: 0.30, y: 0.01)
        )

        XCTAssertEqual(run.move(dx: 0.002, dy: 0, frames: 16), .activate)
    }

    func testHorizontalScrollContinuationWindow() {
        var recency = PointerActivityRecency()
        XCTAssertFalse(recency.continuesHorizontalScroll(at: 10))

        recency.recordHorizontalScrollEnd(at: 10)

        XCTAssertTrue(recency.continuesHorizontalScroll(at: 10.8))
        XCTAssertFalse(recency.continuesHorizontalScroll(at: 11.1))
        XCTAssertFalse(recency.continuesHorizontalScroll(at: 9.5))
        // 捲動結束不算游標活動。
        XCTAssertFalse(recency.landedAfterPointerActivity(at: 10.2))
    }

    // MARK: - Pauses and interruptions

    func testRestThenSlideActivatesFromRestPoint() {
        var run = driver(makeGate(), start: CGPoint(x: 0.30, y: 0.02))

        // 手指先停 0.24 秒，只有顫動。
        for index in 0..<30 {
            let jitter: CGFloat = index.isMultiple(of: 2) ? 0.0003 : -0.0003
            XCTAssertEqual(run.move(dx: jitter, dy: 0), .pending)
        }

        XCTAssertEqual(run.move(dx: 0.002, dy: 0, frames: 14), .pending)
        XCTAssertEqual(run.move(dx: 0.002, dy: 0, frames: 6), .activate)
    }

    func testPauseAfterTravelHandsContactToPointer() {
        var run = driver(makeGate(), start: CGPoint(x: 0.30, y: 0.02))

        // 移動 0.032（超過原地範圍 0.025）後停住。
        XCTAssertEqual(run.move(dx: 0.004, dy: 0, frames: 5), .pending)
        let decision = run.move(dx: 0, dy: 0, frames: 25)

        XCTAssertEqual(decision, .reject(.pausedAfterTravel))
    }

    func testInterruptWhileRestingReanchorsWindow() {
        var run = driver(makeGate(), start: CGPoint(x: 0.30, y: 0.01))
        XCTAssertEqual(run.move(dx: 0.002, dy: 0, frames: 2), .pending)

        XCTAssertEqual(run.gate.interrupt(), .pending)

        // 重新起算：下一幀只當新起點，之後還要完整的 0.05。
        XCTAssertEqual(run.move(dx: 0.002, dy: 0), .pending)
        XCTAssertEqual(run.move(dx: 0.002, dy: 0, frames: 15), .pending)
        XCTAssertEqual(run.move(dx: 0.002, dy: 0, frames: 3), .activate)
    }

    func testInterruptAfterTravelHandsContactToPointer() {
        var run = driver(makeGate(), start: CGPoint(x: 0.30, y: 0.01))
        run.move(dx: 0.004, dy: 0, frames: 5)

        XCTAssertEqual(run.gate.interrupt(), .reject(.interruptedAfterTravel))
    }

    func testNonFinitePositionIsRejected() {
        var gate = makeGate()
        _ = gate.observe(position: CGPoint(x: 0.3, y: 0.01), timestamp: 100)

        XCTAssertEqual(
            gate.observe(
                position: CGPoint(x: CGFloat.nan, y: 0.01),
                timestamp: 100.008
            ),
            .reject(.interruptedAfterTravel)
        )
    }

    // MARK: - Top strip

    func testTopStripMirrorsBottomStrip() {
        var straight = driver(
            makeGate(side: .top),
            start: CGPoint(x: 0.30, y: 0.99)
        )
        XCTAssertEqual(straight.move(dx: 0.002, dy: 0, frames: 20), .activate)

        var leaving = driver(
            makeGate(side: .top),
            start: CGPoint(x: 0.30, y: 0.84)
        )
        XCTAssertEqual(
            leaving.move(dx: 0.002, dy: -0.005, frames: 5),
            .reject(.leftStrip)
        )
    }

    // MARK: - Exit monitor

    private func makeMonitor(
        side: HorizontalStripIntentGate.Side = .bottom
    ) -> HorizontalScrollExitMonitor {
        HorizontalScrollExitMonitor(
            side: side,
            configuration: .init(stripDepth: stripDepth)
        )
    }

    func testExitMonitorDemotesWhenFingerLeavesStrip() {
        var monitor = makeMonitor()

        XCTAssertNil(monitor.observe(
            position: CGPoint(x: 0.4, y: 0.19),
            delta: .init(dx: 0.004, dy: 0.0005)
        ))
        XCTAssertEqual(
            monitor.observe(
                position: CGPoint(x: 0.404, y: 0.196),
                delta: .init(dx: 0.004, dy: 0.006)
            ),
            .leftStrip
        )
    }

    func testExitMonitorDemotesWhenMovementTurnsVertical() {
        // 啟動後手指改往上走：每幀 (-0.0015, 0.008)。
        var monitor = makeMonitor()
        var position = CGPoint(x: 0.5, y: 0.02)
        var demotion: HorizontalScrollExitMonitor.DemotionReason?
        var frames = 0

        while demotion == nil, frames < 20 {
            position.x -= 0.0015
            position.y += 0.008
            demotion = monitor.observe(
                position: position,
                delta: .init(dx: -0.0015, dy: 0.008)
            )
            frames += 1
        }

        XCTAssertEqual(demotion, .turnedVertical)
        XCTAssertLessThanOrEqual(frames, 5)
        XCTAssertLessThan(position.y, stripDepth)
    }

    func testExitMonitorHasNoExpiry() {
        // 舊監測在水平路徑 0.12 之後失效；長時間捲動後轉向仍要交回游標。
        var monitor = makeMonitor()
        var position = CGPoint(x: 0.1, y: 0.03)
        for _ in 0..<60 {
            position.x += 0.004
            XCTAssertNil(monitor.observe(
                position: position,
                delta: .init(dx: 0.004, dy: 0)
            ))
        }

        var demotion: HorizontalScrollExitMonitor.DemotionReason?
        for _ in 0..<8 where demotion == nil {
            position.y += 0.008
            demotion = monitor.observe(
                position: position,
                delta: .init(dx: 0, dy: 0.008)
            )
        }

        XCTAssertEqual(demotion, .turnedVertical)
    }

    func testExitMonitorKeepsStraightScrollAcrossTrackpad() {
        var monitor = makeMonitor()
        var position = CGPoint(x: 0.05, y: 0.10)

        for _ in 0..<150 {
            position.x += 0.004
            position.y = max(0, position.y - 0.0004)
            XCTAssertNil(monitor.observe(
                position: position,
                delta: .init(dx: 0.004, dy: -0.0004)
            ))
        }
    }

    func testExitMonitorKeepsBackAndForthScroll() {
        var monitor = makeMonitor()
        var position = CGPoint(x: 0.3, y: 0.06)

        for round in 0..<6 {
            let dx: CGFloat = round.isMultiple(of: 2) ? 0.004 : -0.004
            for _ in 0..<12 {
                position.x += dx
                XCTAssertNil(monitor.observe(
                    position: position,
                    delta: .init(dx: dx, dy: 0.0002)
                ))
            }
        }
    }

    func testExitMonitorToleratesVerticalWobble() {
        var monitor = makeMonitor()
        var position = CGPoint(x: 0.3, y: 0.06)

        for index in 0..<40 {
            let dy: CGFloat = index.isMultiple(of: 2) ? 0.003 : -0.003
            position.y += dy
            XCTAssertNil(monitor.observe(
                position: position,
                delta: .init(dx: 0, dy: dy)
            ))
        }
    }

    // MARK: - Pointer activity recency

    func testPointerActivityRecencyWindow() {
        var recency = PointerActivityRecency()
        XCTAssertFalse(recency.landedAfterPointerActivity(at: 10))

        recency.recordPointerActivityEnd(at: 10)

        XCTAssertTrue(recency.landedAfterPointerActivity(at: 10.3))
        XCTAssertTrue(recency.landedAfterPointerActivity(at: 10.65))
        XCTAssertFalse(recency.landedAfterPointerActivity(at: 10.75))
        XCTAssertFalse(recency.landedAfterPointerActivity(at: 25))
        // 時間倒退（不同時鐘或重新啟動）不算剛移完游標。
        XCTAssertFalse(recency.landedAfterPointerActivity(at: 9.9))

        recency.reset()
        XCTAssertFalse(recency.landedAfterPointerActivity(at: 10.3))
    }
}
