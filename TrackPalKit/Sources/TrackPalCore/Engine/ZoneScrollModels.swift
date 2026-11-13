import CoreGraphics

/// 一次接觸落在觸控板的哪一區。case 名稱會直接寫進日誌與軌跡檔，改名等於改格式。
public enum ScrollZone: Sendable, Hashable, CaseIterable {
    case none
    case leftEdge
    case rightEdge
    case bottomEdge
    case topEdge
    case middleClick
    case center
    case topLeftCorner
    case topRightCorner
    case bottomLeftCorner
    case bottomRightCorner
}

public enum VerticalEdgeMode: String, CaseIterable, Sendable {
    case left
    case right
    case both
}

public enum HorizontalPosition: String, CaseIterable, Sendable {
    case bottom
    case top
}

public enum AccelerationCurveType: String, CaseIterable, Sendable {
    case linear
    case quadratic
    case cubic
    case ease
}

public enum CornerAction: String, CaseIterable, Sendable {
    case none
    case rightClick
    case missionControl
    case appWindows
    case showDesktop
    case launchpad
    case notificationCenter
}

/// 四個角落各自的壓力動作。
public struct CornerActions: Sendable, Equatable {
    public var topLeft: CornerAction
    public var topRight: CornerAction
    public var bottomLeft: CornerAction
    public var bottomRight: CornerAction

    public init(
        topLeft: CornerAction = .none,
        topRight: CornerAction = .none,
        bottomLeft: CornerAction = .none,
        bottomRight: CornerAction = .none
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    /// 非角落的區域一律是 `.none`。
    public subscript(zone: ScrollZone) -> CornerAction {
        get {
            switch zone {
            case .topLeftCorner: topLeft
            case .topRightCorner: topRight
            case .bottomLeftCorner: bottomLeft
            case .bottomRightCorner: bottomRight
            default: .none
            }
        }
        set {
            switch zone {
            case .topLeftCorner: topLeft = newValue
            case .topRightCorner: topRight = newValue
            case .bottomLeftCorner: bottomLeft = newValue
            case .bottomRightCorner: bottomRight = newValue
            default: break
            }
        }
    }
}

/// 狀態機吃的全部設定。值型別：UI 改一個欄位，整份換進去即可。
public struct ZoneScrollConfiguration: Sendable, Equatable {
    /// 左右邊緣區寬度（佔觸控板寬度的比例）。
    public var edgeZoneWidth: CGFloat = 0.15
    /// 水平長條高度（佔觸控板高度的比例）。
    public var bottomZoneHeight: CGFloat = 0.30
    public var scrollMultiplier: CGFloat = 3.0
    public var verticalEdgeMode: VerticalEdgeMode = .right
    public var horizontalPosition: HorizontalPosition = .bottom
    public var middleClickEnabled: Bool = false
    public var middleClickZoneWidth: CGFloat = 0.30
    public var middleClickZoneHeight: CGFloat = 0.15
    public var accelerationCurveType: AccelerationCurveType = .linear
    public var cornerTriggerEnabled: Bool = false
    public var cornerTriggerZoneSize: CGFloat = 0.15
    public var cornerActions = CornerActions()

    /// 過濾幾乎沒碰到的接觸（density 低於門檻）。
    public var filterLightTouches: Bool = true
    /// 過濾手掌、手腕大小的接觸。
    public var filterLargeTouches: Bool = true
    public var lightTouchDensityThreshold: Float = 0.02
    /// 一般手指約 7–9，手掌約 15–25 以上。
    public var largeTouchMajorAxisThreshold: Float = 15.0
    /// 一般手指約 6–8，手掌約 12–20 以上。
    public var largeTouchMinorAxisThreshold: Float = 12.0

    public init() {}
}

/// 一次接觸結束時交給軌跡記錄的摘要。
public struct GestureTraceSummary: Sendable, Equatable {
    public var sessionID: UInt64
    public var initialZone: String
    public var finalZone: String
    public var outcome: String
    public var duration: Double
    /// 距離上一次游標活動結束的秒數；沒有紀錄時為 nil。
    public var pointerActivityGap: Double?
    /// 距離上一次水平捲動結束的秒數；沒有紀錄時為 nil。
    public var horizontalScrollGap: Double?
    public var stripDepth: Double
    public var edgeWidth: Double
    public var cornerSize: Double
    public var scrollPixelsX: Int64
    public var scrollPixelsY: Int64
    public var maximumForce: Float

    public init(
        sessionID: UInt64,
        initialZone: String,
        finalZone: String,
        outcome: String,
        duration: Double,
        pointerActivityGap: Double?,
        horizontalScrollGap: Double?,
        stripDepth: Double,
        edgeWidth: Double,
        cornerSize: Double,
        scrollPixelsX: Int64,
        scrollPixelsY: Int64,
        maximumForce: Float
    ) {
        self.sessionID = sessionID
        self.initialZone = initialZone
        self.finalZone = finalZone
        self.outcome = outcome
        self.duration = duration
        self.pointerActivityGap = pointerActivityGap
        self.horizontalScrollGap = horizontalScrollGap
        self.stripDepth = stripDepth
        self.edgeWidth = edgeWidth
        self.cornerSize = cornerSize
        self.scrollPixelsX = scrollPixelsX
        self.scrollPixelsY = scrollPixelsY
        self.maximumForce = maximumForce
    }
}

extension ZoneScrollConfiguration {
    /// 有壓力動作的角落，判定範圍沿著側邊往中間延伸的深度（佔觸控板高度的
    /// 比例）。示意圖用這個值畫擴大帶，跟實際判定同一個來源。
    public static let expandedCornerBandDepth: CGFloat =
        1.0 - CornerActivationZone.defaultFarEdgeBoundary
}
