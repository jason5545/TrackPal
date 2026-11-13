import CoreGraphics
import Foundation

/// 只記錄、不執行的 `ZoneScrollEffects`。
@MainActor
public final class RecordingEffects: ZoneScrollEffects {
    public var transcript = EngineEffectTranscript()
    /// `now()` 回傳的值；重播時設成目前這筆輸入的 uptime。
    public var clock: Double = 0
    public var pointer: CGPoint?
    /// 關掉可以省下逐幀的 `trace-frame` 輸出。
    public var recordsTraceFrames = true

    public init() {}

    private typealias Format = EngineEffectTranscript

    public func log(_ message: String) {
        transcript.record("log " + message)
    }

    public func now() -> Double {
        clock
    }

    public func postScroll(
        deltaX: Int32, deltaY: Int32, scrollPhase: Int64, momentumPhase: Int64
    ) {
        transcript.record("scroll \(deltaX) \(deltaY) \(scrollPhase) \(momentumPhase)")
    }

    public func postMiddleClick() -> Bool {
        transcript.record("middle-click")
        return true
    }

    public func performCornerAction(_ action: CornerAction) {
        transcript.record("corner-action \(action.rawValue)")
    }

    public func pointerLocation() -> CGPoint? {
        pointer
    }

    public func warpPointer(to location: CGPoint) {
        transcript.record(
            "warp \(Format.format(Double(location.x))) \(Format.format(Double(location.y)))"
        )
    }

    public func startInertia(velocityX: CGFloat, velocityY: CGFloat) {
        transcript.recordInertia(
            "inertia-start \(Format.format(Double(velocityX))) \(Format.format(Double(velocityY)))"
        )
    }

    public func stopInertia() {
        transcript.recordInertia("inertia-stop")
    }

    public func beginPrimaryClickCapture(token: UInt64, gestureUptime: Double) {
        transcript.record("click-begin \(token) \(Format.format(gestureUptime))")
    }

    public func finishPrimaryClickCapture(
        token: UInt64, replayCapturedClick: Bool, gestureUptime: Double?
    ) {
        transcript.record(
            "click-finish \(token) \(replayCapturedClick ? 1 : 0) \(Format.format(gestureUptime))"
        )
    }

    public func traceBegin(timestamp: Double) {
        transcript.record("trace-begin \(Format.format(timestamp))")
    }

    public func traceFrame(
        timestamp: Double, x: Float, y: Float, state: Int32, density: Float,
        majorAxis: Float, minorAxis: Float, isValid: Bool
    ) {
        guard recordsTraceFrames else { return }
        transcript.record(
            "trace-frame \(Format.format(timestamp)) \(x) \(y) \(state) \(density) \(majorAxis) \(minorAxis) \(isValid ? 1 : 0)"
        )
    }

    public func traceFinish(_ s: GestureTraceSummary) {
        transcript.record(
            "trace-finish \(s.sessionID) \(s.initialZone) \(s.finalZone) \(s.outcome) \(Format.format(s.duration)) \(Format.format(s.pointerActivityGap)) \(Format.format(s.horizontalScrollGap)) \(Format.format(s.stripDepth)) \(Format.format(s.edgeWidth)) \(Format.format(s.cornerSize)) \(s.scrollPixelsX) \(s.scrollPixelsY) \(s.maximumForce)"
        )
    }
}

extension ZoneScrollConfiguration {
    /// raw value 認不得的欄位回傳 nil。
    public init?(_ settings: EngineScenario.Settings) {
        guard let verticalEdgeMode = VerticalEdgeMode(rawValue: settings.verticalEdgeMode),
              let horizontalPosition = HorizontalPosition(rawValue: settings.horizontalPosition),
              let curve = AccelerationCurveType(rawValue: settings.accelerationCurveType),
              let topLeft = CornerAction(rawValue: settings.cornerActionTopLeft),
              let topRight = CornerAction(rawValue: settings.cornerActionTopRight),
              let bottomLeft = CornerAction(rawValue: settings.cornerActionBottomLeft),
              let bottomRight = CornerAction(rawValue: settings.cornerActionBottomRight) else {
            return nil
        }
        self.init()
        edgeZoneWidth = CGFloat(settings.edgeZoneWidth)
        bottomZoneHeight = CGFloat(settings.bottomZoneHeight)
        scrollMultiplier = CGFloat(settings.scrollMultiplier)
        self.verticalEdgeMode = verticalEdgeMode
        self.horizontalPosition = horizontalPosition
        middleClickEnabled = settings.middleClickEnabled
        accelerationCurveType = curve
        cornerTriggerEnabled = settings.cornerTriggerEnabled
        cornerTriggerZoneSize = CGFloat(settings.cornerTriggerZoneSize)
        cornerActions = CornerActions(
            topLeft: topLeft,
            topRight: topRight,
            bottomLeft: bottomLeft,
            bottomRight: bottomRight
        )
        filterLightTouches = settings.filterLightTouches
        filterLargeTouches = settings.filterLargeTouches
        lightTouchDensityThreshold = settings.lightTouchDensityThreshold
        largeTouchMajorAxisThreshold = settings.largeTouchMajorAxisThreshold
        largeTouchMinorAxisThreshold = settings.largeTouchMinorAxisThreshold
    }
}

