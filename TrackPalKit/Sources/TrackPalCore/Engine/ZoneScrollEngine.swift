import CoreGraphics
import Foundation

/// 單指區域捲動的手勢狀態機。
///
/// 吃進排序好的觸控幀與壓力樣本，決定這次接觸是捲動、壓力動作、輕點還是一般
/// 的游標移動，再透過 `ZoneScrollEffects` 把結果送出去。不直接碰任何系統 API，
/// 所以同一段輸入一定得到同一串輸出。
///
/// 檔案依職責拆成多個 extension：
/// - `+FrameRouting`：一幀 callback 進來之後的仲裁與分派
/// - `+Touch`：接觸開始、移動、放開、收尾
/// - `+ScrollIntent`：垂直邊緣與角落的捲動意圖
/// - `+HorizontalStrip`：水平長條（游標優先）
/// - `+Force`：中鍵與角落的壓力動作
/// - `+Zones`、`+TouchFilter`、`+MultiTouch`、`+ScrollOutput`、`+Actions`
@MainActor
public final class ZoneScrollEngine {

    static let cornerMaxMovementBeforeForce =
        CornerForceCrossingGrace.defaultBaseMaximumExcursion

    // MARK: - Dependencies

    public let effects: any ZoneScrollEffects

    /// event tap 讀的旗標；狀態機是唯一的寫入者。
    public let suppression: ScrollSuppressionState

    public var configuration: ZoneScrollConfiguration

    public init(
        configuration: ZoneScrollConfiguration = ZoneScrollConfiguration(),
        effects: any ZoneScrollEffects,
        suppression: ScrollSuppressionState = ScrollSuppressionState()
    ) {
        self.configuration = configuration
        self.effects = effects
        self.suppression = suppression
    }

    // MARK: - Lifecycle

    /// 是否正在接收裝置輸入。
    public private(set) var isRunning = false

    /// 目前有效的裝置 callback ID。停用之後才送達的 callback 會因為 ID 不在
    /// 這裡而被丟掉。
    var activeDeviceCallbackIDs: Set<Int> = []

    /// 開始接收輸入。`deviceIDs` 是這一輪註冊的裝置 callback ID。
    public func start(deviceIDs: [Int]) {
        guard !isRunning else { return }
        resetInputLifecycleForRestart()
        activeDeviceCallbackIDs = Set(deviceIDs)
        isRunning = true
    }

    /// 停止接收輸入。進行中的手勢會被取消（不補送原生點擊）。
    public func stop() {
        if contact.isTracking {
            cancelActiveScrolling(reason: .stopped)
        }
        resetInputLifecycleForRestart()
        isRunning = false
    }

    public func isDeviceCallbackActive(deviceID: Int) -> Bool {
        activeDeviceCallbackIDs.contains(deviceID)
    }

    var isActivelyScrollingInZone: Bool {
        get { suppression.isActivelyScrolling }
        set { suppression.isActivelyScrolling = newValue }
    }

    var isEvaluatingScrollCandidate: Bool {
        get { suppression.isEvaluatingCandidate }
        set { suppression.isEvaluatingCandidate = newValue }
    }

    // MARK: - Tuning constants

    let velocityHistorySize = 5
    let minimumActivationSampleDistance: CGFloat = 0.0005
    let minimumEvidenceActivityDistance: CGFloat = 0.00005
    let activationEvidenceGapDeadline: Double = 0.18
    let activationSafetyMaxSamples = 24
    let tapMaxMovement: CGFloat = ForcePressActionGate.defaultMaxMovementBeforeForce
    let forcePressMaxDuration: Double = 1.0
    let forcePressActionGate = ForcePressActionGate()
    let cornerForcePressThreshold: Float = 100.0
    let cornerForceAssistedThreshold: Float = 70.0
    let middleClickForcePressThreshold: Float = 70.0
    /// A filter spike at the physical edge should not split one contact into
    /// two gestures. Three consecutive invalid frames cancel and quarantine the
    /// contact until every finger has lifted.
    let invalidTouchFramesBeforeCancellation = 3

    // MARK: - Nested types

    enum ScrollRecoveryKind {
        case rightEdgeOutwardSettling
        case rightEdgeLateCoherence
        case cornerScrollOnly

        var logName: String {
            switch self {
            case .rightEdgeOutwardSettling:
                return "Right-edge outward settling recovery"
            case .rightEdgeLateCoherence:
                return "Right-edge late-coherence recovery"
            case .cornerScrollOnly:
                return "Corner scroll recovery"
            }
        }
    }

    enum CornerForceRegion: String, Equatable {
        case strict
        case band
    }

    enum PendingForceTarget: Equatable {
        case middleClick
        case corner(CornerForceRegion)
    }

    struct PendingForceEvaluation {
        let target: PendingForceTarget
        var force: Float
        var sampleTimestamp: Double
        var sampleUptime: Double
    }

    /// Gesture mode for tracking single vs multi-finger state
    enum GestureMode {
        case idle           // No touch
        case singleFinger   // Single finger - TrackPal active
        case multiFinger    // Multi-finger - system gestures
    }

    // MARK: - Per-contact state

    /// 一次接觸（落指到全部放開）期間的全部狀態。
    ///
    /// 落指時換一份新的、放開或取消時再換一份，所以不存在「某個欄位忘了重設、
    /// 帶到下一次接觸」這種錯：新增欄位只要給預設值。跨接觸才有意義的狀態
    /// （裝置仲裁、多指、隔離、游標活動的時間）放在外面的 lifecycle 區。
    struct ContactState {
        var isTracking = false
        var currentZone: ScrollZone = .none
        var lastTouchPosition: CGPoint = .zero
        var lastTouchTime: Double = 0
        var lastTouchCallbackArrivalUptime: Double = 0

