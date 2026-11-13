import CoreGraphics
import Testing
@testable import TrackPalCore

@MainActor
private func makeEngine(
    _ configure: (inout ZoneScrollConfiguration) -> Void = { _ in }
) -> (ZoneScrollEngine, RecordingEffects) {
    var configuration = ZoneScrollConfiguration()
    configuration.middleClickEnabled = true
    configure(&configuration)
    let effects = RecordingEffects()
    return (ZoneScrollEngine(configuration: configuration, effects: effects), effects)
}

@MainActor
@Suite("區域判定")
struct ZoneDeterminationTests {
    struct Probe: Sendable, CustomTestStringConvertible {
        var x: CGFloat
        var y: CGFloat
        var expected: ScrollZone
        var testDescription: String { "(\(x), \(y)) → \(expected)" }
    }

    @Test("預設設定（右側垂直、下方水平、中鍵在上緣中間）", arguments: [
        Probe(x: 0.5, y: 0.5, expected: .center),
        Probe(x: 0.95, y: 0.5, expected: .rightEdge),
        Probe(x: 0.05, y: 0.5, expected: .center),          // 左側沒開
        Probe(x: 0.5, y: 0.1, expected: .bottomEdge),
        Probe(x: 0.5, y: 0.29, expected: .bottomEdge),
        Probe(x: 0.5, y: 0.31, expected: .center),
        Probe(x: 0.5, y: 0.95, expected: .middleClick),
        Probe(x: 0.2, y: 0.95, expected: .center),          // 上緣但不在中間
        Probe(x: 0.95, y: 0.1, expected: .bottomRightCorner), // 兩軸重疊交給方向決定
        Probe(x: 0.05, y: 0.1, expected: .bottomEdge),
    ])
    func defaultLayout(probe: Probe) {
        let (engine, _) = makeEngine()
        #expect(engine.determineZone(CGPoint(x: probe.x, y: probe.y)) == probe.expected)
    }

    @Test("水平位置在上方時，長條與中鍵區上下對調")
    func topLayoutSwapsStripAndMiddleClick() {
        let (engine, _) = makeEngine { $0.horizontalPosition = .top }
        #expect(engine.determineZone(CGPoint(x: 0.5, y: 0.9)) == .topEdge)
        #expect(engine.determineZone(CGPoint(x: 0.5, y: 0.05)) == .middleClick)
        #expect(engine.determineZone(CGPoint(x: 0.2, y: 0.05)) == .center)
        #expect(engine.determineZone(CGPoint(x: 0.95, y: 0.9)) == .topRightCorner)
    }

    @Test("雙側模式：左右都是垂直邊緣，下方兩個角落都是重疊區")
    func bothEdges() {
        let (engine, _) = makeEngine { $0.verticalEdgeMode = .both }
        #expect(engine.determineZone(CGPoint(x: 0.05, y: 0.5)) == .leftEdge)
        #expect(engine.determineZone(CGPoint(x: 0.95, y: 0.5)) == .rightEdge)
        #expect(engine.determineZone(CGPoint(x: 0.05, y: 0.1)) == .bottomLeftCorner)
    }

    @Test("有壓力動作的角落優先於其他區域；沒指定動作的角落不佔位")
    func cornerActionsTakePriority() {
        let (engine, _) = makeEngine {
            $0.cornerTriggerEnabled = true
            $0.cornerTriggerZoneSize = 0.1
            $0.cornerActions.topLeft = .showDesktop
        }
        #expect(engine.determineZone(CGPoint(x: 0.03, y: 0.97)) == .topLeftCorner)
        // 右上角沒指定動作：回到一般判定（右側邊緣）。
        #expect(engine.determineZone(CGPoint(x: 0.97, y: 0.97)) == .rightEdge)
        #expect(engine.isForceEnabledCorner(.topLeftCorner))
        #expect(!engine.isForceEnabledCorner(.topRightCorner))
    }

