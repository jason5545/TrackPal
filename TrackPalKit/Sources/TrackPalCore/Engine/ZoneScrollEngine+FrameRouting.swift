import Foundation

/// 單指幀裡狀態機會用到的欄位。
public struct TouchSample: Sendable, Equatable {
    public var x: Float
    public var y: Float
    /// MultitouchSupport 的 touch state：1 懸停、2–5 接觸中、6 抬起中、7 已放開。
    public var state: Int32
    public var density: Float
    public var majorAxis: Float
    public var minorAxis: Float

    public init(
        x: Float,
        y: Float,
        state: Int32,
        density: Float,
        majorAxis: Float,
        minorAxis: Float
    ) {
        self.x = x
        self.y = y
        self.state = state
        self.density = density
        self.majorAxis = majorAxis
        self.minorAxis = minorAxis
    }
}

/// 一幀已經在 callback 執行緒上登記過手指數、等著交給狀態機的輸入。
///
/// callback 執行緒只做 `DeviceCallbackContext.routeContactFrame`（加鎖、很短），
/// 產生的值丟進 `TouchCallbackSequencer` 依硬體時間排序，最後在 main actor 上
/// `deliver(to:)`。
public struct RoutedTouchFrame: Sendable {
    enum Kind: Sendable {
        case single(TouchSample)
        case zero
        case multi
    }

    let kind: Kind
    let context: DeviceCallbackContext
    let touchCount: Int
    public let timestamp: Double
    let eventUptime: Double
    let previousFingerCount: Int
    let contactGeneration: UInt64
}

extension DeviceCallbackContext {
    /// 在 callback 執行緒上呼叫。回傳 nil 表示這一幀不需要送進狀態機
    /// （懸停幀，或單指幀卻沒有 touch 資料）。
    public func routeContactFrame(
        touchCount: Int,
        touch: TouchSample?,
        timestamp: Double,
        eventUptime: Double
    ) -> RoutedTouchFrame? {
        let fingerFrameState = replaceFingerCount(
            with: Int32(clamping: touchCount),
            eventTimestamp: timestamp,
            eventUptime: eventUptime
        )

        let kind: RoutedTouchFrame.Kind
        if touchCount == 1 {
            guard let touch else { return nil }
            // A state-1 frame is hover, not a failed physical contact. Ignoring
            // it here lets a later state 2/3 in the same raw generation claim
            // input instead of being quarantined by the arbitration gate until
            // zero.
            guard touch.state != 1 else { return nil }
            kind = .single(touch)
        } else if touchCount == 0 {
            kind = .zero
        } else {
            kind = .multi
        }

        return RoutedTouchFrame(
            kind: kind,
            context: self,
            touchCount: touchCount,
            timestamp: timestamp,
            eventUptime: eventUptime,
            previousFingerCount: Int(fingerFrameState.previousFingerCount),
            contactGeneration: fingerFrameState.contactGeneration
        )
    }
}

