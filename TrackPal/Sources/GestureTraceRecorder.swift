import Foundation

/// 把從捲動區、角落、中鍵區起步的接觸逐幀記錄到
/// `~/Library/Logs/TrackPal.traces.jsonl`，一次接觸一行 JSON。
///
/// [AI-Claude: 2026-11-11] 主日誌每次接觸只留一筆總結（起點、淨位移、路徑），
/// 調整判斷規則時沒辦法重播「如果門檻改成這樣會怎樣」，只能從總結猜。
/// 有了逐幀軌跡，新規則可以先對真實資料離線重算，再決定要不要改。
///
/// 只記錄觸控板上的座標與接觸面積，不含游標位置、視窗或按鍵。檔案超過
/// `maximumFileSize` 時輪替成 `TrackPal.traces.previous.jsonl`。
///
/// `frames` 每筆是 `[t, x, y, state, density, major, minor, valid]`：
/// - `t`：距離接觸開始的時間，單位 0.1 ms
/// - `x`、`y`：normalized 座標乘 10000
/// - `density` 乘 1000，`major`、`minor` 乘 100
/// - `valid`：1 表示通過輕觸／大面積過濾
final class GestureTraceRecorder: @unchecked Sendable {

    static let shared = GestureTraceRecorder()

    struct Summary {
        var sessionID: UInt64
        var initialZone: String
        var finalZone: String
        var outcome: String
        var duration: Double
        /// 距離上一次游標活動結束的秒數；沒有紀錄時為 nil。
        var pointerActivityGap: Double?
        var stripDepth: Double
        var edgeWidth: Double
        var cornerSize: Double
        var scrollPixelsX: Int64
        var scrollPixelsY: Int64
        var maximumForce: Float
    }

    private let fileURL: URL
    private let archivedFileURL: URL
    private let queue = DispatchQueue(
        label: "com.jasonchien.TrackPal.trace",
        qos: .utility
    )
    private let maximumFileSize: UInt64 = 8 * 1024 * 1024
    private let maximumFramesPerContact = 3000
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    // 只在觸控處理的執行緒上讀寫。
    private var frames: [String] = []
    private var startTimestamp: Double = 0
    private var startDate = Date()
    private var isRecording = false

    private init() {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        fileURL = logsDirectory.appendingPathComponent("TrackPal.traces.jsonl")
        archivedFileURL = logsDirectory
            .appendingPathComponent("TrackPal.traces.previous.jsonl")
    }

    func begin(timestamp: Double) {
        frames.removeAll(keepingCapacity: true)
        startTimestamp = timestamp
        startDate = Date()
        isRecording = true
    }

    func append(
        timestamp: Double,
        x: Float,
        y: Float,
        state: Int32,
        density: Float,
        majorAxis: Float,
        minorAxis: Float,
        isValid: Bool
    ) {
        guard isRecording,
              frames.count < maximumFramesPerContact,
              timestamp.isFinite,
              x.isFinite,
              y.isFinite,
              density.isFinite,
              majorAxis.isFinite,
              minorAxis.isFinite else {
            return
        }

        let elapsed = Int(((timestamp - startTimestamp) * 10_000).rounded())
        frames.append(
            "[\(elapsed),\(Self.scaled(x, by: 10_000)),\(Self.scaled(y, by: 10_000)),\(state),\(Self.scaled(density, by: 1_000)),\(Self.scaled(majorAxis, by: 100)),\(Self.scaled(minorAxis, by: 100)),\(isValid ? 1 : 0)]"
        )
    }

    /// 接觸結束時呼叫。中央區起步的接觸量最大、又跟區域判斷無關，不寫檔。
    func finish(_ summary: Summary) {
        guard isRecording else { return }
        isRecording = false
        guard summary.initialZone != "center",
              summary.initialZone != "none",
              !frames.isEmpty else {
            frames.removeAll(keepingCapacity: true)
            return
        }

        let gap = summary.pointerActivityGap
            .map { String(format: "%.3f", $0) } ?? "null"
        let line = "{\"id\":\(summary.sessionID)"
            + ",\"date\":\"\(dateFormatter.string(from: startDate))\""
            + ",\"zone\":\"\(summary.initialZone)\""
            + ",\"final\":\"\(summary.finalZone)\""
            + ",\"outcome\":\"\(summary.outcome)\""
            + String(format: ",\"dur\":%.3f", summary.duration)
            + ",\"pointerGap\":\(gap)"
            + String(format: ",\"stripDepth\":%.4f", summary.stripDepth)
            + String(format: ",\"edgeWidth\":%.4f", summary.edgeWidth)
            + String(format: ",\"cornerSize\":%.4f", summary.cornerSize)
            + ",\"pixels\":[\(summary.scrollPixelsX),\(summary.scrollPixelsY)]"
            + String(format: ",\"force\":%.1f", summary.maximumForce)
            + ",\"frames\":[\(frames.joined(separator: ","))]}\n"
        frames.removeAll(keepingCapacity: true)

        queue.async { [fileURL, archivedFileURL, maximumFileSize] in
            guard let data = line.data(using: .utf8) else { return }
            let fileManager = FileManager.default

            if let attributes = try? fileManager
                .attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? NSNumber,
               size.uint64Value >= maximumFileSize {
                try? fileManager.removeItem(at: archivedFileURL)
                try? fileManager.moveItem(at: fileURL, to: archivedFileURL)
            }
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }

    private static func scaled(_ value: Float, by factor: Float) -> Int {
        Int((value * factor).rounded())
    }
}
