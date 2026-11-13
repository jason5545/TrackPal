import CoreGraphics
import Foundation

// 垂直邊緣與角落的捲動意圖：緩衝位移、交給 ScrollIntentGate 判斷、
// 逾時與 recovery。水平長條不走這裡。
extension ZoneScrollEngine {

    // MARK: - Scroll Intent Detection

    enum ScrollIntentResult {
        case activated      // Direction coherent, start scrolling
        case rejected       // Direction mismatch, demote to center
        case needMoreFrames // Too little movement, need more data
    }

    func scrollActivationHasExpired(at now: Double) -> Bool {
        guard contact.isScrollActivationPending else { return false }
        if contact.activeScrollRecoveryKind != nil {
            return scrollRecoveryHasExpired(at: now)
        }
        if shouldHoldNoAxisCornerForLateForce()
            || hasEligiblePendingForceForNoAxisCorner() {
            return false
        }
        // A force-enabled corner may legitimately sit under the finger for most
        // of its one-second press window. Bounded tremor must not cancel the
        // action merely because the sensor produced 24 tiny samples.
        if isActiveForceCandidateCorner(contact.activationOriginalZone),
           contact.maxTouchDisplacement < Self.cornerMaxMovementBeforeForce {
            return false
        }
        return contact.activationDeltas.count >= activationSafetyMaxSamples
    }

    func scrollRecoveryHasExpired(at now: Double) -> Bool {
        guard contact.activeScrollRecoveryKind != nil,
              let startedUptime = contact.scrollRecoveryStartedUptime else {
            return false
        }
        return ScrollIntentRecoveryPolicy.recoveryHasExpired(
            sampleCount: contact.activationDeltas.count,
            elapsed: now - startedUptime
        )
    }

    func logActiveScrollRecoveryExhausted(reason: String) {
        let name = contact.activeScrollRecoveryKind?.logName ?? "Scroll recovery"
        effects.log("\(name) exhausted: \(reason)")
    }

    func isScrollOnlyCornerDecision() -> Bool {
        ScrollIntentRecoveryPolicy.isScrollOnlyCornerDecision(
            isCorner: isCornerZone(contact.activationOriginalZone),
            hasActiveForceCandidate: isActiveForceCandidateCorner(
                contact.activationOriginalZone
            ),
            forceGestureDisqualified: contact.forceGestureDisqualified,
            maximumExcursion: contact.maxTouchDisplacement,
            forceCandidateMaximumExcursion: Self.cornerMaxMovementBeforeForce
        )
    }

    func beginCornerScrollRecoveryIfEligible(
        at eventUptime: Double
    ) -> Bool {
        guard isCornerZone(contact.currentZone),
              !contact.forceActionTriggered,
              !contact.forceEvaluationSuspendedByInvalidTouch,
              !isContactQuarantinedUntilLift,
              activeFingerCount == 1,
              !requiresAllFingersLifted else {
            return false
        }

        let adjacent = adjacentScrollZones(for: contact.activationOriginalZone)
        let availableAxisCount = (adjacent.horizontal == nil ? 0 : 1)
            + (adjacent.vertical == nil ? 0 : 1)
        let hasTriggeringForceCandidate =
            hasTriggeringPendingForceEvaluation()

        guard ScrollIntentRecoveryPolicy.shouldBeginCornerRecovery(
            alreadyUsed: contact.hasUsedCornerScrollRecovery,
            resolutionIsAwaitingMoreEvidence: true,
            isEligibleContact: true,
            availableAxisCount: availableAxisCount,
            sampleCount: contact.activationDeltas.count,
            initialSampleLimit: activationSafetyMaxSamples,
            maximumExcursion: contact.maxTouchDisplacement,
            forceCandidateMaximumExcursion: Self.cornerMaxMovementBeforeForce,
            hasTriggeringForceCandidate: hasTriggeringForceCandidate
        ) else {
            return false
        }

        contact.hasUsedCornerScrollRecovery = true
        contact.activeScrollRecoveryKind = .cornerScrollOnly
        contact.scrollRecoveryStartedUptime = eventUptime
        contact.cornerForceWindowExpired = true
        contact.forceGestureDisqualified = true
        contact.pendingForceEvaluations.removeAll()

        let recoveryTimestamp = contact.activationSampleTimestamps.last
            ?? contact.lastTouchTime
        let discardedSampleCount = contact.activationDeltas.count
        restartScrollActivationEvidence(
            at: recoveryTimestamp,
            logReason: nil
        )
        effects.log(String(
            format: "Corner scroll-only recovery began: zone=%@ discardedSamples=%d maxExcursion=%.4f limit=%d/%.0fms",
            String(describing: contact.activationOriginalZone),
            discardedSampleCount,
            contact.maxTouchDisplacement,
            ScrollIntentRecoveryPolicy.defaultRecoveryMaxSamples,
            ScrollIntentRecoveryPolicy.defaultRecoveryMaxDuration * 1_000
        ))
        return true
    }

