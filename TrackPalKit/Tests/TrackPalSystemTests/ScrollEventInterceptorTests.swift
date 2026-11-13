import CoreGraphics
import Foundation
import os
import Testing
import TrackPalCore
@testable import TrackPalSystem

private final class Collected: Sendable {
    private let storage = OSAllocatedUnfairLock(
        initialState: (
            logs: [String](),
            replays: [PrimaryClickSnapshot](),
            parts: [ScrollEventInterceptor.ClickReplayPart]()
        )
    )
    var logs: [String] { storage.withLock { $0.logs } }
    var replays: [PrimaryClickSnapshot] { storage.withLock { $0.replays } }
    var parts: [ScrollEventInterceptor.ClickReplayPart] { storage.withLock { $0.parts } }
    func log(_ message: String) { storage.withLock { $0.logs.append(message) } }
    func replay(_ part: ScrollEventInterceptor.ClickReplayPart, _ snapshot: PrimaryClickSnapshot) {
        storage.withLock {
            $0.parts.append(part)
            $0.replays.append(snapshot)
        }
    }
}

/// 奈秒換成 `CGEvent.timestamp` 的單位（mach 刻度）。測試裡的事件時間都經過
/// 這個函式，跟真的事件一樣要再換算回來才對得上接觸時間。
private func machTicks(fromNanoseconds nanoseconds: UInt64) -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let product = nanoseconds.multipliedFullWidth(by: UInt64(info.denom))
    return UInt64(info.numer).dividingFullWidth(product).quotient
}

private func uptimeNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

/// event tap 的判斷邏輯。不建立真正的 tap，事件也不送出去。
@Suite("event tap 的判斷")
struct ScrollEventInterceptorTests {
    private func makeInterceptor(
        pressEvidence: PressEvidence? = nil
    ) -> (ScrollEventInterceptor, ScrollSuppressionState, Collected) {
        let suppression = ScrollSuppressionState()
        let collected = Collected()
        let interceptor = ScrollEventInterceptor(
            suppression: suppression,
            log: { collected.log($0) },
            pressEvidence: pressEvidence,
            replayClick: { part, snapshot, _ in collected.replay(part, snapshot) }
        )
        return (interceptor, suppression, collected)
    }

