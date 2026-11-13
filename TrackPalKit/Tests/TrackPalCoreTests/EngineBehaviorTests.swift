import Testing
@testable import TrackPalCore

/// 整條手勢流程的行為測試：輸入是觸控幀，檢查的是狀態機實際對外做的事。
/// 每一條都是「使用者做了什麼 → 應該發生什麼」，讀起來就是規格。
@MainActor
@Suite("狀態機行為")
struct EngineBehaviorTests {

    // MARK: - 垂直邊緣

    @Test("右側邊緣往上滑：內容往上捲（自然捲動方向），放開前游標被凍住")
    func rightEdgeSlideUpScrolls() {
        var script = ContactScript()
        script.down(0.95, 0.5)
        script.move(dx: 0, dy: 0.006, frames: 20)
        script.lift()
        let result = script.run()

        #expect(result.outcomes == ["scroll:rightEdge"])
        #expect(!result.scrolls.isEmpty)
        // 手指往上（+y）→ 捲動的 deltaY 是負的。
        #expect(result.scrolls.allSatisfy { $0.deltaY < 0 && $0.deltaX == 0 })
        // 落指時進入判斷（游標凍住），啟動後變成捲動中，放開後兩者都清掉。
        #expect(result.flags == ["0 1", "1 0", "0 0"])
    }

    @Test("右側邊緣往下滑：deltaY 是正的")
    func rightEdgeSlideDownScrollsPositive() {
        var script = ContactScript()
        script.down(0.95, 0.6)
        script.move(dx: 0, dy: -0.006, frames: 20)
        script.lift()
        let result = script.run()

        #expect(result.outcomes == ["scroll:rightEdge"])
        #expect(result.totalScrollY > 0)
    }

    @Test("捲動量照原生的增益：0.5 個觸控板高／秒滑過 0.2，約 112 px；靈敏度 3 就是三倍")
    func scrollDistanceMatchesNativeGain() {
        var script = ContactScript()
        script.down(0.95, 0.3)
        script.move(dx: 0, dy: 0.004, frames: 50)   // 共 0.2，速度 0.5/秒
        script.hold(frames: 8)                      // 停住再放開，不帶慣性
        script.lift()

        let atOne = script.run { $0.scrollMultiplier = 1 }
        let atThree = script.run { $0.scrollMultiplier = 3 }

        // 0.2 × (500 + 119 × 0.5) = 111.9。啟動那幾幀用的是預設速度，容許幾個像素。
        #expect((-116 ... -108).contains(atOne.totalScrollY))
        #expect((-348 ... -324).contains(atThree.totalScrollY))
        #expect(atOne.count(prefix: "inertia-start") == 0)
    }

    @Test("滑得快，每單位位移捲動得略多（原生的加速很溫和）")
    func fasterStrokesScrollSlightlyMore() {
        func distance(perFrame: Double, frames: Int) -> Int {
            var script = ContactScript()
            script.down(0.95, 0.2)
            script.move(dx: 0, dy: perFrame, frames: frames)
            script.hold(frames: 8)
            script.lift()
            return abs(script.run { $0.scrollMultiplier = 1 }.totalScrollY)
        }
        let slow = distance(perFrame: 0.002, frames: 150)    // 0.25/秒，共 0.3
        let fast = distance(perFrame: 0.012, frames: 25)     // 1.5/秒，共 0.3
        #expect(fast > slow)
        #expect(Double(fast) / Double(slow) < 1.45)
    }

    @Test("慢慢滑也是逐像素：每一幀送出的位移很小，不會攢成一大格")
    func slowScrollIsPixelPrecise() {
        var script = ContactScript()
        script.down(0.95, 0.3)
        script.move(dx: 0, dy: 0.002, frames: 60)   // 每幀約 1 px
        script.lift()
        let result = script.run { $0.scrollMultiplier = 1 }

        // 啟動那一刻會補送判斷期間緩衝的位移，之後每幀只有 0–2 px。
        let steady = result.scrolls.dropFirst(3).map { abs($0.deltaY) }
        #expect(steady.count > 30)
        #expect(steady.allSatisfy { (1...2).contains($0) })
    }

