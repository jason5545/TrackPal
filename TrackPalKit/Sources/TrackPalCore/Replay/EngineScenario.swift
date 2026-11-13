import Foundation

/// 一段可以重播的輸入：設定加上依序發生的觸控幀、壓力樣本與重啟。
///
/// 狀態機不碰系統 API，所以同一份 scenario 丟進去一定得到同一串輸出。
/// 測試、`trackpal-replay` 與重構時的新舊對照都用這個格式。
public struct EngineScenario: Codable, Sendable, Equatable {
    public var name: String
    public var settings: Settings
    public var deviceCount: Int
    public var events: [Event]

    public init(
        name: String,
        settings: Settings = Settings(),
        deviceCount: Int = 1,
        events: [Event] = []
    ) {
        self.name = name
        self.settings = settings
        self.deviceCount = deviceCount
        self.events = events
    }

    /// 與 App 設定一一對應；列舉用 raw value 存，格式不綁 Swift 型別。
    public struct Settings: Codable, Sendable, Equatable {
        public var edgeZoneWidth: Double = 0.15
        public var bottomZoneHeight: Double = 0.30
        public var scrollMultiplier: Double = 3.0
        public var verticalEdgeMode: String = "right"
        public var horizontalPosition: String = "bottom"
        public var middleClickEnabled: Bool = true
        public var accelerationCurveType: String = "linear"
        public var cornerTriggerEnabled: Bool = false
        public var cornerTriggerZoneSize: Double = 0.15
        public var cornerActionTopLeft: String = "none"
        public var cornerActionTopRight: String = "none"
        public var cornerActionBottomLeft: String = "none"
        public var cornerActionBottomRight: String = "rightClick"
        public var filterLightTouches: Bool = true
        public var filterLargeTouches: Bool = true
        public var lightTouchDensityThreshold: Float = 0.02
        public var largeTouchMajorAxisThreshold: Float = 15.0
        public var largeTouchMinorAxisThreshold: Float = 12.0

        public init() {}
    }

    public enum Event: Codable, Sendable, Equatable {
        case touch(TouchFrame)
        case force(ForceSample)
        /// 停用再啟用（對應使用者關掉再打開，或喚醒後重新註冊裝置）。
        case restart(uptime: Double)
        /// 之後查詢游標位置時回傳的值（全域螢幕座標）。
        case pointer(x: Double, y: Double)
    }

    /// 一次 contact-frame callback。`count` 是這一幀的手指數；`count == 1`
    /// 以外的幀只用到 `timestamp` 與 `uptime`。
    public struct TouchFrame: Codable, Sendable, Equatable {
        public var device: Int
        public var timestamp: Double
        public var uptime: Double
        public var count: Int
        public var x: Float
        public var y: Float
        public var state: Int32
        public var density: Float
        public var majorAxis: Float
        public var minorAxis: Float

        public init(
            device: Int = 0,
            timestamp: Double,
            uptime: Double,
            count: Int,
            x: Float = 0,
            y: Float = 0,
            state: Int32 = 7,
            density: Float = 0,
            majorAxis: Float = 0,
            minorAxis: Float = 0
        ) {
            self.device = device
            self.timestamp = timestamp
            self.uptime = uptime
            self.count = count
            self.x = x
            self.y = y
            self.state = state
            self.density = density
            self.majorAxis = majorAxis
            self.minorAxis = minorAxis
        }
    }

    /// 一次 force-centroid callback。`rawTimestamp` 是 framework 的毫秒時鐘。
    public struct ForceSample: Codable, Sendable, Equatable {
        public var device: Int
        public var rawTimestamp: Double
        public var uptime: Double
        public var x: Float
        public var y: Float
        public var force: Float

        public init(
            device: Int = 0,
            rawTimestamp: Double,
            uptime: Double,
            x: Float = 0,
            y: Float = 0,
            force: Float
        ) {
            self.device = device
            self.rawTimestamp = rawTimestamp
            self.uptime = uptime
            self.x = x
            self.y = y
            self.force = force
        }
    }
}

/// 把狀態機的輸出寫成一行一筆的文字，方便逐位元比對。
///
/// 慣性的啟動與停止另外排在該事件所有其他輸出之後：舊版把它們丟到下一輪
/// main queue 才執行，新版同步呼叫，兩者在同一個事件內的相對順序不同，
/// 但對外可觀察的結果一樣。
public struct EngineEffectTranscript: Sendable {
    public private(set) var lines: [String] = []
    private var deferredInertiaLines: [String] = []
    private var lastFlags: String?

    public init() {}

    public mutating func record(_ line: String) {
        lines.append(line)
    }

    public mutating func recordInertia(_ line: String) {
        deferredInertiaLines.append(line)
    }

    /// 每個輸入事件處理完呼叫一次。
    public mutating func finishEvent(
        isActivelyScrolling: Bool,
        isEvaluatingCandidate: Bool
    ) {
        lines.append(contentsOf: deferredInertiaLines)
        deferredInertiaLines.removeAll(keepingCapacity: true)
        let flags = "flags \(isActivelyScrolling ? 1 : 0) \(isEvaluatingCandidate ? 1 : 0)"
        if flags != lastFlags {
            lines.append(flags)
            lastFlags = flags
        }
    }

    public static func format(_ value: Double) -> String {
        String(format: "%.9g", value)
    }

    public static func format(_ value: Double?) -> String {
        value.map { String(format: "%.9g", $0) } ?? "nil"
    }
}
