import CoreGraphics
import Foundation
import Testing
@testable import TrackPalSystem

@Suite("原生捲動的校正記錄")
struct NativeScrollRecorderTests {
    private func makeRecorder(enabled: Bool) -> (NativeScrollRecorder, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trackpal-native-\(UUID().uuidString).jsonl")
        return (NativeScrollRecorder(fileURL: url, isEnabled: enabled), url)
    }

    private func scrollEvent(_ pixels: Int32) throws -> CGEvent {
        try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: pixels, wheel2: 0, wheel3: 0
        ))
    }

    private func lines(_ url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    @Test("關閉時什麼都不寫")
    func disabledWritesNothing() throws {
        let (recorder, url) = makeRecorder(enabled: false)
        defer { try? FileManager.default.removeItem(at: url) }
        recorder.recordFrame(uptime: 1, timestamp: 1, points: [(0.4, 0.5), (0.6, 0.5)])
        recorder.recordScroll(try scrollEvent(5), uptime: 1.01)
        recorder.recordLift(uptime: 1.1, timestamp: 1.1)
        recorder.flush()
        #expect(lines(url).isEmpty)
    }

    @Test("雙指的幀、期間的捲動事件、放開、放開後的慣性都依序記下來")
    func recordsTwoFingerSession() throws {
        let (recorder, url) = makeRecorder(enabled: true)
        defer { try? FileManager.default.removeItem(at: url) }

        recorder.recordFrame(uptime: 1, timestamp: 10, points: [(0.4, 0.5), (0.6, 0.5)])
        recorder.recordScroll(try scrollEvent(7), uptime: 1.01)
        recorder.recordFrame(uptime: 1.02, timestamp: 10.02, points: [(0.4, 0.52)])
        recorder.recordLift(uptime: 1.1, timestamp: 10.1)
        recorder.recordScroll(try scrollEvent(3), uptime: 1.5)      // 慣性
        recorder.flush()

        let records = lines(url)
        #expect(records.map { $0["k"] as? String } == ["f", "s", "f", "z", "s"])
        #expect((records[0]["p"] as? [[Double]])?.count == 2)
        #expect(records[1]["py"] as? Int == 7)
        #expect((records[2]["p"] as? [[Double]])?.count == 1)
        #expect(records[4]["py"] as? Int == 3)
    }

    @Test("單指的接觸與跟雙指無關的捲動事件不記錄")
    func ignoresSingleFingerAndUnrelatedScrolls() throws {
        let (recorder, url) = makeRecorder(enabled: true)
        defer { try? FileManager.default.removeItem(at: url) }

        recorder.recordFrame(uptime: 1, timestamp: 1, points: [(0.5, 0.5)])
        recorder.recordLift(uptime: 1.1, timestamp: 1.1)
        recorder.recordScroll(try scrollEvent(9), uptime: 1.2)     // 例如滑鼠滾輪
        recorder.flush()
        #expect(lines(url).isEmpty)
    }

    @Test("放開超過四秒之後的捲動事件不再算這次雙指的慣性")
    func momentumWindowExpires() throws {
        let (recorder, url) = makeRecorder(enabled: true)
        defer { try? FileManager.default.removeItem(at: url) }

        recorder.recordFrame(uptime: 1, timestamp: 1, points: [(0.4, 0.5), (0.6, 0.5)])
        recorder.recordLift(uptime: 1.1, timestamp: 1.1)
        recorder.recordScroll(try scrollEvent(9), uptime: 6)
        recorder.recordScroll(try scrollEvent(9), uptime: 6.1)
        recorder.flush()
        #expect(lines(url).map { $0["k"] as? String } == ["f", "z"])
    }
}
