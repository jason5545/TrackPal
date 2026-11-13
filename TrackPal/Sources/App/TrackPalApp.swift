import SwiftUI
import TrackPalSystem

@main
struct TrackPalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopupView()
                .environment(appDelegate.runtime)
        } label: {
            Image(systemName: "hand.draw")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime = AppRuntime()

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime.logger.log("TrackPal starting")

        // 選單列 App：沒有 Dock 圖示，彈出視窗關掉後仍要繼續執行。
        NSApp.setActivationPolicy(.accessory)

        #if DEBUG
        if PopupSnapshot.writeIfRequested(runtime: runtime) {
            exit(0)
        }
        #endif

        if !runtime.isAccessibilityTrusted {
            requestAccessibilityPermission()
        } else if runtime.settings.isEnabled {
            runtime.start()
        }

        observeSystemWake()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        // 彈出視窗是唯一的視窗；關掉它不代表要結束。
        false
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // macOS 26 起，`.window` 樣式的 MenuBarExtra 關掉彈出視窗時 AppKit 會
        // 嘗試結束整個 App。那種結束不是使用者要的，一律取消；使用者按「結束」
        // 或系統（登出、關機、其他程式送的 quit 事件）要求時才放行。
        if runtime.isQuitRequested || Self.isQuitAppleEventInProgress {
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.stop()
        runtime.logger.flush()
    }

    private static var isQuitAppleEventInProgress: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return false
        }
        return event.eventClass == AEEventClass(kCoreEventClass)
            && event.eventID == AEEventID(kAEQuitApplication)
    }

    // MARK: - Wake recovery

    private func observeSystemWake() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                let reason = notification.name.rawValue
                MainActor.assumeIsolated {
                    self?.runtime.scheduleDeviceRestart(reason: reason)
                }
            }
        }
    }

    // MARK: - Accessibility permission

    private func requestAccessibilityPermission() {
        runtime.logger.log("Accessibility permission required")

        let alert = NSAlert()
        alert.messageText = String(localized: "Accessibility Permission Required")
        alert.informativeText = String(localized: "TrackPal needs accessibility permission to track trackpad input.\n\nPlease allow TrackPal in System Settings → Privacy & Security → Accessibility.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Later"))

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

#if DEBUG
/// 開發用：`TrackPal --snapshot <資料夾>` 把彈出視窗的主頁與設定頁畫成 PNG
/// 就結束，不註冊裝置、不建立 event tap，所以正式版在跑的時候也可以用。
/// 只存在於 Debug 版。毛玻璃背景在離屏繪製時不會有模糊效果，用來檢查版面與
/// 文字，不是檢查材質。
@MainActor
private enum PopupSnapshot {
    static func writeIfRequested(runtime: AppRuntime) -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"),
              index + 1 < arguments.count else {
            return false
        }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        for (name, showsSettings, height) in [
            ("popup-main", false, 330.0), ("popup-settings", true, 760.0),
        ] {
            let hosting = NSHostingView(
                rootView: MenuBarPopupView(initiallyShowingSettings: showsSettings)
                    .environment(runtime)
                    .frame(height: height, alignment: .top)
            )
            hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()

            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(
                in: hosting.bounds
            ) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(name).png"))
        }
        return true
    }
}
#endif