        // Velocity tracking for inertia
        var velocityHistory: [(vx: CGFloat, vy: CGFloat, time: Double)] = []

        // Sub-pixel scroll accumulator (prevents truncation dead zone)
        var scrollAccumulatorX: CGFloat = 0
        var scrollAccumulatorY: CGFloat = 0
        var hasEmittedScrollBegan = false

        // Scroll activation (vertical edges and corners): determine if the
        // user really wants to scroll.
        var isScrollActivationPending = false
        /// Original zone before a corner was promoted to an edge.
        var activationOriginalZone: ScrollZone = .none
        var activationDeltas: [CGPoint] = []
        var activationSampleTimestamps: [Double] = []
        var activationDeltaAccumulator: CGPoint = .zero
        var activationRawEvidenceMetrics = ScrollIntentGate.Metrics()
        var activationRawEvidenceIsValid = true
        var activationWindowStartTimestamp: Double = 0
        var activationLastEvidenceUptime: Double?
        var scrollIntentGate: ScrollIntentGate?
        var hasUsedEarlyOutwardScrollRecovery = false
        var hasUsedLateCoherenceScrollRecovery = false
        var hasUsedCornerScrollRecovery = false
        var activeScrollRecoveryKind: ScrollRecoveryKind?
        var scrollRecoveryStartedUptime: Double?

        // 水平長條（游標優先）：判斷期間不凍結游標，由 HorizontalStripIntentGate
        // 決定是否啟動；啟動後由 HorizontalScrollExitMonitor 監看手指有沒有離開
        // 長條或轉向。
        var stripIntentGate: HorizontalStripIntentGate?
        var horizontalExitMonitor: HorizontalScrollExitMonitor?
        var gesturePointerActivityGap: Double?
        var gestureHorizontalScrollGap: Double?
        /// 落在水平長條那一刻的游標位置（全域螢幕座標）。確認是捲動時把游標
        /// 放回這裡，捲動才會作用在落指時游標所在的內容上。
        var stripPointerOrigin: CGPoint?
        var horizontalScrollLockedUntilLift = false
        var hasLoggedHorizontalLockSuppressionInTouch = false

        // Tap and force-press detection
        var touchStartTime: Double = 0
        var touchStartUptime: Double = 0
        var touchStartPosition: CGPoint = .zero
        var maxTouchDisplacement: CGFloat = 0
        var forcePressSatisfied = false
        var forcePressMaxForce: Float = 0
        var rawForceSampleCount = 0
        var rawForcePeak: Float = 0
        var forcePressSource = "none"
        var forceActionTriggered = false
        var forcePressThresholdRejected = false
        var forceGestureDisqualified = false
        var cornerForceWindowExpired = false
        var isTouchEnding = false
        var touchEndingTimestamp: Double?
        var pendingForceEvaluations: [PendingForceEvaluation] = []
        var touchExcursionTimeline = TouchExcursionTimeline()
        var cornerForceCapCrossing: CornerForceCrossingGrace?
        var hasLoggedForceDropReason = false

        // Invalid-frame debounce while tracking
        var consecutiveInvalidTouchFrames = 0
        var forceEvaluationSuspendedByInvalidTouch = false

        // Per-contact identity is also used to scope native click suppression.
        var activeTouchSessionID: UInt64?
        var pendingForceClickSessionID: UInt64?
        var shouldReplayPendingPrimaryClick = false

        // Terminal telemetry. One concise record per physical contact is much
        // more useful than several unrelated threshold messages.
        var gestureOutcome: GestureOutcome = .none
        var gestureInitialZone: ScrollZone = .none
        var gesturePathX: CGFloat = 0
        var gesturePathY: CGFloat = 0
        var gestureNetX: CGFloat = 0
        var gestureNetY: CGFloat = 0
        var emittedScrollEventCount = 0
        var emittedScrollPixelsX: Int64 = 0
        var emittedScrollPixelsY: Int64 = 0
    }

    var contact = ContactState()

    // MARK: - Lifecycle state (spans contacts)

    var touchDeviceArbitrationGate = TouchDeviceArbitrationGate()
    var currentGestureMode: GestureMode = .idle
    var activeFingerCount = 0
    var requiresAllFingersLifted = false
    var isContactQuarantinedUntilLift = false
    /// Palm-sized frames seen before any valid frame started tracking.
    var pretrackingInvalidTouchFrames = 0
    var pointerActivityRecency = PointerActivityRecency()
    var nextTouchSessionID: UInt64 = 0

    /// Stop/start is also a hard physical-contact boundary. Without clearing
    /// this state, disabling TrackPal during a multi-touch or quarantined
    /// contact can poison the first complete gesture after it is re-enabled.
    func resetInputLifecycleForRestart() {
        activeDeviceCallbackIDs.removeAll()
        touchDeviceArbitrationGate.reset()
        currentGestureMode = .idle
        activeFingerCount = 0
        requiresAllFingersLifted = false
        isContactQuarantinedUntilLift = false
        pretrackingInvalidTouchFrames = 0
        pointerActivityRecency.reset()
        contact = ContactState()
        isActivelyScrollingInZone = false
        isEvaluatingScrollCandidate = false
    }
}
