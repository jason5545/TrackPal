struct PrimaryClickSuppressionGate {
    enum MouseEvent {
        case leftMouseDown
        case leftMouseUp
    }

    private var suppressUntil: UInt64 = 0
    private var isSuppressingSequence = false

    mutating func arm(now: UInt64, durationNanoseconds: UInt64) {
        suppressUntil = max(suppressUntil, now + durationNanoseconds)
    }

    mutating func shouldSuppress(event: MouseEvent, now: UInt64) -> Bool {
        let isInsideSuppressionWindow = now <= suppressUntil

        switch event {
        case .leftMouseDown:
            guard isInsideSuppressionWindow else {
                return false
            }

            isSuppressingSequence = true
            return true

        case .leftMouseUp:
            if isSuppressingSequence {
                isSuppressingSequence = false
                suppressUntil = 0
                return true
            }

            guard isInsideSuppressionWindow else {
                return false
            }

            suppressUntil = 0
            return true
        }
    }
}
