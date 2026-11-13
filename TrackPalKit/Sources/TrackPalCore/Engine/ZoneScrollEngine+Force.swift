import CoreGraphics
import Foundation

// 壓力動作（中鍵、角落）：樣本排隊、依完整軌跡裁決、原生左鍵的攔截與補送。
extension ZoneScrollEngine {

    func recordTouchExcursion(
        to position: CGPoint,
        timestamp: Double,
        callbackArrivalUptime: Double
    ) {
        let excursionBeforeUpdate = contact.maxTouchDisplacement
        contact.maxTouchDisplacement = max(
            contact.maxTouchDisplacement,
            physicalTouchDistance(from: contact.touchStartPosition, to: position)
        )
        contact.touchExcursionTimeline.record(
            timestamp: timestamp,
            maximumExcursion: contact.maxTouchDisplacement
        )

        guard contact.cornerForceCapCrossing == nil,
              excursionBeforeUpdate < Self.cornerMaxMovementBeforeForce,
              contact.maxTouchDisplacement >= Self.cornerMaxMovementBeforeForce,
              isActiveForceCandidateCorner(contact.currentZone) else {
            return
        }

        let adjacent = adjacentScrollZones(for: contact.currentZone)
        guard adjacent.horizontal == nil, adjacent.vertical == nil else {
            return
        }

        contact.cornerForceCapCrossing = CornerForceCrossingGrace(
            crossingTimestamp: timestamp,
            crossingArrivalUptime: callbackArrivalUptime,
            maximumExcursionBeforeCrossing: excursionBeforeUpdate,
            maximumExcursionAtCrossing: contact.maxTouchDisplacement
        )
        effects.log(String(
            format: "Corner force movement cap crossed: zone=%@ touchTs=%.6f before=%.4f after=%.4f",
            String(describing: contact.currentZone),
            timestamp,
            excursionBeforeUpdate,
            contact.maxTouchDisplacement
        ))
    }

    func processForceCentroid(
        x _: Float,
        y _: Float,
        force: Float,
        sampleTimestamp: Double,
        sampleUptime: Double
    ) {
        guard contact.isTracking,
              force.isFinite,
              sampleTimestamp.isFinite,
              sampleUptime.isFinite else {
            return
        }

        // Force centroid samples are delivered on a separate event stream from
        // touch frames. Use the touch trajectory for zone/movement evidence;
        // centroid coordinates are diagnostic only and can drift at the edge.
        contact.forcePressMaxForce = max(contact.forcePressMaxForce, force)
        if contact.isTouchEnding {
            guard let endingTimestamp = contact.touchEndingTimestamp,
                  sampleTimestamp <= endingTimestamp else {
                logForceDropOnce(
                    reason: "after-lifting-boundary",
                    force: force,
                    sampleTimestamp: sampleTimestamp,
                    boundaryTimestamp: contact.touchEndingTimestamp
                )
                return
            }
        }
        guard !contact.forceGestureDisqualified else {
            logForceDropOnce(
                reason: "gesture-disqualified",
                force: force,
                sampleTimestamp: sampleTimestamp
            )
            return
        }
        guard !contact.forceEvaluationSuspendedByInvalidTouch else {
            logForceDropOnce(
                reason: "invalid-touch-suspension",
                force: force,
                sampleTimestamp: sampleTimestamp
            )
            return
        }

        if contact.currentZone == .middleClick && configuration.middleClickEnabled {
            if force >= middleClickForcePressThreshold {
                queuePendingForceEvaluation(
                    target: .middleClick,
                    force: force,
                    sampleTimestamp: sampleTimestamp,
                    sampleUptime: sampleUptime
                )
            }
            return
        }

        guard isActiveForceCandidateCorner(contact.currentZone) else { return }
        guard let cornerForceRegion = cornerForceRegion(for: contact.touchStartPosition, in: contact.currentZone) else { return }

        let assistedThreshold: Float
        if cornerForceRegion == .strict {
            assistedThreshold = cornerForceAssistedThreshold
        } else {
            assistedThreshold = cornerForcePressThreshold
        }

        if force >= assistedThreshold {
            queuePendingForceEvaluation(
                target: .corner(cornerForceRegion),
                force: force,
                sampleTimestamp: sampleTimestamp,
                sampleUptime: sampleUptime
            )
        }
    }

