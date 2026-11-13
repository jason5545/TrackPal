import Foundation
import os

/// 寫到 `~/Library/Logs/TrackPal.log` 的日誌，同時送一份到系統的 unified log。
///
/// 檔案讓外部工具（包含 AI）讀得到診斷紀錄。格式固定是
/// `[MM-dd HH:mm:ss.SSS] 訊息`。檔案到 `maximumSize` 就輪替成
/// `TrackPal.previous.log`（啟動時與執行中都會檢查），所以磁碟用量有上限，
/// 又留得住幾天的紀錄供校正門檻。
public final class FileLogger: @unchecked Sendable {
    public static let defaultMaximumSize: UInt64 = 16 * 1024 * 1024

    public let fileURL: URL
    public let archivedFileURL: URL
    private let maximumSize: UInt64
    private let queue = DispatchQueue(
        label: "com.jasonchien.TrackPal.log", qos: .utility
    )
    private let systemLogger: Logger?

    // 以下只在 `queue` 上讀寫。
    private var handle: FileHandle?
    private var currentSize: UInt64 = 0
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // 帶日期：日誌跨多天保留，沒有日期就分不出哪一天。
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    public init(
        fileURL: URL,
        archivedFileURL: URL,
        maximumSize: UInt64 = FileLogger.defaultMaximumSize,
        systemLogger: Logger? = Logger(
            subsystem: "com.jasonchien.TrackPal", category: "gesture"
        )
    ) {
        self.fileURL = fileURL
        self.archivedFileURL = archivedFileURL
        self.maximumSize = maximumSize
        self.systemLogger = systemLogger
        queue.sync { openHandle(rotatingIfNeeded: true) }
    }

    /// `~/Library/Logs/TrackPal.log`
    public convenience init() {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        self.init(
            fileURL: logs.appendingPathComponent("TrackPal.log"),
            archivedFileURL: logs.appendingPathComponent("TrackPal.previous.log")
        )
    }

    public func log(_ message: String) {
        // Explicit public privacy keeps gesture diagnostics readable in Console.
        systemLogger?.info("\(message, privacy: .public)")

        let date = Date()
        queue.async { [self] in
            write("[\(dateFormatter.string(from: date))] \(message)\n")
        }
    }

    /// 等所有排隊中的訊息寫完（測試與結束前用）。
    public func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    private func write(_ line: String) {
        // 檔案在執行中被刪掉或搬走時重新建立，不然之後的紀錄都寫進看不到的 inode。
        if handle == nil || !FileManager.default.fileExists(atPath: fileURL.path) {
            openHandle(rotatingIfNeeded: false)
        }
        guard let handle, let data = line.data(using: .utf8) else { return }

        do {
            try handle.write(contentsOf: data)
            currentSize += UInt64(data.count)
        } catch {
            self.handle = nil
            return
        }

        if currentSize >= maximumSize {
            openHandle(rotatingIfNeeded: true)
        }
    }

    private func openHandle(rotatingIfNeeded: Bool) {
        try? handle?.close()
        handle = nil

        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if rotatingIfNeeded,
           let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? NSNumber,
           size.uint64Value >= maximumSize {
            try? fileManager.removeItem(at: archivedFileURL)
            try? fileManager.moveItem(at: fileURL, to: archivedFileURL)
        }

        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let newHandle = try? FileHandle(forWritingTo: fileURL) else { return }
        currentSize = (try? newHandle.seekToEnd()) ?? 0
        handle = newHandle
    }
}
