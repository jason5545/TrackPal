import CoreGraphics

/// 純資料驅動的捲動意圖判斷，不讀取時間、設定或任何 Cocoa singleton。
///
/// 呼叫端每次送入一個「相對於上一幀」的位移。Gate 會同時檢查：
/// - 從觸控起點算起的淨位移
/// - 手指實際走過的路徑
/// - 目標軸是否主導，以及沿目標方向是否前後一致
///
/// 水平位移會固定乘上 1.6，補償 trackpad normalized coordinate 的長寬比。
struct ScrollIntentGate {
    static let horizontalAspectCompensation: CGFloat = 1.6
    static let defaultForceCandidateMaxExcursion: CGFloat = 0.025
    /// 第一筆 hardware delta 可能混有 contact centroid settling。保留方向，
    /// 但限制它能帶進 intent gate 的物理距離，避免一筆跳動主宰整個手勢。
    static let initialSampleMaximumPhysicalMagnitude: CGFloat = 0.008

    enum Axis: Hashable {
        case horizontal
        case vertical
    }

    struct Sample: Equatable {
        let dx: CGFloat
        let dy: CGFloat

        init(dx: CGFloat, dy: CGFloat) {
            self.dx = dx
            self.dy = dy
        }
    }

    struct TimedVelocity: Equatable {
        let vx: CGFloat
        let vy: CGFloat
        let time: Double
    }

    struct Configuration: Equatable {
        let maxSamples: Int
        let activationDisplacement: CGFloat
        let fastActivationDisplacement: CGFloat
        let activationDominance: CGFloat
        let fastActivationDominance: CGFloat
        let minimumAxisCoherence: CGFloat
        let minimumPathCoherence: CGFloat
        let offAxisRejectionDisplacement: CGFloat
        let offAxisRejectionDominance: CGFloat

        init(
            maxSamples: Int = 8,
            activationDisplacement: CGFloat = 0.008,
            fastActivationDisplacement: CGFloat = 0.016,
            activationDominance: CGFloat = 0.68,
            fastActivationDominance: CGFloat = 0.82,
            minimumAxisCoherence: CGFloat = 0.75,
            minimumPathCoherence: CGFloat = 0.62,
            offAxisRejectionDisplacement: CGFloat = 0.010,
            offAxisRejectionDominance: CGFloat = 0.72
        ) {
            // Off-axis 至少要觀察三筆才能拒絕，因此 maxSamples 也不能更短。
            self.maxSamples = max(3, maxSamples)
            self.activationDisplacement = activationDisplacement
            self.fastActivationDisplacement = fastActivationDisplacement
            self.activationDominance = activationDominance
            self.fastActivationDominance = fastActivationDominance
            self.minimumAxisCoherence = minimumAxisCoherence
            self.minimumPathCoherence = minimumPathCoherence
            self.offAxisRejectionDisplacement = offAxisRejectionDisplacement
            self.offAxisRejectionDominance = offAxisRejectionDominance
        }
    }

    enum Decision: Equatable {
        case pending
        case activate(axis: Axis)
        case reject(reason: RejectionReason)
    }

    enum RejectionReason: Equatable {
        /// 位移與路徑都太小，較像 tap 或原地停留。
        case insufficientMovement
        /// 淨位移清楚指向另一個軸。
        case offAxisDominant
        /// 路徑不小，但反覆折返，沒有穩定方向。
        case incoherentMovement
        /// 方向合理，但在觀察期限內仍未累積到啟動距離。
        case insufficientOnAxisMovement
    }

    enum CornerResolution: Equatable {
        /// 還在 force/tap 候選範圍內，不可搶先 promotion。
        case preserveForceCandidate(maximumExcursion: CGFloat)
        /// Force 已因位移失效，但方向證據還不足；保留 scroll-only
        /// candidate，等待後續 sample，不能把曖昧的第二幀直接判死。
        case awaitMoreScrollEvidence(maximumExcursion: CGFloat)
        /// 已通過完整軌跡門檻；呼叫端應直接開始捲動，不可再用 net delta 做第二次 gate。
        case activate(axis: Axis)
        case reject(reason: CornerRejectionReason)
    }

