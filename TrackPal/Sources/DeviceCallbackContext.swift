import Foundation
import os

struct DeviceFingerFrameState {
    let previousFingerCount: Int32
    let contactGeneration: UInt64
}

struct BufferedForceSample {
    let contactGeneration: UInt64
    let x: Float
    let y: Float
    let force: Float
    let sampleTimestamp: Double
    let sampleUptime: Double
}

/// Thread-safe identity and force buffer owned by one MultitouchSupport device.
/// Hardware timestamps, rather than callback arrival order, assign every force
/// sample to either the active or most recently closing contact generation.
final class DeviceCallbackContext: @unchecked Sendable {
    let deviceID: Int
    private var lock = os_unfair_lock()
    private var currentFingerCount: Int32 = 0
    private var contactGeneration: UInt64 = 0
    private var currentContactStartTimestamp: Double = 0
    private var lastContactStartTimestamp: Double = 0
    private var lastContactEndTimestamp: Double = 0
    private var lastEndedContactGeneration: UInt64 = 0
    private var pendingForceSamples: [BufferedForceSample] = []
    private var hasLoggedTouchValues = false

    init(deviceID: Int) {
        self.deviceID = deviceID
    }

    func replaceFingerCount(
        with newCount: Int32,
        eventTimestamp: Double,
        eventUptime _: Double
    ) -> DeviceFingerFrameState {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let previous = currentFingerCount
        if previous == 0, newCount > 0 {
            contactGeneration &+= 1
            currentContactStartTimestamp = eventTimestamp
        } else if previous > 0, newCount == 0 {
            lastContactStartTimestamp = currentContactStartTimestamp
            lastContactEndTimestamp = eventTimestamp
            lastEndedContactGeneration = contactGeneration
        }
        currentFingerCount = newCount
        return DeviceFingerFrameState(
            previousFingerCount: previous,
            contactGeneration: contactGeneration
        )
    }

    func recordForceSample(
        x: Float,
        y: Float,
        force: Float,
        sampleTimestamp: Double,
        sampleUptime: Double
    ) -> UInt64? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        guard force >= 70, sampleTimestamp > 0 else { return nil }

        let generation: UInt64
        if currentFingerCount > 0,
           currentContactStartTimestamp <= 0
                || sampleTimestamp >= currentContactStartTimestamp {
            generation = contactGeneration
        } else if lastEndedContactGeneration > 0,
                  sampleTimestamp >= lastContactStartTimestamp,
                  sampleTimestamp <= lastContactEndTimestamp {
            generation = lastEndedContactGeneration
        } else {
            return nil
        }

        let sample = BufferedForceSample(
            contactGeneration: generation,
            x: x,
            y: y,
            force: force,
            sampleTimestamp: sampleTimestamp,
            sampleUptime: sampleUptime
        )

        let isStandardBand = force >= 100
        if let existingIndex = pendingForceSamples.firstIndex(where: {
            $0.contactGeneration == generation
                && ($0.force >= 100) == isStandardBand
        }) {
            let existing = pendingForceSamples[existingIndex]
            if sample.sampleTimestamp < existing.sampleTimestamp
                || (sample.sampleTimestamp == existing.sampleTimestamp
                    && sample.sampleUptime < existing.sampleUptime) {
                pendingForceSamples[existingIndex] = sample
            }
            return generation
        }

        pendingForceSamples.append(sample)
        if pendingForceSamples.count > 64 {
            pendingForceSamples.removeFirst()
        }
        return generation
    }

    func takePendingForceSamples(
        contactGeneration: UInt64,
        throughEventTimestamp cutoffTimestamp: Double
    ) -> [BufferedForceSample] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        guard cutoffTimestamp > 0 else { return [] }

        var matching: [BufferedForceSample] = []
        pendingForceSamples.removeAll { sample in
            guard sample.contactGeneration == contactGeneration,
                  sample.sampleTimestamp <= cutoffTimestamp else {
                return false
            }
            matching.append(sample)
            return true
        }
        return matching.sorted {
            if $0.sampleTimestamp == $1.sampleTimestamp {
                return $0.sampleUptime < $1.sampleUptime
            }
            return $0.sampleTimestamp < $1.sampleTimestamp
        }
    }

    func discardPendingForceSamples(contactGeneration: UInt64) {
        os_unfair_lock_lock(&lock)
        pendingForceSamples.removeAll {
            $0.contactGeneration == contactGeneration
        }
        if lastEndedContactGeneration == contactGeneration {
            lastEndedContactGeneration = 0
            lastContactStartTimestamp = 0
            lastContactEndTimestamp = 0
        }
        os_unfair_lock_unlock(&lock)
    }

    func claimTouchValueDiagnostic() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !hasLoggedTouchValues else { return false }
        hasLoggedTouchValues = true
        return true
    }
}
