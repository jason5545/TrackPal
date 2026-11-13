import CoreGraphics
import Foundation

// 輕觸／大面積過濾，以及無效幀對進行中手勢的影響。
extension ZoneScrollEngine {

    // MARK: - Touch Filtering (Scroll2-style)

    enum TouchFilterResult {
        case valid
        case tooLight
        case tooLarge
    }

    /// Process touch with filtering applied. Called from the callback on main thread.
    func processFilteredTouch(
        x: Float,
        y: Float,
        state: Int32,
        timestamp: Double,
        eventUptime: Double,
        density: Float,
        majorAxis: Float,
        minorAxis: Float
    ) {
        guard x.isFinite,
              y.isFinite,
              timestamp.isFinite,
              eventUptime.isFinite,
              density.isFinite,
              majorAxis.isFinite,
              minorAxis.isFinite else {
            rejectNonFiniteTouchFrame(state: state)
            return
        }

        // Density drops to 0 while lifting, so release frames bypass filtering.
        // Quarantine is cleared only at the real released/zero-touch boundary.
        if state >= 6 {
            if contact.isTracking {
                processTouch(
                    x: x,
                    y: y,
                    state: state,
                    timestamp: timestamp,
                    eventUptime: eventUptime
                )
                recordTraceFrame(
                    x: x, y: y, state: state, timestamp: timestamp,
                    density: density, majorAxis: majorAxis,
                    minorAxis: minorAxis, isValid: true
                )
            }
            if state >= 7 {
                isContactQuarantinedUntilLift = false
                contact.consecutiveInvalidTouchFrames = 0
                pretrackingInvalidTouchFrames = 0
                contact.forceEvaluationSuspendedByInvalidTouch = false
            }
            return
        }

        guard !isContactQuarantinedUntilLift else { return }

        let result = classifyTouchValues(density: density, majorAxis: majorAxis, minorAxis: minorAxis)

        switch result {
        case .valid:
            contact.consecutiveInvalidTouchFrames = 0
            pretrackingInvalidTouchFrames = 0
            contact.forceEvaluationSuspendedByInvalidTouch = false
            processTouch(
                x: x,
                y: y,
                state: state,
                timestamp: timestamp,
                eventUptime: eventUptime
            )
            recordTraceFrame(
                x: x, y: y, state: state, timestamp: timestamp,
                density: density, majorAxis: majorAxis,
                minorAxis: minorAxis, isValid: true
            )

        case .tooLight:
            recordTraceFrame(
                x: x, y: y, state: state, timestamp: timestamp,
                density: density, majorAxis: majorAxis,
                minorAxis: minorAxis, isValid: false
            )
            handleInvalidTouchFrame(
                x: x,
                y: y,
                timestamp: timestamp,
                eventUptime: eventUptime,
                reason: .filterLight,
                detail: String(format: "density=%.3f", density)
            )

        case .tooLarge:
            recordTraceFrame(
                x: x, y: y, state: state, timestamp: timestamp,
                density: density, majorAxis: majorAxis,
                minorAxis: minorAxis, isValid: false
            )
            handleInvalidTouchFrame(
                x: x,
                y: y,
                timestamp: timestamp,
                eventUptime: eventUptime,
                reason: .filterLarge,
                detail: String(format: "major=%.3f minor=%.3f", majorAxis, minorAxis)
            )
        }
    }

    func recordTraceFrame(
        x: Float,
        y: Float,
        state: Int32,
        timestamp: Double,
        density: Float,
        majorAxis: Float,
        minorAxis: Float,
        isValid: Bool
    ) {
        guard contact.isTracking else { return }
        effects.traceFrame(
            timestamp: timestamp,
            x: x,
            y: y,
            state: state,
            density: density,
            majorAxis: majorAxis,
            minorAxis: minorAxis,
            isValid: isValid
        )
    }