    enum CornerRejectionReason: Equatable {
        case noAvailableAxis
        case ambiguousDirection
        case incoherentMovement
        case movementTargetsUnavailableAxis
    }

    struct Metrics: Equatable {
        fileprivate(set) var sampleCount = 0
        fileprivate(set) var rawNetX: CGFloat = 0
        fileprivate(set) var rawNetY: CGFloat = 0
        fileprivate(set) var normalizedPathX: CGFloat = 0
        fileprivate(set) var pathY: CGFloat = 0
        fileprivate(set) var normalizedPathLength: CGFloat = 0
        fileprivate(set) var maximumCompensatedExcursion: CGFloat = 0

        var normalizedNetX: CGFloat {
            rawNetX * ScrollIntentGate.horizontalAspectCompensation
        }

        var netY: CGFloat {
            rawNetY
        }

        var normalizedNetDistance: CGFloat {
            Self.magnitude(x: normalizedNetX, y: netY)
        }

        var pathCoherence: CGFloat {
            guard normalizedPathLength > 0 else { return 0 }
            return min(1, normalizedNetDistance / normalizedPathLength)
        }

        mutating func append(_ sample: Sample) {
            sampleCount += 1
            rawNetX += sample.dx
            rawNetY += sample.dy

            let normalizedDx = sample.dx * ScrollIntentGate.horizontalAspectCompensation
            normalizedPathX += abs(normalizedDx)
            pathY += abs(sample.dy)
            normalizedPathLength += Self.magnitude(x: normalizedDx, y: sample.dy)
            maximumCompensatedExcursion = max(
                maximumCompensatedExcursion,
                Self.magnitude(x: normalizedNetX, y: rawNetY)
            )
        }

        fileprivate func onAxisNet(for axis: Axis) -> CGFloat {
            switch axis {
            case .horizontal:
                return abs(normalizedNetX)
            case .vertical:
                return abs(netY)
            }
        }

        fileprivate func offAxisNet(for axis: Axis) -> CGFloat {
            switch axis {
            case .horizontal:
                return abs(netY)
            case .vertical:
                return abs(normalizedNetX)
            }
        }

        fileprivate func onAxisPath(for axis: Axis) -> CGFloat {
            switch axis {
            case .horizontal:
                return normalizedPathX
            case .vertical:
                return pathY
            }
        }

        fileprivate func offAxisPath(for axis: Axis) -> CGFloat {
            switch axis {
            case .horizontal:
                return pathY
            case .vertical:
                return normalizedPathX
            }
        }

        fileprivate func axisDominance(for axis: Axis) -> CGFloat {
            let onAxis = onAxisNet(for: axis)
            let offAxis = offAxisNet(for: axis)
            let total = onAxis + offAxis
            return total > 0 ? onAxis / total : 0.5
        }

        fileprivate func axisCoherence(for axis: Axis) -> CGFloat {
            let path = onAxisPath(for: axis)
            return path > 0 ? min(1, onAxisNet(for: axis) / path) : 0
        }

        fileprivate func offAxisCoherence(for axis: Axis) -> CGFloat {
            let path = offAxisPath(for: axis)
            return path > 0 ? min(1, offAxisNet(for: axis) / path) : 0
        }

        private static func magnitude(x: CGFloat, y: CGFloat) -> CGFloat {
            (x * x + y * y).squareRoot()
        }
    }

    let axis: Axis
    let configuration: Configuration
    private(set) var metrics = Metrics()
    /// 真正被 gate 納入判斷的 samples。第一筆會先 winsorize，後續保持原值。
    /// 呼叫端啟動捲動時應 replay 這一組，而不是另外保存未經 gate 處理的 delta。
    private(set) var acceptedSamples: [Sample] = []
    private(set) var observationCount = 0
    private var provisionalInitialSample: Sample?
    private var provisionalInitialContradictsAxis = false
    private var terminalDecision: Decision?