extension RoutedTouchFrame {
    /// 把這一幀交給狀態機：裝置仲裁、手指數變化、壓力樣本排空、觸控處理。
    @MainActor
    public func deliver(to engine: ZoneScrollEngine) {
        let deviceID = context.deviceID
        guard engine.isDeviceCallbackActive(deviceID: deviceID) else { return }

        switch kind {
        case let .single(touch):
            guard let acceptedPrevCount = engine.acceptedPreviousFingerCount(
                deviceID: deviceID,
                contactGeneration: contactGeneration,
                touchCount: touchCount,
                devicePreviousFingerCount: previousFingerCount,
                allowClaimNewContact: touch.state == 2 || touch.state == 3,
                eventTimestamp: timestamp
            ) else { return }

            if touchCount != acceptedPrevCount {
                engine.handleFingerCountTransition(
                    from: acceptedPrevCount, to: touchCount
                )
            }

            // Check debounce after multi→single transition
            guard engine.shouldProcessSingleFingerTouch() else { return }

            // Existing contacts drain force before the touch frame so scroll
            // direction still gets the first commit decision on this frame.
            // A new contact establishes its zone first, then drains any force
            // sample that raced ahead of the touch frame.
            if acceptedPrevCount > 0 {
                engine.drainPendingRawForceDiagnostic(
                    from: context,
                    contactGeneration: contactGeneration,
                    throughEventTimestamp: timestamp
                )
                engine.drainPendingForceSamples(
                    from: context,
                    contactGeneration: contactGeneration,
                    throughEventTimestamp: timestamp
                )
            }

            engine.processFilteredTouch(
                x: touch.x,
                y: touch.y,
                state: touch.state,
                timestamp: timestamp,
                eventUptime: eventUptime,
                density: touch.density,
                majorAxis: touch.majorAxis,
                minorAxis: touch.minorAxis
            )

            if acceptedPrevCount == 0 {
                engine.drainPendingRawForceDiagnostic(
                    from: context,
                    contactGeneration: contactGeneration,
                    throughEventTimestamp: timestamp
                )
                engine.drainPendingForceSamples(
                    from: context,
                    contactGeneration: contactGeneration,
                    throughEventTimestamp: timestamp
                )
            }

        case .zero:
            // Drain samples captured before the physical zero boundary while
            // this contact still owns the arbitration gate.
            let finalizedForcePayload = context.finalizePendingForcePayload(
                contactGeneration: contactGeneration,
                throughEventTimestamp: timestamp
            )
            engine.processFinalizedForcePayload(
                finalizedForcePayload,
                from: context,
                contactGeneration: contactGeneration
            )

            guard let acceptedPrevCount = engine.acceptedPreviousFingerCount(
                deviceID: deviceID,
                contactGeneration: contactGeneration,
                touchCount: touchCount,
                devicePreviousFingerCount: previousFingerCount,
                eventTimestamp: timestamp
            ) else { return }

            if touchCount != acceptedPrevCount {
                engine.handleFingerCountTransition(
                    from: acceptedPrevCount, to: touchCount
                )
            }
            engine.processTouch(
                x: 0,
                y: 0,
                state: 7,
                timestamp: timestamp,
                eventUptime: eventUptime
            )
            engine.completeZeroTouchBoundary()

        case .multi:
            // Multi-finger: handle transition, let system handle gestures
            guard let acceptedPrevCount = engine.acceptedPreviousFingerCount(
                deviceID: deviceID,
                contactGeneration: contactGeneration,
                touchCount: touchCount,
                devicePreviousFingerCount: previousFingerCount,
                eventTimestamp: timestamp
            ) else { return }

            // Capture raw force before a multi-finger transition cancels and
            // logs the active single-finger gesture. Action samples retain the
            // existing post-transition ordering below.
            engine.drainPendingRawForceDiagnostic(
                from: context,
                contactGeneration: contactGeneration,
                throughEventTimestamp: timestamp
            )
            if touchCount != acceptedPrevCount {
                engine.handleFingerCountTransition(
                    from: acceptedPrevCount, to: touchCount
                )
            }
            engine.drainPendingForceSamples(
                from: context,
                contactGeneration: contactGeneration,
                throughEventTimestamp: timestamp
            )
        }
    }
}

extension ZoneScrollEngine {

    func drainPendingForceSamples(
        from callbackContext: DeviceCallbackContext,
        contactGeneration: UInt64,
        throughEventTimestamp cutoffTimestamp: Double
    ) {
        let samples = callbackContext.takePendingForceSamples(
            contactGeneration: contactGeneration,
            throughEventTimestamp: cutoffTimestamp
        )
        guard !samples.isEmpty else { return }

        guard shouldAcceptForceSample(
            deviceID: callbackContext.deviceID,
            contactGeneration: contactGeneration
        ) else {
            return
        }

        for sample in samples {
            processForceCentroid(
                x: sample.x,
                y: sample.y,
                force: sample.force,
                sampleTimestamp: sample.sampleTimestamp,
                sampleUptime: sample.sampleUptime
            )
        }
    }

    func drainPendingRawForceDiagnostic(
        from callbackContext: DeviceCallbackContext,
        contactGeneration: UInt64,
        throughEventTimestamp cutoffTimestamp: Double
    ) {
        // Do not destructively drain force that raced ahead of the first valid
        // touch. A light/invalid settling frame may precede the actual corner
        // start within the same device generation.
        guard hasActiveGestureForForceDiagnostics() else { return }
        guard let diagnostic = callbackContext.takePendingRawForceDiagnostic(
            contactGeneration: contactGeneration,
            throughEventTimestamp: cutoffTimestamp
        ) else {
            return
        }

        guard shouldAcceptForceSample(
            deviceID: callbackContext.deviceID,
            contactGeneration: contactGeneration
        ) else {
            return
        }
        recordRawForceDiagnostic(diagnostic)
    }

    func processFinalizedForcePayload(
        _ payload: PendingForcePayload,
        from callbackContext: DeviceCallbackContext,
        contactGeneration: UInt64
    ) {
        guard payload.rawDiagnostic != nil || !payload.actionSamples.isEmpty else {
            return
        }
        guard shouldAcceptForceSample(
            deviceID: callbackContext.deviceID,
            contactGeneration: contactGeneration
        ) else {
            return
        }

        if let diagnostic = payload.rawDiagnostic {
            recordRawForceDiagnostic(diagnostic)
        }
        for sample in payload.actionSamples {
            processForceCentroid(
                x: sample.x,
                y: sample.y,
                force: sample.force,
                sampleTimestamp: sample.sampleTimestamp,
                sampleUptime: sample.sampleUptime
            )
        }
    }
}