    func logForceDropOnce(
        reason: String,
        force: Float,
        sampleTimestamp: Double,
        boundaryTimestamp: Double? = nil
    ) {
        guard !contact.hasLoggedForceDropReason,
              contact.currentZone == .middleClick || isCornerZone(contact.currentZone) else {
            return
        }
        contact.hasLoggedForceDropReason = true

        if let boundaryTimestamp {
            effects.log(String(
                format: "Force sample dropped: reason=%@ zone=%@ force=%.1f sampleTs=%.6f boundaryTs=%.6f",
                reason,
                String(describing: contact.currentZone),
                force,
                sampleTimestamp,
                boundaryTimestamp
            ))
        } else {
            effects.log(String(
                format: "Force sample dropped: reason=%@ zone=%@ force=%.1f sampleTs=%.6f",
                reason,
                String(describing: contact.currentZone),
                force,
                sampleTimestamp
            ))
        }
    }

    func queuePendingForceEvaluation(
        target: PendingForceTarget,
        force: Float,
        sampleTimestamp: Double,
        sampleUptime: Double
    ) {
        let sample = PendingForceEvaluation(
            target: target,
            force: force,
            sampleTimestamp: sampleTimestamp,
            sampleUptime: sampleUptime
        )
        retainForceTierEndpoints(
            sample,
            in: &contact.pendingForceEvaluations,
            matchingTier: { pendingForceSamplesShareTier($0, sample) },
            orderedBefore: {
                if $0.sampleTimestamp == $1.sampleTimestamp {
                    return $0.sampleUptime < $1.sampleUptime
                }
                return $0.sampleTimestamp < $1.sampleTimestamp
            }
        )
    }

    /// Keep assisted and standard corner samples in separate slots. This lets
    /// commit choose the earliest sample that passes using its own timestamp
    /// and movement evidence instead of letting one pressure tier erase another.
    func pendingForceSamplesShareTier(
        _ lhs: PendingForceEvaluation,
        _ rhs: PendingForceEvaluation
    ) -> Bool {
        guard lhs.target == rhs.target else { return false }
        guard case .corner = lhs.target else { return true }
        return (lhs.force >= cornerForcePressThreshold)
            == (rhs.force >= cornerForcePressThreshold)
    }

    /// When a corner has already moved far enough to be meaningful but still
    /// lacks a confirming direction sample, do not let force win the same frame.
    /// The next touch sample (or release) resolves the full trajectory first.
    func shouldDeferPendingForceForScrollEvidence() -> Bool {
        guard contact.isScrollActivationPending,
              isActiveForceCandidateCorner(contact.activationOriginalZone),
              !contact.activationDeltas.isEmpty,
              contact.maxTouchDisplacement
                >= ScrollIntentGate.initialSampleMaximumPhysicalMagnitude else {
            return false
        }

        let adjacent = adjacentScrollZones(for: contact.activationOriginalZone)
        return adjacent.horizontal != nil || adjacent.vertical != nil
    }

    func hasEligiblePendingForceForNoAxisCorner() -> Bool {
        guard isActiveForceCandidateCorner(contact.activationOriginalZone) else {
            return false
        }

        let adjacent = adjacentScrollZones(for: contact.activationOriginalZone)
        guard adjacent.horizontal == nil, adjacent.vertical == nil else {
            return false
        }

        return contact.pendingForceEvaluations.contains { pending in
            guard case .corner = pending.target,
                  let decision = pendingForceDecision(for: pending) else {
                return false
            }
            if case .trigger = decision { return true }
            return false
        }
    }

    func hasTriggeringPendingForceEvaluation() -> Bool {
        contact.pendingForceEvaluations.contains { pending in
            guard let decision = pendingForceDecision(for: pending) else {
                return false
            }
            if case .trigger = decision { return true }
            return false
        }
    }

    func shouldHoldNoAxisCornerForLateForce() -> Bool {
        guard contact.isScrollActivationPending,
              isActiveForceCandidateCorner(contact.activationOriginalZone),
              let crossing = contact.cornerForceCapCrossing else {
            return false
        }

        let adjacent = adjacentScrollZones(for: contact.activationOriginalZone)
        let latestTouchTimestamp = contact.activationSampleTimestamps.last
            ?? contact.lastTouchTime
        return crossing.shouldHoldDecision(
            hasAvailableScrollAxis: adjacent.horizontal != nil
                || adjacent.vertical != nil,
            atTouchTimestamp: latestTouchTimestamp,
            decisionUptime: contact.lastTouchCallbackArrivalUptime
        )
    }

