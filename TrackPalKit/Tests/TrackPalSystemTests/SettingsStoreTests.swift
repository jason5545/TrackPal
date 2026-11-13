import Foundation
import Testing
import TrackPalCore
@testable import TrackPalSystem

@MainActor
private final class FakeLoginItem: LoginItemControlling {
    var calls: [Bool] = []
    var error: (any Error)?

    func setEnabled(_ enabled: Bool) throws {
        calls.append(enabled)
        if let error { throw error }
    }
}

private struct LoginItemFailure: Error {}

/// 每個測試用自己的 UserDefaults suite，不碰真正的設定。
@MainActor
@Suite("設定儲存")
struct SettingsStoreTests {
    private let suiteName = "trackpal-tests-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let loginItem = FakeLoginItem()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults, loginItem: loginItem)
    }

    @Test("第一次啟動的預設值，並且登記開機自動啟動")
    func firstLaunchDefaults() {
        defer { cleanUp() }
        let store = makeStore()

        #expect(store.isEnabled)
        #expect(store.launchAtLogin)
        #expect(store.middleClickEnabled)
        #expect(store.edgeZoneWidth == 0.15)
        #expect(store.bottomZoneHeight == 0.30)
        #expect(store.scrollMultiplier == 3.0)
        #expect(store.verticalEdgeMode == .right)
        #expect(store.horizontalPosition == .bottom)
        #expect(store.accelerationCurveType == .linear)
        #expect(!store.cornerTriggerEnabled)
        #expect(store.cornerTriggerZoneSize == 0.15)
        #expect(store.cornerActionBottomRight == .rightClick)
        #expect(store.cornerActionTopLeft == CornerAction.none)
        #expect(store.filterLightTouches && store.filterLargeTouches)
        #expect(store.lightTouchDensityThreshold == 0.02)
        #expect(store.largeTouchMajorAxisThreshold == 15)
        #expect(store.largeTouchMinorAxisThreshold == 12)

        #expect(loginItem.calls == [true])
        #expect(defaults.bool(forKey: "hasLaunchedBefore"))
    }

    @Test("第二次啟動不會再動登入項目")
    func secondLaunchLeavesLoginItemAlone() {
        defer { cleanUp() }
        _ = makeStore()
        loginItem.calls.removeAll()
        _ = makeStore()
        #expect(loginItem.calls.isEmpty)
    }

    @Test("改過的設定下次啟動還在（key 與舊版相同）")
    func persistsAcrossInstances() {
        defer { cleanUp() }
        let store = makeStore()
        store.isEnabled = false
        store.edgeZoneWidth = 0.1302
        store.bottomZoneHeight = 0.1647
        store.scrollMultiplier = 1
        store.verticalEdgeMode = .both
        store.horizontalPosition = .top
        store.accelerationCurveType = .ease
        store.cornerTriggerEnabled = true
        store.cornerTriggerZoneSize = 0.0684
        store.cornerActionTopLeft = .showDesktop
        store.middleClickEnabled = false
        store.filterLargeTouches = false
        store.largeTouchMajorAxisThreshold = 18.5

        // 舊版讀寫的就是這些 key 與型別。
        #expect(defaults.double(forKey: "edgeZoneWidth") == 0.1302)
        #expect(defaults.string(forKey: "verticalEdgeMode") == "both")
        #expect(defaults.string(forKey: "cornerActionTopLeft") == "showDesktop")
        #expect(defaults.object(forKey: "isEnabled") as? Bool == false)

        let reloaded = makeStore()
        #expect(!reloaded.isEnabled)
        #expect(reloaded.edgeZoneWidth == 0.1302)
        #expect(reloaded.bottomZoneHeight == 0.1647)
        #expect(reloaded.scrollMultiplier == 1)
        #expect(reloaded.verticalEdgeMode == .both)
        #expect(reloaded.horizontalPosition == .top)
        #expect(reloaded.accelerationCurveType == .ease)
        #expect(reloaded.cornerTriggerEnabled)
        #expect(reloaded.cornerTriggerZoneSize == 0.0684)
        #expect(reloaded.cornerActionTopLeft == .showDesktop)
        #expect(!reloaded.middleClickEnabled)
        #expect(!reloaded.filterLargeTouches)
        #expect(reloaded.largeTouchMajorAxisThreshold == 18.5)
    }

    @Test("設定對應到狀態機的設定")
    func configurationMapping() {
        defer { cleanUp() }
        let store = makeStore()
        store.edgeZoneWidth = 0.2
        store.cornerTriggerEnabled = true
        store.cornerActionBottomLeft = .launchpad
        store.accelerationCurveType = .cubic

        let configuration = store.configuration
        #expect(configuration.edgeZoneWidth == 0.2)
        #expect(configuration.bottomZoneHeight == 0.30)
        #expect(configuration.middleClickEnabled)
        #expect(configuration.cornerTriggerEnabled)
        #expect(configuration.cornerActions == CornerActions(bottomLeft: .launchpad, bottomRight: .rightClick))
        #expect(configuration.accelerationCurveType == .cubic)
        #expect(configuration.lightTouchDensityThreshold == 0.02)
    }

    @Test("影響狀態機的設定一改就通知；總開關與開機啟動不通知")
    func notifiesOnConfigurationChange() {
        defer { cleanUp() }
        let store = makeStore()
        var received: [ZoneScrollConfiguration] = []
        store.onConfigurationChange = { received.append($0) }

        store.scrollMultiplier = 5
        store.verticalEdgeMode = .left
        #expect(received.count == 2)
        #expect(received.last?.scrollMultiplier == 5)
        #expect(received.last?.verticalEdgeMode == .left)

        store.isEnabled = false
        store.launchAtLogin = false
        #expect(received.count == 2)
    }

    @Test("切換開機自動啟動會呼叫登入項目；失敗時設定值照樣記住")
    func launchAtLoginToggles() {
        defer { cleanUp() }
        let store = makeStore()
        loginItem.calls.removeAll()

        store.launchAtLogin = false
        store.launchAtLogin = true
        #expect(loginItem.calls == [false, true])

        loginItem.error = LoginItemFailure()
        store.launchAtLogin = false
        #expect(!store.launchAtLogin)
        #expect(defaults.object(forKey: "launchAtLogin") as? Bool == false)
    }

    @Test("舊版用中文存的列舉值會轉成英文識別字")
    func migratesChineseRawValues() {
        defer { cleanUp() }
        defaults.set("雙側", forKey: "verticalEdgeMode")
        defaults.set("上方", forKey: "horizontalPosition")
        defaults.set("三次", forKey: "accelerationCurveType")
        defaults.set("顯示桌面", forKey: "cornerActionTopLeft")
        defaults.set("無動作", forKey: "cornerActionBottomRight")

        let store = makeStore()
        #expect(store.verticalEdgeMode == .both)
        #expect(store.horizontalPosition == .top)
        #expect(store.accelerationCurveType == .cubic)
        #expect(store.cornerActionTopLeft == .showDesktop)
        // 舊版的右下角「無動作」其實是右鍵，轉換時保留原本的行為。
        #expect(store.cornerActionBottomRight == .rightClick)
        #expect(defaults.string(forKey: "verticalEdgeMode") == "both")
        #expect(defaults.bool(forKey: "hasMigratedEnumRawValues_v3"))
    }

    @Test("轉換只做一次：之後使用者把右下角設成無動作，不會被改回去")
    func migrationRunsOnce() {
        defer { cleanUp() }
        let store = makeStore()
        store.cornerActionBottomRight = .none

        #expect(makeStore().cornerActionBottomRight == CornerAction.none)
    }

    @Test("認不得的列舉值退回預設值")
    func unknownRawValuesFallBack() {
        defer { cleanUp() }
        defaults.set(true, forKey: "hasMigratedEnumRawValues_v3")
        defaults.set("diagonal", forKey: "verticalEdgeMode")
        defaults.set("teleport", forKey: "cornerActionTopRight")

        let store = makeStore()
        #expect(store.verticalEdgeMode == .right)
        #expect(store.cornerActionTopRight == CornerAction.none)
    }

    @Test("清掉已移除功能留下的 key，其他設定不動")
    func removesObsoleteKeys() {
        defer { cleanUp() }
        defaults.set(0.55, forKey: "adaptive_dirCenterH")
        defaults.set(154, forKey: "adaptive_missCountH")
        defaults.set(1.0, forKey: "scrollMultiplier")

        let store = makeStore()
        #expect(defaults.object(forKey: "adaptive_dirCenterH") == nil)
        #expect(defaults.object(forKey: "adaptive_missCountH") == nil)
        #expect(store.scrollMultiplier == 1.0)
    }
}
