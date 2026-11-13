import CoreGraphics
import Testing
@testable import TrackPalCore

@Suite("原生左鍵的攔截與補送")
struct PrimaryClickCaptureCoordinatorTests {
    private typealias Coordinator = PrimaryClickCaptureCoordinator

    private func snapshot(_ x: CGFloat = 10, clickState: Int64 = 1) -> PrimaryClickSnapshot {
        PrimaryClickSnapshot(location: CGPoint(x: x, y: 20), flags: 0x100, clickState: clickState)
    }

    @Test("沒有進行中的接觸：左鍵直接放行")
    func passesWithoutGesture() {
        var coordinator = Coordinator()
        let result = coordinator.capture(.leftMouseDown, eventTimestamp: 100, receivedAt: 100) {
            Issue.record("放行的事件不該被記錄")
            return snapshot()
        }
        #expect(result == .init(shouldSuppress: false, replay: nil))
    }

    @Test("一般結果：接觸期間的一組 down／up 先吃掉，定案後原樣補送")
    func capturedPairIsReplayed() {
        var coordinator = Coordinator()
        coordinator.begin(token: 1, gestureTimestamp: 1_000, receivedAt: 1_000)

        let down = coordinator.capture(.leftMouseDown, eventTimestamp: 1_100, receivedAt: 1_100) { snapshot(33, clickState: 2) }
        let up = coordinator.capture(.leftMouseUp, eventTimestamp: 1_200, receivedAt: 1_200) { snapshot(99) }
        #expect(down.shouldSuppress && down.replay == nil)
        #expect(up.shouldSuppress && up.replay == nil)

        let replay = coordinator.finish(token: 1, replayCapturedClick: true, gestureTimestamp: 1_300, receivedAt: 1_300)
        // 補送用的是 down 當下的位置與 clickState。
        #expect(replay == PrimaryClickReplay(token: 1, expectedPairCount: 1, snapshots: [snapshot(33, clickState: 2)]))
    }

    @Test("同一次接觸的多組點擊依原本的順序補送")
    func multiplePairsKeepOrder() {
        var coordinator = Coordinator()
        coordinator.begin(token: 5, gestureTimestamp: 1_000, receivedAt: 1_000)
        for (index, time) in [1_100, 1_300].enumerated() {
            _ = coordinator.capture(.leftMouseDown, eventTimestamp: UInt64(time), receivedAt: UInt64(time)) { snapshot(CGFloat(index)) }
            _ = coordinator.capture(.leftMouseUp, eventTimestamp: UInt64(time + 50), receivedAt: UInt64(time + 50)) { snapshot() }
        }

        let replay = coordinator.finish(token: 5, replayCapturedClick: true, gestureTimestamp: 1_500, receivedAt: 1_500)
        #expect(replay?.expectedPairCount == 2)
        #expect(replay?.snapshots.map(\.location?.x) == [0, 1])
    }

    @Test("壓力動作或捲動：吃掉的點擊丟掉，晚到的那一組也不會漏出去")
    func forceActionDiscardsAndGuardsDelayedPair() {
        var coordinator = Coordinator()
        coordinator.begin(token: 1, gestureTimestamp: 1_000, receivedAt: 1_000)
        let replay = coordinator.finish(token: 1, replayCapturedClick: false, gestureTimestamp: 1_300, receivedAt: 1_300)
        #expect(replay == nil)

        // 實體上發生在那次接觸期間、但 event tap 晚收到的 down／up。
        let down = coordinator.capture(.leftMouseDown, eventTimestamp: 1_250, receivedAt: 1_320) { snapshot() }
        let up = coordinator.capture(.leftMouseUp, eventTimestamp: 1_280, receivedAt: 1_330) { snapshot() }
        #expect(down.shouldSuppress)
        #expect(up.shouldSuppress && up.replay == nil)
    }

