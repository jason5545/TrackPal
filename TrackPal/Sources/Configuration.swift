import Foundation

/// User configuration and preferences
@MainActor
final class Configuration {

    static let shared = Configuration()

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let scrollMultiplier = "scrollMultiplier"
        static let enableInertia = "enableInertia"
        static let smoothScrolling = "smoothScrolling"
        static let launchAtLogin = "launchAtLogin"
        static let friction = "friction"
        static let disabledApps = "disabledApps"
    }

    // MARK: - Properties

    var scrollMultiplier: CGFloat {
        get { CGFloat(defaults.double(forKey: Keys.scrollMultiplier).nonZero ?? 1.5) }
        set {
            defaults.set(Double(newValue), forKey: Keys.scrollMultiplier)
            ScrollManager.shared.scrollMultiplier = newValue
        }
    }

    var enableInertia: Bool {
        get { defaults.bool(forKey: Keys.enableInertia) }
        set {
            defaults.set(newValue, forKey: Keys.enableInertia)
            ScrollManager.shared.enableInertia = newValue
        }
    }

    var smoothScrolling: Bool {
        get { defaults.bool(forKey: Keys.smoothScrolling) }
        set {
            defaults.set(newValue, forKey: Keys.smoothScrolling)
            ScrollManager.shared.smoothScrolling = newValue
        }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    var friction: CGFloat {
        get { CGFloat(defaults.double(forKey: Keys.friction).nonZero ?? 0.95) }
        set {
            defaults.set(Double(newValue), forKey: Keys.friction)
            InertiaScroller.shared.friction = newValue
        }
    }

    var disabledApps: [String] {
        get { defaults.stringArray(forKey: Keys.disabledApps) ?? [] }
        set { defaults.set(newValue, forKey: Keys.disabledApps) }
    }

    // MARK: - Init

    private init() {
        registerDefaults()
        applyConfiguration()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.scrollMultiplier: 1.5,
            Keys.enableInertia: true,
            Keys.smoothScrolling: true,
            Keys.launchAtLogin: false,
            Keys.friction: 0.95,
            Keys.disabledApps: [] as [String]
        ])
    }

    private func applyConfiguration() {
        ScrollManager.shared.scrollMultiplier = scrollMultiplier
        ScrollManager.shared.enableInertia = enableInertia
        ScrollManager.shared.smoothScrolling = smoothScrolling
        InertiaScroller.shared.friction = friction
    }

    // MARK: - App-specific Settings

    func isAppDisabled(_ bundleIdentifier: String) -> Bool {
        disabledApps.contains(bundleIdentifier)
    }

    func setApp(_ bundleIdentifier: String, disabled: Bool) {
        var apps = disabledApps
        if disabled {
            if !apps.contains(bundleIdentifier) {
                apps.append(bundleIdentifier)
            }
        } else {
            apps.removeAll { $0 == bundleIdentifier }
        }
        disabledApps = apps
    }
}

// MARK: - Helpers

private extension Double {
    var nonZero: Double? {
        self == 0 ? nil : self
    }
}