    func handleInvalidTouchFrame(
        x: Float,
        y: Float,
        timestamp: Double,
        eventUptime: Double,
        reason: GestureCancellationReason,
        detail: String
    ) {
        if contact.isTracking {
            recordInvalidTouchTrajectory(
                x: x,
                y: y,
                timestamp: timestamp,
                eventUptime: eventUptime
            )
            contact.forceEvaluationSuspendedByInvalidTouch = true
            contact.consecutiveInvalidTouchFrames += 1

            if contact.activeScrollRecoveryKind != nil {
                contact.activationRawEvidenceIsValid = false
                logActiveScrollRecoveryExhausted(
                    reason: "invalid touch (\(detail))"
                )
                contact.forceGestureDisqualified = true
                contact.pendingForceEvaluations.removeAll()
                expireScrollActivation()
                contact.gestureOutcome = .scrollRecoveryInvalid
                return
            }

            // An invalid frame is a hard evidence boundary even before the
            // three-frame contact debounce decides whether to quarantine. Do
            // not let a later valid or lifting frame complete a scroll prefix
            // that was collected before the contact started looking like a
            // palm/large touch.
            if contact.isScrollActivationPending {
                restartScrollActivationEvidence(
                    at: timestamp,
                    logReason: nil
                )
            }
            if var gate = contact.stripIntentGate {
                let decision = gate.interrupt()
                contact.stripIntentGate = gate
                applyStripIntentDecision(decision, gate: gate)
            }

            guard contact.consecutiveInvalidTouchFrames >= invalidTouchFramesBeforeCancellation else {
                return
            }

            effects.log(
                "Touch cancelled after \(contact.consecutiveInvalidTouchFrames) consecutive invalid frames (\(detail))"
            )
            isContactQuarantinedUntilLift = true
            cancelActiveScrolling(reason: reason)
            return
        }

        // A normal finger can spend several scan frames below the density
        // threshold while settling onto the pad. Before tracking starts, wait
        // for it to become valid; only palm-sized contacts earn quarantine.
        if reason == .filterLight {
            // Palm quarantine requires consecutive large-contact evidence.
            // A light/settling frame breaks that sequence.
            pretrackingInvalidTouchFrames = 0
            return
        }

        pretrackingInvalidTouchFrames += 1
        guard pretrackingInvalidTouchFrames >= invalidTouchFramesBeforeCancellation else {
            return
        }

        isContactQuarantinedUntilLift = true
        effects.log(
            "Contact quarantined before activation after \(pretrackingInvalidTouchFrames) invalid frames (\(detail))"
        )
    }

    func recordInvalidTouchTrajectory(
        x: Float,
        y: Float,
        timestamp: Double,
        eventUptime: Double
    ) {
        contact.lastTouchCallbackArrivalUptime = eventUptime
        let position = CGPoint(x: CGFloat(x), y: CGFloat(y))
        let delta = CGPoint(
            x: position.x - contact.lastTouchPosition.x,
            y: position.y - contact.lastTouchPosition.y
        )

        recordTouchExcursion(
            to: position,
            timestamp: timestamp,
            callbackArrivalUptime: eventUptime
        )
        contact.gesturePathX += abs(delta.x)
        contact.gesturePathY += abs(delta.y)
        contact.gestureNetX += delta.x
        contact.gestureNetY += delta.y
        contact.lastTouchPosition = position
        contact.lastTouchTime = timestamp
        contact.activationDeltaAccumulator = .zero

        // Invalid samples are useful as trajectory boundaries but must never
        // contribute momentum or a single huge recovery delta.
        contact.velocityHistory.removeAll()
    }

    /// Classify touch using extracted values (thread-safe, no MTTouch struct needed)
    func classifyTouchValues(density: Float, majorAxis: Float, minorAxis: Float) -> TouchFilterResult {
        // Light touch filter: reject hovering / barely touching contacts
        if configuration.filterLightTouches {
            if density < configuration.lightTouchDensityThreshold {
                return .tooLight
            }
        }

        // Large touch filter: reject palm/wrist sized contacts
        if configuration.filterLargeTouches {
            if majorAxis > configuration.largeTouchMajorAxisThreshold {
                return .tooLarge
            }
            if minorAxis > configuration.largeTouchMinorAxisThreshold {
                return .tooLarge
            }
        }

        return .valid
    }

    func physicalTouchDistance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        physicalDeltaMagnitude(
            CGPoint(x: end.x - start.x, y: end.y - start.y)
        )
    }

    func physicalDeltaMagnitude(_ delta: CGPoint) -> CGFloat {
        hypot(
            delta.x * ScrollIntentGate.horizontalAspectCompensation,
            delta.y
        )
    }
}
