import CoreGraphics
import Foundation

// 觸控幀的主流程：接觸開始、移動、放開，以及每次接觸結束時的收尾。
extension ZoneScrollEngine {

    // MARK: - Touch Processing

    func processTouch(
        x: Float,
        y: Float,
        state: Int32,
        timestamp: Double,
        eventUptime: Double
    ) {
        guard x.isFinite,
              y.isFinite,
              timestamp.isFinite,
              eventUptime.isFinite else {
            rejectNonFiniteTouchFrame(state: state)
            return
        }

        let position = CGPoint(x: CGFloat(x), y: CGFloat(y))
        let chronologicalEventUptime: Double
        if contact.isTracking,
           timestamp.isFinite,
           timestamp >= contact.touchStartTime {
            chronologicalEventUptime = contact.touchStartUptime
                + (timestamp - contact.touchStartTime)
        } else {
            chronologicalEventUptime = eventUptime
        }

        // Touch states from MultitouchSupport:
        // 1 = not touching (hovering)
        // 2 = starting
        // 3 = making contact
        // 4 = touching/moving
        // 5 = moving (velocity)
        // 6 = lifting
        // 7 = released

        switch state {
        case 2, 3, 4, 5: // Touch active states
            guard !isContactQuarantinedUntilLift else { return }
            contact.isTouchEnding = false
            contact.touchEndingTimestamp = nil

            if !contact.isTracking {
                // 換一份全新的接觸狀態：上一輪留下的任何欄位都不會帶進來。
                contact = ContactState()
                contact.isTracking = true
                contact.lastTouchPosition = position
                contact.lastTouchTime = timestamp
                contact.lastTouchCallbackArrivalUptime = eventUptime

                // Record for tap detection
                contact.touchStartTime = timestamp
                contact.touchStartUptime = eventUptime
                contact.touchStartPosition = position
                contact.touchExcursionTimeline.begin(at: timestamp)
                pretrackingInvalidTouchFrames = 0

                nextTouchSessionID &+= 1
                contact.activeTouchSessionID = nextTouchSessionID
                contact.gestureOutcome = .pending
                contact.gesturePointerActivityGap = pointerActivityRecency
                    .lastPointerActivityEnd
                    .map { eventUptime - $0 }
                contact.gestureHorizontalScrollGap = pointerActivityRecency
                    .lastHorizontalScrollEnd
                    .map { eventUptime - $0 }
                effects.traceBegin(timestamp: timestamp)

                let preliminaryZone = determineZone(position)
                contact.currentZone = preliminaryZone
                contact.gestureInitialZone = preliminaryZone
                if shouldPreemptNativePrimaryClick(for: preliminaryZone) {
                    contact.pendingForceClickSessionID = contact.activeTouchSessionID
                    if let sessionID = contact.activeTouchSessionID {
                        effects.beginPrimaryClickCapture(
                            token: sessionID,
                            gestureUptime: chronologicalEventUptime
                        )
                    }
                } else {
                    contact.pendingForceClickSessionID = nil
                }

                if isHorizontalZone(preliminaryZone) {
                    // Cancel any running inertia from a previous scroll direction
                    effects.stopInertia()
                    beginStripIntentEvaluation(
                        zone: preliminaryZone,
                        position: position,
                        timestamp: timestamp,
                        eventUptime: eventUptime
                    )
                } else if isScrollZone(preliminaryZone) {
                    // Cancel any running inertia from a previous scroll direction
                    effects.stopInertia()
                    // Normal edge scrolling does not require force.
                    contact.isScrollActivationPending = true
                    contact.activationOriginalZone = preliminaryZone
                    contact.activationDeltas = []
                    contact.activationSampleTimestamps = []
                    contact.activationDeltaAccumulator = .zero
                    contact.activationWindowStartTimestamp = timestamp
                    contact.activationLastEvidenceUptime = nil
                    contact.scrollIntentGate = makeScrollIntentGate(for: preliminaryZone)
                    isActivelyScrollingInZone = false
                    isEvaluatingScrollCandidate = true
                    effects.log(String(format: "Gesture %llu started at (%.3f, %.3f) zone=%@ [SCROLL-PENDING]",
                                                 contact.activeTouchSessionID ?? 0, x, y, String(describing: preliminaryZone)))
                } else if isCornerZone(preliminaryZone) {
                    // Cancel any running inertia from a previous scroll direction
                    effects.stopInertia()
                    // Corner touches enter activation pending too:
                    // if user slides (not taps), promote to adjacent scroll zone.
                    contact.isScrollActivationPending = true
                    contact.activationOriginalZone = preliminaryZone
                    contact.activationDeltas = []
                    contact.activationSampleTimestamps = []
                    contact.activationDeltaAccumulator = .zero
                    contact.activationWindowStartTimestamp = timestamp
                    contact.activationLastEvidenceUptime = nil
                    contact.scrollIntentGate = nil
                    isActivelyScrollingInZone = false
                    isEvaluatingScrollCandidate = true
                    effects.log(String(format: "Gesture %llu started at (%.3f, %.3f) zone=%@ [CORNER-PENDING]",
                                                 contact.activeTouchSessionID ?? 0, x, y, String(describing: preliminaryZone)))
                } else {
                    contact.isScrollActivationPending = false
                    contact.scrollIntentGate = nil
                    isEvaluatingScrollCandidate = false
                    effects.log(String(format: "Gesture %llu started at (%.3f, %.3f) zone=%@",
                                                 contact.activeTouchSessionID ?? 0, x, y, String(describing: contact.currentZone)))
                }
            } else {
                processTrackedMovement(
                    to: position,
                    timestamp: timestamp,
                    eventUptime: chronologicalEventUptime,
                    callbackArrivalUptime: eventUptime
                )
                releasePrimaryClickCaptureIfForceActionImpossible(
                    timestamp: timestamp,
                    gestureUptime: chronologicalEventUptime
                )
            }

        case 6: // Lifting; wait for the real zero-touch/released boundary.
            guard contact.isTracking else { return }
            // MultitouchSupport can report the final physical displacement on
            // state 6. Feed it through the exact same trajectory path before
            // closing the force window, otherwise a legitimate threshold tail
            // disappears at lift.
            processTrackedMovement(
                to: position,
                timestamp: timestamp,
                eventUptime: chronologicalEventUptime,
                callbackArrivalUptime: eventUptime
            )
            contact.isTouchEnding = true
            contact.touchEndingTimestamp = timestamp

        case 7: // Released / zero-touch boundary
            guard contact.isTracking else { return }
            contact.isTouchEnding = true
            if contact.touchEndingTimestamp == nil {
                contact.touchEndingTimestamp = timestamp
            }

            finalizeScrollActivationOnRelease(
                timestamp: timestamp,
                eventUptime: chronologicalEventUptime
            )

            // A force callback can arrive after the last moving frame. Commit it
            // here only after the complete touch trajectory is known.
            if !contact.forceGestureDisqualified {
                commitPendingForceEvaluation(allowDuringRelease: true)
            }

            if contact.currentZone == .middleClick {
                handleMiddleClickTap(endPosition: contact.lastTouchPosition, endTime: timestamp)
            } else if isCornerZone(contact.currentZone) {
                handleCornerTap(zone: contact.currentZone, endPosition: contact.lastTouchPosition, endTime: timestamp)
            } else if contact.isScrollActivationPending && isScrollZone(contact.currentZone) {
                effects.log("Touch released during scroll activation pending → no scroll")
                contact.gestureOutcome = .tapInScrollZone
            } else if contact.stripIntentGate != nil {
                // 放開時仍未定案：整段都是游標或輕點，沒有送出捲動。
                contact.gestureOutcome = contact.maxTouchDisplacement
                    < PointerActivityRecency.minimumPointerExcursion
                    ? .tapInScrollZone
                    : .stripUndecided
            } else {
                // Send scroll phase ended event before starting inertia
                if contact.hasEmittedScrollBegan {
                    effects.postScroll(deltaX: 0, deltaY: 0, scrollPhase: 4, momentumPhase: 0)
                }
                startInertiaIfNeeded()
            }
            resolvePendingPrimaryClick(
                replayCapturedClick: !contact.forceActionTriggered,
                gestureUptime: chronologicalEventUptime
            )
            resetTracking()

        default:
            break
        }
    }

