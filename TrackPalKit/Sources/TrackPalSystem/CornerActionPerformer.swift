import AppKit
import TrackPalCore

// Private CoreDock API（Mission Control、App 視窗、顯示桌面）。
@_silgen_name("CoreDockSendNotification")
private func CoreDockSendNotification(
    _ notification: CFString, _ unknown: UnsafeMutableRawPointer?
)

/// 角落壓力動作實際對系統做的事。
@MainActor
public enum CornerActionPerformer {
    public static func perform(_ action: CornerAction) {
        switch action {
        case .none:
            break

        case .rightClick:
            guard let location = pointerLocation() else { return }
            SyntheticEvents.postMousePair(
                downType: .rightMouseDown,
                upType: .rightMouseUp,
                at: location,
                button: .right
            )

        case .missionControl:
            CoreDockSendNotification("com.apple.expose.awake" as CFString, nil)

        case .appWindows:
            CoreDockSendNotification("com.apple.expose.front.awake" as CFString, nil)

        case .showDesktop:
            CoreDockSendNotification("com.apple.showdesktop.awake" as CFString, nil)

        case .launchpad:
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/Launchpad.app")
            )

        case .notificationCenter:
            // 點主螢幕右上角的時鐘。
            guard let screen = NSScreen.main else { return }
            SyntheticEvents.postMousePair(
                downType: .leftMouseDown,
                upType: .leftMouseUp,
                at: CGPoint(x: screen.frame.maxX - 20, y: 12),
                button: .left
            )
        }
    }

    /// 游標位置，全域螢幕座標。直接問 Quartz；問不到才用 AppKit 的座標換算
    /// （原點在主螢幕左下角，要對主螢幕的高度翻轉）。
    static func pointerLocation() -> CGPoint? {
        if let location = SyntheticEvents.pointerLocation() {
            return location
        }
        guard let primary = NSScreen.screens.first else { return nil }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x, y: primary.frame.height - mouse.y)
    }
}