    @Test("角落觸發關閉時，指定了動作也不算")
    func cornerTriggerDisabled() {
        let (engine, _) = makeEngine { $0.cornerActions.topLeft = .showDesktop }
        #expect(engine.determineZone(CGPoint(x: 0.03, y: 0.97)) == .center)
        #expect(!engine.isForceEnabledCorner(.topLeftCorner))
    }

    @Test("角落的壓力門檻分兩級：實體角落方塊內是 strict，擴大帶是 band")
    func cornerForceRegions() {
        let (engine, _) = makeEngine {
            $0.cornerTriggerEnabled = true
            $0.cornerTriggerZoneSize = 0.1
            $0.cornerActions.bottomRight = .rightClick
        }
        #expect(engine.cornerForceRegion(for: CGPoint(x: 0.97, y: 0.03), in: .bottomRightCorner) == .strict)
        #expect(engine.cornerForceRegion(for: CGPoint(x: 0.97, y: 0.18), in: .bottomRightCorner) == .band)
        #expect(engine.cornerForceRegion(for: CGPoint(x: 0.5, y: 0.5), in: .bottomRightCorner) == nil)
    }

    @Test("角落相鄰的捲動軸取決於設定")
    func adjacentZones() {
        let (engine, _) = makeEngine()
        let bottomRight = engine.adjacentScrollZones(for: .bottomRightCorner)
        #expect(bottomRight.horizontal == .bottomEdge)
        #expect(bottomRight.vertical == .rightEdge)

        let bottomLeft = engine.adjacentScrollZones(for: .bottomLeftCorner)
        #expect(bottomLeft.horizontal == .bottomEdge)
        #expect(bottomLeft.vertical == nil)       // 左側沒開

        let topRight = engine.adjacentScrollZones(for: .topRightCorner)
        #expect(topRight.horizontal == nil)       // 水平長條在下方
        #expect(topRight.vertical == .rightEdge)

        #expect(engine.adjacentScrollZones(for: .center).horizontal == nil)
    }

    @Test("CornerActions 以區域當索引")
    func cornerActionsSubscript() {
        var actions = CornerActions()
        actions[.topRightCorner] = .launchpad
        actions[.center] = .rightClick     // 非角落：忽略
        #expect(actions.topRight == .launchpad)
        #expect(actions[.center] == .none)
        #expect(actions == CornerActions(topRight: .launchpad))
    }
}

@MainActor
@Suite("位移換算成捲動")
struct ScrollOutputTests {
    @Test("加速曲線保留正負號")
    func accelerationCurvesPreserveSign() {
        for curve in AccelerationCurveType.allCases {
            let (engine, _) = makeEngine { $0.accelerationCurveType = curve }
            let positive = engine.applyAccelerationCurve(CGPoint(x: 0.2, y: 0.3))
            let negative = engine.applyAccelerationCurve(CGPoint(x: -0.2, y: -0.3))
            #expect(positive.x > 0 && positive.y > 0, "\(curve)")
            #expect(negative.x == -positive.x && negative.y == -positive.y, "\(curve)")
        }
    }

    @Test("線性曲線不改變位移；二次、三次曲線壓小細微位移")
    func curveShapes() {
        let delta = CGPoint(x: 0.1, y: -0.1)
        let (linear, _) = makeEngine { $0.accelerationCurveType = .linear }
        let (quadratic, _) = makeEngine { $0.accelerationCurveType = .quadratic }
        let (cubic, _) = makeEngine { $0.accelerationCurveType = .cubic }
        let (ease, _) = makeEngine { $0.accelerationCurveType = .ease }

        #expect(linear.applyAccelerationCurve(delta) == delta)
        #expect(abs(quadratic.applyAccelerationCurve(delta).x - 0.01) < 1e-12)
        #expect(abs(cubic.applyAccelerationCurve(delta).x - 0.001) < 1e-12)
        // ease：位移夠大（|x| × 10 ≥ 1）時係數是 1。
        #expect(abs(ease.applyAccelerationCurve(delta).x - 0.1) < 1e-12)
        // 很小的位移係數趨近 0.5。
        #expect(abs(ease.applyAccelerationCurve(CGPoint(x: 0.0001, y: 0)).x - 0.00005) < 1e-7)
    }

