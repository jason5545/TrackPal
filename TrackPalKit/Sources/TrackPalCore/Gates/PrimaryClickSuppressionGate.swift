struct PrimaryClickSuppressionGate {
    typealias GestureToken = UInt64

    static let endingPartialExpiryNanoseconds: UInt64 = 150_000_000

    enum MouseEvent: Equatable {
        case leftMouseDown
        case leftMouseUp
    }

    struct ClickPair: Equatable {
        let downAt: UInt64
        let upAt: UInt64
    }

    enum Resolution: Equatable {
        case none
        case discard(token: GestureToken)
        case replayClicks(token: GestureToken, pairs: [ClickPair])
        /// 補送完整的幾組之後，再把還沒等到 up 的那個 down 單獨送出去。
        /// 實體按鍵還按著，對應的 up 之後由 `suppressAndRepostUp` 接手。
        case replayClicksAndReleaseDown(
            token: GestureToken,
            pairs: [ClickPair],
            downAt: UInt64
        )

        var token: GestureToken? {
            switch self {
            case .none:
                nil
            case let .discard(token),
                 let .replayClicks(token, _),
                 let .replayClicksAndReleaseDown(token, _, _):
                token
            }
        }
    }

    enum CaptureDecision: Equatable {
        case pass
        case passAndReset
        case suppress(token: GestureToken)
        case suppressAndResolve(Resolution)
        /// 這個 up 屬於先前單獨放行的 down。吃掉原生事件、改由呼叫端補送，
        /// 補送的 down 與 up 走同一條路，順序才不會顛倒。
        case suppressAndRepostUp(token: GestureToken)
    }

    private struct ActiveGesture {
        let token: GestureToken
        let beganAt: UInt64
        var completedPairs: [ClickPair]
        var pendingDownAt: UInt64?
    }

    private struct EndingGesture {
        let token: GestureToken
        let beganAt: UInt64
        let endedAt: UInt64
        var pendingDownAt: UInt64?
        let replayCapturedClick: Bool
        /// A force action can finish before the event tap receives either half
        /// of its native click. This guard may therefore capture a delayed down;
        /// an ordinary partial ending may only wait for its already-captured up.
        let acceptsDelayedDown: Bool
        let expiresAt: UInt64
    }

    // Raw touch for the next contact can begin before the event tap delivers
    // the previous contact's mouse events. Keep ending state beside the new
    // active token instead of replacing it and losing suppressed input.
    private var activeGesture: ActiveGesture?
    private var endingGestures: [EndingGesture] = []
    /// 已經單獨放行 down、還在等原生 up 的那次接觸。
    private var releasedDownToken: GestureToken?

    /// `time` is the raw gesture's physical uptime timestamp. `receivedAt`
    /// is when the callback is handled and is used only to expire old guards.
    mutating func begin(
        token: GestureToken,
        at time: UInt64,
        receivedAt: UInt64? = nil
    ) {
        _ = purgeExpiredEndings(at: receivedAt ?? time)
        activeGesture = ActiveGesture(
            token: token,
            beganAt: time,
            completedPairs: [],
            pendingDownAt: nil
        )
    }

    /// `time` is `CGEvent.timestamp`; `receivedAt` is callback delivery uptime.
    /// Keeping both prevents main-thread delay from changing event ownership.
    mutating func capture(
        event: MouseEvent,
        at time: UInt64,
        receivedAt: UInt64? = nil
    ) -> CaptureDecision {
        let purgedExpiredEnding = purgeExpiredEndings(
            at: receivedAt ?? time
        )

        if let token = releasedDownToken {
            releasedDownToken = nil
            if event == .leftMouseUp {
                return .suppressAndRepostUp(token: token)
            }
            // 還沒等到 up 就來了新的 down：狀態對不上，照一般流程處理。
        }

        // Event timestamps and raw-touch gesture boundaries share the system
        // uptime clock. A click that physically occurred after the new contact
        // began belongs to that active token even if an older action guard is
        // still waiting for delayed event-tap delivery.
        if let activeDecision = captureForActiveGesture(
            event: event,
            at: time
        ) {
            return activeDecision
        }

        if event == .leftMouseUp,
           let endingIndex = endingGestures.firstIndex(where: {
               guard let downAt = $0.pendingDownAt else { return false }
               guard time >= downAt else { return false }
               return !$0.acceptsDelayedDown || time <= $0.endedAt
           }) {
            var ending = endingGestures[endingIndex]
            guard let downAt = ending.pendingDownAt else {
                return .pass
            }
            if ending.acceptsDelayedDown {
                // Keep a force-action guard alive until its delivery expiry so
                // every physically old pair can be discarded, not only the
                // first pair that happens to reach the event tap.
                ending.pendingDownAt = nil
                endingGestures[endingIndex] = ending
            } else {
                endingGestures.remove(at: endingIndex)
            }
            let resolution: Resolution = ending.replayCapturedClick
                ? .replayClicks(
                    token: ending.token,
                    pairs: [ClickPair(downAt: downAt, upAt: time)]
                )
                : .discard(token: ending.token)
            return .suppressAndResolve(resolution)
        }

        // A force action with no captured down stays armed briefly because the
        // raw-touch release can overtake an entire native down/up pair. Only an
        // event physically inside that old gesture interval belongs to it.
        if event == .leftMouseDown,
           let endingIndex = endingGestures.firstIndex(where: {
               $0.acceptsDelayedDown
                   && time >= $0.beganAt
                   && time <= $0.endedAt
           }) {
            var ending = endingGestures[endingIndex]
            if ending.pendingDownAt == nil {
                ending.pendingDownAt = time
                endingGestures[endingIndex] = ending
            }
            return .suppress(token: ending.token)
        }

        if event == .leftMouseDown,
           activeGesture == nil,
           !endingGestures.isEmpty {
            endingGestures.removeAll()
            return .passAndReset
        }

        return purgedExpiredEnding ? .passAndReset : .pass
    }

    /// `time` is the raw gesture's physical end timestamp. The 150 ms delivery
    /// allowance starts at `receivedAt`, never at a delayed event timestamp.
    mutating func finish(
        token: GestureToken,
        replayCapturedClick: Bool,
        at time: UInt64,
        receivedAt: UInt64? = nil
    ) -> Resolution {
        let deliveryTime = receivedAt ?? time
        _ = purgeExpiredEndings(at: deliveryTime)
        guard let gesture = activeGesture, gesture.token == token else {
            return .none
        }

        // 被這次接觸攔下的事件，時間可能比接觸的結束時間晚（輕點點按是手指
        // 離開之後才由系統送出）。這裡一律收尾：時間對不上就把結束時間往後
        // 推，不讓攔截留到下一次接觸、把之後的點擊吃掉。
        var time = max(time, gesture.beganAt)
        if let lastUpAt = gesture.completedPairs.last?.upAt {
            time = max(time, lastUpAt)
        }
        if let downAt = gesture.pendingDownAt {
            time = max(time, downAt)
        }

        activeGesture = nil

        if let downAt = gesture.pendingDownAt {
            if replayCapturedClick {
                // 實體按鍵還按著（例如按住拖曳）：現在就把 down 放出去，
                // 不等 up。
                releasedDownToken = token
                return .replayClicksAndReleaseDown(
                    token: token,
                    pairs: gesture.completedPairs,
                    downAt: downAt
                )
            }
            endingGestures.append(EndingGesture(
                token: token,
                beganAt: gesture.beganAt,
                endedAt: time,
                pendingDownAt: downAt,
                replayCapturedClick: false,
                acceptsDelayedDown: false,
                expiresAt: expiryDeadline(from: deliveryTime)
            ))
        } else if !replayCapturedClick {
            // A successful force action may outrun another complete native
            // click, even when an earlier pair was already captured. Keep a
            // no-down guard so delayed follow-up down/up cannot leak through.
            endingGestures.append(EndingGesture(
                token: token,
                beganAt: gesture.beganAt,
                endedAt: time,
                pendingDownAt: nil,
                replayCapturedClick: false,
                acceptsDelayedDown: true,
                expiresAt: expiryDeadline(from: deliveryTime)
            ))
        }

        if replayCapturedClick {
            guard !gesture.completedPairs.isEmpty else {
                // Normal finish with no native down is not ambiguous: disarm
                // immediately instead of swallowing the user's next click.
                return .discard(token: token)
            }
            return .replayClicks(
                token: token,
                pairs: gesture.completedPairs
            )
        }

        return gesture.completedPairs.isEmpty
            ? .none
            : .discard(token: token)
    }

    mutating func disarm(token: GestureToken) {
        if activeGesture?.token == token {
            activeGesture = nil
        }
        endingGestures.removeAll { $0.token == token }
    }

    mutating func reset() {
        activeGesture = nil
        endingGestures.removeAll()
        releasedDownToken = nil
    }

    func contains(token: GestureToken) -> Bool {
        activeGesture?.token == token
            || endingGestures.contains { $0.token == token }
    }

    @discardableResult
    private mutating func purgeExpiredEndings(at time: UInt64) -> Bool {
        let previousCount = endingGestures.count
        endingGestures.removeAll { time > $0.expiresAt }
        return endingGestures.count != previousCount
    }

    private func expiryDeadline(from time: UInt64) -> UInt64 {
        let (deadline, overflow) = time.addingReportingOverflow(
            Self.endingPartialExpiryNanoseconds
        )
        return overflow ? .max : deadline
    }

    private mutating func captureForActiveGesture(
        event: MouseEvent,
        at time: UInt64
    ) -> CaptureDecision? {
        guard var gesture = activeGesture,
              time >= gesture.beganAt else {
            return nil
        }

        switch event {
        case .leftMouseDown:
            if let pendingDownAt = gesture.pendingDownAt {
                guard time >= pendingDownAt else { return .pass }
                return .suppress(token: gesture.token)
            }
            if let previousUpAt = gesture.completedPairs.last?.upAt,
               time < previousUpAt {
                return .pass
            }
            gesture.pendingDownAt = time
            activeGesture = gesture
            return .suppress(token: gesture.token)

        case .leftMouseUp:
            guard let downAt = gesture.pendingDownAt,
                  time >= downAt else {
                return .pass
            }
            gesture.completedPairs.append(
                ClickPair(downAt: downAt, upAt: time)
            )
            gesture.pendingDownAt = nil
            activeGesture = gesture
            return .suppress(token: gesture.token)
        }
    }
}