    @Test("放開時手指還在動就有慣性，起始速度照原生的曲線；放開得慢就沒有")
    func inertiaFollowsNativeCurve() throws {
        func inertiaStart(perFrame: Double) -> Double? {
            var script = ContactScript()
            script.down(0.95, 0.2)
            script.move(dx: 0, dy: perFrame, frames: 40)
            script.lift()
            let line = script.run { $0.scrollMultiplier = 1 }.lines(prefix: "inertia-start").first
            return line.flatMap { Double($0.split(separator: " ")[2]) }
        }

        // 0.75/秒：0.75 × (650 + 375) = 769 px/s（實測 0.7–0.9 的中位數 780）。往上滑 → 負值。
        let moderate = try #require(inertiaStart(perFrame: 0.006))
        #expect((-800 ... -740).contains(moderate))
        // 以前要 1.0/秒以上才有慣性。
        let gentle = try #require(inertiaStart(perFrame: 0.0035))     // 0.44/秒
        #expect((-420 ... -340).contains(gentle))
        // 0.25/秒：低於原生的門檻。
        #expect(inertiaStart(perFrame: 0.002) == nil)
    }

    @Test("水平方向用同樣的實體尺度：同樣的手指距離與速度，像素與慣性都是垂直的 1.6 倍左右")
    func horizontalUsesPhysicalUnits() throws {
        var script = ContactScript()
        script.down(0.3, 0.05)
        script.move(dx: 0.004, dy: 0, frames: 60)    // 0.5 觸控板寬／秒 = 0.8 高／秒
        script.lift()
        let result = script.run { $0.scrollMultiplier = 1 }

        #expect(result.outcomes == ["scroll:bottomEdge"])
        let line = try #require(result.lines(prefix: "inertia-start").first)
        let velocityX = try #require(Double(line.split(separator: " ")[1]))
        // 0.8 × (650 + 400) = 840 px/s，往右滑 → 正值。
        #expect((800 ... 880).contains(velocityX))
    }

