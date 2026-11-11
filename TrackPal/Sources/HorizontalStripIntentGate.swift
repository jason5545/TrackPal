import CoreGraphics

/// 水平捲動長條（下方或上方區）的意圖判斷，游標優先。
///
/// [AI-Claude: 2026-11-11] 為什麼不沿用 `ScrollIntentGate`：
/// 下方區同時是單指使用者移游標最常起步的地方。11/10～11/11 的日誌裡，
/// 一天有 1,600 多次接觸從下方區開始，舊 gate 啟動了 253 次水平捲動，其中
/// 至少 127 次手指其實往上離開了長條或走斜線（在移游標）。舊 gate 在水平
/// 淨位移 1.6 mm 時就定案，之後整段接觸都鎖成捲動；判斷期間游標還被凍住，
/// 被拒絕的 685 次游標移動中位數各損失 0.19 秒。
///
/// 這個 gate 的規則：
/// - 判斷期間呼叫端不凍結游標，所以可以等到證據夠強才決定，錯了也只是
///   游標照常移動。
/// - 啟動條件是「留在長條內、持續一段時間的橫向直線滑動」：補償後水平
///   淨位移達 `activationDistance`，路徑連貫，判斷視窗至少持續
///   `minimumWindowDuration`，而且沒有明顯往觸控板內側走。
/// - 垂直方向分開看。往內側（遠離邊緣）是移游標的特徵，淨位移不得超過
///   水平的 `maximumSlope` 倍。往邊緣靠不算反證：11/11 實機記到 17 次刻意
///   的水平捲動，起點離下緣 0～8 mm 都有，常見的走法是落指後往下緣靠、
///   再貼著邊橫滑，或一邊橫滑一邊往下緣靠。同一段時間的游標移動都是往
///   內側走。
/// - 手指在游標移動剛結束後落下時（單指接力移游標），距離與時間改用較長
///   的 `cautious…`。上一次接觸剛做完水平捲動又落在長條時不加嚴：捲動
///   本來就是一下一下接著滑。
/// - 一旦明顯走向垂直、離開長條、或游移太久，整段接觸交給游標，不再回頭
///   判斷。
///
/// 座標是 MultitouchSupport 的 normalized 座標；水平位移乘上
/// `ScrollIntentGate.horizontalAspectCompensation` 後，1.0 約等於觸控板高度。
struct HorizontalStripIntentGate {
    enum Side: Equatable {
        case bottom
        case top
    }

    struct Configuration: Equatable {
        /// 長條厚度（normalized，從觸控板邊緣起算）。
        var stripDepth: CGFloat
        /// 一般情況下啟動所需的補償後水平淨位移。
        var activationDistance: CGFloat = 0.05
        /// 剛移完游標時所需的水平淨位移。
        var cautiousActivationDistance: CGFloat = 0.08
        /// 判斷視窗至少要持續的時間。日誌裡 0.1 秒內結束的橫向接觸是手掠過
        /// 邊緣，不是捲動。
        var minimumWindowDuration: Double = 0.12
        var cautiousMinimumWindowDuration: Double = 0.20
        /// 啟動時往內側（遠離邊緣）的淨位移不得超過水平淨位移的這個倍數
        /// （約 14 度）。
        var maximumSlope: CGFloat = 0.25
        /// 啟動時往邊緣靠的淨位移不得超過水平淨位移的這個倍數。
        var maximumDescentSlope: CGFloat = 1.0
        var minimumAxisCoherence: CGFloat = 0.80
        var minimumPathCoherence: CGFloat = 0.75
        /// 判斷視窗內至少要有的位移筆數。
        var minimumDeltaCount = 3
        /// 往內側的淨位移達到這個距離、而且斜度超過 `rejectionSlope` 就交給
        /// 游標。
        var rejectionVerticalDistance: CGFloat = 0.03
        var rejectionSlope: CGFloat = 0.5
        /// 啟動前，手指超出長條這麼多就交給游標。
        var exitMargin: CGFloat = 0.02
        /// 判斷視窗內累積路徑的上限；超過時軌跡仍不像橫向直線滑動就交給
        /// 游標。軌跡符合、只差持續時間的快速滑動不受這個上限影響。
        var wanderPathBudget: CGFloat = 0.25
        /// 手指停在 `pauseRadius` 內超過這個時間算停頓。
        var pauseDuration: Double = 0.18
        var pauseRadius: CGFloat = 0.004
        /// 一個判斷視窗最長的時間。
        var windowMaximumDuration: Double = 1.2
        /// 停頓或逾時發生時，手指離落點不到這個距離才算「還在原地」，可以
        /// 重開判斷視窗；超過就代表已經在移游標，整段接觸交給游標。
        var restExcursionLimit: CGFloat = 0.025

