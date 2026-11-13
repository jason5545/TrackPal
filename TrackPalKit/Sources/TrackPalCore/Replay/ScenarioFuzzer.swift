import Foundation

/// 可重現的亂數（SplitMix64）。同一個 seed 在任何機器上都產生同一串數字，
/// 所以 fuzz 情境可以當回歸測試的固定輸入。
public struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1)
    public mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    public mutating func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }

    public mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    public mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }

    public mutating func pick<Element>(_ elements: [Element]) -> Element {
        elements[int(in: 0...(elements.count - 1))]
    }
}

/// 依 seed 產生一段多次接觸的輸入：各種起點、移動方式、壓力曲線、無效幀、
/// 多指、第二台裝置與中途重啟。目的不是模擬真人，而是把狀態機的分支踩開。
public enum ScenarioFuzzer {
    public static func scenario(seed: UInt64) -> EngineScenario {
        var generator = Generator(seed: seed)
        return generator.makeScenario(name: "fuzz-\(seed)")
    }

    private struct Generator {
        var rng: SplitMix64
        var settings = EngineScenario.Settings()
        var events: [EngineScenario.Event] = []
        var clock: Double
        var uptimeOffset: Double
        var deviceCount = 1

        init(seed: UInt64) {
            rng = SplitMix64(seed: seed)
            clock = 1_000 + rng.double(in: 0...10)
            uptimeOffset = 5_000 + rng.unit()
        }

        mutating func makeScenario(name: String) -> EngineScenario {
            makeSettings()
            events.append(.pointer(
                x: rng.double(in: 0...1_500).rounded(),
                y: rng.double(in: 0...900).rounded()
            ))

            let contactCount = rng.int(in: 2...6)
            for _ in 0..<contactCount {
                clock += rng.pick([0.03, 0.2, 0.5, 0.9, 1.5, 3.0])
                    * rng.double(in: 0.5...1.5)
                if rng.chance(0.04) {
                    events.append(.restart(uptime: uptime(at: clock)))
                    clock += 0.05
                }
                makeContact()
            }

            return EngineScenario(
                name: name,
                settings: settings,
                deviceCount: deviceCount,
                events: events
            )
        }

        private mutating func makeSettings() {
            settings.edgeZoneWidth = rng.pick([0.05, 0.1302, 0.15, 0.22, 0.30])
            settings.bottomZoneHeight = rng.pick([0.10, 0.1647, 0.30, 0.40])
            settings.scrollMultiplier = rng.pick([1.0, 3.0, 3.0, 5.5, 10.0])
            settings.verticalEdgeMode = rng.pick(
                ["right", "right", "right", "left", "both"]
            )
            settings.horizontalPosition = rng.pick(
                ["bottom", "bottom", "bottom", "top"]
            )
            settings.middleClickEnabled = rng.chance(0.7)
            settings.accelerationCurveType = rng.pick(
                ["linear", "linear", "linear", "quadratic", "cubic", "ease"]
            )
            settings.cornerTriggerEnabled = rng.chance(0.6)
            settings.cornerTriggerZoneSize = rng.pick([0.05, 0.0684, 0.15, 0.25])
            let actions = [
                "none", "none", "rightClick", "rightClick", "missionControl",
                "appWindows", "showDesktop", "launchpad", "notificationCenter",
            ]
            settings.cornerActionTopLeft = rng.pick(actions)
            settings.cornerActionTopRight = rng.pick(actions)
            settings.cornerActionBottomLeft = rng.pick(actions)
            settings.cornerActionBottomRight = rng.pick(actions)
            settings.filterLightTouches = rng.chance(0.85)
            settings.filterLargeTouches = rng.chance(0.85)
            deviceCount = rng.chance(0.15) ? 2 : 1
        }

        private func uptime(at timestamp: Double) -> Double {
            timestamp + uptimeOffset
        }

        // MARK: - Contact

        private enum StartZone: CaseIterable {
            case rightEdge, leftEdge, bottom, top
            case bottomRight, bottomLeft, topRight, topLeft
            case middleTop, middleBottom, center
        }

        private enum Motion: CaseIterable {
            case tap, holdStill, slideVertical, slideHorizontal, diagonal
            case tremor, pauseThenSlide, slideThenTurn, flick
            case inwardThenSlide, slowCreep
        }