    func rejectNonFiniteTouchFrame(state: Int32) {
        effects.log(
            "Non-finite touch frame rejected; contact quarantined until lift"
        )
        if contact.isTracking {
            cancelActiveScrolling(reason: .nonFiniteTouch)
        }

        if state >= 7 {
            completeZeroTouchBoundary()
        } else {
            isContactQuarantinedUntilLift = true
        }
    }

    func processTrackedMovement(
        to position: CGPoint,
        timestamp: Double,
        eventUptime: Double,
        callbackArrivalUptime: Double
    ) {
        contact.lastTouchCallbackArrivalUptime = callbackArrivalUptime
        let delta = CGPoint(
            x: position.x - contact.lastTouchPosition.x,
            y: position.y - contact.lastTouchPosition.y
        )
        recordTouchExcursion(
            to: position,
            timestamp: timestamp,
            callbackArrivalUptime: callbackArrivalUptime
        )
        contact.gesturePathX += abs(delta.x)
        contact.gesturePathY += abs(delta.y)
        contact.gestureNetX += delta.x
        contact.gestureNetY += delta.y

        let wasEvaluatingScroll = contact.isScrollActivationPending

        let dt = timestamp - contact.lastTouchTime
        if dt > 0, !wasEvaluatingScroll {
            contact.velocityHistory.append((
                vx: delta.x / CGFloat(dt),
                vy: delta.y / CGFloat(dt),
                time: timestamp
            ))
            if contact.velocityHistory.count > velocityHistorySize {
                contact.velocityHistory.removeFirst()
            }
        }

        // 水平長條的候選：游標照常移動，只把位置交給 gate 判斷。
        if var gate = contact.stripIntentGate {
            let decision = gate.observe(position: position, timestamp: timestamp)
            contact.stripIntentGate = gate
            applyStripIntentDecision(decision, gate: gate)
            contact.lastTouchPosition = position
            contact.lastTouchTime = timestamp
            return
        }

        // Scroll direction gets the first decision on this touch frame. A
        // queued force sample is committed only afterwards, using the complete
        // trajectory through this hardware timestamp.
        if wasEvaluatingScroll {
            if scrollRecoveryHasExpired(at: eventUptime) {
                logActiveScrollRecoveryExhausted(
                    reason: "time/sample boundary"
                )
                expireScrollActivation()
            } else if contact.isScrollActivationPending {
                expireCornerForceWindowIfNeeded(
                    at: eventUptime,
                    activationTimestamp: timestamp
                )
                if scrollActivationEvidenceHasGoneStale(at: eventUptime) {
                    let shouldExpire = ScrollIntentRecoveryPolicy
                        .shouldExpireOnEvidenceGap(
                            hasActiveRecovery: contact.activeScrollRecoveryKind != nil,
                            isScrollOnlyCorner: isScrollOnlyCornerDecision()
                        )
                    if shouldExpire {
                        if contact.activeScrollRecoveryKind != nil {
                            logActiveScrollRecoveryExhausted(
                                reason: "evidence gap"
                            )
                        } else {
                            effects.log(
                                "Corner scroll-only candidate exhausted: evidence gap"
                            )
                        }
                        expireScrollActivation()
                    } else {
                        restartScrollActivationEvidence(at: timestamp)
                    }
                }
            }
        }

        if contact.isScrollActivationPending {
            var didAppendActivationSample = false
            let deltaMagnitude = physicalDeltaMagnitude(delta)

            // While no evidence exists, stationary callbacks keep the velocity
            // window anchored at the last real sensor frame. A deliberate flick
            // after a long hold is then measured from its actual onset, not from
            // the original touch-down time. Preserve the tiny carried net delta
            // so a genuinely slow coherent motion can still cross the sample
            // floor, while dropping the old hold-noise path around that net.
            if contact.activationDeltas.isEmpty,
               physicalDeltaMagnitude(contact.activationDeltaAccumulator)
                    < minimumEvidenceActivityDistance,
               contact.activationLastEvidenceUptime == nil,
               deltaMagnitude < minimumEvidenceActivityDistance {
                contact.activationWindowStartTimestamp = timestamp
                contact.activationRawEvidenceMetrics = ScrollIntentGate.Metrics()
                if physicalDeltaMagnitude(contact.activationDeltaAccumulator) > 0 {
                    contact.activationRawEvidenceMetrics.append(
                        ScrollIntentGate.Sample(
                            dx: contact.activationDeltaAccumulator.x,
                            dy: contact.activationDeltaAccumulator.y
                        )
                    )
                }
            }

            contact.activationRawEvidenceMetrics.append(
                ScrollIntentGate.Sample(dx: delta.x, dy: delta.y)
            )
            contact.activationDeltaAccumulator.x += delta.x
            contact.activationDeltaAccumulator.y += delta.y
            if deltaMagnitude >= minimumEvidenceActivityDistance {
                contact.activationLastEvidenceUptime = eventUptime
            }

            if physicalDeltaMagnitude(contact.activationDeltaAccumulator)
                >= minimumActivationSampleDistance {
                contact.activationDeltas.append(contact.activationDeltaAccumulator)
                contact.activationSampleTimestamps.append(timestamp)
                contact.activationDeltaAccumulator = .zero
                didAppendActivationSample = true
            }

            if didAppendActivationSample {
                applyScrollIntentResult(
                    evaluateScrollIntent(eventUptime: eventUptime),
                    eventUptime: eventUptime
                )
            }
        }

        if !contact.forceActionTriggered,
           !contact.forceGestureDisqualified,
           !shouldDeferPendingForceForScrollEvidence() {
            commitPendingForceEvaluation()
        }

        if !wasEvaluatingScroll && !contact.forceActionTriggered,
           !demoteActivatedHorizontalScrollIfNeeded(
               position: position,
               delta: delta
           ) {
            handleScroll(delta: delta, zone: contact.currentZone)
        }

        contact.lastTouchPosition = position
        contact.lastTouchTime = timestamp
    }

