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

    @Test("捲動事件：連續捲動標記、phase 全部是 0、蓋上簽章")
    func scrollEventFields() throws {
        let event = try #require(SyntheticEvents.makeScrollEvent(
            deltaX: -42, deltaY: 7, lineX: -5, lineY: 1
        ))

        #expect(event.type == .scrollWheel)
        #expect(SyntheticEvents.isOwnEvent(event))
        #expect(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
        #expect(event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0)
    }

    /// 設定順序錯了的話，系統會把像素位移重算成「行位移 × 8」
    /// （見 `makeScrollEvent` 的說明）。這條測試讀回實際的欄位值。
    @Test("App 收到的像素位移就是指定的值，行位移也各自獨立", arguments: [
        (Int32(1), Int32(0)), (3, 0), (5, 1), (7, 0), (19, 2), (42, 5), (300, 37),
        (-1, 0), (-25, -3), (0, 0), (2, 1), (9, -1),
    ])
    func pointAndLineDeltasAreIndependent(pixels: Int32, lines: Int32) throws {
        let vertical = try #require(SyntheticEvents.makeScrollEvent(
            deltaX: 0, deltaY: pixels, lineX: 0, lineY: lines
        ))
        // axis1 是垂直、axis2 是水平。
        #expect(vertical.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == Int64(pixels))
        #expect(vertical.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0)
        #expect(vertical.getIntegerValueField(.scrollWheelEventDeltaAxis1) == Int64(lines))
        #expect(vertical.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 0)

        let horizontal = try #require(SyntheticEvents.makeScrollEvent(
            deltaX: pixels, deltaY: 0, lineX: lines, lineY: 0
        ))
        #expect(horizontal.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == Int64(pixels))
        #expect(horizontal.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0)
        #expect(horizontal.getIntegerValueField(.scrollWheelEventDeltaAxis2) == Int64(lines))
        #expect(horizontal.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2) == 0)
    }

    @Test("兩軸同時有位移時互不干擾")
    func bothAxes() throws {
        let event = try #require(SyntheticEvents.makeScrollEvent(
            deltaX: -42, deltaY: 7, lineX: -5, lineY: 0
        ))
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 7)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -42)
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis2) == -5)
    }

    @Test("零位移的捲動事件（捲動或慣性結束時送的那一筆）也建得出來")
    func zeroDeltaScrollEvent() throws {
        let event = try #require(SyntheticEvents.makeScrollEvent(
            deltaX: 0, deltaY: 0, lineX: 0, lineY: 0
        ))
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
    }

    @MainActor
    @Test("發送出口：像素原樣送出，行位移每 8 px 一行、零頭跨事件累加")
    func posterAccumulatesLines() {
        var sent: [CGEvent] = []
        let poster = ScrollEventPoster { sent.append($0) }
        for _ in 0..<6 { poster.post(deltaX: 0, deltaY: -3) }      // 共 -18 px
        poster.post(deltaX: 20, deltaY: 0)
        poster.post(deltaX: 0, deltaY: 0)

        #expect(sent.count == 8)
        #expect(sent.prefix(6).map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }
            == [-3, -3, -3, -3, -3, -3])
        #expect(sent.prefix(6).map { $0.getIntegerValueField(.scrollWheelEventDeltaAxis1) }
            == [0, 0, -1, 0, 0, -1])
        #expect(sent[6].getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 20)
        #expect(sent[6].getIntegerValueField(.scrollWheelEventDeltaAxis2) == 2)
        #expect(sent[7].getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0)
        #expect(sent.allSatisfy(SyntheticEvents.isOwnEvent))
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
