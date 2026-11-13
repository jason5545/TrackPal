import CoreGraphics
import QuartzCore
import TrackPalCore

/// 狀態機的輸出接到真正的系統：CGEvent、event tap、display link、檔案。
@MainActor
public final class LiveZoneScrollEffects: ZoneScrollEffects {
    private let logger: FileLogger
    private let interceptor: ScrollEventInterceptor
    private let inertia: InertiaScroller
    private let traceWriter: GestureTraceFileWriter
    private let scrollPoster: ScrollEventPoster

    public init(
        logger: FileLogger,
        interceptor: ScrollEventInterceptor,
        inertia: InertiaScroller,
        traceWriter: GestureTraceFileWriter,
        scrollPoster: ScrollEventPoster
    ) {
        self.scrollPoster = scrollPoster
        self.logger = logger
        self.interceptor = interceptor
        self.inertia = inertia
        self.traceWriter = traceWriter
    }

    public func log(_ message: String) {
        logger.log(message)
    }

    public func now() -> Double {
        CACurrentMediaTime()
    }

    public func postScroll(
        deltaX: Int32, deltaY: Int32, scrollPhase: Int64, momentumPhase: Int64
    ) {
        scrollPoster.post(deltaX: deltaX, deltaY: deltaY)
    }

    public func postMiddleClick() -> Bool {
        guard let location = CornerActionPerformer.pointerLocation() else {
            logger.log("Failed to construct paired synthetic mouse events")
            return false
        }
        let posted = SyntheticEvents.postMousePair(
            downType: .otherMouseDown,
            upType: .otherMouseUp,
            at: location,
            button: .center
        )
        if !posted {
            logger.log("Failed to construct paired synthetic mouse events")
        }
        return posted
    }

    public func performCornerAction(_ action: CornerAction) {
        CornerActionPerformer.perform(action)
    }

    public func pointerLocation() -> CGPoint? {
        SyntheticEvents.pointerLocation()
    }

    public func warpPointer(to location: CGPoint) {
        CGWarpMouseCursorPosition(location)
        // warp 之後系統預設會抑制滑鼠事件 0.25 秒；重新 associate 取消它。
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    public func startInertia(velocityX: CGFloat, velocityY: CGFloat) {
        inertia.start(velocityX: velocityX, velocityY: velocityY)
    }

    public func stopInertia() {
        inertia.stop()
    }

    public func beginPrimaryClickCapture(token: UInt64, gestureUptime: Double) {
        interceptor.beginPendingForceGesture(
            token: token, gestureUptime: gestureUptime
        )
    }

    public func finishPrimaryClickCapture(
        token: UInt64, replayCapturedClick: Bool, gestureUptime: Double?
    ) {
        interceptor.finishPendingForceGesture(
            token: token,
            replayCapturedClick: replayCapturedClick,
            gestureUptime: gestureUptime
        )
    }

    public func traceBegin(timestamp: Double) {
        traceWriter.begin(timestamp: timestamp)
    }

    public func traceFrame(
        timestamp: Double,
        x: Float,
        y: Float,
        state: Int32,
        density: Float,
        majorAxis: Float,
        minorAxis: Float,
        isValid: Bool
    ) {
        traceWriter.append(
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

    public func traceFinish(_ summary: GestureTraceSummary) {
        traceWriter.finish(summary)
    }
}
