import CoreGraphics
import Foundation
import os

/// 校正用：把系統原生的雙指捲動錄下來，當作調整手感的參考。
///
/// 多指接觸期間的觸控幀，加上系統自己送出的捲動事件（含放開後的慣性），依
/// 到達時間寫進 `~/Library/Logs/TrackPal.native-scroll.jsonl`，一筆一行：
///
/// - `{"k":"f","u":<到達時間>,"t":<硬體時間>,"p":[[x,y],…]}`：一幀，每根手指的
///   normalized 座標。
/// - `{"k":"z","u":…,"t":…}`：手指全部放開。
/// - `{"k":"s","u":…,"t":<事件時間，秒>,"py":…,"px":…,"fy":…,"fx":…,"ly":…,
///   "lx":…,"ph":<scroll phase>,"mo":<momentum phase>,"c":<isContinuous>}`：
///   一筆原生捲動事件。`py/px` 是像素位移，`fy/fx` 是 fixed-point 位移，
///   `ly/lx` 是行位移。
///
/// 只有觸控板座標與捲動量，沒有游標位置、視窗或按鍵。預設關閉；用
/// `defaults write com.jasonchien.TrackPal recordNativeScrollReference -bool YES`
/// 打開後重新啟動 App。
public final class NativeScrollRecorder: @unchecked Sendable {
    public static let defaultsKey = "recordNativeScrollReference"
    public static let defaultMaximumFileSize: UInt64 = 8 * 1024 * 1024

    public let fileURL: URL
    private let maximumFileSize: UInt64
    private let queue = DispatchQueue(
        label: "com.jasonchien.TrackPal.native-scroll", qos: .utility
    )

    private struct State {
        var isEnabled = false
        /// 多指接觸進行中，或剛放開、還可能有慣性事件。
        var isMultiFingerActive = false
        var lastActivityUptime: Double = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    // 只在 `queue` 上讀寫。
    private var handle: FileHandle?
    private var writtenBytes: UInt64 = 0

    /// 放開之後這段時間內的捲動事件仍然記錄（原生慣性最長大約兩三秒）。
    private static let momentumWindow: Double = 4.0

    public init(
        fileURL: URL,
        isEnabled: Bool,
        maximumFileSize: UInt64 = NativeScrollRecorder.defaultMaximumFileSize
    ) {
        self.fileURL = fileURL
        self.maximumFileSize = maximumFileSize
        state.withLock { $0.isEnabled = isEnabled }
    }

    public convenience init(isEnabled: Bool) {
        self.init(
            fileURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/TrackPal.native-scroll.jsonl"),
            isEnabled: isEnabled
        )
    }

    public var isEnabled: Bool {
        state.withLock { $0.isEnabled }
    }

    /// 一幀觸控。`points` 是這一幀每根手指的 normalized 座標。可以從任何
    /// 執行緒呼叫。
    public func recordFrame(
        uptime: Double, timestamp: Double, points: [(x: Float, y: Float)]
    ) {
        let shouldRecord: Bool = state.withLock { state in
            guard state.isEnabled else { return false }
            if points.count >= 2 {
                state.isMultiFingerActive = true
                state.lastActivityUptime = uptime
                return true
            }
            // 多指之後剩一根手指：照樣記，才看得到手指是怎麼離開的。
            guard state.isMultiFingerActive else { return false }
            state.lastActivityUptime = uptime
            return true
        }
        guard shouldRecord else { return }

        let coordinates = points
            .map { String(format: "[%.5f,%.5f]", $0.x, $0.y) }
            .joined(separator: ",")
        write(String(
            format: "{\"k\":\"f\",\"u\":%.6f,\"t\":%.6f,\"p\":[%@]}\n",
            uptime, timestamp, coordinates
        ))
    }

    /// 手指全部放開。
    public func recordLift(uptime: Double, timestamp: Double) {
        let shouldRecord: Bool = state.withLock { state in
            guard state.isEnabled, state.isMultiFingerActive else { return false }
            state.lastActivityUptime = uptime
            return true
        }
        guard shouldRecord else { return }
        write(String(format: "{\"k\":\"z\",\"u\":%.6f,\"t\":%.6f}\n", uptime, timestamp))
    }

    /// 一筆不是 TrackPal 自己送的捲動事件。只在多指接觸期間與放開後的一小段
    /// 時間內記錄。
    public func recordScroll(_ event: CGEvent, uptime: Double) {
        let shouldRecord: Bool = state.withLock { state in
            guard state.isEnabled, state.isMultiFingerActive else { return false }
            if uptime - state.lastActivityUptime > Self.momentumWindow {
                state.isMultiFingerActive = false
                return false
            }
            // 慣性事件持續到達就延長時間窗。
            state.lastActivityUptime = uptime
            return true
        }
        guard shouldRecord else { return }

        write(String(
            format: "{\"k\":\"s\",\"u\":%.6f,\"t\":%.6f,\"py\":%lld,\"px\":%lld,\"fy\":%.4f,\"fx\":%.4f,\"ly\":%lld,\"lx\":%lld,\"ph\":%lld,\"mo\":%lld,\"c\":%lld}\n",
            uptime,
            Double(event.timestamp) / 1_000_000_000,
            event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            event.getIntegerValueField(.scrollWheelEventScrollPhase),
            event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            event.getIntegerValueField(.scrollWheelEventIsContinuous)
        ))
    }

    /// 等排隊中的寫入完成（測試用）。
    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private func write(_ line: String) {
        queue.async { [self] in
            guard let data = line.data(using: .utf8) else { return }
            let fileManager = FileManager.default
            if handle == nil || !fileManager.fileExists(atPath: fileURL.path) {
                try? handle?.close()
                try? fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !fileManager.fileExists(atPath: fileURL.path) {
                    fileManager.createFile(atPath: fileURL.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: fileURL)
                writtenBytes = (try? handle?.seekToEnd()) ?? 0
            }
            // 校正用的檔案，滿了就停，不輪替：要的是一段完整的樣本。
            guard writtenBytes < maximumFileSize, let handle else { return }
            do {
                try handle.write(contentsOf: data)
                writtenBytes += UInt64(data.count)
            } catch {
                self.handle = nil
            }
        }
    }
}
