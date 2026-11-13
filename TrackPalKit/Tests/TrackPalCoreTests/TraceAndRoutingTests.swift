import CoreGraphics
import Foundation
import Testing
@testable import TrackPalCore

private func summary(
    zone: String = "bottomEdge",
    outcome: String = "scroll:bottomEdge",
    pointerGap: Double? = 0.4,
    force: Float = 0
) -> GestureTraceSummary {
    GestureTraceSummary(
        sessionID: 42,
        initialZone: zone,
        finalZone: zone,
        outcome: outcome,
        duration: 0.321,
        pointerActivityGap: pointerGap,
        horizontalScrollGap: nil,
        stripDepth: 0.1647,
        edgeWidth: 0.1302,
        cornerSize: 0.0684,
        scrollPixelsX: -12,
        scrollPixelsY: 3,
        maximumForce: force
    )
}

/// 一段貼著下緣往右滑的軌跡。
private func slideTrace(
    zone: String = "bottomEdge",
    y: Float = 0.05,
    pointerGap: Double? = nil,
    force: Float = 0
) throws -> GestureTrace {
    var builder = GestureTraceLineBuilder()
    builder.begin(timestamp: 50)
    for index in 0..<40 {
        builder.append(
            timestamp: 50 + Double(index) * 0.008,
            x: 0.3 + Float(index) * 0.004, y: y, state: index == 0 ? 2 : 4,
            density: 0.2, majorAxis: 8, minorAxis: 6.5, isValid: true
        )
    }
    let finished = builder.finish(
        summary(zone: zone, pointerGap: pointerGap, force: force),
        date: "2026-11-13T09:00:00.000+08:00"
    )
    let line = try #require(finished)
    return try JSONDecoder().decode(GestureTrace.self, from: Data(line.utf8))
}

@Suite("軌跡檔格式")
struct GestureTraceFormatTests {
    @Test("寫出去的一行可以原樣讀回來")
    func lineRoundTrips() throws {
        var builder = GestureTraceLineBuilder()
        builder.begin(timestamp: 10)
        builder.append(timestamp: 10, x: 0.4783, y: 0, state: 2, density: 0.188, majorAxis: 8.51, minorAxis: 5.5, isValid: true)
        builder.append(timestamp: 10.008, x: 0.5, y: 0.0123, state: 4, density: 0.2, majorAxis: 9, minorAxis: 6, isValid: false)
        let finished = builder.finish(summary(), date: "2026-11-13T08:56:23.393+08:00")
        let line = try #require(finished)

        #expect(line.hasSuffix("\n"))
        #expect(!line.dropLast().contains("\n"))
        let trace = try JSONDecoder().decode(GestureTrace.self, from: Data(line.utf8))

        #expect(trace.id == 42)
        #expect(trace.date == "2026-11-13T08:56:23.393+08:00")
        #expect(trace.zone == "bottomEdge")
        #expect(trace.outcome == "scroll:bottomEdge")
        #expect(trace.dur == 0.321)
        #expect(trace.pointerGap == 0.4)
        #expect(trace.scrollGap == nil)
        #expect(trace.pixels == [-12, 3])
        #expect(trace.frames == [[0, 4783, 0, 2, 188, 851, 550, 1], [80, 5000, 123, 4, 200, 900, 600, 0]])

        let frames = trace.decodedFrames
        #expect(frames.count == 2)
        #expect(abs(frames[1].elapsed - 0.008) < 1e-9)
        #expect(abs(frames[0].x - 0.4783) < 1e-6)
        #expect(frames[0].wasValid && !frames[1].wasValid)
    }

    @Test("中央區起步、沒有幀、或沒有 begin：不輸出")
    func skipsUninterestingContacts() {
        var builder = GestureTraceLineBuilder()
        let withoutBegin = builder.finish(summary(), date: "d")
        #expect(withoutBegin == nil)

        builder.begin(timestamp: 1)
        let withoutFrames = builder.finish(summary(), date: "d")
        #expect(withoutFrames == nil)

        builder.begin(timestamp: 1)
        builder.append(timestamp: 1, x: 0.5, y: 0.5, state: 2, density: 0.2, majorAxis: 8, minorAxis: 6, isValid: true)
        let fromCenter = builder.finish(summary(zone: "center"), date: "d")
        #expect(fromCenter == nil)
        #expect(!builder.isRecording)
    }