    init(axis: Axis, configuration: Configuration = Configuration()) {
        self.axis = axis
        self.configuration = configuration
    }

    /// 加入一幀位移並回傳目前決策。啟動或拒絕後，後續呼叫會維持同一結果，直到 `reset()`。
    mutating func observe(_ sample: Sample) -> Decision {
        if let terminalDecision {
            return terminalDecision
        }

        observationCount += 1

        // 第一筆只建立候選，不可單獨 activate/reject。第二筆抵達後，才把
        // winsorized 第一筆與原值第二筆一起交給完整軌跡判斷。
        if observationCount == 1 {
            provisionalInitialSample = Self.winsorizedInitialSample(sample)
            provisionalInitialContradictsAxis = Self.sample(
                sample,
                isStronglyOffAxisFor: axis
            )
            return .pending
        }

        if let provisionalInitialSample {
            appendAccepted(provisionalInitialSample)
            self.provisionalInitialSample = nil
        }
        appendAccepted(sample)

        let needsThirdSampleForInitialContradiction =
            provisionalInitialContradictsAxis && observationCount < 3
        if metrics.sampleCount >= 2,
           !needsThirdSampleForInitialContradiction,
           qualifiesForActivationAtCurrentSampleCount {
            return finish(with: .activate(axis: axis))
        }

        // [AI-Codex: 2026-07-24] 不讓單一 noisy frame 把手勢直接判死。
        // 只有累積三筆後仍清楚往錯軸前進，才提早拒絕。
        if metrics.sampleCount >= 3, isClearlyOffAxis {
            return finish(with: .reject(reason: .offAxisDominant))
        }

        if metrics.sampleCount >= configuration.maxSamples {
            return finish(with: .reject(reason: rejectionReasonAtDeadline))
        }

        return .pending
    }

    mutating func observe(deltaX: CGFloat, deltaY: CGFloat) -> Decision {
        observe(Sample(dx: deltaX, dy: deltaY))
    }

    mutating func reset() {
        metrics = Metrics()
        acceptedSamples.removeAll()
        observationCount = 0
        provisionalInitialSample = nil
        provisionalInitialContradictsAxis = false
        terminalDecision = nil
    }

    /// A very short outward nudge at the physical right boundary is usually
    /// contact settling, not a request to move the pointer back into the app.
    /// Runtime may discard this prefix once and open a fresh decision window;
    /// activation thresholds in that second window remain unchanged.
    func isRecoverableOutwardBoundaryPrefix(
        outwardSign: CGFloat,
        maximumSampleCount: Int = 6,
        maximumCompensatedOffAxisDisplacement: CGFloat = 0.016
    ) -> Bool {
        guard axis == .vertical,
              case .some(.reject(reason: .offAxisDominant)) = terminalDecision,
              outwardSign.isFinite,
              outwardSign != 0,
              maximumSampleCount > 0,
              maximumCompensatedOffAxisDisplacement.isFinite,
              maximumCompensatedOffAxisDisplacement > 0,
              metrics.sampleCount <= maximumSampleCount else {
            return false
        }

        let signedOutwardNet = metrics.normalizedNetX * outwardSign
        return signedOutwardNet > 0
            && signedOutwardNet < maximumCompensatedOffAxisDisplacement
            && metrics.normalizedPathX < maximumCompensatedOffAxisDisplacement
            && abs(metrics.netY) < configuration.activationDisplacement
    }

    private mutating func appendAccepted(_ sample: Sample) {
        acceptedSamples.append(sample)
        metrics.append(sample)
    }