    func startInertiaIfNeeded() {
        guard contact.isTracking, contact.currentZone != .none, contact.currentZone != .center else { return }
        guard !contact.isScrollActivationPending else { return }
        guard contact.hasEmittedScrollBegan else { return }
        guard !contact.velocityHistory.isEmpty else { return }

        // Calculate average velocity from recent history
        var avgVx: CGFloat = 0
        var avgVy: CGFloat = 0
        for v in contact.velocityHistory {
            avgVx += v.vx
            avgVy += v.vy
        }
        avgVx /= CGFloat(contact.velocityHistory.count)
        avgVy /= CGFloat(contact.velocityHistory.count)

        // 放開時的慣性照原生雙指捲動的曲線（NativeScrollCurve）：手指速度換成
        // 起始的像素速度，太慢就不滑。方向跟捲動一致。
        var scrollVelX: CGFloat = 0
        var scrollVelY: CGFloat = 0

        switch contact.currentZone {
        case .leftEdge, .rightEdge:
            // Vertical scrolling - natural direction: finger up = content up.
            let speed = NativeScrollCurve.momentumSpeed(atLiftSpeed: avgVy)
            scrollVelY = (avgVy > 0 ? -speed : speed) * configuration.scrollMultiplier
        case .bottomEdge, .topEdge:
            // Horizontal scrolling - trackpad +X = screen +X. The finger speed
            // is scaled by the trackpad aspect ratio (~1.6:1) into the same
            // physical units as vertical.
            let speed = NativeScrollCurve.momentumSpeed(
                atLiftSpeed: avgVx * ScrollIntentGate.horizontalAspectCompensation
            )
            scrollVelX = (avgVx > 0 ? speed : -speed) * configuration.scrollMultiplier
        default:
            return
        }

        if scrollVelX != 0 || scrollVelY != 0 {
            effects.log(String(format: "Starting inertia vx=%.1f vy=%.1f", scrollVelX, scrollVelY))
            effects.startInertia(velocityX: scrollVelX, velocityY: scrollVelY)
        }
    }