    /// A deadline rejection describes only the prefix seen by the first gate.
    /// At the physical right edge, a noisy foldback prefix can be followed by
    /// an unmistakable vertical scroll in the same contact. Give that suffix
    /// one fresh, short decision window without weakening the normal gate.
    func beginLateCoherenceScrollRecoveryIfEligible(
        after decision: ScrollIntentGate.Decision,
        gate: ScrollIntentGate,
        at eventUptime: Double
    ) -> Bool {
        guard case let .reject(reason) = decision,
              !contact.forceActionTriggered,
              !contact.forceEvaluationSuspendedByInvalidTouch,
              !isContactQuarantinedUntilLift,
              activeFingerCount == 1,
              !requiresAllFingersLifted,
              contact.activationRawEvidenceIsValid,
              ScrollIntentRecoveryPolicy.shouldBeginLateCoherenceRecovery(
                  alreadyUsed: contact.hasUsedLateCoherenceScrollRecovery,
                  hasActiveRecovery: contact.activeScrollRecoveryKind != nil,
                  isRightEdge: contact.activationOriginalZone == .rightEdge
                      && contact.currentZone == .rightEdge,
                  rejectionReason: reason,
                  sampleCount: gate.metrics.sampleCount,
                  initialSampleLimit: activationSafetyMaxSamples,
                  onAxisPath: gate.metrics.pathY,
                  offAxisPath: gate.metrics.normalizedPathX
              ) else {
            return false
        }

        contact.hasUsedLateCoherenceScrollRecovery = true
        contact.activeScrollRecoveryKind = .rightEdgeLateCoherence
        contact.scrollRecoveryStartedUptime = eventUptime

        let recoveryTimestamp = contact.activationSampleTimestamps.last
            ?? contact.lastTouchTime
        let discardedSampleCount = contact.activationDeltas.count
        let discardedNetX = gate.metrics.rawNetX
        let discardedNetY = gate.metrics.rawNetY
        let discardedPathX = gate.metrics.normalizedPathX
        let discardedPathY = gate.metrics.pathY
        restartScrollActivationEvidence(
            at: recoveryTimestamp,
            logReason: nil
        )
        effects.log(String(
            format: "Right-edge late-coherence recovery began: reason=%@ discardedSamples=%d net=(%.4f,%.4f) path=(%.4f,%.4f) limit=%d/%.0fms",
            String(describing: reason),
            discardedSampleCount,
            discardedNetX,
            discardedNetY,
            discardedPathX,
            discardedPathY,
            ScrollIntentRecoveryPolicy.defaultRecoveryMaxSamples,
            ScrollIntentRecoveryPolicy.defaultRecoveryMaxDuration * 1_000
        ))
        return true
    }

    func scrollActivationEvidenceHasGoneStale(at now: Double) -> Bool {
        guard contact.isScrollActivationPending,
              let lastEvidenceUptime = contact.activationLastEvidenceUptime else {
            return false
        }

        return max(0, now - lastEvidenceUptime)
            >= activationEvidenceGapDeadline
    }