/// 把一段 `EngineScenario` 丟進真正的狀態機，回傳它對外做的每一件事。
///
/// 輸入照順序直接送進去，不經過 `TouchCallbackSequencer`（排序器另外測）。
@MainActor
public enum EngineScenarioRunner {
    public struct Options: Sendable {
        public var recordsTraceFrames = true
        public init() {}
    }

    /// 一次重播。可以一筆一筆餵事件，每次拿回新增的輸出。
    @MainActor
    public final class Session {
        private let effects = RecordingEffects()
        private let engine: ZoneScrollEngine
        private let deviceCount: Int
        private var contexts: [DeviceCallbackContext] = []
        private var nextDeviceID = 0
        private var consumedLineCount = 0

        /// 設定裡有不認得的 raw value 時回傳 nil。
        public init?(
            settings: EngineScenario.Settings,
            deviceCount: Int = 1,
            options: Options = Options()
        ) {
            guard let configuration = ZoneScrollConfiguration(settings) else {
                return nil
            }
            effects.recordsTraceFrames = options.recordsTraceFrames
            engine = ZoneScrollEngine(configuration: configuration, effects: effects)
            self.deviceCount = max(1, deviceCount)
            startDevices()
        }

        private func startDevices() {
            contexts = (0..<deviceCount).map { _ in
                nextDeviceID += 1
                return DeviceCallbackContext(deviceID: nextDeviceID)
            }
            engine.start(deviceIDs: contexts.map(\.deviceID))
        }

        /// 目前為止的全部輸出。
        public var lines: [String] { effects.transcript.lines }

        /// 處理一筆事件，回傳這筆事件新增的輸出。
        @discardableResult
        public func feed(_ event: EngineScenario.Event) -> ArraySlice<String> {
            switch event {
            case let .pointer(x, y):
                effects.pointer = CGPoint(x: x, y: y)

            case let .restart(uptime):
                effects.clock = uptime
                engine.stop()
                startDevices()
                finishEvent()

            case let .force(sample):
                guard contexts.indices.contains(sample.device) else { break }
                effects.clock = sample.uptime
                recordForceCentroidSample(
                    x: sample.x,
                    y: sample.y,
                    force: sample.force,
                    rawTimestamp: sample.rawTimestamp,
                    sampleUptime: sample.uptime,
                    into: contexts[sample.device]
                )
                finishEvent()

            case let .touch(frame):
                guard contexts.indices.contains(frame.device) else { break }
                effects.clock = frame.uptime
                let routed = contexts[frame.device].routeContactFrame(
                    touchCount: frame.count,
                    touch: frame.count == 1
                        ? TouchSample(
                            x: frame.x,
                            y: frame.y,
                            state: frame.state,
                            density: frame.density,
                            majorAxis: frame.majorAxis,
                            minorAxis: frame.minorAxis
                        )
                        : nil,
                    timestamp: frame.timestamp,
                    eventUptime: frame.uptime
                )
                routed?.deliver(to: engine)
                finishEvent()
            }

            let newLines = effects.transcript.lines[consumedLineCount...]
            consumedLineCount = effects.transcript.lines.count
            return newLines
        }

        private func finishEvent() {
            effects.transcript.finishEvent(
                isActivelyScrolling: engine.suppression.isActivelyScrolling,
                isEvaluatingCandidate: engine.suppression.isEvaluatingCandidate
            )
        }
    }

    public static func run(
        _ scenario: EngineScenario,
        options: Options = Options()
    ) -> [String] {
        guard let session = Session(
            settings: scenario.settings,
            deviceCount: scenario.deviceCount,
            options: options
        ) else {
            return ["error invalid settings"]
        }
        for event in scenario.events {
            session.feed(event)
        }
        return session.lines
    }
}
