import Foundation
import QuartzCore
import TrackPalCore
import TrackPalSystem

/// C callback 透過 refcon 拿到的東西。停用之後仍然留著（見
/// `MultitouchDeviceManager.retiredBoxes`），所以晚到的 callback 不會碰到已釋放
/// 的記憶體。
private final class DeviceCallbackBox: Sendable {
    let context: DeviceCallbackContext
    let engine: ZoneScrollEngine
    let logger: FileLogger
    let nativeScrollRecorder: NativeScrollRecorder

    init(
        context: DeviceCallbackContext,
        engine: ZoneScrollEngine,
        logger: FileLogger,
        nativeScrollRecorder: NativeScrollRecorder
    ) {
        self.context = context
        self.engine = engine
        self.logger = logger
        self.nativeScrollRecorder = nativeScrollRecorder
    }
}

/// 向 MultitouchSupport（私有 framework）註冊觸控與壓力的 callback。
///
/// 這是整個 App 唯一碰私有 framework 的地方。callback 只做三件事：取出數值、
/// 在 `DeviceCallbackContext` 登記、丟進排序器；判斷全部在 `TrackPalCore`。
@MainActor
final class MultitouchDeviceManager {
    private let engine: ZoneScrollEngine
    private let logger: FileLogger
    private let nativeScrollRecorder: NativeScrollRecorder

    private var devices: [MTDeviceRef] = []
    /// Keeps the enumerated device objects alive while their raw refs are in use.
    private var deviceList: CFArray?
    private var boxes: [DeviceCallbackBox] = []
    // MultitouchSupport does not document whether unregister/stop drains an
    // already-running callback synchronously. Retain retired refcons for the
    // process lifetime so a late callback can fail its active-ID check safely.
    private var retiredBoxes: [DeviceCallbackBox] = []
    private var nextDeviceID = 0

    init(
        engine: ZoneScrollEngine,
        logger: FileLogger,
        nativeScrollRecorder: NativeScrollRecorder
    ) {
        self.engine = engine
        self.logger = logger
        self.nativeScrollRecorder = nativeScrollRecorder
    }

    /// 列舉並啟動所有 multitouch 裝置。回傳這一輪的裝置 callback ID；
    /// 找不到裝置時回傳空陣列。
    func start() -> [Int] {
        guard let list = MTDeviceCreateList() else {
            logger.log("MTDeviceCreateList returned nil")
            return []
        }

        deviceList = list
        let count = CFArrayGetCount(list)
        logger.log("Found \(count) multitouch device(s)")
        guard count > 0 else {
            logger.log("No devices found")
            return []
        }

        for index in 0..<count {
            guard let rawPointer = CFArrayGetValueAtIndex(list, index) else {
                logger.log("Device \(index) pointer is nil")
                continue
            }
            // MTDeviceRef is void * — use UnsafeMutableRawPointer.
            let device = UnsafeMutableRawPointer(mutating: rawPointer)
            devices.append(device)

            nextDeviceID &+= 1
            let box = DeviceCallbackBox(
                context: DeviceCallbackContext(deviceID: nextDeviceID),
                engine: engine,
                logger: logger,
                nativeScrollRecorder: nativeScrollRecorder
            )
            boxes.append(box)
            let refcon = Unmanaged.passUnretained(box).toOpaque()

            logger.log("Device \(index) found, registering callback...")
            MTRegisterContactFrameCallbackWithRefcon(device, touchCallback, refcon)
            if MTDeviceSupportsForce(device) {
                let registered = MTRegisterForceCentroidCallbackWithRefcon(
                    device, forceCentroidCallback, refcon
                )
                logger.log(registered
                    ? "Device \(index) supports force, registered force callback"
                    : "Device \(index) supports force, but force callback registration failed")
            } else {
                logger.log(
                    "Device \(index) does not support force; force-gated actions unavailable"
                )
            }
            MTDeviceStart(device, 0)
            logger.log("Device \(index) started")
        }

        return boxes.map(\.context.deviceID)
    }

