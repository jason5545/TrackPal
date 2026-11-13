import Foundation
import TrackPalCore

// 把 ~/Library/Logs/TrackPal.traces*.jsonl 的實機軌跡丟進真正的判斷邏輯重算。
// 用的是 App 裡跑的同一份程式碼，沒有另外的複本。

let usage = """
用法：
  trackpal-replay [strip] [名稱=數值 ...] [--summary] [--dir <資料夾>]
      水平長條：每筆從下方／上方區起步的接觸，列出當時的結果與重算的結果。
      可以帶門檻試算，例如 D=0.04 slope=0.3。
      名稱：D、DC（一般／較嚴的水平淨位移）、T、TC（最短持續時間）、
            slope（往內側的斜度上限）、descent（往邊緣靠的斜度上限）、
            wander（路徑上限）、window（游標活動後多久內算接力）、
            scrollWindow（水平捲動後多久內算接著捲）。

  trackpal-replay engine [--summary] [--dir <資料夾>]
      整個狀態機：所有區域的接觸依時間順序重播，列出當時的結果與重播的結果。
      軌跡檔沒有逐筆壓力與多指資料，角落、中鍵區的壓力是照最大值合成的，
      這一類的結果僅供參考。

  trackpal-replay native [<記錄檔>]
      跟原生雙指捲動對帳：把 NativeScrollRecorder 錄到的雙指軌跡當成單指在
      右側邊緣的滑動，丟進狀態機（靈敏度 1.0），比較接觸段與慣性的捲動量
      跟系統當時實際送出的差多少。記錄檔預設是
      ~/Library/Logs/TrackPal.native-scroll.jsonl。

  trackpal-replay transcript fuzz <起始 seed> <結束 seed> <輸出檔>
  trackpal-replay transcript traces <每段幾筆> <輸出檔> [--dir <資料夾>]
      把狀態機對外做的每一件事寫成文字檔。重構前後各跑一次再 diff，
      可以確認行為沒有變。

  --dir 沒給時讀 ~/Library/Logs（或環境變數 TRACKPAL_TRACE_DIR）。
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}

var traceDirectory: URL?
if let index = arguments.firstIndex(of: "--dir") {
    guard index + 1 < arguments.count else { fail("--dir 後面要接資料夾") }
    traceDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    arguments.removeSubrange(index...(index + 1))
}
let summaryOnly = arguments.contains("--summary")
arguments.removeAll { $0 == "--summary" }

let command = arguments.first.flatMap { ["strip", "engine", "transcript", "native"].contains($0) ? $0 : nil } ?? "strip"
if arguments.first == command { arguments.removeFirst() }

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func printTable(_ table: [String: Int], title: String) {
    print(title)
    for (key, count) in table.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
        print(String(format: "%6d  %@", count, key))
    }
}

/// App 目前的設定（沒寫進軌跡檔的那些欄位），讀不到就用預設值。
func currentAppSettings() -> EngineScenario.Settings {
    var settings = EngineScenario.Settings()
    guard let defaults = UserDefaults(suiteName: "com.jasonchien.TrackPal") else {
        return settings
    }
    func string(_ key: String, _ fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }
    func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
    settings.scrollMultiplier = defaults.object(forKey: "scrollMultiplier") as? Double ?? 3.0
    settings.verticalEdgeMode = string("verticalEdgeMode", "right")
    settings.horizontalPosition = string("horizontalPosition", "bottom")
    settings.middleClickEnabled = bool("middleClickEnabled", true)
    settings.accelerationCurveType = string("accelerationCurveType", "linear")
    settings.cornerTriggerEnabled = bool("cornerTriggerEnabled", false)
    settings.cornerActionTopLeft = string("cornerActionTopLeft", "none")
    settings.cornerActionTopRight = string("cornerActionTopRight", "none")
    settings.cornerActionBottomLeft = string("cornerActionBottomLeft", "none")
    settings.cornerActionBottomRight = string("cornerActionBottomRight", "rightClick")
    settings.filterLightTouches = bool("filterLightTouches", true)
    settings.filterLargeTouches = bool("filterLargeTouches", true)
    return settings
}

func outcomeFamily(_ outcome: String) -> String {
    String(outcome.split(separator: ":").first ?? "")
}

switch command {
case "strip":
    var overrides = StripGateReplay.Overrides()
    for argument in arguments {
        let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, let value = Double(parts[1]),
              overrides.set(parts[0], to: value) else {
            fail("看不懂的參數：\(argument)\n\n\(usage)")
        }
    }

    var table: [String: Int] = [:]
    for trace in GestureTrace.loadDefaultLogs(in: traceDirectory) {
        guard let result = StripGateReplay.replay(trace, overrides: overrides) else {
            continue
        }
        table["\(pad(outcomeFamily(trace.outcome), 22)) → \(result.decision)", default: 0] += 1
        guard !summaryOnly else { continue }

        let frames = trace.decodedFrames
        guard let first = frames.first, let last = frames.last else { continue }
        let date = trace.date.count >= 19
            ? String(trace.date.dropFirst(5).prefix(14)) : trace.date
        let decidedAt = result.decidedAt.map { String(format: "%.3f", $0) } ?? "-"
        print(
            "#\(pad(String(trace.id), 5)) \(date) actual=\(pad(String(trace.outcome.prefix(32)), 32)) replay=\(pad(result.decision, 30)) at=\(decidedAt) after=\(result.landedAfterPointerActivity ? 1 : 0) dur=\(trace.dur)"
            + String(format: " start=(%.3f,%.3f) end=(%.3f,%.3f)", first.x, first.y, last.x, last.y)
            + " pix=\(trace.pixels.first ?? 0)"
        )
    }
    printTable(table, title: "--- 當時的結果 → 重算")

case "engine":
    let traces = GestureTrace.loadDefaultLogs(in: traceDirectory)
    guard let first = traces.first else { fail("找不到軌跡檔") }
    var settings = currentAppSettings()
    settings.bottomZoneHeight = first.stripDepth
    settings.edgeZoneWidth = first.edgeWidth
    settings.cornerTriggerZoneSize = first.cornerSize

    var options = EngineScenarioRunner.Options()
    options.recordsTraceFrames = false
    guard var session = EngineScenarioRunner.Session(settings: settings, options: options) else {
        fail("App 設定裡有不認得的值")
    }
    session.feed(.pointer(x: 640, y: 400))

    var table: [String: Int] = [:]
    var sizes = (first.stripDepth, first.edgeWidth, first.cornerSize)
    var start = 0
    // 區域大小改過的話，從那一筆起換一個新的狀態機。
    while start < traces.count {
        var end = start
        while end < traces.count,
              (traces[end].stripDepth, traces[end].edgeWidth, traces[end].cornerSize) == sizes {
            end += 1
        }
        let batch = Array(traces[start..<end])
        for (trace, events) in zip(batch, EngineScenario.traceEvents(batch)) {
            var replayed = "(未開始追蹤)"
            for event in events {
                for line in session.feed(event) where line.hasPrefix("trace-finish ") {
                    let fields = line.split(separator: " ")
                    if fields.count > 4 { replayed = String(fields[4]) }
                }
            }
            table["\(pad(trace.zone, 18)) \(pad(outcomeFamily(trace.outcome), 22)) → \(outcomeFamily(replayed))", default: 0] += 1
            if !summaryOnly {
                print("#\(pad(String(trace.id), 5)) \(pad(trace.zone, 18)) actual=\(pad(trace.outcome, 34)) replay=\(replayed)")
            }
        }
        start = end
        if start < traces.count {
            sizes = (traces[start].stripDepth, traces[start].edgeWidth, traces[start].cornerSize)
            settings.bottomZoneHeight = sizes.0
            settings.edgeZoneWidth = sizes.1
            settings.cornerTriggerZoneSize = sizes.2
            guard let next = EngineScenarioRunner.Session(settings: settings, options: options) else {
                fail("App 設定裡有不認得的值")
            }
            session = next
            session.feed(.pointer(x: 640, y: 400))
        }
    }
    printTable(table, title: "--- 起步區域 當時的結果 → 重播")

case "native":
    let path = arguments.first ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TrackPal.native-scroll.jsonl").path
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("讀不到 \(path)")
    }

    struct NativeSession {
        var frames: [(uptime: Double, y: Double)] = []      // 雙指的質心
        var contactPixels = 0.0
        var momentumPixels = 0.0
        var hasLifted = false
    }
    var sessions: [NativeSession] = []
    var current = NativeSession()
    for line in text.split(separator: "\n") {
        guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let kind = record["k"] as? String, let uptime = record["u"] as? Double else {
            continue
        }
        switch kind {
        case "f":
            if current.hasLifted {
                sessions.append(current)
                current = NativeSession()
            }
            if let points = record["p"] as? [[Double]], points.count == 2 {
                current.frames.append((uptime, (points[0][1] + points[1][1]) / 2))
            }
        case "z":
            current.hasLifted = true
        case "s":
            let pixels = abs(record["py"] as? Double ?? 0)
            let momentum = record["mo"] as? Int ?? 0
            if momentum == 0 {
                current.contactPixels += pixels
            } else if momentum == 1 || momentum == 2 {
                current.momentumPixels += pixels
            }
        default:
            break
        }
    }
    if !current.frames.isEmpty { sessions.append(current) }
    sessions = sessions.filter { $0.frames.count >= 8 && $0.contactPixels > 0 }
    guard !sessions.isEmpty else { fail("記錄檔裡沒有可用的雙指捲動") }

    var settings = EngineScenario.Settings()
    settings.scrollMultiplier = 1
    settings.bottomZoneHeight = 0.10
    settings.middleClickEnabled = false
    settings.cornerTriggerEnabled = false

    var nativeContact = 0.0, nativeMomentum = 0.0
    var engineContact = 0.0, engineMomentum = 0.0
    var ratios: [Double] = []
    var nativeOnly = 0, engineOnly = 0
    for session in sessions {
        // 軌跡平移到觸控板中段，避開上下的區域；只取垂直分量。
        let origin = session.frames[0]
        var events: [EngineScenario.Event] = []
        for (index, frame) in session.frames.enumerated() {
            let time = 100 + frame.uptime - origin.uptime
            let y = min(0.88, max(0.12, 0.5 + frame.y - origin.y))
            events.append(.touch(.init(
                timestamp: time, uptime: time + 1_000, count: 1,
                x: 0.95, y: Float(y), state: index == 0 ? 2 : 4,
                density: 0.2, majorAxis: 8, minorAxis: 6.5
            )))
        }
        let end = 100 + session.frames[session.frames.count - 1].uptime - origin.uptime + 0.008
        events.append(.touch(.init(timestamp: end, uptime: end + 1_000, count: 0)))

        var contact = 0.0, momentum = 0.0
        for line in EngineScenarioRunner.run(EngineScenario(name: "native", settings: settings, events: events)) {
            let fields = line.split(separator: " ")
            if fields.first == "scroll", fields.count == 5 {
                contact += abs(Double(fields[2]) ?? 0)
            } else if fields.first == "inertia-start", fields.count == 3 {
                let speed = abs(Double(fields[2]) ?? 0)
                momentum = max(0, NativeScrollCurve.momentumTimeConstant
                    * (speed - Double(NativeScrollCurve.momentumStopSpeed)))
            }
        }

        nativeContact += session.contactPixels
        nativeMomentum += session.momentumPixels
        engineContact += contact
        engineMomentum += momentum
        if session.momentumPixels > 0, momentum == 0 { nativeOnly += 1 }
        if session.momentumPixels == 0, momentum > 0 { engineOnly += 1 }
        if session.momentumPixels > 0, momentum > 0 {
            ratios.append((contact + momentum) / (session.contactPixels + session.momentumPixels))
        }
    }
    ratios.sort()
    func quantile(_ q: Double) -> Double {
        ratios.isEmpty ? .nan : ratios[Int(q * Double(ratios.count - 1))]
    }
    print("雙指捲動 \(sessions.count) 次；同樣的手指軌跡，原生實際送出 → 狀態機（靈敏度 1.0）")
    print(String(format: "  接觸段  %6.0f px → %6.0f px（%.2f 倍）", nativeContact, engineContact, engineContact / nativeContact))
    print(String(format: "  慣性    %6.0f px → %6.0f px（%.2f 倍）", nativeMomentum, engineMomentum, engineMomentum / max(nativeMomentum, 1)))
    print(String(format: "  合計    %6.0f px → %6.0f px（%.2f 倍）", nativeContact + nativeMomentum, engineContact + engineMomentum,
                 (engineContact + engineMomentum) / (nativeContact + nativeMomentum)))
    print(String(format: "  兩邊都有慣性的 %d 次，每次合計的比值：P25 %.2f  中位數 %.2f  P75 %.2f",
                 ratios.count, quantile(0.25), quantile(0.5), quantile(0.75)))
    print("  原生有慣性、狀態機沒有：\(nativeOnly) 次；原生沒有、狀態機有：\(engineOnly) 次")
    print("  （原生要先認出雙指捲動才開始送，起步那一小段不捲；狀態機沒有這段，所以接觸段會偏多。）")

case "transcript":
    guard let kind = arguments.first, let outputPath = arguments.last,
          arguments.count >= 3 else {
        fail(usage)
    }
    var output = ""
    func append(_ scenario: EngineScenario) {
        output += "### \(scenario.name)\n"
            + EngineScenarioRunner.run(scenario).joined(separator: "\n") + "\n"
    }

    switch kind {
    case "fuzz":
        guard arguments.count == 4,
              let from = UInt64(arguments[1]), let to = UInt64(arguments[2]),
              from <= to else {
            fail(usage)
        }
        for seed in from...to {
            append(ScenarioFuzzer.scenario(seed: seed))
        }

    case "traces":
        guard arguments.count == 3, let chunk = Int(arguments[1]), chunk > 0 else {
            fail(usage)
        }
        // 固定的一組設定，讓重構前後的輸出可以直接比對。
        var index = 0
        for url in GestureTrace.defaultLogURLs(in: traceDirectory) {
            guard let traces = try? GestureTrace.load(contentsOf: url) else { continue }
            var start = 0
            while start < traces.count {
                let slice = Array(traces[start..<min(start + chunk, traces.count)])
                var settings = EngineScenario.Settings()
                settings.bottomZoneHeight = slice[0].stripDepth
                settings.edgeZoneWidth = slice[0].edgeWidth
                settings.cornerTriggerZoneSize = slice[0].cornerSize
                settings.scrollMultiplier = 1
                settings.cornerTriggerEnabled = true
                settings.cornerActionTopLeft = "showDesktop"
                settings.cornerActionBottomRight = "rightClick"
                append(EngineScenario.replaying(
                    slice, name: "traces-\(index)", settings: settings
                ))
                index += 1
                start += chunk
            }
        }

    default:
        fail(usage)
    }

    do {
        try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
    } catch {
        fail("寫不進 \(outputPath)：\(error.localizedDescription)")
    }

default:
    fail(usage)
}