        init(stripDepth: CGFloat) {
            self.stripDepth = stripDepth
        }
    }

    enum RejectionReason: String, Equatable {
        /// 手指離開了長條。
        case leftStrip
        /// 明顯往觸控板內側走（垂直或斜線）。
        case verticalMovement
        /// 走了很長的路仍不符合直線滑動。
        case wandering
        /// 已經移動一段距離後停頓。
        case pausedAfterTravel
        /// 已經移動一段距離後，判斷視窗逾時。
        case stalledAfterTravel
        /// 已經移動一段距離後，出現無效的觸控幀。
        case interruptedAfterTravel
    }

    enum Decision: Equatable {
        case pending
        case activate
        case reject(RejectionReason)
    }

    let side: Side
    let configuration: Configuration
    /// 這次接觸是不是在游標移動剛結束後落下。
    let landedAfterPointerActivity: Bool
    /// 這次接觸是不是緊接在一次水平捲動之後落下。
    let continuesRecentScroll: Bool

    private(set) var decision: Decision = .pending
    /// 目前判斷視窗內的位移筆數與淨位移（未補償），供日誌使用。
    private(set) var windowDeltaCount = 0
    private(set) var windowNet: CGPoint = .zero
    private(set) var maximumExcursionFromTouchDown: CGFloat = 0

    private struct Point {
        var x: CGFloat      // 已補償
        var depth: CGFloat
        var time: Double
    }

    private var touchDown: Point?
    private var windowOrigin: Point?
    private var lastPoint: Point?
    private var stillAnchor: Point?
    private var needsAnchor = false
    private var pathX: CGFloat = 0
    private var pathLength: CGFloat = 0

    init(
        side: Side,
        configuration: Configuration,
        landedAfterPointerActivity: Bool,
        continuesRecentScroll: Bool = false
    ) {
        self.side = side
        self.configuration = configuration
        self.landedAfterPointerActivity = landedAfterPointerActivity
        self.continuesRecentScroll = continuesRecentScroll
    }

    /// 目前判斷視窗是不是要用較嚴的距離與時間。
    var isCautious: Bool {
        landedAfterPointerActivity && !continuesRecentScroll
    }

    /// 目前判斷視窗需要的水平淨位移。
    var requiredDistance: CGFloat {
        isCautious
            ? configuration.cautiousActivationDistance
            : configuration.activationDistance
    }

    /// 目前判斷視窗至少要持續的時間。
    var requiredDuration: Double {
        isCautious
            ? configuration.cautiousMinimumWindowDuration
            : configuration.minimumWindowDuration
    }

