import CoreGraphics

/// 被攔下來的一次原生左鍵按下，補送時要還原的欄位。
public struct PrimaryClickSnapshot: Sendable, Equatable {
    public var location: CGPoint?
    /// `CGEventFlags.rawValue`。
    public var flags: UInt64
    public var clickState: Int64

    public init(location: CGPoint?, flags: UInt64 = 0, clickState: Int64 = 1) {
        self.location = location
        self.flags = flags
        self.clickState = clickState
    }
}

/// 一次接觸定案後要補送的原生點擊。`snapshots.count` 跟 `expectedPairCount`
/// 對不上代表攔截與記錄不同步，呼叫端應該放棄補送並記一筆日誌。
public struct PrimaryClickReplay: Sendable, Equatable {
    public var token: UInt64
    public var expectedPairCount: Int
    public var snapshots: [PrimaryClickSnapshot]
    /// 還按著、沒等到 up 的那個 down。補送完 `snapshots` 之後單獨送出；它的
    /// up 之後會以 `CaptureResult.repostUp` 回來。
    public var releasedDown: PrimaryClickSnapshot?

    public init(
        token: UInt64,
        expectedPairCount: Int,
        snapshots: [PrimaryClickSnapshot],
        releasedDown: PrimaryClickSnapshot? = nil
    ) {
        self.token = token
        self.expectedPairCount = expectedPairCount
        self.snapshots = snapshots
        self.releasedDown = releasedDown
    }
}

/// event tap 這一側的原生左鍵攔截：`PrimaryClickSuppressionGate` 決定每個
/// down／up 屬於哪一次接觸、要不要吃掉；這裡負責把被吃掉的事件記下來，等那次
/// 接觸定案（壓力動作觸發就丟掉，其餘補送）。
///
/// 值型別、沒有鎖也不碰 CGEvent：呼叫端自己加鎖，並且在鎖外補送。
public struct PrimaryClickCaptureCoordinator: Sendable {
    public enum MouseEvent: Sendable, Equatable {
        case leftMouseDown
        case leftMouseUp
    }

    public struct CaptureResult: Sendable, Equatable {
        /// 這個原生事件要不要吃掉。
        public var shouldSuppress: Bool
        public var replay: PrimaryClickReplay?
        /// 這個 up 屬於先前單獨放行的 down：吃掉原生事件，由呼叫端照它的
        /// 位置與旗標補送一個 up。
        public var repostUp = false

        public init(
            shouldSuppress: Bool,
            replay: PrimaryClickReplay?,
            repostUp: Bool = false
        ) {
            self.shouldSuppress = shouldSuppress
            self.replay = replay
            self.repostUp = repostUp
        }
    }

    private struct CaptureState: Sendable {
        var completedSnapshots: [PrimaryClickSnapshot] = []
        var pendingSnapshot: PrimaryClickSnapshot?
    }

    private var gate = PrimaryClickSuppressionGate()
    private var activeToken: UInt64?
    private var captureStates: [UInt64: CaptureState] = [:]

    public init() {}

    public mutating func reset() {
        gate.reset()
        activeToken = nil
        captureStates.removeAll()
    }

    /// 一次可能出現壓力動作的接觸開始了。時間都是單調時鐘的奈秒。
    public mutating func begin(
        token: UInt64,
        gestureTimestamp: UInt64,
        receivedAt: UInt64
    ) {
        gate.begin(token: token, at: gestureTimestamp, receivedAt: receivedAt)
        pruneCaptureStates()
        activeToken = token
        captureStates[token] = CaptureState()
    }

    /// 接觸定案。回傳要補送的點擊；不用補送時是 nil。
    public mutating func finish(
        token: UInt64,
        replayCapturedClick: Bool,
        gestureTimestamp: UInt64,
        receivedAt: UInt64
    ) -> PrimaryClickReplay? {
        guard activeToken == token else { return nil }

        let resolution = gate.finish(
            token: token,
            replayCapturedClick: replayCapturedClick,
            at: gestureTimestamp,
            receivedAt: receivedAt
        )
        activeToken = nil
        guard resolution != .none else { return nil }
        let consumed = consumeSnapshots(for: resolution)
        return replay(for: resolution, consumed: consumed)
    }

