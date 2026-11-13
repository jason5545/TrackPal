import Foundation

/// 把一次接觸的逐幀資料組成軌跡檔的一行 JSON（格式見 `GestureTrace`）。
///
/// 只記觸控板上的座標與接觸面積，不含游標位置、視窗或按鍵。中央區起步的接觸
/// 量最大、又跟區域判斷無關，不輸出。
public struct GestureTraceLineBuilder: Sendable {
    public static let maximumFramesPerContact = 3_000

    private var frames: [String] = []
    private var startTimestamp: Double = 0
    public private(set) var isRecording = false

    public init() {}

    public mutating func begin(timestamp: Double) {
        frames.removeAll(keepingCapacity: true)
        startTimestamp = timestamp
        isRecording = true
    }

    public mutating func append(
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
              frames.count < Self.maximumFramesPerContact,
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

    /// 接觸結束。回傳要寫進檔案的一行（含換行）；不需要寫時回傳 nil。
    /// `date` 是接觸開始的時間，ISO 8601 字串。
    public mutating func finish(
        _ summary: GestureTraceSummary,
        date: String
    ) -> String? {
        guard isRecording else { return nil }
        isRecording = false
        defer { frames.removeAll(keepingCapacity: true) }
        guard summary.initialZone != "center",
              summary.initialZone != "none",
              !frames.isEmpty else {
            return nil
        }

        let gap = summary.pointerActivityGap
            .map { String(format: "%.3f", $0) } ?? "null"
        let scrollGap = summary.horizontalScrollGap
            .map { String(format: "%.3f", $0) } ?? "null"
        return "{\"id\":\(summary.sessionID)"
            + ",\"date\":\"\(date)\""
            + ",\"zone\":\"\(summary.initialZone)\""
            + ",\"final\":\"\(summary.finalZone)\""
            + ",\"outcome\":\"\(summary.outcome)\""
            + String(format: ",\"dur\":%.3f", summary.duration)
            + ",\"pointerGap\":\(gap)"
            + ",\"scrollGap\":\(scrollGap)"
            + String(format: ",\"stripDepth\":%.4f", summary.stripDepth)
            + String(format: ",\"edgeWidth\":%.4f", summary.edgeWidth)
            + String(format: ",\"cornerSize\":%.4f", summary.cornerSize)
            + ",\"pixels\":[\(summary.scrollPixelsX),\(summary.scrollPixelsY)]"
            + String(format: ",\"force\":%.1f", summary.maximumForce)
            + ",\"frames\":[\(frames.joined(separator: ","))]}\n"
    }

    private static func scaled(_ value: Float, by factor: Float) -> Int {
        Int((value * factor).rounded())
    }
}
