import Foundation
import TrackPalCore

/// 把從捲動區、角落、中鍵區起步的接觸逐幀寫到
/// `~/Library/Logs/TrackPal.traces.jsonl`，一次接觸一行 JSON。
///
/// 主日誌每次接觸只留一筆總結，調整判斷規則時沒辦法重播「門檻改成這樣會
/// 怎樣」。有了逐幀軌跡，新規則可以先用 `trackpal-replay` 對真實資料離線
/// 重算。檔案超過 `maximumFileSize` 時輪替成 `TrackPal.traces.previous.jsonl`。
@MainActor
public final class GestureTraceFileWriter {
    public static let defaultMaximumFileSize: UInt64 = 8 * 1024 * 1024

    private let fileURL: URL
    private let archivedFileURL: URL
    private let maximumFileSize: UInt64
    private let queue = DispatchQueue(
        label: "com.jasonchien.TrackPal.trace", qos: .utility
    )
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    private var builder = GestureTraceLineBuilder()
    private var startDate = Date()

    public init(
        fileURL: URL,
        archivedFileURL: URL,
        maximumFileSize: UInt64 = GestureTraceFileWriter.defaultMaximumFileSize
    ) {
        self.fileURL = fileURL
        self.archivedFileURL = archivedFileURL
        self.maximumFileSize = maximumFileSize
    }

    public convenience init() {
        let urls = GestureTrace.defaultLogURLs()
        self.init(fileURL: urls[1], archivedFileURL: urls[0])
    }

    public func begin(timestamp: Double) {
        builder.begin(timestamp: timestamp)
        startDate = Date()
    }

    public func append(
        timestamp: Double,
        x: Float,
        y: Float,
        state: Int32,
        density: Float,
        majorAxis: Float,
        minorAxis: Float,
        isValid: Bool
    ) {
        builder.append(
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

    public func finish(_ summary: GestureTraceSummary) {
        guard let line = builder.finish(
            summary, date: dateFormatter.string(from: startDate)
        ) else {
            return
        }

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
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
    }

    /// 等排隊中的寫入完成（測試用）。
    public func flush() {
        queue.sync {}
    }
}