    static func winsorizedInitialSample(_ sample: Sample) -> Sample {
        let normalizedX = sample.dx * horizontalAspectCompensation
        let physicalMagnitude = hypot(normalizedX, sample.dy)

        guard physicalMagnitude > initialSampleMaximumPhysicalMagnitude else {
            return sample
        }

        let scale = initialSampleMaximumPhysicalMagnitude / physicalMagnitude
        return Sample(dx: sample.dx * scale, dy: sample.dy * scale)
    }

    /// A release tail below the normal sample floor may complete displacement,
    /// but it must not manufacture the extra observation required to confirm a
    /// provisional first jump. Runtime therefore appends only a physically
    /// meaningful tail as a new activation sample.
    static func releaseTailCanConfirm(
        _ sample: Sample,
        minimumPhysicalMagnitude: CGFloat
    ) -> Bool {
        hypot(
            sample.dx * horizontalAspectCompensation,
            sample.dy
        ) >= minimumPhysicalMagnitude
    }

    /// A raw first sample that strongly targets the unavailable axis is still
    /// provisional centroid-settling evidence. Keep the corner recoverable while
    /// later samples can dilute it, but never beyond the runtime safety bound.
    /// This is called only after the full corner resolver reports
    /// `movementTargetsUnavailableAxis`.
    static func shouldAwaitUnavailableAxisRejection(
        rawSamples: [Sample],
        availableAxis: Axis,
        maximumSampleCount: Int
    ) -> Bool {
        guard rawSamples.count < max(3, maximumSampleCount),
              let first = rawSamples.first else {
            return false
        }

        guard sample(first, isStronglyOffAxisFor: availableAxis) else {
            return false
        }

        // Judge the follow-up path without the provisional first jump. Keep
        // waiting only while those real confirmation samples are still
        // recoverable. A clearly continued unavailable-axis path can terminate
        // earlier than the outer 24-sample deadline.
        var recoveryGate = ScrollIntentGate(
            axis: availableAxis,
            configuration: Configuration(
                maxSamples: max(3, maximumSampleCount - 1)
            )
        )
        var recoveryDecision: Decision = .pending
        for followUp in rawSamples.dropFirst() {
            recoveryDecision = recoveryGate.observe(followUp)
            if recoveryDecision != .pending {
                break
            }
        }

        return recoveryDecision == .pending
    }

    /// The first activation sample is deliberately provisional and may be
    /// winsorized. It is useful for displacement replay, but its touch-down time
    /// interval is not trustworthy enough to seed inertia. Velocities start at
    /// the first confirming sample instead; a real multi-frame flick still keeps
    /// its confirming high-speed samples.
    static func confirmedVelocitySamples(
        samples: [Sample],
        timestamps: [Double],
        windowStartTimestamp: Double
    ) -> [TimedVelocity] {
        let count = min(samples.count, timestamps.count)
        guard count >= 2,
              windowStartTimestamp.isFinite else {
            return []
        }

        let alignedSamples = Array(samples.suffix(count))
        let alignedTimestamps = Array(timestamps.suffix(count))
        guard let firstTimestamp = alignedTimestamps.first,
              firstTimestamp.isFinite,
              firstTimestamp >= windowStartTimestamp else {
            return []
        }

        var result: [TimedVelocity] = []
        var previousTime = firstTimestamp
        for index in 1..<count {
            let sampleTime = alignedTimestamps[index]
            guard sampleTime.isFinite else { continue }

            let dt = sampleTime - previousTime
            if dt > 0 {
                let sample = alignedSamples[index]
                result.append(TimedVelocity(
                    vx: sample.dx / CGFloat(dt),
                    vy: sample.dy / CGFloat(dt),
                    time: sampleTime
                ))
            }
            previousTime = sampleTime
        }

        return result
    }

