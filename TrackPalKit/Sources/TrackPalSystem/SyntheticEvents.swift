import CoreGraphics
import TrackPalCore

/// TrackPal 自己合成的 CGEvent：捲動與成對的滑鼠按鍵。
///
/// 每個事件都在 `eventSourceUserData` 蓋上 `signature`，event tap 靠它認出
/// 自己送的事件、不會再攔一次。
public enum SyntheticEvents {
    /// "TRPL"
    public static let signature: Int64 = 0x5452_504C

    public static func isOwnEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == signature
    }

    /// 建立一筆捲動事件（不送出）。
    ///
    /// 欄位的填法是對著原生 Cocoa App（預覽程式、Finder）與 Mac Catalyst App
    /// 實測出來的，它們比 Chrome、終端機挑剔：
    /// - `isContinuous = 1`：標成觸控板式捲動，`NSEvent` 才會給精確位移。
    /// - scroll phase 與 momentum phase 一律 0：只要 phase 是 began，
    ///   `NSScrollView` 會啟動 responsive scrolling 的追蹤迴圈，那個迴圈會把
    ///   `CGEvent.post` 送進來的合成事件默默丟掉。phase 留 0，每筆事件各自
    ///   獨立處理。
    /// - `fixedPtDeltaAxis1/2 = 0`。
    ///
    /// **設定的順序不能調換。** 2026-11-13 在 macOS 27.2 上逐步讀回欄位：
    /// 設定行位移（`deltaAxis1/2`）時，系統會把像素位移（`pointDeltaAxis1/2`，
    /// `NSEvent.scrollingDeltaY/X` 讀的那一欄）重算成「行位移 × 8」，蓋掉前面
    /// 設的值。所以 App 實際收到的像素位移是 8 的倍數：傳進來 1–19 px 變成
    /// 8，20–29 變成 16，42 變成 32。目前的捲動手感（包含使用者調好的靈敏度）
    /// 建立在這個結果上。把 `pointDeltaAxis` 移到最後設定就會變成真正逐像素，
    /// 但捲動量會差到數倍，靈敏度要重新調：那是手感上的改變，不是重構。
    /// `SyntheticEventsTests` 把目前的數值釘住，並跟舊版的建構方式逐欄比對。
    public static func makeScrollEvent(deltaX: Int32, deltaY: Int32) -> CGEvent? {
        // `.combinedSessionState` 才有正確的事件路由；nil 在部分原生 App 有問題。
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return nil }

        let deltas = ScrollWheelDeltas(pixelX: deltaX, pixelY: deltaY)
        event.setIntegerValueField(.eventSourceUserData, value: signature)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(
            .scrollWheelEventPointDeltaAxis1, value: Int64(deltas.pixelY)
        )
        event.setIntegerValueField(
            .scrollWheelEventPointDeltaAxis2, value: Int64(deltas.pixelX)
        )
        if deltas.pixelY != 0 {
            event.setIntegerValueField(
                .scrollWheelEventDeltaAxis1, value: Int64(deltas.lineY)
            )
        }
        if deltas.pixelX != 0 {
            event.setIntegerValueField(
                .scrollWheelEventDeltaAxis2, value: Int64(deltas.lineX)
            )
        }
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
        return event
    }

    @discardableResult
    public static func postScroll(deltaX: Int32, deltaY: Int32) -> Bool {
        guard let event = makeScrollEvent(deltaX: deltaX, deltaY: deltaY) else {
            return false
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    /// 建立一組 down／up（不送出）。兩個都建得出來才回傳，避免只送出單邊。
    public static func makeMousePair(
        downType: CGEventType,
        upType: CGEventType,
        at location: CGPoint,
        button: CGMouseButton,
        flags: CGEventFlags = [],
        clickState: Int64 = 1
    ) -> (down: CGEvent, up: CGEvent)? {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(
            mouseEventSource: source,
            mouseType: downType,
            mouseCursorPosition: location,
            mouseButton: button
        ), let up = CGEvent(
            mouseEventSource: source,
            mouseType: upType,
            mouseCursorPosition: location,
            mouseButton: button
        ) else {
            return nil
        }

        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
            event.setIntegerValueField(.eventSourceUserData, value: signature)
        }
        return (down, up)
    }

    @discardableResult
    public static func postMousePair(
        downType: CGEventType,
        upType: CGEventType,
        at location: CGPoint,
        button: CGMouseButton,
        flags: CGEventFlags = [],
        clickState: Int64 = 1
    ) -> Bool {
        guard let pair = makeMousePair(
            downType: downType,
            upType: upType,
            at: location,
            button: button,
            flags: flags,
            clickState: clickState
        ) else {
            return false
        }
        pair.down.post(tap: .cghidEventTap)
        pair.up.post(tap: .cghidEventTap)
        return true
    }

    /// 游標目前的位置（全域螢幕座標，原點在主螢幕左上角）。
    public static func pointerLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }
}
