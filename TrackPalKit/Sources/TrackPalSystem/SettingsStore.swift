import Foundation
import Observation
import ServiceManagement
import TrackPalCore

/// 開機自動啟動的開關。抽成 protocol 是為了讓測試不會真的去註冊登入項目。
@MainActor
public protocol LoginItemControlling {
    func setEnabled(_ enabled: Bool) throws
}

/// 用 `SMAppService.mainApp` 註冊登入項目。
public struct MainAppLoginItem: LoginItemControlling {
    public init() {}

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// 使用者設定：唯一的資料來源。
///
/// UI 直接綁這個物件的屬性；每次寫入都存進 `UserDefaults`，並把最新的
/// `ZoneScrollConfiguration` 交給 `onConfigurationChange`（App 把它接到
/// 狀態機）。key 與預設值跟舊版完全相同，既有使用者的設定不會變。
@MainActor
@Observable
public final class SettingsStore {
    enum Key {
        static let isEnabled = "isEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let middleClickEnabled = "middleClickEnabled"
        static let edgeZoneWidth = "edgeZoneWidth"
        static let bottomZoneHeight = "bottomZoneHeight"
        static let scrollMultiplier = "scrollMultiplier"
        static let verticalEdgeMode = "verticalEdgeMode"
        static let horizontalPosition = "horizontalPosition"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let accelerationCurveType = "accelerationCurveType"
        static let cornerTriggerEnabled = "cornerTriggerEnabled"
        static let cornerTriggerZoneSize = "cornerTriggerZoneSize"
        static let cornerActionTopLeft = "cornerActionTopLeft"
        static let cornerActionTopRight = "cornerActionTopRight"
        static let cornerActionBottomLeft = "cornerActionBottomLeft"
        static let cornerActionBottomRight = "cornerActionBottomRight"
        static let filterLightTouches = "filterLightTouches"
        static let filterLargeTouches = "filterLargeTouches"
        static let lightTouchDensityThreshold = "lightTouchDensityThreshold"
        static let largeTouchMajorAxisThreshold = "largeTouchMajorAxisThreshold"
        static let largeTouchMinorAxisThreshold = "largeTouchMinorAxisThreshold"
        static let enumRawValueMigration = "hasMigratedEnumRawValues_v3"
        static let obsoleteKeyCleanup = "hasRemovedObsoleteKeys_v1"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loginItem: any LoginItemControlling
    @ObservationIgnored private let log: (String) -> Void

    /// 任何會影響狀態機的設定改變時呼叫。
    @ObservationIgnored public var onConfigurationChange:
        ((ZoneScrollConfiguration) -> Void)?

    // MARK: - Settings

    public var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    public var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            updateLoginItem(launchAtLogin)
        }
    }

    public var middleClickEnabled: Bool {
        didSet { save(middleClickEnabled, Key.middleClickEnabled) }
    }

    /// 左右邊緣區寬度，0.05–0.30。
    public var edgeZoneWidth: Double {
        didSet { save(edgeZoneWidth, Key.edgeZoneWidth) }
    }

    /// 水平長條高度，0.10–0.40。
    public var bottomZoneHeight: Double {
        didSet { save(bottomZoneHeight, Key.bottomZoneHeight) }
    }

    /// 捲動靈敏度，1.0–10.0。
    public var scrollMultiplier: Double {
        didSet { save(scrollMultiplier, Key.scrollMultiplier) }
    }

    public var verticalEdgeMode: VerticalEdgeMode {
        didSet { save(verticalEdgeMode.rawValue, Key.verticalEdgeMode) }
    }

    public var horizontalPosition: HorizontalPosition {
        didSet { save(horizontalPosition.rawValue, Key.horizontalPosition) }
    }

    public var accelerationCurveType: AccelerationCurveType {
        didSet { save(accelerationCurveType.rawValue, Key.accelerationCurveType) }
    }

    public var cornerTriggerEnabled: Bool {
        didSet { save(cornerTriggerEnabled, Key.cornerTriggerEnabled) }
    }

    /// 角落區大小，0.05–0.25。
    public var cornerTriggerZoneSize: Double {
        didSet { save(cornerTriggerZoneSize, Key.cornerTriggerZoneSize) }
    }

