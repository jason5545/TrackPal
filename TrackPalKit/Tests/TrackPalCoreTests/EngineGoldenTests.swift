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
        "704a9660beb7a74a79088ddf86f14ab133fb58fef408cd3a688d12bad5fab4b0",
        "a261ed8ce29159cb3d8be97defb05cdfa1a6500127b8c8060984a0793dbf3a37",
        "f0c48d86d29b2b4b4d2979eafe3e5d88f02362006bd97e30b82cac1112da7d78",
        "3f10bec88d0e99107da18715a30d30f1aeb5c961f4a12f327216fc300b65cf19",
        "1f46a51661a5aea051d5f9cebfdeceec42bb68f352c0db8413e5cc77b8b45b3a",
        "456cf06de1079fca2803ab2c0d12ec937909a83f20e7e095dd6c8167b9c0f0a2",
        "2db0af8166654595b623129327fdb4e31128826a4b406bfdad4acce9b7ab308a",
        "840cd9445dcece519e88ee38c217b67da4fc914ada22c4ff3561ea3c0d1f95da",
        "ef5cca900442f9a662c89e6c8d13491f0f7445a5cbaec8f04f38549ebf560479",
        "02aec00c9a076dfc0e1e558895c69f71356c3f17d8807dd4fe3360cc2ea3c3b9",
        "bfbb15230bf60ac6ea7150e5fb41855a89dc2e571c835414c95c26360bd51a91",
        "7489b43ca4d31ba0216b612d13fc6f87d10ba0da7fcbf9a1b2dbae96f233ddec",
        "4fce532662440f7346d4a4d1065615487b5a25390053a2c8fad880befe51f908",
        "b6cde6026e4dcacd33a13949044f0b014b909fd14f2dc37b11f1fac6d76a920f",
        "7d71cf7eda7020f63ae967e1a0bb8e7cd4efa1697d4fa97edfa38c44a61456da",
        "0c841870ca8138b474ba03612a43dcc55ee32022a1b0c50a8b56838d1e4cc2c4",
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