    /// 送入一幀有效觸控的位置。定案後維持同一結果。
    mutating func observe(position: CGPoint, timestamp: Double) -> Decision {
        guard decision == .pending else { return decision }
        guard position.x.isFinite,
              position.y.isFinite,
              timestamp.isFinite else {
            return finish(.reject(.interruptedAfterTravel))
        }

        let point = Point(
            x: position.x * ScrollIntentGate.horizontalAspectCompensation,
            depth: depth(of: position),
            time: timestamp
        )

        guard let touchDown else {
            self.touchDown = point
            anchorWindow(at: point)
            return .pending
        }

        maximumExcursionFromTouchDown = max(
            maximumExcursionFromTouchDown,
            hypot(point.x - touchDown.x, point.depth - touchDown.depth)
        )

        if point.depth > configuration.stripDepth + configuration.exitMargin {
            return finish(.reject(.leftStrip))
        }

        if needsAnchor {
            needsAnchor = false
            anchorWindow(at: point)
            return .pending
        }

        guard let origin = windowOrigin, let last = lastPoint else {
            anchorWindow(at: point)
            return .pending
        }

        let stepX = point.x - last.x
        let stepDepth = point.depth - last.depth
        pathX += abs(stepX)
        pathLength += hypot(stepX, stepDepth)
        windowDeltaCount += 1
        lastPoint = point

        let signedNetDepth = point.depth - origin.depth
        windowNet = CGPoint(
            x: (point.x - origin.x)
                / ScrollIntentGate.horizontalAspectCompensation,
            y: side == .bottom ? signedNetDepth : -signedNetDepth
        )
        let netX = abs(point.x - origin.x)
        // 往內側（遠離邊緣）與往邊緣靠分開算。
        let inward = max(0, signedNetDepth)
        let towardEdge = max(0, -signedNetDepth)

        if inward >= configuration.rejectionVerticalDistance,
           inward > configuration.rejectionSlope * netX {
            return finish(.reject(.verticalMovement))
        }

        let looksLikeStraightSlide =
            windowDeltaCount >= configuration.minimumDeltaCount
            && point.depth <= configuration.stripDepth
            && netX >= requiredDistance
            && inward <= configuration.maximumSlope * netX
            && towardEdge <= configuration.maximumDescentSlope * netX
            && pathX > 0
            && netX / pathX >= configuration.minimumAxisCoherence
            && pathLength > 0
            && hypot(netX, signedNetDepth) / pathLength
                >= configuration.minimumPathCoherence

        if looksLikeStraightSlide {
            if point.time - origin.time >= requiredDuration {
                return finish(.activate)
            }
        } else if pathLength >= configuration.wanderPathBudget {
            return finish(.reject(.wandering))
        }

        let isPaused = updatePause(with: point)
        let windowExpired =
            point.time - origin.time >= configuration.windowMaximumDuration
        if isPaused || windowExpired {
            guard maximumExcursionFromTouchDown
                    < configuration.restExcursionLimit else {
                return finish(.reject(
                    isPaused ? .pausedAfterTravel : .stalledAfterTravel
                ))
            }
            anchorWindow(at: point)
        }

        return .pending
    }

    /// 無效觸控幀（太輕或太大）是證據邊界：還在原地就等下一幀重新起算，
    /// 已經移動過就交給游標。
    mutating func interrupt() -> Decision {
        guard decision == .pending else { return decision }
        guard maximumExcursionFromTouchDown
                < configuration.restExcursionLimit else {
            return finish(.reject(.interruptedAfterTravel))
        }
        needsAnchor = true
        return .pending
    }

    private func depth(of position: CGPoint) -> CGFloat {
        switch side {
        case .bottom:
            return position.y
        case .top:
            return 1 - position.y
        }
    }

    private mutating func anchorWindow(at point: Point) {
        windowOrigin = point
        lastPoint = point
        stillAnchor = point
        pathX = 0
        pathLength = 0
        windowDeltaCount = 0
        windowNet = .zero
    }

    private mutating func updatePause(with point: Point) -> Bool {
        guard let anchor = stillAnchor else {
            stillAnchor = point
            return false
        }
        if hypot(point.x - anchor.x, point.depth - anchor.depth)
            > configuration.pauseRadius {
            stillAnchor = point
            return false
        }
        return point.time - anchor.time >= configuration.pauseDuration
    }

    private mutating func finish(_ decision: Decision) -> Decision {
        self.decision = decision
        return decision
    }
}

/// 水平捲動啟動之後的監測：手指離開長條，或有一段位移明顯走向垂直，就把
/// 手勢交回游標。
///
/// [AI-Claude: 2026-11-11] 取代 11/10 的 `ScrollActivationTurnMonitor`。
/// 舊監測只在捲動剛啟動（水平路徑不到 0.12）時有效，之後就失效；日誌裡有
/// 手指從下緣一路斜走到觸控板頂端、整段都被當成水平捲動的例子（淨位移
/// 垂直 0.999）。這個版本沒有期限，逐段檢查：每累積 `segmentDistance` 的
/// 位移看一次方向，垂直佔比達 `minimumVerticalDominance` 就交回游標。
struct HorizontalScrollExitMonitor {
    struct Configuration: Equatable {
        var stripDepth: CGFloat
        /// 啟動後，手指超出長條這麼多就交回游標。
        var exitMargin: CGFloat = 0.03
        var segmentDistance: CGFloat = 0.035
        var minimumVerticalDominance: CGFloat = 0.65