    private static func sample(
        _ sample: Sample,
        isStronglyOffAxisFor axis: Axis
    ) -> Bool {
        let normalizedX = abs(sample.dx * horizontalAspectCompensation)
        let vertical = abs(sample.dy)
        let physicalMagnitude = hypot(normalizedX, vertical)
        guard physicalMagnitude > initialSampleMaximumPhysicalMagnitude else {
            return false
        }

        switch axis {
        case .horizontal:
            return vertical > normalizedX
        case .vertical:
            return normalizedX > vertical
        }
    }

    /// 角落的 samples 也是逐幀 delta，不是絕對座標。
    ///
    /// 一般會在 compensated excursion 未達 force 邊界時保留 corner force/tap；
    /// 但至少兩筆、距離與方向都很明確的 scroll 可以提早勝出。達到邊界時 force
    /// 已不能成立；方向仍曖昧但路徑連貫時，先轉成 scroll-only candidate 等下一筆，
    /// 不因 sample 數增加就把可恢復的方向判斷提早判死。觀察上限由 runtime
    /// 呼叫端負責。
    ///
    /// `.activate` 已是最終 scroll activation。呼叫端不可把整段 net displacement
    /// 偽裝成一筆 sample 再送進另一個 gate，否則會遺失原始 path/coherence。
    static func resolveCorner(
        samples: [Sample],
        availableAxes: Set<Axis>,
        forceCandidateMaxExcursion: CGFloat = defaultForceCandidateMaxExcursion,
        measuredMaximumExcursion: CGFloat? = nil
    ) -> CornerResolution {
        var metrics = Metrics()
        samples.forEach { metrics.append($0) }
        let maximumExcursion = max(
            metrics.maximumCompensatedExcursion,
            measuredMaximumExcursion ?? 0
        )

        let isInsideForceCandidate =
            maximumExcursion < forceCandidateMaxExcursion

        if isInsideForceCandidate {
            guard metrics.sampleCount >= 2,
                  let dominantAxis = dominantAxis(
                      from: metrics,
                      minimumDominance: 0.85
                  ),
                  metrics.onAxisNet(for: dominantAxis) >= 0.012,
                  metrics.axisCoherence(for: dominantAxis) >= 0.85,
                  metrics.pathCoherence >= 0.80 else {
                return .preserveForceCandidate(
                    maximumExcursion: maximumExcursion
                )
            }

            // With no adjacent scroll axis there is nothing for movement to
            // promote into. Keep the force candidate alive while it is still
            // inside the existing movement cap; the force gate remains the
            // authority on pressure, duration, and final excursion.
            guard !availableAxes.isEmpty else {
                return .preserveForceCandidate(
                    maximumExcursion: maximumExcursion
                )
            }
            guard availableAxes.contains(dominantAxis) else {
                return .reject(reason: .movementTargetsUnavailableAxis)
            }

            return .activate(axis: dominantAxis)
        }

        guard !availableAxes.isEmpty else {
            return .reject(reason: .noAvailableAxis)
        }

        // 單筆越界仍必須符合 fast thresholds；兩筆以上使用一般 gate 的
        // standard thresholds。Runtime 另外要求至少兩筆 physical sample，
        // 所以 corner 不會因一筆 centroid settling jump 啟動。
        let standardConfiguration = Configuration()
        let isSingleSample = metrics.sampleCount == 1
        let requiredDisplacement = isSingleSample
            ? standardConfiguration.fastActivationDisplacement
            : standardConfiguration.activationDisplacement
        let requiredDominance = isSingleSample
            ? standardConfiguration.fastActivationDominance
            : standardConfiguration.activationDominance

        guard let dominantAxis = dominantAxis(
            from: metrics,
            minimumDominance: requiredDominance
        ) else {
            // A coherent diagonal can still converge after initial centroid
            // settling noise. Only a clear foldback is terminal here; runtime
            // owns the finite sample deadline for an otherwise coherent trace.
            if metrics.sampleCount >= 3, metrics.pathCoherence < 0.35 {
                return .reject(reason: .incoherentMovement)
            }
            return .awaitMoreScrollEvidence(
                maximumExcursion: maximumExcursion
            )
        }

        guard availableAxes.contains(dominantAxis) else {
            return .reject(reason: .movementTargetsUnavailableAxis)
        }

        guard metrics.axisCoherence(for: dominantAxis)
                >= standardConfiguration.minimumAxisCoherence,
              metrics.pathCoherence
                >= standardConfiguration.minimumPathCoherence else {
            if metrics.sampleCount < 3 {
                return .awaitMoreScrollEvidence(
                    maximumExcursion: maximumExcursion
                )
            }
            return .reject(reason: .incoherentMovement)
        }

        guard metrics.onAxisNet(for: dominantAxis) >= requiredDisplacement else {
            return .awaitMoreScrollEvidence(
                maximumExcursion: maximumExcursion
            )
        }

        return .activate(axis: dominantAxis)
    }

