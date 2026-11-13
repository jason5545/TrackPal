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
}

/// event tap 這一側的原生左鍵攔截：`PrimaryClickSuppressionGate` 決定每個
/// down／up 屬於哪一次接觸、要不要吃掉；這裡負責把被吃掉的事件記下來，等那次
/// 接觸定案（一般結果補送、壓力動作或捲動則丟掉）。
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
        let snapshots = consumeSnapshots(for: resolution)
        return replay(for: resolution, snapshots: snapshots)
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
                let snapshots = consumeSnapshots(for: resolution)
                if activeToken == token {
                    activeToken = nil
                }
                result.replay = replay(for: resolution, snapshots: snapshots)
            }
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

    private mutating func consumeSnapshots(
        for resolution: PrimaryClickSuppressionGate.Resolution
    ) -> [PrimaryClickSnapshot] {
        guard let token = resolution.token,
              var state = captureStates[token] else {
            return []
        }

        let snapshots: [PrimaryClickSnapshot]
        switch resolution {
        case .none:
            return []

        case .discard:
            state.completedSnapshots.removeAll()
            snapshots = []

        case let .replayClicks(_, pairs):
            let replayCount = min(pairs.count, state.completedSnapshots.count)
            snapshots = Array(state.completedSnapshots.prefix(replayCount))
            state.completedSnapshots.removeFirst(replayCount)
        }

        if gate.contains(token: token) {
            captureStates[token] = state
        } else {
            captureStates.removeValue(forKey: token)
        }
        return snapshots
    }

    private func replay(
        for resolution: PrimaryClickSuppressionGate.Resolution,
        snapshots: [PrimaryClickSnapshot]
    ) -> PrimaryClickReplay? {
        guard case let .replayClicks(token, pairs) = resolution else {
            return nil
        }
        return PrimaryClickReplay(
            token: token,
            expectedPairCount: pairs.count,
            snapshots: snapshots
        )
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
