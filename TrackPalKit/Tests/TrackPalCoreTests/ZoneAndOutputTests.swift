import CoreGraphics
import Foundation
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
}

@Suite("行位移的累加")
struct LineDeltaAccumulatorTests {
    @Test("每 8 個像素算一行，零頭留到下一筆")
    func carriesRemainder() {
        var accumulator = LineDeltaAccumulator()
        var lines: [Int32] = []
        for pixels: Int32 in [3, 3, 3, 3, 3, 1] {      // 共 16 px
            lines.append(accumulator.lines(forPixels: pixels))
        }
        #expect(lines == [0, 0, 1, 0, 0, 1])
    }

    @Test("不管事件切多細，行數總和只跟像素總和有關")
    func totalIsIndependentOfChunking() {
        var fine = LineDeltaAccumulator()
        var coarse = LineDeltaAccumulator()
        var fineTotal: Int32 = 0
        for _ in 0..<400 { fineTotal += fine.lines(forPixels: 1) }
        let coarseTotal = coarse.lines(forPixels: 400)
        #expect(fineTotal == 50)
        #expect(coarseTotal == 50)
    }

    @Test("反方向的位移會抵銷零頭；負向同樣每 8 px 一行")
    func handlesDirectionChanges() {
        var accumulator = LineDeltaAccumulator()
        let forward = accumulator.lines(forPixels: 7)
        let back = accumulator.lines(forPixels: -7)
        let negative = accumulator.lines(forPixels: -8)
        let more = accumulator.lines(forPixels: -20)
        #expect(forward == 0)
        #expect(back == 0)
        #expect(negative == -1)
        #expect(more == -2)        // 零頭 -4 留著
        let rest = accumulator.lines(forPixels: -4)
        #expect(rest == -1)
    }

    @Test("零位移不產生行位移；reset 清掉零頭")
    func zeroAndReset() {
        var accumulator = LineDeltaAccumulator()
        _ = accumulator.lines(forPixels: 7)
        let zero = accumulator.lines(forPixels: 0)
        #expect(zero == 0)
        accumulator.reset()
        let afterReset = accumulator.lines(forPixels: 7)
        #expect(afterReset == 0)
    }
}

@Suite("原生手感的曲線")
struct NativeScrollCurveTests {
    @Test("接觸增益落在實測的範圍，而且隨速度緩慢增加", arguments: [
        (0.42, 550.0), (0.62, 597.0), (0.87, 616.0), (1.25, 649.0),
    ])
    func contactGainMatchesMeasurements(speed: Double, measured: Double) {
        let gain = Double(NativeScrollCurve.contactGain(atSpeed: CGFloat(speed)))
        // 跟各速度區間實測的中位數差不到 5%。
        #expect(abs(gain - measured) / measured < 0.05)
    }

    @Test("增益只看速度大小；極端值夾在範圍內，不會爆掉")
    func contactGainIsBounded() {
        #expect(NativeScrollCurve.contactGain(atSpeed: -0.8) == NativeScrollCurve.contactGain(atSpeed: 0.8))
        #expect(NativeScrollCurve.contactGain(atSpeed: 0) == 500)
        #expect(NativeScrollCurve.contactGain(atSpeed: 100) == NativeScrollCurve.contactGain(atSpeed: 4))
        #expect(NativeScrollCurve.contactGain(atSpeed: .nan).isFinite)
        #expect(NativeScrollCurve.contactGain(atSpeed: 4) < 1_000)
        // 速度增加一倍，增益只多一成左右：原生的加速很溫和。
        #expect(NativeScrollCurve.contactGain(atSpeed: 1.0) / NativeScrollCurve.contactGain(atSpeed: 0.5) < 1.15)
    }