    @Test("行位移 = 像素 ÷ 10，但只要有像素就至少 ±1", arguments: [
        (0, 0), (1, 1), (9, 1), (10, 1), (25, 2), (-1, -1), (-9, -1), (-37, -3),
    ])
    func lineDeltas(pixels: Int32, expected: Int32) {
        #expect(ScrollWheelDeltas.lineDelta(forPixels: pixels) == expected)
    }

    @Test("ScrollWheelDeltas 兩軸各自換算")
    func scrollWheelDeltas() {
        let deltas = ScrollWheelDeltas(pixelX: -42, pixelY: 3)
        #expect(deltas.lineX == -4)
        #expect(deltas.lineY == 1)
    }
}

@Suite("慣性模型")
struct InertiaModelTests {
    @Test("沒啟動時 tick 什麼都不做")
    func idleByDefault() {
        var model = InertiaModel()
        do { let value = model.tick(); #expect(value == .idle) }
        do { let value = model.stop(); #expect(value == false) }
    }

    @Test("每個 tick 速度乘上固定衰減，像素往零截斷，第一筆是 began")
    func decaysAndTruncates() {
        var model = InertiaModel()
        model.start(velocityX: 0, velocityY: -100)
        let decay = pow(0.998, 16.67)

        do { let value = model.tick(); #expect(value == .scroll(deltaX: 0, deltaY: Int32(-100 * decay), momentumPhase: 1)) }
        do { let value = model.tick(); #expect(value == .scroll(deltaX: 0, deltaY: Int32(-100 * decay * decay), momentumPhase: 2)) }
        #expect(abs(model.velocityY - (-100 * decay * decay)) < 1e-9)
    }

    @Test("兩軸都慢到門檻以下就結束，並要求補一筆結束事件")
    func finishesBelowMinimumVelocity() {
        var model = InertiaModel()
        model.start(velocityX: 30, velocityY: 0)

        var scrollCount = 0
        var finished: InertiaModel.Tick?
        for _ in 0..<1_000 {
            let tick = model.tick()
            if case .scroll = tick {
                scrollCount += 1
            } else {
                finished = tick
                break
            }
        }

        // 30 × 0.9672ⁿ < 2 → n = 82。
        #expect(scrollCount == 81)
        #expect(finished == .finished(emitTerminal: true))
        #expect(!model.isScrolling)
        do { let value = model.tick(); #expect(value == .idle) }
    }

    @Test("一開始就低於門檻：直接結束，不用補結束事件")
    func belowThresholdFromTheStart() {
        var model = InertiaModel()
        model.start(velocityX: 1, velocityY: 1.5)
        do { let value = model.tick(); #expect(value == .finished(emitTerminal: false)) }
    }

    @Test("中途喊停：送過事件才需要補結束事件")
    func stopReportsWhetherTerminalIsNeeded() {
        var model = InertiaModel()
        model.start(velocityX: 0, velocityY: 200)
        do { let value = model.stop(); #expect(value == false) }

        model.start(velocityX: 0, velocityY: 200)
        _ = model.tick()
        do { let value = model.stop(); #expect(value == true) }
        #expect(model.velocityY == 0)
    }

    @Test("非有限的速度不啟動；超大的速度夾在 Int32 範圍內")
    func rejectsNonFiniteAndClampsHugeVelocity() {
        var model = InertiaModel()
        do { let value = model.start(velocityX: .nan, velocityY: 0); #expect(value == false) }
        do { let value = model.start(velocityX: 0, velocityY: .infinity); #expect(value == false) }
        #expect(!model.isScrolling)

        do { let started = model.start(velocityX: 1e30, velocityY: -1e30); #expect(started) }
        do { let value = model.tick(); #expect(value == .scroll(deltaX: .max, deltaY: .min, momentumPhase: 1)) }
    }

    @Test("重新啟動會重新從 began 開始")
    func restartResetsPhase() {
        var model = InertiaModel()
        model.start(velocityX: 0, velocityY: 100)
        _ = model.tick()
        model.start(velocityX: 0, velocityY: 100)
        guard case let .scroll(_, _, phase) = model.tick() else {
            Issue.record("應該送出捲動")
            return
        }
        #expect(phase == 1)
    }
}

@Suite("手勢結果的文字格式")
struct GestureOutcomeTests {
    @Test("寫進日誌與軌跡檔的字串不能變")
    func descriptionsAreStable() {
        let cases: [(GestureOutcome, String)] = [
            (.none, "none"),
            (.pending, "pending"),
            (.stripPending, "strip-pending"),
            (.scroll(.rightEdge), "scroll:rightEdge"),
            (.scroll(.bottomEdge), "scroll:bottomEdge"),
            (.scrollRejected, "scroll-rejected"),
            (.scrollTimeout, "scroll-timeout"),
            (.scrollDemoted(.bottomEdge), "scroll-demoted:bottomEdge"),
            (.scrollRecoveryInvalid, "scroll-recovery-invalid"),
            (.stripRejected(.verticalMovement), "strip-rejected:verticalMovement"),
            (.stripUndecided, "strip-undecided"),
            (.tapInScrollZone, "tap-in-scroll-zone"),
            (.middleClick, "middle-click"),
            (.cornerAction(.rightClick), "corner-action:rightClick"),
            (.cancelled(.multiFinger), "multi-finger"),
            (.cancelled(.filterLight), "filter-light"),
            (.cancelled(.filterLarge), "filter-large"),
            (.cancelled(.nonFiniteTouch), "non-finite-touch"),
            (.cancelled(.stopped), "stopped"),
            (.cancelled(.cancelled), "cancelled"),
        ]
        for (outcome, text) in cases {
            #expect(outcome.description == text)
        }
    }

    @Test("只有真的在捲動才算 endedAsScroll；被打斷的三種取消算 wasInterrupted")
    func classification() {
        #expect(GestureOutcome.scroll(.leftEdge).endedAsScroll)
        #expect(!GestureOutcome.scrollDemoted(.bottomEdge).endedAsScroll)
        #expect(!GestureOutcome.scrollRejected.endedAsScroll)

        #expect(GestureOutcome.cancelled(.multiFinger).wasInterrupted)
        #expect(GestureOutcome.cancelled(.filterLarge).wasInterrupted)
        #expect(GestureOutcome.cancelled(.filterLight).wasInterrupted)
        #expect(!GestureOutcome.cancelled(.stopped).wasInterrupted)
        #expect(!GestureOutcome.pending.wasInterrupted)
    }

    @Test("區域名稱就是 case 名稱（日誌與軌跡檔用它）")
    func zoneNames() {
        #expect("\(ScrollZone.bottomRightCorner)" == "bottomRightCorner")
        #expect(String(describing: ScrollZone.middleClick) == "middleClick")
    }
}

@Suite("event tap 讀的旗標")
struct ScrollSuppressionStateTests {
    @Test("游標移動在捲動中或判斷中都要擋")
    func pointerSuppression() {
        let state = ScrollSuppressionState()
        #expect(!state.shouldSuppressPointerMovement)
        state.isEvaluatingCandidate = true
        #expect(state.shouldSuppressPointerMovement)
        state.isEvaluatingCandidate = false
        state.isActivelyScrolling = true
        #expect(state.shouldSuppressPointerMovement)
    }

    @Test("多執行緒同時讀寫不會壞")
    func concurrentAccess() async {
        let state = ScrollSuppressionState()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    for step in 0..<2_000 {
                        state.isActivelyScrolling = (index + step).isMultiple(of: 2)
                        _ = state.shouldSuppressPointerMovement
                    }
                }
            }
        }
        state.isActivelyScrolling = false
        #expect(!state.isActivelyScrolling)
    }
}
