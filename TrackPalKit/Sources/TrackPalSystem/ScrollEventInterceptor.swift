import CoreGraphics
import Foundation
import os
import TrackPalCore

/// HID 層的 event tap：區域捲動進行中擋掉系統自己的捲動與游標移動，並攔下
/// 可能要改成壓力動作的原生左鍵。
///
/// tap 掛在 main run loop 上。判斷邏輯在 `shouldSuppress(type:event:)`，不依賴
/// tap 本身，所以可以用沒送出去的 CGEvent 直接測。
public final class ScrollEventInterceptor: @unchecked Sendable {
    /// 補送被攔下的原生左鍵時要送哪一部分。
    public enum ClickReplayPart: Sendable, Equatable {
        /// 完整的一組 down／up。
        case pair
        /// 只有 down：實體按鍵還按著（按住拖曳）。
        case down
        /// 只有 up：對應先前單獨補送的 down。
        case up
    }

    public typealias ClickReplayer = @Sendable (ClickReplayPart, PrimaryClickSnapshot, CGPoint) -> Void

    private let suppression: ScrollSuppressionState
    private let log: @Sendable (String) -> Void
    private let replayClick: ClickReplayer
    private let foreignScrollObserver: (@Sendable (CGEvent) -> Void)?
    private let pressEvidence: PressEvidence?

    private struct State {
        var eventTap: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var isRunning = false
        var clicks = PrimaryClickCaptureCoordinator()
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    public init(
        suppression: ScrollSuppressionState,
        log: @escaping @Sendable (String) -> Void,
        foreignScrollObserver: (@Sendable (CGEvent) -> Void)? = nil,
        pressEvidence: PressEvidence? = nil,
        replayClick: @escaping ClickReplayer = { part, snapshot, location in
            let flags = CGEventFlags(rawValue: snapshot.flags)
            switch part {
            case .pair:
                SyntheticEvents.postMousePair(
                    downType: .leftMouseDown,
                    upType: .leftMouseUp,
                    at: location,
                    button: .left,
                    flags: flags,
                    clickState: snapshot.clickState
                )
            case .down:
                SyntheticEvents.postMouseEvent(
                    type: .leftMouseDown,
                    at: location,
                    button: .left,
                    flags: flags,
                    clickState: snapshot.clickState
                )
            case .up:
                SyntheticEvents.postMouseEvent(
                    type: .leftMouseUp,
                    at: location,
                    button: .left,
                    flags: flags,
                    clickState: snapshot.clickState
                )
            }
        }
    ) {
        self.suppression = suppression
        self.log = log
        self.foreignScrollObserver = foreignScrollObserver
        self.pressEvidence = pressEvidence
        self.replayClick = replayClick
    }

    /// `CGEvent.timestamp` 換成單調時鐘的奈秒。
    ///
    /// 這個欄位跟 `mach_absolute_time` 同單位，不是奈秒：Apple Silicon 上一格
    /// 是 125/3 奈秒。2026-11-13 以前這裡把它直接當奈秒，跟由 uptime 換算
    /// 的接觸時間一比永遠偏早，原生左鍵的攔截因此從來沒有生效過。
    public static func monotonicNanoseconds(fromEventTimestamp ticks: UInt64) -> UInt64 {
        PrimaryClickCaptureCoordinator.nanoseconds(
            fromMachTicks: ticks,
            numer: machTimebase.numer,
            denom: machTimebase.denom
        )
    }

    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public var isRunning: Bool {
        state.withLockUnchecked { $0.isRunning }
    }

    // MARK: - Tap lifecycle

    @discardableResult
    public func start() -> Bool {
        if isRunning { return true }

        let eventMask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)

        // Create event tap at HID level (same as where we post events)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: scrollInterceptorCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log("Failed to create scroll event tap")
            return false
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault, eventTap, 0
        ) else {
            CFMachPortInvalidate(eventTap)
            log("Failed to create scroll event tap run loop source")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        state.withLockUnchecked {
            $0.eventTap = eventTap
            $0.runLoopSource = runLoopSource
            $0.isRunning = true
        }
        log("Scroll event interceptor started")
        return true
    }

    public func stop() {
        let (eventTap, runLoopSource, wasRunning) = state.withLockUnchecked { state in
            state.clicks.reset()
            let snapshot = (state.eventTap, state.runLoopSource, state.isRunning)
            state.eventTap = nil
            state.runLoopSource = nil
            state.isRunning = false
            return snapshot
        }
        guard wasRunning else { return }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        // 讓 mach port 失效，tap 才會真的從系統移除；只停用的話，每次重新啟動
        // （例如喚醒後重新註冊裝置）都會多留一個停用中的 tap。
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        log("Scroll event interceptor stopped")
    }