    /// event tap 收到一個不是 TrackPal 自己送的左鍵 down／up。`snapshot` 只在
    /// 真的需要記錄時才會被呼叫。
    public mutating func capture(
        _ event: MouseEvent,
        eventTimestamp: UInt64,
        receivedAt: UInt64,
        snapshot: () -> PrimaryClickSnapshot
    ) -> CaptureResult {
        let gateEvent: PrimaryClickSuppressionGate.MouseEvent = switch event {
        case .leftMouseDown: .leftMouseDown
        case .leftMouseUp: .leftMouseUp
        }
        let decision = gate.capture(
            event: gateEvent,
            at: eventTimestamp,
            receivedAt: receivedAt
        )

        var result = CaptureResult(shouldSuppress: false, replay: nil)
        switch decision {
        case .pass:
            break

        case .passAndReset:
            pruneCaptureStates()
            if let token = activeToken, !gate.contains(token: token) {
                activeToken = nil
            }

        case let .suppress(token):
            result.shouldSuppress = true
            recordSnapshot(token: token, event: event, snapshot: snapshot)

        case let .suppressAndResolve(resolution):
            result.shouldSuppress = true
            if let token = resolution.token {
                recordSnapshot(token: token, event: event, snapshot: snapshot)
                let consumed = consumeSnapshots(for: resolution)
                if activeToken == token {
                    activeToken = nil
                }
                result.replay = replay(for: resolution, consumed: consumed)
            }

        case .suppressAndRepostUp:
            result.shouldSuppress = true
            result.repostUp = true
        }
        pruneCaptureStates()
        return result
    }

    private mutating func pruneCaptureStates() {
        captureStates = captureStates.filter { gate.contains(token: $0.key) }
    }

    private mutating func recordSnapshot(
        token: UInt64,
        event: MouseEvent,
        snapshot: () -> PrimaryClickSnapshot
    ) {
        var state = captureStates[token] ?? CaptureState()

        switch event {
        case .leftMouseDown:
            guard state.pendingSnapshot == nil else { return }
            state.pendingSnapshot = snapshot()

        case .leftMouseUp:
            guard let pendingSnapshot = state.pendingSnapshot else { return }
            state.completedSnapshots.append(pendingSnapshot)
            state.pendingSnapshot = nil
        }

        captureStates[token] = state
    }

    private struct ConsumedSnapshots {
        var pairs: [PrimaryClickSnapshot] = []
        var releasedDown: PrimaryClickSnapshot?
    }

    private mutating func consumeSnapshots(
        for resolution: PrimaryClickSuppressionGate.Resolution
    ) -> ConsumedSnapshots {
        guard let token = resolution.token,
              var state = captureStates[token] else {
            return ConsumedSnapshots()
        }

        var consumed = ConsumedSnapshots()
        switch resolution {
        case .none:
            return consumed

        case .discard:
            state.completedSnapshots.removeAll()

        case let .replayClicks(_, pairs):
            let replayCount = min(pairs.count, state.completedSnapshots.count)
            consumed.pairs = Array(state.completedSnapshots.prefix(replayCount))
            state.completedSnapshots.removeFirst(replayCount)

        case let .replayClicksAndReleaseDown(_, pairs, _):
            let replayCount = min(pairs.count, state.completedSnapshots.count)
            consumed.pairs = Array(state.completedSnapshots.prefix(replayCount))
            state.completedSnapshots.removeFirst(replayCount)
            consumed.releasedDown = state.pendingSnapshot
            state.pendingSnapshot = nil
        }

        if gate.contains(token: token) {
            captureStates[token] = state
        } else {
            captureStates.removeValue(forKey: token)
        }
        return consumed
    }

    private func replay(
        for resolution: PrimaryClickSuppressionGate.Resolution,
        consumed: ConsumedSnapshots
    ) -> PrimaryClickReplay? {
        switch resolution {
        case .none, .discard:
            return nil

        case let .replayClicks(token, pairs):
            return PrimaryClickReplay(
                token: token,
                expectedPairCount: pairs.count,
                snapshots: consumed.pairs
            )

        case let .replayClicksAndReleaseDown(token, pairs, _):
            return PrimaryClickReplay(
                token: token,
                expectedPairCount: pairs.count,
                snapshots: consumed.pairs,
                releasedDown: consumed.releasedDown
            )
        }
    }

    /// 把 mach 時間刻度換成奈秒。`CGEvent.timestamp` 與 `mach_absolute_time`
    /// 同一個單位；在 Apple Silicon 上一格是 125/3 奈秒，不是 1 奈秒。
    public static func nanoseconds(
        fromMachTicks ticks: UInt64,
        numer: UInt32,
        denom: UInt32
    ) -> UInt64 {
        guard numer > 0, denom > 0 else { return ticks }
        guard numer != denom else { return ticks }
        let product = ticks.multipliedFullWidth(by: UInt64(numer))
        guard product.high < UInt64(denom) else { return .max }
        return UInt64(denom).dividingFullWidth(product).quotient
    }

    /// 把秒為單位的系統 uptime 換成奈秒；不合理的值用 `fallback`。
    public static func monotonicNanoseconds(
        fromSystemUptime uptime: Double,
        fallback: UInt64
    ) -> UInt64 {
        let nanosecondsPerSecond = 1_000_000_000.0
        guard uptime.isFinite,
              uptime > 0,
              uptime <= Double(UInt64.max) / nanosecondsPerSecond else {
            return fallback
        }
        return UInt64((uptime * nanosecondsPerSecond).rounded())
    }
}