    @Test("一次接觸最多 3,000 幀；非有限值的幀跳過")
    func capsFramesAndSkipsNonFinite() throws {
        var builder = GestureTraceLineBuilder()
        builder.begin(timestamp: 0)
        builder.append(timestamp: 0, x: .nan, y: 0, state: 2, density: 0.2, majorAxis: 8, minorAxis: 6, isValid: true)
        for index in 0..<3_100 {
            builder.append(timestamp: Double(index) * 0.008, x: 0.5, y: 0.1, state: 4, density: 0.2, majorAxis: 8, minorAxis: 6, isValid: true)
        }
        let finished = builder.finish(summary(), date: "d")
        let line = try #require(finished)
        let trace = try JSONDecoder().decode(GestureTrace.self, from: Data(line.utf8))
        #expect(trace.frames.count == GestureTraceLineBuilder.maximumFramesPerContact)
    }

    @Test("讀檔時跳過壞掉的行")
    func loadSkipsBrokenLines() throws {
        let good = try slideTrace()
        let goodLine = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trackpal-trace-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try "\(goodLine)\n{\"id\":1,\"broken\n\n\(goodLine)\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(try GestureTrace.load(contentsOf: url).count == 2)
    }

    @Test("軌跡檔的位置：指定資料夾時舊檔在前")
    func logURLs() {
        let directory = URL(fileURLWithPath: "/tmp/somewhere", isDirectory: true)
        #expect(GestureTrace.defaultLogURLs(in: directory).map(\.lastPathComponent)
            == ["TrackPal.traces.previous.jsonl", "TrackPal.traces.jsonl"])
        #expect(GestureTrace.loadDefaultLogs(in: directory).isEmpty)
    }

    @Test("軌跡轉成重播輸入：每筆軌跡一組事件，最後補一個全部放開的幀")
    func traceEventsAreGroupedPerTrace() throws {
        let trace = try slideTrace()
        var empty = trace
        empty.frames = []
        let groups = EngineScenario.traceEvents([trace, empty, trace])

        #expect(groups.count == 3)
        #expect(groups[0].count == 41)
        #expect(groups[1].isEmpty)
        guard case let .touch(last) = groups[0].last, case let .touch(first) = groups[2].first else {
            Issue.record("每組應該以觸控幀開頭與結尾")
            return
        }
        #expect(last.count == 0)
        // 兩筆軌跡的日期相同，間隔取下限 0.02 秒；時間一路往前。
        #expect(first.timestamp > last.timestamp)
    }

    @Test("壓力只替角落與中鍵區的軌跡合成，而且要有記錄到壓力")
    func forceIsSynthesizedOnlyWhereItMatters() throws {
        func forceCount(_ trace: GestureTrace, synthesize: Bool = true) -> Int {
            EngineScenario.traceEvents([trace], synthesizeForce: synthesize)[0].count {
                if case .force = $0 { true } else { false }
            }
        }
        #expect(forceCount(try slideTrace(zone: "bottomEdge", force: 150)) == 0)
        #expect(forceCount(try slideTrace(zone: "bottomRightCorner", force: 10)) == 0)
        #expect(forceCount(try slideTrace(zone: "bottomRightCorner", force: 150)) > 0)
        #expect(forceCount(try slideTrace(zone: "middleClick", force: 150)) > 0)
        #expect(forceCount(try slideTrace(zone: "middleClick", force: 150), synthesize: false) == 0)
    }

    @MainActor
    @Test("實機格式的軌跡丟進狀態機重播：貼著下緣橫滑會啟動水平捲動")
    func replayingATraceThroughTheEngine() throws {
        var settings = EngineScenario.Settings()
        settings.bottomZoneHeight = 0.1647
        let scenario = EngineScenario.replaying([try slideTrace()], name: "trace", settings: settings)
        let result = Transcript(lines: EngineScenarioRunner.run(scenario))

        #expect(result.outcomes == ["scroll:bottomEdge"])
        #expect(result.totalScrollX > 0)
    }
}