    @Test("放開得太慢沒有慣性；門檻以上的起始速度符合實測", arguments: [
        (0.2, 0.0, 0.0), (0.34, 0.0, 0.0),
        (0.45, 360.0, 480.0),      // 實測 0.40–0.50：360–600 px/s
        (0.85, 720.0, 960.0),      // 實測 0.81–0.88：720–960
        (1.05, 1_000.0, 1_700.0),  // 實測 960–2280（只有 3 筆）
        (9.0, 20_000.0, 23_000.0), // 極端值夾在 6.0
    ])
    func momentumSpeed(liftSpeed: Double, low: Double, high: Double) {
        let speed = Double(NativeScrollCurve.momentumSpeed(atLiftSpeed: CGFloat(liftSpeed)))
        #expect(speed >= low && speed <= high)
        #expect(Double(NativeScrollCurve.momentumSpeed(atLiftSpeed: CGFloat(-liftSpeed))) == speed)
    }

    @Test("照模型滑完的總距離接近原生（原生：峰值速度的 0.24 秒左右）", arguments: [
        (840.0, 184.0, 209.0), (1680.0, 396.0, 440.0), (2280.0, 544.0, 600.0),
    ])
    func momentumDistanceMatchesNative(peak: Double, low: Double, high: Double) {
        var model = InertiaModel()
        model.start(velocityX: 0, velocityY: CGFloat(peak))
        var total = 0
        for _ in 0..<2_000 {
            let tick = model.tick(elapsed: 1.0 / 120.0)
            if case let .scroll(_, deltaY, _) = tick { total += Int(deltaY) }
            if case .finished = tick { break }
        }
        #expect(Double(total) >= low * 0.95 && Double(total) <= high * 1.05)
    }
}

@Suite("慣性模型")
struct InertiaModelTests {
    private static let frame = 1.0 / 120.0

    /// 跑到結束，回傳每一格送出的像素（垂直）、格數與結束時的狀態。
    private func run(
        _ model: inout InertiaModel, elapsed: Double = InertiaModelTests.frame
    ) -> (pixels: [Int32], ticks: Int, last: InertiaModel.Tick) {
        var pixels: [Int32] = []
        var ticks = 0
        while true {
            let tick = model.tick(elapsed: elapsed)
            ticks += 1
            switch tick {
            case let .scroll(_, deltaY, _): pixels.append(deltaY)
            case .coasting: pixels.append(0)
            case .idle, .finished: return (pixels, ticks, tick)
            }
            if ticks > 100_000 { return (pixels, ticks, tick) }
        }
    }

    @Test("沒啟動時 tick 什麼都不做")
    func idleByDefault() {
        var model = InertiaModel()
        let tick = model.tick(elapsed: Self.frame)
        let stopped = model.stop()
        #expect(tick == .idle)
        #expect(stopped == false)
    }

    @Test("速度依時間指數衰減，每一格送出這段時間走過的像素，第一筆是 began")
    func decaysOverTime() {
        var model = InertiaModel()
        model.start(velocityX: 0, velocityY: -1_200)

        let first = model.tick(elapsed: Self.frame)
        let second = model.tick(elapsed: Self.frame)
        let decay = exp(-Self.frame / 0.27)
        // 1200 × decay ÷ 120 = 9.70 → -9，零頭 -0.70；下一格 9.40 + 0.70 = 10.1 → -10。
        #expect(first == .scroll(deltaX: 0, deltaY: -9, momentumPhase: 1))
        #expect(second == .scroll(deltaX: 0, deltaY: -10, momentumPhase: 2))
        #expect(abs(Double(model.velocityY) - (-1_200 * decay * decay)) < 1e-6)
    }

    @Test("滑行的總距離 ≈ 時間常數 ×（起始速度 − 停止速度），零頭不會丟掉")
    func totalDistance() {
        var model = InertiaModel()
        model.start(velocityX: 0, velocityY: 840)
        let result = run(&model)

        let total = result.pixels.reduce(0) { $0 + Int($1) }
        #expect(abs(Double(total) - 0.27 * (840 - 120)) < 6)
        #expect(result.last == .finished(emitTerminal: true))
        #expect(!model.isScrolling)
    }