    private static func dominantAxis(
        from metrics: Metrics,
        minimumDominance: CGFloat
    ) -> Axis? {
        let horizontalNet = abs(metrics.normalizedNetX)
        let verticalNet = abs(metrics.netY)
        let totalNet = horizontalNet + verticalNet
        guard totalNet > 0 else { return nil }

        let horizontalShare = horizontalNet / totalNet
        if horizontalShare >= minimumDominance {
            return .horizontal
        }
        if 1 - horizontalShare >= minimumDominance {
            return .vertical
        }
        return nil
    }

    /// Two samples are enough only for an unambiguously fast gesture. A normal
    /// threshold crossing needs one more valid sample, which gives the touch
    /// filter a frame to expose a contact that is growing into a palm/large
    /// touch before any buffered scroll is emitted.
    private var qualifiesForActivationAtCurrentSampleCount: Bool {
        let usesFastThresholds = metrics.sampleCount == 2
        let requiredDisplacement = usesFastThresholds
            ? configuration.fastActivationDisplacement
            : configuration.activationDisplacement
        let requiredDominance = usesFastThresholds
            ? configuration.fastActivationDominance
            : configuration.activationDominance

        return metrics.onAxisNet(for: axis) >= requiredDisplacement
            && metrics.axisDominance(for: axis) >= requiredDominance
            && metrics.axisCoherence(for: axis) >= configuration.minimumAxisCoherence
            && metrics.pathCoherence >= configuration.minimumPathCoherence
    }

    private var isClearlyOffAxis: Bool {
        let offAxisDominance = 1 - metrics.axisDominance(for: axis)
        return metrics.offAxisNet(for: axis) >= configuration.offAxisRejectionDisplacement
            && offAxisDominance >= configuration.offAxisRejectionDominance
            && metrics.offAxisCoherence(for: axis) >= configuration.minimumAxisCoherence
            && metrics.pathCoherence >= configuration.minimumPathCoherence
    }

    private var rejectionReasonAtDeadline: RejectionReason {
        let onAxisNet = metrics.onAxisNet(for: axis)
        let offAxisNet = metrics.offAxisNet(for: axis)

        if metrics.normalizedPathLength < configuration.activationDisplacement {
            return .insufficientMovement
        }

        if offAxisNet > onAxisNet {
            return .offAxisDominant
        }

        if metrics.axisCoherence(for: axis) < configuration.minimumAxisCoherence
            || metrics.pathCoherence < configuration.minimumPathCoherence {
            return .incoherentMovement
        }

        return .insufficientOnAxisMovement
    }

    private mutating func finish(with decision: Decision) -> Decision {
        terminalDecision = decision
        return decision
    }
}

/// Pure boundaries for the one-shot scroll recovery windows. Runtime owns the
/// state transition; this type keeps raw-prefix and exact sample/time limits
/// testable without exposing TrackpadZoneScroller's mutable gesture state.
struct ScrollIntentRecoveryPolicy {
    static let defaultRecoveryMaxSamples = 16
    static let defaultRecoveryMaxDuration: Double = 0.150
    static let defaultOutwardPrefixMaxDuration: Double = 0.150
    static let minimumCornerRecoveryConfirmationSamples = 3
    static let minimumLateCoherenceRecoveryOnAxisPath: CGFloat = 0.020
    static let minimumLateCoherenceRecoveryPathDominance: CGFloat = 1.5