        private mutating func startPosition(_ zone: StartZone) -> (Double, Double) {
            let edge = settings.edgeZoneWidth
            let strip = settings.bottomZoneHeight
            let corner = settings.cornerTriggerZoneSize
            let stripDepth = rng.chance(0.6)
                ? rng.double(in: 0...min(strip, 0.08))
                : rng.double(in: 0...(strip * 1.1))
            switch zone {
            case .rightEdge:
                return (1 - edge * rng.double(in: 0...1.1), rng.double(in: 0.2...0.8))
            case .leftEdge:
                return (edge * rng.double(in: 0...1.1), rng.double(in: 0.2...0.8))
            case .bottom:
                return (rng.double(in: 0.2...0.8), stripDepth)
            case .top:
                return (rng.double(in: 0.2...0.8), 1 - stripDepth)
            case .bottomRight:
                return (
                    1 - corner * rng.double(in: 0...1.5),
                    corner * rng.double(in: 0...1.5)
                )
            case .bottomLeft:
                return (
                    corner * rng.double(in: 0...1.5),
                    corner * rng.double(in: 0...1.5)
                )
            case .topRight:
                return (
                    1 - corner * rng.double(in: 0...1.5),
                    1 - corner * rng.double(in: 0...1.5)
                )
            case .topLeft:
                return (
                    corner * rng.double(in: 0...1.5),
                    1 - corner * rng.double(in: 0...1.5)
                )
            case .middleTop:
                return (rng.double(in: 0.36...0.64), rng.double(in: 0.86...1.0))
            case .middleBottom:
                return (rng.double(in: 0.36...0.64), rng.double(in: 0...0.14))
            case .center:
                return (rng.double(in: 0.3...0.7), rng.double(in: 0.35...0.65))
            }
        }

        /// 每一幀的位移（normalized 單位）。
        private mutating func steps(for motion: Motion) -> [(Double, Double, Double)] {
            // (dx, dy, dt)
            let frame = 0.008
            func jitter(_ rng: inout SplitMix64, _ scale: Double) -> Double {
                rng.double(in: -scale...scale)
            }
            let sign: Double = rng.chance(0.5) ? 1 : -1
            let speed = rng.pick([0.0015, 0.004, 0.008, 0.015, 0.03])
            var result: [(Double, Double, Double)] = []

            switch motion {
            case .tap:
                for _ in 0..<rng.int(in: 2...9) {
                    result.append((jitter(&rng, 0.0008), jitter(&rng, 0.0008), frame))
                }
            case .holdStill:
                for _ in 0..<rng.int(in: 30...150) {
                    result.append((jitter(&rng, 0.0004), jitter(&rng, 0.0004), frame))
                }
            case .slideVertical:
                for _ in 0..<rng.int(in: 10...60) {
                    result.append((jitter(&rng, speed * 0.15), sign * speed, frame))
                }
            case .slideHorizontal:
                for _ in 0..<rng.int(in: 10...60) {
                    result.append((sign * speed, jitter(&rng, speed * 0.15), frame))
                }
            case .diagonal:
                let ratio = rng.double(in: 0.3...1.7)
                let vertical: Double = rng.chance(0.5) ? 1 : -1
                for _ in 0..<rng.int(in: 10...50) {
                    result.append((sign * speed, vertical * speed * ratio, frame))
                }
            case .tremor:
                for _ in 0..<rng.int(in: 20...90) {
                    result.append((jitter(&rng, 0.003), jitter(&rng, 0.003), frame))
                }
            case .pauseThenSlide:
                for _ in 0..<rng.int(in: 3...20) {
                    result.append((jitter(&rng, 0.0003), jitter(&rng, 0.0003), frame))
                }
                result.append((0, 0, rng.double(in: 0.1...0.5)))
                let horizontal = rng.chance(0.5)
                for _ in 0..<rng.int(in: 10...40) {
                    result.append(horizontal
                        ? (sign * speed, jitter(&rng, speed * 0.1), frame)
                        : (jitter(&rng, speed * 0.1), sign * speed, frame))
                }
            case .slideThenTurn:
                let horizontalFirst = rng.chance(0.5)
                for _ in 0..<rng.int(in: 8...30) {
                    result.append(horizontalFirst
                        ? (sign * speed, jitter(&rng, speed * 0.1), frame)
                        : (jitter(&rng, speed * 0.1), sign * speed, frame))
                }
                let turn: Double = rng.chance(0.5) ? 1 : -1
                for _ in 0..<rng.int(in: 8...30) {
                    result.append(horizontalFirst
                        ? (jitter(&rng, speed * 0.1), turn * speed, frame)
                        : (turn * speed, jitter(&rng, speed * 0.1), frame))
                }
            case .flick:
                let horizontal = rng.chance(0.5)
                for index in 0..<rng.int(in: 4...10) {
                    let v = 0.01 + Double(index) * 0.006
                    result.append(horizontal ? (sign * v, 0, frame) : (0, sign * v, frame))
                }
            case .inwardThenSlide:
                for _ in 0..<rng.int(in: 3...10) {
                    result.append((jitter(&rng, 0.001), rng.double(in: -0.006...0.006), frame))
                }
                for _ in 0..<rng.int(in: 10...40) {
                    result.append((sign * speed, jitter(&rng, speed * 0.2), frame))
                }
            case .slowCreep:
                let horizontal = rng.chance(0.5)
                for _ in 0..<rng.int(in: 40...160) {
                    let v = rng.double(in: 0.0001...0.0006)
                    result.append(horizontal ? (sign * v, 0, frame) : (0, sign * v, frame))
                }
            }

            // 落指時質心跳動。
            if rng.chance(0.3), !result.isEmpty {
                result[0].0 += jitter(&rng, 0.03)
                result[0].1 += jitter(&rng, 0.03)
            }
            // 取樣間隔抖動。
            for index in result.indices where rng.chance(0.1) {
                result[index].2 *= rng.double(in: 0.6...2.5)
            }
            return result
        }

