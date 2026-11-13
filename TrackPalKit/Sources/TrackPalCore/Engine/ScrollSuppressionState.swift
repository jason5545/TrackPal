import os

/// event tap 判斷要不要吃掉系統事件時讀的兩個旗標。
///
/// 狀態機在 main actor 上寫，event tap 的 C callback 讀。目前 tap 也掛在 main
/// run loop，但這個型別不依賴那個前提：鎖是配置在堆積上的
/// `OSAllocatedUnfairLock`，位址固定（把 `os_unfair_lock` 當成 Swift 的 stored
/// property 用，位址不保證固定）。
public final class ScrollSuppressionState: Sendable {
    private struct Flags {
        var isActivelyScrolling = false
        var isEvaluatingCandidate = false
    }

    private let flags = OSAllocatedUnfairLock(initialState: Flags())

    public init() {}

    /// 正在某一區送出捲動：系統自己的捲動與游標移動都要擋掉。
    public var isActivelyScrolling: Bool {
        get { flags.withLock { $0.isActivelyScrolling } }
        set { flags.withLock { $0.isActivelyScrolling = newValue } }
    }

    /// 垂直邊緣或角落還在判斷是不是捲動：游標先凍住。
    public var isEvaluatingCandidate: Bool {
        get { flags.withLock { $0.isEvaluatingCandidate } }
        set { flags.withLock { $0.isEvaluatingCandidate = newValue } }
    }

    /// 游標移動事件是否該被吃掉。
    public var shouldSuppressPointerMovement: Bool {
        flags.withLock { $0.isActivelyScrolling || $0.isEvaluatingCandidate }
    }
}