    /// The gate winsorizes its first sample, so its metrics alone cannot prove
    /// that the physical prefix was small. Check the untouched samples too:
    /// recovery is reserved for a short, coherent nudge toward the trackpad's
    /// outer boundary, never a clear cursor move hidden by winsorization.
    static func rawOutwardPrefixIsWithinBounds(
        samples: [ScrollIntentGate.Sample],
        outwardSign: CGFloat,
        elapsed: Double = 0,
        maximumPhysicalPath: CGFloat = 0.016,
        minimumPathCoherence: CGFloat = 0.90
    ) -> Bool {
        guard !samples.isEmpty,
              outwardSign.isFinite,
              outwardSign != 0,
              maximumPhysicalPath.isFinite,
              maximumPhysicalPath > 0,
              minimumPathCoherence.isFinite,
              (0...1).contains(minimumPathCoherence),
              samples.allSatisfy({ $0.dx.isFinite && $0.dy.isFinite }) else {
            return false
        }

        var rawMetrics = ScrollIntentGate.Metrics()
        samples.forEach { rawMetrics.append($0) }
        return rawOutwardPrefixIsWithinBounds(
            rawMetrics: rawMetrics,
            outwardSign: outwardSign,
            elapsed: elapsed,
            maximumPhysicalPath: maximumPhysicalPath,
            minimumPathCoherence: minimumPathCoherence
        )
    }

    static func rawOutwardPrefixIsWithinBounds(
        rawMetrics: ScrollIntentGate.Metrics,
        outwardSign: CGFloat,
        elapsed: Double,
        maximumDuration: Double = defaultOutwardPrefixMaxDuration,
        maximumPhysicalPath: CGFloat = 0.016,
        minimumPathCoherence: CGFloat = 0.90
    ) -> Bool {
        guard rawMetrics.sampleCount > 0,
              outwardSign.isFinite,
              outwardSign != 0,
              elapsed.isFinite,
              elapsed >= 0,
              maximumDuration.isFinite,
              maximumDuration > 0,
              elapsed < maximumDuration,
              maximumPhysicalPath.isFinite,
              maximumPhysicalPath > 0,
              minimumPathCoherence.isFinite,
              (0...1).contains(minimumPathCoherence),
              rawMetrics.normalizedNetX.isFinite,
              rawMetrics.netY.isFinite,
              rawMetrics.normalizedPathX.isFinite,
              rawMetrics.normalizedPathLength.isFinite,
              rawMetrics.maximumCompensatedExcursion.isFinite else {
            return false
        }

        let signedOutwardNet = rawMetrics.normalizedNetX * outwardSign

        return signedOutwardNet > 0
            && rawMetrics.normalizedPathX < maximumPhysicalPath
            && rawMetrics.normalizedPathLength < maximumPhysicalPath
            && rawMetrics.maximumCompensatedExcursion < maximumPhysicalPath
            && rawMetrics.pathCoherence >= minimumPathCoherence
    }

    static func shouldBeginEarlyOutwardRecovery(
        alreadyUsed: Bool,
        prefixIsRecoverable: Bool
    ) -> Bool {
        !alreadyUsed && prefixIsRecoverable
    }