        init(stripDepth: CGFloat) {
            self.stripDepth = stripDepth
        }
    }

    enum DemotionReason: String, Equatable {
        case leftStrip
        case turnedVertical
    }

    let side: HorizontalStripIntentGate.Side
    let configuration: Configuration
    private var segmentNetX: CGFloat = 0
    private var segmentNetY: CGFloat = 0

    /// 啟動視窗已經通過直線條件，所以第一段從啟動那一刻重新起算。
    init(
        side: HorizontalStripIntentGate.Side,
        configuration: Configuration
    ) {
        self.side = side
        self.configuration = configuration
    }

    /// 送入啟動後的一幀；回傳非 nil 代表應該取消捲動、交回游標。
    mutating func observe(
        position: CGPoint,
        delta: ScrollIntentGate.Sample
    ) -> DemotionReason? {
        guard position.x.isFinite,
              position.y.isFinite,
              delta.dx.isFinite,
              delta.dy.isFinite else {
            return nil
        }

        let depth = side == .bottom ? position.y : 1 - position.y
        if depth > configuration.stripDepth + configuration.exitMargin {
            return .leftStrip
        }

        segmentNetX += delta.dx * ScrollIntentGate.horizontalAspectCompensation
        segmentNetY += delta.dy
        let horizontal = abs(segmentNetX)
        let vertical = abs(segmentNetY)
        guard hypot(horizontal, vertical) >= configuration.segmentDistance else {
            return nil
        }

        let total = horizontal + vertical
        if total > 0,
           vertical / total >= configuration.minimumVerticalDominance {
            return .turnedVertical
        }

        segmentNetX = 0
        segmentNetY = 0
        return nil
    }
}

/// 兩次接觸之間的脈絡：上一次手部活動是不是在移游標、什麼時候結束。
///
/// 單指移游標要一段一段接力（抬起、放回、再滑）。接力的落點常在下方區，
/// 動作跟刻意的水平捲動分不出來，只能靠「剛剛還在移游標」這個脈絡提高
/// 門檻。
struct PointerActivityRecency {
    /// 水平捲動結束後，這段時間內再落在長條算「接著捲」。
    static let scrollContinuationWindow: Double = 1.0

    /// 接力間隔的上限。日誌裡確定是游標移動的下方區誤啟動，69% 發生在
    /// 上一個手勢結束後 0.8 秒內。
    static let defaultWindow: Double = 0.7
    /// 接觸位移達到這個距離才算「移動過游標」；輕點不算。
    static let minimumPointerExcursion: CGFloat = 0.03

    private(set) var lastPointerActivityEnd: Double?
    private(set) var lastHorizontalScrollEnd: Double?

    mutating func recordPointerActivityEnd(at uptime: Double) {
        guard uptime.isFinite else { return }
        lastPointerActivityEnd = uptime
    }

    mutating func recordHorizontalScrollEnd(at uptime: Double) {
        guard uptime.isFinite else { return }
        lastHorizontalScrollEnd = uptime
    }

    mutating func reset() {
        lastPointerActivityEnd = nil
        lastHorizontalScrollEnd = nil
    }

    func continuesHorizontalScroll(
        at uptime: Double,
        window: Double = scrollContinuationWindow
    ) -> Bool {
        guard let lastHorizontalScrollEnd,
              uptime.isFinite,
              window.isFinite,
              window > 0 else {
            return false
        }
        let gap = uptime - lastHorizontalScrollEnd
        return gap >= 0 && gap < window
    }

    func landedAfterPointerActivity(
        at uptime: Double,
        window: Double = defaultWindow
    ) -> Bool {
        guard let lastPointerActivityEnd,
              uptime.isFinite,
              window.isFinite,
              window > 0 else {
            return false
        }
        let gap = uptime - lastPointerActivityEnd
        return gap >= 0 && gap < window
    }
}