    func touchMaximumExcursion(
        for pending: PendingForceEvaluation
    ) -> CGFloat? {
        contact.touchExcursionTimeline.maximumExcursion(
            through: pending.sampleTimestamp
        )
    }

    func cornerForceMovementPolicy(
        for pending: PendingForceEvaluation
    ) -> CornerForceCrossingGrace.MovementPolicy? {
        guard case .corner = pending.target,
              let observedMaximumExcursion = touchMaximumExcursion(for: pending) else {
            return nil
        }

        let adjacent = adjacentScrollZones(for: contact.activationOriginalZone)
        guard let crossing = contact.cornerForceCapCrossing else {
            return .init(
                observedMaximumExcursion: observedMaximumExcursion,
                maximumAllowedExcursion: Self.cornerMaxMovementBeforeForce,
                usedLateStandardForceGrace: false,
                hardwareDelayAfterCrossing: nil,
                arrivalDelayAfterCrossing: nil
            )
        }

        return crossing.movementPolicy(
            hasAvailableScrollAxis: adjacent.horizontal != nil
                || adjacent.vertical != nil,
            force: pending.force,
            standardThreshold: cornerForcePressThreshold,
            forceTimestamp: pending.sampleTimestamp,
            forceSampleUptime: pending.sampleUptime,
            observedMaximumExcursion: observedMaximumExcursion
        )
    }

    func pendingForceDecision(
        for pending: PendingForceEvaluation
    ) -> ForcePressActionGate.Decision? {
        guard let movementAtForce = touchMaximumExcursion(for: pending) else {
            return nil
        }

        switch pending.target {
        case .middleClick:
            guard contact.currentZone == .middleClick, configuration.middleClickEnabled else {
                return nil
            }
            return forcePressActionGate.evaluateForce(
                force: pending.force,
                standardThreshold: middleClickForcePressThreshold,
                assistedThreshold: middleClickForcePressThreshold,
                maximumTouchExcursion: movementAtForce,
                touchDuration: max(0, pending.sampleTimestamp - contact.touchStartTime)
            )

        case let .corner(region):
            guard isCornerZone(contact.currentZone),
                  cornerForceRegion(for: contact.touchStartPosition, in: contact.currentZone) == region,
                  let movementPolicy = cornerForceMovementPolicy(for: pending) else {
                return nil
            }
            let assistedThreshold = region == .strict
                ? cornerForceAssistedThreshold
                : cornerForcePressThreshold
            return ForcePressActionGate(
                maxMovementBeforeForce: movementPolicy.maximumAllowedExcursion
            ).evaluateForce(
                force: pending.force,
                standardThreshold: cornerForcePressThreshold,
                assistedThreshold: assistedThreshold,
                maximumTouchExcursion: movementPolicy.observedMaximumExcursion,
                touchDuration: max(0, pending.sampleTimestamp - contact.touchStartTime)
            )
        }
    }

    /// A non-triggering sample inside the ordinary-to-late-force movement band
    /// must not permanently reject the gesture while a replacement standard
    /// sample can still arrive. The rejected sample is retired by commit so it
    /// cannot occupy the same-tier slot and block that replacement.
    func shouldAwaitLateStandardForce(
        candidates: [PendingForceEvaluation],
        decisions: [ForcePressActionGate.Decision?]
    ) -> Bool {
        guard candidates.count == decisions.count,
              let crossing = contact.cornerForceCapCrossing else {
            return false
        }

        let adjacent = adjacentScrollZones(for: contact.activationOriginalZone)
        let latestTouchTimestamp = contact.activationSampleTimestamps.last
            ?? contact.lastTouchTime
        let hasAvailableScrollAxis = adjacent.horizontal != nil
            || adjacent.vertical != nil

        return zip(candidates, decisions).contains { pending, decision in
            guard case .corner = pending.target,
                  case let .reject(reason, rejectedMovement)? = decision,
                  reason == .movedTooFarBeforeForce else {
                return false
            }

            return crossing.shouldAwaitReplacementCandidate(
                hasAvailableScrollAxis: hasAvailableScrollAxis,
                rejectedMovement: rejectedMovement,
                currentMaximumExcursion: contact.maxTouchDisplacement,
                touchDuration: max(0, pending.sampleTimestamp - contact.touchStartTime),
                maximumTouchDuration: forcePressMaxDuration,
                atTouchTimestamp: latestTouchTimestamp,
                decisionUptime: contact.lastTouchCallbackArrivalUptime
            )
        }
    }

