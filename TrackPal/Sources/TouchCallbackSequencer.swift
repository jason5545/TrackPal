import Dispatch

/// Deterministic reorder buffer for independently delivered touch callbacks.
///
/// Every event must age for `minimumHoldNanoseconds`. Ready events are released
/// only from the hardware-timestamp-ordered prefix, so an earlier event that is
/// still inside its grace period blocks a later event that is otherwise ready.
struct TouchCallbackOrderingBuffer<Payload> {
    private struct PendingEvent {
        let orderingTimestamp: Double
        let sequence: UInt64
        let eligibleUptimeNanoseconds: UInt64
        let payload: Payload
    }

    let minimumHoldNanoseconds: UInt64

    private var pendingEvents: [PendingEvent] = []
    private var nextSequence: UInt64 = 0
    private var latestValidHardwareTimestamp: Double?

    init(minimumHoldNanoseconds: UInt64 = 8_000_000) {
        self.minimumHoldNanoseconds = minimumHoldNanoseconds
    }

    var pendingCount: Int {
        pendingEvents.count
    }

    var nextReleaseUptimeNanoseconds: UInt64? {
        pendingEvents.first?.eligibleUptimeNanoseconds
    }

    mutating func enqueue(
        hardwareTimestamp: Double,
        arrivalUptimeNanoseconds: UInt64,
        payload: Payload
    ) {
        nextSequence &+= 1

        let orderingTimestamp: Double
        if hardwareTimestamp.isFinite, hardwareTimestamp > 0 {
            orderingTimestamp = hardwareTimestamp
            if let latestValidHardwareTimestamp {
                self.latestValidHardwareTimestamp = max(
                    latestValidHardwareTimestamp,
                    hardwareTimestamp
                )
            } else {
                latestValidHardwareTimestamp = hardwareTimestamp
            }
        } else {
            // An invalid timestamp cannot be compared with hardware time. Place
            // it at the latest known watermark, then use sequence as a stable
            // tie-breaker. This keeps the comparator total and deterministic.
            orderingTimestamp = latestValidHardwareTimestamp
                ?? -Double.greatestFiniteMagnitude
        }

        let (deadline, overflow) = arrivalUptimeNanoseconds.addingReportingOverflow(
            minimumHoldNanoseconds
        )
        pendingEvents.append(PendingEvent(
            orderingTimestamp: orderingTimestamp,
            sequence: nextSequence,
            eligibleUptimeNanoseconds: overflow ? UInt64.max : deadline,
            payload: payload
        ))
        pendingEvents.sort(by: eventPrecedes)
    }

    mutating func releaseReadyEvents(
        at uptimeNanoseconds: UInt64
    ) -> [Payload] {
        var readyCount = 0
        for event in pendingEvents {
            guard event.eligibleUptimeNanoseconds <= uptimeNanoseconds else {
                break
            }
            readyCount += 1
        }

        guard readyCount > 0 else { return [] }
        let readyEvents = Array(pendingEvents.prefix(readyCount))
        pendingEvents.removeFirst(readyCount)
        return readyEvents.map(\.payload)
    }

    private func eventPrecedes(_ lhs: PendingEvent, _ rhs: PendingEvent) -> Bool {
        if lhs.orderingTimestamp != rhs.orderingTimestamp {
            return lhs.orderingTimestamp < rhs.orderingTimestamp
        }
        return lhs.sequence < rhs.sequence
    }
}

/// Runtime wrapper around `TouchCallbackOrderingBuffer`.
///
/// A fixed per-event delay is intentional: unlike whole-batch debounce, a
/// continuous frame stream keeps releasing aged callbacks instead of waiting
/// for the gesture to end.
final class TouchCallbackSequencer: @unchecked Sendable {
    static let shared = TouchCallbackSequencer()
    static let minimumHoldNanoseconds: UInt64 = 8_000_000

    private typealias Action = @Sendable () -> Void

    private let queue = DispatchQueue(
        label: "com.jasonchien.TrackPal.touch-callback-sequencer",
        qos: .userInteractive
    )
    private var orderingBuffer = TouchCallbackOrderingBuffer<Action>(
        minimumHoldNanoseconds: minimumHoldNanoseconds
    )
    private var isWakeScheduled = false

    private init() {}

    func enqueue(
        timestamp: Double,
        action: @escaping @Sendable () -> Void
    ) {
        let arrivalUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            orderingBuffer.enqueue(
                hardwareTimestamp: timestamp,
                arrivalUptimeNanoseconds: arrivalUptimeNanoseconds,
                payload: action
            )
            scheduleNextWakeIfNeeded()
        }
    }

    private func scheduleNextWakeIfNeeded() {
        guard !isWakeScheduled,
              let deadline = orderingBuffer.nextReleaseUptimeNanoseconds else {
            return
        }

        isWakeScheduled = true
        queue.asyncAfter(
            deadline: DispatchTime(uptimeNanoseconds: deadline)
        ) { [self] in
            isWakeScheduled = false
            releaseReadyEvents()
        }
    }

    private func releaseReadyEvents() {
        let actions = orderingBuffer.releaseReadyEvents(
            at: DispatchTime.now().uptimeNanoseconds
        )

        if !actions.isEmpty {
            DispatchQueue.main.async {
                for action in actions {
                    action()
                }
            }
        }

        scheduleNextWakeIfNeeded()
    }
}
