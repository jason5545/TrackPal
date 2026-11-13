import Foundation
import Testing
import TrackPalCore
@testable import TrackPalSystem

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("trackpal-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fileSize(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
}

@Suite("檔案日誌")
struct FileLoggerTests {
    private func makeLogger(in directory: URL, maximumSize: UInt64 = 1_000_000) -> FileLogger {
        FileLogger(
            fileURL: directory.appendingPathComponent("TrackPal.log"),
            archivedFileURL: directory.appendingPathComponent("TrackPal.previous.log"),
            maximumSize: maximumSize,
            systemLogger: nil
        )
    }

    @Test("每行的格式是 [MM-dd HH:mm:ss.SSS] 訊息，順序跟呼叫順序一致")
    func lineFormat() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = makeLogger(in: directory)

        logger.log("first")
        logger.log("第二行 → ok")
        logger.flush()

        let lines = try String(contentsOf: logger.fileURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        let pattern = /^\[\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] (.*)$/
        #expect(try pattern.wholeMatch(in: lines[0])?.1 == "first")
        #expect(try pattern.wholeMatch(in: lines[1])?.1 == "第二行 → ok")
    }

    @Test("重新啟動時接著寫，不清空舊紀錄")
    func appendsAcrossLaunches() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var logger: FileLogger? = makeLogger(in: directory)
        logger?.log("before")
        logger?.flush()
        logger = nil

        let second = makeLogger(in: directory)
        second.log("after")
        second.flush()

        let text = try String(contentsOf: second.fileURL, encoding: .utf8)
        #expect(text.contains("before") && text.contains("after"))
    }

    @Test("執行中超過上限就輪替：舊的搬到 previous，新的從頭開始")
    func rotatesWhileRunning() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = makeLogger(in: directory, maximumSize: 400)

        for index in 0..<20 {
            logger.log("message number \(index) padded to be reasonably long")
        }
        logger.flush()

        #expect(FileManager.default.fileExists(atPath: logger.archivedFileURL.path))
        #expect(fileSize(logger.fileURL) < 400)
        #expect(fileSize(logger.archivedFileURL) >= 400)
        // 最後一筆一定在其中一個檔案裡，沒有掉。
        let combined = try String(contentsOf: logger.archivedFileURL, encoding: .utf8)
            + String(contentsOf: logger.fileURL, encoding: .utf8)
        #expect(combined.contains("message number 19"))
        #expect(combined.contains("message number 18"))
    }

    @Test("啟動時檔案已經超過上限：先輪替")
    func rotatesAtLaunch() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("TrackPal.log")
        try String(repeating: "x", count: 600).write(to: url, atomically: true, encoding: .utf8)

        let logger = makeLogger(in: directory, maximumSize: 500)
        logger.log("fresh")
        logger.flush()

        #expect(fileSize(logger.archivedFileURL) == 600)
        #expect(try String(contentsOf: logger.fileURL, encoding: .utf8).hasSuffix("fresh\n"))
    }

    @Test("檔案在執行中被刪掉：下一筆會重新建立")
    func recreatesDeletedFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = makeLogger(in: directory)

        logger.log("one")
        logger.flush()
        try FileManager.default.removeItem(at: logger.fileURL)
        logger.log("two")
        logger.flush()

        let text = try String(contentsOf: logger.fileURL, encoding: .utf8)
        #expect(text.hasSuffix("two\n"))
        #expect(!text.contains("one"))
    }

    @Test("多個執行緒同時寫：每一筆都完整")
    func concurrentWrites() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = makeLogger(in: directory)

        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for index in 0..<50 { logger.log("w\(worker)-\(index)") }
                }
            }
        }
        logger.flush()

        let lines = try String(contentsOf: logger.fileURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 400)
        #expect(lines.allSatisfy { $0.hasPrefix("[") && $0.contains("] w") })
    }
}

@MainActor
@Suite("軌跡檔寫入")
struct GestureTraceFileWriterTests {
    private func summary(zone: String = "rightEdge") -> GestureTraceSummary {
        GestureTraceSummary(
            sessionID: 1, initialZone: zone, finalZone: zone, outcome: "scroll:\(zone)",
            duration: 0.2, pointerActivityGap: nil, horizontalScrollGap: 1.5,
            stripDepth: 0.3, edgeWidth: 0.15, cornerSize: 0.15,
            scrollPixelsX: 0, scrollPixelsY: -30, maximumForce: 0
        )
    }

    private func record(_ writer: GestureTraceFileWriter, zone: String = "rightEdge", frames: Int = 5) {
        writer.begin(timestamp: 100)
        for index in 0..<frames {
            writer.append(
                timestamp: 100 + Double(index) * 0.008, x: 0.95, y: 0.3 + Float(index) * 0.01,
                state: 4, density: 0.2, majorAxis: 8, minorAxis: 6, isValid: true
            )
        }
        writer.finish(summary(zone: zone))
        writer.flush()
    }

    @Test("一次接觸寫一行，讀得回來；日期是 ISO 8601")
    func writesOneLinePerContact() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = GestureTrace.defaultLogURLs(in: directory)
        let writer = GestureTraceFileWriter(fileURL: urls[1], archivedFileURL: urls[0])

        record(writer)
        record(writer)
        record(writer, zone: "center")      // 中央區不寫

        let traces = try GestureTrace.load(contentsOf: urls[1])
        #expect(traces.count == 2)
        #expect(traces[0].frames.count == 5)
        #expect(traces[0].outcome == "scroll:rightEdge")
        #expect(traces[0].scrollGap == 1.5)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(formatter.date(from: traces[0].date) != nil)
    }

    @Test("超過上限就輪替")
    func rotates() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = GestureTrace.defaultLogURLs(in: directory)
        let writer = GestureTraceFileWriter(
            fileURL: urls[1], archivedFileURL: urls[0], maximumFileSize: 300
        )

        for _ in 0..<4 { record(writer, frames: 8) }

        #expect(FileManager.default.fileExists(atPath: urls[0].path))
        let total = GestureTrace.loadDefaultLogs(in: directory).count
        #expect(total >= 2 && total <= 4)
    }
}