    /// A fresh suffix is allowed only after the full first decision window.
    /// Incoherent prefixes already prove foldback. A deadline off-axis result
    /// is recoverable only when the physical path was nevertheless strongly
    /// vertical, which distinguishes net cancellation from a real cursor move.
    static func shouldBeginLateCoherenceRecovery(
        alreadyUsed: Bool,
        hasActiveRecovery: Bool,
        isRightEdge: Bool,
        rejectionReason: ScrollIntentGate.RejectionReason,
        sampleCount: Int,
        initialSampleLimit: Int,
        onAxisPath: CGFloat,
        offAxisPath: CGFloat,
        minimumOnAxisPath: CGFloat = minimumLateCoherenceRecoveryOnAxisPath,
        minimumPathDominance: CGFloat = minimumLateCoherenceRecoveryPathDominance
    ) -> Bool {
        guard !alreadyUsed,
              !hasActiveRecovery,
              isRightEdge,
              initialSampleLimit > 0,
              sampleCount >= initialSampleLimit,
              onAxisPath.isFinite,
              offAxisPath.isFinite,
              minimumOnAxisPath.isFinite,
              minimumPathDominance.isFinite,
              onAxisPath >= minimumOnAxisPath,
              offAxisPath >= 0,
              minimumOnAxisPath > 0,
              minimumPathDominance > 1 else {
            return false
        }

        switch rejectionReason {
        case .incoherentMovement:
            return true
        case .offAxisDominant:
            return onAxisPath >= offAxisPath * minimumPathDominance
        case .insufficientMovement, .insufficientOnAxisMovement:
            return false
        }
    }

    static func shouldBeginCornerRecovery(
        alreadyUsed: Bool,
        resolutionIsAwaitingMoreEvidence: Bool,
        isEligibleContact: Bool,
        availableAxisCount: Int,
        sampleCount: Int,
        initialSampleLimit: Int,
        maximumExcursion: CGFloat,
        forceCandidateMaximumExcursion: CGFloat,
        hasTriggeringForceCandidate: Bool
    ) -> Bool {
        guard !alreadyUsed,
              resolutionIsAwaitingMoreEvidence,
              isEligibleContact,
              availableAxisCount > 0,
              initialSampleLimit > 0,
              sampleCount >= initialSampleLimit,
              maximumExcursion.isFinite,
              forceCandidateMaximumExcursion.isFinite,
              maximumExcursion >= forceCandidateMaximumExcursion,
              !hasTriggeringForceCandidate else {
            return false
        }
        return true
    }

    static func cornerRecoveryCanActivate(freshSampleCount: Int) -> Bool {
        freshSampleCount >= minimumCornerRecoveryConfirmationSamples
    }

    static func isScrollOnlyCornerDecision(
        isCorner: Bool,
        hasActiveForceCandidate: Bool,
        forceGestureDisqualified: Bool,
        maximumExcursion: CGFloat,
        forceCandidateMaximumExcursion: CGFloat
    ) -> Bool {
        guard isCorner else { return false }
        guard maximumExcursion.isFinite,
              forceCandidateMaximumExcursion.isFinite,
              forceCandidateMaximumExcursion > 0 else {
            return true
        }

        return !hasActiveForceCandidate
            || forceGestureDisqualified
            || maximumExcursion >= forceCandidateMaximumExcursion
    }

    static func shouldExpireOnEvidenceGap(
        hasActiveRecovery: Bool,
        isScrollOnlyCorner: Bool
    ) -> Bool {
        hasActiveRecovery || isScrollOnlyCorner
    }

    /// Checked both before accepting a new frame and after an unresolved
    /// decision. This lets the 16th physical sample confirm an intent, but an
    /// unresolved 16-sample window cannot receive a 17th sample.
    static func recoveryHasExpired(
        sampleCount: Int,
        elapsed: Double,
        maximumSampleCount: Int = defaultRecoveryMaxSamples,
        maximumDuration: Double = defaultRecoveryMaxDuration
    ) -> Bool {
        guard sampleCount >= 0,
              elapsed.isFinite,
              elapsed >= 0,
              maximumSampleCount > 0,
              maximumDuration.isFinite,
              maximumDuration > 0 else {
            return true
        }

        return sampleCount >= maximumSampleCount
            || elapsed >= maximumDuration
    }
}