@Suite("水平長條重算")
struct StripGateReplayTests {
    @Test("貼著下緣橫滑：啟動")
    func slideActivates() throws {
        let result = try #require(StripGateReplay.replay(try slideTrace()))
        #expect(result.decision == "activate")
        #expect(result.decidedAt != nil)
        #expect(!result.landedAfterPointerActivity)
    }

    @Test("不是從水平長條起步的軌跡：不適用")
    func otherZonesAreSkipped() throws {
        #expect(StripGateReplay.replay(try slideTrace(zone: "rightEdge")) == nil)
    }

    @Test("門檻調高到滑不到的距離：不啟動")
    func overridesChangeTheDecision() throws {
        var overrides = StripGateReplay.Overrides()
        let didSet = overrides.set("D", to: 0.9)
        #expect(didSet)
        let result = try #require(StripGateReplay.replay(try slideTrace(), overrides: overrides))
        #expect(result.decision != "activate")
    }

    @Test("剛移完游標就落指：改用較嚴的門檻，同一段滑動比較晚才啟動")
    func cautiousAfterPointerActivity() throws {
        let relaxed = try #require(StripGateReplay.replay(try slideTrace()))
        let cautious = try #require(StripGateReplay.replay(try slideTrace(pointerGap: 0.2)))
        #expect(cautious.landedAfterPointerActivity)
        #expect(cautious.decision == "activate")
        #expect(try #require(cautious.decidedAt) > (try #require(relaxed.decidedAt)))

        // 把「接力」的時間窗縮到 0.1 秒，0.2 秒前的游標活動就不算了。
        var overrides = StripGateReplay.Overrides()
        let didSet = overrides.set("window", to: 0.1)
        #expect(didSet)
        let narrowed = try #require(StripGateReplay.replay(try slideTrace(pointerGap: 0.2), overrides: overrides))
        #expect(!narrowed.landedAfterPointerActivity)
        #expect(narrowed.decidedAt == relaxed.decidedAt)
    }

    @Test("往內側走的軌跡：交給游標")
    func inwardMovementIsRejected() throws {
        var builder = GestureTraceLineBuilder()
        builder.begin(timestamp: 0)
        for index in 0..<30 {
            builder.append(timestamp: Double(index) * 0.008, x: 0.5, y: 0.03 + Float(index) * 0.006, state: 4, density: 0.2, majorAxis: 8, minorAxis: 6, isValid: true)
        }
        let finished = builder.finish(summary(), date: "2026-11-13T09:00:00.000+08:00")
        let line = try #require(finished)
        let trace = try JSONDecoder().decode(GestureTrace.self, from: Data(line.utf8))
        let result = try #require(StripGateReplay.replay(trace))
        #expect(result.decision.hasPrefix("reject:"))
    }

    @Test("認得的參數名稱都能設定，不認得的回報失敗")
    func overrideNames() {
        var overrides = StripGateReplay.Overrides()
        for name in StripGateReplay.Overrides.argumentNames {
            let didSet = overrides.set(name, to: 0.5)
            #expect(didSet, "\(name)")
        }
        let unknown = overrides.set("bogus", to: 1)
        #expect(!unknown)
        #expect(overrides.maximumSlope == 0.5 && overrides.scrollWindow == 0.5)
    }
}

@MainActor
@Suite("幀的分派")
struct FrameRoutingTests {
    private let touch = TouchSample(x: 0.95, y: 0.5, state: 2, density: 0.2, majorAxis: 8, minorAxis: 6.5)

    @Test("懸停幀與沒有 touch 資料的單指幀不送進狀態機，但手指數照樣登記")
    func hoverAndMissingTouchAreDropped() {
        let context = DeviceCallbackContext(deviceID: 1)
        var hover = touch
        hover.state = 1

        #expect(context.routeContactFrame(touchCount: 1, touch: hover, timestamp: 1, eventUptime: 1) == nil)
        #expect(context.routeContactFrame(touchCount: 1, touch: nil, timestamp: 1.008, eventUptime: 1.008) == nil)

        // 手指數已經是 1：下一幀的「先前手指數」是 1，世代不變。
        let next = context.routeContactFrame(touchCount: 1, touch: touch, timestamp: 1.016, eventUptime: 1.016)
        #expect(next?.previousFingerCount == 1)
        #expect(next?.contactGeneration == 1)
    }