    func expireCornerForceWindowIfNeeded(
        at now: Double,
        activationTimestamp: Double
    ) {
        guard isActiveForceCandidateCorner(contact.activationOriginalZone),
              max(0, now - contact.touchStartUptime) >= forcePressMaxDuration,
              !hasTimelyPendingForceEvaluation() else {
            return
        }

        contact.cornerForceWindowExpired = true
        contact.forceGestureDisqualified = true
        contact.pendingForceEvaluations.removeAll()
        // The evidence accumulated while force had priority is mostly hold
        // tremor. Once that window closes, begin a clean scroll-only decision
        // with the current physical frame instead of carrying the old foldback
        // path into the 24-sample safety deadline.
        restartScrollActivationEvidence(at: activationTimestamp)
        effects.log(
            "Corner force window expired; restarted as scroll-only candidate"
        )
    }

    /// A pause invalidates old evidence but not the user's entire contact. The
    /// next movement starts a fresh two-sample decision, so tremor followed by a
    /// deliberate slow scroll is not permanently demoted to cursor movement.
    func restartScrollActivationEvidence(
        at timestamp: Double,
        logReason: String? = "after pause"
    ) {
        contact.activationDeltas.removeAll()
        contact.activationSampleTimestamps.removeAll()
        contact.activationDeltaAccumulator = .zero
        contact.activationRawEvidenceMetrics = ScrollIntentGate.Metrics()
        contact.activationRawEvidenceIsValid = true
        contact.activationWindowStartTimestamp = timestamp
        contact.activationLastEvidenceUptime = nil
        contact.scrollIntentGate = makeScrollIntentGate(for: contact.activationOriginalZone)
        if let logReason {
            effects.log("Scroll evidence window restarted \(logReason)")
        }
    }

    func expireScrollActivation() {
        let isForceCorner = isActiveForceCandidateCorner(contact.activationOriginalZone)
        if isForceCorner, !hasTimelyPendingForceEvaluation() {
            contact.forceGestureDisqualified = true
            contact.pendingForceEvaluations.removeAll()
        }

        contact.isScrollActivationPending = false
        contact.activeScrollRecoveryKind = nil
        contact.scrollRecoveryStartedUptime = nil
        contact.activationDeltas.removeAll()
        contact.activationSampleTimestamps.removeAll()
        contact.activationDeltaAccumulator = .zero
        contact.activationRawEvidenceMetrics = ScrollIntentGate.Metrics()
        contact.activationRawEvidenceIsValid = true
        contact.activationWindowStartTimestamp = 0
        isActivelyScrollingInZone = false
        isEvaluatingScrollCandidate = false
        contact.gestureOutcome = .scrollTimeout

        if isForceCorner {
            contact.currentZone = contact.activationOriginalZone
            effects.log("Scroll timeout → restored \(contact.activationOriginalZone)")
        } else {
            contact.currentZone = .center
            effects.log("Scroll timeout → center")
        }
    }