        private mutating func makeContact() {
            let zone = rng.pick(StartZone.allCases)
            let motion = rng.pick(Motion.allCases)
            var (x, y) = startPosition(zone)
            let device = deviceCount == 2 && rng.chance(0.3) ? 1 : 0
            let movement = steps(for: motion)

            let invalidStart = rng.chance(0.14)
                ? rng.int(in: 0...max(0, movement.count - 1)) : -1
            let invalidLength = rng.int(in: 1...4)
            let invalidIsLarge = rng.chance(0.5)
            let multiFingerAt = rng.chance(0.1)
                ? rng.int(in: 1...max(1, movement.count)) : -1
            let interferenceAt = deviceCount == 2 && rng.chance(0.3)
                ? rng.int(in: 0...max(0, movement.count - 1)) : -1

            let isForceZone: Bool
            switch zone {
            case .bottomRight, .bottomLeft, .topRight, .topLeft,
                 .middleTop, .middleBottom:
                isForceZone = true
            default:
                isForceZone = false
            }
            let hasForce = isForceZone ? rng.chance(0.8) : rng.chance(0.15)
            let forcePeak = rng.pick([40.0, 65, 75, 90, 105, 150, 220])
            let forceStart = rng.int(in: -1...max(0, movement.count * 7 / 10))
            let forceRamp = rng.int(in: 2...8)
            let forceRunsLate = rng.chance(0.1)

            // 起始幀。
            if rng.chance(0.05) {
                appendTouch(device: device, x: x, y: y, state: 1)
                clock += 0.008
            }
            appendForce(
                device: device, index: -1, start: forceStart, ramp: forceRamp,
                peak: forcePeak, enabled: hasForce
            )
            appendTouch(
                device: device, x: x, y: y,
                state: rng.pick([2, 2, 2, 2, 2, 2, 3, 3, 4])
            )

            var endedByMultiFinger = false
            for (index, step) in movement.enumerated() {
                clock += step.2
                x = min(1, max(0, x + step.0))
                y = min(1, max(0, y + step.1))

                if index == interferenceAt {
                    let other = 1 - device
                    appendTouch(device: other, x: 0.5, y: 0.5, state: 2)
                    appendTouch(device: other, x: 0.5, y: 0.5, state: 4, advance: 0.004)
                    appendZero(device: other, advance: 0.006)
                }

                if index == multiFingerAt {
                    for _ in 0..<rng.int(in: 1...5) {
                        events.append(.touch(.init(
                            device: device, timestamp: clock,
                            uptime: uptime(at: clock), count: 2
                        )))
                        clock += 0.008
                    }
                    endedByMultiFinger = rng.chance(0.5)
                    if endedByMultiFinger { break }
                }

                let forceBeforeTouch = rng.chance(0.5)
                if forceBeforeTouch {
                    appendForce(
                        device: device, index: index, start: forceStart,
                        ramp: forceRamp, peak: forcePeak, enabled: hasForce
                    )
                }

                if index >= invalidStart, invalidStart >= 0,
                   index < invalidStart + invalidLength {
                    if invalidIsLarge {
                        appendTouch(
                            device: device, x: x, y: y, state: 4,
                            density: 0.2, major: rng.double(in: 16...25),
                            minor: rng.double(in: 9...16)
                        )
                    } else {
                        appendTouch(
                            device: device, x: x, y: y, state: 4,
                            density: 0.005, major: 5, minor: 4
                        )
                    }
                } else if rng.chance(0.0004) {
                    appendTouch(device: device, x: .nan, y: y, state: 4)
                } else {
                    appendTouch(
                        device: device, x: x, y: y,
                        state: rng.pick([4, 4, 4, 4, 4, 4, 3, 5])
                    )
                }

                if !forceBeforeTouch {
                    appendForce(
                        device: device, index: index, start: forceStart,
                        ramp: forceRamp, peak: forcePeak, enabled: hasForce
                    )
                }
            }

            if !endedByMultiFinger, rng.chance(0.5) {
                for _ in 0..<rng.int(in: 1...2) {
                    clock += 0.008
                    if rng.chance(0.4) {
                        x = min(1, max(0, x + rng.double(in: -0.004...0.004)))
                        y = min(1, max(0, y + rng.double(in: -0.004...0.004)))
                    }
                    appendTouch(
                        device: device, x: x, y: y, state: 6,
                        density: 0, major: 3, minor: 3
                    )
                }
            }

            if hasForce, forceRunsLate {
                // 放開後才送達的壓力樣本。
                let late = clock + rng.double(in: 0.001...0.03)
                events.append(.force(.init(
                    device: device,
                    rawTimestamp: rng.chance(0.3) ? 0 : late * 1_000,
                    uptime: uptime(at: late) + 0.002,
                    force: Float(forcePeak)
                )))
            }
            appendZero(device: device, advance: 0.008)
        }

