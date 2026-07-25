import Foundation
import os

/// Contact-frame timestamps arrive in seconds, while force-centroid timestamps
/// use the framework's raw millisecond clock. Convert them before generation
/// assignment and cutoff comparisons so both callback streams share one scale.
func forceCentroidTimestampInTouchSeconds(_ rawTimestamp: Double) -> Double {
    guard rawTimestamp.isFinite, rawTimestamp > 0 else { return 0 }
    return rawTimestamp / 1_000.0
}

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

/// Raw force telemetry is intentionally separate from action candidates.
/// Values below the assisted threshold are useful for diagnosing misses, but
/// must never enter the force gate or change its decisions.
struct RawForceDiagnostic: Equatable {
    let sampleCount: Int
    let maximumForce: Float
}

struct PendingForcePayload {
    let actionSamples: [BufferedForceSample]
    let rawDiagnostic: RawForceDiagnostic?
}

private struct RawForceObservation {
    let contactGeneration: UInt64
    let latestSampleTimestamp: Double
    let sampleCount: Int
    let maximumForce: Float
}

/// Force callbacks can outpace a delayed touch-frame commit. Keep both ends of
/// each threshold tier so an early rejected sample cannot erase the later
/// replacement, while an early valid sample is never overwritten by latest-wins.
func retainForceTierEndpoints<Sample>(
    _ sample: Sample,
    in samples: inout [Sample],
    matchingTier: (Sample) -> Bool,
    orderedBefore: (Sample, Sample) -> Bool
) {
    var tierSamples = samples.filter(matchingTier)
    tierSamples.append(sample)
    tierSamples.sort(by: orderedBefore)

    samples.removeAll(where: matchingTier)
    guard let earliest = tierSamples.first else { return }
    samples.append(earliest)

    guard let latest = tierSamples.last,
          orderedBefore(earliest, latest) else {
        return
    }
    samples.append(latest)
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
    private var pendingRawForceObservations: [RawForceObservation] = []
    private let maximumRawForceObservationsPerGeneration = 4_096
    private var hasLoggedTouchValues = false
    private var hasLoggedForceValues = false

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

        guard force.isFinite,
              sampleTimestamp.isFinite,
              sampleUptime.isFinite,
              force >= 0,
              sampleTimestamp > 0,
              sampleUptime >= 0 else {
            return nil
        }

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
        pendingRawForceObservations.append(RawForceObservation(
            contactGeneration: generation,
            latestSampleTimestamp: sampleTimestamp,
            sampleCount: 1,
            maximumForce: force
        ))
        compactRawForceObservationsIfNeeded(for: generation)

        // Preserve the existing action threshold exactly. Sub-threshold force
        // is retained only in raw telemetry for terminal diagnostics.
        guard force >= 70 else { return nil }

        let isStandardBand = force >= 100
        retainForceTierEndpoints(
            sample,
            in: &pendingForceSamples,
            matchingTier: {
                $0.contactGeneration == generation
                    && ($0.force >= 100) == isStandardBand
            },
            orderedBefore: {
                if $0.sampleTimestamp == $1.sampleTimestamp {
                    return $0.sampleUptime < $1.sampleUptime
                }
                return $0.sampleTimestamp < $1.sampleTimestamp
            }
        )
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

    func takePendingRawForceDiagnostic(
        contactGeneration: UInt64,
        throughEventTimestamp cutoffTimestamp: Double
    ) -> RawForceDiagnostic? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        guard cutoffTimestamp > 0 else { return nil }

        var sampleCount = 0
        var maximumForce: Float = 0
        pendingRawForceObservations.removeAll { observation in
            guard observation.contactGeneration == contactGeneration,
                  observation.latestSampleTimestamp <= cutoffTimestamp else {
                return false
            }
            sampleCount += observation.sampleCount
            maximumForce = max(maximumForce, observation.maximumForce)
            return true
        }

        guard sampleCount > 0 else { return nil }
        return RawForceDiagnostic(
            sampleCount: sampleCount,
            maximumForce: maximumForce
        )
    }

    /// The physical zero boundary consumes action and telemetry under the same
    /// lock. A force callback can therefore land wholly before or after
    /// finalization, but never between two destructive drains and disappear
    /// from only one side of the terminal record.
    func finalizePendingForcePayload(
        contactGeneration: UInt64,
        throughEventTimestamp cutoffTimestamp: Double
    ) -> PendingForcePayload {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        var actionSamples: [BufferedForceSample] = []
        var rawSampleCount = 0
        var rawMaximumForce: Float = 0

        pendingForceSamples.removeAll { sample in
            guard sample.contactGeneration == contactGeneration else {
                return false
            }
            if cutoffTimestamp > 0,
               sample.sampleTimestamp <= cutoffTimestamp {
                actionSamples.append(sample)
            }
            return true
        }
        pendingRawForceObservations.removeAll { observation in
            guard observation.contactGeneration == contactGeneration else {
                return false
            }
            if cutoffTimestamp > 0,
               observation.latestSampleTimestamp <= cutoffTimestamp {
                rawSampleCount += observation.sampleCount
                rawMaximumForce = max(
                    rawMaximumForce,
                    observation.maximumForce
                )
            }
            return true
        }

        if lastEndedContactGeneration == contactGeneration {
            lastEndedContactGeneration = 0
            lastContactStartTimestamp = 0
            lastContactEndTimestamp = 0
        }

        actionSamples.sort {
            if $0.sampleTimestamp == $1.sampleTimestamp {
                return $0.sampleUptime < $1.sampleUptime
            }
            return $0.sampleTimestamp < $1.sampleTimestamp
        }
        let rawDiagnostic = rawSampleCount > 0
            ? RawForceDiagnostic(
                sampleCount: rawSampleCount,
                maximumForce: rawMaximumForce
            )
            : nil
        return PendingForcePayload(
            actionSamples: actionSamples,
            rawDiagnostic: rawDiagnostic
        )
    }

    func discardPendingForceSamples(contactGeneration: UInt64) {
        os_unfair_lock_lock(&lock)
        pendingForceSamples.removeAll {
            $0.contactGeneration == contactGeneration
        }
        pendingRawForceObservations.removeAll {
            $0.contactGeneration == contactGeneration
        }
        if lastEndedContactGeneration == contactGeneration {
            lastEndedContactGeneration = 0
            lastContactStartTimestamp = 0
            lastContactEndTimestamp = 0
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Raw telemetry normally drains every accepted touch frame. Bound the
    /// exceptional pretracking/non-owner case without losing its peak or count.
    /// The compacted prefix is released only once its latest timestamp reaches
    /// the caller's hardware cutoff, so future evidence is never pulled early.
    private func compactRawForceObservationsIfNeeded(for generation: UInt64) {
        // Keep the ordinary callback path O(1). The more expensive per-
        // generation sort is needed only after the whole context reaches the
        // exceptional backlog limit.
        guard pendingRawForceObservations.count
                > maximumRawForceObservationsPerGeneration else {
            return
        }
        var generationObservations = pendingRawForceObservations
            .filter { $0.contactGeneration == generation }
        guard generationObservations.count
                > maximumRawForceObservationsPerGeneration else {
            return
        }

        generationObservations.sort {
            $0.latestSampleTimestamp < $1.latestSampleTimestamp
        }
        let retainedCount = maximumRawForceObservationsPerGeneration / 2
        let compactedCount = generationObservations.count - retainedCount
        let prefix = generationObservations.prefix(compactedCount)
        let compacted = RawForceObservation(
            contactGeneration: generation,
            latestSampleTimestamp: prefix.last?.latestSampleTimestamp ?? 0,
            sampleCount: prefix.reduce(0) { $0 + $1.sampleCount },
            maximumForce: prefix.reduce(0) {
                max($0, $1.maximumForce)
            }
        )

        pendingRawForceObservations.removeAll {
            $0.contactGeneration == generation
        }
        pendingRawForceObservations.append(compacted)
        pendingRawForceObservations.append(
            contentsOf: generationObservations.suffix(retainedCount)
        )
    }

    func claimTouchValueDiagnostic() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !hasLoggedTouchValues else { return false }
        hasLoggedTouchValues = true
        return true
    }

    func claimForceValueDiagnostic() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !hasLoggedForceValues else { return false }
        hasLoggedForceValues = true
        return true
    }
}

/// Shared by the private-framework callback and tests so timestamp decoding
/// cannot silently drift away from the generation buffer again.
@discardableResult
func recordForceCentroidSample(
    x: Float,
    y: Float,
    force: Float,
    rawTimestamp: Double,
    sampleUptime: Double,
    into callbackContext: DeviceCallbackContext
) -> UInt64? {
    callbackContext.recordForceSample(
        x: x,
        y: y,
        force: force,
        sampleTimestamp: forceCentroidTimestampInTouchSeconds(
            rawTimestamp
        ),
        sampleUptime: sampleUptime
    )
}
