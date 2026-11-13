import CoreGraphics
import Testing
import TrackPalCore
@testable import TrackPalSystem

/// 合成事件的欄位。這些數值是對著原生 Cocoa App 實測出來的，少一欄或 phase
/// 不是 0，預覽程式、Finder、Catalyst App 就會捲不動。
@Suite("合成的 CGEvent")
struct SyntheticEventsTests {
    @Test("CGEventField 的編號沒有變")
    func fieldNumbers() {
        #expect(CGEventField.scrollWheelEventDeltaAxis1.rawValue == 11)
        #expect(CGEventField.scrollWheelEventDeltaAxis2.rawValue == 12)
        #expect(CGEventField.scrollWheelEventIsContinuous.rawValue == 88)
        #expect(CGEventField.scrollWheelEventFixedPtDeltaAxis1.rawValue == 93)
        #expect(CGEventField.scrollWheelEventFixedPtDeltaAxis2.rawValue == 94)
        #expect(CGEventField.scrollWheelEventPointDeltaAxis1.rawValue == 96)
        #expect(CGEventField.scrollWheelEventPointDeltaAxis2.rawValue == 97)
        #expect(CGEventField.scrollWheelEventScrollPhase.rawValue == 99)
        #expect(CGEventField.scrollWheelEventMomentumPhase.rawValue == 123)
    }

    @Test("簽章是 TRPL")
    func signature() {
        #expect(SyntheticEvents.signature == 0x5452_504C)
        let bytes = withUnsafeBytes(of: UInt32(SyntheticEvents.signature).bigEndian) { Array($0) }
        #expect(String(decoding: bytes, as: UTF8.self) == "TRPL")
    }

    @Test("捲動事件：連續捲動標記、phase 全部是 0、行位移、蓋上簽章")
    func scrollEventFields() throws {
        let event = try #require(SyntheticEvents.makeScrollEvent(deltaX: -42, deltaY: 7))

        #expect(event.type == .scrollWheel)
        #expect(SyntheticEvents.isOwnEvent(event))
        #expect(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
        // axis1 是垂直、axis2 是水平。
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 1)
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis2) == -4)
        #expect(event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0)
    }

    /// 這是目前出貨的行為，不是理想值：設定行位移時系統把像素位移重算成
    /// 「行位移 × 8」。捲動手感建立在這組數值上，見 `makeScrollEvent` 的說明。
    @Test("App 實際收到的像素位移 = 行位移 × 8", arguments: [
        (Int32(1), Int64(8)), (9, 8), (19, 8), (20, 16), (42, 32), (100, 80),
        (-1, -8), (-25, -16), (0, 0),
    ])
    func deliveredPointDeltaIsQuantized(pixels: Int32, delivered: Int64) throws {
        let vertical = try #require(SyntheticEvents.makeScrollEvent(deltaX: 0, deltaY: pixels))
        #expect(vertical.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == delivered)
        #expect(vertical.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0)

        let horizontal = try #require(SyntheticEvents.makeScrollEvent(deltaX: pixels, deltaY: 0))
        #expect(horizontal.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == delivered)
        #expect(horizontal.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0)
    }

    /// 重構前 `TrackpadZoneScroller.postScrollEvent` 的建構方式，逐字保留。
    private func legacyScrollEvent(deltaX: Int32, deltaY: Int32) -> CGEvent? {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
            wheel1: deltaY, wheel2: deltaX, wheel3: 0
        ) else { return nil }
        event.setIntegerValueField(.eventSourceUserData, value: 0x5452504C)
        event.setIntegerValueField(CGEventField(rawValue: 99)!, value: 0)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: 0)
        event.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(deltaY))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(deltaX))
        if deltaY != 0 {
            let lineDY = deltaY > 0 ? max(Int32(1), deltaY / 10) : min(Int32(-1), deltaY / 10)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(lineDY))
        }
        if deltaX != 0 {
            let lineDX = deltaX > 0 ? max(Int32(1), deltaX / 10) : min(Int32(-1), deltaX / 10)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(lineDX))
        }
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
        return event
    }

    @Test("每一個欄位都跟重構前建構出來的事件相同")
    func matchesLegacyConstructionFieldByField() throws {
        let fields: [CGEventField] = [
            .eventSourceUserData,
            .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3,
            .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
            .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
            .scrollWheelEventIsContinuous, .scrollWheelEventScrollPhase,
            .scrollWheelEventMomentumPhase, .scrollWheelEventScrollCount,
            .scrollWheelEventInstantMouser,
        ]
        let values: [Int32] = [-250, -42, -20, -19, -10, -9, -1, 0, 1, 2, 7, 9, 10, 11, 19, 20, 99, 300]
        for deltaX in values {
            for deltaY in values {
                let current = try #require(SyntheticEvents.makeScrollEvent(deltaX: deltaX, deltaY: deltaY))
                let legacy = try #require(legacyScrollEvent(deltaX: deltaX, deltaY: deltaY))
                #expect(current.type == legacy.type)
                for field in fields {
                    #expect(
                        current.getIntegerValueField(field) == legacy.getIntegerValueField(field),
                        "(\(deltaX), \(deltaY)) 欄位 \(field.rawValue)"
                    )
                }
            }
        }
    }

    @Test("零位移的捲動事件（慣性結束時送的那一筆）也建得出來")
    func zeroDeltaScrollEvent() throws {
        let event = try #require(SyntheticEvents.makeScrollEvent(deltaX: 0, deltaY: 0))
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
    }

    @Test("滑鼠按鍵成對建立：位置、修飾鍵、clickState 兩邊一致，都有簽章")
    func mousePair() throws {
        let location = CGPoint(x: 321, y: 654)
        let pair = try #require(SyntheticEvents.makeMousePair(
            downType: .leftMouseDown,
            upType: .leftMouseUp,
            at: location,
            button: .left,
            flags: .maskCommand,
            clickState: 2
        ))

        #expect(pair.down.type == .leftMouseDown)
        #expect(pair.up.type == .leftMouseUp)
        for event in [pair.down, pair.up] {
            #expect(event.location == location)
            #expect(event.flags.contains(.maskCommand))
            #expect(event.getIntegerValueField(.mouseEventClickState) == 2)
            #expect(SyntheticEvents.isOwnEvent(event))
        }
    }

    @Test("中鍵與右鍵用對應的事件類型與按鍵編號")
    func otherButtons() throws {
        let middle = try #require(SyntheticEvents.makeMousePair(
            downType: .otherMouseDown, upType: .otherMouseUp, at: .zero, button: .center
        ))
        #expect(middle.down.type == .otherMouseDown)
        #expect(middle.down.getIntegerValueField(.mouseEventButtonNumber) == 2)

        let right = try #require(SyntheticEvents.makeMousePair(
            downType: .rightMouseDown, upType: .rightMouseUp, at: .zero, button: .right
        ))
        #expect(right.up.type == .rightMouseUp)
        #expect(right.up.getIntegerValueField(.mouseEventButtonNumber) == 1)
    }

    @Test("別人的事件沒有簽章")
    func foreignEventsAreNotOwn() throws {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: 5, wheel2: 0, wheel3: 0
        ))
        #expect(!SyntheticEvents.isOwnEvent(event))
    }
}