    public var cornerActionTopLeft: CornerAction {
        didSet { save(cornerActionTopLeft.rawValue, Key.cornerActionTopLeft) }
    }

    public var cornerActionTopRight: CornerAction {
        didSet { save(cornerActionTopRight.rawValue, Key.cornerActionTopRight) }
    }

    public var cornerActionBottomLeft: CornerAction {
        didSet { save(cornerActionBottomLeft.rawValue, Key.cornerActionBottomLeft) }
    }

    public var cornerActionBottomRight: CornerAction {
        didSet { save(cornerActionBottomRight.rawValue, Key.cornerActionBottomRight) }
    }

    public var filterLightTouches: Bool {
        didSet { save(filterLightTouches, Key.filterLightTouches) }
    }

    public var filterLargeTouches: Bool {
        didSet { save(filterLargeTouches, Key.filterLargeTouches) }
    }

    public var lightTouchDensityThreshold: Float {
        didSet { save(lightTouchDensityThreshold, Key.lightTouchDensityThreshold) }
    }

    public var largeTouchMajorAxisThreshold: Float {
        didSet { save(largeTouchMajorAxisThreshold, Key.largeTouchMajorAxisThreshold) }
    }

    public var largeTouchMinorAxisThreshold: Float {
        didSet { save(largeTouchMinorAxisThreshold, Key.largeTouchMinorAxisThreshold) }
    }

    // MARK: - Init

    public init(
        defaults: UserDefaults = .standard,
        loginItem: any LoginItemControlling = MainAppLoginItem(),
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.defaults = defaults
        self.loginItem = loginItem
        self.log = log

        Self.migrateEnumRawValues(in: defaults, log: log)
        Self.removeObsoleteKeys(in: defaults)

        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        func double(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) as? Double ?? fallback
        }
        func float(_ key: String, _ fallback: Float) -> Float {
            defaults.object(forKey: key) as? Float ?? fallback
        }
        func choice<Value: RawRepresentable>(
            _ key: String, _ fallback: Value
        ) -> Value where Value.RawValue == String {
            guard let raw = defaults.string(forKey: key),
                  let value = Value(rawValue: raw) else {
                return fallback
            }
            return value
        }

        // 第一次啟動時所有功能預設開啟。
        isEnabled = bool(Key.isEnabled, true)
        launchAtLogin = bool(Key.launchAtLogin, true)
        middleClickEnabled = bool(Key.middleClickEnabled, true)
        edgeZoneWidth = double(Key.edgeZoneWidth, 0.15)
        bottomZoneHeight = double(Key.bottomZoneHeight, 0.30)
        scrollMultiplier = double(Key.scrollMultiplier, 3.0)
        verticalEdgeMode = choice(Key.verticalEdgeMode, .right)
        horizontalPosition = choice(Key.horizontalPosition, .bottom)
        accelerationCurveType = choice(Key.accelerationCurveType, .linear)
        cornerTriggerEnabled = bool(Key.cornerTriggerEnabled, false)
        cornerTriggerZoneSize = double(Key.cornerTriggerZoneSize, 0.15)
        cornerActionTopLeft = choice(Key.cornerActionTopLeft, CornerAction.none)
        cornerActionTopRight = choice(Key.cornerActionTopRight, CornerAction.none)
        cornerActionBottomLeft = choice(Key.cornerActionBottomLeft, CornerAction.none)
        cornerActionBottomRight = choice(Key.cornerActionBottomRight, .rightClick)
        filterLightTouches = bool(Key.filterLightTouches, true)
        filterLargeTouches = bool(Key.filterLargeTouches, true)
        lightTouchDensityThreshold = float(Key.lightTouchDensityThreshold, 0.02)
        largeTouchMajorAxisThreshold = float(Key.largeTouchMajorAxisThreshold, 15.0)
        largeTouchMinorAxisThreshold = float(Key.largeTouchMinorAxisThreshold, 12.0)

