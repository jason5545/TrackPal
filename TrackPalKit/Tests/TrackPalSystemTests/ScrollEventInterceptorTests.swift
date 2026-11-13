import CoreGraphics
import Foundation
import os
import Testing
import TrackPalCore
@testable import TrackPalSystem

private final class Collected: Sendable {
    private let storage = OSAllocatedUnfairLock(
        initialState: (logs: [String](), replays: [PrimaryClickSnapshot]())
    )
    var logs: [String] { storage.withLock { $0.logs } }
    var replays: [PrimaryClickSnapshot] { storage.withLock { $0.replays } }
    func log(_ message: String) { storage.withLock { $0.logs.append(message) } }
    func replay(_ snapshot: PrimaryClickSnapshot) { storage.withLock { $0.replays.append(snapshot) } }
}

private func uptimeNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

/// event tap 的判斷邏輯。不建立真正的 tap，事件也不送出去。
@Suite("event tap 的判斷")
struct ScrollEventInterceptorTests {
    private func makeInterceptor() -> (ScrollEventInterceptor, ScrollSuppressionState, Collected) {
        let suppression = ScrollSuppressionState()
        let collected = Collected()
        let interceptor = ScrollEventInterceptor(
            suppression: suppression,
            log: { collected.log($0) },
            replayClick: { snapshot, _ in collected.replay(snapshot) }
        )
        return (interceptor, suppression, collected)
    }

    private func foreignScroll() throws -> CGEvent {
        try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: 5, wheel2: 0, wheel3: 0
        ))
    }

    private func mouseEvent(_ type: CGEventType, at timestamp: UInt64, x: CGFloat = 50) throws -> CGEvent {
        let event = try #require(CGEvent(
            mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: CGPoint(x: x, y: 60), mouseButton: .left
        ))
        event.timestamp = timestamp
        return event
    }

    @Test("沒在捲動時，什麼都不擋")
    func idlePassesEverything() throws {
        let (interceptor, _, _) = makeInterceptor()
        #expect(!interceptor.shouldSuppress(type: .scrollWheel, event: try foreignScroll()))
        #expect(!interceptor.shouldSuppress(type: .mouseMoved, event: try mouseEvent(.mouseMoved, at: 1)))
        #expect(!interceptor.shouldSuppress(type: .leftMouseDown, event: try mouseEvent(.leftMouseDown, at: uptimeNanoseconds())))
        #expect(!interceptor.shouldSuppress(type: .keyDown, event: try foreignScroll()))
    }

    @Test("區域捲動進行中：擋掉系統的捲動與游標移動，放行自己送的捲動")
    func activeScrollSuppressesForeignEvents() throws {
        let (interceptor, suppression, _) = makeInterceptor()
        suppression.isActivelyScrolling = true

        #expect(interceptor.shouldSuppress(type: .scrollWheel, event: try foreignScroll()))
        #expect(interceptor.shouldSuppress(type: .mouseMoved, event: try mouseEvent(.mouseMoved, at: 1)))
        let own = try #require(SyntheticEvents.makeScrollEvent(deltaX: 0, deltaY: 3))
        #expect(!interceptor.shouldSuppress(type: .scrollWheel, event: own))
    }

    @Test("還在判斷是不是捲動：只凍結游標，捲動事件照常放行")
    func evaluatingFreezesPointerOnly() throws {
        let (interceptor, suppression, _) = makeInterceptor()
        suppression.isEvaluatingCandidate = true

        #expect(interceptor.shouldSuppress(type: .mouseMoved, event: try mouseEvent(.mouseMoved, at: 1)))
        #expect(!interceptor.shouldSuppress(type: .scrollWheel, event: try foreignScroll()))
    }

    @Test("可能是壓力動作的接觸：原生左鍵先吃掉，一般結果再補送")
    func capturedClickIsReplayedOnNormalFinish() throws {
        let (interceptor, _, collected) = makeInterceptor()
        let began = uptimeNanoseconds()
        interceptor.beginPendingForceGesture(token: 9, gestureUptime: Double(began) / 1e9)

        #expect(interceptor.shouldSuppress(type: .leftMouseDown, event: try mouseEvent(.leftMouseDown, at: began + 1_000_000, x: 77)))
        #expect(interceptor.shouldSuppress(type: .leftMouseUp, event: try mouseEvent(.leftMouseUp, at: began + 2_000_000)))
        #expect(collected.replays.isEmpty)

        interceptor.finishPendingForceGesture(
            token: 9, replayCapturedClick: true, gestureUptime: Double(began + 3_000_000) / 1e9
        )
        #expect(collected.replays.count == 1)
        #expect(collected.replays.first?.location == CGPoint(x: 77, y: 60))
        #expect(collected.logs.contains("Native left click replayed for gesture 9, pairs=1"))
    }

    @Test("壓力動作已觸發：吃掉的左鍵不補送")
    func capturedClickIsDroppedAfterForceAction() throws {
        let (interceptor, _, collected) = makeInterceptor()
        let began = uptimeNanoseconds()
        interceptor.beginPendingForceGesture(token: 3, gestureUptime: Double(began) / 1e9)
        _ = interceptor.shouldSuppress(type: .leftMouseDown, event: try mouseEvent(.leftMouseDown, at: began + 1_000_000))
        _ = interceptor.shouldSuppress(type: .leftMouseUp, event: try mouseEvent(.leftMouseUp, at: began + 2_000_000))

        interceptor.finishPendingForceGesture(
            token: 3, replayCapturedClick: false, gestureUptime: Double(began + 3_000_000) / 1e9
        )
        #expect(collected.replays.isEmpty)
    }

    @Test("TrackPal 自己送的左鍵永遠放行，不會被自己攔下來")
    func ownClicksAreNeverCaptured() throws {
        let (interceptor, _, _) = makeInterceptor()
        let began = uptimeNanoseconds()
        interceptor.beginPendingForceGesture(token: 1, gestureUptime: Double(began) / 1e9)
        let pair = try #require(SyntheticEvents.makeMousePair(
            downType: .leftMouseDown, upType: .leftMouseUp, at: .zero, button: .left
        ))
        pair.down.timestamp = began + 1_000_000

        #expect(!interceptor.shouldSuppress(type: .leftMouseDown, event: pair.down))
    }

    @Test("stop 會清掉攔截狀態；沒啟動過也可以安全呼叫")
    func stopResetsCaptureState() throws {
        let (interceptor, _, _) = makeInterceptor()
        let began = uptimeNanoseconds()
        interceptor.beginPendingForceGesture(token: 1, gestureUptime: Double(began) / 1e9)
        interceptor.stop()

        #expect(!interceptor.isRunning)
        #expect(!interceptor.shouldSuppress(type: .leftMouseDown, event: try mouseEvent(.leftMouseDown, at: began + 1_000_000)))
    }
}
