import Foundation

/// `~/Library/Logs/TrackPal.traces.jsonl` 的一行：一次接觸的逐幀軌跡。
///
/// `frames` 每筆是 `[t, x, y, state, density, major, minor, valid]`：
/// - `t`：距離接觸開始的時間，單位 0.1 ms
/// - `x`、`y`：normalized 座標乘 10000
/// - `density` 乘 1000，`major`、`minor` 乘 100
/// - `valid`：1 表示當時通過輕觸／大面積過濾
public struct GestureTrace: Codable, Sendable, Equatable {
    public var id: UInt64
    public var date: String
    public var zone: String
    public var final: String
    public var outcome: String
    public var dur: Double
    public var pointerGap: Double?
    public var scrollGap: Double?
    public var stripDepth: Double
    public var edgeWidth: Double
    public var cornerSize: Double
    public var pixels: [Int64]
    public var force: Double
    public var frames: [[Int]]

    public struct Frame: Sendable, Equatable {
        public var elapsed: Double
        public var x: Float
        public var y: Float
        public var state: Int32
        public var density: Float
        public var majorAxis: Float
        public var minorAxis: Float
        public var wasValid: Bool
    }

    public var decodedFrames: [Frame] {
        frames.compactMap { raw in
            guard raw.count >= 8 else { return nil }
            return Frame(
                elapsed: Double(raw[0]) / 10_000,
                x: Float(raw[1]) / 10_000,
                y: Float(raw[2]) / 10_000,
                state: Int32(raw[3]),
                density: Float(raw[4]) / 1_000,
                majorAxis: Float(raw[5]) / 100,
                minorAxis: Float(raw[6]) / 100,
                wasValid: raw[7] != 0
            )
        }
    }

    /// 讀一個 jsonl 檔；壞掉的行（例如寫到一半）直接跳過。
    public static func load(contentsOf url: URL) throws -> [GestureTrace] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(GestureTrace.self, from: Data(line))
        }
    }

    /// 兩個軌跡檔，舊的在前。`directory` 沒給時用環境變數
    /// `TRACKPAL_TRACE_DIR`，再沒有就是 `~/Library/Logs`。
    public static func defaultLogURLs(in directory: URL? = nil) -> [URL] {
        let logs: URL
        if let directory {
            logs = directory
        } else if let override = ProcessInfo.processInfo
            .environment["TRACKPAL_TRACE_DIR"], !override.isEmpty {
            logs = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            logs = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs")
        }
        return [
            logs.appendingPathComponent("TrackPal.traces.previous.jsonl"),
            logs.appendingPathComponent("TrackPal.traces.jsonl"),
        ]
    }

    /// 依序讀兩個軌跡檔；不存在的檔案跳過。
    public static func loadDefaultLogs(in directory: URL? = nil) -> [GestureTrace] {
        defaultLogURLs(in: directory).flatMap { url in
            (try? load(contentsOf: url)) ?? []
        }
    }
}

extension EngineScenario {
    /// 把一串實機軌跡接成一段輸入，接觸之間保留原本的時間間隔（上限
    /// `maximumGap` 秒），所以「剛移完游標又落在長條」這類前後文也會重現。
    ///
    /// 軌跡檔沒有逐筆的壓力樣本，只有整次接觸的最大值。`synthesizeForce`
    /// 為 true 時，會替從角落、中鍵區起步的接觸補一段爬升到該最大值的壓力，
    /// 讓壓力相關的分支也走得到；這段是合成的，不代表當時真正的壓力曲線。
    public static func replaying(
        _ traces: [GestureTrace],
        name: String,
        settings: Settings,
        synthesizeForce: Bool = true,
        maximumGap: Double = 5
    ) -> EngineScenario {
        let groups = traceEvents(
            traces, synthesizeForce: synthesizeForce, maximumGap: maximumGap
        )
        return EngineScenario(
            name: name,
            settings: settings,
            events: [.pointer(x: 640, y: 400)] + groups.flatMap { $0 }
        )
    }

    /// `replaying` 的事件，依軌跡分組（跟輸入一一對應；沒有幀的軌跡是空陣列）。
    public static func traceEvents(
        _ traces: [GestureTrace],
        synthesizeForce: Bool = true,
        maximumGap: Double = 5
    ) -> [[Event]] {
        var groups: [[Event]] = []
        var clock = 1_000.0
        let uptimeOffset = 5_000.0
        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var previousEnd: Date?

        for trace in traces {
            var events: [Event] = []
            let frames = trace.decodedFrames
            guard !frames.isEmpty else {
                groups.append(events)
                continue
            }

            let start = dateParser.date(from: trace.date)
            if let start, let previousEnd {
                let gap = start.timeIntervalSince(previousEnd)
                clock += min(max(gap, 0.02), maximumGap)
            } else {
                clock += 1
            }
            let base = clock
            let lastElapsed = frames[frames.count - 1].elapsed

            let wantsForce = synthesizeForce
                && trace.force >= 20
                && (trace.zone.hasSuffix("Corner") || trace.zone == "middleClick")
            let rampStart = lastElapsed * 0.3
            let rampEnd = max(rampStart + 0.016, lastElapsed * 0.5)

            for frame in frames {
                let timestamp = base + frame.elapsed
                if wantsForce, frame.elapsed >= rampStart {
                    let progress = min(
                        1, (frame.elapsed - rampStart) / (rampEnd - rampStart)
                    )
                    events.append(.force(.init(
                        rawTimestamp: timestamp * 1_000,
                        uptime: timestamp + uptimeOffset,
                        force: Float(20 + (trace.force - 20) * progress)
                    )))
                }
                events.append(.touch(.init(
                    timestamp: timestamp,
                    uptime: timestamp + uptimeOffset,
                    count: 1,
                    x: frame.x,
                    y: frame.y,
                    state: frame.state,
                    density: frame.density,
                    majorAxis: frame.majorAxis,
                    minorAxis: frame.minorAxis
                )))
            }

            clock = base + lastElapsed + 0.008
            events.append(.touch(.init(
                timestamp: clock,
                uptime: clock + uptimeOffset,
                count: 0
            )))
            previousEnd = start?.addingTimeInterval(lastElapsed + 0.008)
            groups.append(events)
        }

        return groups
    }
}
