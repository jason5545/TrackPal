import CoreGraphics
import Foundation

// 多指與多裝置：誰擁有目前的接觸、手指數變化、取消進行中的手勢。
extension ZoneScrollEngine {

    // MARK: - Concurrent Touch Handling

    func acceptedPreviousFingerCount(
        deviceID: Int,
        contactGeneration: UInt64,
        touchCount: Int,
        devicePreviousFingerCount: Int,
        allowClaimNewContact: Bool = true,
        eventTimestamp: Double? = nil
    ) -> Int? {
        let isClaimingNewOwnership = touchDeviceArbitrationGate.ownerContact == nil
            && touchCount > 0
        let contact = TouchDeviceArbitrationGate.Contact(
            deviceID: deviceID,
            generation: contactGeneration
        )
        let owner = touchDeviceArbitrationGate.ownerContact
        // The callback sequencer already orders ordinary cross-device overlap.
        // While another owner is still present, omit the timestamp so the gate
        // fails closed instead of creating a deferred claim that this hot path
        // cannot replay. Once owner is nil, the timestamp still blocks a truly
        // overlapping start that arrived outside the bounded reorder window.
        let arbitrationTimestamp = touchCount == 0
            || owner == nil
            || owner == contact
            ? eventTimestamp
            : nil
        let decision = touchDeviceArbitrationGate.processTouchFrame(
            deviceID: deviceID,
            contactGeneration: contactGeneration,
            touchCount: touchCount,
            allowClaim: allowClaimNewContact,
            eventTimestamp: arbitrationTimestamp
        )
        guard decision == .accept else { return nil }
        return isClaimingNewOwnership ? 0 : devicePreviousFingerCount
    }

    func shouldAcceptForceSample(
        deviceID: Int,
        contactGeneration: UInt64
    ) -> Bool {
        touchDeviceArbitrationGate.processForce(
            deviceID: deviceID,
            contactGeneration: contactGeneration
        ) == .accept
    }

    func hasActiveGestureForForceDiagnostics() -> Bool {
        contact.isTracking
    }

    func recordRawForceDiagnostic(_ diagnostic: RawForceDiagnostic) {
        guard contact.isTracking, isCornerZone(contact.gestureInitialZone) else { return }
        contact.rawForceSampleCount += diagnostic.sampleCount
        contact.rawForcePeak = max(contact.rawForcePeak, diagnostic.maximumForce)
    }

    func handleFingerCountTransition(from oldCount: Int, to newCount: Int) {
        // Once a device enters a multi-finger gesture, do not reinterpret the
        // remaining finger as a fresh TrackPal gesture. A real zero-touch frame
        // is the only reset boundary.
        if newCount > 1 {
            if oldCount == 1 && contact.isTracking {
                cancelActiveScrolling(reason: .multiFinger)
            }
            requiresAllFingersLifted = true
            currentGestureMode = .multiFinger
            effects.log("Single→Multi transition, cancelling scroll")
        }
        else if newCount == 0 {
            if currentGestureMode == .multiFinger {
                // 多指期間（常見的是手掌邊緣加手指）多半也在移游標。
                pointerActivityRecency.recordPointerActivityEnd(
                    at: effects.now()
                )
            }
            currentGestureMode = .idle
            requiresAllFingersLifted = false
        }
        else if newCount == 1 && !requiresAllFingersLifted {
            currentGestureMode = .singleFinger
        } else if newCount == 1 {
            currentGestureMode = .multiFinger
            effects.log("Multi→Single transition ignored until all fingers lift")
        }

        activeFingerCount = newCount
    }

    func completeZeroTouchBoundary() {
        if isContactQuarantinedUntilLift {
            pointerActivityRecency.recordPointerActivityEnd(
                at: effects.now()
            )
        }
        isContactQuarantinedUntilLift = false
        pretrackingInvalidTouchFrames = 0
        contact.consecutiveInvalidTouchFrames = 0
        contact.forceEvaluationSuspendedByInvalidTouch = false
    }

    func cancelActiveScrolling(reason: GestureCancellationReason = .cancelled) {
        contact.gestureOutcome = .cancelled(reason)
        contact.forceGestureDisqualified = true
        contact.pendingForceEvaluations.removeAll()
        // 只有壓力動作真的觸發過，才把同一下的原生左鍵丟掉；其餘的取消
        // （多指、過濾、停用）照原樣放行。
        resolvePendingPrimaryClick(
            replayCapturedClick: !contact.forceActionTriggered
        )

        // Send scroll phase ended if we had started tracking
        if contact.hasEmittedScrollBegan {
            effects.postScroll(deltaX: 0, deltaY: 0, scrollPhase: 4, momentumPhase: 0)
        }
        effects.stopInertia()
        isActivelyScrollingInZone = false

        resetTracking()
    }

    func shouldProcessSingleFingerTouch() -> Bool {
        activeFingerCount == 1
            && currentGestureMode == .singleFinger
            && !requiresAllFingersLifted
    }
}
