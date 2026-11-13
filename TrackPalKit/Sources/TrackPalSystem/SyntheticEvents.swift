import CoreGraphics

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

    /// 建立一筆逐像素的捲動事件（不送出）。
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
    /// **設定的順序不能調換：行位移 → fixedPt → 最後才是像素位移。**
    /// 2026-11-13 在 macOS 27.2 上逐步讀回欄位：設定行位移（`deltaAxis1/2`）
    /// 時，系統會把像素位移（`pointDeltaAxis1/2`，`NSEvent.scrollingDeltaY/X`
    /// 讀的那一欄）重算成「行位移 × 8」。舊版先設像素再設行位移，結果 App
    /// 收到的像素永遠是 8 的倍數（1–19 px 一律變 8）。像素放到最後設定，三個
    /// 欄位才會各自是指定的值。`SyntheticEventsTests` 把讀回來的數值釘住。
    ///
    /// - Parameters:
    ///   - lineX, lineY: 行單位的位移，給只讀行位移的 App；可以是 0。由
    ///     `LineDeltaAccumulator` 從像素累加而來。
    public static func makeScrollEvent(
        deltaX: Int32,
        deltaY: Int32,
        lineX: Int32,
        lineY: Int32
    ) -> CGEvent? {
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

        event.setIntegerValueField(.eventSourceUserData, value: signature)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // axis1 是垂直、axis2 是水平。
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(lineY))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(lineX))
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
        event.setIntegerValueField(
            .scrollWheelEventPointDeltaAxis1, value: Int64(deltaY)
        )
        event.setIntegerValueField(
            .scrollWheelEventPointDeltaAxis2, value: Int64(deltaX)
        )
        return event
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

    /// 建立單一個滑鼠按鍵事件（不送出）。只用在把攔下來的原生 down 或 up
    /// 單獨補送回去；一般的點擊請用成對的 `makeMousePair`。
    public static func makeMouseEvent(
        type: CGEventType,
        at location: CGPoint,
        button: CGMouseButton,
        flags: CGEventFlags = [],
        clickState: Int64 = 1
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .combinedSessionState),
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: button
        ) else {
            return nil
        }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.setIntegerValueField(.eventSourceUserData, value: signature)
        return event
    }

    @discardableResult
    public static func postMouseEvent(
        type: CGEventType,
        at location: CGPoint,
        button: CGMouseButton,
        flags: CGEventFlags = [],
        clickState: Int64 = 1
    ) -> Bool {
        guard let event = makeMouseEvent(
            type: type,
            at: location,
            button: button,
            flags: flags,
            clickState: clickState
        ) else {
            return false
        }
        event.post(tap: .cghidEventTap)
        return true
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