    fileprivate func reenableTapAfterSystemDisable() {
        if let eventTap = state.withLockUnchecked({ $0.eventTap }) {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    // MARK: - Primary click capture

    public func beginPendingForceGesture(token: UInt64, gestureUptime: Double) {
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        let gestureTimestamp = PrimaryClickCaptureCoordinator.monotonicNanoseconds(
            fromSystemUptime: gestureUptime,
            fallback: receivedAt
        )
        state.withLockUnchecked {
            $0.clicks.begin(
                token: token,
                gestureTimestamp: gestureTimestamp,
                receivedAt: receivedAt
            )
        }
        log("Primary click capture began for gesture \(token)")
    }

    public func finishPendingForceGesture(
        token: UInt64,
        replayCapturedClick: Bool,
        gestureUptime: Double?
    ) {
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        let gestureTimestamp = gestureUptime.map {
            PrimaryClickCaptureCoordinator.monotonicNanoseconds(
                fromSystemUptime: $0,
                fallback: receivedAt
            )
        } ?? receivedAt

        let replay = state.withLockUnchecked {
            $0.clicks.finish(
                token: token,
                replayCapturedClick: replayCapturedClick,
                gestureTimestamp: gestureTimestamp,
                receivedAt: receivedAt
            )
        }
        // 補送要在鎖外做：送出去的事件會再進這個 tap。
        perform(replay)
    }

    // MARK: - Decisions

    /// 這個事件要不要吃掉。
    public func shouldSuppress(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .mouseMoved:
            // Suppress cursor movement during active zone scrolling
            return suppression.shouldSuppressPointerMovement

        case .leftMouseDown, .leftMouseUp:
            return shouldSuppressPrimaryClick(type: type, event: event)

        case .scrollWheel:
            // Suppress other scroll events while we're actively scrolling, but
            // never TrackPal's own.
            let isOwn = SyntheticEvents.isOwnEvent(event)
            if !isOwn {
                // 校正用的觀察者：只看，不影響要不要擋。
                foreignScrollObserver?(event)
            }
            guard suppression.isActivelyScrolling else { return false }
            return !isOwn

        default:
            return false
        }
    }

    private func shouldSuppressPrimaryClick(
        type: CGEventType, event: CGEvent
    ) -> Bool {
        guard !SyntheticEvents.isOwnEvent(event) else { return false }

        let receivedAt = DispatchTime.now().uptimeNanoseconds
        let eventTimestamp = event.timestamp > 0
            ? Self.monotonicNanoseconds(fromEventTimestamp: event.timestamp)
            : receivedAt
        let mouseEvent: PrimaryClickCaptureCoordinator.MouseEvent =
            type == .leftMouseDown ? .leftMouseDown : .leftMouseUp

        // 沒有按壓力道的 down 是輕點點按，不可能跟壓力動作是同一下：完全不碰。
        if mouseEvent == .leftMouseDown,
           let pressEvidence,
           !pressEvidence.hasPress(near: eventTimestamp) {
            return false
        }

        let result = state.withLockUnchecked {
            $0.clicks.capture(
                mouseEvent,
                eventTimestamp: eventTimestamp,
                receivedAt: receivedAt
            ) {
                PrimaryClickSnapshot(
                    location: event.location,
                    flags: event.flags.rawValue,
                    clickState: event.getIntegerValueField(.mouseEventClickState)
                )
            }
        }
        perform(result.replay)

        if result.repostUp {
            // 對應的 down 是我們補送的；up 也走同一條路，順序才不會顛倒。
            replayClick(
                .up,
                PrimaryClickSnapshot(
                    location: event.location,
                    flags: event.flags.rawValue,
                    clickState: event.getIntegerValueField(.mouseEventClickState)
                ),
                event.location
            )
            log("Native left up reposted after released down")
        } else if result.shouldSuppress {
            log("Native left click suppressed during force action guard")
        }
        return result.shouldSuppress
    }

    private func perform(_ replay: PrimaryClickReplay?) {
        guard let replay else { return }

        if replay.snapshots.count == replay.expectedPairCount {
            for snapshot in replay.snapshots {
                guard let location = snapshot.location else {
                    log("Primary click replay missing location for gesture \(replay.token)")
                    continue
                }
                replayClick(.pair, snapshot, location)
            }
            if replay.expectedPairCount > 0 || replay.releasedDown == nil {
                log(
                    "Native left click replayed for gesture \(replay.token), pairs=\(replay.expectedPairCount)"
                )
            }
        } else {
            log(
                "Primary click replay snapshot mismatch for gesture \(replay.token): pairs=\(replay.expectedPairCount) snapshots=\(replay.snapshots.count)"
            )
        }

        // 還按著的 down 不管前面補送得如何都要放出去，否則之後的 up 會落單。
        if let down = replay.releasedDown {
            if let location = down.location {
                replayClick(.down, down, location)
                log("Native left down released for gesture \(replay.token)")
            } else {
                log("Primary click replay missing location for gesture \(replay.token)")
            }
        }
    }
}

/// C callback for the event tap.
private func scrollInterceptorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<ScrollEventInterceptor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()

    // 系統因為逾時或使用者輸入把 tap 停用時，重新啟用。
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        interceptor.reenableTapAfterSystemDisable()
        return Unmanaged.passUnretained(event)
    }

    if interceptor.shouldSuppress(type: type, event: event) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