    func hasTimelyPendingForceEvaluation() -> Bool {
        contact.pendingForceEvaluations.contains { pending in
            max(0, pending.sampleTimestamp - contact.touchStartTime)
                < forcePressMaxDuration
        }
    }

    func commitPendingForceEvaluation(allowDuringRelease: Bool = false) {
        guard !contact.pendingForceEvaluations.isEmpty,
              contact.isTracking,
              !contact.forceGestureDisqualified,
              !contact.forceEvaluationSuspendedByInvalidTouch,
              allowDuringRelease || !contact.isTouchEnding else {
            return
        }

        let chronologicalCandidates = contact.pendingForceEvaluations
            .filter { pending in
                guard let endingTimestamp = contact.touchEndingTimestamp else { return true }
                return pending.sampleTimestamp <= endingTimestamp
            }
            .sorted { lhs, rhs in
                if lhs.sampleTimestamp == rhs.sampleTimestamp {
                    return lhs.sampleUptime < rhs.sampleUptime
                }
                return lhs.sampleTimestamp < rhs.sampleTimestamp
            }

        guard !chronologicalCandidates.isEmpty else {
            contact.pendingForceEvaluations.removeAll()
            return
        }

        let candidateDecisions = chronologicalCandidates.map {
            pendingForceDecision(for: $0)
        }
        let preferredIndex = ForcePressCandidateSelection.preferredIndex(
            in: candidateDecisions
        )
        let hasTriggeringCandidate = preferredIndex.map { index in
            guard let decision = candidateDecisions[index] else { return false }
            if case .trigger = decision { return true }
            return false
        } ?? false

        if !hasTriggeringCandidate,
           !allowDuringRelease,
           shouldAwaitLateStandardForce(
               candidates: chronologicalCandidates,
               decisions: candidateDecisions
           ) {
            if let deferredIndex = candidateDecisions.firstIndex(where: { decision in
                guard case .reject(
                    reason: .movedTooFarBeforeForce,
                    movementBeforeForce: _
                )? = decision else {
                    return false
                }
                return true
            }) {
                let deferred = chronologicalCandidates[deferredIndex]
                let movement = touchMaximumExcursion(for: deferred) ?? .nan
                effects.log(String(
                    format: "Corner force candidate deferred: zone=%@ force=%.1f sampleTs=%.6f movement=%.4f awaiting replacement standard sample",
                    String(describing: contact.currentZone),
                    deferred.force,
                    deferred.sampleTimestamp,
                    movement
                ))
            }
            // Same-tier buffering keeps the earliest sample. Remove every
            // non-triggering candidate so a later real sample can take its slot.
            contact.pendingForceEvaluations.removeAll()
            return
        }

        let pending = chronologicalCandidates[preferredIndex ?? 0]
        contact.pendingForceEvaluations.removeAll()

        guard let movementAtForce = touchMaximumExcursion(for: pending) else {
            contact.forceGestureDisqualified = true
            effects.log(String(
                format: "Force action rejected: missing touch excursion snapshot sampleTs=%.6f",
                pending.sampleTimestamp
            ))
            return
        }

        switch pending.target {
        case .middleClick:
            guard contact.currentZone == .middleClick, configuration.middleClickEnabled else {
                contact.forceGestureDisqualified = true
                return
            }
            markForcePressSatisfied(
                force: pending.force,
                standardThreshold: middleClickForcePressThreshold,
                assistedThreshold: middleClickForcePressThreshold,
                actionGate: forcePressActionGate,
                maxMovementBeforeForce: tapMaxMovement,
                sampleTimestamp: pending.sampleTimestamp,
                movementBeforeForce: movementAtForce
            )

        case let .corner(region):
            guard isCornerZone(contact.currentZone),
                  cornerForceRegion(for: contact.touchStartPosition, in: contact.currentZone) == region else {
                contact.forceGestureDisqualified = true
                return
            }

            guard let movementPolicy = cornerForceMovementPolicy(for: pending) else {
                contact.forceGestureDisqualified = true
                return
            }

            if movementPolicy.usedLateStandardForceGrace,
               let hardwareDelay = movementPolicy.hardwareDelayAfterCrossing,
               let arrivalDelay = movementPolicy.arrivalDelayAfterCrossing,
               let crossing = contact.cornerForceCapCrossing {
                effects.log(String(
                    format: "Corner late standard-force grace applied: zone=%@ force=%.1f hardwareDelay=%.1fms arrivalDelay=%.1fms beforeCrossing=%.4f atCrossing=%.4f observedAtForce=%.4f cap=%.4f",
                    String(describing: contact.currentZone),
                    pending.force,
                    hardwareDelay * 1_000,
                    arrivalDelay * 1_000,
                    crossing.maximumExcursionBeforeCrossing,
                    crossing.maximumExcursionAtCrossing,
                    movementPolicy.observedMaximumExcursion,
                    movementPolicy.maximumAllowedExcursion
                ))
            }

            let assistedThreshold = region == .strict
                ? cornerForceAssistedThreshold
                : cornerForcePressThreshold
            markForcePressSatisfied(
                force: pending.force,
                standardThreshold: cornerForcePressThreshold,
                assistedThreshold: assistedThreshold,
                actionGate: ForcePressActionGate(
                    maxMovementBeforeForce: movementPolicy.maximumAllowedExcursion
                ),
                maxMovementBeforeForce: movementPolicy.maximumAllowedExcursion,
                sampleTimestamp: pending.sampleTimestamp,
                movementBeforeForce: movementPolicy.observedMaximumExcursion,
                cornerRegion: region
            )
        }
    }