    @Test("定案時 down 還按著：先把 down 放出去，之後的 up 交給呼叫端補送")
    func heldDownIsReleasedAndItsUpReposted() {
        var coordinator = Coordinator()
        coordinator.begin(token: 2, gestureTimestamp: 1_000, receivedAt: 1_000)
        _ = coordinator.capture(.leftMouseDown, eventTimestamp: 1_100, receivedAt: 1_100) { snapshot(7) }

        let atFinish = coordinator.finish(token: 2, replayCapturedClick: true, gestureTimestamp: 1_200, receivedAt: 1_200)
        #expect(atFinish == PrimaryClickReplay(
            token: 2, expectedPairCount: 0, snapshots: [], releasedDown: snapshot(7)
        ))

        // 拖了很久才放開也一樣：這個 up 不會過期。
        let up = coordinator.capture(.leftMouseUp, eventTimestamp: 9_000_000_000, receivedAt: 9_000_000_000) { snapshot() }
        #expect(up.shouldSuppress)
        #expect(up.repostUp)
        #expect(up.replay == nil)

        // 之後回到什麼都不攔。
        let next = coordinator.capture(.leftMouseDown, eventTimestamp: 9_100_000_000, receivedAt: 9_100_000_000) { snapshot() }
        #expect(!next.shouldSuppress && !next.repostUp)
    }

    @Test("先完成一組、第二下還按著：整組先補送，再放出 down")
    func completedPairThenHeldDown() {
        var coordinator = Coordinator()
        coordinator.begin(token: 5, gestureTimestamp: 1_000, receivedAt: 1_000)
        _ = coordinator.capture(.leftMouseDown, eventTimestamp: 1_100, receivedAt: 1_100) { snapshot(1) }
        _ = coordinator.capture(.leftMouseUp, eventTimestamp: 1_150, receivedAt: 1_150) { snapshot() }
        _ = coordinator.capture(.leftMouseDown, eventTimestamp: 1_300, receivedAt: 1_300) { snapshot(2) }

        let replay = coordinator.finish(token: 5, replayCapturedClick: true, gestureTimestamp: 1_400, receivedAt: 1_400)
        #expect(replay == PrimaryClickReplay(
            token: 5, expectedPairCount: 1, snapshots: [snapshot(1)], releasedDown: snapshot(2)
        ))
    }

    @Test("壓力動作觸發時 down 還按著：down 丟掉，它的 up 也吃掉")
    func heldDownIsDroppedAfterForceAction() {
        var coordinator = Coordinator()
        coordinator.begin(token: 3, gestureTimestamp: 1_000, receivedAt: 1_000)
        _ = coordinator.capture(.leftMouseDown, eventTimestamp: 1_100, receivedAt: 1_100) { snapshot() }

        let atFinish = coordinator.finish(token: 3, replayCapturedClick: false, gestureTimestamp: 1_200, receivedAt: 1_200)
        #expect(atFinish == nil)

        let up = coordinator.capture(.leftMouseUp, eventTimestamp: 1_250, receivedAt: 1_250) { snapshot() }
        #expect(up.shouldSuppress)
        #expect(!up.repostUp)
        #expect(up.replay == nil)
    }

    @Test("攔到的事件時間比接觸結束還晚：照樣收尾，不會留著吃掉之後的點擊")
    func eventsStampedAfterGestureEndStillResolve() {
        var coordinator = Coordinator()
        coordinator.begin(token: 4, gestureTimestamp: 1_000, receivedAt: 1_000)
        _ = coordinator.capture(.leftMouseDown, eventTimestamp: 1_500, receivedAt: 1_500) { snapshot(9) }
        _ = coordinator.capture(.leftMouseUp, eventTimestamp: 1_600, receivedAt: 1_600) { snapshot() }

        // 接觸的結束時間（1_200）比這組點擊早。
        let replay = coordinator.finish(token: 4, replayCapturedClick: true, gestureTimestamp: 1_200, receivedAt: 1_700)
        #expect(replay == PrimaryClickReplay(token: 4, expectedPairCount: 1, snapshots: [snapshot(9)]))

        let next = coordinator.capture(.leftMouseDown, eventTimestamp: 2_000, receivedAt: 2_000) { snapshot() }
        #expect(!next.shouldSuppress)
    }

    @Test("上一次接觸的攔截不會搶走下一次接觸的點擊")
    func nextContactKeepsItsOwnClick() {
        var coordinator = Coordinator()
        coordinator.begin(token: 1, gestureTimestamp: 1_000, receivedAt: 1_000)
        _ = coordinator.finish(token: 1, replayCapturedClick: false, gestureTimestamp: 1_100, receivedAt: 1_100)

        coordinator.begin(token: 2, gestureTimestamp: 1_200, receivedAt: 1_200)
        _ = coordinator.capture(.leftMouseDown, eventTimestamp: 1_250, receivedAt: 1_250) { snapshot(2) }
        _ = coordinator.capture(.leftMouseUp, eventTimestamp: 1_300, receivedAt: 1_300) { snapshot() }
        let replay = coordinator.finish(token: 2, replayCapturedClick: true, gestureTimestamp: 1_400, receivedAt: 1_400)

        #expect(replay?.token == 2)
        #expect(replay?.snapshots == [snapshot(2)])
    }

    @Test("用錯的 token 結束：不做任何事")
    func finishWithStaleTokenIsIgnored() {
        var coordinator = Coordinator()
        coordinator.begin(token: 3, gestureTimestamp: 1_000, receivedAt: 1_000)
        let stale = coordinator.finish(token: 99, replayCapturedClick: true, gestureTimestamp: 1_100, receivedAt: 1_100)
        #expect(stale == nil)

        // 原本的接觸仍然有效。
        let down = coordinator.capture(.leftMouseDown, eventTimestamp: 1_150, receivedAt: 1_150) { snapshot() }
        #expect(down.shouldSuppress)
    }

    @Test("reset 之後回到什麼都不攔的狀態")
    func resetClearsEverything() {
        var coordinator = Coordinator()
        coordinator.begin(token: 1, gestureTimestamp: 1_000, receivedAt: 1_000)
        coordinator.reset()
        let down = coordinator.capture(.leftMouseDown, eventTimestamp: 1_100, receivedAt: 1_100) { snapshot() }
        #expect(!down.shouldSuppress)
    }

    @Test("只有 down 會讀取事件內容；up 沿用 down 記下的那一份")
    func snapshotIsOnlyTakenOnDown() {
        var coordinator = Coordinator()
        coordinator.begin(token: 1, gestureTimestamp: 1_000, receivedAt: 1_000)
        var downReads = 0
        var upReads = 0
        _ = coordinator.capture(.leftMouseDown, eventTimestamp: 1_100, receivedAt: 1_100) { downReads += 1; return snapshot() }
        _ = coordinator.capture(.leftMouseUp, eventTimestamp: 1_200, receivedAt: 1_200) { upReads += 1; return snapshot() }
        #expect(downReads == 1)
        #expect(upReads == 0)
    }

    @Test("uptime 換算成奈秒；不合理的值用備援", arguments: [
        (1.5, UInt64(1_500_000_000)),
        (0.000_000_001, UInt64(1)),
        (0.0, UInt64(777)),
        (-3.0, UInt64(777)),
        (Double.nan, UInt64(777)),
        (Double.infinity, UInt64(777)),
        (1e30, UInt64(777)),
    ])
    func monotonicNanoseconds(uptime: Double, expected: UInt64) {
        #expect(Coordinator.monotonicNanoseconds(fromSystemUptime: uptime, fallback: 777) == expected)
    }

    @Test("mach 刻度換算成奈秒", arguments: [
        // Apple Silicon：一格 125/3 奈秒。
        (UInt64(3), UInt32(125), UInt32(3), UInt64(125)),
        (UInt64(4_854_000_000_000), UInt32(125), UInt32(3), UInt64(202_250_000_000_000)),
        // Intel：一格就是一奈秒。
        (UInt64(123_456), UInt32(1), UInt32(1), UInt64(123_456)),
        // 不合理的 timebase 原樣回傳，不除以零。
        (UInt64(500), UInt32(0), UInt32(0), UInt64(500)),
        // 溢位時封頂。
        (UInt64.max, UInt32(125), UInt32(3), UInt64.max),
    ])
    func machTicksToNanoseconds(ticks: UInt64, numer: UInt32, denom: UInt32, expected: UInt64) {
        #expect(Coordinator.nanoseconds(fromMachTicks: ticks, numer: numer, denom: denom) == expected)
    }
}
