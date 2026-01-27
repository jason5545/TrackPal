// TrackPal/TrackPalApp.swift
import SwiftUI
import ServiceManagement

@main
struct TrackPalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopupView()
        } label: {
            Image(systemName: "hand.draw")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App Delegate for setup

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("TrackPal: Starting...")

        // Load saved settings
        Settings.shared.loadSettings()

        // Request accessibility permission if needed
        if !isAccessibilityEnabled() {
            requestAccessibilityPermission()
        } else {
            // Auto-start zone scrolling if enabled (default: true)
            if Settings.shared.isEnabled {
                TrackpadZoneScroller.shared.start()
                NSLog("TrackPal: Zone scrolling auto-started")
            }
        }

        NSLog("TrackPal: Ready")
    }

    nonisolated func isAccessibilityEnabled() -> Bool {
        return AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        NSLog("TrackPal: Accessibility permission required")

        let alert = NSAlert()
        alert.messageText = "需要輔助功能權限"
        alert.informativeText = "TrackPal 需要輔助功能權限才能追蹤觸控板輸入。\n\n請在「系統設定 → 隱私權與安全性 → 輔助功能」中允許 TrackPal。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "開啟系統設定")
        alert.addButton(withTitle: "稍後")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Settings Manager

@MainActor
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    // Keys
    private enum Keys {
        static let isEnabled = "isEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let middleClickEnabled = "middleClickEnabled"
        static let edgeZoneWidth = "edgeZoneWidth"
        static let bottomZoneHeight = "bottomZoneHeight"
        static let scrollMultiplier = "scrollMultiplier"
        static let verticalEdgeMode = "verticalEdgeMode"
        static let horizontalPosition = "horizontalPosition"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }

    // Properties with defaults (all features enabled by default)
    var isEnabled: Bool {
        get { defaults.object(forKey: Keys.isEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.isEnabled) }
    }

    var launchAtLogin: Bool {
        get { defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            updateLaunchAtLogin(newValue)
        }
    }

    var middleClickEnabled: Bool {
        get { defaults.object(forKey: Keys.middleClickEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.middleClickEnabled) }
    }

    var edgeZoneWidth: CGFloat {
        get { CGFloat(defaults.object(forKey: Keys.edgeZoneWidth) as? Double ?? 0.15) }
        set { defaults.set(Double(newValue), forKey: Keys.edgeZoneWidth) }
    }

    var bottomZoneHeight: CGFloat {
        get { CGFloat(defaults.object(forKey: Keys.bottomZoneHeight) as? Double ?? 0.20) }
        set { defaults.set(Double(newValue), forKey: Keys.bottomZoneHeight) }
    }

    var scrollMultiplier: CGFloat {
        get { CGFloat(defaults.object(forKey: Keys.scrollMultiplier) as? Double ?? 3.0) }
        set { defaults.set(Double(newValue), forKey: Keys.scrollMultiplier) }
    }

    var verticalEdgeMode: TrackpadZoneScroller.VerticalEdgeMode {
        get {
            guard let raw = defaults.string(forKey: Keys.verticalEdgeMode),
                  let mode = TrackpadZoneScroller.VerticalEdgeMode(rawValue: raw) else {
                return .right
            }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.verticalEdgeMode) }
    }

    var horizontalPosition: TrackpadZoneScroller.HorizontalPosition {
        get {
            guard let raw = defaults.string(forKey: Keys.horizontalPosition),
                  let pos = TrackpadZoneScroller.HorizontalPosition(rawValue: raw) else {
                return .bottom
            }
            return pos
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.horizontalPosition) }
    }

    private init() {}

    func loadSettings() {
        let scroller = TrackpadZoneScroller.shared

        // Check if first launch - set up defaults
        if !defaults.bool(forKey: Keys.hasLaunchedBefore) {
            defaults.set(true, forKey: Keys.hasLaunchedBefore)
            // Enable launch at login on first run
            updateLaunchAtLogin(true)
            NSLog("TrackPal: First launch - enabling launch at login")
        }

        // Apply saved settings to scroller
        scroller.middleClickEnabled = middleClickEnabled
        scroller.edgeZoneWidth = edgeZoneWidth
        scroller.bottomZoneHeight = bottomZoneHeight
        scroller.scrollMultiplier = scrollMultiplier
        scroller.verticalEdgeMode = verticalEdgeMode
        scroller.horizontalPosition = horizontalPosition

        NSLog("TrackPal: Settings loaded - enabled=\(isEnabled), middleClick=\(middleClickEnabled), launchAtLogin=\(launchAtLogin)")
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                NSLog("TrackPal: Launch at login enabled")
            } else {
                try SMAppService.mainApp.unregister()
                NSLog("TrackPal: Launch at login disabled")
            }
        } catch {
            NSLog("TrackPal: Failed to update launch at login: \(error)")
        }
    }
}