    @Test("螢幕更新率不影響滑行的距離與時間")
    func independentOfTickRate() {
        var at120 = InertiaModel()
        var at60 = InertiaModel()
        at120.start(velocityX: 1_500, velocityY: 0)
        at60.start(velocityX: 1_500, velocityY: 0)

        var distance120 = 0, distance60 = 0, time120 = 0.0, time60 = 0.0
        while case let tick = at120.tick(elapsed: 1.0 / 120.0), tick != .idle {
            if case let .scroll(deltaX, _, _) = tick { distance120 += Int(deltaX) }
            if case .finished = tick { break }
            time120 += 1.0 / 120.0
        }
        while case let tick = at60.tick(elapsed: 1.0 / 60.0), tick != .idle {
            if case let .scroll(deltaX, _, _) = tick { distance60 += Int(deltaX) }
            if case .finished = tick { break }
            time60 += 1.0 / 60.0
        }

        #expect(abs(distance120 - distance60) <= 8)
        #expect(abs(time120 - time60) < 0.03)
    }

    @Test("越滑越慢：每一格送出的像素不會比前一格多超過 1")
    func deceleratesSmoothly() {
        var model = InertiaModel()
        model.start(velocityX: 0, velocityY: 900)
        let pixels = run(&model).pixels

        #expect(pixels.first == 7)                  // 900 × decay ÷ 120
        #expect((pixels.last ?? 99) <= 2)
        for (previous, next) in zip(pixels, pixels.dropFirst()) {
            #expect(next <= previous + 1)
        }
    }

    @Test("一開始就低於停止速度：直接結束，不用補結束事件")
    func belowStopSpeedFromTheStart() {
        var model = InertiaModel()
        model.start(velocityX: 50, velocityY: 100)
        let tick = model.tick(elapsed: Self.frame)
        #expect(tick == .finished(emitTerminal: false))
    }

    @Test("這一格攢不到一個像素時不送事件；時間長度不合理時不前進")
    func coastsWithoutEmitting() {
        var model = InertiaModel()
        model.stopSpeed = 10
        model.start(velocityX: 0, velocityY: 60)     // 每格 0.5 px
        let first = model.tick(elapsed: Self.frame)
        let second = model.tick(elapsed: Self.frame)
        let invalid = model.tick(elapsed: 0)
        let negative = model.tick(elapsed: -1)
        #expect(first == .coasting)
        #expect(second == .coasting || second == .scroll(deltaX: 0, deltaY: 1, momentumPhase: 1))
        #expect(invalid == .coasting)
        #expect(negative == .coasting)
    }

    @Test("中途喊停：送過事件才需要補結束事件")
    func stopReportsWhetherTerminalIsNeeded() {
        var model = InertiaModel()
        model.start(velocityX: 0, velocityY: 2_000)
        let beforeAnyTick = model.stop()
        #expect(beforeAnyTick == false)

        model.start(velocityX: 0, velocityY: 2_000)
        _ = model.tick(elapsed: Self.frame)
        let afterTick = model.stop()
        #expect(afterTick == true)
        #expect(model.velocityY == 0)
    }

    @Test("非有限的速度不啟動；超大的速度夾在 Int32 範圍內")
    func rejectsNonFiniteAndClampsHugeVelocity() {
        var model = InertiaModel()
        let nan = model.start(velocityX: .nan, velocityY: 0)
        let infinite = model.start(velocityX: 0, velocityY: .infinity)
        #expect(nan == false)
        #expect(infinite == false)
        #expect(!model.isScrolling)

        let started = model.start(velocityX: 1e30, velocityY: -1e30)
        #expect(started)
        let tick = model.tick(elapsed: Self.frame)
        #expect(tick == .scroll(deltaX: .max, deltaY: .min, momentumPhase: 1))
    }

    @Test("重新啟動會重新從 began 開始，零頭也歸零")
    func restartResetsPhase() {
        var model = InertiaModel()
        model.start(velocityX: 0, velocityY: 1_200)
        _ = model.tick(elapsed: Self.frame)
        model.start(velocityX: 0, velocityY: 1_200)
        let tick = model.tick(elapsed: Self.frame)
        #expect(tick == .scroll(deltaX: 0, deltaY: 9, momentumPhase: 1))
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