    func markForcePressSatisfied(
        force: Float,
        standardThreshold: Float,
        assistedThreshold: Float,
        actionGate: ForcePressActionGate,
        maxMovementBeforeForce: CGFloat,
        sampleTimestamp: Double,
        movementBeforeForce: CGFloat,
        cornerRegion: CornerForceRegion? = nil
    ) {
        guard !contact.forcePressSatisfied else { return }

        let decision = actionGate.evaluateForce(
            force: force,
            standardThreshold: standardThreshold,
            assistedThreshold: assistedThreshold,
            maximumTouchExcursion: movementBeforeForce,
            touchDuration: max(0, sampleTimestamp - contact.touchStartTime)
        )

        if case let .reject(reason: reason, movementBeforeForce: movementBeforeForce) = decision {
            contact.forceGestureDisqualified = true
            if !contact.forcePressThresholdRejected {
                contact.forcePressThresholdRejected = true
                effects.log(String(format: "Force action rejected: %@ movementBeforeForce=%.4f max=%.4f",
                                             reason.rawValue, movementBeforeForce, maxMovementBeforeForce))
            }
            return
        }

        contact.forcePressSatisfied = true
        guard case let .trigger(source: triggerSource, movementBeforeForce: _) = decision else { return }
        contact.forcePressSource = triggerSource.rawValue

        if contact.currentZone == .middleClick && configuration.middleClickEnabled {
            contact.forceActionTriggered = true
            contact.forceActionPosition = contact.lastTouchPosition
            contact.gestureOutcome = .middleClick
            effects.log(String(format: "Middle click press accepted: source=%@ maxForce=%.1f movementAtForce=%.4f",
                                         contact.forcePressSource, contact.forcePressMaxForce, movementBeforeForce))
            postMiddleClickEvent()
            return
        }

        guard isCornerZone(contact.currentZone) else { return }

        contact.isScrollActivationPending = false
        contact.activationDeltas.removeAll()
        contact.activationSampleTimestamps.removeAll()
        contact.activationDeltaAccumulator = .zero
        contact.activationRawEvidenceMetrics = ScrollIntentGate.Metrics()
        contact.activationRawEvidenceIsValid = true
        contact.activeScrollRecoveryKind = nil
        contact.scrollRecoveryStartedUptime = nil
        isActivelyScrollingInZone = false
        isEvaluatingScrollCandidate = false

        let region = cornerRegion?.rawValue ?? "unknown"
        effects.log(String(format: "Corner force press accepted: zone=%@ region=%@ source=%@ maxForce=%.1f movementAtForce=%.4f",
                                     String(describing: contact.currentZone), region, contact.forcePressSource,
                                     contact.forcePressMaxForce, movementBeforeForce))

        let action = configuration.cornerActions[contact.currentZone]
        guard action != .none else { return }

        contact.forceActionTriggered = true
        contact.forceActionPosition = contact.lastTouchPosition
        contact.gestureOutcome = .cornerAction(action)
        effects.log(String(format: "Corner action accepted: zone=%@ source=%@ maxForce=%.1f",
                                     String(describing: contact.currentZone), contact.forcePressSource, contact.forcePressMaxForce))
        executeCornerAction(action)
    }