    func resetTracking() {
        if let sessionID = contact.activeTouchSessionID {
            let duration = max(0, effects.now() - contact.touchStartUptime)
            var terminalRecord = String(
                format: "Gesture %llu terminal outcome=%@ initial=%@ final=%@ duration=%.3f maxExcursion=%.4f path=(%.4f,%.4f) net=(%.4f,%.4f) force=%.1f scrollEvents=%d pixels=(%lld,%lld)",
                sessionID,
                contact.gestureOutcome.description,
                String(describing: contact.gestureInitialZone),
                String(describing: contact.currentZone),
                duration,
                contact.maxTouchDisplacement,
                contact.gesturePathX,
                contact.gesturePathY,
                contact.gestureNetX,
                contact.gestureNetY,
                contact.forcePressMaxForce,
                contact.emittedScrollEventCount,
                contact.emittedScrollPixelsX,
                contact.emittedScrollPixelsY
            )
            if isCornerZone(contact.gestureInitialZone) {
                terminalRecord += String(
                    format: " rawForceSamples=%d rawForcePeak=%.1f",
                    contact.rawForceSampleCount,
                    contact.rawForcePeak
                )
            }
            effects.log(terminalRecord)

            effects.traceFinish(.init(
                sessionID: sessionID,
                initialZone: String(describing: contact.gestureInitialZone),
                finalZone: String(describing: contact.currentZone),
                outcome: contact.gestureOutcome.description,
                duration: duration,
                pointerActivityGap: contact.gesturePointerActivityGap,
                horizontalScrollGap: contact.gestureHorizontalScrollGap,
                stripDepth: Double(configuration.bottomZoneHeight),
                edgeWidth: Double(configuration.edgeZoneWidth),
                cornerSize: Double(configuration.cornerTriggerZoneSize),
                scrollPixelsX: contact.emittedScrollPixelsX,
                scrollPixelsY: contact.emittedScrollPixelsY,
                maximumForce: contact.forcePressMaxForce
            ))

            // 這次接觸如果是在移游標，記下結束時間；緊接著落在水平長條的
            // 接觸多半是接力移游標，要更強的證據才算捲動。
            let endedAsScroll = contact.gestureOutcome.endedAsScroll
            if endedAsScroll,
               isHorizontalZone(contact.currentZone),
               contact.emittedScrollEventCount > 0 {
                pointerActivityRecency.recordHorizontalScrollEnd(
                    at: effects.now()
                )
            }
            let wasInterrupted = contact.gestureOutcome.wasInterrupted
            if !endedAsScroll,
               !contact.forceActionTriggered,
               wasInterrupted
                || contact.maxTouchDisplacement
                    >= PointerActivityRecency.minimumPointerExcursion {
                pointerActivityRecency.recordPointerActivityEnd(
                    at: effects.now()
                )
            }
        }

        contact = ContactState()
        pretrackingInvalidTouchFrames = 0
        isActivelyScrollingInZone = false
        isEvaluatingScrollCandidate = false
    }
}
