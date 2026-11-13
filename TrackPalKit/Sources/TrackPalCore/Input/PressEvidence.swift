import os

/// 「最近有沒有真的往下按」的證據，給 event tap 判斷一個原生左鍵是不是實體
/// 按壓產生的。
///
/// 輕點點按（tap to click）是手指離開之後才由系統送出左鍵，整段接觸沒有按壓
/// 力道；實體按下去則在按鍵作動前就持續有壓力樣本。只有後者才可能跟壓力動作
/// 是同一下，所以沒有按壓證據的左鍵一律不攔、原樣放行。
///
/// 壓力 callback 在 MultitouchSupport 的執行緒上寫，event tap 在 main run loop
/// 上讀；這裡不經過 8 ms 的排序器，寫進來的就是最新的。
public final class PressEvidence: Sendable {
    /// 算得上「有在按」的最小力道。壓力動作的門檻是 70 起跳，一般輕觸多半
    /// 低於 30。
    public static let minimumForce: Float = 30
    /// 左鍵事件的時間往前多久以內要有按壓樣本。按著的時候每一幀都有樣本，
    /// 這個寬限只是容許兩條事件路徑的送達時間差。
    public static let recencyNanoseconds: UInt64 = 100_000_000

    private let latestPressUptime = OSAllocatedUnfairLock<UInt64?>(initialState: nil)

    public init() {}

    /// 記一筆壓力樣本。`uptime` 是秒，跟 `CACurrentMediaTime` 同一個時鐘。
    public func note(force: Float, uptime: Double) {
        guard force.isFinite, force >= Self.minimumForce else { return }
        let nanoseconds = PrimaryClickCaptureCoordinator.monotonicNanoseconds(
            fromSystemUptime: uptime,
            fallback: 0
        )
        guard nanoseconds > 0 else { return }
        latestPressUptime.withLock { latest in
            latest = max(latest ?? 0, nanoseconds)
        }
    }

    /// `eventTimestamp`（單調時鐘的奈秒）前後有沒有按壓樣本。
    public func hasPress(near eventTimestamp: UInt64) -> Bool {
        guard let latest = latestPressUptime.withLock({ $0 }) else { return false }
        if latest >= eventTimestamp { return true }
        return eventTimestamp - latest <= Self.recencyNanoseconds
    }

    public func reset() {
        latestPressUptime.withLock { $0 = nil }
    }
}
