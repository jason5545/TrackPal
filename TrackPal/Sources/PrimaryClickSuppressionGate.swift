struct PrimaryClickSuppressionGate {
    enum MouseEvent {
        case leftMouseDown
        case leftMouseUp
    }

    private var suppressUntil: UInt64 = 0
    private var isSuppressingSequence = false
    private var generation: UInt64 = 0
    private var suppressingSequenceGeneration: UInt64 = 0

    mutating func arm(now: UInt64, durationNanoseconds: UInt64) {
        generation &+= 1
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
            suppressingSequenceGeneration = generation
            return true

        case .leftMouseUp:
            if isSuppressingSequence {
                let sequenceGeneration = suppressingSequenceGeneration
                isSuppressingSequence = false
                suppressingSequenceGeneration = 0
                if sequenceGeneration == generation {
                    suppressUntil = 0
                }
                return true
            }

            guard isInsideSuppressionWindow else {
                return false
            }

            return true
        }
    }
}