    private func foreignScroll() throws -> CGEvent {
        try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: 5, wheel2: 0, wheel3: 0
        ))
    }

    /// `timestamp` 是奈秒；寫進事件時換成系統實際用的 mach 刻度。
    private func mouseEvent(_ type: CGEventType, at timestamp: UInt64, x: CGFloat = 50) throws -> CGEvent {
        let event = try #require(CGEvent(
            mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: CGPoint(x: x, y: 60), mouseButton: .left
        ))
        event.timestamp = machTicks(fromNanoseconds: timestamp)
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
        let own = try #require(SyntheticEvents.makeScrollEvent(deltaX: 0, deltaY: 3, lineX: 0, lineY: 0))
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
        #expect(collected.parts == [.pair])
        #expect(collected.replays.first?.location == CGPoint(x: 77, y: 60))
        #expect(collected.logs.contains("Native left click replayed for gesture 9, pairs=1"))
    }

    @Test("事件時間是 mach 刻度：換算後跟 uptime 同一個時鐘")
    func eventTimestampUsesMachTicks() throws {
        let before = uptimeNanoseconds()
        let converted = ScrollEventInterceptor.monotonicNanoseconds(
            fromEventTimestamp: mach_absolute_time()
        )
        let after = uptimeNanoseconds()
        #expect(converted >= before && converted <= after)
    }

    @Test("真實的事件時間（mach 刻度）落在接觸期間內就會被攔下")
    func eventStampedInMachTicksIsCapturedDuringGesture() throws {
        let (interceptor, _, _) = makeInterceptor()
        let began = uptimeNanoseconds()
        interceptor.beginPendingForceGesture(token: 1, gestureUptime: Double(began) / 1e9)

        // 2026-11-13 以前：刻度被當成奈秒，在 Apple Silicon 上永遠比接觸的
        // 開始時間早，這個 down 會直接放行。
        let event = try #require(CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: .zero, mouseButton: .left
        ))
        event.timestamp = mach_absolute_time()
        #expect(interceptor.shouldSuppress(type: .leftMouseDown, event: event))
    }

    @Test("按住拖曳：攔截提早結束時先補送 down，之後的 up 也改由補送")
    func heldDownIsReleasedThenUpIsReposted() throws {
        let (interceptor, _, collected) = makeInterceptor()
        let began = uptimeNanoseconds()
        interceptor.beginPendingForceGesture(token: 4, gestureUptime: Double(began) / 1e9)
        #expect(interceptor.shouldSuppress(type: .leftMouseDown, event: try mouseEvent(.leftMouseDown, at: began + 1_000_000, x: 20)))

        // 手指滑出去，壓力動作已經不可能：引擎提早結束攔截。
        interceptor.finishPendingForceGesture(
            token: 4, replayCapturedClick: true, gestureUptime: Double(began + 2_000_000) / 1e9
        )
        #expect(collected.parts == [.down])
        #expect(collected.replays.first?.location == CGPoint(x: 20, y: 60))

        // 拖到別處才放開：原生 up 吃掉，照它自己的位置補送。
        #expect(interceptor.shouldSuppress(type: .leftMouseUp, event: try mouseEvent(.leftMouseUp, at: began + 900_000_000, x: 300)))
        #expect(collected.parts == [.down, .up])
        #expect(collected.replays.last?.location == CGPoint(x: 300, y: 60))

        // 之後的點擊完全不受影響。
        #expect(!interceptor.shouldSuppress(type: .leftMouseDown, event: try mouseEvent(.leftMouseDown, at: began + 950_000_000)))
        #expect(!interceptor.shouldSuppress(type: .leftMouseUp, event: try mouseEvent(.leftMouseUp, at: began + 960_000_000)))
        #expect(collected.parts == [.down, .up])
    }

    @Test("輕點點按在手指離開後才送出：照樣補送，不會把之後的點擊吃掉")
    func clickStampedAfterContactEndIsStillReleased() throws {
        let (interceptor, _, collected) = makeInterceptor()
        let began = uptimeNanoseconds()
        interceptor.beginPendingForceGesture(token: 6, gestureUptime: Double(began) / 1e9)
        // 事件時間比接觸的結束時間（+3 ms）還晚。
        #expect(interceptor.shouldSuppress(type: .leftMouseDown, event: try mouseEvent(.leftMouseDown, at: began + 5_000_000)))
        #expect(interceptor.shouldSuppress(type: .leftMouseUp, event: try mouseEvent(.leftMouseUp, at: began + 6_000_000)))

        interceptor.finishPendingForceGesture(
            token: 6, replayCapturedClick: true, gestureUptime: Double(began + 3_000_000) / 1e9
        )
        #expect(collected.parts == [.pair])

        #expect(!interceptor.shouldSuppress(type: .leftMouseDown, event: try mouseEvent(.leftMouseDown, at: began + 50_000_000)))
        #expect(!interceptor.shouldSuppress(type: .leftMouseUp, event: try mouseEvent(.leftMouseUp, at: began + 60_000_000)))
        #expect(collected.parts == [.pair])
    }

    @Test("沒有按壓力道的左鍵（輕點點按）完全不攔；有按壓才攔")
    func clickWithoutPressEvidenceIsNeverHeld() throws {
        let evidence = PressEvidence()
        let (interceptor, _, collected) = makeInterceptor(pressEvidence: evidence)
        let began = uptimeNanoseconds()
        interceptor.beginPendingForceGesture(token: 8, gestureUptime: Double(began) / 1e9)

        // 力道不到門檻的樣本不算數。
        evidence.note(force: 12, uptime: Double(began + 500_000) / 1e9)
        #expect(!interceptor.shouldSuppress(type: .leftMouseDown, event: try mouseEvent(.leftMouseDown, at: began + 1_000_000)))
        #expect(!interceptor.shouldSuppress(type: .leftMouseUp, event: try mouseEvent(.leftMouseUp, at: began + 2_000_000)))

        // 真的按下去之後才攔。
        evidence.note(force: 85, uptime: Double(began + 20_000_000) / 1e9)
        #expect(interceptor.shouldSuppress(type: .leftMouseDown, event: try mouseEvent(.leftMouseDown, at: began + 25_000_000)))
        #expect(interceptor.shouldSuppress(type: .leftMouseUp, event: try mouseEvent(.leftMouseUp, at: began + 80_000_000)))
        #expect(collected.replays.isEmpty)

        // 很久以前的按壓不算最近的證據。
        #expect(!evidence.hasPress(near: began + 500_000_000))
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
