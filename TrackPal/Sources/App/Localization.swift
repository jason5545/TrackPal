import TrackPalCore

/// 顯示在設定選單裡的名稱。列舉本身定義在 `TrackPalCore`，那邊不碰 UI 文字；
/// 字串放在 App 的 `Localizable.xcstrings`。
protocol LocalizedNameProvider {
    var localizedName: String { get }
}

extension VerticalEdgeMode: LocalizedNameProvider {
    var localizedName: String {
        switch self {
        case .left: String(localized: "Left")
        case .right: String(localized: "Right")
        case .both: String(localized: "Both")
        }
    }
}

extension HorizontalPosition: LocalizedNameProvider {
    var localizedName: String {
        switch self {
        case .bottom: String(localized: "Bottom")
        case .top: String(localized: "Top")
        }
    }
}

extension AccelerationCurveType: LocalizedNameProvider {
    var localizedName: String {
        switch self {
        case .linear: String(localized: "Linear")
        case .quadratic: String(localized: "Quadratic")
        case .cubic: String(localized: "Cubic")
        case .ease: String(localized: "Ease")
        }
    }
}

extension CornerAction: LocalizedNameProvider {
    var localizedName: String {
        switch self {
        case .none: String(localized: "No Action")
        case .rightClick: String(localized: "Right Click")
        case .missionControl: String(localized: "Mission Control")
        case .appWindows: String(localized: "App Windows")
        case .showDesktop: String(localized: "Show Desktop")
        case .launchpad: String(localized: "Launchpad")
        case .notificationCenter: String(localized: "Notification Center")
        }
    }
}
