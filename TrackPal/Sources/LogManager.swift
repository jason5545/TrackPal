// TrackPal/Sources/LogManager.swift
import Foundation

/// File-based log manager - writes to ~/Library/Logs/TrackPal.log
/// Allows external tools (e.g. Claude) to read app diagnostics via file access
final class LogManager: @unchecked Sendable {

    static let shared = LogManager()

    private let logFileURL: URL
    private let queue = DispatchQueue(label: "com.jasonchien.TrackPal.log", qos: .utility)
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        logFileURL = logsDir.appendingPathComponent("TrackPal.log")

        // Truncate on launch
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
    }

    /// Log a message to file and system console
    func log(_ message: String) {
        // System log (thread-safe by itself)
        NSLog("TrackPal: %@", message)

        // File log (async to avoid blocking; formatting inside queue for thread safety)
        queue.async { [logFileURL, dateFormatter] in
            let timestamp = dateFormatter.string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
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
}
