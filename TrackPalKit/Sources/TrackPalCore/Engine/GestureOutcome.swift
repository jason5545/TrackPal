/// 進行中的手勢為什麼被取消。raw value 會寫進日誌與軌跡檔。
enum GestureCancellationReason: String, Sendable {
    case cancelled
    case stopped
    case multiFinger = "multi-finger"
    case filterLight = "filter-light"
    case filterLarge = "filter-large"
    case nonFiniteTouch = "non-finite-touch"
}

/// 一次接觸目前（或最後）被判成什麼。
///
/// `description` 就是寫進日誌 `terminal outcome=` 與軌跡檔 `outcome` 的字串；
/// 分析工具靠這些字串分類，所以新增 case 可以，改既有字串不行。
enum GestureOutcome: Sendable, Equatable, CustomStringConvertible {
    case none
    /// 接觸進行中，還沒有任何判定。
    case pending
    /// 落在水平長條，游標照常移動，等 gate 判斷。
    case stripPending
    case scroll(ScrollZone)
    case scrollRejected
    case scrollTimeout
    /// 水平捲動啟動後，手指離開長條或轉向，交回游標。
    case scrollDemoted(ScrollZone)
    case scrollRecoveryInvalid
    case stripRejected(HorizontalStripIntentGate.RejectionReason)
    /// 放開時長條仍未定案，而且手指有移動。
    case stripUndecided
    case tapInScrollZone
    case middleClick
    case cornerAction(CornerAction)
    case cancelled(GestureCancellationReason)

    var description: String {
        switch self {
        case .none: "none"
        case .pending: "pending"
        case .stripPending: "strip-pending"
        case let .scroll(zone): "scroll:\(zone)"
        case .scrollRejected: "scroll-rejected"
        case .scrollTimeout: "scroll-timeout"
        case let .scrollDemoted(zone): "scroll-demoted:\(zone)"
        case .scrollRecoveryInvalid: "scroll-recovery-invalid"
        case let .stripRejected(reason): "strip-rejected:\(reason.rawValue)"
        case .stripUndecided: "strip-undecided"
        case .tapInScrollZone: "tap-in-scroll-zone"
        case .middleClick: "middle-click"
        case let .cornerAction(action): "corner-action:\(action.rawValue)"
        case let .cancelled(reason): reason.rawValue
        }
    }

    /// 這次接觸最後是在送捲動。
    var endedAsScroll: Bool {
        if case .scroll = self { true } else { false }
    }

    /// 被多指或過濾打斷：手多半還在觸控板上移游標。
    var wasInterrupted: Bool {
        switch self {
        case .cancelled(.multiFinger), .cancelled(.filterLarge), .cancelled(.filterLight):
            true
        default:
            false
        }
    }
}