        if !defaults.bool(forKey: Key.hasLaunchedBefore) {
            defaults.set(true, forKey: Key.hasLaunchedBefore)
            // Enable launch at login on first run
            updateLoginItem(true)
            log("First launch - enabling launch at login")
        }
    }

    // MARK: - Configuration

    /// 目前設定對應的狀態機設定。
    public var configuration: ZoneScrollConfiguration {
        var configuration = ZoneScrollConfiguration()
        configuration.edgeZoneWidth = CGFloat(edgeZoneWidth)
        configuration.bottomZoneHeight = CGFloat(bottomZoneHeight)
        configuration.scrollMultiplier = CGFloat(scrollMultiplier)
        configuration.verticalEdgeMode = verticalEdgeMode
        configuration.horizontalPosition = horizontalPosition
        configuration.middleClickEnabled = middleClickEnabled
        configuration.accelerationCurveType = accelerationCurveType
        configuration.cornerTriggerEnabled = cornerTriggerEnabled
        configuration.cornerTriggerZoneSize = CGFloat(cornerTriggerZoneSize)
        configuration.cornerActions = CornerActions(
            topLeft: cornerActionTopLeft,
            topRight: cornerActionTopRight,
            bottomLeft: cornerActionBottomLeft,
            bottomRight: cornerActionBottomRight
        )
        configuration.filterLightTouches = filterLightTouches
        configuration.filterLargeTouches = filterLargeTouches
        configuration.lightTouchDensityThreshold = lightTouchDensityThreshold
        configuration.largeTouchMajorAxisThreshold = largeTouchMajorAxisThreshold
        configuration.largeTouchMinorAxisThreshold = largeTouchMinorAxisThreshold
        return configuration
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onConfigurationChange?(configuration)
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            log("Launch at login \(enabled ? "enabled" : "disabled")")
        } catch {
            log("Failed to update launch at login: \(error)")
        }
    }

    // MARK: - Migrations

    /// 舊版把列舉存成中文顯示名稱，換成英文識別字。
    private static func migrateEnumRawValues(
        in defaults: UserDefaults, log: (String) -> Void
    ) {
        guard !defaults.bool(forKey: Key.enumRawValueMigration) else { return }

        let verticalEdgeMap = ["左側": "left", "右側": "right", "雙側": "both"]
        let horizontalPositionMap = ["下方": "bottom", "上方": "top"]
        let accelerationCurveMap = [
            "線性": "linear", "二次": "quadratic", "三次": "cubic", "緩動": "ease",
        ]
        let cornerActionMap = [
            "無動作": "none", "Mission Control": "missionControl",
            "應用程式視窗": "appWindows", "顯示桌面": "showDesktop",
            "啟動台": "launchpad", "通知中心": "notificationCenter",
            "右鍵": "rightClick",
        ]

        func migrate(_ key: String, _ map: [String: String]) {
            if let old = defaults.string(forKey: key), let new = map[old] {
                defaults.set(new, forKey: key)
            }
        }

        migrate(Key.verticalEdgeMode, verticalEdgeMap)
        migrate(Key.horizontalPosition, horizontalPositionMap)
        migrate(Key.accelerationCurveType, accelerationCurveMap)
        migrate(Key.cornerActionTopLeft, cornerActionMap)
        migrate(Key.cornerActionTopRight, cornerActionMap)
        migrate(Key.cornerActionBottomLeft, cornerActionMap)
        migrate(Key.cornerActionBottomRight, cornerActionMap)

        // Preserve previous behavior from old builds where bottom-right
        // No Action was overloaded as right-click.
        if defaults.string(forKey: Key.cornerActionBottomRight) == nil
            || defaults.string(forKey: Key.cornerActionBottomRight)
                == CornerAction.none.rawValue {
            defaults.set(
                CornerAction.rightClick.rawValue,
                forKey: Key.cornerActionBottomRight
            )
        }

        defaults.set(true, forKey: Key.enumRawValueMigration)
        log("Enum raw value migration completed")
    }

    /// 2026-07 移除的自我調整機制留下的 key，已經沒有任何程式讀。
    private static func removeObsoleteKeys(in defaults: UserDefaults) {
        guard !defaults.bool(forKey: Key.obsoleteKeyCleanup) else { return }
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("adaptive_") {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: Key.obsoleteKeyCleanup)
    }
}