        private mutating func appendTouch(
            device: Int,
            x: Double,
            y: Double,
            state: Int32,
            density: Double? = nil,
            major: Double? = nil,
            minor: Double? = nil,
            advance: Double = 0
        ) {
            clock += advance
            events.append(.touch(.init(
                device: device,
                timestamp: clock,
                uptime: uptime(at: clock) + rng.double(in: 0...0.002),
                count: 1,
                x: Float(x),
                y: Float(y),
                state: state,
                density: Float(density ?? rng.double(in: 0.08...0.3)),
                majorAxis: Float(major ?? rng.double(in: 6.5...10)),
                minorAxis: Float(minor ?? rng.double(in: 5...8))
            )))
        }

        private mutating func appendZero(device: Int, advance: Double) {
            clock += advance
            events.append(.touch(.init(
                device: device,
                timestamp: clock,
                uptime: uptime(at: clock) + rng.double(in: 0...0.002),
                count: 0
            )))
        }

        private mutating func appendForce(
            device: Int,
            index: Int,
            start: Int,
            ramp: Int,
            peak: Double,
            enabled: Bool
        ) {
            guard enabled, index >= start else { return }
            let progress = min(1, Double(index - start + 1) / Double(ramp))
            let force = 20 + (peak - 20) * progress
            let sampleTime = clock + rng.double(in: -0.003...0.003)
            events.append(.force(.init(
                device: device,
                rawTimestamp: rng.chance(0.01) ? 0 : sampleTime * 1_000,
                uptime: uptime(at: sampleTime) + rng.double(in: 0...0.004),
                x: 0.5,
                y: 0.5,
                force: Float(force)
            )))
        }
    }
}