    func applyScrollIntentResult(
        _ result: ScrollIntentResult,
        eventUptime: Double
    ) {
        switch result {
        case .activated:
            contact.forceGestureDisqualified = true
            contact.pendingForceEvaluations.removeAll()
            contact.activeScrollRecoveryKind = nil
            contact.scrollRecoveryStartedUptime = nil
            contact.isScrollActivationPending = false
            isActivelyScrollingInZone = true
            isEvaluatingScrollCandidate = false
            contact.gestureOutcome = .scroll(contact.currentZone)

            let acceptedDeltas = acceptedActivationDeltasForFlush()
            contact.horizontalExitMonitor = makeHorizontalExitMonitor(for: contact.currentZone)
            seedVelocityHistoryFromActivation(acceptedDeltas: acceptedDeltas)
            for buffered in acceptedDeltas {
                handleScroll(delta: buffered, zone: contact.currentZone)
            }
            ensureActivatedScrollEmitsAtLeastOnePixel(
                acceptedDeltas: acceptedDeltas,
                zone: contact.currentZone
            )
            contact.activationDeltas.removeAll()
            contact.activationSampleTimestamps.removeAll()
            contact.activationRawEvidenceMetrics = ScrollIntentGate.Metrics()
            contact.activationRawEvidenceIsValid = true
            effects.log("Scroll activated: \(contact.currentZone)")

        case .rejected:
            let isForceCorner = isActiveForceCandidateCorner(
                contact.activationOriginalZone
            )
            if isForceCorner {
                contact.forceGestureDisqualified = true
                contact.pendingForceEvaluations.removeAll()
            }
            contact.isScrollActivationPending = false
            contact.activeScrollRecoveryKind = nil
            contact.scrollRecoveryStartedUptime = nil
            contact.activationDeltas.removeAll()
            contact.activationSampleTimestamps.removeAll()
            contact.activationRawEvidenceMetrics = ScrollIntentGate.Metrics()
            contact.activationRawEvidenceIsValid = true
            isActivelyScrollingInZone = false
            isEvaluatingScrollCandidate = false
            contact.gestureOutcome = .scrollRejected
            if isForceCorner {
                contact.currentZone = contact.activationOriginalZone
                effects.log(
                    "Scroll rejected → restored \(contact.activationOriginalZone) (corner tap still possible)"
                )
            } else {
                contact.currentZone = .center
                effects.log("Scroll rejected → center (cursor movement)")
            }

        case .needMoreFrames:
            if scrollActivationHasExpired(at: eventUptime) {
                if !beginCornerScrollRecoveryIfEligible(at: eventUptime) {
                    expireScrollActivation()
                }
            }
        }
    }

    func finalizeScrollActivationOnRelease(
        timestamp: Double,
        eventUptime: Double
    ) {
        guard contact.isScrollActivationPending else { return }

        if scrollRecoveryHasExpired(at: eventUptime) {
            logActiveScrollRecoveryExhausted(
                reason: "release time/sample boundary"
            )
            expireScrollActivation()
            return
        }

        if scrollActivationEvidenceHasGoneStale(at: eventUptime) {
            let shouldExpire = ScrollIntentRecoveryPolicy
                .shouldExpireOnEvidenceGap(
                    hasActiveRecovery: contact.activeScrollRecoveryKind != nil,
                    isScrollOnlyCorner: isScrollOnlyCornerDecision()
                )
            if shouldExpire {
                if contact.activeScrollRecoveryKind != nil {
                    logActiveScrollRecoveryExhausted(
                        reason: "release evidence gap"
                    )
                } else {
                    effects.log(
                        "Corner scroll-only candidate exhausted: release evidence gap"
                    )
                }
                expireScrollActivation()
            } else {
                restartScrollActivationEvidence(at: timestamp)
            }
            return
        }

        guard physicalDeltaMagnitude(contact.activationDeltaAccumulator) > 0 else {
            return
        }

        let tail = ScrollIntentGate.Sample(
            dx: contact.activationDeltaAccumulator.x,
            dy: contact.activationDeltaAccumulator.y
        )
        guard ScrollIntentGate.releaseTailCanConfirm(
            tail,
            minimumPhysicalMagnitude: minimumActivationSampleDistance
        ) else {
            return
        }

        contact.activationDeltas.append(contact.activationDeltaAccumulator)
        contact.activationSampleTimestamps.append(timestamp)
        contact.activationDeltaAccumulator = .zero
        contact.activationLastEvidenceUptime = eventUptime
        applyScrollIntentResult(
            evaluateScrollIntent(eventUptime: eventUptime),
            eventUptime: eventUptime
        )
    }

    func seedVelocityHistoryFromActivation(
        acceptedDeltas: [CGPoint]
    ) {
        contact.velocityHistory.removeAll()
        let samples = acceptedDeltas.map {
            ScrollIntentGate.Sample(dx: $0.x, dy: $0.y)
        }
        let confirmedVelocities = ScrollIntentGate.confirmedVelocitySamples(
            samples: samples,
            timestamps: contact.activationSampleTimestamps,
            windowStartTimestamp: contact.activationWindowStartTimestamp
        )
        for velocity in confirmedVelocities.suffix(velocityHistorySize) {
            contact.velocityHistory.append((
                vx: velocity.vx,
                vy: velocity.vy,
                time: velocity.time
            ))
        }
    }

