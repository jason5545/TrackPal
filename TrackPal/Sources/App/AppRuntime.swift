import AppKit
import Observation
import TrackPalCore
import TrackPalSystem

/// 把各個元件接起來的地方：設定、狀態機、event tap、慣性、裝置、日誌。
///
/// 沒有任何單例；誰需要什麼都在這裡明講，UI 透過 environment 拿到這個物件。
@MainActor
@Observable
final class AppRuntime {
    let settings: SettingsStore

    /// 區域捲動是否正在運作（裝置已註冊、event tap 已啟動）。
    private(set) var isRunning = false

    @ObservationIgnored let logger: FileLogger
    @ObservationIgnored private let engine: ZoneScrollEngine
    @ObservationIgnored private let interceptor: ScrollEventInterceptor
    @ObservationIgnored private let inertia: InertiaScroller
    @ObservationIgnored private let devices: MultitouchDeviceManager
    @ObservationIgnored private var restartTask: Task<Void, Never>?

    init() {
        let logger = FileLogger()
        self.logger = logger

        let settings = SettingsStore(log: { logger.log($0) })
        self.settings = settings

        let suppression = ScrollSuppressionState()
        let interceptor = ScrollEventInterceptor(
            suppression: suppression,
            log: { logger.log($0) }
        )
        // 手指跟隨的捲動與慣性共用同一個出口。
        let scrollPoster = ScrollEventPoster()
        let inertia = InertiaScroller { deltaX, deltaY in
            scrollPoster.post(deltaX: deltaX, deltaY: deltaY)
        }
        let engine = ZoneScrollEngine(
            configuration: settings.configuration,
            effects: LiveZoneScrollEffects(
                logger: logger,
                interceptor: interceptor,
                inertia: inertia,
                traceWriter: GestureTraceFileWriter(),
                scrollPoster: scrollPoster
            ),
            suppression: suppression
        )
        self.interceptor = interceptor
        self.inertia = inertia
        self.engine = engine
        devices = MultitouchDeviceManager(engine: engine, logger: logger)

        settings.onConfigurationChange = { [engine] configuration in
            engine.configuration = configuration
        }

        logger.log(
            "Settings loaded - enabled=\(settings.isEnabled), middleClick=\(settings.middleClickEnabled), filterLight=\(settings.filterLightTouches), filterLarge=\(settings.filterLargeTouches)"
        )
    }

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Start / stop

    func start() {
        guard !isRunning else { return }
        logger.log("Starting zone scroller...")

        let deviceIDs = devices.start()
        guard !deviceIDs.isEmpty else {
            devices.stop()
            return
        }

        engine.start(deviceIDs: deviceIDs)
        interceptor.start()
        isRunning = true
        logger.log("Trackpad zone scrolling enabled successfully")
    }

    func stop() {
        // 先讓狀態機取消進行中的手勢（會結算原生點擊的攔截），再拆 event tap。
        engine.stop()
        inertia.stop()
        interceptor.stop()

        guard isRunning else { return }
        devices.stop()
        isRunning = false
        logger.log("Trackpad zone scrolling disabled")
    }

    /// UI 的總開關：記住使用者的選擇，並照著啟動或停止。
    func setEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    // MARK: - Quit

    /// 使用者按了「結束」。`AppDelegate.applicationShouldTerminate` 靠這個旗標
    /// 分辨「使用者要結束」與「AppKit 在彈出視窗關閉時自己想結束」。
    @ObservationIgnored private(set) var isQuitRequested = false

    func quit() {
        isQuitRequested = true
        NSApp.terminate(nil)
    }

    // MARK: - Wake recovery

    /// Hibernate (e.g. low-battery sleep) invalidates the MultitouchSupport
    /// device handles registered at launch: the process keeps running but
    /// touch callbacks never arrive again. Re-enumerate devices after wake.
    func scheduleDeviceRestart(reason: String) {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            // Give the trackpad driver time to re-attach before enumerating.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled,
                  let self,
                  self.settings.isEnabled,
                  self.isAccessibilityTrusted else { return }
            self.logger.log("Re-registering multitouch devices after \(reason)")
            self.stop()
            self.start()
        }
    }
}
