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
        "9115a7763c53a9e2e2e3b9f0202b6ba25e8f5a9b79f350ab517e2194dca38c28",
        "170a1ee205d3638ef59abacae648bcd67e96ee3cbf37ee643e4b20b4d8ed1781",
        "ae7a40c2f00970d7e32794f64789b5723f242e80ca0160f375cddc297ffd336e",
        "b2998aed6c0e1e484ae89e3c36bae22275949fab7d3152685a3dc134bf0a8fa5",
        "6a335af3198c9fb5fa0351d6b97b6dd21e646ccb5603dc6c8428b1518a307d5a",
        "add8139155ddde86811402a65c3af44c7620de06ad2acdb368d5f4f031bb6cc1",
        "e6726827a4c4f6d114494b30e6551fba7f30cbb4061e7311590aba43eddcce30",
        "e0401540e210c6a982ea6cc3161cf87f694d30eccb61dfa31568e140cffb9a42",
        "7aaf31b4cc6811fdba536e96ad96fb2c6ce38571b03be2d275f6aed1ffd54c91",
        "d04b476097f28121301d177400ca411571481b79b5873e8fb91e836d56e323a1",
        "ca1dd318dc740c5c6e04f29d2b69302057b3f67c45cb68c3779bc25b87170dc1",
        "c4f5b80cfcfb25aed42d6c95c6427ca553b5fd10f0696466a5f89f0d0e4773a3",
        "8be1e25b8f71375f7cf8d8935084a8d0adcf18578c9af8534bd69aa66ef9626a",
        "bdee269c3c5b05ce5f4f763b413012c2b1f9ae1d5a0a7dc65328345e617177a4",
        "86b5c4018d49be003cc211d1e6734070687d9b3b0f007100284c7d32fbbcf52e",
        "d7cbce4e114652b8c77d35e3a1c17311f76e078048c70c296ecb9a38f5d448f3",
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