    /// Evaluate scroll intent from cumulative displacement and direction. A
    /// candidate is not an activation until the pure gate says so.
    func evaluateScrollIntent(
        eventUptime: Double
    ) -> ScrollIntentResult {
        guard let latestDelta = contact.activationDeltas.last else { return .needMoreFrames }

        if isCornerZone(contact.currentZone) {
            let adjacent = adjacentScrollZones(for: contact.currentZone)
            var availableAxes: Set<ScrollIntentGate.Axis> = []
            if adjacent.horizontal != nil { availableAxes.insert(.horizontal) }
            if adjacent.vertical != nil { availableAxes.insert(.vertical) }

            // Touch and force are independent sensor streams. Briefly preserve
            // a gentle no-axis crossing so a causally adjacent standard-force
            // sample can be resolved before the corner rejects it.
            if availableAxes.isEmpty {
                if shouldHoldNoAxisCornerForLateForce()
                    || hasEligiblePendingForceForNoAxisCorner() {
                    return .needMoreFrames
                }
            }

            let samples = cornerIntentSamples()
            // One callback can still be a centroid-settling jump. Even after
            // movement crosses the force cap, wait for a second physical sample
            // before committing a corner to scroll or rejection.
            guard samples.count >= 2 else { return .needMoreFrames }
            let resolution = ScrollIntentGate.resolveCorner(
                samples: samples,
                availableAxes: availableAxes,
                forceCandidateMaxExcursion: isActiveForceCandidateCorner(contact.currentZone)
                    ? Self.cornerMaxMovementBeforeForce
                    : 0,
                measuredMaximumExcursion: contact.maxTouchDisplacement
            )

            switch resolution {
            case .preserveForceCandidate:
                return .needMoreFrames

            case .awaitMoreScrollEvidence:
                return .needMoreFrames

            case let .reject(reason):
                if reason == .movementTargetsUnavailableAxis,
                   availableAxes.count == 1,
                   let availableAxis = availableAxes.first,
                   ScrollIntentGate.shouldAwaitUnavailableAxisRejection(
                       rawSamples: contact.activationDeltas.map {
                           ScrollIntentGate.Sample(dx: $0.x, dy: $0.y)
                       },
                       availableAxis: availableAxis,
                       maximumSampleCount: activationSafetyMaxSamples
                   ) {
                    return .needMoreFrames
                }
                effects.log("Corner scroll rejected: \(reason)")
                return .rejected

            case let .activate(axis):
                if contact.activeScrollRecoveryKind == .cornerScrollOnly,
                   !ScrollIntentRecoveryPolicy.cornerRecoveryCanActivate(
                       freshSampleCount: contact.activationDeltas.count
                   ) {
                    return .needMoreFrames
                }
                if contact.activationDeltas.count < 3,
                   cornerInitialSampleContradicts(axis: axis) {
                    return .needMoreFrames
                }
                // 轉成水平捲動要是一段近乎水平的直線滑動，跟水平長條
                // 本身的條件一致。
                if axis == .horizontal,
                   !ScrollIntentGate.cornerHorizontalPromotionQualifies(
                       samples: samples
                   ) {
                    return .needMoreFrames
                }
                guard let promotedZone = axis == .horizontal ? adjacent.horizontal : adjacent.vertical else {
                    return .rejected
                }

                contact.currentZone = promotedZone
                contact.scrollIntentGate = nil
                effects.log("Corner direction committed → \(promotedZone)")
                return .activated
            }
        }

        guard var gate = contact.scrollIntentGate ?? makeScrollIntentGate(for: contact.currentZone) else {
            return .rejected
        }

        let decision = gate.observe(deltaX: latestDelta.x, deltaY: latestDelta.y)
        contact.scrollIntentGate = gate

        let prefixElapsed = (contact.activationSampleTimestamps.last
            ?? contact.activationWindowStartTimestamp) - contact.activationWindowStartTimestamp
        let prefixIsRecoverable = contact.activationOriginalZone == .rightEdge
            && gate.isRecoverableOutwardBoundaryPrefix(outwardSign: 1)
            && contact.activationRawEvidenceIsValid
            && ScrollIntentRecoveryPolicy.rawOutwardPrefixIsWithinBounds(
                rawMetrics: contact.activationRawEvidenceMetrics,
                outwardSign: 1,
                elapsed: prefixElapsed
            )
        if ScrollIntentRecoveryPolicy.shouldBeginEarlyOutwardRecovery(
            alreadyUsed: contact.hasUsedEarlyOutwardScrollRecovery,
            prefixIsRecoverable: prefixIsRecoverable
        ) {
            contact.hasUsedEarlyOutwardScrollRecovery = true
            contact.activeScrollRecoveryKind = .rightEdgeOutwardSettling
            contact.scrollRecoveryStartedUptime = eventUptime
            let recoveryTimestamp = contact.activationSampleTimestamps.last
                ?? contact.lastTouchTime
            effects.log(String(
                format: "Right-edge outward settling recovery: samples=%d net=(%.4f,%.4f) path=(%.4f,%.4f) rawPath=%.4f elapsed=%.1fms",
                gate.metrics.sampleCount,
                gate.metrics.rawNetX,
                gate.metrics.rawNetY,
                gate.metrics.normalizedPathX,
                gate.metrics.pathY,
                contact.activationRawEvidenceMetrics.normalizedPathLength,
                prefixElapsed * 1_000
            ))
            restartScrollActivationEvidence(
                at: recoveryTimestamp,
                logReason: nil
            )
            return .needMoreFrames
        }

        if decision != .pending {
            effects.log(String(
                format: "Scroll intent %@ samples=%d net=(%.4f,%.4f) path=(%.4f,%.4f)",
                String(describing: decision),
                gate.metrics.sampleCount,
                gate.metrics.rawNetX,
                gate.metrics.rawNetY,
                gate.metrics.normalizedPathX,
                gate.metrics.pathY
            ))
        }

        if beginLateCoherenceScrollRecoveryIfEligible(
            after: decision,
            gate: gate,
            at: eventUptime
        ) {
            return .needMoreFrames
        }

        return scrollIntentResult(from: decision)
    }

