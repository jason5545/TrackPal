// TrackPal/Sources/LogManager.swift
import Foundation
import os

/// File-based log manager - writes to ~/Library/Logs/TrackPal.log
/// Allows external tools (e.g. Claude) to read app diagnostics via file access
final class LogManager: @unchecked Sendable {

    static let shared = LogManager()

    private let logFileURL: URL
    private let archivedLogFileURL: URL
    private let queue = DispatchQueue(label: "com.jasonchien.TrackPal.log", qos: .utility)
    private let systemLogger = Logger(subsystem: "com.jasonchien.TrackPal", category: "gesture")
    private let maximumLogSize: UInt64 = 2 * 1024 * 1024
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        logFileURL = logsDir.appendingPathComponent("TrackPal.log")
        archivedLogFileURL = logsDir.appendingPathComponent("TrackPal.previous.log")

        // [AI-Codex: 2026-07-24] Keep the previous session available for
        // calibration. The old logger truncated on every launch and then never
        // recreated a file that had been removed while the app was running.
        prepareLogFile()
    }

    /// Log a message to file and system console
    func log(_ message: String) {
        // Explicit public privacy keeps gesture diagnostics readable in Console.
        systemLogger.info("\(message, privacy: .public)")

        // File log (async to avoid blocking; formatting inside queue for thread safety)
        queue.async { [logFileURL, dateFormatter] in
            let timestamp = dateFormatter.string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: logFileURL.path) {
                fileManager.createFile(atPath: logFileURL.path, contents: nil)
            }

            if let data = line.data(using: .utf8),
               let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }

    /// Path for external access
    var logFilePath: String {
        logFileURL.path
    }

    private func prepareLogFile() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let attributes = try? fileManager.attributesOfItem(atPath: logFileURL.path),
           let size = attributes[.size] as? NSNumber,
           size.uint64Value >= maximumLogSize {
            try? fileManager.removeItem(at: archivedLogFileURL)
            try? fileManager.moveItem(at: logFileURL, to: archivedLogFileURL)
        }

        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }
    }
}
