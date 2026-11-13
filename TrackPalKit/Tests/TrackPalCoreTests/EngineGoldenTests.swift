import CryptoKit
import Foundation
import Testing
@testable import TrackPalCore

/// 回歸指紋：固定 seed 的隨機情境丟進狀態機，整串輸出（每一筆捲動、點擊、
/// 日誌、旗標變化）的 SHA-256 必須跟記錄的值一樣。
///
/// 來歷：2026-11-13 重構時，新狀態機與重構前的程式碼（140fdf4）在 6,000 組
/// 情境與 3,758 筆實機軌跡上的輸出逐位元相同，當時的指紋是用重構前的輸出
/// 算的（commit 9460c38）。同一天把捲動改成逐像素、換算倍率從 100 改成 800，
/// 指紋隨之更新；那次改動前後，21,538 次接觸與 3,758 筆實機軌跡的判定結果
/// 沒有任何一筆不同，變的只有捲動的像素數量與連帶的紀錄。
///
/// 接著照原生雙指捲動的實測換掉增益與慣性（`NativeScrollCurve`），指紋再更新
/// 一次；同樣驗過那兩批輸入的判定結果沒有任何一筆不同。
///
/// 之後任何重構只要讓指紋變了，就代表某個可觀察的行為（或日誌文字）改了。
///
/// 刻意改行為或改日誌格式時，用下面的指令印出新的指紋，貼回 `expected`：
///
///     TRACKPAL_PRINT_GOLDEN=1 swift test --filter EngineGoldenTests
@MainActor
@Suite("狀態機回歸指紋")
struct EngineGoldenTests {
    static let seedsPerGroup: UInt64 = 100

    static let expected: [String] = [
        // GOLDEN-BEGIN
        "bb57ed6536b6cff2942b09e67531d080a98fbe38a3ea6050098320f0150436f0",
        "3ab4cb2aac7d2293cec223c3874667d2538fd97448e2b008251c0c32f4a19f84",
        "9f689b7b6caf2f7a0fa68c6ac5d61332ab7578e60e2a566eb020de6d7dcb6244",
        "b3f69c317bd84bca829a8d1b8864583af22c8b328a2f07c13c13e4d72472180e",
        "a388c9fb2a805079449573a5f68b1a0b5b17fffdc75dac9357e7de26fd6671a3",
        "e9bc8db4285ee0357083c6ec4fdf934ba06cc7220011f99af594a69deb09e0c1",
        "eeb0c663b37566b499a059d76a21c1154f55351540d9b79d99e511d6d0b61951",
        "96436aaa00327015771cfa15fcd2e70ad027907eac64e332dc29098284836508",
        "18dbfa38df71e0b8f6b72b526509696e171fa2c7db5cdf13d150f31b1a5be1f1",
        "4ef0e5efd53989a8465c0260b4443d9d16327d9e48ef0b0ec464a60e586fd2e1",
        "f9836d33883df33d14295afa8eae48911109b7940b4cce1103fdfc2bfb6a633f",
        "2f11e503d7fb1c68bf3a5ec5de3a3de575e4474f53ab4a077ab3604a9b4aea95",
        "1b9344ae11f3084d4878098420750382f817f73cef6add9511e0f0b1ebc60145",
        "c0d40dd35546640c9ed5700fd919814714aae1c55e23267b3280c14210092aa8",
        "45cf5a49148e4575ae66808f37efa37628efb5dfe962974a7d0619904b25c48d",
        "fb72bf00dcecddfdcc671f669dc1b87cbe2d708a053f1c05c61063bb0606c1e1",
        // GOLDEN-END
    ]

    static func digest(group: Int) -> String {
        var hasher = SHA256()
        let first = UInt64(group) * seedsPerGroup + 1
        for seed in first..<(first + seedsPerGroup) {
            let scenario = ScenarioFuzzer.scenario(seed: seed)
            hasher.update(data: Data("### \(scenario.name)\n".utf8))
            for line in EngineScenarioRunner.run(scenario) {
                hasher.update(data: Data(line.utf8))
                hasher.update(data: Data([0x0A]))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @Test("16 組、共 1,600 個情境的輸出指紋不變")
    func transcriptsMatchRecordedDigests() {
        let groupCount = 16
        let actual = (0..<groupCount).map(Self.digest(group:))

        if ProcessInfo.processInfo.environment["TRACKPAL_PRINT_GOLDEN"] != nil {
            print("// GOLDEN-BEGIN")
            for digest in actual { print("        \"\(digest)\",") }
            print("// GOLDEN-END")
        }

        #expect(Self.expected.count == groupCount)
        for (group, digest) in actual.enumerated() where group < Self.expected.count {
            #expect(
                digest == Self.expected[group],
                "seed \(group * 100 + 1)…\(group * 100 + 100) 的輸出變了"
            )
        }
    }

    @Test("同一個 seed 產生的情境完全相同")
    func fuzzerIsDeterministic() {
        #expect(ScenarioFuzzer.scenario(seed: 42) == ScenarioFuzzer.scenario(seed: 42))
        #expect(ScenarioFuzzer.scenario(seed: 42) != ScenarioFuzzer.scenario(seed: 43))
    }

    @Test("SplitMix64 的輸出跟參考實作一致")
    func splitMixMatchesReference() {
        // seed 0 的前三個值，出自 SplitMix64 的參考實作。
        var rng = SplitMix64(seed: 0)
        do { let value = rng.next(); #expect(value == 0xE220_A839_7B1D_CDAF) }
        do { let value = rng.next(); #expect(value == 0x6E78_9E6A_A1B9_65F4) }
        do { let value = rng.next(); #expect(value == 0x06C4_5D18_8009_454F) }
    }

    @Test("同一段輸入重播兩次，輸出相同（狀態機沒有隱藏的全域狀態）")
    func replayIsRepeatable() {
        let scenario = ScenarioFuzzer.scenario(seed: 7)
        #expect(EngineScenarioRunner.run(scenario) == EngineScenarioRunner.run(scenario))
    }

    @Test("情境可以存成 JSON 再讀回來")
    func scenarioRoundTripsThroughJSON() throws {
        let scenario = ScenarioFuzzer.scenario(seed: 11)
        let data = try JSONEncoder().encode(scenario)
        let decoded = try JSONDecoder().decode(EngineScenario.self, from: data)
        // NaN 不等於自己，所以比對重播結果而不是比對值。
        #expect(EngineScenarioRunner.run(decoded) == EngineScenarioRunner.run(scenario))
    }

    @Test("設定裡有不認得的值：不執行，回報錯誤")
    func invalidSettingsAreReported() {
        var scenario = EngineScenario(name: "bad")
        scenario.settings.verticalEdgeMode = "diagonal"
        #expect(EngineScenarioRunner.run(scenario) == ["error invalid settings"])
        #expect(ZoneScrollConfiguration(scenario.settings) == nil)
    }
}