    @Test("每次從零指變成有手指，接觸世代加一")
    func generationAdvancesPerContact() {
        let context = DeviceCallbackContext(deviceID: 1)
        let first = context.routeContactFrame(touchCount: 1, touch: touch, timestamp: 1, eventUptime: 1)
        _ = context.routeContactFrame(touchCount: 0, touch: nil, timestamp: 1.1, eventUptime: 1.1)
        let second = context.routeContactFrame(touchCount: 2, touch: nil, timestamp: 2, eventUptime: 2)

        #expect(first?.contactGeneration == 1)
        #expect(second?.contactGeneration == 2)
        #expect(second?.previousFingerCount == 0)
    }

    @Test("停用之後才送達的幀會被丟掉")
    func framesFromInactiveDevicesAreIgnored() throws {
        let effects = RecordingEffects()
        let engine = ZoneScrollEngine(effects: effects)
        let context = DeviceCallbackContext(deviceID: 7)
        engine.start(deviceIDs: [7])
        engine.stop()

        let frame = try #require(context.routeContactFrame(touchCount: 1, touch: touch, timestamp: 1, eventUptime: 1))
        frame.deliver(to: engine)

        #expect(effects.transcript.lines.isEmpty)
        #expect(!engine.isRunning)
    }

    @Test("start／stop 是冪等的；重新啟動後只認新的裝置 ID")
    func lifecycle() {
        let engine = ZoneScrollEngine(effects: RecordingEffects())
        engine.start(deviceIDs: [1, 2])
        engine.start(deviceIDs: [9])          // 已經在跑：忽略
        #expect(engine.isDeviceCallbackActive(deviceID: 1))
        #expect(!engine.isDeviceCallbackActive(deviceID: 9))

        engine.stop()
        engine.stop()
        #expect(!engine.isDeviceCallbackActive(deviceID: 1))

        engine.start(deviceIDs: [3])
        #expect(engine.isDeviceCallbackActive(deviceID: 3))
        #expect(!engine.isDeviceCallbackActive(deviceID: 1))
    }

    @Test("設定可以在執行中更換，下一次接觸生效")
    func configurationCanChangeWhileRunning() throws {
        let effects = RecordingEffects()
        let engine = ZoneScrollEngine(effects: effects)
        let context = DeviceCallbackContext(deviceID: 1)
        engine.start(deviceIDs: [1])

        func tapAtLeftEdge(at time: Double) throws {
            var sample = touch
            sample.x = 0.05
            try #require(context.routeContactFrame(touchCount: 1, touch: sample, timestamp: time, eventUptime: time)).deliver(to: engine)
            try #require(context.routeContactFrame(touchCount: 0, touch: nil, timestamp: time + 0.05, eventUptime: time + 0.05)).deliver(to: engine)
        }

        try tapAtLeftEdge(at: 1)
        engine.configuration.verticalEdgeMode = .both
        try tapAtLeftEdge(at: 2)

        let starts = effects.transcript.lines.filter { $0.contains("started at") }
        #expect(starts.count == 2)
        #expect(starts[0].contains("zone=center"))
        #expect(starts[1].contains("zone=leftEdge"))
    }

    @Test("排序器：晚到但硬體時間較早的幀先執行，而且在 main actor 上")
    func sequencerOrdersByHardwareTimestamp() async {
        let recorder = OrderRecorder()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            TouchCallbackSequencer.shared.enqueue(timestamp: 2.0) {
                recorder.append(2)
            }
            TouchCallbackSequencer.shared.enqueue(timestamp: 1.0) {
                recorder.append(1)
            }
            TouchCallbackSequencer.shared.enqueue(timestamp: 3.0) {
                recorder.append(3)
                continuation.resume()
            }
        }
        #expect(recorder.values == [1, 2, 3])
    }
}

@MainActor
private final class OrderRecorder {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}
