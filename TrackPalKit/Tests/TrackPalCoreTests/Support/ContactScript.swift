import Foundation
@testable import TrackPalCore

/// 用幾行程式描述一段觸控輸入：落指、移動、施壓、放開。
///
/// 每一幀相隔 8 ms（實機的取樣間隔），硬體時間與 uptime 差一個固定值。
struct ContactScript {
    private(set) var events: [EngineScenario.Event] = []
    private(set) var clock: Double = 100
    private let uptimeOffset: Double = 1_000
    private(set) var x: Double = 0.5
    private(set) var y: Double = 0.5
    var device = 0

    static let frameInterval = 0.008

    init(pointer: (Double, Double)? = (640, 400)) {
        if let pointer {
            events.append(.pointer(x: pointer.0, y: pointer.1))
        }
    }

    var uptime: Double { clock + uptimeOffset }

    private mutating func appendTouch(
        state: Int32,
        density: Float = 0.2,
        major: Float = 8,
        minor: Float = 6.5
    ) {
        events.append(.touch(.init(
            device: device,
            timestamp: clock,
            uptime: uptime,
            count: 1,
            x: Float(x),
            y: Float(y),
            state: state,
            density: density,
            majorAxis: major,
            minorAxis: minor
        )))
    }

    /// 手指落在 (x, y)。
    mutating func down(_ x: Double, _ y: Double, state: Int32 = 2) {
        self.x = x
        self.y = y
        appendTouch(state: state)
    }

    /// 每幀移動 (dx, dy)，共 `frames` 幀。
    mutating func move(dx: Double, dy: Double, frames: Int, state: Int32 = 4) {
        for _ in 0..<frames {
            clock += Self.frameInterval
            x = min(1, max(0, x + dx))
            y = min(1, max(0, y + dy))
            appendTouch(state: state)
        }
    }

    /// 停在原地 `frames` 幀。
    mutating func hold(frames: Int) {
        move(dx: 0, dy: 0, frames: frames)
    }

    /// 過 `seconds` 秒（不產生任何幀）。
    mutating func wait(_ seconds: Double) {
        clock += seconds
    }

    /// 在目前時間送一筆壓力樣本。
    mutating func force(_ value: Float) {
        events.append(.force(.init(
            device: device,
            rawTimestamp: clock * 1_000,
            uptime: uptime,
            x: Float(x),
            y: Float(y),
            force: value
        )))
    }

    /// 輕觸（density 低於門檻）的幀。
    mutating func lightFrames(_ count: Int) {
        for _ in 0..<count {
            clock += Self.frameInterval
            appendTouch(state: 4, density: 0.005, major: 5, minor: 4)
        }
    }

    /// 手掌大小的幀。
    mutating func palmFrames(_ count: Int) {
        for _ in 0..<count {
            clock += Self.frameInterval
            appendTouch(state: 4, major: 20, minor: 14)
        }
    }

    /// 抬起中（state 6）的幀。
    mutating func lifting(dx: Double = 0, dy: Double = 0) {
        clock += Self.frameInterval
        x += dx
        y += dy
        appendTouch(state: 6, density: 0, major: 3, minor: 3)
    }

    /// 懸停（state 1）的幀。
    mutating func hover() {
        appendTouch(state: 1)
    }

    /// 第二根手指落下，持續 `frames` 幀。
    mutating func multiFinger(frames: Int, count: Int = 2) {
        for _ in 0..<frames {
            clock += Self.frameInterval
            events.append(.touch(.init(
                device: device, timestamp: clock, uptime: uptime, count: count
            )))
        }
    }

    /// 全部手指放開。
    mutating func lift() {
        clock += Self.frameInterval
        events.append(.touch(.init(
            device: device, timestamp: clock, uptime: uptime, count: 0
        )))
    }

    mutating func restart() {
        events.append(.restart(uptime: uptime))
    }

    func scenario(
        _ name: String = "test",
        deviceCount: Int = 1,
        configure: (inout EngineScenario.Settings) -> Void = { _ in }
    ) -> EngineScenario {
        var settings = EngineScenario.Settings()
        configure(&settings)
        return EngineScenario(
            name: name,
            settings: settings,
            deviceCount: deviceCount,
            events: events
        )
    }

    @MainActor
    func run(
        deviceCount: Int = 1,
        configure: (inout EngineScenario.Settings) -> Void = { _ in }
    ) -> Transcript {
        Transcript(lines: EngineScenarioRunner.run(
            scenario(deviceCount: deviceCount, configure: configure)
        ))
    }
}

/// 狀態機輸出的查詢介面。
struct Transcript {
    let lines: [String]

    struct Scroll: Equatable {
        var deltaX: Int
        var deltaY: Int
    }

    /// 所有帶位移的捲動（不含零位移的結束標記）。
    var scrolls: [Scroll] {
        lines.compactMap { line in
            guard line.hasPrefix("scroll ") else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count == 5,
                  let dx = Int(parts[1]), let dy = Int(parts[2]),
                  dx != 0 || dy != 0 else { return nil }
            return Scroll(deltaX: dx, deltaY: dy)
        }
    }

    var totalScrollX: Int { scrolls.reduce(0) { $0 + $1.deltaX } }
    var totalScrollY: Int { scrolls.reduce(0) { $0 + $1.deltaY } }

    /// 每次接觸的 terminal outcome，依序。
    var outcomes: [String] {
        lines.compactMap { line in
            guard let range = line.range(of: " terminal outcome=") else { return nil }
            return String(line[range.upperBound...].prefix { $0 != " " })
        }
    }

    /// `flags <捲動中> <判斷中>` 的變化序列。
    var flags: [String] {
        lines.filter { $0.hasPrefix("flags ") }.map { String($0.dropFirst(6)) }
    }

    var logs: [String] {
        lines.filter { $0.hasPrefix("log ") }.map { String($0.dropFirst(4)) }
    }

    func count(prefix: String) -> Int {
        lines.count { $0.hasPrefix(prefix) }
    }

    func contains(_ text: String) -> Bool {
        lines.contains { $0.contains(text) }
    }

    func lines(prefix: String) -> [String] {
        lines.filter { $0.hasPrefix(prefix) }
    }
}