    func stop() {
        for device in devices {
            MTUnregisterContactFrameCallbackWithRefcon(device, touchCallback)
            MTUnregisterForceCentroidCallback(device, forceCentroidCallback)
            MTDeviceStop(device)
        }
        devices.removeAll()
        deviceList = nil
        retiredBoxes.append(contentsOf: boxes)
        boxes.removeAll()
    }
}

// MARK: - C callbacks

private func touchCallback(
    device: MTDeviceRef?,
    touches: UnsafeMutablePointer<MTTouch>?,
    numTouches: Int32,
    timestamp: Double,
    frame: Int32,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let box = Unmanaged<DeviceCallbackBox>.fromOpaque(refcon).takeUnretainedValue()
    let callbackUptime = CACurrentMediaTime()

    // Extract values from the touch struct before leaving the callback: the
    // buffer belongs to the framework.
    var sample: TouchSample?
    if numTouches == 1, let touches {
        let touch = touches[0]

        // Diagnostic: log actual MTTouch values once per device for threshold
        // calibration.
        if touch.state >= 4, box.context.claimTouchValueDiagnostic() {
            box.logger.log(String(
                format: "[DIAG] Device %d MTTouch values - density=%.4f, majorAxis=%.4f, minorAxis=%.4f, size=%.4f, angle=%.4f, state=%d",
                box.context.deviceID, touch.density, touch.majorAxis,
                touch.minorAxis, touch.size, touch.angle, touch.state
            ))
        }

        sample = TouchSample(
            x: touch.normalized.position.x,
            y: touch.normalized.position.y,
            state: touch.state,
            density: touch.density,
            majorAxis: touch.majorAxis,
            minorAxis: touch.minorAxis
        )
    }

    // 校正用：多指接觸的幀交給原生捲動的記錄器（預設關閉）。
    if box.nativeScrollRecorder.isEnabled {
        if numTouches == 0 {
            box.nativeScrollRecorder.recordLift(
                uptime: callbackUptime, timestamp: timestamp
            )
        } else if let touches {
            let count = min(Int(numTouches), 5)
            box.nativeScrollRecorder.recordFrame(
                uptime: callbackUptime,
                timestamp: timestamp,
                points: (0..<count).map {
                    (touches[$0].normalized.position.x, touches[$0].normalized.position.y)
                }
            )
        }
    }

    guard let routed = box.context.routeContactFrame(
        touchCount: Int(numTouches),
        touch: sample,
        timestamp: timestamp,
        eventUptime: callbackUptime
    ) else {
        return
    }

    let engine = box.engine
    TouchCallbackSequencer.shared.enqueue(timestamp: timestamp) {
        routed.deliver(to: engine)
    }
}

private func forceCentroidCallback(
    device: MTDeviceRef?,
    centroid: UnsafeMutablePointer<MTForceCentroid>?,
    refcon: UnsafeMutableRawPointer?
) {
    guard let centroid, let refcon else { return }
    let box = Unmanaged<DeviceCallbackBox>.fromOpaque(refcon).takeUnretainedValue()

    let forceCentroid = centroid.pointee
    let sampleUptime = CACurrentMediaTime()
    if box.context.claimForceValueDiagnostic() {
        box.logger.log(String(
            format: "[DIAG] Device %d force centroid - force=%.1f, rawTimestamp=%.3f, touchSeconds=%.6f",
            box.context.deviceID,
            forceCentroid.force,
            forceCentroid.timestamp,
            forceCentroidTimestampInTouchSeconds(forceCentroid.timestamp)
        ))
    }
    recordForceCentroidSample(
        x: forceCentroid.normalizedX,
        y: forceCentroid.normalizedY,
        force: forceCentroid.force,
        rawTimestamp: forceCentroid.timestamp,
        sampleUptime: sampleUptime,
        into: box.context
    )
}