    func cornerIntentSamples() -> [ScrollIntentGate.Sample] {
        contact.activationDeltas.enumerated().map { index, delta in
            let sample = ScrollIntentGate.Sample(dx: delta.x, dy: delta.y)
            return index == 0
                ? ScrollIntentGate.winsorizedInitialSample(sample)
                : sample
        }
    }

    func cornerInitialSampleContradicts(
        axis: ScrollIntentGate.Axis
    ) -> Bool {
        guard let first = contact.activationDeltas.first else { return false }
        let normalizedX = abs(
            first.x * ScrollIntentGate.horizontalAspectCompensation
        )
        let vertical = abs(first.y)
        guard hypot(normalizedX, vertical)
                > ScrollIntentGate.initialSampleMaximumPhysicalMagnitude else {
            return false
        }

        switch axis {
        case .horizontal:
            return vertical > normalizedX
        case .vertical:
            return normalizedX > vertical
        }
    }

    func acceptedActivationDeltasForFlush() -> [CGPoint] {
        if let gate = contact.scrollIntentGate,
           !gate.acceptedSamples.isEmpty {
            return gate.acceptedSamples.map {
                CGPoint(x: $0.dx, y: $0.dy)
            }
        }

        return cornerIntentSamples().map {
            CGPoint(x: $0.dx, y: $0.dy)
        }
    }

    /// 只服務垂直邊緣。水平長條由 `HorizontalStripIntentGate` 判斷，不會走到
    /// 這個緩衝式的 gate。
    func makeScrollIntentGate(for zone: ScrollZone) -> ScrollIntentGate? {
        guard scrollAxis(for: zone) == .vertical else { return nil }
        return ScrollIntentGate(
            axis: .vertical,
            configuration: .init(maxSamples: activationSafetyMaxSamples)
        )
    }
}