    func shouldPreemptNativePrimaryClick(for zone: ScrollZone) -> Bool {
        if zone == .middleClick {
            return configuration.middleClickEnabled
        }

        if isCornerZone(zone) {
            return isForceEnabledCorner(zone)
        }

        return false
    }

    /// 這次接觸還有沒有可能觸發壓力動作。寧可多答「有」：答錯成「有」只是
    /// 讓攔下來的左鍵晚一點放行，答錯成「沒有」則是壓力動作連帶多點一下。
    func forceActionRemainsPossible(at timestamp: Double) -> Bool {
        if contact.forceGestureDisqualified { return false }
        // 已經排隊、還沒裁決的樣本可能在下一幀觸發。
        if !contact.pendingForceEvaluations.isEmpty { return true }
        if timestamp - contact.touchStartTime >= forcePressMaxDuration {
            return false
        }
        // 中鍵的位移上限，也是角落含寬限在內的最大值。
        if contact.maxTouchDisplacement
            >= max(tapMaxMovement, CornerForceCrossingGrace.defaultMaximumExcursionAtForce) {
            return false
        }
        if contact.currentZone == .middleClick {
            return configuration.middleClickEnabled
        }
        return isActiveForceCandidateCorner(contact.currentZone)
    }

    /// 原生左鍵的攔截只需要撐到「壓力動作還有可能」為止。位移、時間或區域
    /// 已經排除壓力動作之後就提早結束，攔下來的左鍵立刻放行：從中鍵區或角落
    /// 起手的一般點擊與按住拖曳不用等到抬指。
    func releasePrimaryClickCaptureIfForceActionImpossible(
        timestamp: Double,
        gestureUptime: Double
    ) {
        guard contact.isTracking,
              contact.pendingForceClickSessionID != nil else {
            return
        }

        if contact.forceActionTriggered {
            // 壓力動作已經觸發：同一下的原生左鍵要丟掉，所以攔截繼續。但手指
            // 滑到別處之後再按就是另一下了（例如右鍵選單出來後滑去選項目），
            // 不能一路吃到抬指。
            guard let origin = contact.forceActionPosition,
                  physicalTouchDistance(
                      from: origin, to: contact.lastTouchPosition
                  ) >= tapMaxMovement else {
                return
            }
            resolvePendingPrimaryClick(
                replayCapturedClick: false,
                gestureUptime: gestureUptime
            )
            return
        }

        guard !forceActionRemainsPossible(at: timestamp) else {
            contact.forceActionRuledOutSince = nil
            return
        }

        if !contact.forceGestureDisqualified {
            // 壓力樣本走另一條事件流，最多會比觸控幀晚約 150 ms 才到；晚到
            // 的樣本是用它自己那個時間點的位移來判斷，仍然可能觸發。等過這段
            // 寬限，確定不會再有更早的樣本進來才放行。
            let ruledOutSince = contact.forceActionRuledOutSince ?? timestamp
            contact.forceActionRuledOutSince = ruledOutSince
            guard timestamp - ruledOutSince
                >= CornerForceCrossingGrace.defaultDecisionHoldWindow else {
                return
            }
        }

        resolvePendingPrimaryClick(
            replayCapturedClick: true,
            gestureUptime: gestureUptime
        )
    }

    func resolvePendingPrimaryClick(
        replayCapturedClick: Bool,
        gestureUptime: Double? = nil
    ) {
        guard let token = contact.pendingForceClickSessionID else { return }
        contact.pendingForceClickSessionID = nil

        effects.finishPrimaryClickCapture(
            token: token,
            replayCapturedClick: replayCapturedClick,
            gestureUptime: gestureUptime
        )
    }
}