    @Test("靈敏度同時放大接觸中的捲動與慣性")
    func sensitivityScalesInertia() throws {
        var script = ContactScript()
        script.down(0.95, 0.2)
        script.move(dx: 0, dy: 0.006, frames: 40)
        script.lift()
        func start(_ multiplier: Double) throws -> Double {
            let line = try #require(script.run { $0.scrollMultiplier = multiplier }
                .lines(prefix: "inertia-start").first)
            return try #require(Double(line.split(separator: " ")[2]))
        }
        let one = try start(1)
        let two = try start(2)
        #expect(abs(two / one - 2) < 0.01)
    }

    @Test("在邊緣區輕點：不捲動，也不留下凍住的游標")
    func tapInEdgeDoesNotScroll() {
        var script = ContactScript()
        script.down(0.95, 0.5)
        script.hold(frames: 5)
        script.lift()
        let result = script.run()

        #expect(result.outcomes == ["tap-in-scroll-zone"])
        #expect(result.scrolls.isEmpty)
        #expect(result.flags.last == "0 0")
    }

    @Test("從右側邊緣橫著滑進中央：判成游標移動，整段不捲")
    func rightEdgeHorizontalMoveIsRejected() {
        var script = ContactScript()
        script.down(0.95, 0.5)
        script.move(dx: -0.01, dy: 0, frames: 20)
        script.lift()
        let result = script.run()

        #expect(result.outcomes == ["scroll-rejected"])
        #expect(result.scrolls.isEmpty)
        #expect(result.contains("Scroll rejected → center (cursor movement)"))
    }

    @Test("垂直邊緣只設右側時，左側邊緣是一般區域")
    func leftEdgeInactiveWhenRightOnly() {
        var script = ContactScript()
        script.down(0.05, 0.5)
        script.move(dx: 0, dy: 0.006, frames: 20)
        script.lift()

        #expect(script.run().scrolls.isEmpty)
        #expect(script.run { $0.verticalEdgeMode = "both" }.outcomes == ["scroll:leftEdge"])
    }

    // MARK: - 水平長條（游標優先）

    @Test("下方長條橫滑：啟動前游標不凍結，啟動時游標放回落指位置，之後才開始捲")
    func bottomStripSlideActivatesAndWarps() {
        var script = ContactScript(pointer: (321, 654))
        script.down(0.4, 0.05)
        script.move(dx: 0.004, dy: 0, frames: 40)
        script.lift()
        let result = script.run()

        #expect(result.outcomes == ["scroll:bottomEdge"])
        #expect(result.lines(prefix: "warp ") == ["warp 321 654"])
        #expect(result.scrolls.allSatisfy { $0.deltaX > 0 && $0.deltaY == 0 })
        // 判斷期間旗標沒有變過（游標照常移動），啟動後才是捲動中。
        #expect(result.flags == ["0 0", "1 0", "0 0"])
        // 第一筆捲動出現在游標放回去之後。
        let warpIndex = result.lines.firstIndex { $0.hasPrefix("warp ") }
        let scrollIndex = result.lines.firstIndex { $0.hasPrefix("scroll ") }
        #expect(warpIndex != nil && scrollIndex != nil && warpIndex! < scrollIndex!)
    }

    @Test("下方長條往左滑：deltaX 是負的")
    func bottomStripSlideLeft() {
        var script = ContactScript()
        script.down(0.6, 0.05)
        script.move(dx: -0.004, dy: 0, frames: 40)
        script.lift()
        #expect(script.run().totalScrollX < 0)
    }

    @Test("從下方長條往內側走：交給游標，整段不捲、游標從頭到尾沒被凍住")
    func bottomStripInwardMoveIsPointer() {
        var script = ContactScript()
        script.down(0.5, 0.05)
        script.move(dx: 0.001, dy: 0.008, frames: 30)
        script.lift()
        let result = script.run()

        #expect(result.outcomes.count == 1)
        #expect(result.outcomes[0].hasPrefix("strip-rejected:"))
        #expect(result.scrolls.isEmpty)
        #expect(result.flags == ["0 0"])
        #expect(result.count(prefix: "warp ") == 0)
    }

    @Test("水平捲動啟動後手指往上離開長條：取消捲動，交回游標")
    func activatedStripDemotesWhenLeaving() {
        var script = ContactScript()
        script.down(0.3, 0.05)
        script.move(dx: 0.004, dy: 0, frames: 40)
        script.move(dx: 0, dy: 0.02, frames: 20)
        script.lift()
        let result = script.run()

        #expect(result.outcomes == ["scroll-demoted:bottomEdge"])
        #expect(result.contains("Scroll demoted → center"))
        #expect(result.flags.last == "0 0")
    }

    @Test("水平位置設成上方時，長條在觸控板上緣")
    func topStripWhenConfigured() {
        var script = ContactScript()
        script.down(0.4, 0.96)
        script.move(dx: 0.004, dy: 0, frames: 40)
        script.lift()

        #expect(script.run { $0.horizontalPosition = "top"; $0.middleClickEnabled = false }
            .outcomes == ["scroll:topEdge"])
        #expect(script.run { $0.middleClickEnabled = false }.scrolls.isEmpty)
    }

    // MARK: - 慣性

    @Test("快速滑完放開：啟動慣性；下一次在捲動區落指會先停掉慣性")
    func flickStartsInertiaAndNextTouchStopsIt() {
        var script = ContactScript()
        script.down(0.95, 0.3)
        script.move(dx: 0, dy: 0.01, frames: 20)
        script.lift()
        script.wait(0.1)
        script.down(0.95, 0.5)
        script.hold(frames: 3)
        script.lift()
        let result = script.run()

        let start = result.lines(prefix: "inertia-start")
        #expect(start.count == 1)
        // 垂直捲動的慣性只有 Y 方向，方向跟捲動一致（往上滑 → 負）。
        let parts = start[0].split(separator: " ")
        #expect(Double(parts[1]) == 0)
        #expect((Double(parts[2]) ?? 0) < 0)
        #expect(result.count(prefix: "inertia-stop") >= 1)
    }

    @Test("慢慢滑到停再放開：不啟動慣性")
    func slowReleaseHasNoInertia() {
        var script = ContactScript()
        script.down(0.95, 0.3)
        script.move(dx: 0, dy: 0.004, frames: 20)
        script.hold(frames: 12)
        script.lift()

        #expect(script.run().count(prefix: "inertia-start") == 0)
    }

    // MARK: - 壓力動作與原生點擊

    private func cornerSettings(_ settings: inout EngineScenario.Settings) {
        settings.cornerTriggerEnabled = true
        settings.cornerActionBottomRight = "rightClick"
        settings.cornerActionTopLeft = "showDesktop"
    }

    @Test("右下角用力按：送出右鍵，被攔下來的原生左鍵不補送")
    func cornerForcePressTriggersAction() {
        var script = ContactScript()
        script.down(0.97, 0.03)
        script.hold(frames: 4)
        script.force(150)
        script.hold(frames: 4)
        script.lift()
        let result = script.run(configure: cornerSettings)

        #expect(result.lines(prefix: "corner-action") == ["corner-action rightClick"])
        #expect(result.outcomes == ["corner-action:rightClick"])
        #expect(result.lines(prefix: "click-begin").count == 1)
        #expect(result.lines(prefix: "click-finish").first?.contains(" 0 ") == true)
    }

    @Test("在角落輕點（沒用力）：不觸發動作，原生左鍵照常補送")
    func cornerTapWithoutForceReplaysNativeClick() {
        var script = ContactScript()
        script.down(0.97, 0.03)
        script.hold(frames: 5)
        script.lift()
        let result = script.run(configure: cornerSettings)

        #expect(result.count(prefix: "corner-action") == 0)
        #expect(result.lines(prefix: "click-finish").first?.contains(" 1 ") == true)
    }

    @Test("壓力不到門檻：不觸發")
    func weakForceDoesNotTrigger() {
        var script = ContactScript()
        script.down(0.97, 0.03)
        script.hold(frames: 4)
        script.force(60)
        script.hold(frames: 4)
        script.lift()

        #expect(script.run(configure: cornerSettings).count(prefix: "corner-action") == 0)
    }

    @Test("從角落滑出去再用力：移動太多，不算壓力動作")
    func forceAfterMovementIsRejected() {
        var script = ContactScript()
        script.down(0.97, 0.03)
        script.move(dx: -0.01, dy: 0.01, frames: 10)
        script.force(200)
        script.hold(frames: 3)
        script.lift()

        #expect(script.run(configure: cornerSettings).count(prefix: "corner-action") == 0)
    }

    @Test("沒指定動作的角落不是死區：照樣可以當邊緣捲動")
    func unassignedCornerStillScrolls() {
        var script = ContactScript()
        script.down(0.97, 0.03)
        script.move(dx: 0, dy: 0.006, frames: 25)
        script.lift()
        let result = script.run {
            $0.cornerTriggerEnabled = true
            $0.cornerActionBottomRight = "none"
        }

        #expect(result.outcomes == ["scroll:rightEdge"])
        #expect(result.totalScrollY < 0)
    }

    @Test("中鍵區用力按：送出中鍵")
    func middleClickForcePress() {
        var script = ContactScript()
        script.down(0.5, 0.95)
        script.hold(frames: 4)
        script.force(120)
        script.hold(frames: 3)
        script.lift()
        let result = script.run()

        #expect(result.count(prefix: "middle-click") == 1)
        #expect(result.outcomes == ["middle-click"])
    }

    @Test("中鍵關閉時，同一個位置不攔原生點擊")
    func middleClickDisabledDoesNotCapture() {
        var script = ContactScript()
        script.down(0.5, 0.95)
        script.hold(frames: 4)
        script.force(120)
        script.lift()
        let result = script.run { $0.middleClickEnabled = false }

        #expect(result.count(prefix: "middle-click") == 0)
        #expect(result.count(prefix: "click-begin") == 0)
    }

    // MARK: - 多指、過濾、重啟

    @Test("捲到一半放下第二根手指：立刻取消，剩下的那根手指在全部放開前不算數")
    func secondFingerCancelsScroll() {
        var script = ContactScript()
        script.down(0.95, 0.3)
        script.move(dx: 0, dy: 0.006, frames: 15)
        script.multiFinger(frames: 3)
        let scrollCountBefore = script.run().scrolls.count
        script.move(dx: 0, dy: 0.006, frames: 15)
        script.lift()
        let result = script.run()

        #expect(result.outcomes == ["multi-finger"])
        #expect(result.scrolls.count == scrollCountBefore)
        #expect(result.contains("Multi→Single transition ignored until all fingers lift"))
        #expect(result.flags.last == "0 0")
    }

    @Test("連續三幀手掌大小的接觸：取消並隔離到全部放開")
    func palmFramesCancelAndQuarantine() {
        var script = ContactScript()
        script.down(0.95, 0.3)
        script.move(dx: 0, dy: 0.006, frames: 10)
        script.palmFrames(3)
        script.move(dx: 0, dy: 0.006, frames: 10)
        script.lift()
        let result = script.run()

        #expect(result.outcomes == ["filter-large"])
        #expect(result.contains("Touch cancelled after 3 consecutive invalid frames"))
    }

    @Test("關掉大面積過濾後，同樣的輸入照常捲動")
    func palmFilterCanBeDisabled() {
        var script = ContactScript()
        script.down(0.95, 0.3)
        script.move(dx: 0, dy: 0.006, frames: 10)
        script.palmFrames(3)
        script.move(dx: 0, dy: 0.006, frames: 10)
        script.lift()

        #expect(script.run { $0.filterLargeTouches = false }.outcomes == ["scroll:rightEdge"])
    }

    @Test("落指前幾幀太輕（手指還沒放穩）：等到有效幀才開始，不會整輪失效")
    func lightSettlingFramesDoNotQuarantine() {
        var settled = ContactScript()
        settled.down(0.95, 0.3)
        settled.move(dx: 0, dy: 0.006, frames: 20)
        settled.lift()

        var light = ContactScript()
        light.lightFrames(4)
        light.down(0.95, 0.3, state: 3)
        light.move(dx: 0, dy: 0.006, frames: 20)
        light.lift()

        #expect(settled.run().outcomes == ["scroll:rightEdge"])
        #expect(light.run().count(prefix: "log Contact quarantined") == 0)
    }

    @Test("手勢進行中停用再啟用：取消手勢，下一次接觸正常")
    func restartCancelsActiveGesture() {
        var script = ContactScript()
        script.down(0.95, 0.3)
        script.move(dx: 0, dy: 0.006, frames: 15)
        script.restart()
        script.lift()
        script.wait(0.2)
        script.down(0.95, 0.3)
        script.move(dx: 0, dy: 0.006, frames: 20)
        script.lift()
        let result = script.run()

        #expect(result.outcomes == ["stopped", "scroll:rightEdge"])
    }

    @Test("懸停幀（state 1）不算接觸")
    func hoverFramesAreIgnored() {
        var script = ContactScript()
        script.down(0.95, 0.3)
        script.hover()
        var reference = ContactScript()
        reference.down(0.95, 0.3)

        #expect(script.run().lines == reference.run().lines)
    }

    @Test("另一台裝置的觸控不會打斷目前的手勢")
    func otherDeviceCannotStealGesture() {
        var script = ContactScript()
        script.down(0.95, 0.3)
        script.move(dx: 0, dy: 0.006, frames: 10)
        script.device = 1
        script.down(0.5, 0.5)
        script.lift()
        script.device = 0
        script.move(dx: 0, dy: 0.006, frames: 10)
        script.lift()
        let result = script.run(deviceCount: 2)

        #expect(result.outcomes == ["scroll:rightEdge"])
    }

    @Test("座標出現非有限值：丟掉這次接觸，不當掉")
    func nonFiniteFrameIsQuarantined() {
        var scenario = EngineScenario(name: "nan")
        scenario.events = [
            .touch(.init(timestamp: 100, uptime: 1_100, count: 1, x: 0.95, y: 0.3, state: 2, density: 0.2, majorAxis: 8, minorAxis: 6)),
            .touch(.init(timestamp: 100.008, uptime: 1_100.008, count: 1, x: .nan, y: 0.3, state: 4, density: 0.2, majorAxis: 8, minorAxis: 6)),
            .touch(.init(timestamp: 100.016, uptime: 1_100.016, count: 0)),
        ]
        let result = Transcript(lines: EngineScenarioRunner.run(scenario))

        #expect(result.outcomes == ["non-finite-touch"])
    }

    // MARK: - 加速曲線

    @Test("加速曲線只改變位移到像素的換算，不影響方向", arguments: ["linear", "quadratic", "cubic", "ease"])
    func accelerationCurvesKeepDirection(curve: String) {
        var script = ContactScript()
        script.down(0.95, 0.3)
        script.move(dx: 0, dy: 0.01, frames: 30)
        script.lift()
        let result = script.run {
            $0.accelerationCurveType = curve
            $0.scrollMultiplier = 10
        }

        #expect(result.outcomes == ["scroll:rightEdge"])
        #expect(result.totalScrollY < 0)
    }
}
